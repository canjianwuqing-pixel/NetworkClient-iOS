import Clash
import Foundation

/// Retains only an error class and phase; SDK errors can contain private config.
struct MihomoCoreFailure: Error, Sendable {
    let stage: String
    let domain: String
    let code: Int

    init(_ stage: String, _ error: NSError?) {
        self.stage = stage
        domain = error?.domain ?? "none"
        code = error?.code ?? 0
    }
}

enum MihomoNodeProbeError: Error, Equatable, Sendable {
    case timeout, unreachable
}

/// Deliberately non-Sendable. One AppOnlyRecoveryRuntime actor owns this object;
/// its ClashBoxService and all SDK calls stay on that actor's serial execution.
/// The Objective-C platform callback holds no Swift runtime state.
final class MihomoCoreBridge {
    private var service: ClashBoxService?

    var hasService: Bool { service != nil }
    var isRunning: Bool { service?.status() == "running" }

    func setup(in base: URL, cache: URL) throws -> Int {
        let options = ClashSetupOptions()
        options.basePath = base.path
        options.workingPath = base.path
        options.tempPath = base.path
        options.runtimeProfile = ClashRuntimeProfileIOSApplication
        // This pinned SDK requires a persistent cache to create a service.
        // It is confined to the app-private, data-protected temp directory.
        options.disablePersistentCache = false
        options.persistentCacheDirectory = cache.path
        let started = ProcessInfo.processInfo.systemUptime
        var error: NSError?
        guard ClashSetup(options, &error) else { throw MihomoCoreFailure("setup", error) }
        return Int(((ProcessInfo.processInfo.systemUptime - started) * 1_000).rounded())
    }

    func start(yaml: String) throws -> (configMS: Int, serviceStartMS: Int) {
        precondition(service == nil, "Core owner must stop before starting again")
        let configStarted = ProcessInfo.processInfo.systemUptime
        var configError: NSError?
        guard ClashCheckConfig(yaml, &configError) else {
            throw MihomoCoreFailure("config", configError)
        }
        let configMS = Int(((ProcessInfo.processInfo.systemUptime - configStarted) * 1_000).rounded())
        let serviceStarted = ProcessInfo.processInfo.systemUptime
        var creationError: NSError?
        guard let candidate = ClashNewService(MihomoAppPlatform(), &creationError) else {
            throw MihomoCoreFailure("create", creationError)
        }
        do {
            try candidate.start(yaml)
            service = candidate
            return (
                configMS,
                Int(((ProcessInfo.processInfo.systemUptime - serviceStarted) * 1_000).rounded())
            )
        } catch {
            let startFailure = MihomoCoreFailure("start", error as NSError)
            do {
                try candidate.close()
            } catch {
                // Keep ownership if close fails. A subsequent start must not
                // orphan this service or crash at the single-owner precondition.
                service = candidate
                throw MihomoCoreFailure("start-close", error as NSError)
            }
            throw startFailure
        }
    }

    /// Mihomo's pinned HTTP URLTest sends the request through the named
    /// outbound. A negative value means failure, never a measured delay.
    func httpDelay(proxyName: String) throws -> Int {
        guard isRunning, !proxyName.isEmpty else { throw MihomoCoreFailure("probe-not-running", nil) }
        return try Self.httpDelayForRunningProxy(proxyName: proxyName)
    }

    /// Called only while the owning actor keeps the one Core service alive.
    /// This entry point contains no mutable Swift SDK ownership; Mihomo runs
    /// separate named outbound URLTests concurrently in Go.
    static func httpDelayForRunningProxy(proxyName: String) throws -> Int {
        guard let target = NodeLatencyTarget.url else {
            throw MihomoCoreFailure("probe-target", nil)
        }
        let delay = Int(ClashURLTest(proxyName, target))
        guard delay >= 0 else {
            let failure = MihomoProbeFailureKind.from(
                delaySnapshot: ClashProxyDelaysJSON(), proxyName: proxyName
            )
            throw failure == .timeout ? MihomoNodeProbeError.timeout : MihomoNodeProbeError.unreachable
        }
        return delay
    }

    @discardableResult
    func stop() -> MihomoCoreFailure? {
        guard let current = service else { return nil }
        do {
            try current.close()
            service = nil
            return nil
        } catch {
            // Retain ownership for a bounded retry; do not orphan a listener.
            return MihomoCoreFailure("stop", error as NSError)
        }
    }
}
