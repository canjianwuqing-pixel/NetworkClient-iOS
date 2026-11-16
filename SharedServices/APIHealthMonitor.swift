import Foundation
import Network

/// Kept in memory only. The scope isolates diagnostic observations between
/// configurations; it is never an input to formal request routing.
struct APIHealthScope: Sendable, Equatable {
    let config: AppConfig

    static func == (lhs: Self, rhs: Self) -> Bool {
        AppConfig.orderedAPIBaseURLs(from: lhs.config) == AppConfig.orderedAPIBaseURLs(from: rhs.config)
            && lhs.config.safeUserAgent == rhs.config.safeUserAgent
    }
}

/// A value snapshot of the parts of NWPath that can change the route used by
/// URLSession. NWPath notifications are not themselves evidence of a new
/// network: iOS may deliver the same effective path more than once.
struct APIHealthNetworkPath: Sendable, Equatable {
    let status: NWPath.Status
    let usedInterfaceTypes: Set<NWInterface.InterfaceType>
    let usedInterfaceIdentifiers: Set<String>
    let gateways: Set<NWEndpoint>
    let localEndpoint: NWEndpoint?
    let isExpensive: Bool
    let isConstrained: Bool
    let supportsIPv4: Bool
    let supportsIPv6: Bool
    let supportsDNS: Bool
    let unsatisfiedReason: NWPath.UnsatisfiedReason?

    var isReachable: Bool { status == .satisfied }

    init(
        status: NWPath.Status,
        usedInterfaceTypes: Set<NWInterface.InterfaceType> = [],
        usedInterfaceIdentifiers: Set<String> = [],
        gateways: Set<NWEndpoint> = [],
        localEndpoint: NWEndpoint? = nil,
        isExpensive: Bool = false,
        isConstrained: Bool = false,
        supportsIPv4: Bool = true,
        supportsIPv6: Bool = true,
        supportsDNS: Bool = true,
        unsatisfiedReason: NWPath.UnsatisfiedReason? = nil
    ) {
        self.status = status
        self.usedInterfaceTypes = usedInterfaceTypes
        self.usedInterfaceIdentifiers = usedInterfaceIdentifiers
        self.gateways = gateways
        self.localEndpoint = localEndpoint
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
        self.supportsDNS = supportsDNS
        self.unsatisfiedReason = unsatisfiedReason
    }

    init(_ path: NWPath) {
        let types: Set<NWInterface.InterfaceType> = Set(
            [NWInterface.InterfaceType.wifi, .cellular, .wiredEthernet, .loopback, .other]
                .filter { path.usesInterfaceType($0) }
        )
        self.init(
            status: path.status,
            usedInterfaceTypes: types,
            usedInterfaceIdentifiers: Set(path.availableInterfaces
                .filter { types.contains($0.type) }
                .map { "\($0.type):\($0.name):\($0.index)" }),
            gateways: Set(path.gateways),
            localEndpoint: path.localEndpoint,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            supportsIPv4: path.supportsIPv4,
            supportsIPv6: path.supportsIPv6,
            supportsDNS: path.supportsDNS,
            unsatisfiedReason: path.status == .satisfied ? nil : path.unsatisfiedReason
        )
    }

    /// Only coarse, non-identifying values may enter ordinary diagnostics.
    var safeInterfaceCategory: String {
        guard isReachable else { return "unavailable" }
        if usedInterfaceTypes.contains(.wifi) && usedInterfaceTypes.contains(.cellular) { return "mixed" }
        if usedInterfaceTypes.contains(.wifi) { return "wifi" }
        if usedInterfaceTypes.contains(.cellular) { return "cellular" }
        if usedInterfaceTypes.contains(.wiredEthernet) { return "wired" }
        return "other"
    }

    func safeChangedFields(from previous: Self) -> String {
        var fields: [String] = []
        if status != previous.status || unsatisfiedReason != previous.unsatisfiedReason {
            fields.append("reachability")
        }
        if usedInterfaceTypes != previous.usedInterfaceTypes ||
            usedInterfaceIdentifiers != previous.usedInterfaceIdentifiers {
            fields.append("interface")
        }
        if gateways != previous.gateways || localEndpoint != previous.localEndpoint {
            fields.append("route")
        }
        if isExpensive != previous.isExpensive || isConstrained != previous.isConstrained {
            fields.append("cost")
        }
        if supportsIPv4 != previous.supportsIPv4 || supportsIPv6 != previous.supportsIPv6 ||
            supportsDNS != previous.supportsDNS {
            fields.append("capability")
        }
        return fields.joined(separator: ",")
    }
}

