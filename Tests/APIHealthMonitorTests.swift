import XCTest
import Network
@testable import NetworkClient

private func probeReply(_ request: URLRequest, status: Int = 200,
                        contentType: String = "application/json",
                        body: String = #"{"data":{"is_email_verify":1}}"#) -> (Data, URLResponse) {
    (Data(body.utf8), HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: nil,
        headerFields: ["Content-Type": contentType]
    )!)
}

private actor ProbeFixtureTransport: NetworkTransport {
    typealias Responder = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let responder: Responder
    private(set) var calls: [String] = []
    private var active = 0
    private(set) var maximumActive = 0

    init(_ responder: @escaping Responder) { self.responder = responder }

    func data(for request: URLRequest, kind: NetworkRequestKind) async throws -> (Data, URLResponse) {
        XCTAssertEqual(kind, .apiProbe)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.httpBody)
        calls.append(request.url?.host ?? "")
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        return try await responder(request)
    }
}

private actor StaleProbeTransport: NetworkTransport {
    private(set) var calls = 0

    func data(for request: URLRequest, kind: NetworkRequestKind) async throws -> (Data, URLResponse) {
        calls += 1
        if calls == 1 {
            // Simulate a transport that finishes after its caller was cancelled.
            try? await Task.sleep(for: .milliseconds(80))
            return probeReply(request)
        }
        throw URLError(.timedOut)
    }

    func waitForFirstCall() async {
        while calls == 0 { await Task.yield() }
    }
}

private final class HealthTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func current() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

private actor RouteAttemptRecorder {
    private var targets: [String] = []

    func append(_ target: String) {
        targets.append(target)
    }

    func snapshot() -> [String] {
        targets
    }
}

final class APIHealthMonitorTests: XCTestCase {
    private let first = "https://127.0.0.1"
    private let second = "https://127.0.0.2"
    private let third = "https://127.0.0.3"
    private let fourth = "https://127.0.0.4"

    private func path(
        _ interface: NWInterface.InterfaceType,
        identifier: String = "active-interface",
        reachable: Bool = true,
        constrained: Bool = false
    ) -> APIHealthNetworkPath {
        APIHealthNetworkPath(
            status: reachable ? .satisfied : .unsatisfied,
            usedInterfaceTypes: reachable ? [interface] : [],
            usedInterfaceIdentifiers: reachable ? [identifier] : [],
            isExpensive: interface == .cellular,
            isConstrained: constrained
        )
    }

    private func config(_ hosts: [String], active: String? = nil, name: String = "Fixture") -> AppConfig {
        AppConfig(
            appName: name, loginTitle: nil, appLogo: nil, homePage: nil,
            telegramGroup: nil, supportAPI: nil, updateURL: nil,
            userAgent: "Offline-Test", latencyDisplayRatio: 1, inviteLink: nil,
            apiBaseURLs: hosts, activeAPIBaseURL: active, builtInProxy: []
        )
    }

    private func policy(
        budget: TimeInterval = 1,
        ttl: TimeInterval = 120,
        cooldown: TimeInterval = 0,
        debounce: TimeInterval = 0.02,
        concurrency: Int = 2
    ) -> APIHealthPolicy {
        APIHealthPolicy(
            probeTimeout: 0.5, totalBudget: budget, healthyTTL: ttl,
            retryCooldown: cooldown, networkDebounce: debounce,
            maximumConcurrentProbes: concurrency
        )
    }

