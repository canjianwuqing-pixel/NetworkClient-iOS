import Foundation
import Network
import Security

#if DEBUG || ROUTE_VALIDATION
/// Records only transport phases for subscription diagnostics. No URL, host,
/// request headers, response body, or credentials cross this delegate.
private final class SubscriptionTransportMetrics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        let transactions = metrics.transactionMetrics
        guard let transaction = transactions.last else {
            SafeLog.info("[SubscriptionMetric] transactions=0 dnsMS=unobserved connectMS=unobserved tlsMS=unobserved http=unobserved")
            #if DEBUG
            DeveloperDiagnostics.shared.record(.init(
                operationID: DeveloperDiagnosticOperation.make("subscription-metrics"),
                module: .subscription,
                level: .warning,
                stage: "urlsession-metrics",
                outcome: "unobserved",
                detail: "transactions=0"
            ))
            #endif
            return
        }
        func duration(_ start: Date?, _ end: Date?) -> String {
            guard let start, let end, end >= start else { return "unobserved" }
            return String(Int((end.timeIntervalSince(start) * 1_000).rounded()))
        }
        let status = (task.response as? HTTPURLResponse).map { String($0.statusCode) } ?? "unobserved"
        // A redirect can move a signed subscription URL to another host. Keep
        // only counts and a Boolean: neither the URL nor its token is logged.
        let redirectResponses = transactions.reduce(0) { count, item in
            let code = (item.response as? HTTPURLResponse)?.statusCode ?? 0
            return count + ((300...399).contains(code) ? 1 : 0)
        }
        let targetHosts = Set(transactions.compactMap { $0.request.url?.host?.lowercased() })
        let sawDNS = transactions.contains { $0.domainLookupStartDate != nil }
        let sawConnect = transactions.contains { $0.connectStartDate != nil }
        let sawTLS = transactions.contains { $0.secureConnectionStartDate != nil }
        SafeLog.info(
            "[SubscriptionMetric] transactions=\(transactions.count) redirects=\(redirectResponses) "
            + "targetHostChanged=\(targetHosts.count > 1) "
            + "dnsObserved=\(sawDNS) connectObserved=\(sawConnect) tlsObserved=\(sawTLS) "
            + "dnsMS=\(duration(transaction.domainLookupStartDate, transaction.domainLookupEndDate)) "
            + "connectMS=\(duration(transaction.connectStartDate, transaction.connectEndDate)) "
            + "tlsMS=\(duration(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate)) "
            + "http=\(status) reused=\(transaction.isReusedConnection)"
        )
        #if DEBUG
        DeveloperDiagnostics.shared.record(.init(
            operationID: DeveloperDiagnosticOperation.make("subscription-metrics"),
            module: .subscription,
            stage: "urlsession-metrics",
            outcome: "collected",
            httpStatus: (task.response as? HTTPURLResponse)?.statusCode,
            detail: "transactions=\(transactions.count) redirects=\(redirectResponses) hostChanged=\(targetHosts.count > 1) dns=\(sawDNS) connect=\(sawConnect) tls=\(sawTLS) reused=\(transaction.isReusedConnection)"
        ))
        #endif
    }
}
#endif

/// Describes the caller's safety boundary. Routing and retry decisions remain with
/// the owning service; a transport sends exactly one request per invocation.
enum NetworkRequestKind: Sendable, Equatable {
    case apiRead
    case apiLogin
    case apiWrite
    case apiProbe
    case writeRouteProbe
    case remoteConfiguration
    case subscription
    case brandResource

    /// A semantic boundary: invite/save is a GET write; coupon/check is a POST read.
    var isNonIdempotentWrite: Bool { self == .apiWrite || self == .apiLogin }
}

/// Shared by Direct and the App-local SOCKS task delegate. Refusing a redirect
/// returns the original 3xx response; it does not establish that the write failed.
class NetworkRedirectPolicyDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let kind: NetworkRequestKind

    init(kind: NetworkRequestKind) { self.kind = kind }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(kind.isNonIdempotentWrite ? nil : request)
    }
}

protocol NetworkTransport: Sendable {
    func data(for request: URLRequest, kind: NetworkRequestKind) async throws -> (Data, URLResponse)
}