struct APIHealthPolicy: Sendable {
    let probeTimeout: TimeInterval
    let totalBudget: TimeInterval
    let healthyTTL: TimeInterval
    let retryCooldown: TimeInterval
    let networkDebounce: TimeInterval
    let maximumConcurrentProbes: Int

    static let standard = APIHealthPolicy(
        probeTimeout: NetworkTransportPolicy.requestTimeout(for: .apiProbe),
        totalBudget: 7,
        healthyTTL: 2 * 60,
        retryCooldown: 10,
        networkDebounce: 0.75,
        maximumConcurrentProbes: 2
    )
}

enum APIProbeCategory: String, Sendable {
    case healthy
    case dns
    case timeout
    case tls
    case transport
    case unauthorized
    case http
    case server
    case business
    case invalidContent
    case invalidPayload
    case cancelled
}

struct APIProbeDiagnostic: Sendable {
    let candidateIndex: Int
    let category: APIProbeCategory
    let latencyBucket: String
    let checkedAt: Date
}

/// A direct-only, best-effort observer. Its records are available to Debug
/// diagnostics only and never reorder, suppress, or gate business requests.
actor APIHealthMonitor {
    private enum ProbeTrigger: String {
        case configuration
        case foreground
        case initialPath
        case networkChanged
    }

    private enum InvalidationReason: String {
        case configurationChanged
        case networkChanged
        case networkUnavailable
    }

    private struct Record: Sendable {
        let category: APIProbeCategory
        let checkedAt: Date
        let latencyBucket: String
    }

    private struct Outcome: Sendable {
        let target: String
        let candidateIndex: Int
        let category: APIProbeCategory
        let checkedAt: Date
        let startedAt: Date
        let latencyBucket: String
    }

    private let transport: any NetworkTransport
    private let policy: APIHealthPolicy
    private let now: @Sendable () -> Date
    private let observeNetwork: Bool
    private var pathMonitor: NWPathMonitor?
    private var networkPath: APIHealthNetworkPath?
    private var networkReachable = true
    private var foreground = true
    private var scope: APIHealthScope?
    private var records: [String: Record] = [:]
    private var lastAttemptAt: Date?
    private var generation: UInt64 = 0
    private var probeRound: UInt64 = 0
    private var inFlight: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?

    init(
        transport: any NetworkTransport = URLSessionNetworkTransport(profile: .apiProbe),
        policy: APIHealthPolicy = .standard,
        now: @escaping @Sendable () -> Date = Date.init,
        observeNetwork: Bool = true
    ) {
        self.transport = transport
        self.policy = policy
        self.now = now
        self.observeNetwork = observeNetwork
    }

    /// Starts a bounded probe without awaiting its result. Authentication remains usable.
    func configure(_ config: AppConfig) {
        let newScope = APIHealthScope(config: config)
        if scope != newScope {
            invalidate(reason: .configurationChanged)
            lastAttemptAt = nil
            scope = newScope
        }
        startPathObservationIfNeeded()
        startProbeIfNeeded(reason: .configuration)
    }

    func setForeground(_ active: Bool) {
        foreground = active
        if active {
            startProbeIfNeeded(reason: .foreground)
        } else {
            generation &+= 1
            let interruptedProbe = inFlight != nil
            cancelInFlight()
            debounceTask?.cancel()
            debounceTask = nil
            if interruptedProbe { lastAttemptAt = nil }
        }
    }

    /// A user retry respects the existing in-flight task and failure cooldown.
    /// It never invalidates a healthy result or changes the API candidate set.
    func retryProbeIfNeeded() {
        startProbeIfNeeded(reason: .foreground)
    }

    /// Equivalent NWPath callbacks preserve valid health, even when they are
    /// delivered repeatedly while the radio and route remain unchanged.
    func networkDidChange(path: APIHealthNetworkPath) {
        if let previous = networkPath {
            guard previous != path else {
                #if DEBUG
                SafeLog.info("[APIHealth] pathEvent=equivalent link=\(path.safeInterfaceCategory)")
                #endif
                return
            }
            SafeLog.info(
                "[APIHealth] pathEvent=changed fields=\(path.safeChangedFields(from: previous)) "
                    + "link=\(path.safeInterfaceCategory)"
            )
        } else {
            SafeLog.info("[APIHealth] pathEvent=initial link=\(path.safeInterfaceCategory)")
            networkPath = path
            networkReachable = path.isReachable
            if !path.isReachable {
                invalidate(reason: .networkUnavailable)
                return
            }
            startProbeIfNeeded(reason: .initialPath)
            return
        }
        networkPath = path
        networkReachable = path.isReachable
        invalidate(reason: path.isReachable ? .networkChanged : .networkUnavailable)
        guard path.isReachable, foreground else { return }
        let elapsed = lastAttemptAt.map { now().timeIntervalSince($0) } ?? .infinity
        let delay = max(policy.networkDebounce, policy.retryCooldown - elapsed + 0.05)
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.startProbeIfNeeded(reason: .networkChanged)
        }
    }

    func diagnostics() -> [APIProbeDiagnostic] {
        guard let scope else { return [] }
        return AppConfig.orderedAPIBaseURLs(from: scope.config).enumerated().compactMap { index, target in
            guard let record = records[target] else { return nil }
            return APIProbeDiagnostic(
                candidateIndex: index + 1,
                category: record.category,
                latencyBucket: record.latencyBucket,
                checkedAt: record.checkedAt
            )
        }
    }

    func waitForCurrentProbe() async {
        let scheduled = debounceTask
        await scheduled?.value
        let task = inFlight
        await task?.value
    }

    private func startPathObservationIfNeeded() {
        guard observeNetwork, pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let snapshot = APIHealthNetworkPath(path)
            Task { await self?.networkDidChange(path: snapshot) }
        }
        pathMonitor = monitor
        monitor.start(queue: DispatchQueue(label: "NetworkClient.APIHealth.Path"))
    }

    private func startProbeIfNeeded(reason: ProbeTrigger) {
        guard foreground, networkReachable, inFlight == nil, let scope else { return }
        let targets = AppConfig.orderedAPIBaseURLs(from: scope.config)
        guard !targets.isEmpty else { return }
        let current = now()
        if records.values.contains(where: {
            $0.category == .healthy && current.timeIntervalSince($0.checkedAt) < policy.healthyTTL
        }) { return }
        if let lastAttemptAt, current.timeIntervalSince(lastAttemptAt) < policy.retryCooldown { return }
        lastAttemptAt = current
        probeRound &+= 1
        let round = probeRound
        SafeLog.info(
            "[APIHealth] probeStart round=\(round) reason=\(reason.rawValue) "
                + "candidates=\(targets.count) link=\(networkPath?.safeInterfaceCategory ?? "unknown")"
        )
        #if DEBUG
        DeveloperDiagnostics.shared.record(.init(
            operationID: "health-\(round)",
            module: .apiHealth,
            stage: "probe-round",
            outcome: "started",
            timeoutMilliseconds: Int((policy.totalBudget * 1_000).rounded()),
            generation: String(generation),
            detail: "reason=\(reason.rawValue) candidates=\(targets.count) link=\(networkPath?.safeInterfaceCategory ?? "unknown")"
        ))
        #endif
        let expectedGeneration = generation
        inFlight = Task(priority: .background) { [weak self] in
            guard let self else { return }
            await self.runProbes(scope: scope, targets: targets, generation: expectedGeneration, round: round)
        }
    }

    private func runProbes(
        scope expectedScope: APIHealthScope, targets: [String],
        generation expectedGeneration: UInt64, round: UInt64
    ) async {
        let transport = self.transport
        let policy = self.policy
        let now = self.now
        await withTaskGroup(of: Outcome?.self) { group in
            var nextIndex = 0
            var completed = 0
            let limit = min(max(1, policy.maximumConcurrentProbes), targets.count)
            func addCandidate() {
                let index = nextIndex
                nextIndex += 1
                group.addTask {
                    await Self.probe(
                        target: targets[index], index: index + 1,
                        config: expectedScope.config, transport: transport,
                        timeout: policy.probeTimeout, now: now
                    )
                }
            }
            for _ in 0..<limit { addCandidate() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, policy.totalBudget) * 1_000_000_000))
                return nil
            }
            while let next = await group.next() {
                guard !Task.isCancelled, let outcome = next else { break }
                completed += 1
                apply(outcome, scope: expectedScope, generation: expectedGeneration, round: round)
                if nextIndex < targets.count { addCandidate() }
                if completed == targets.count { break }
            }
            group.cancelAll()
        }
        if generation == expectedGeneration, scope == expectedScope {
            inFlight = nil
        }
    }

    private func apply(
        _ outcome: Outcome, scope expectedScope: APIHealthScope,
        generation expectedGeneration: UInt64, round: UInt64
    ) {
        guard generation == expectedGeneration, scope == expectedScope else {
            #if DEBUG
            DeveloperDiagnostics.shared.record(.init(
                operationID: "health-\(round)", module: .apiHealth, level: .warning,
                stage: "probe-result", outcome: "superseded",
                generation: String(expectedGeneration), superseded: true,
                detail: "candidateIndex=\(outcome.candidateIndex)"
            ))
            #endif
            return
        }
        records[outcome.target] = Record(
            category: outcome.category,
            checkedAt: outcome.checkedAt,
            latencyBucket: outcome.latencyBucket
        )
        SafeLog.info(
            "[APIHealth] candidateIndex=\(outcome.candidateIndex) category=\(outcome.category.rawValue) "
                + "latency=\(outcome.latencyBucket) round=\(round)"
        )
        #if DEBUG
        DeveloperDiagnostics.shared.record(.init(
            operationID: "health-\(round)",
            module: .apiHealth,
            level: outcome.category == .healthy ? .success : (outcome.category == .cancelled ? .warning : .error),
            stage: "probe-result",
            outcome: outcome.category.rawValue,
            elapsedMilliseconds: Int(outcome.checkedAt.timeIntervalSince(outcome.startedAt) * 1_000),
            timeoutMilliseconds: Int((policy.probeTimeout * 1_000).rounded()),
            attempt: outcome.candidateIndex,
            generation: String(expectedGeneration),
            cancelled: outcome.category == .cancelled,
            detail: "latency=\(outcome.latencyBucket)"
        ))
        #endif
    }

    private func invalidate(reason: InvalidationReason) {
        SafeLog.info("[APIHealth] cacheInvalidated reason=\(reason.rawValue)")
        #if DEBUG
        DeveloperDiagnostics.shared.record(.init(
            operationID: "health-\(probeRound)", module: .apiHealth, level: .warning,
            stage: "cache-invalidated", outcome: reason.rawValue,
            generation: String(generation), cancelled: inFlight != nil
        ))
        #endif
        generation &+= 1
        cancelInFlight()
        debounceTask?.cancel()
        debounceTask = nil
        records.removeAll()
    }

    private func cancelInFlight() {
        inFlight?.cancel()
        inFlight = nil
    }

    private static func probe(
        target: String,
        index: Int,
        config: AppConfig,
        transport: any NetworkTransport,
        timeout: TimeInterval,
        now: @Sendable () -> Date
    ) async -> Outcome {
        let startedAt = now()
        let clock = ContinuousClock()
        let start = clock.now
        let category: APIProbeCategory
        do {
            try Task.checkCancellation()
            let url = try AppConfig.apiURL(baseURL: target, relativePath: V2BoardAPIClient.registrationConfigPath)
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = timeout
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(config.safeUserAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await transport.data(for: request, kind: .apiProbe)
            try Task.checkCancellation()
            category = classify(data: data, response: response)
        } catch is CancellationError {
            category = .cancelled
        } catch let error as URLError {
            category = classify(error)
        } catch {
            category = .transport
        }
        let elapsed = start.duration(to: clock.now)
        let bucket = elapsed < .milliseconds(250) ? "<250ms" : elapsed < .seconds(1) ? "250ms-1s" : ">=1s"
        return Outcome(
            target: target, candidateIndex: index, category: category,
            checkedAt: now(), startedAt: startedAt, latencyBucket: bucket
        )
    }

    private static func classify(data: Data, response: URLResponse) -> APIProbeCategory {
        guard let response = response as? HTTPURLResponse else { return .invalidContent }
        switch response.statusCode {
        case 401, 403: return .unauthorized
        case 500...599: return .server
        case 200: break
        default: return .http
        }
        let contentType = response.value(forHTTPHeaderField: "Content-Type")
        guard contentType?.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "application/json" else {
            return .invalidContent
        }
        do {
            let root = try V2BoardAPIErrorParser.decodeResponse(
                data: data, statusCode: response.statusCode,
                contentType: contentType, context: .login
            )
            guard let payload = root["data"] as? [String: Any],
                  ["is_email_verify", "is_invite_force", "is_recaptcha"]
                    .contains(where: { key in
                        guard let value = payload[key] else { return false }
                        if value is NSNumber { return true }
                        guard let text = value as? String else { return false }
                        return ["0", "1", "true", "false"].contains(text.lowercased())
                    }) else { return .invalidPayload }
            return .healthy
        } catch let error as NetworkClientError {
            if case .backendBusinessError = error { return .business }
            return .invalidPayload
        } catch {
            return .invalidPayload
        }
    }

    private static func classify(_ error: URLError) -> APIProbeCategory {
        switch error.code {
        case .cancelled: .cancelled
        case .cannotFindHost, .dnsLookupFailed: .dns
        case .timedOut: .timeout
        case .secureConnectionFailed, .serverCertificateHasBadDate,
             .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected: .tls
        default: .transport
        }
    }
}
