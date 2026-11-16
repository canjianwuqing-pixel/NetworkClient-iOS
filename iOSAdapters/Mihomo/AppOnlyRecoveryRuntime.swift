import Foundation
import Network

/// URLSession does not expose the SOCKS handshake or the Mihomo-to-node DNS
/// exchange. Nil means unobserved, never zero elapsed time.
struct ProxyRequestTiming: Sendable {
    let completedAtUnixMS: Int
    let coreCold: Bool
    let setupMS: Int?
    let configMS: Int?
    let serviceStartMS: Int?
    let urlSessionDNSMS: Int?
    /// Apple's connect interval may include TLS and describes URLSession's
    /// connection, not the Mihomo-to-upstream socket.
    let urlSessionConnectMS: Int?
    let tlsMS: Int?
    let firstByteMS: Int?
    let totalMS: Int
    let reusedConnection: Bool?

    var sanitizedLine: String {
        func field(_ value: Int?) -> String { value.map(String.init) ?? "unobserved" }
        let reuse = reusedConnection.map(String.init) ?? "unobserved"
        return "atUnixMS=\(completedAtUnixMS) coreCold=\(coreCold) setupMS=\(field(setupMS)) configMS=\(field(configMS)) serviceStartMS=\(field(serviceStartMS)) urlSessionDNSMS=\(field(urlSessionDNSMS)) urlSessionConnectMS=\(field(urlSessionConnectMS)) proxyHandshakeMS=unobserved tlsMS=\(field(tlsMS)) firstByteMS=\(field(firstByteMS)) totalMS=\(totalMS) reusedConnection=\(reuse)"
    }
}

/// The sole mutable value is guarded by lock. Delegate callbacks may arrive
/// off actor; only an immutable scalar snapshot crosses into the actor.
private final class ProxyTaskMetrics: NetworkRedirectPolicyDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var collected: (dns: Int?, tcp: Int?, tls: Int?, firstByte: Int?, reused: Bool?)?

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let transaction = metrics.transactionMetrics.last else { return }
        func elapsed(_ start: Date?, _ end: Date?) -> Int? {
            guard let start, let end, end >= start else { return nil }
            return Int((end.timeIntervalSince(start) * 1_000).rounded())
        }
        let values = (
            dns: elapsed(transaction.domainLookupStartDate, transaction.domainLookupEndDate),
            tcp: elapsed(transaction.connectStartDate, transaction.connectEndDate),
            tls: elapsed(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate),
            firstByte: elapsed(transaction.requestEndDate, transaction.responseStartDate),
            reused: Optional(transaction.isReusedConnection)
        )
        lock.lock()
        collected = values
        lock.unlock()
    }

    func snapshot() -> (dns: Int?, tcp: Int?, tls: Int?, firstByte: Int?, reused: Bool?)? {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }
}

enum RecoveryRuntimeError: Error {
    case coolingDown
    case differentNodeInUse
    case unavailable
    case invalidPort
    case stopFailed
}

/// Synchronous SDK boundary, owned exclusively by the recovery actor.
/// Tests substitute this boundary without starting a real Core or network I/O.
protocol MihomoRecoveryCore: AnyObject {
    var hasService: Bool { get }
    var isRunning: Bool { get }
    func setup(in base: URL, cache: URL) throws -> Int
    func start(yaml: String) throws -> (configMS: Int, serviceStartMS: Int)
    func stop() -> MihomoCoreFailure?
    func httpDelay(proxyName: String) throws -> Int
}

extension MihomoCoreBridge: MihomoRecoveryCore {}