/// A one-shot write owns its direct session and releases it after submission.
protocol ManagedNetworkTransport: NetworkTransport {
    func finishTasksAndInvalidate()
}

enum NetworkSessionProfile: Sendable {
    case api
    case apiProbe
    case writeRouteProbe
    case remoteConfiguration
    case subscription
    case brandResource
}

enum NetworkTransportPolicy {
    static func requestTimeout(for kind: NetworkRequestKind) -> TimeInterval {
        switch kind {
        case .apiRead, .apiLogin, .apiWrite: 25
        case .apiProbe: 3
        case .writeRouteProbe: 4
        case .remoteConfiguration: 6
        case .subscription: 60
        case .brandResource: 8
        }
    }

    static func configuration(for profile: NetworkSessionProfile) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        let timeouts: (request: TimeInterval, resource: TimeInterval)
        switch profile {
        case .api: timeouts = (25, 25)
        case .apiProbe: timeouts = (3, 3)
        case .writeRouteProbe: timeouts = (4, 4)
        case .remoteConfiguration: timeouts = (6, 6)
        case .subscription: timeouts = (60, 90)
        case .brandResource: timeouts = (8, 12)
        }
        configuration.timeoutIntervalForRequest = timeouts.request
        configuration.timeoutIntervalForResource = timeouts.resource
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        return configuration
    }
}

/// The default direct transport. A future App-local recovery transport can conform
/// to NetworkTransport without becoming a system VPN or changing request callers.
struct URLSessionNetworkTransport: ManagedNetworkTransport {
    private let session: URLSession
    private let writeProbeSession: URLSession?

    init(profile: NetworkSessionProfile) {
        let configuration = NetworkTransportPolicy.configuration(for: profile)
        if case .api = profile {
            writeProbeSession = URLSession(configuration: NetworkTransportPolicy.configuration(for: .writeRouteProbe))
        } else {
            writeProbeSession = nil
        }
        #if DEBUG || ROUTE_VALIDATION
        if case .subscription = profile {
            session = URLSession(configuration: configuration, delegate: SubscriptionTransportMetrics(), delegateQueue: nil)
        } else {
            session = URLSession(configuration: configuration)
        }
        #else
        session = URLSession(configuration: configuration)
        #endif
    }

    init(session: URLSession) {
        self.session = session
        writeProbeSession = nil
    }

    func data(for request: URLRequest, kind: NetworkRequestKind) async throws -> (Data, URLResponse) {
        let session = kind == .writeRouteProbe ? (writeProbeSession ?? self.session) : self.session
        let redirectPolicy = kind.isNonIdempotentWrite ? NetworkRedirectPolicyDelegate(kind: kind) : nil
        #if DEBUG
        let operationID = DeveloperDiagnosticOperation.make("transport")
        let started = ContinuousClock.now
        let timeout = Int((request.timeoutInterval * 1_000).rounded())
        DeveloperDiagnostics.shared.record(.init(
            operationID: operationID,
            module: Self.diagnosticModule(for: kind),
            stage: "request",
            outcome: "started",
            timeoutMilliseconds: timeout,
            route: "direct",
            detail: "kind=\(String(describing: kind)) method=\(request.httpMethod ?? "unknown")"
        ))
        do {
            let result = try await session.data(for: request, delegate: redirectPolicy)
            let elapsed = Self.milliseconds(started.duration(to: .now))
            DeveloperDiagnostics.shared.record(.init(
                operationID: operationID,
                module: Self.diagnosticModule(for: kind),
                level: .success,
                stage: "request",
                outcome: "completed",
                elapsedMilliseconds: elapsed,
                timeoutMilliseconds: timeout,
                httpStatus: (result.1 as? HTTPURLResponse)?.statusCode,
                route: "direct",
                detail: "kind=\(String(describing: kind))"
            ))
            return result
        } catch is CancellationError {
            let elapsed = Self.milliseconds(started.duration(to: .now))
            DeveloperDiagnostics.shared.record(.init(
                operationID: operationID,
                module: Self.diagnosticModule(for: kind),
                level: .warning,
                stage: "request",
                outcome: "cancelled",
                elapsedMilliseconds: elapsed,
                timeoutMilliseconds: timeout,
                route: "direct",
                cancelled: true,
                detail: "kind=\(String(describing: kind))"
            ))
            throw CancellationError()
        } catch let error as URLError {
            let elapsed = Self.milliseconds(started.duration(to: .now))
            DeveloperDiagnostics.shared.record(.init(
                operationID: operationID,
                module: Self.diagnosticModule(for: kind),
                level: .error,
                stage: "request",
                outcome: Self.safeCategory(error.code),
                elapsedMilliseconds: elapsed,
                timeoutMilliseconds: timeout,
                urlErrorCode: error.code.rawValue,
                route: "direct",
                cancelled: error.code == .cancelled,
                detail: "kind=\(String(describing: kind))"
            ))
            throw error
        } catch {
            let elapsed = Self.milliseconds(started.duration(to: .now))
            DeveloperDiagnostics.shared.record(.init(
                operationID: operationID,
                module: Self.diagnosticModule(for: kind),
                level: .error,
                stage: "request",
                outcome: "transport-error",
                elapsedMilliseconds: elapsed,
                timeoutMilliseconds: timeout,
                route: "direct",
                detail: "kind=\(String(describing: kind)) type=\(String(describing: type(of: error)))"
            ))
            throw error
        }
        #else
        return try await session.data(for: request, delegate: redirectPolicy)
        #endif
    }

