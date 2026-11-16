#if DEBUG
import Foundation

actor DeveloperDiagnostics {
    static let shared = DeveloperDiagnostics()
    static let retentionInterval: TimeInterval = 3 * 24 * 60 * 60
    static let maximumBytes = 5 * 1024 * 1024
    static let maximumVisibleEvents = 2_000
    private static let applicationMaximumBytes = 4 * 1024 * 1024

    nonisolated static var defaultDirectoryURL: URL {
        let root = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("NetworkClient", isDirectory: true)
            .appendingPathComponent("DeveloperDiagnostics", isDirectory: true)
    }

    private let directoryURL: URL
    private let maximumBytes: Int
    private let retentionInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var events: [DeveloperDiagnosticEvent] = []
    private var loaded = false
    private var continuations: [UUID: AsyncStream<[DeveloperDiagnosticEvent]>.Continuation] = [:]

    init(
        directoryURL: URL = DeveloperDiagnostics.defaultDirectoryURL,
        maximumBytes: Int = DeveloperDiagnostics.applicationMaximumBytes,
        retentionInterval: TimeInterval = DeveloperDiagnostics.retentionInterval,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directoryURL = directoryURL
        self.maximumBytes = max(1_024, maximumBytes)
        self.retentionInterval = max(1, retentionInterval)
        self.now = now
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    nonisolated func record(_ event: DeveloperDiagnosticEvent) {
        Task(priority: .utility) { await self.store(event) }
    }

    func recordAndWait(_ event: DeveloperDiagnosticEvent) async {
        await store(event)
    }

    func currentEvents() async -> [DeveloperDiagnosticEvent] {
        await loadIfNeeded()
        return mergedEvents()
    }

    func snapshots() async -> AsyncStream<[DeveloperDiagnosticEvent]> {
        await loadIfNeeded()
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.yield(mergedEvents())
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeContinuation(id) }
            }
        }
    }

    func exportText() async -> String {
        await loadIfNeeded()
        return mergedEvents().map(Self.render).joined(separator: "\n")
    }

    func exportFile() async throws -> URL {
        await loadIfNeeded()
        try prepareDirectory()
        let url = directoryURL.appendingPathComponent("networkclient-diagnostics.txt")
        try (mergedEvents().map(Self.render).joined(separator: "\n") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(Self.protectedFileAttributes, ofItemAtPath: url.path)
        return url
    }

    func clear() async {
        await loadIfNeeded()
        try? FileManager.default.removeItem(at: eventsURL)
        try? FileManager.default.removeItem(at: directoryURL.appendingPathComponent("networkclient-diagnostics.txt"))
        events.removeAll()
        yieldSnapshot()
    }

    func storedByteCount() async -> Int64 {
        await loadIfNeeded()
        let values = try? FileManager.default.attributesOfItem(atPath: eventsURL.path)
        return (values?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private var eventsURL: URL { directoryURL.appendingPathComponent("events.jsonl") }

    private func store(_ rawEvent: DeveloperDiagnosticEvent) async {
        await loadIfNeeded()
        let event = Self.sanitized(rawEvent)
        let cutoff = now().addingTimeInterval(-retentionInterval)
        events.removeAll { $0.timestamp < cutoff }
        events.append(event)
        if events.count > Self.maximumVisibleEvents {
            events.removeFirst(events.count - Self.maximumVisibleEvents)
        }
        do {
            try persistBounded()
        } catch {
            SafeLog.warning("[DeveloperDiagnostics] write failed category=local_io")
        }
        yieldSnapshot()
    }

    private func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: eventsURL), !data.isEmpty else { return }
        let cutoff = now().addingTimeInterval(-retentionInterval)
        events = data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(DeveloperDiagnosticEvent.self, from: Data(line))
        }
        .filter { $0.timestamp >= cutoff }
        .suffix(Self.maximumVisibleEvents)
        .map { $0 }
        try? persistBounded()
    }

    private func persistBounded() throws {
        try prepareDirectory()
        var lines = try events.map { try encoder.encode($0) }
        var total = lines.reduce(0) { $0 + $1.count + 1 }
        while total > maximumBytes, lines.count > 1 {
            total -= lines.removeFirst().count + 1
            events.removeFirst()
        }
        var output = Data()
        output.reserveCapacity(total)
        for line in lines {
            output.append(line)
            output.append(0x0A)
        }
        try output.write(to: eventsURL, options: .atomic)
        try? FileManager.default.setAttributes(Self.protectedFileAttributes, ofItemAtPath: eventsURL.path)
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [
                .posixPermissions: 0o700,
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
            ]
        )
    }

    private func removeContinuation(_ id: UUID) { continuations[id] = nil }

    private func yieldSnapshot() {
        let snapshot = mergedEvents()
        continuations.values.forEach { $0.yield(snapshot) }
    }

    private func mergedEvents() -> [DeveloperDiagnosticEvent] {
        Array(events
            .sorted { $0.timestamp < $1.timestamp }
            .suffix(Self.maximumVisibleEvents))
    }

    private static func sanitized(_ event: DeveloperDiagnosticEvent) -> DeveloperDiagnosticEvent {
        DeveloperDiagnosticEvent(
            id: event.id,
            timestamp: event.timestamp,
            operationID: safe(event.operationID, maximum: 80),
            module: event.module,
            level: event.level,
            stage: safe(event.stage, maximum: 100),
            outcome: safe(event.outcome, maximum: 100),
            elapsedMilliseconds: event.elapsedMilliseconds,
            timeoutMilliseconds: event.timeoutMilliseconds,
            httpStatus: event.httpStatus,
            urlErrorCode: event.urlErrorCode,
            attempt: event.attempt,
            route: event.route.map { safe($0, maximum: 80) },
            generation: event.generation.map { safe($0, maximum: 80) },
            cancelled: event.cancelled,
            superseded: event.superseded,
            detail: event.detail.map { safe($0, maximum: 300) }
        )
    }

    private static func safe(_ value: String, maximum: Int) -> String {
        String(UserLogSanitizer.sanitize(value).prefix(maximum))
    }

    private static func render(_ event: DeveloperDiagnosticEvent) -> String {
        let timestamp = ISO8601DateFormatter().string(from: event.timestamp)
        var fields = [
            timestamp,
            "op=\(event.operationID)",
            "module=\(event.module.rawValue)",
            "level=\(event.level.rawValue)",
            "stage=\(event.stage)",
            "outcome=\(event.outcome)"
        ]
        if let value = event.elapsedMilliseconds { fields.append("elapsedMS=\(value)") }
        if let value = event.timeoutMilliseconds { fields.append("timeoutMS=\(value)") }
        if let value = event.httpStatus { fields.append("http=\(value)") }
        if let value = event.urlErrorCode { fields.append("urlError=\(value)") }
        if let value = event.attempt { fields.append("attempt=\(value)") }
        if let value = event.route { fields.append("route=\(value)") }
        if let value = event.generation { fields.append("generation=\(value)") }
        if event.cancelled { fields.append("cancelled=true") }
        if event.superseded { fields.append("superseded=true") }
        if let value = event.detail { fields.append("detail=\(value)") }
        return fields.joined(separator: " ")
    }

    private static var protectedFileAttributes: [FileAttributeKey: Any] {
        [.posixPermissions: 0o600, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    }
}

