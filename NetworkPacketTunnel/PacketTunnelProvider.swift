import Clash
import Foundation
import NetworkExtension
import OSLog

#if !DEBUG
#error("Build 15 GeoData redistribution provenance is not approved")
#endif

private final class ProviderCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Error?) -> Void)?
    init(_ handler: @escaping (Error?) -> Void) { self.handler = handler }
    func finish(_ error: Error?) {
        lock.lock(); let callback = handler; handler = nil; lock.unlock()
        callback?(error)
    }
}

private final class ProviderMessageCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Data?) -> Void)?
    init(_ handler: ((Data?) -> Void)?) { self.handler = handler }
    func finish(_ data: Data?) {
        lock.lock(); let callback = handler; handler = nil; lock.unlock()
        callback?(data)
    }
}

private struct ProviderRuntimeFiles {
    let configuration: MihomoTunnelConfiguration
    let base: URL
    let cache: URL
    let controlSocket: URL
}

private final class ProviderStartResources {
    let configurationID: UUID
    var configuration: MihomoTunnelConfiguration?
    var files: ProviderRuntimeFiles?
    var geoData: GeoDataPublication?
    var platform: TunnelPlatform?
    init(configurationID: UUID) { self.configurationID = configurationID }
    func cleanup() {
        platform?.stop()
        platform = nil
        if let files {
            try? FileManager.default.removeItem(at: files.base.appendingPathComponent("latency-candidates.yaml"))
            try? FileManager.default.removeItem(at: files.controlSocket)
        }
        try? MihomoTunnelStore.remove(expectedGeneration: configurationID)
    }
}

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let worker = DispatchQueue(label: "NetworkClient.MihomoPacketTunnel.worker")
    private let probeExecutor = ProviderProbeExecutor()
    private let runtime = ProviderRuntime()
    private let logger = Logger(subsystem: "NetworkClient.PacketTunnel", category: "vpn")

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let completion = ProviderCompletion(completionHandler)
        logger.info("provider start entered")
        // Only this start's fresh configuration is accepted. Saved preference
        // metadata and old runtime/stage records never select a configuration.
        guard let text = options?["configurationGeneration"] as? String,
              let configurationID = UUID(uuidString: text), let id = runtime.beginStart() else {
            completion.finish(providerError(.configuration))
            return
        }
        worker.async { [self] in
            let resources = ProviderStartResources(configurationID: configurationID)
            runtime.start(id: id, operations: .init(
                loadConfiguration: {
                    resources.configuration = try MihomoTunnelStore.load(expectedGeneration: configurationID)
                },
                prepareRuntime: {
                    guard let configuration = resources.configuration else {
                        throw ProviderRuntime.Failure.configuration
                    }
                    resources.files = try Self.prepareRuntime(configuration)
                },
                ensureGeoData: {
                    guard resources.files != nil,
                          let configuration = resources.configuration,
                          let publicationIdentifier = configuration.geoDataPublicationIdentifier else {
                        throw GeoDataContractError.publicationMismatch
                    }
                    resources.geoData = try GeoDataReadiness.requireCurrent(
                        in: GeoDataStore.root(),
                        expectedPublicationIdentifier: publicationIdentifier
                    )
                },
                setup: {
                    guard let files = resources.files,
                          let geoData = resources.geoData else { throw ProviderRuntime.Failure.runtime }
                    let setup = ClashSetupOptions()
                    // GeoData remains pinned to this immutable directory for
                    // the full Provider session; mutable work/cache paths stay
                    // in the existing extension-owned locations.
                    setup.basePath = geoData.directory.path
                    setup.workingPath = files.base.path
                    setup.tempPath = files.base.path
                    setup.clashAPISocketPath = files.controlSocket.path
                    setup.runtimeProfile = ClashRuntimeProfileIOSPacketTunnel
                    setup.ipQueryMode = "config"
                    setup.tunIPv6Mode = "automatic"
                    setup.tunMTU = 1500
                    setup.disablePersistentCache = false
                    setup.persistentCacheDirectory = files.cache.path
                    setup.maxProcs = 1
                    setup.includeAllNetworks = false
                    setup.timeZone = TimeZone.current.identifier
                    var error: NSError?
                    return (ClashSetup(setup, &error), error)
                },
                createService: {
                    guard let files = resources.files else { throw ProviderRuntime.Failure.runtime }
                    let platform = TunnelPlatform(provider: self)
                    resources.platform = platform
                    var error: NSError?
                    let candidate = ClashNewService(platform, &error)
                    let service = candidate.map { candidate in
                        let configuredNames = Set(
                            files.configuration.candidatePool?.map(\.coreName)
                                ?? [files.configuration.coreName].compactMap { $0 }
                        )
                        return ProviderRuntime.Service(start: {
                            try ProviderRuntime.startService(
                                start: { try candidate.start(files.configuration.yaml) },
                                coreName: files.configuration.coreName,
                                select: { group, name in
                                    var error: NSError?
                                    return (ClashSelectProxy(group, name, &error), error)
                                }
                            )
                        },
                        close: { resources.platform?.stop(); try candidate.close() },
                        candidateCoreNames: configuredNames,
                        candidatePoolRevision: files.configuration.candidatePoolRevision,
                        selectorCandidateCoreNames: { Self.currentVPNCandidateCoreNames() },
                        selectedNode: { Self.selectedVPNCoreName() },
                        selectNode: { target in
                            var error: NSError?
                            return ClashSelectProxy("VPN", target, &error) && error == nil
                        },
                        mode: { candidate.mode().lowercased() },
                        setMode: { target in
                            do { try candidate.setMode(target); return true }
                            catch { return false }
                        },
                        closeConnections: {
                            // The pinned global API has no failure return. It
                            // synchronously closes every tracked connection.
                            ClashCloseAllConnections()
                            return true
                        },
                        trafficSnapshot: { Self.currentTrafficSnapshot() },
                        probeNode: { Self.probeCurrentCore($0) })
                    }
                    return (service, error)
                },
                cleanup: { resources.cleanup() }
            ), completion: { error in
                if let error {
                    let failure = error as? ProviderRuntime.Failure ?? .serviceStart
                    if failure == .serviceStart { logger.error("provider service start failed") }
                    else { logger.error("provider setup failed category=\(String(describing: failure), privacy: .public)") }
                    completion.finish(providerError(failure))
                } else {
                    logger.info("provider service started")
                    completion.finish(nil)
                }
            })
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.info("provider stop entered")
        let completion = ProviderCompletion { _ in completionHandler() }
        let id = runtime.cancelStart()
        worker.async { [self] in
            // Keep the service and fixed Core alive until every admitted URLTest
            // has returned. Pending App messages remain queued on `worker`.
            probeExecutor.waitForAll()
            runtime.stop(id: id) { completion.finish(nil) }
        }
    }

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)? = nil
    ) {
        let completion = ProviderMessageCompletion(completionHandler)
        worker.async { [self] in
            guard let request = MihomoTunnelControlCodec.decodeRequest(messageData) else {
                completion.finish(MihomoTunnelControlCodec.encode(.init(
                    requestID: nil, result: .init(status: .malformed)
                )))
                return
            }
            if request.isWellFormed, request.knownCommand == .probeNodes,
               let targetCount = request.payload?.probeCoreNames?.count {
                let accepted = probeExecutor.submit(targetCount: targetCount) { [self] in
                    let result = runtime.handle(request)
                    logger.info("provider control command=\(request.command, privacy: .public) status=\(result.status.rawValue, privacy: .public)")
                    completion.finish(MihomoTunnelControlCodec.encode(.init(
                        requestID: request.requestID, result: result
                    )))
                }
                if !accepted {
                    completion.finish(MihomoTunnelControlCodec.encode(.init(
                        requestID: request.requestID, result: .init(status: .malformed)
                    )))
                }
                return
            }
            if ProviderControlScheduling.requiresProbeDrain(before: request.knownCommand) {
                // Node/mode mutations remain exclusive with URLTest. Traffic
                // snapshots deliberately do not wait and stay responsive.
                probeExecutor.waitForAll()
            }
            let result = runtime.handle(request)
            logger.info("provider control command=\(request.command, privacy: .public) status=\(result.status.rawValue, privacy: .public)")
            completion.finish(MihomoTunnelControlCodec.encode(.init(
                requestID: request.requestID, result: result
            )))
        }
    }

    private static func selectedVPNCoreName() -> String? {
        struct Catalog: Decodable {
            struct Proxy: Decodable { let now: String? }
            let proxies: [String: Proxy]
        }
        guard let data = ClashProxiesJSON().data(using: .utf8),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else { return nil }
        return catalog.proxies["VPN"]?.now
    }

    private static func currentVPNCandidateCoreNames() -> Set<String>? {
        ProviderRuntime.candidateCoreNames(
            fromGroupMembersJSON: ClashGroupMembersJSON("VPN", 0, 0)
        )
    }

    private static func probeCurrentCore(_ coreName: String) -> ProviderRuntime.ProbeMeasurement {
        guard let target = NodeLatencyTarget.url else { return .unavailable }
        let delay = Int(ClashURLTest(coreName, target))
        guard delay < 0 else { return .measured(delay) }
        let failure = MihomoProbeFailureKind.from(
            delaySnapshot: ClashProxyDelaysJSON(), proxyName: coreName
        )
        return failure == .timeout ? .timedOut : .failed
    }

    private static func currentTrafficSnapshot() -> ProviderRuntime.TrafficSnapshot? {
        struct Traffic: Decodable {
            let up: Int64
            let down: Int64
            let rateFresh: Int64
            let rateSampledAtUnixMs: Int64
        }
        guard let data = ClashTrafficJSON().data(using: .utf8),
              let traffic = try? JSONDecoder().decode(Traffic.self, from: data) else { return nil }
        return .init(
            uploadBytesPerSecond: traffic.rateFresh == 1 ? traffic.up : 0,
            downloadBytesPerSecond: traffic.rateFresh == 1 ? traffic.down : 0,
            sampledAtUnixMilliseconds: traffic.rateSampledAtUnixMs
        )
    }

    private static func prepareRuntime(_ configuration: MihomoTunnelConfiguration) throws -> ProviderRuntimeFiles {
        let base = FileManager.default.temporaryDirectory
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw ProviderRuntime.Failure.runtime
        }
        let cache = caches
            .appendingPathComponent("NetworkClientVPN", isDirectory: true)
            .appendingPathComponent("PersistentCache", isDirectory: true)
        let controlSocket = ProviderRuntimePaths.controlSocket(in: base)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: controlSocket)
        let emptyProvider = "proxies:\n  - {name: __networkclient_latency_empty__, type: reject}\n"
        try Data(emptyProvider.utf8).write(to: base.appendingPathComponent("latency-candidates.yaml"),
                                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #if !targetEnvironment(simulator)
        for directory in [base, cache] {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                 ofItemAtPath: directory.path)
        }
        #endif
        return .init(configuration: configuration, base: base, cache: cache, controlSocket: controlSocket)
    }

    private func providerError(_ failure: ProviderRuntime.Failure) -> NSError {
        let code: Int
        switch failure {
        case .configuration: code = 11
        case .runtime: code = 17
        case .geoData: code = 20
        case .setup: code = 13
        case .serviceCreation: code = 14
        case .serviceStart: code = 15
        case .cancelled: code = 16
        }
        return NSError(domain: "NetworkClientVPNTest.TunnelStart", code: code)
    }
}
