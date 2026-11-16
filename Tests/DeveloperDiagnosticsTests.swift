#if DEBUG
import XCTest
@testable import NetworkClient



private actor DiagnosticFixtureTransport: NetworkTransport {
    enum Behavior { case healthy, timeout, invalid, subscriptionFailure, delayedInvalid }
    let behavior: Behavior
    init(_ behavior: Behavior) { self.behavior = behavior }

    func data(for request: URLRequest, kind: NetworkRequestKind) async throws -> (Data, URLResponse) {
        switch behavior {
        case .healthy:
            return (
                Data(#"{"data":{"is_email_verify":1}}"#.utf8),
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
            )
        case .timeout:
            throw URLError(.timedOut)
        case .invalid:
            return (
                Data("<html>wrong service</html>".utf8),
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "text/html"]
                )!
            )
        case .subscriptionFailure:
            throw URLError(.networkConnectionLost)
        case .delayedInvalid:
            try? await Task.sleep(for: .milliseconds(120))
            return (
                Data("invalid".utf8),
                HTTPURLResponse(
                    url: request.url!, statusCode: 503, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
            )
        }
    }
}

private actor DiagnosticRecoveryRuntime: BuiltInProxyRecoveryRuntimeProtocol {
    enum Mode { case succeeds, fails }
    let mode: Mode
    init(_ mode: Mode) { self.mode = mode }
    func start(endpoint: BuiltInProxyEndpoint) async throws -> BuiltInProxyRecoveryRuntimeInfo {
        if mode == .fails { throw RecoveryRuntimeError.unavailable }
        return BuiltInProxyRecoveryRuntimeInfo(protocolName: "fixture", mixedPort: 1)
    }
    func makeRecoveryTransport() throws -> any NetworkTransport {
        DiagnosticFixtureTransport(.healthy)
    }
    func stopRecovery() async throws {}
}

@MainActor
final class DeveloperDiagnosticsTests: XCTestCase {
    private func config(_ hosts: [String] = ["https://127.0.0.1"]) -> AppConfig {
        AppConfig(
            appName: "Fixture", loginTitle: nil, appLogo: nil, homePage: nil,
            telegramGroup: nil, supportAPI: nil, updateURL: nil,
            userAgent: "Offline-Test", latencyDisplayRatio: 1, inviteLink: nil,
            apiBaseURLs: hosts, activeAPIBaseURL: nil, builtInProxy: []
        )
    }

    private func policy() -> APIHealthPolicy {
        APIHealthPolicy(
            probeTimeout: 0.05, totalBudget: 0.2, healthyTTL: 120,
            retryCooldown: 0, networkDebounce: 0.01, maximumConcurrentProbes: 2
        )
    }

    private func resetShared() async { await DeveloperDiagnostics.shared.clear() }

