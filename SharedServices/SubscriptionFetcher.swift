import Foundation

enum SubscriptionFetchError: Error, Equatable, Sendable {
    case missingSubscriptionURL
    case invalidSubscriptionURL
    case invalidUserAgent
    case downloadFailed
    case invalidHTTPResponse(statusCode: Int?)
    case invalidEncoding

    var userFacingKey: String {
        switch self {
        case .missingSubscriptionURL: "nodes.error.missing_subscription"
        case .invalidSubscriptionURL, .invalidUserAgent: "nodes.error.invalid_subscription"
        case .downloadFailed, .invalidHTTPResponse: "nodes.error.download_failed"
        case .invalidEncoding: "nodes.error.invalid_format"
        }
    }
}

protocol SubscriptionFetching: Sendable {
    func fetchSubscription(from rawURL: String, userAgent: String, builtInProxy: [String]) async throws -> String
}

actor SubscriptionFetcher: SubscriptionFetching {
    private static let maximumAttemptCount = 2
    private static let retryDelayNanoseconds: UInt64 = 400_000_000

    private let transport: any NetworkTransport
    private let physicalNetworkTransport: (any NetworkTransport)?
    private let isSystemVPNActive: @Sendable () async -> Bool
    private let recoveryRouter: APIRecoveryRouter?

    init(
        transport: any NetworkTransport = URLSessionNetworkTransport(profile: .subscription),
        physicalNetworkTransport: (any NetworkTransport)? = nil,
        isSystemVPNActive: @escaping @Sendable () async -> Bool = { false },
        recoveryRouter: APIRecoveryRouter? = nil
    ) {
        self.transport = transport
        self.physicalNetworkTransport = physicalNetworkTransport
        self.isSystemVPNActive = isSystemVPNActive
        self.recoveryRouter = recoveryRouter
    }

    func fetchSubscription(
        from rawURL: String, userAgent: String, builtInProxy: [String] = []
    ) async throws -> String {
        let deadline = recoveryRouter?.operationDeadline(OperationBudget.subscription)
            ?? OperationDeadline(after: OperationBudget.subscription)
        return try await OperationDeadline.$current.withValue(deadline) {
            try await self.fetchWithinDeadline(from: rawURL, userAgent: userAgent, builtInProxy: builtInProxy)
        }
    }

    private func fetchWithinDeadline(
        from rawURL: String, userAgent: String, builtInProxy: [String]
    ) async throws -> String {
        try OperationDeadline.checkCurrent()
        #if DEBUG
        let diagnosticOperation: String? = DeveloperDiagnosticOperation.make("subscription")
        DeveloperDiagnostics.shared.record(.init(
            operationID: diagnosticOperation!, module: .subscription,
            stage: "yaml-download", outcome: "started",
            timeoutMilliseconds: Int(NetworkTransportPolicy.requestTimeout(for: .subscription) * 1_000),
            detail: "recoveryCandidates=\(builtInProxy.count)"
        ))
        #else
        let diagnosticOperation: String? = nil
        #endif
        let url = try Self.requestURL(from: rawURL)
        let normalizedUserAgent = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUserAgent.isEmpty else { throw SubscriptionFetchError.invalidUserAgent }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = NetworkTransportPolicy.requestTimeout(for: .subscription)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(normalizedUserAgent, forHTTPHeaderField: "User-Agent")
        let systemVPNWasActive = await isSystemVPNActive()

        do {
            let content = try await fetchDirect(
                request,
                maximumAttempts: Self.maximumAttemptCount,
                diagnosticOperation: diagnosticOperation
            )
            #if DEBUG
            DeveloperDiagnostics.shared.record(.init(
                operationID: diagnosticOperation!, module: .subscription, level: .success,
                stage: "yaml-download", outcome: "direct-success", route: "direct"
            ))
            #endif
            return content
        } catch let error as SubscriptionFetchError {
            try OperationDeadline.checkCurrent()
            #if DEBUG
            DeveloperDiagnostics.shared.record(.init(
                operationID: diagnosticOperation!, module: .subscription, level: .error,
                stage: "yaml-download", outcome: String(describing: error), route: "direct"
            ))
            #endif
            guard error == .downloadFailed else { throw error }
            let systemVPNCurrentlyActive = await isSystemVPNActive()
            let systemVPNIsActive = systemVPNWasActive || systemVPNCurrentlyActive
            if systemVPNIsActive, let physicalNetworkTransport {
                do {
                    return try await fetchThroughPhysicalNetwork(
                        request, transport: physicalNetworkTransport,
                        diagnosticOperation: diagnosticOperation
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch let fallbackError as SubscriptionFetchError {
                    guard fallbackError == .downloadFailed else { throw fallbackError }
                }
                // A live system VPN already owns the formal Core. A failed
                // physical request must not start the App-only recovery Core.
                throw error
            }
            let systemVPNActiveBeforeRecovery = await isSystemVPNActive()
            guard !systemVPNIsActive, !systemVPNActiveBeforeRecovery else { throw error }
            guard let recoveryRouter,
                  !BuiltInProxyParser.parseMany(builtInProxy).isEmpty else { throw error }
            #if DEBUG
            DeveloperDiagnostics.shared.record(.init(
                operationID: diagnosticOperation!, module: .subscription, level: .warning,
                stage: "yaml-download", outcome: "direct-failed", route: "direct"
            ))
            #endif
            let content = try await fetchThroughRecovery(
                request, url: url, builtInProxy: builtInProxy, router: recoveryRouter
            )
            #if DEBUG
            DeveloperDiagnostics.shared.record(.init(
                operationID: diagnosticOperation!, module: .subscription, level: .success,
                stage: "yaml-download", outcome: "recovery-success", route: "built-in"
            ))
            #endif
            return content
        }
    }

    private func fetchDirect(
        _ request: URLRequest,
        maximumAttempts: Int,
        diagnosticOperation: String?
    ) async throws -> String {
        for attempt in 1...maximumAttempts {
            try OperationDeadline.checkCurrent()
            let started = Date()
            #if DEBUG || ROUTE_VALIDATION
            SafeLog.info("[SubscriptionStage] attempt=\(attempt) stage=request-start")
            #endif
            #if DEBUG
            if let diagnosticOperation { DeveloperDiagnostics.shared.record(.init(
                operationID: diagnosticOperation, module: .subscription,
                stage: "direct-attempt", outcome: "started", attempt: attempt,
                route: "direct"
            )) }
            #endif
            do {
                let (data, response) = try await OperationDeadline.request(kind: .subscription) {
                    try await self.transport.data(for: request, kind: .subscription)
                }
                try OperationDeadline.checkCurrent()
                guard let httpResponse = response as? HTTPURLResponse else {
                    #if DEBUG || ROUTE_VALIDATION
                    SafeLog.warning("[SubscriptionStage] attempt=\(attempt) stage=response-invalid elapsedMS=\(Int(Date().timeIntervalSince(started) * 1_000))")
                    #endif
                    throw SubscriptionFetchError.invalidHTTPResponse(statusCode: nil)
                }
                #if DEBUG || ROUTE_VALIDATION
                SafeLog.info("[SubscriptionStage] attempt=\(attempt) stage=http-response status=\(httpResponse.statusCode) elapsedMS=\(Int(Date().timeIntervalSince(started) * 1_000))")
                #endif
                if Self.isRetryableHTTPStatus(httpResponse.statusCode),
                   attempt < maximumAttempts {
                    Self.logRetry(attempt: attempt, category: "http_\(httpResponse.statusCode)")
                    try await Self.waitBeforeRetry()
                    continue
                }
                guard (200...299).contains(httpResponse.statusCode) else {
                    #if DEBUG
                    if let diagnosticOperation { DeveloperDiagnostics.shared.record(.init(
                        operationID: diagnosticOperation, module: .subscription, level: .error,
                        stage: "direct-attempt", outcome: "http-error",
                        elapsedMilliseconds: Int(Date().timeIntervalSince(started) * 1_000),
                        httpStatus: httpResponse.statusCode, attempt: attempt, route: "direct"
                    )) }
                    #endif
                    throw SubscriptionFetchError.invalidHTTPResponse(
                        statusCode: httpResponse.statusCode
                    )
                }
                guard let content = String(data: data, encoding: .utf8) else {
                    throw SubscriptionFetchError.invalidEncoding
                }
                #if DEBUG
                if let diagnosticOperation { DeveloperDiagnostics.shared.record(.init(
                    operationID: diagnosticOperation, module: .subscription, level: .success,
                    stage: "direct-attempt", outcome: "decoded",
                    elapsedMilliseconds: Int(Date().timeIntervalSince(started) * 1_000),
                    httpStatus: httpResponse.statusCode, attempt: attempt, route: "direct"
                )) }
                #endif
                return content
            } catch is CancellationError {
                #if DEBUG
                if let diagnosticOperation { DeveloperDiagnostics.shared.record(.init(
                    operationID: diagnosticOperation, module: .subscription, level: .warning,
                    stage: "direct-attempt", outcome: "cancelled", attempt: attempt,
                    route: "direct", cancelled: true
                )) }
                #endif
                throw CancellationError()
            } catch let error as URLError {
                if error.code == .cancelled || Task.isCancelled {
                    throw CancellationError()
                }
                #if DEBUG || ROUTE_VALIDATION
                SafeLog.warning("[SubscriptionStage] attempt=\(attempt) stage=transport-failed category=\(Self.safeCategory(error.code)) elapsedMS=\(Int(Date().timeIntervalSince(started) * 1_000))")
                #endif
                #if DEBUG
                if let diagnosticOperation { DeveloperDiagnostics.shared.record(.init(
                    operationID: diagnosticOperation, module: .subscription, level: .error,
                    stage: "direct-attempt", outcome: Self.safeCategory(error.code),
                    elapsedMilliseconds: Int(Date().timeIntervalSince(started) * 1_000),
                    urlErrorCode: error.code.rawValue, attempt: attempt, route: "direct",
                    cancelled: error.code == .cancelled
                )) }
                #endif
                guard Self.isRetryableNetworkError(error.code),
                      attempt < maximumAttempts else {
                    throw SubscriptionFetchError.downloadFailed
                }
                Self.logRetry(attempt: attempt, category: Self.safeCategory(error.code))
                try await Self.waitBeforeRetry()
            } catch let error as SubscriptionFetchError {
                try OperationDeadline.checkCurrent()
                throw error
            } catch {
                try OperationDeadline.checkCurrent()
                #if DEBUG || ROUTE_VALIDATION
                SafeLog.warning("[SubscriptionStage] attempt=\(attempt) stage=unexpected-transport-failure elapsedMS=\(Int(Date().timeIntervalSince(started) * 1_000))")
                #endif
                throw SubscriptionFetchError.downloadFailed
            }
        }

        throw SubscriptionFetchError.downloadFailed
    }

    private func fetchThroughPhysicalNetwork(
        _ request: URLRequest,
        transport: any NetworkTransport,
        diagnosticOperation: String?
    ) async throws -> String {
        #if DEBUG || ROUTE_VALIDATION
        SafeLog.info("[SubscriptionStage] stage=physical-network-start")
        #endif
        #if DEBUG
        if let diagnosticOperation { DeveloperDiagnostics.shared.record(.init(
            operationID: diagnosticOperation, module: .subscription,
            stage: "physical-network", outcome: "started", route: "physical"
        )) }
        #endif
        do {
            let (data, response) = try await OperationDeadline.request(kind: .subscription) {
                try await transport.data(for: request, kind: .subscription)
            }
            try OperationDeadline.checkCurrent()
            guard let http = response as? HTTPURLResponse else {
                throw SubscriptionFetchError.invalidHTTPResponse(statusCode: nil)
            }
            guard (200...299).contains(http.statusCode) else {
                throw SubscriptionFetchError.invalidHTTPResponse(statusCode: http.statusCode)
            }
            guard let content = String(data: data, encoding: .utf8) else {
                throw SubscriptionFetchError.invalidEncoding
            }
            #if DEBUG || ROUTE_VALIDATION
            SafeLog.info("[SubscriptionStage] stage=physical-network-success status=\(http.statusCode)")
            #endif
            #if DEBUG
            if let diagnosticOperation { DeveloperDiagnostics.shared.record(.init(
                operationID: diagnosticOperation, module: .subscription, level: .success,
                stage: "physical-network", outcome: "decoded",
                httpStatus: http.statusCode, route: "physical"
            )) }
            #endif
            return content
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as SubscriptionFetchError {
            throw error
        } catch {
            try OperationDeadline.checkCurrent()
            #if DEBUG || ROUTE_VALIDATION
            SafeLog.warning("[SubscriptionStage] stage=physical-network-failed")
            #endif
            #if DEBUG
            if let diagnosticOperation { DeveloperDiagnostics.shared.record(.init(
                operationID: diagnosticOperation, module: .subscription, level: .error,
                stage: "physical-network", outcome: "failed", route: "physical"
            )) }
            #endif
            throw SubscriptionFetchError.downloadFailed
        }
    }

    private func fetchThroughRecovery(
        _ request: URLRequest, url: URL, builtInProxy: [String], router: APIRecoveryRouter
    ) async throws -> String {
        let plan = APIRecoveryPlan.forAbsoluteURL(url.absoluteString, builtInProxy: builtInProxy)
        do {
            return try await router.safeRetry(
                plan: plan,
                directAlreadyExhausted: .transport("订阅直连暂时不可用"),
                budget: OperationBudget.subscription
            ) { route in
                guard let transport = route.transport else {
                    throw NetworkClientError.transport("订阅恢复通道不可用")
                }
                let data: Data
                let response: URLResponse
                do {
                    try OperationDeadline.checkCurrent()
                    (data, response) = try await OperationDeadline.request(kind: .subscription) {
                        try await transport.data(for: request, kind: .subscription)
                    }
                    try OperationDeadline.checkCurrent()
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError || (error as? URLError)?.code == .cancelled {
                        throw CancellationError()
                    }
                    try OperationDeadline.checkCurrent()
                    throw error
                }
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode) else {
                    throw NetworkClientError.serviceUnavailable(
                        "订阅暂时不可用", retryable: true
                    )
                }
                guard let content = String(data: data, encoding: .utf8) else {
                    throw NetworkClientError.serviceUnavailable(
                        "订阅格式无效", retryable: false
                    )
                }
                return content
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try OperationDeadline.checkCurrent()
            throw SubscriptionFetchError.downloadFailed
        }
    }

    private static func isRetryableNetworkError(_ code: URLError.Code) -> Bool {
        switch code {
        case .timedOut,
             .networkConnectionLost,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .secureConnectionFailed:
            true
        default:
            false
        }
    }

    private static func isRetryableHTTPStatus(_ statusCode: Int) -> Bool {
        statusCode == 502 || statusCode == 503 || statusCode == 504
    }

    private static func waitBeforeRetry() async throws {
        if let deadline = OperationDeadline.current {
            try deadline.check()
            try await deadline.clock.sleepUntil(min(deadline.expires,
                deadline.clock.now() + .nanoseconds(Int64(retryDelayNanoseconds))))
            try deadline.check()
        } else {
            try await Task.sleep(nanoseconds: retryDelayNanoseconds)
        }
    }

    private static func logRetry(attempt: Int, category: String) {
        SafeLog.warning(
            "[Subscription] download attempt=\(attempt) failed "
                + "category=\(category) retrying=true"
        )
    }

    private static func safeCategory(_ code: URLError.Code) -> String {
        switch code {
        case .timedOut: "timeout"
        case .networkConnectionLost: "connection_lost"
        case .cannotConnectToHost: "cannot_connect"
        case .cannotFindHost: "host_not_found"
        case .dnsLookupFailed: "dns_lookup_failed"
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot:
            "tls_failure"
        case .notConnectedToInternet: "offline"
        case .internationalRoamingOff, .dataNotAllowed: "network_policy"
        default: "network"
        }
    }

    static func requestURL(from rawURL: String) throws -> URL {
        let normalized = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw SubscriptionFetchError.missingSubscriptionURL }
        guard var components = URLComponents(string: normalized),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false else {
            throw SubscriptionFetchError.invalidSubscriptionURL
        }

        var queryItems = components.queryItems ?? []
        let firstFlagIndex = queryItems.firstIndex { $0.name == "flag" }
        let existingFlag = queryItems.first {
            $0.name == "flag" && $0.value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }?.value
        queryItems.removeAll { $0.name == "flag" }
        let flagItem = URLQueryItem(name: "flag", value: existingFlag ?? "meta")
        queryItems.insert(flagItem, at: min(firstFlagIndex ?? queryItems.endIndex, queryItems.endIndex))
        components.queryItems = queryItems

        guard let url = components.url else { throw SubscriptionFetchError.invalidSubscriptionURL }
        return url
    }
}