enum DeveloperRecoveryAcceptanceKind: String, Sendable {
    case shadowsocks = "ss"
    case vmess
}

/// One-shot Debug-only acceptance path. The caller must explicitly launch the
/// process with NETWORKCLIENT_RECOVERY_ACCEPTANCE=ss or vmess. Nothing is
/// persisted, normal transports are not modified, and Release never compiles it.
enum DeveloperRecoveryAcceptance {
    private static let environmentKey = "NETWORKCLIENT_RECOVERY_ACCEPTANCE"
    private enum NegativeControlError: Error { case unexpectedSuccess }

    static func requestedKind(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DeveloperRecoveryAcceptanceKind? {
        guard let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else { return nil }
        return DeveloperRecoveryAcceptanceKind(rawValue: raw)
    }

    static func recordBlocked(kind: DeveloperRecoveryAcceptanceKind, reason: String) async {
        await DeveloperDiagnostics.shared.recordAndWait(.init(
            operationID: operationID(for: kind), module: .recovery, level: .warning,
            stage: "acceptance", outcome: "blocked", detail: "reason=\(reason)"
        ))
    }

    static func run(
        kind: DeveloperRecoveryAcceptanceKind,
        config: AppConfig,
        router: APIRecoveryRouter,
        runtime: MihomoAppRecoveryRuntime
    ) async {
        let operationID = operationID(for: kind)
        let started = ContinuousClock.now
        let endpoints = BuiltInProxyParser.parseMany(config.builtInProxy)
        let compatible = endpoints.filter { endpoint in
            switch (kind, endpoint.kind) {
            case (.shadowsocks, .shadowsocks), (.vmess, .vmess): true
            default: false
            }
        }
        await record(
            operationID: operationID, stage: "candidate-audit",
            outcome: compatible.isEmpty ? "missing" : "compatible",
            level: compatible.isEmpty ? .warning : .success,
            detail: "configured=\(config.builtInProxy.count) parsed=\(endpoints.count) matching=\(compatible.count) protocol=\(kind.rawValue)"
        )
        guard let endpoint = compatible.first else {
            await finish(operationID, started: started, outcome: "not-tested-no-candidate", level: .warning)
            return
        }

        let targets = AppConfig.orderedAPIBaseURLs(from: config)
        guard !targets.isEmpty else {
            await finish(operationID, started: started, outcome: "blocked-no-api-target", level: .error)
            return
        }

        let direct = URLSessionNetworkTransport(profile: .api)
        defer { direct.finishTasksAndInvalidate() }
        var baselineTarget: String?
        do {
            let baseline = try await firstValidTarget(targets, config: config, transport: direct)
            baselineTarget = baseline.target
            await record(
                operationID: operationID, stage: "direct-baseline", outcome: "valid-v2board",
                level: .success, httpStatus: baseline.status,
                detail: "targetIndex=\(baseline.index)"
            )

            let result: Int = try await router.safeRetry(
                plan: APIRecoveryPlan(targets: targets, builtInProxy: [endpoint.normalizedValue])
            ) { route in
                switch route.path {
                case .normal:
                    await record(
                        operationID: operationID, stage: "direct-fault", outcome: "injected",
                        level: .warning, attempt: route.targetIndex + 1, route: "direct",
                        detail: "scope=acceptance-only category=offline"
                    )
                    throw NetworkClientError.fromTransport(URLError(.notConnectedToInternet))
                case let .builtIn(_, protocolName):
                    guard protocolName == kind.rawValue, let transport = route.transport else {
                        throw NetworkClientError.transport("恢复通道不可用")
                    }
                    do {
                        let delay = try await runtime.validateActiveRecoveryOutbound()
                        await record(
                            operationID: operationID, stage: "core-urltest",
                            outcome: "reachable", level: .success,
                            detail: "namedOutbound=true delayBucket=\(delayBucket(delay))"
                        )
                    } catch {
                        await record(
                            operationID: operationID, stage: "core-urltest",
                            outcome: "failed", level: .warning,
                            detail: "category=\(safeCategory(error))"
                        )
                    }
                    let status = try await requestRegistrationConfig(
                        target: route.target, config: config, transport: transport
                    )
                    await record(
                        operationID: operationID, stage: "proxied-api", outcome: "valid-v2board",
                        level: .success, httpStatus: status, attempt: route.targetIndex + 1,
                        route: "built-in-\(protocolName)", detail: "socks5=true failover=false"
                    )
                    return status
                }
            }
            guard (200...299).contains(result) else {
                throw NetworkClientError.responseInvalid("无效的 API 响应")
            }

            let stopped = await runtime.snapshot()
            guard !stopped.running, stopped.loopbackPort == nil, stopped.activeRequests == 0 else {
                await finish(operationID, started: started, outcome: "failed-runtime-residual", level: .error)
                return
            }
            await record(
                operationID: operationID, stage: "runtime-cleanup", outcome: "released",
                level: .success, generation: nil,
                detail: "running=false listener=false activeRequests=0"
            )

            try await runNegativeControl(
                kind: kind, target: baseline.target, config: config,
                router: router, runtime: runtime, operationID: operationID
            )

            let postStatus = try await requestRegistrationConfig(
                target: baseline.target, config: config, transport: direct
            )
            await record(
                operationID: operationID, stage: "post-recovery-direct",
                outcome: "valid-v2board", level: .success, httpStatus: postStatus,
                detail: "route=direct"
            )
            await finish(operationID, started: started, outcome: "passed", level: .success)
        } catch is CancellationError {
            await runFailureNegativeControl(
                kind: kind, target: baselineTarget, config: config,
                router: router, runtime: runtime, operationID: operationID
            )
            await finish(operationID, started: started, outcome: "cancelled", level: .warning, cancelled: true)
        } catch let error as NetworkClientError {
            await runFailureNegativeControl(
                kind: kind, target: baselineTarget, config: config,
                router: router, runtime: runtime, operationID: operationID
            )
            await finish(
                operationID, started: started, outcome: "failed", level: .error,
                detail: "category=\(error.logCategory)"
            )
        } catch {
            await runFailureNegativeControl(
                kind: kind, target: baselineTarget, config: config,
                router: router, runtime: runtime, operationID: operationID
            )
            await finish(
                operationID, started: started, outcome: "failed", level: .error,
                detail: "category=\(safeCategory(error))"
            )
        }
    }

    private static func runFailureNegativeControl(
        kind: DeveloperRecoveryAcceptanceKind,
        target: String?,
        config: AppConfig,
        router: APIRecoveryRouter,
        runtime: MihomoAppRecoveryRuntime,
        operationID: String
    ) async {
        guard let target else { return }
        do {
            try await runNegativeControl(
                kind: kind, target: target, config: config,
                router: router, runtime: runtime, operationID: operationID
            )
        } catch {
            await record(
                operationID: operationID, stage: "negative-control",
                outcome: "verification-failed", level: .error,
                detail: "category=\(safeCategory(error))"
            )
        }
    }

    private static func runNegativeControl(
        kind: DeveloperRecoveryAcceptanceKind,
        target: String,
        config: AppConfig,
        router: APIRecoveryRouter,
        runtime: MihomoAppRecoveryRuntime,
        operationID: String
    ) async throws {
        let invalidShare = try invalidControlShare(kind)
        do {
            let _: Int = try await router.safeRetry(
                plan: APIRecoveryPlan(targets: [target], builtInProxy: [invalidShare])
            ) { route in
                switch route.path {
                case .normal:
                    throw NetworkClientError.fromTransport(URLError(.notConnectedToInternet))
                case .builtIn:
                    guard let transport = route.transport else {
                        throw NetworkClientError.transport("恢复通道不可用")
                    }
                    return try await requestRegistrationConfig(
                        target: route.target, config: config, transport: transport
                    )
                }
            }
            await record(
                operationID: operationID, stage: "negative-control",
                outcome: "unexpected-success", level: .error,
                detail: "directFailover=false"
            )
            throw NegativeControlError.unexpectedSuccess
        } catch NegativeControlError.unexpectedSuccess {
            throw NetworkClientError.responseInvalid("负向恢复测试意外成功")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let stopped = await runtime.snapshot()
            guard !stopped.running, stopped.loopbackPort == nil, stopped.activeRequests == 0 else {
                throw NetworkClientError.serviceUnavailable("恢复资源未释放", retryable: false)
            }
            await record(
                operationID: operationID, stage: "negative-control",
                outcome: "failed-closed", level: .success,
                detail: "directFailover=false runtimeReleased=true"
            )
        }
    }

    private static func invalidControlShare(_ kind: DeveloperRecoveryAcceptanceKind) throws -> String {
        switch kind {
        case .shadowsocks:
            let credentials = Data("aes-256-gcm:negative-control".utf8).base64EncodedString()
            return "ss://\(credentials)@127.0.0.1:9"
        case .vmess:
            let object: [String: Any] = [
                "v": "2", "add": "127.0.0.1", "port": "9",
                "id": "11111111-1111-4111-8111-111111111111", "aid": "0",
                "scy": "auto", "net": "tcp", "tls": "",
            ]
            return "vmess://" + (try JSONSerialization.data(withJSONObject: object)).base64EncodedString()
        }
    }

    private static func firstValidTarget(
        _ targets: [String], config: AppConfig, transport: any NetworkTransport
    ) async throws -> (target: String, index: Int, status: Int) {
        var lastError: Error = NetworkClientError.transport("网络连接失败，请稍后重试")
        for (index, target) in targets.enumerated() {
            do {
                return (target, index, try await requestRegistrationConfig(
                    target: target, config: config, transport: transport
                ))
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func requestRegistrationConfig(
        target: String, config: AppConfig, transport: any NetworkTransport
    ) async throws -> Int {
        let url = try AppConfig.apiURL(
            baseURL: target, relativePath: V2BoardAPIClient.registrationConfigPath
        )
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 7
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(config.safeUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport.data(for: request, kind: .apiRead)
        guard let http = response as? HTTPURLResponse else {
            throw NetworkClientError.responseInvalid("无效的 API 响应")
        }
        let root = try V2BoardAPIErrorParser.decodeResponse(
            data: data, statusCode: http.statusCode,
            contentType: http.value(forHTTPHeaderField: "Content-Type"), context: .login
        )
        guard root["data"] as? [String: Any] != nil else {
            throw NetworkClientError.responseInvalid("无效的 API 响应")
        }
        return http.statusCode
    }

    private static func operationID(for kind: DeveloperRecoveryAcceptanceKind) -> String {
        DeveloperDiagnosticOperation.make("real-recovery-\(kind.rawValue)")
    }

    private static func record(
        operationID: String, stage: String, outcome: String,
        level: DeveloperDiagnosticLevel, httpStatus: Int? = nil,
        attempt: Int? = nil, route: String? = nil, generation: String? = nil,
        detail: String? = nil
    ) async {
        await DeveloperDiagnostics.shared.recordAndWait(.init(
            operationID: operationID, module: .recovery, level: level,
            stage: stage, outcome: outcome, httpStatus: httpStatus,
            attempt: attempt, route: route, generation: generation, detail: detail
        ))
    }

    private static func finish(
        _ operationID: String, started: ContinuousClock.Instant,
        outcome: String, level: DeveloperDiagnosticLevel,
        cancelled: Bool = false, detail: String? = nil
    ) async {
        await DeveloperDiagnostics.shared.recordAndWait(.init(
            operationID: operationID, module: .recovery, level: level,
            stage: "acceptance", outcome: outcome,
            elapsedMilliseconds: milliseconds(started.duration(to: .now)),
            cancelled: cancelled, detail: detail
        ))
    }

    private static func safeCategory(_ error: Error) -> String {
        if let urlError = error as? URLError { return "url-\(urlError.code.rawValue)" }
        return String(describing: type(of: error))
    }

    private static func delayBucket(_ milliseconds: Int) -> String {
        switch milliseconds {
        case ..<250: "under-250ms"
        case 250..<500: "250-499ms"
        case 500..<1_000: "500-999ms"
        default: "1000ms-or-more"
        }
    }

    private static func milliseconds(_ duration: ContinuousClock.Duration) -> Int {
        let value = duration.components
        return Int(value.seconds * 1_000 + value.attoseconds / 1_000_000_000_000_000)
    }
}
#endif