    private func eventually(
        _ predicate: @escaping ([DeveloperDiagnosticEvent]) -> Bool
    ) async -> [DeveloperDiagnosticEvent] {
        for _ in 0..<80 {
            let events = await DeveloperDiagnostics.shared.currentEvents()
            if predicate(events) { return events }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await DeveloperDiagnostics.shared.currentEvents()
    }

    func testAppConfigLocalMissCreatesUnavailableDiagnosticChain() async throws {
        await resetShared()
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let service = RemoteConfigService(cacheRoot: cacheRoot)
        do {
            _ = try await service.loadLocalConfig()
            XCTFail("A missing local cache must be unavailable")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        let events = await eventually { $0.contains { $0.stage == "local-config" } }
        XCTAssertTrue(events.contains {
            $0.module == .configuration && $0.stage == "local-config" && $0.outcome == "unavailable"
        })
    }

    func testAppConfigRemoteTimeoutRecordsUnavailableStage() async throws {
        await resetShared()
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let service = RemoteConfigService(
            cacheRoot: cacheRoot,
            networkTransport: DiagnosticFixtureTransport(.timeout),
            policy: RemoteConfigRefreshPolicy(
                singleSourceTimeout: 0.01, totalBudget: 0.05,
                failedCooldown: 0, manualCooldown: 0
            )
        )
        do {
            _ = try await service.loadConfig(forceRemote: true)
            XCTFail("Timeout without cache must be unavailable")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        let events = await eventually { $0.contains { $0.outcome == "unavailable" } }
        XCTAssertTrue(events.contains { $0.module == .configuration && $0.outcome == "unavailable" })
    }

    func testAnonymousProbeSuccessRecordsRoundAndCandidate() async {
        await resetShared()
        let monitor = APIHealthMonitor(
            transport: DiagnosticFixtureTransport(.healthy), policy: policy(), observeNetwork: false
        )
        await monitor.configure(config())
        await monitor.waitForCurrentProbe()
        let events = await eventually { $0.contains { $0.stage == "probe-result" } }
        XCTAssertTrue(events.contains { $0.stage == "probe-round" && $0.outcome == "started" })
        XCTAssertTrue(events.contains { $0.stage == "probe-result" && $0.outcome == "healthy" })
    }

    func testAnonymousProbeTimeoutRecordsCategoryAndTimeout() async {
        await resetShared()
        let monitor = APIHealthMonitor(
            transport: DiagnosticFixtureTransport(.timeout), policy: policy(), observeNetwork: false
        )
        await monitor.configure(config())
        await monitor.waitForCurrentProbe()
        let events = await eventually { $0.contains { $0.stage == "probe-result" } }
        XCTAssertTrue(events.contains {
            $0.stage == "probe-result" && $0.outcome == "timeout" && $0.timeoutMilliseconds == 50
        })
    }

    func testRecoverySuccessRecordsDirectFailureAndRecoverySuccess() async throws {
        await resetShared()
        let router = APIRecoveryRouter(recoveryRuntime: DiagnosticRecoveryRuntime(.succeeds), recoveryInitiallySuspendedForFormalVPN: false)
        let ss = "ss://YWVzLTEyOC1nY206cGFzc3dvcmQ@127.0.0.1:8388?type=tcp"
        let result: String = try await router.safeRetry(
            plan: APIRecoveryPlan(targets: ["one"], builtInProxy: [ss])
        ) { route in
            if route.transport == nil { throw NetworkClientError.transport("fixture") }
            return "ok"
        }
        XCTAssertEqual(result, "ok")
        let events = await eventually { $0.contains { $0.outcome == "recovery-success" } }
        XCTAssertTrue(events.contains { $0.outcome == "exhausted" })
        XCTAssertTrue(events.contains { $0.outcome == "recovery-success" })
    }

    func testAllRecoveryPathsFailRecordsTerminalFailure() async {
        await resetShared()
        let router = APIRecoveryRouter(recoveryRuntime: DiagnosticRecoveryRuntime(.fails), recoveryInitiallySuspendedForFormalVPN: false)
        let ss = "ss://YWVzLTEyOC1nY206cGFzc3dvcmQ@127.0.0.1:8388?type=tcp"
        do {
            let _: String = try await router.safeRetry(
                plan: APIRecoveryPlan(targets: ["one"], builtInProxy: [ss])
            ) { _ in throw NetworkClientError.transport("fixture") }
            XCTFail("Expected failure")
        } catch {}
        let events = await eventually { $0.contains { $0.outcome == "all-routes-failed" } }
        XCTAssertTrue(events.contains { $0.outcome == "all-routes-failed" })
    }

    func testProbeCancellationIsRecorded() async {
        await resetShared()
        let monitor = APIHealthMonitor(
            transport: DiagnosticFixtureTransport(.delayedInvalid), policy: policy(), observeNetwork: false
        )
        await monitor.configure(config(["https://127.0.0.1"]))
        await monitor.setForeground(false)
        let events = await eventually { $0.contains { $0.stage == "cache-invalidated" || $0.cancelled } }
        XCTAssertTrue(events.contains { $0.cancelled || $0.stage == "cache-invalidated" })
    }

    func testOldProbeResultIsMarkedSupersededAfterConfigurationChange() async {
        await resetShared()
        let monitor = APIHealthMonitor(
            transport: DiagnosticFixtureTransport(.delayedInvalid), policy: policy(), observeNetwork: false
        )
        await monitor.configure(config(["https://127.0.0.1"]))
        await monitor.configure(config(["https://127.0.0.2"]))
        await monitor.waitForCurrentProbe()
        try? await Task.sleep(for: .milliseconds(150))
        let events = await DeveloperDiagnostics.shared.currentEvents()
        XCTAssertTrue(events.contains { $0.superseded || $0.stage == "cache-invalidated" })
    }

    func testUIErrorMappingAndClearCreateEvents() async {
        await resetShared()
        let model = AppModel(offline: false, initialConfig: config())
        _ = await model.perform(authFeedback: true) {
            throw NetworkClientError.transport("fixture")
        }
        model.clearAuthenticationFeedback()
        let events = await eventually { $0.contains { $0.outcome == "cleared" } }
        XCTAssertTrue(events.contains { $0.stage == "error-to-user-message" })
        XCTAssertTrue(events.contains { $0.stage == "auth-error-state" && $0.outcome == "cleared" })
    }

    func testSubscriptionFailureIsDistinctFromAPIStage() async {
        await resetShared()
        let fetcher = SubscriptionFetcher(transport: DiagnosticFixtureTransport(.subscriptionFailure))
        do {
            _ = try await fetcher.fetchSubscription(
                from: "https://example.invalid/sub?token=private", userAgent: "Fixture"
            )
            XCTFail("Expected failure")
        } catch {}
        let events = await eventually { $0.contains { $0.stage == "yaml-download" && $0.level == .error } }
        XCTAssertTrue(events.contains { $0.module == .subscription && $0.stage == "yaml-download" })
        XCTAssertFalse(events.contains { $0.detail?.contains("private") == true })
    }

    func testBoundedStoreRotatesUnderMaximumSize() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DeveloperDiagnostics(directoryURL: root, maximumBytes: 1_500)
        for index in 0..<30 {
            await store.recordAndWait(.init(
                operationID: "rotation-\(index)", module: .app,
                stage: "payload", outcome: "stored", detail: String(repeating: "x", count: 200)
            ))
        }
        let storedByteCount = await store.storedByteCount()
        let storedEventCount = await store.currentEvents().count
        XCTAssertLessThanOrEqual(storedByteCount, 1_500)
        XCTAssertLessThan(storedEventCount, 30)
    }

    func testDiagnosticsPersistAcrossStoreRestart() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = DeveloperDiagnostics(directoryURL: root)
        await first.recordAndWait(.init(
            operationID: "restart", module: .app, stage: "before", outcome: "stored"
        ))
        let second = DeveloperDiagnostics(directoryURL: root)
        let operationIDs = await second.currentEvents().map(\.operationID)
        XCTAssertEqual(operationIDs, ["restart"])
    }

    func testSensitiveValuesAreRedactedBeforePersistenceAndExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DeveloperDiagnostics(directoryURL: root)
        await store.recordAndWait(.init(
            operationID: "redact", module: .api, stage: "request", outcome: "failed",
            detail: "token=secret https://private.example/path user@example.com"
        ))
        let output = await store.exportText()
        XCTAssertFalse(output.contains("token=secret"))
        XCTAssertFalse(output.contains("private.example"))
        XCTAssertFalse(output.contains("user@example.com"))
    }