    func testSingleHealthyAPIAndValidatedProbeRequest() async {
        let host = first
        let transport = ProbeFixtureTransport { request in probeReply(request) }
        let monitor = APIHealthMonitor(transport: transport, policy: policy(), observeNetwork: false)
        let configured = config([host])
        await monitor.configure(configured)
        await monitor.waitForCurrentProbe()
        let diagnostic = await monitor.diagnostics()
        XCTAssertEqual(diagnostic.map(\.category), [.healthy])
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testMultipleHealthyAPIsRemainDiagnosticOnly() async {
        let hosts = [first, second]
        let transport = ProbeFixtureTransport { request in
            if request.url?.host == "127.0.0.2" { try await Task.sleep(for: .milliseconds(20)) }
            return probeReply(request)
        }
        let monitor = APIHealthMonitor(transport: transport, policy: policy(), observeNetwork: false)
        let configured = config(hosts, active: second)
        await monitor.configure(configured)
        await monitor.waitForCurrentProbe()
        XCTAssertEqual(AppConfig.orderedAPIBaseURLs(from: configured), [second, first])
        let diagnostic = await monitor.diagnostics()
        XCTAssertEqual(diagnostic.map(\.category), [.healthy, .healthy])
    }

    func testFailedPrimaryHealthyBackupDoesNotReorderBusinessRoutes() async throws {
        let transport = ProbeFixtureTransport { request in
            if request.url?.host == "127.0.0.1" { throw URLError(.cannotFindHost) }
            return probeReply(request)
        }
        let monitor = APIHealthMonitor(transport: transport, policy: policy(), observeNetwork: false)
        let configured = config([first, second], active: first)
        await monitor.configure(configured)
        await monitor.waitForCurrentProbe()
        let diagnostic = await monitor.diagnostics()
        XCTAssertEqual(diagnostic.map(\.category), [.dns, .healthy])
        let attempts = RouteAttemptRecorder()
        let expectedFirst = first
        let selected: String = try await APIRecoveryRouter().safeRetry(plan: .forAPI(configured)) { route in
            await attempts.append(route.target)
            if route.target == expectedFirst { throw NetworkClientError.dnsFailure }
            return route.target
        }
        XCTAssertEqual(selected, second)
        let attemptedTargets = await attempts.snapshot()
        XCTAssertEqual(attemptedTargets, [first, second])
    }

    func testAllProbeFailuresStillAllowExistingActualRequestFailover() async throws {
        let transport = ProbeFixtureTransport { _ in throw URLError(.timedOut) }
        let monitor = APIHealthMonitor(transport: transport, policy: policy(), observeNetwork: false)
        let configured = config([first, second], active: first)
        await monitor.configure(configured)
        await monitor.waitForCurrentProbe()
        let router = APIRecoveryRouter()
        let attempted = AttemptCounter()
        let chosen: String = try await router.safeRetry(plan: .forAPI(configured)) { route in
            await attempted.increment()
            if route.target == "https://127.0.0.1" { throw NetworkClientError.transport("offline") }
            return route.target
        }
        XCTAssertEqual(chosen, second)
        let count = await attempted.value
        XCTAssertEqual(count, 2)
        let diagnostic = await monitor.diagnostics()
        XCTAssertEqual(diagnostic.map(\.category), [.timeout, .timeout])
    }

    func testHTMLAndMalformedSuccessfulResponsesAreUnhealthy() async {
        let transport = ProbeFixtureTransport { request in
            if request.url?.host == "127.0.0.1" {
                return probeReply(request, contentType: "text/html", body: "<html>not an API</html>")
            }
            return probeReply(request, body: #"{"data":{"unexpected":1}}"#)
        }
        let monitor = APIHealthMonitor(transport: transport, policy: policy(), observeNetwork: false)
        await monitor.configure(config([first, second]))
        await monitor.waitForCurrentProbe()
        let diagnostic = await monitor.diagnostics()
        XCTAssertEqual(diagnostic.map(\.category), [.invalidContent, .invalidPayload])
    }

    func testHTTPAndBusinessFailuresAreClassifiedWithoutAddressExposure() async {
        let transport = ProbeFixtureTransport { request in
            switch request.url?.host {
            case "127.0.0.1": return probeReply(request, status: 401)
            case "127.0.0.2": return probeReply(request, status: 403)
            case "127.0.0.3": return probeReply(request, status: 503)
            default: return probeReply(request, body: #"{"status":"fail","message":"Invalid input","data":false}"#)
            }
        }
        let monitor = APIHealthMonitor(transport: transport, policy: policy(), observeNetwork: false)
        await monitor.configure(config([first, second, third, fourth]))
        await monitor.waitForCurrentProbe()
        let diagnostic = await monitor.diagnostics()
        XCTAssertEqual(diagnostic.map(\.category), [.unauthorized, .unauthorized, .server, .business])
        let description = String(describing: diagnostic)
        XCTAssertFalse(description.contains("127.0.0"))
        XCTAssertFalse(description.contains("Invalid input"))
        XCTAssertFalse(description.contains("Authorization"))
    }

    func testTLSAndTimeoutAreDistinct() async {
        let transport = ProbeFixtureTransport { request in
            if request.url?.host == "127.0.0.1" { throw URLError(.secureConnectionFailed) }
            throw URLError(.timedOut)
        }
        let monitor = APIHealthMonitor(transport: transport, policy: policy(), observeNetwork: false)
        await monitor.configure(config([first, second]))
        await monitor.waitForCurrentProbe()
        let diagnostic = await monitor.diagnostics()
        XCTAssertEqual(diagnostic.map(\.category), [.tls, .timeout])
    }

    func testConcurrentLimitAndTotalBudgetCancelSlowProbes() async {
        let transport = ProbeFixtureTransport { request in
            try await Task.sleep(for: .milliseconds(250))
            return probeReply(request)
        }
        let monitor = APIHealthMonitor(
            transport: transport, policy: policy(budget: 0.05), observeNetwork: false
        )
        let clock = ContinuousClock()
        let start = clock.now
        await monitor.configure(config([first, second, third, fourth]))
        await monitor.waitForCurrentProbe()
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(1))
        let maximum = await transport.maximumActive
        XCTAssertLessThanOrEqual(maximum, 2)
        let calls = await transport.calls
        XCTAssertLessThanOrEqual(calls.count, 2)
    }

    func testAllCandidatesRespectConcurrencyLimit() async {
        let transport = ProbeFixtureTransport { request in
            try await Task.sleep(for: .milliseconds(15))
            return probeReply(request)
        }
        let monitor = APIHealthMonitor(
            transport: transport, policy: policy(concurrency: 2), observeNetwork: false
        )
        await monitor.configure(config([first, second, third, fourth]))
        await monitor.waitForCurrentProbe()
        let maximum = await transport.maximumActive
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 4)
        XCTAssertLessThanOrEqual(maximum, 2)
    }

    func testConcurrentConfigureAndForegroundShareOneProbe() async {
        let transport = ProbeFixtureTransport { request in
            try await Task.sleep(for: .milliseconds(20))
            return probeReply(request)
        }
        let monitor = APIHealthMonitor(transport: transport, policy: policy(), observeNetwork: false)
        let configured = config([first, second])
        await monitor.configure(configured)
        await monitor.configure(configured)
        await monitor.setForeground(true)
        await monitor.waitForCurrentProbe()
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 2)
    }