    #if DEBUG
    private static func diagnosticModule(for kind: NetworkRequestKind) -> DeveloperDiagnosticModule {
        switch kind {
        case .remoteConfiguration: .configuration
        case .apiProbe: .apiHealth
        case .subscription: .subscription
        case .apiRead, .apiLogin, .apiWrite, .writeRouteProbe, .brandResource: .api
        }
    }

    private static func safeCategory(_ code: URLError.Code) -> String {
        switch code {
        case .timedOut: "timeout"
        case .cancelled: "cancelled"
        case .cannotFindHost, .dnsLookupFailed: "dns"
        case .cannotConnectToHost: "connect"
        case .networkConnectionLost: "connection-lost"
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot: "tls"
        case .notConnectedToInternet: "offline"
        default: "network"
        }
    }

    private static func milliseconds(_ duration: ContinuousClock.Duration) -> Int {
        let value = duration.components
        return Int(value.seconds * 1_000 + value.attoseconds / 1_000_000_000_000_000)
    }
    #endif

    func finishTasksAndInvalidate() {
        session.finishTasksAndInvalidate()
        writeProbeSession?.finishTasksAndInvalidate()
    }

    func invalidateAndCancel() {
        session.invalidateAndCancel()
        writeProbeSession?.invalidateAndCancel()
    }
}

/// Sends one subscription GET over an explicitly selected physical interface.
/// This is a request-scoped fallback only: it never changes the process route,
/// the active Packet Tunnel, or the App-only recovery Core owner.
struct PhysicalNetworkSubscriptionTransport: NetworkTransport {
    private static let interfaceTypes: [NWInterface.InterfaceType] = [
        .wifi, .cellular, .wiredEthernet,
    ]