    func testRetentionRemovesEventsOlderThanThreeDays() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let store = DeveloperDiagnostics(directoryURL: root, now: { now })
        await store.recordAndWait(.init(
            timestamp: now.addingTimeInterval(-4 * 24 * 60 * 60),
            operationID: "old", module: .app, stage: "old", outcome: "expired"
        ))
        await store.recordAndWait(.init(
            timestamp: now, operationID: "new", module: .app, stage: "new", outcome: "kept"
        ))
        let operationIDs = await store.currentEvents().map(\.operationID)
        XCTAssertEqual(operationIDs, ["new"])
    }

    func testDebugDiagnosticsCompilationContract() async {
        await resetShared()
        await DeveloperDiagnostics.shared.recordAndWait(.init(
            operationID: "debug-contract", module: .app, stage: "compile", outcome: "included"
        ))
        let operationID = await DeveloperDiagnostics.shared.currentEvents().last?.operationID
        XCTAssertEqual(operationID, "debug-contract")
    }

}
#endif


#if DEBUG
import NetworkExtension
@MainActor
final class LastDisconnectDiagnosticPrivacyTests: XCTestCase {
    private struct Fixture {
        let generation = UUID(), operation = UUID(), secretUUID = UUID()
        let poison = ["192.0.2.55", "https://example.invalid/private-fixture", "fixture@example.invalid", "synthetic-token-only"]
        var sensitive: String { (poison + [secretUUID.uuidString]).joined(separator: " ") }
        func event(_ info: [String: Any]) -> DeveloperDiagnosticEvent {
            let value = VPNLastDisconnectError(NSError(domain: NEVPNConnectionErrorDomain, code: 12, userInfo: info))
            // Feed only the finite public-error summary through the unchanged
            // generic event/export path. No old lifecycle observer is involved.
            return DeveloperDiagnosticEvent(operationID: "fixture", module: .vpn,
                stage: "error-mapping", outcome: "failure",
                detail: "domainCategory=\"\(value.domain.rawValue)\" code=\(value.code) category=\"\(value.category.rawValue)\"")
        }
        func assertSafe(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
            for value in poison + [secretUUID.uuidString, generation.uuidString, operation.uuidString] {
                XCTAssertFalse(text.contains(value), file: file, line: line)
            }
        }
    }
    private func json(_ e: DeveloperDiagnosticEvent) throws -> String {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try XCTUnwrap(String(data: encoder.encode(e), encoding: .utf8))
    }
    func testLocalizedDescriptionIsNotPersisted() throws {
        let f = Fixture(); let text = try json(f.event([NSLocalizedDescriptionKey: f.sensitive]))
        f.assertSafe(text); XCTAssertFalse(text.contains("NSLocalizedDescription"))
    }
    func testUserInfoIsNotPersisted() throws {
        let f = Fixture(); let text = try json(f.event(["fixture-private": f.sensitive]))
        f.assertSafe(text); XCTAssertFalse(text.contains("fixture-private"))
    }
    func testUnderlyingErrorIsNeitherPersistedNorUsedToClassifyOuterError() throws {
        let f = Fixture(); let underlying = NSError(domain: f.sensitive, code: 77, userInfo: [NSLocalizedDescriptionKey: f.sensitive])
        let text = try json(f.event([NSUnderlyingErrorKey: underlying]))
        f.assertSafe(text); XCTAssertFalse(text.contains("NSUnderlyingError"))
        XCTAssertTrue(text.contains("provider"))
    }
    func testDynamicDomainIsClassifiedWithoutPersistingItsText() throws {
        let f = Fixture()
        let record = VPNLastDisconnectError(NSError(domain: f.sensitive, code: -9191))
        f.assertSafe(String(reflecting: record)); XCTAssertEqual(record.domain, .unknown); XCTAssertEqual(record.category, .unknown)
    }
    func testExistingEventEncodingRetainsItsOriginalIdentityAndFields() throws {
        let e = DeveloperDiagnosticEvent(operationID: "fixture", module: .vpn, stage: "connect", outcome: "started",
            elapsedMilliseconds: 7, timeoutMilliseconds: 9, httpStatus: 200, urlErrorCode: -999, attempt: 2,
            route: "direct", generation: "1234ABCD", cancelled: true, superseded: true, detail: "fixture")
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let data = try encoder.encode(e)
        XCTAssertEqual(try decoder.decode(DeveloperDiagnosticEvent.self, from: data), e)
    }
    func testCurrentEventsAndExportFileIncludeOnlySafeNewMetadata() async throws {
        let f = Fixture(), directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DeveloperDiagnostics(directoryURL: directory)
        await store.recordAndWait(f.event([NSLocalizedDescriptionKey: f.sensitive, "fixture-private": f.sensitive]))
        let events = await store.currentEvents()
        XCTAssertTrue(events.contains { $0.stage == "error-mapping" && $0.module == .vpn })
        let file = try await store.exportFile(), text = try String(contentsOf: file, encoding: .utf8)
        f.assertSafe(text); XCTAssertTrue(text.contains("error-mapping"))
        XCTAssertTrue(text.contains("domainCategory=\"network-extension\"")); XCTAssertTrue(text.contains("code=12"))
        let jsonl = try String(contentsOf: directory.appendingPathComponent("events.jsonl"), encoding: .utf8)
        f.assertSafe(jsonl)
    }
}
#endif