/// Main-app recovery only. It never opens TUN or changes system proxy/DNS.
/// The API router starts it only after eligible direct paths fail.
actor MihomoAppRecoveryRuntime: BuiltInProxyRecoveryRuntimeProtocol {
    private let idleSeconds: TimeInterval
    private struct PathSignature: Equatable, Sendable {
        let ready: Bool
        let wifi: Bool
        let cellular: Bool
        let wired: Bool
        let expensive: Bool
        let constrained: Bool
        let ipv4: Bool
        let ipv6: Bool

        init(_ path: NWPath) {
            ready = path.status == .satisfied
            wifi = path.usesInterfaceType(.wifi)
            cellular = path.usesInterfaceType(.cellular)
            wired = path.usesInterfaceType(.wiredEthernet)
            expensive = path.isExpensive
            constrained = path.isConstrained
            ipv4 = path.supportsIPv4
            ipv6 = path.supportsIPv6
        }
    }

    struct Snapshot: Sendable {
        let lifecycle: MihomoBridgeLifecycle
        let running: Bool
        let loopbackPort: UInt16?
        let activeRequests: Int
        let coolingDown: Bool
        let failureStage: String
        let failureDomain: String
        let failureCode: Int
        let pathChanges: Int
        let pathKind: String
    }

    private let failureCooldownSeconds: TimeInterval = 10
    private let requestTimeoutSeconds: TimeInterval = 7
    // The non-Sendable SDK owner never leaves this actor.
    private let core: any MihomoRecoveryCore
    private var lifecycle: MihomoBridgeLifecycle = .idle
    private var session: URLSession?
    private var localPort: UInt16?
    private var activeNode: RecoveryNode?
    private var configuredNode: RecoveryNode?
    private var activeRequests = 0
    private var batchProbing = false
    private var batchInvalidated = false
    private var probeDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var failureUntil: Date?
    private var idleTask: Task<Void, Never>?
    private var generation = MihomoBridgeGeneration()
    private let pathMonitor = NWPathMonitor()
    private var lastPath: PathSignature?
    private var pathChanges = 0
    private var pathKind = "unknown"
    private var failureStage = "none"
    private var failureDomain = "none"
    private var failureCode = 0
    private var latestTiming: ProxyRequestTiming?
    private var recentTimings: [ProxyRequestTiming] = []

    func requestTiming() -> ProxyRequestTiming? { latestTiming }
    func drainTimings() -> [ProxyRequestTiming] {
        defer { recentTimings.removeAll(keepingCapacity: true) }
        return recentTimings
    }

    init(idleSeconds: TimeInterval = 30, core: sending (any MihomoRecoveryCore)? = nil) {
        self.idleSeconds = max(1, idleSeconds)
        self.core = core ?? MihomoCoreBridge()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let signature = PathSignature(path)
            Task { await self?.pathDidUpdate(signature) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "NetworkClient.MihomoRecoveryPath"))
    }

    deinit { pathMonitor.cancel() }

    func snapshot() -> Snapshot {
        Snapshot(
            lifecycle: lifecycle,
            running: core.isRunning,
            loopbackPort: localPort,
            activeRequests: activeRequests,
            coolingDown: failureUntil.map { Date() < $0 } ?? false,
            failureStage: failureStage,
            failureDomain: failureDomain,
            failureCode: failureCode,
            pathChanges: pathChanges,
            pathKind: pathKind
        )
    }

    #if DEBUG
    // Exercise the real quiesce continuation without running latency probes.
    func beginBatchForCancellationTesting() {
        precondition(!batchProbing && !core.hasService)
        batchProbing = true
    }

    func batchDrainWaiterCountForTesting() -> Int { probeDrainWaiters.count }

    func finishBatchForCancellationTesting() {
        batchProbing = false
        let waiters = probeDrainWaiters
        probeDrainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// Acceptance-only proof that the running Core can reach its existing,
    /// non-sensitive latency target through the named recovery outbound.
    func validateActiveRecoveryOutbound() throws -> Int {
        guard configuredNode != nil, core.isRunning else {
            throw RecoveryRuntimeError.unavailable
        }
        return try core.httpDelay(proxyName: "recovery")
    }
    #endif

    /// The App-only Core is a single owner. A probe never takes over a live
    /// recovery service, changes the system tunnel, or switches its selector.
    /// The SDK bounds its HTTP URLTest to five seconds; this synchronous actor
    /// section also prevents recovery requests from interleaving with a probe.
    func quiesce() async {
        // A single URLTest occupies the actor synchronously. A batch yields
        // while its task group joins Core calls, so wait for its deferred stop.
        guard batchProbing else { return }
        // The caller is about to start the system tunnel. Stop scheduling
        // further URLTests, then wait until the existing Core calls have joined.
        batchInvalidated = true
        await withCheckedContinuation { probeDrainWaiters.append($0) }
    }

    func probeNode(yaml: String, coreName: String) async throws -> Int {
        guard !batchProbing, !core.hasService, activeRequests == 0,
              configuredNode == nil else {
            throw RecoveryRuntimeError.unavailable
        }
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mihomo-node-probe", isDirectory: true)
        let cache = base.appendingPathComponent("private-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        #if !targetEnvironment(simulator)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete],
                                              ofItemAtPath: base.path)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete],
                                              ofItemAtPath: cache.path)
        #endif
        _ = try core.setup(in: base, cache: cache)
        try Task.checkCancellation()
        defer { _ = core.stop() }
        _ = try core.start(yaml: yaml)
        let delay = try core.httpDelay(proxyName: coreName)
        try Task.checkCancellation()
        return delay
    }

    func probeBatch(
        _ candidates: [NodeProbeCandidate],
        onStart: @escaping @Sendable (NodeProbeCandidate) async -> Bool,
        onResult: @escaping @Sendable (NodeProbeResult) async -> Void
    ) async throws {
        guard !candidates.isEmpty else { return }
        guard !batchProbing, !core.hasService, activeRequests == 0,
              configuredNode == nil else {
            throw RecoveryRuntimeError.unavailable
        }
        batchProbing = true
        batchInvalidated = false
        defer {
            // The task group joins every in-flight URLTest before Core stops.
            // Never close the global SDK service under an active Go request.
            _ = core.stop()
            batchProbing = false
            batchInvalidated = false
            let waiters = probeDrainWaiters
            probeDrainWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        let yaml = try MihomoNodeProbeConfiguration.batchYAML(from: candidates)
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mihomo-node-probe", isDirectory: true)
        let cache = base.appendingPathComponent("private-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        #if !targetEnvironment(simulator)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete],
                                              ofItemAtPath: base.path)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete],
                                              ofItemAtPath: cache.path)
        #endif
        _ = try core.setup(in: base, cache: cache)
        try Task.checkCancellation()
        _ = try core.start(yaml: yaml)
        let startedAt = ProcessInfo.processInfo.systemUptime
        let peak = await NodeProbePool.run(candidates, probe: { name in
            do {
                return .measured(try MihomoCoreBridge.httpDelayForRunningProxy(proxyName: name))
            } catch MihomoNodeProbeError.timeout { return .timedOut }
            catch { return .failed }
        }, shouldContinue: { [weak self] in
            await self?.batchIsCurrent() == true
        }, onStart: { candidate in
            await onStart(candidate)
        }, onResult: { [weak self] result in
            guard await self?.batchIsCurrent() == true else { return }
            await onResult(result)
        })
        #if ROUTE_VALIDATION
        let elapsed = Int(((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000).rounded())
        SafeLog.info("[Latency] batch completed count=\(candidates.count) peak=\(peak) elapsedMS=\(elapsed)")
        #endif
        try Task.checkCancellation()
        guard !batchInvalidated else { throw CancellationError() }
    }

    private func batchIsCurrent() -> Bool { batchProbing && !batchInvalidated }

    func request(_ request: URLRequest, through node: RecoveryNode,
                 kind: NetworkRequestKind = .apiRead) async throws -> (Data, URLResponse) {
        guard !batchProbing else { throw RecoveryRuntimeError.unavailable }
        try OperationDeadline.checkCurrent()
        let requestStarted = ProcessInfo.processInfo.systemUptime
        let (transport, coreCold, setupMS, configMS, serviceStartMS) = try startIfNeeded(node)
        let requestEpoch = generation.value
        try checkStartupCancellation()
        idleTask?.cancel()
        idleTask = nil
        activeRequests += 1
        defer { finishRequest() }
        let metrics = ProxyTaskMetrics(kind: kind)
        func saveTiming() {
            let observed = metrics.snapshot()
            latestTiming = ProxyRequestTiming(
                completedAtUnixMS: Int(Date().timeIntervalSince1970 * 1_000),
                coreCold: coreCold, setupMS: setupMS, configMS: configMS,
                serviceStartMS: serviceStartMS, urlSessionDNSMS: observed?.dns,
                urlSessionConnectMS: observed?.tcp, tlsMS: observed?.tls,
                firstByteMS: observed?.firstByte,
                totalMS: Int(((ProcessInfo.processInfo.systemUptime - requestStarted) * 1_000).rounded()),
                reusedConnection: observed?.reused
            )
            if let latestTiming { recentTimings.append(latestTiming) }
        }
        do {
            let response = try await transport.data(for: request, delegate: metrics)
            try OperationDeadline.checkCurrent()
            // A path change, background stop, or explicit stop may have
            // replaced the service while URLSession was suspended.
            guard generation.contains(requestEpoch) else { throw CancellationError() }
            saveTiming()
            return response
        } catch {
            saveTiming()
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            let code = (error as NSError).code
            if generation.contains(requestEpoch), !Task.isCancelled,
               !(error is CancellationError), code != NSURLErrorCancelled {
                diagnose("request", error as NSError)
            }
            // One API target failing does not prove the proxy endpoint or Core
            // is unusable. APIRecoveryRouter owns the endpoint attempt and may
            // still need the same live transport for the next configured API.
            // It stops the Runtime after success or after exhausting targets.
            throw error
        }
    }

    func start(endpoint: BuiltInProxyEndpoint) async throws -> BuiltInProxyRecoveryRuntimeInfo {
        try OperationDeadline.checkCurrent()
        #if DEBUG
        let diagnosticOperation = DeveloperDiagnosticOperation.make("app-recovery")
        DeveloperDiagnostics.shared.record(.init(
            operationID: diagnosticOperation, module: .recovery,
            stage: "app-proxy-runtime", outcome: "start-requested",
            detail: "protocol=\(endpoint.protocolName) path=\(pathKind)"
        ))
        #endif
        // A real recovery request has priority over low-priority latency work.
        // Stop scheduling new URLTests and wait for the bounded in-flight group
        // to drain before acquiring the one Core service.
        if batchProbing { await quiesce() }
        try OperationDeadline.checkCurrent(minimum: OperationBudget.minimumRecoveryStart)
        guard !batchProbing else { throw RecoveryRuntimeError.unavailable }
        // The endpoint parser must preserve all security-relevant share fields.
        // Strict mapping rejects protocols and fields this pinned Core cannot honor.
        let node = try BuiltInProxyBridge.map(endpoint.normalizedValue)
        if let configuredNode, configuredNode != node {
            throw RecoveryRuntimeError.differentNodeInUse
        }
        _ = try startIfNeeded(node)
        configuredNode = node
        guard let localPort else { throw RecoveryRuntimeError.invalidPort }
        #if DEBUG
        DeveloperDiagnostics.shared.record(.init(
            operationID: diagnosticOperation, module: .recovery, level: .success,
            stage: "app-proxy-runtime", outcome: "running",
            generation: String(generation.value), detail: "protocol=\(endpoint.protocolName)"
        ))
        #endif
        return BuiltInProxyRecoveryRuntimeInfo(
            protocolName: endpoint.protocolName,
            mixedPort: localPort
        )
    }

    func makeRecoveryTransport() throws -> any NetworkTransport {
        try OperationDeadline.checkCurrent()
        guard let configuredNode, core.isRunning else { throw RecoveryRuntimeError.unavailable }
        return MihomoRecoveryTransport(
            owner: self, node: configuredNode, generation: generation.value
        )
    }

    fileprivate func routedRequest(
        _ request: URLRequest, through node: RecoveryNode, generation expected: UInt64,
        kind: NetworkRequestKind
    ) async throws -> (Data, URLResponse) {
        guard generation.contains(expected), configuredNode == node else {
            throw CancellationError()
        }
        return try await self.request(request, through: node, kind: kind)
    }

    func unauthenticatedRequestReachedNode(_ request: URLRequest, expectedBody: Data) async -> Bool {
        guard core.isRunning, let localPort, let port = NWEndpoint.Port(rawValue: localPort) else { return false }
        let configuration = URLSessionConfiguration.ephemeral
        var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: .ipv4(.loopback), port: port))
        proxy.allowFailover = false
        configuration.proxyConfigurations = [proxy]
        configuration.timeoutIntervalForRequest = 2
        let unauthorized = URLSession(configuration: configuration)
        defer { unauthorized.invalidateAndCancel() }
        do {
            let (data, _) = try await unauthorized.data(for: request)
            return data == expectedBody
        } catch { return false }
    }

    func networkDidChange() {
        // A path change invalidates the existing endpoint and any in-flight URLSession tasks.
        // The next actual request can try again; this does not poll in the background.
        stop()
        failureUntil = nil
    }

    private func pathDidUpdate(_ signature: PathSignature) {
        let kind = !signature.ready ? "offline" : signature.wifi ? "wifi" : signature.cellular ? "cellular" : signature.wired ? "wired" : "other"
        guard let previous = lastPath else {
            lastPath = signature
            pathKind = kind
            return
        }
        guard previous != signature else { return }
        lastPath = signature
        pathChanges += 1
        pathKind = kind
        #if DEBUG
        DeveloperDiagnostics.shared.record(.init(
            operationID: DeveloperDiagnosticOperation.make("app-recovery-path"),
            module: .recovery, level: .warning,
            stage: "physical-path", outcome: "changed",
            detail: "path=\(kind) changes=\(pathChanges)"
        ))
        #endif
        networkDidChange()
    }

    func enteredBackground() { stop() }

    func stop() {
        if batchProbing {
            batchInvalidated = true
            return
        }
        idleTask?.cancel()
        idleTask = nil
        generation.advance()
        lifecycle = .stopping
        session?.invalidateAndCancel()
        session = nil
        localPort = nil
        if let error = core.stop() {
            diagnose(error.stage, NSError(domain: error.domain, code: error.code))
            failureUntil = Date().addingTimeInterval(failureCooldownSeconds)
            lifecycle = .failed
        }
        activeNode = nil
        configuredNode = nil
        if !core.hasService { lifecycle = .idle }
        #if DEBUG
        DeveloperDiagnostics.shared.record(.init(
            operationID: DeveloperDiagnosticOperation.make("app-recovery-stop"),
            module: .recovery,
            stage: "app-proxy-runtime", outcome: core.hasService ? "stop-failed" : "stopped",
            generation: String(generation.value),
            detail: "failureStage=\(failureStage) failureCode=\(failureCode)"
        ))
        #endif
    }

    /// Router-facing close confirmation. The internal stop path intentionally
    /// retains a failed SDK service so no second Core can be orphaned beside it.
    func stopRecovery() throws {
        stop()
        guard !core.hasService else { throw RecoveryRuntimeError.stopFailed }
    }

    private func startIfNeeded(_ node: RecoveryNode) throws -> (URLSession, Bool, Int?, Int?, Int?) {
        try OperationDeadline.checkCurrent()
        if let session {
            // A retained Swift wrapper does not prove the Go service is alive.
            // Detect an unexpected stop before reusing its authenticated port.
            if !core.isRunning {
                stop()
            } else {
                guard activeNode == node else { throw RecoveryRuntimeError.differentNodeInUse }
                return (session, false, nil, nil, nil)
            }
        }
        if let until = failureUntil, Date() < until { throw RecoveryRuntimeError.coolingDown }
        if core.hasService {
            if let error = core.stop() {
                diagnose(error.stage, NSError(domain: error.domain, code: error.code))
                failureUntil = Date().addingTimeInterval(failureCooldownSeconds)
                lifecycle = .failed
                throw RecoveryRuntimeError.unavailable
            }
        }
        lifecycle = .starting
        defer { if lifecycle == .starting { lifecycle = .failed } }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mihomo-recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let cache = base.appendingPathComponent("private-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        #if targetEnvironment(simulator)
        // Simulator file protection is not equivalent to a physical device.
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: base.path)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: cache.path)
        #else
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: base.path)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: cache.path)
        #endif
        let setupMS: Int
        try OperationDeadline.checkCurrent(minimum: OperationBudget.minimumRecoveryStart)
        do { setupMS = try core.setup(in: base, cache: cache) }
        catch let error as MihomoCoreFailure {
            try checkStartupCancellation()
            diagnose(error.stage, NSError(domain: error.domain, code: error.code))
            failureUntil = Date().addingTimeInterval(failureCooldownSeconds)
            lifecycle = .failed
            throw RecoveryRuntimeError.unavailable
        }
        try checkStartupCancellation()

        // A free-port probe cannot reserve the port until Mihomo binds it.
        // Retrying boundedly handles a competing local bind without a fixed port.
        for _ in 0..<3 {
            try OperationDeadline.checkCurrent()
            let localPort = Int(MihomoFreeLoopbackPort())
            guard (1...65_535).contains(localPort),
                  let networkPort = NWEndpoint.Port(rawValue: UInt16(localPort))
            else { throw RecoveryRuntimeError.invalidPort }
            let username = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let password = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let yaml = try node.appOnlyYAML(localPort: localPort, username: username, password: password)
            do {
                try OperationDeadline.checkCurrent(minimum: OperationBudget.minimumRecoveryStart)
                // SDK startup is synchronous and cannot be preempted by a Task
                // cancellation or deadline. Observe both on return and release ownership
                // through the normal stop path before publishing a session.
                let timings = try core.start(yaml: yaml)
                try checkStartupCancellation()
                let configuration = URLSessionConfiguration.ephemeral
                var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: .ipv4(.loopback), port: networkPort))
                proxy.applyCredential(username: username, password: password)
                proxy.allowFailover = false
                configuration.proxyConfigurations = [proxy]
                configuration.timeoutIntervalForRequest = requestTimeoutSeconds
                configuration.timeoutIntervalForResource = requestTimeoutSeconds
                let transport = URLSession(configuration: configuration)
                session = transport
                self.localPort = UInt16(localPort)
                activeNode = node
                failureUntil = nil
                lifecycle = .running
                return (transport, true, setupMS, timings.configMS, timings.serviceStartMS)
            } catch let error as MihomoCoreFailure {
                try checkStartupCancellation()
                diagnose(error.stage, NSError(domain: error.domain, code: error.code))
                // A bad node config cannot be repaired by selecting another port.
                // A failed close retains the service for a later bounded stop.
                if error.stage == "config" || core.hasService { break }
            }
        }
        try OperationDeadline.checkCurrent()
        failureUntil = Date().addingTimeInterval(failureCooldownSeconds)
        lifecycle = .failed
        throw RecoveryRuntimeError.unavailable
    }

    private func checkStartupCancellation() throws {
        do { try OperationDeadline.checkCurrent() }
        catch {
            if activeRequests == 0 { stop() }
            throw error
        }
    }

    private func finishRequest() {
        activeRequests -= 1
        guard activeRequests == 0, core.isRunning else { return }
        let capturedEpoch = generation.value
        let idleDelay = idleSeconds
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(idleDelay))
            await self?.stopIfIdle(epoch: capturedEpoch)
        }
    }

    private func diagnose(_ stage: String, _ error: NSError?) {
        // Only a phase and NSError class/code are exposed; no URL or credentials.
        failureStage = stage
        failureDomain = error?.domain ?? "none"
        failureCode = error?.code ?? 0
    }

    private func stopIfIdle(epoch candidate: UInt64) {
        if generation.contains(candidate) && activeRequests == 0 { stop() }
    }
}

/// A route can hold this value without sharing URLSession or SDK objects.
/// Once the owner stops, the captured generation is rejected before I/O.
private struct MihomoRecoveryTransport: NetworkTransport {
    let owner: MihomoAppRecoveryRuntime
    let node: RecoveryNode
    let generation: UInt64

    func data(for request: URLRequest, kind: NetworkRequestKind) async throws -> (Data, URLResponse) {
        try await owner.routedRequest(request, through: node, generation: generation, kind: kind)
    }
}