    func data(
        for request: URLRequest, kind: NetworkRequestKind
    ) async throws -> (Data, URLResponse) {
        guard kind == .subscription, request.httpMethod == "GET",
              request.httpBody == nil else {
            throw URLError(.unsupportedURL)
        }
        var lastError: Error = URLError(.notConnectedToInternet)
        for interfaceType in Self.interfaceTypes {
            try Task.checkCancellation()
            do {
                return try await Self.followRedirects(
                    request, interfaceType: interfaceType
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func followRedirects(
        _ original: URLRequest, interfaceType: NWInterface.InterfaceType
    ) async throws -> (Data, URLResponse) {
        var request = original
        for redirectCount in 0...3 {
            let result = try await PhysicalHTTPExchange(
                request: request, interfaceType: interfaceType
            ).run()
            guard let response = result.1 as? HTTPURLResponse,
                  (300...399).contains(response.statusCode),
                  let location = response.value(forHTTPHeaderField: "Location") else {
                return result
            }
            guard redirectCount < 3, let currentURL = request.url,
                  let target = URL(string: location, relativeTo: currentURL)?.absoluteURL,
                  let scheme = target.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  target.user == nil, target.password == nil else {
                throw URLError(.httpTooManyRedirects)
            }
            var redirected = request
            redirected.url = target
            if currentURL.host?.lowercased() != target.host?.lowercased() {
                redirected.setValue(nil, forHTTPHeaderField: "Authorization")
            }
            request = redirected
        }
        throw URLError(.httpTooManyRedirects)
    }
}

private final class PhysicalHTTPExchange: @unchecked Sendable {
    private static let maximumResponseBytes = 4 * 1_024 * 1_024
    private static let queue = DispatchQueue(
        label: "NetworkClient.SubscriptionPhysicalNetwork",
        attributes: .concurrent
    )

    private let request: URLRequest
    private let interfaceType: NWInterface.InterfaceType
    private let lock = NSLock()
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var timeout: DispatchWorkItem?
    private var completed = false
    private var responseBytes = Data()

    init(request: URLRequest, interfaceType: NWInterface.InterfaceType) {
        self.request = request
        self.interfaceType = interfaceType
    }

    func run() async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !completed else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                lock.unlock()
                start()
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    private func start() {
        do {
            let prepared = try Self.prepare(request)
            let parameters: NWParameters
            if prepared.secure {
                let tls = NWProtocolTLS.Options()
                sec_protocol_options_add_tls_application_protocol(
                    tls.securityProtocolOptions, "http/1.1"
                )
                parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            } else {
                parameters = .tcp
            }
            parameters.requiredInterfaceType = interfaceType
            let connection = NWConnection(
                host: NWEndpoint.Host(prepared.host),
                port: NWEndpoint.Port(rawValue: prepared.port)!,
                using: parameters
            )
            lock.lock()
            guard !completed else {
                lock.unlock()
                connection.cancel()
                return
            }
            self.connection = connection
            lock.unlock()
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.send(prepared.bytes, on: connection)
                case let .failed(error):
                    self.finish(.failure(Self.urlError(from: error)))
                case let .waiting(error):
                    // A required physical interface that is not currently
                    // usable must yield immediately so the next interface can
                    // be tried; waiting here would hide an available cellular
                    // path behind an unavailable Wi-Fi path.
                    self.finish(.failure(Self.urlError(from: error)))
                case .cancelled:
                    self.finish(.failure(CancellationError()))
                default:
                    break
                }
            }
            let seconds = max(1, min(request.timeoutInterval, 25))
            let timeout = DispatchWorkItem { [weak self] in
                self?.finish(.failure(URLError(.timedOut)))
            }
            lock.lock()
            self.timeout = timeout
            lock.unlock()
            Self.queue.asyncAfter(deadline: .now() + seconds, execute: timeout)
            connection.start(queue: Self.queue)
        } catch {
            finish(.failure(error))
        }
    }

    private func send(_ bytes: Data, on connection: NWConnection) {
        connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.finish(.failure(Self.urlError(from: error)))
            } else {
                self.receive(on: connection)
            }
        })
    }

    private func receive(on connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: 1, maximumLength: 64 * 1_024
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lock.lock()
                self.responseBytes.append(data)
                let oversized = self.responseBytes.count > Self.maximumResponseBytes
                self.lock.unlock()
                if oversized {
                    self.finish(.failure(URLError(.dataLengthExceedsMaximum)))
                    return
                }
            }
            if let error {
                self.finish(.failure(Self.urlError(from: error)))
            } else if isComplete {
                do { self.finish(.success(try Self.parse(self.responseBytes, request: self.request))) }
                catch { self.finish(.failure(error)) }
            } else {
                self.receive(on: connection)
            }
        }
    }

    private func finish(_ result: Result<(Data, URLResponse), Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let continuation = continuation
        self.continuation = nil
        let connection = connection
        self.connection = nil
        let timeout = timeout
        self.timeout = nil
        lock.unlock()
        timeout?.cancel()
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        continuation?.resume(with: result)
    }

    private struct PreparedRequest {
        let host: String
        let port: UInt16
        let secure: Bool
        let bytes: Data
    }

    private static func prepare(_ request: URLRequest) throws -> PreparedRequest {
        guard request.httpMethod == "GET", request.httpBody == nil,
              let url = request.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else {
            throw URLError(.unsupportedURL)
        }
        let secure = scheme == "https"
        let portValue = url.port ?? (secure ? 443 : 80)
        guard let port = UInt16(exactly: portValue), port > 0,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        var target = components.percentEncodedPath
        if target.isEmpty { target = "/" }
        if let query = components.percentEncodedQuery { target += "?" + query }
        guard !target.contains("\r"), !target.contains("\n") else {
            throw URLError(.badURL)
        }
        let defaultPort = secure ? 443 : 80
        let hostHeader = portValue == defaultPort ? host : "\(host):\(portValue)"
        var headers = request.allHTTPHeaderFields ?? [:]
        headers["Host"] = hostHeader
        headers["Connection"] = "close"
        headers["Accept-Encoding"] = "identity"
        var lines = ["GET \(target) HTTP/1.1"]
        for (name, value) in headers.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            guard !name.isEmpty, !name.contains(":"), !name.contains("\r"), !name.contains("\n"),
                  !value.contains("\r"), !value.contains("\n") else {
                throw URLError(.badURL)
            }
            lines.append("\(name): \(value)")
        }
        lines.append("")
        lines.append("")
        guard let bytes = lines.joined(separator: "\r\n").data(using: .utf8) else {
            throw URLError(.badURL)
        }
        return PreparedRequest(host: host, port: port, secure: secure, bytes: bytes)
    }

    private static func parse(
        _ raw: Data, request: URLRequest
    ) throws -> (Data, URLResponse) {
        let separator = Data("\r\n\r\n".utf8)
        guard let boundary = raw.range(of: separator), let url = request.url,
              let headerText = String(data: raw[..<boundary.lowerBound], encoding: .isoLatin1) else {
            throw URLError(.cannotParseResponse)
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw URLError(.cannotParseResponse) }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/"),
              let statusCode = Int(statusParts[1]), (100...599).contains(statusCode) else {
            throw URLError(.cannotParseResponse)
        }
        var headers: [String: String] = [:]
        var normalized: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                throw URLError(.cannotParseResponse)
            }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw URLError(.cannotParseResponse) }
            headers[name] = value
            normalized[name.lowercased()] = value
        }
        guard normalized["content-encoding"]?.lowercased() ?? "identity" == "identity" else {
            throw URLError(.cannotDecodeContentData)
        }
        let bodyStart = boundary.upperBound
        let encodedBody = Data(raw[bodyStart...])
        let body: Data
        if normalized["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = try decodeChunked(encodedBody)
        } else if let rawLength = normalized["content-length"],
                  let length = Int(rawLength), length >= 0 {
            guard encodedBody.count >= length else { throw URLError(.cannotParseResponse) }
            body = encodedBody.prefix(length)
        } else {
            body = encodedBody
        }
        guard let response = HTTPURLResponse(
            url: url, statusCode: statusCode, httpVersion: String(statusParts[0]),
            headerFields: headers
        ) else { throw URLError(.cannotParseResponse) }
        return (body, response)
    }

    private static func decodeChunked(_ data: Data) throws -> Data {
        var cursor = data.startIndex
        var decoded = Data()
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = data[cursor...].range(of: crlf) else {
                throw URLError(.cannotParseResponse)
            }
            let sizeBytes = data[cursor..<lineEnd.lowerBound]
            guard let sizeLine = String(data: sizeBytes, encoding: .ascii),
                  let token = sizeLine.split(separator: ";", maxSplits: 1).first,
                  let size = Int(token.trimmingCharacters(in: .whitespaces), radix: 16),
                  size >= 0 else { throw URLError(.cannotParseResponse) }
            cursor = lineEnd.upperBound
            if size == 0 { return decoded }
            guard size <= Self.maximumResponseBytes,
                  data.distance(from: cursor, to: data.endIndex) >= size + 2 else {
                throw URLError(.cannotParseResponse)
            }
            let end = data.index(cursor, offsetBy: size)
            decoded.append(data[cursor..<end])
            guard decoded.count <= Self.maximumResponseBytes,
                  data[end..<data.index(end, offsetBy: 2)] == crlf else {
                throw URLError(.cannotParseResponse)
            }
            cursor = data.index(end, offsetBy: 2)
        }
    }

    private static func urlError(from error: NWError) -> Error {
        switch error {
        case let .posix(code):
            switch code {
            case .ENETDOWN, .ENETUNREACH, .EHOSTUNREACH: URLError(.notConnectedToInternet)
            case .ETIMEDOUT: URLError(.timedOut)
            case .ECONNREFUSED: URLError(.cannotConnectToHost)
            default: URLError(.networkConnectionLost)
            }
        case .dns: URLError(.dnsLookupFailed)
        case .tls: URLError(.secureConnectionFailed)
        case .wifiAware: URLError(.networkConnectionLost)
        @unknown default: URLError(.unknown)
        }
    }
}