#if DEBUG
@MainActor
final class PluginFailedDiagnosticTokenTests: XCTestCase {
    private func record(domain: String = NEVPNConnectionErrorDomain, code: Int = 12) -> VPNLastDisconnectError {
        VPNLastDisconnectError(NSError(domain: domain, code: code))
    }
    func testPublicPluginFailedRawValueIsTwelve() {
        XCTAssertEqual(NEVPNConnectionError.pluginFailed.rawValue, 12)
    }
    func testExactPublicDomainAndCodeEmitPluginFailed() {
        let r = record(); XCTAssertEqual(r.connectionError, "plugin-failed"); XCTAssertEqual(r.category, .provider)
    }
    func testOtherPublicCodesNeverEmitPluginFailed() {
        for code in Array(-2...30) + [9999, Int.max] where code != 12 {
            XCTAssertNil(record(code: code).connectionError)
        }
    }
    func testOtherDomainsWithTwelveNeverEmitPluginFailed() {
        for domain in [NEVPNErrorDomain, NSURLErrorDomain, NSPOSIXErrorDomain, NSCocoaErrorDomain, "synthetic-unknown"] {
            XCTAssertNil(record(domain: domain).connectionError)
        }
    }
    func testPluginTokenDoesNotCopyNSErrorText() {
        let value = VPNLastDisconnectError(NSError(domain: NEVPNConnectionErrorDomain,
            code: 12, userInfo: [NSLocalizedDescriptionKey: "synthetic-private-description",
                                NSUnderlyingErrorKey: NSError(domain: "synthetic-underlying", code: 9)]))
        XCTAssertEqual(value.connectionError, "plugin-failed")
        XCTAssertEqual(value.domain, .networkExtension); XCTAssertEqual(value.category, .provider)
        XCTAssertFalse(String(reflecting: value).contains("synthetic-"))
    }
}

#endif