    func testHealthTTLExpiryAndForegroundRefresh() async {
        let clock = HealthTestClock()
        let transport = ProbeFixtureTransport { request in
            if request.url?.host == "127.0.0.1" { throw URLError(.cannotConnectToHost) }
            return probeReply(request)
        }
        let monitor = APIHealthMonitor(
            transport: transport, policy: policy(ttl: 30), now: { clock.current() }, observeNetwork: false
        )
        let configured = config([first, second], active: first)
        await monitor.configure(configured)
        await monitor.waitForCurrentProbe()
        clock.advance(31)
        await monitor.setForeground(true)
        await monitor.setForeground(true)
        await monitor.waitForCurrentProbe()
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 4)
    }

    func testConfigurationChangeDiscardsOldInFlightResult() async {
        let transport = ProbeFixtureTransport { request in
            if request.url?.host == "127.0.0.1" { try await Task.sleep(for: .milliseconds(100)) }
            return probeReply(request)
        }
        let monitor = APIHealthMonitor(transport: transport, policy: policy(), observeNetwork: false)
        let old = config([first])
        let replacement = config([second], name: "Another fixture")
        await monitor.configure(old)
        await Task.yield()
        await monitor.configure(replacement)
        await monitor.waitForCurrentProbe()
        let diagnostic = await monitor.diagnostics()
        XCTAssertEqual(diagnostic.map(\.candidateIndex), [1])
        XCTAssertEqual(diagnostic.map(\.category), [.healthy])
    }

    func testEquivalentPathCallbacksKeepHealthAndDoNotStartAnotherProbe() async {
        let clock = HealthTestClock()
        let transport = ProbeFixtureTransport { request in probeReply(request) }
        let monitor = APIHealthMonitor(
            transport: transport, policy: policy(ttl: 120, cooldown: 10),
            now: { clock.current() }, observeNetwork: false
        )
        let configured = config([first, second])
        await monitor.configure(configured)
        await monitor.waitForCurrentProbe()
        let wifi = path(.wifi)
        await monitor.networkDidChange(path: wifi) // Initial NWPath snapshot.
        for _ in 0..<10 {
            clock.advance(10)
            await monitor.networkDidChange(path: wifi)
            await monitor.setForeground(true)
        }
        await monitor.waitForCurrentProbe()
        let diagnostic = await monitor.diagnostics()
        XCTAssertEqual(diagnostic.map(\.category), [.healthy, .healthy])
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 2)
    }

    func testExpiredObservationWaitsForObserverLifecycleInsteadOfBusinessDemand() async {
        let clock = HealthTestClock()
        let transport = ProbeFixtureTransport { request in probeReply(request) }
        let monitor = APIHealthMonitor(
            transport: transport, policy: policy(ttl: 120, cooldown: 10),
            now: { clock.current() }, observeNetwork: false
        )
        let configured = config([first])
        await monitor.configure(configured)
        await monitor.waitForCurrentProbe()
        let wifi = path(.wifi)
        await monitor.networkDidChange(path: wifi)
        clock.advance(121)
        for _ in 0..<20 { await monitor.networkDidChange(path: wifi) }
        let beforeDemand = await transport.calls
        XCTAssertEqual(beforeDemand.count, 1)
        await monitor.setForeground(true)
        await monitor.waitForCurrentProbe()
        let afterDemand = await transport.calls
        XCTAssertEqual(afterDemand.count, 2)
    }

    func testWiFiToCellularStableCellularAndReturnToWiFi() async {
        let transport = ProbeFixtureTransport { request in probeReply(request) }
        let monitor = APIHealthMonitor(
            transport: transport, policy: policy(debounce: 0.02), observeNetwork: false
        )
        await monitor.configure(config([first, second]))
        await monitor.waitForCurrentProbe()
        let wifi = path(.wifi)
        let cellular = path(.cellular)
        await monitor.networkDidChange(path: wifi)
        await monitor.networkDidChange(path: cellular)
        await monitor.waitForCurrentProbe()
        let afterCellular = await transport.calls
        XCTAssertEqual(afterCellular.count, 4)
        for _ in 0..<14 { await monitor.networkDidChange(path: cellular) }
        await monitor.waitForCurrentProbe()
        let stableCellular = await transport.calls
        XCTAssertEqual(stableCellular.count, 4)
        await monitor.networkDidChange(path: wifi)
        await monitor.waitForCurrentProbe()
        let afterWiFi = await transport.calls
        XCTAssertEqual(afterWiFi.count, 6)
    }

    func testMeaningfulRouteFeaturesInvalidateButEquivalentOrderingDoesNot() async {
        let transport = ProbeFixtureTransport { request in probeReply(request) }
        let monitor = APIHealthMonitor(
            transport: transport, policy: policy(debounce: 0.02), observeNetwork: false
        )
        await monitor.configure(config([first]))
        await monitor.waitForCurrentProbe()
        await monitor.networkDidChange(path: path(.wifi, identifier: "wifi-a"))
        await monitor.networkDidChange(path: path(.wifi, identifier: "wifi-b"))
        await monitor.waitForCurrentProbe()
        let afterInterfaceChange = await transport.calls
        XCTAssertEqual(afterInterfaceChange.count, 2)
        await monitor.networkDidChange(path: path(.wifi, identifier: "wifi-b", constrained: true))
        await monitor.waitForCurrentProbe()
        let afterConstraintChange = await transport.calls
        XCTAssertEqual(afterConstraintChange.count, 3)
        await monitor.networkDidChange(path: path(.wifi, identifier: "wifi-b", constrained: true))
        await monitor.waitForCurrentProbe()
        let afterEquivalent = await transport.calls
        XCTAssertEqual(afterEquivalent.count, 3)
    }

    func testFingerprintIgnoresOrderingAndReportsRouteChangeWithoutGatewayValue() {
        let gatewayA = NWEndpoint.hostPort(host: "192.0.2.1", port: .any)
        let gatewayB = NWEndpoint.hostPort(host: "192.0.2.2", port: .any)
        let firstPath = APIHealthNetworkPath(
            status: .satisfied,
            usedInterfaceTypes: [.wifi, .cellular],
            usedInterfaceIdentifiers: ["wifi", "cell"],
            gateways: [gatewayA, gatewayB]
        )
        let reordered = APIHealthNetworkPath(
            status: .satisfied,
            usedInterfaceTypes: [.cellular, .wifi],
            usedInterfaceIdentifiers: ["cell", "wifi"],
            gateways: [gatewayB, gatewayA]
        )
        XCTAssertEqual(firstPath, reordered)
        let newRoute = APIHealthNetworkPath(
            status: .satisfied, usedInterfaceTypes: [.wifi, .cellular],
            usedInterfaceIdentifiers: ["wifi", "cell"], gateways: [gatewayB]
        )
        let category = newRoute.safeChangedFields(from: firstPath)
        XCTAssertEqual(category, "route")
        XCTAssertFalse(category.contains("192.0.2"))
    }

    func testDisconnectRecoveryAndBriefPathFlappingYieldOneFinalProbe() async {
        let transport = ProbeFixtureTransport { request in probeReply(request) }
        let monitor = APIHealthMonitor(
            transport: transport, policy: policy(debounce: 0.03), observeNetwork: false
        )
        let configured = config([first])
        await monitor.configure(configured)
        await monitor.waitForCurrentProbe()
        let wifi = path(.wifi)
        let offline = path(.wifi, reachable: false)
        await monitor.networkDidChange(path: wifi)
        await monitor.networkDidChange(path: offline)
        let offlineDiagnostic = await monitor.diagnostics()
        XCTAssertTrue(offlineDiagnostic.isEmpty)
        await monitor.networkDidChange(path: wifi)
        await monitor.networkDidChange(path: offline)
        await monitor.networkDidChange(path: wifi)
        await monitor.waitForCurrentProbe()
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 2)
        let recovered = await monitor.diagnostics()
        XCTAssertEqual(recovered.map(\.category), [.healthy])
    }

    func testNetworkChangeInBackgroundWaitsForForeground() async {
        let transport = ProbeFixtureTransport { request in probeReply(request) }
        let monitor = APIHealthMonitor(
            transport: transport, policy: policy(debounce: 0.02), observeNetwork: false
        )
        await monitor.configure(config([first]))
        await monitor.waitForCurrentProbe()
        await monitor.networkDidChange(path: path(.wifi))
        await monitor.setForeground(false)
        await monitor.networkDidChange(path: path(.cellular))
        await monitor.waitForCurrentProbe()
        let inBackground = await transport.calls
        XCTAssertEqual(inBackground.count, 1)
        await monitor.setForeground(true)
        await monitor.waitForCurrentProbe()
        let afterForeground = await transport.calls
        XCTAssertEqual(afterForeground.count, 2)
    }

    func testOldNetworkProbeCannotOverwriteNewPathResult() async {
        let transport = StaleProbeTransport()
        let monitor = APIHealthMonitor(
            transport: transport, policy: policy(debounce: 0.02), observeNetwork: false
        )
        await monitor.configure(config([first]))
        await transport.waitForFirstCall()
        await monitor.networkDidChange(path: path(.wifi))
        await monitor.networkDidChange(path: path(.cellular))
        await monitor.waitForCurrentProbe()
        let diagnostic = await monitor.diagnostics()
        XCTAssertEqual(diagnostic.map(\.category), [.timeout])
        let calls = await transport.calls
        XCTAssertEqual(calls, 2)
    }

    func testBackgroundCancellationAndForegroundResume() async {
        let transport = ProbeFixtureTransport { request in
            try await Task.sleep(for: .milliseconds(100))
            return probeReply(request)
        }
        let monitor = APIHealthMonitor(transport: transport, policy: policy(), observeNetwork: false)
        await monitor.configure(config([first]))
        await Task.yield()
        await monitor.setForeground(false)
        await monitor.setForeground(true)
        await monitor.waitForCurrentProbe()
        let diagnostic = await monitor.diagnostics()
        XCTAssertEqual(diagnostic.map(\.category), [.healthy])
    }

    func testCancellingObservationDoesNotCancelFormalBusinessRequest() async throws {
        let transport = ProbeFixtureTransport { request in
            try await Task.sleep(for: .milliseconds(100))
            return probeReply(request)
        }
        let monitor = APIHealthMonitor(transport: transport, policy: policy(), observeNetwork: false)
        let configured = config([first, second])
        await monitor.configure(configured)
        await Task.yield()
        await monitor.setForeground(false)

        let attempts = AttemptCounter()
        let value: String = try await APIRecoveryRouter().safeRetry(plan: .forAPI(configured)) { route in
            await attempts.increment()
            return route.target
        }
        XCTAssertEqual(value, first)
        let attemptCount = await attempts.value
        XCTAssertEqual(attemptCount, 1)
    }

    func testHealthUpdateDoesNotReplayStartedLoginOrWrite() async throws {
        let transport = ProbeFixtureTransport { request in probeReply(request) }
        let monitor = APIHealthMonitor(transport: transport, policy: policy(), observeNetwork: false)
        let configured = config([first, second])
        await monitor.configure(configured)
        await monitor.waitForCurrentProbe()
        let router = APIRecoveryRouter()
        let attempts = AttemptCounter()
        let result: String = try await router.safeRetry(plan: .forAPI(configured)) { route in
            await attempts.increment()
            await monitor.configure(configured)
            return route.target
        }
        XCTAssertEqual(result, first)
        let readCount = await attempts.value
        XCTAssertEqual(readCount, 1)
        do {
            let _: String = try await router.singleAttemptWrite(
                plan: .forAPI(configured), probe: { _ in }, submit: { _ in
                    await attempts.increment()
                    throw NetworkClientError.transport("unknown result")
                }
            )
            XCTFail("Expected failed write")
        } catch {}
        let totalCount = await attempts.value
        XCTAssertEqual(totalCount, 2)
    }

    func testVisualConfigChangeKeepsHealthWhileAPIChangeInvalidatesIt() async {
        let transport = ProbeFixtureTransport { request in probeReply(request) }
        let monitor = APIHealthMonitor(transport: transport, policy: policy(), observeNetwork: false)
        let firstConfig = config([first], name: "First Fixture")
        let visualOnly = config([first], name: "Second Fixture")
        await monitor.configure(firstConfig)
        await monitor.waitForCurrentProbe()
        await monitor.configure(visualOnly)
        await monitor.waitForCurrentProbe()
        let afterVisual = await transport.calls
        XCTAssertEqual(afterVisual.count, 1)
        let visualDiagnostics = await monitor.diagnostics()
        XCTAssertEqual(visualDiagnostics.map(\.category), [.healthy])

        await monitor.configure(config([second], name: "Second Fixture"))
        await monitor.waitForCurrentProbe()
        let afterAPI = await transport.calls
        XCTAssertEqual(afterAPI.count, 2)
    }
}