/// A small monotonic clock seam. Tests advance virtual time and wake sleepers;
/// production uses ContinuousClock, including while the device is asleep.
struct OperationClock: Sendable {
    let now: @Sendable () -> Duration
    let sleepUntil: @Sendable (Duration) async throws -> Void

    static let continuous: Self = {
        let clock = ContinuousClock()
        let origin = clock.now
        return Self(now: { origin.duration(to: clock.now) }, sleepUntil: {
            try await clock.sleep(until: origin.advanced(by: $0))
        })
    }()
}

enum OperationBudget {
    static let read: Duration = .seconds(30)
    static let writeRouting: Duration = .seconds(18)
    static let writeSubmit: Duration = .seconds(25)
    static let subscription: Duration = .seconds(90)
    static let login: Duration = .seconds(60)
    static let minimumRecoveryStart: Duration = .seconds(1)
}

/// A cooperative deadline, not a way to kill synchronous SDK calls. Task-local
/// propagation keeps nested API paths on the same clock and remaining budget.
struct OperationDeadline: Sendable {
    @TaskLocal static var current: Self?
    let clock: OperationClock
    let expires: Duration

    init(after duration: Duration, clock: OperationClock = .continuous,
         parent: Self? = Self.current) {
        self.clock = parent?.clock ?? clock
        expires = self.clock.now() + min(duration, parent?.remaining ?? duration)
    }

    var remaining: Duration { max(.zero, expires - clock.now()) }

    func check(minimum: Duration = .zero) throws {
        try Task.checkCancellation()
        guard remaining > .zero, remaining >= minimum else { throw NetworkClientError.timedOut }
    }

    static func checkCurrent(minimum: Duration = .zero) throws {
        try Task.checkCancellation()
        try current?.check(minimum: minimum)
    }

    /// Only cooperative work (HTTP or a submit callback) is raced. The group
    /// joins cancellation and cleanup before returning; no Core owner is detached.
    func run<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try check()
        do {
            return try await Self.$current.withValue(self) {
                try await withThrowingTaskGroup(of: Result.self) { group in
                    defer { group.cancelAll() }
                    group.addTask {
                        do {
                            try check()
                            let result = try await operation()
                            try check()
                            return result
                        } catch {
                            // A callback can cancel its own task before throwing
                            // another error. Preserve that cancellation across
                            // the child-task boundary instead of retrying it.
                            try Task.checkCancellation()
                            throw error
                        }
                    }
                    group.addTask {
                        try await clock.sleepUntil(expires)
                        try Task.checkCancellation()
                        throw NetworkClientError.timedOut
                    }
                    guard let result = try await group.next() else { throw CancellationError() }
                    return result
                }
            }
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }

    static func request<Result: Sendable>(
        kind: NetworkRequestKind,
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        let seconds: TimeInterval = kind == .subscription ? 90 : NetworkTransportPolicy.requestTimeout(for: kind)
        return try await Self(after: .seconds(seconds)).run(operation)
    }

    static func requestTimeout(for kind: NetworkRequestKind) -> TimeInterval {
        let value = current?.remaining.components
        let remaining = value.map { Double($0.seconds) + Double($0.attoseconds) / 1e18 }
        return min(NetworkTransportPolicy.requestTimeout(for: kind), remaining ?? .greatestFiniteMagnitude)
    }
}
