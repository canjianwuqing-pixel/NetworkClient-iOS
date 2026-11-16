import Foundation
import XCTest
@testable import NetworkClient

final class MihomoRecoveryTests: XCTestCase {
    private let ss = "ss://" + Data("aes-128-gcm:synthetic-only".utf8).base64EncodedString()
        + "@198.51.100.20:443"

    private func vmess(network: String, tls: Bool = true) throws -> String {
        var root: [String: Any] = [
            "v": "2", "add": "198.51.100.21", "port": "443",
            "id": "11111111-1111-4111-8111-111111111111", "aid": "0",
            "scy": "auto", "net": network, "tls": tls ? "tls" : "",
            "sni": "synthetic.example", "alpn": "h2,http/1.1", "fp": "chrome"
        ]
        if network == "ws" {
            root["host"] = "synthetic.example"
            root["path"] = "/recovery"
        } else if network == "grpc" {
            root["path"] = "recovery-service"
        }
        return "vmess://" + (try JSONSerialization.data(withJSONObject: root)).base64EncodedString()
    }

    func testUnsupportedShareFieldsNeverReachCore() async throws {
        let queried = ss + "?unknown=1"
        XCTAssertThrowsError(try BuiltInProxyParser.parse(queried))
        XCTAssertThrowsError(try BuiltInProxyParser.parse(ss + "?plugin=synthetic"))
        var vmess: [String: Any] = [
            "v": "2", "add": "198.51.100.10", "port": "443",
            "id": "11111111-1111-4111-8111-111111111111", "net": "tcp",
            "silent-loss": true,
        ]
        let share = "vmess://" + (try JSONSerialization.data(withJSONObject: vmess)).base64EncodedString()
        let endpoint = try BuiltInProxyParser.parse(share)
        let runtime = MihomoAppRecoveryRuntime()
        do {
            _ = try await runtime.start(endpoint: endpoint)
            XCTFail("Unverified field reached Core")
        } catch is RecoveryMappingError {}
        vmess.removeValue(forKey: "silent-loss")
        XCTAssertEqual(BuiltInProxyParser.parseMany([ss, queried]).count, 1)
    }

    func testShadowsocksTCPImportMetadataUsesTheStrictTCPRecoveryMapping() throws {
        let imported = ss + "?type=tcp#synthetic-name"
        let endpoint = try BuiltInProxyParser.parse(imported)
        XCTAssertFalse(endpoint.normalizedValue.contains("?"))
        XCTAssertFalse(endpoint.normalizedValue.contains("#"))
        let node = try BuiltInProxyBridge.map(endpoint.normalizedValue)
        XCTAssertEqual(node.kind, .shadowsocks)
        XCTAssertEqual(node.network, "tcp")
        XCTAssertThrowsError(try BuiltInProxyParser.parse(ss + "?type=udp"))
        XCTAssertThrowsError(try BuiltInProxyParser.parse(ss + "?type=tcp&unknown=1"))
    }

    func testPinnedCoreReviewedShadowsocksAEADCiphersRemainNarrow() throws {
        for method in ["aes-128-gcm", "aes-256-gcm"] {
            let share = "ss://" + Data("\(method):synthetic-only".utf8).base64EncodedString()
                + "@198.51.100.20:443"
            let node = try BuiltInProxyBridge.map(share)
            XCTAssertEqual(node.kind, .shadowsocks)
            XCTAssertEqual(node.cipher, method)
        }
        for method in ["aes-192-gcm", "chacha20-ietf-poly1305", "rc4-md5"] {
            let share = "ss://" + Data("\(method):synthetic-only".utf8).base64EncodedString()
                + "@198.51.100.20:443"
            XCTAssertThrowsError(try BuiltInProxyBridge.map(share), method)
        }
    }

    func testVMessTCPWebSocketAndGRPCRecoveryMappingsRemainStrict() throws {
        for network in ["tcp", "ws", "grpc"] {
            let share = try vmess(network: network)
            let endpoint = try BuiltInProxyParser.parse(share)
            let node = try BuiltInProxyBridge.map(endpoint.normalizedValue)
            XCTAssertEqual(node.kind, .vmess)
            XCTAssertEqual(node.network, network)
            XCTAssertEqual(node.serverName, "synthetic.example")
            XCTAssertEqual(node.alpn, ["h2", "http/1.1"])
            XCTAssertEqual(node.fingerprint, "chrome")
        }
        XCTAssertThrowsError(try BuiltInProxyParser.parse(try vmess(network: "h2")))
    }

    func testRecoveryStartsOnlyAfterAllDirectCandidatesFail() async throws {
        let runtime = FakeRecoveryRuntime()
        let router = APIRecoveryRouter(recoveryRuntime: runtime, recoveryInitiallySuspendedForFormalVPN: false)
        let result: String = try await router.safeRetry(
            plan: APIRecoveryPlan(
                targets: ["first", "second"],
                builtInProxy: [ss + "?type=tcp#synthetic-name"]
            )
        ) { route in
            if case .normal = route.path { throw NetworkClientError.transport("fixture down") }
            XCTAssertNotNil(route.transport)
            return route.target
        }
        XCTAssertEqual(result, "first")
        let counts = await runtime.counts
        XCTAssertEqual(counts.starts, 1)
        XCTAssertEqual(counts.stops, 1)
    }

    func testRecoveryTransportFailureOnFirstAPITargetContinuesToSecond() async throws {
        let runtime = FakeRecoveryRuntime()
        let router = APIRecoveryRouter(recoveryRuntime: runtime, recoveryInitiallySuspendedForFormalVPN: false)
        let result: String = try await router.safeRetry(
            plan: APIRecoveryPlan(targets: ["first", "second"], builtInProxy: [ss])
        ) { route in
            if case .normal = route.path {
                throw NetworkClientError.transport("fixture down")
            }
            if route.target == "first" { throw URLError(.secureConnectionFailed) }
            return route.target
        }
        XCTAssertEqual(result, "second")
        let counts = await runtime.counts
        XCTAssertEqual(counts.starts, 1)
        XCTAssertEqual(counts.stops, 1)
    }

    func testDirectSuccessNeverStartsRecovery() async throws {
        let runtime = FakeRecoveryRuntime()
        let router = APIRecoveryRouter(recoveryRuntime: runtime, recoveryInitiallySuspendedForFormalVPN: false)
        let result: String = try await router.safeRetry(
            plan: APIRecoveryPlan(targets: ["first"], builtInProxy: [ss])
        ) { route in route.target }
        XCTAssertEqual(result, "first")
        let counts = await runtime.counts
        XCTAssertEqual(counts.starts, 0)
    }

    func testBackgroundStopsAppLocalRecoveryWithoutStartingIt() async {
        let runtime = FakeRecoveryRuntime()
        let router = APIRecoveryRouter(recoveryRuntime: runtime, recoveryInitiallySuspendedForFormalVPN: false)
        await router.setRecoveryForeground(false)
        do {
            let _: String = try await router.safeRetry(
                plan: APIRecoveryPlan(targets: ["first"], builtInProxy: [ss])
            ) { _ in throw NetworkClientError.transport("fixture down") }
            XCTFail("Background request unexpectedly recovered")
        } catch {}
        let counts = await runtime.counts
        XCTAssertEqual(counts.starts, 0)
        XCTAssertEqual(counts.stops, 1)
    }

    func testSystemTunnelEngagementCancelsRecoveryStartBeforeAnyProxiedRequest() async throws {
        let runtime = SuspendedRecoveryRuntime()
        let router = APIRecoveryRouter(recoveryRuntime: runtime, recoveryInitiallySuspendedForFormalVPN: false)
        let counter = RecoverySubmitCounter()
        let plan = APIRecoveryPlan(targets: ["first"], builtInProxy: [ss])
        let task = Task {
            try await router.safeRetry(
                plan: plan
            ) { route -> String in
                if case .normal = route.path { throw NetworkClientError.transport("fixture down") }
                await counter.increment()
                return "unexpected recovery"
            }
        }
        await runtime.waitUntilStarting()
        await router.setRecoveryForeground(false)
        await runtime.finishStart()
        do {
            _ = try await task.value
            XCTFail("Obsolete app-local recovery was allowed inside the system tunnel")
        } catch is CancellationError {
            // The system tunnel invalidated this recovery generation.
        }
        let recoveredRequests = await counter.count
        XCTAssertEqual(recoveredRequests, 0)
        let stopped = await runtime.stopCount
        XCTAssertGreaterThanOrEqual(stopped, 1)
    }

    func testSystemTunnelEngagementNeverSubmitsPendingRecoveredWrite() async throws {
        let runtime = SuspendedRecoveryRuntime()
        let router = APIRecoveryRouter(recoveryRuntime: runtime, recoveryInitiallySuspendedForFormalVPN: false)
        let counter = RecoverySubmitCounter()
        let plan = APIRecoveryPlan(targets: ["first"], builtInProxy: [ss])
        let task = Task {
            try await router.singleAttemptWrite(
                plan: plan,
                probe: { route in
                    if case .normal = route.path { throw NetworkClientError.transport("fixture down") }
                },
                submit: { _ in
                    await counter.increment()
                    return "unexpected submission"
                }
            )
        }
        await runtime.waitUntilStarting()
        await router.setRecoveryForeground(false)
        await runtime.finishStart()
        do {
            _ = try await task.value
            XCTFail("Obsolete recovery submitted a non-idempotent write")
        } catch is CancellationError {}
        let submitted = await counter.count
        XCTAssertEqual(submitted, 0)
    }

    func testRecoveredWriteSubmitsExactlyOnce() async throws {
        let runtime = FakeRecoveryRuntime()
        let counter = RecoverySubmitCounter()
        let router = APIRecoveryRouter(recoveryRuntime: runtime, recoveryInitiallySuspendedForFormalVPN: false)
        let result: String = try await router.singleAttemptWrite(
            plan: APIRecoveryPlan(targets: ["first", "second"], builtInProxy: [ss]),
            probe: { route in
                if case .normal = route.path { throw NetworkClientError.transport("fixture down") }
            },
            submit: { route in
                await counter.increment()
                XCTAssertNotNil(route.transport)
                return "submitted"
            }
        )
        XCTAssertEqual(result, "submitted")
        let submitted = await counter.count
        XCTAssertEqual(submitted, 1)
        let counts = await runtime.counts
        XCTAssertEqual(counts.starts, 1)
        XCTAssertEqual(counts.stops, 1)
    }

    func testConcurrentRecoveriesShareOneRuntimeOwner() async throws {
        let runtime = SerialRecoveryRuntime()
        let router = APIRecoveryRouter(recoveryRuntime: runtime, recoveryInitiallySuspendedForFormalVPN: false)
        let plan = APIRecoveryPlan(targets: ["first"], builtInProxy: [ss])
        async let first: String = router.safeRetry(plan: plan) { route in
            if case .normal = route.path { throw NetworkClientError.transport("fixture down") }
            try await Task.sleep(for: .milliseconds(30))
            return "first"
        }
        async let second: String = router.safeRetry(plan: plan) { route in
            if case .normal = route.path { throw NetworkClientError.transport("fixture down") }
            return "second"
        }
        let values = try await [first, second]
        XCTAssertEqual(Set(values), Set(["first", "second"]))
        let snapshot = await runtime.snapshot
        XCTAssertEqual(snapshot.starts, 2)
        XCTAssertEqual(snapshot.stops, 2)
        XCTAssertEqual(snapshot.maximumActive, 1)
    }

    func testCancelledRuntimeWaiterDoesNotDeadlockNextRecovery() async throws {
        let runtime = SerialRecoveryRuntime()
        let router = APIRecoveryRouter(recoveryRuntime: runtime, recoveryInitiallySuspendedForFormalVPN: false)
        let gate = RecoveryOperationGate()
        let plan = APIRecoveryPlan(targets: ["first"], builtInProxy: [ss])
        let owning = Task {
            try await router.safeRetry(plan: plan) { route -> String in
                if case .normal = route.path { throw NetworkClientError.transport("fixture down") }
                await gate.wait()
                return "owner"
            }
        }
        await runtime.waitForStarts(1)
        let cancelled = Task {
            try await router.safeRetry(plan: plan) { route -> String in
                if case .normal = route.path { throw NetworkClientError.transport("fixture down") }
                return "cancelled"
            }
        }
        let deadline = Date().addingTimeInterval(2)
        while await router.recoveryWaiterCountForTesting() == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let queued = await router.recoveryWaiterCountForTesting()
        XCTAssertEqual(queued, 1)
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled waiter entered recovery")
        } catch is CancellationError {}
        let beforeRelease = await runtime.snapshot
        XCTAssertEqual(beforeRelease.starts, 1)
        let remainingWaiters = await router.recoveryWaiterCountForTesting()
        XCTAssertEqual(remainingWaiters, 0)
        await gate.open()
        let ownerResult = try await owning.value
        XCTAssertEqual(ownerResult, "owner")

        let next: String = try await router.safeRetry(plan: plan) { route in
            if case .normal = route.path { throw NetworkClientError.transport("fixture down") }
            return "next"
        }
        XCTAssertEqual(next, "next")
        let final = await runtime.snapshot
        XCTAssertEqual(final.starts, 2, "Only owner A and the following live request may start")
        XCTAssertEqual(final.maximumActive, 1)
    }

    func testRuntimeWaitIsBoundedWhenOwnerDoesNotFinish() async throws {
        let runtime = SerialRecoveryRuntime()
        let router = APIRecoveryRouter(
            recoveryRuntime: runtime, recoveryInitiallySuspendedForFormalVPN: false, recoveryWaitTimeout: .milliseconds(30)
        )
        let gate = RecoveryOperationGate()
        let plan = APIRecoveryPlan(targets: ["first"], builtInProxy: [ss])
        let owning = Task {
            try await router.safeRetry(plan: plan) { route -> String in
                if case .normal = route.path { throw NetworkClientError.transport("fixture down") }
                await gate.wait()
                return "owner"
            }
        }
        await runtime.waitForStarts(1)
        do {
            let _: String = try await router.safeRetry(plan: plan) { route in
                if case .normal = route.path { throw NetworkClientError.transport("fixture down") }
                return "unexpected"
            }
            XCTFail("A blocked recovery owner caused an unbounded wait")
        } catch let error as NetworkClientError {
            XCTAssertEqual(error.logCategory, "service_unavailable")
        }
        await gate.open()
        let ownerResult = try await owning.value
        XCTAssertEqual(ownerResult, "owner")
    }

    func testCoreCloseFailureBlocksSecondRecoveryEndpoint() async {
        let runtime = StopFailingRecoveryRuntime()
        let router = APIRecoveryRouter(recoveryRuntime: runtime, recoveryInitiallySuspendedForFormalVPN: false)
        let secondSS = "ss://" + Data("aes-128-gcm:synthetic-only".utf8).base64EncodedString()
            + "@198.51.100.22:444"
        do {
            let _: String = try await router.safeRetry(
                plan: APIRecoveryPlan(targets: ["first"], builtInProxy: [ss, secondSS])
            ) { _ in
                throw NetworkClientError.transport("fixture down")
            }
            XCTFail("Expected recovery failure")
        } catch {}
        let starts = await runtime.starts
        XCTAssertEqual(starts, 1)
    }

    func testStartFailureReleasesOwnerBeforeNextEndpoint() async throws {
        let runtime = FirstStartFailingRecoveryRuntime()
        let router = APIRecoveryRouter(recoveryRuntime: runtime, recoveryInitiallySuspendedForFormalVPN: false)
        let secondSS = "ss://" + Data("aes-128-gcm:synthetic-only".utf8).base64EncodedString()
            + "@198.51.100.22:444"
        let result: String = try await router.safeRetry(
            plan: APIRecoveryPlan(targets: ["first"], builtInProxy: [ss, secondSS])
        ) { route in
            if case .normal = route.path { throw NetworkClientError.transport("fixture down") }
            return "recovered"
        }
        XCTAssertEqual(result, "recovered")
        let snapshot = await runtime.snapshot
        XCTAssertEqual(snapshot.starts, 2)
        XCTAssertEqual(snapshot.stops, 2)
    }

    func testVMessEndpointCanDriveTheExistingRecoveryRoute() async throws {
        let runtime = FakeRecoveryRuntime()
        let result: String = try await APIRecoveryRouter(recoveryRuntime: runtime, recoveryInitiallySuspendedForFormalVPN: false).safeRetry(
            plan: APIRecoveryPlan(targets: ["first"], builtInProxy: [try vmess(network: "ws")])
        ) { route in
            if case .normal = route.path { throw NetworkClientError.transport("fixture down") }
            guard case let .builtIn(_, protocolName) = route.path else {
                XCTFail("Expected built-in route")
                return "unexpected"
            }
            XCTAssertEqual(protocolName, "vmess")
            return "recovered"
        }
        XCTAssertEqual(result, "recovered")
        let runtimeCounts = await runtime.counts
        XCTAssertEqual(runtimeCounts.starts, 1)
    }

    func testRemoteConfigurationHTTPRejectionDoesNotStartProxy() async throws {
        let runtime = FakeRecoveryRuntime()
        let direct = RecordingNetworkTransport { request, kind in
            XCTAssertEqual(kind, .remoteConfiguration)
            return (
                Data(), HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil,
                                        headerFields: ["Content-Type": "application/json"])!
            )
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = RemoteConfigService(
            recoveryRouter: APIRecoveryRouter(recoveryRuntime: runtime, recoveryInitiallySuspendedForFormalVPN: false),
            cacheRoot: directory,
            installationID: "rejected-config-fixture", networkTransport: direct
        )
        do {
            _ = try await service.loadConfig(forceRemote: true)
            XCTFail("An HTTP rejection without cache must remain unavailable")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        let directCalls = await direct.calls
        let runtimeCounts = await runtime.counts
        XCTAssertEqual(directCalls.count, 1)
        XCTAssertEqual(runtimeCounts.starts, 0)
    }

    func testInvalidRemoteConfigurationDoesNotStartProxyOrTryAnotherSource() async throws {
        let runtime = FakeRecoveryRuntime()
        let direct = RecordingNetworkTransport { request, kind in
            XCTAssertEqual(kind, .remoteConfiguration)
            return (
                Data(#"{"AppName":"","ApiBaseUrls":[]}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"])!
            )
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = RemoteConfigService(
            recoveryRouter: APIRecoveryRouter(recoveryRuntime: runtime, recoveryInitiallySuspendedForFormalVPN: false),
            cacheRoot: directory,
            installationID: "invalid-config-fixture", networkTransport: direct
        )
        do {
            _ = try await service.loadConfig(forceRemote: true)
            XCTFail("Invalid remote business configuration must remain unavailable")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        let directCalls = await direct.calls
        let runtimeCounts = await runtime.counts
        XCTAssertEqual(directCalls.count, 1)
        XCTAssertEqual(runtimeCounts.starts, 0)
    }

    func testFirstInstallWithoutTrustedCacheCannotStartRecovery() async throws {
        let recovery = FakeRecoveryRuntime()
        let router = APIRecoveryRouter(recoveryRuntime: recovery, recoveryInitiallySuspendedForFormalVPN: false)
        let direct = RecordingNetworkTransport { _, _ in
            throw URLError(.notConnectedToInternet)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = RemoteConfigService(
            recoveryRouter: router, cacheRoot: directory,
            installationID: "synthetic-first-install", networkTransport: direct
        )
        do {
            _ = try await service.loadConfig(forceRemote: true)
            XCTFail("First install has no trusted recovery endpoints")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        let counts = await recovery.counts
        XCTAssertEqual(counts.starts, 0)
        XCTAssertEqual(counts.stops, 0)
    }

    private var cancellationCandidates: [String] {
        [ss, ss.replacingOccurrences(of: "198.51.100.20", with: "198.51.100.21")]
    }

    func testCancellationDirectAPIDoesNotEnterRecovery() async {
        let direct = RecordingNetworkTransport { _, _ in throw URLError(.cancelled) }
        let runtime = FakeRecoveryRuntime()
        let api = V2BoardAPIClient(
            recoveryRouter: APIRecoveryRouter(recoveryRuntime: runtime, recoveryInitiallySuspendedForFormalVPN: false), transport: direct
        )
        let config = AppConfig(
            appName: "Fixture", loginTitle: nil, appLogo: nil, homePage: nil,
            telegramGroup: nil, supportAPI: nil, updateURL: nil,
            userAgent: "NetworkClient-Test", latencyDisplayRatio: 1,
            inviteLink: nil, apiBaseURLs: ["https://127.0.0.1", "https://127.0.0.2"],
            activeAPIBaseURL: nil, builtInProxy: cancellationCandidates
        )
        do {
            _ = try await api.fetchRegistrationConfig(config: config)
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch { XCTFail("Expected CancellationError, got \(type(of: error))") }
        let calls = await direct.calls
        let counts = await runtime.counts
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(counts.starts, 0)
    }

    func testCancellationSubscriptionDirectDoesNotEnterRecovery() async {
        let direct = RecordingNetworkTransport { _, _ in throw URLError(.cancelled) }
        let runtime = FakeRecoveryRuntime()
        let fetcher = SubscriptionFetcher(
            transport: direct, recoveryRouter: APIRecoveryRouter(recoveryRuntime: runtime, recoveryInitiallySuspendedForFormalVPN: false)
        )
        do {
            _ = try await fetcher.fetchSubscription(
                from: "https://subscription.example.invalid/synthetic",
                userAgent: "NetworkClient-Test", builtInProxy: cancellationCandidates
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch { XCTFail("Expected CancellationError") }
        let calls = await direct.calls
        let counts = await runtime.counts
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(counts.starts, 0)
    }

    func testCancellationBeforeNextHostStopsReadAndWritePreflight() async throws {
        for write in [false, true] {
            let runtime = FakeRecoveryRuntime()
        let router = APIRecoveryRouter(recoveryRuntime: runtime, recoveryInitiallySuspendedForFormalVPN: false)
            let attempts = RecoverySubmitCounter()
            let submissions = RecoverySubmitCounter()
            let plan = APIRecoveryPlan(targets: ["host-a", "host-b"], builtInProxy: cancellationCandidates)
            let operation: APIRecoveryRouter.Operation<Void> = { _ in
                await attempts.increment()
                withUnsafeCurrentTask { $0?.cancel() }
                // Deliberately omit lower-layer cancellation normalization.
                throw NetworkClientError.transport("synthetic failure")
            }
            let task = Task {
                if write {
                    return try await router.singleAttemptWrite(plan: plan, probe: operation) { _ in
                        await submissions.increment()
                    }
                }
                return try await router.safeRetry(plan: plan, operation: operation)
            }
            do {
                try await task.value
                XCTFail("Expected cancellation")
            } catch is CancellationError {}
            let attempted = await attempts.count
            let submitted = await submissions.count
            let counts = await runtime.counts
            XCTAssertEqual(attempted, 1)
            XCTAssertEqual(submitted, 0)
            XCTAssertEqual(counts.starts, 0)
        }
    }

    func testCancellationBetweenRecoveryCandidatesStopsReadAndWritePreflight() async throws {
        for write in [false, true] {
            let runtime = CancellationRecoveryRuntime(
                transport: FakeRecoveryTransport(payload: nil), cancelOnStop: true
            )
        let router = APIRecoveryRouter(recoveryRuntime: runtime, recoveryInitiallySuspendedForFormalVPN: false)
            let attempts = RecoverySubmitCounter()
            let plan = APIRecoveryPlan(targets: ["host-a"], builtInProxy: cancellationCandidates)
            let operation: APIRecoveryRouter.Operation<Void> = { route in
                if case .normal = route.path { throw NetworkClientError.transport("direct down") }
                await attempts.increment()
                throw NetworkClientError.transport("candidate A down")
            }
            let task = Task {
                if write {
                    return try await router.singleAttemptWrite(plan: plan, probe: operation) { _ in
                        XCTFail("Cancelled preflight must not submit")
                    }
                }
                return try await router.safeRetry(plan: plan, operation: operation)
            }
            do {
                try await task.value
                XCTFail("Expected cancellation")
            } catch is CancellationError {}
            let attempted = await attempts.count
            let counts = await runtime.counts
            XCTAssertEqual(attempted, 1)
            XCTAssertEqual(counts.starts, 1)
        }
    }

    func testCancellationRawRouterURLErrorDoesNotFailOver() async {
        let runtime = FakeRecoveryRuntime()
        let router = APIRecoveryRouter(recoveryRuntime: runtime, recoveryInitiallySuspendedForFormalVPN: false)
        let attempts = RecoverySubmitCounter()
        do {
            let _: String = try await router.safeRetry(plan: APIRecoveryPlan(
                targets: ["host-a", "host-b"], builtInProxy: cancellationCandidates
            )) { _ in
                await attempts.increment()
                throw URLError(.cancelled)
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch { XCTFail("Expected CancellationError") }
        let attempted = await attempts.count
        let counts = await runtime.counts
        XCTAssertEqual(attempted, 1)
        XCTAssertEqual(counts.starts, 0)
    }

    func testCancellationLogoutDuringSubscriptionRecoveryDoesNotReturnNetworkError() async throws {
        let entered = RecoveryOperationGate()
        let release = RecoveryOperationGate()
        let direct = RecordingNetworkTransport { _, _ in throw URLError(.cannotConnectToHost) }
        let recovered = RecordingNetworkTransport { _, _ in
            await entered.open()
            await release.wait()
            // A non-cooperative transport returns a network error after Logout.
            throw URLError(.networkConnectionLost)
        }
        let runtime = CancellationRecoveryRuntime(transport: recovered)
        let fetcher = SubscriptionFetcher(
            transport: direct, recoveryRouter: APIRecoveryRouter(recoveryRuntime: runtime, recoveryInitiallySuspendedForFormalVPN: false)
        )
        let candidates = cancellationCandidates
        let accountATask = Task {
            try await fetcher.fetchSubscription(
                from: "https://subscription.example.invalid/synthetic",
                userAgent: "NetworkClient-Test", builtInProxy: candidates
            )
        }
        await entered.wait()
        accountATask.cancel() // The same Task cancellation boundary used by Logout.
        await release.open()
        do {
            _ = try await accountATask.value
            XCTFail("Cancelled account task returned business data")
        } catch is CancellationError {}
        let calls = await recovered.calls
        let counts = await runtime.counts
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(counts.starts, 1)
        XCTAssertEqual(counts.stops, 1)
    }

    func testCancellationDuringBatchQuiesceNeverStartsCore() async throws {
        let core = CancellationTestCore()
        let runtime = MihomoAppRecoveryRuntime(core: core)
        await runtime.beginBatchForCancellationTesting()
        let endpoint = try BuiltInProxyParser.parse(ss)
        let task = Task { try await runtime.start(endpoint: endpoint) }
        let deadline = Date().addingTimeInterval(2)
        while await runtime.batchDrainWaiterCountForTesting() == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let waiting = await runtime.batchDrainWaiterCountForTesting()
        XCTAssertEqual(waiting, 1)
        task.cancel()
        await runtime.finishBatchForCancellationTesting()
        do {
            _ = try await task.value
            XCTFail("Cancelled quiesce waiter started Core")
        } catch is CancellationError {}
        XCTAssertEqual(core.counts.setups, 0)
        XCTAssertEqual(core.counts.starts, 0)
        let snapshot = await runtime.snapshot()
        XCTAssertFalse(snapshot.running)
        XCTAssertNil(snapshot.loopbackPort)
    }

    func testCancellationDuringSynchronousStartupCleansUpBeforeReturning() async throws {
        let core = CancellationTestCore(blockStartup: true)
        let runtime = MihomoAppRecoveryRuntime(core: core)
        let endpoint = try BuiltInProxyParser.parse(ss)
        let task = Task { try await runtime.start(endpoint: endpoint) }
        await fulfillment(of: [core.startEntered], timeout: 3)
        task.cancel()
        core.releaseStartup()
        do {
            _ = try await task.value
            XCTFail("Cancelled synchronous startup returned success")
        } catch is CancellationError {}
        XCTAssertEqual(core.counts.starts, 1)
        XCTAssertEqual(core.counts.closes, 1)
        XCTAssertFalse(core.hasService)
        let snapshot = await runtime.snapshot()
        XCTAssertFalse(snapshot.running)
        XCTAssertNil(snapshot.loopbackPort)
        do {
            _ = try await runtime.makeRecoveryTransport()
            XCTFail("Cancelled startup published a transport")
        } catch {}
    }

    func testCancellationHardeningPreservesTimeoutAndDNSRecovery() async throws {
        for code in [URLError.Code.timedOut, .dnsLookupFailed] {
            let runtime = FakeRecoveryRuntime()
        let router = APIRecoveryRouter(recoveryRuntime: runtime, recoveryInitiallySuspendedForFormalVPN: false)
            let attempts = RecoverySubmitCounter()
            let result: String = try await router.safeRetry(plan: APIRecoveryPlan(
                targets: ["host-a", "host-b"], builtInProxy: cancellationCandidates
            )) { route in
                await attempts.increment()
                if case .normal = route.path { throw URLError(code) }
                return "recovered"
            }
            let attempted = await attempts.count
            let counts = await runtime.counts
            XCTAssertEqual(result, "recovered")
            XCTAssertEqual(attempted, 3)
            XCTAssertEqual(counts.starts, 1)
        }
    }

    func testCancellationSubscriptionRecoveryDoesNotTrySecondCandidate() async {
        let direct = RecordingNetworkTransport { _, _ in throw URLError(.cannotConnectToHost) }
        let recovered = RecordingNetworkTransport { _, _ in throw URLError(.cancelled) }
        let runtime = CancellationRecoveryRuntime(transport: recovered)
        let fetcher = SubscriptionFetcher(
            transport: direct, recoveryRouter: APIRecoveryRouter(recoveryRuntime: runtime, recoveryInitiallySuspendedForFormalVPN: false)
        )
        do {
            _ = try await fetcher.fetchSubscription(
                from: "https://subscription.example.invalid/synthetic",
                userAgent: "NetworkClient-Test", builtInProxy: [
                    ss, ss.replacingOccurrences(of: "198.51.100.20", with: "198.51.100.21")
                ]
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(type(of: error))")
        }
        let calls = await recovered.calls
        let counts = await runtime.counts
        XCTAssertEqual(calls.count, 1, "Cancellation must not send a second recovery request")
        XCTAssertEqual(counts.starts, 1, "Cancellation must not start candidate B")
        XCTAssertEqual(counts.stops, 1)
    }

    func testSubscriptionRecoveryRunsOnlyAfterBoundedDirectNetworkFailures() async throws {
        let direct = RecordingNetworkTransport { _, kind in
            XCTAssertEqual(kind, .subscription)
            throw URLError(.timedOut)
        }
        let runtime = FakeRecoveryRuntime(payload: Data("proxies: []".utf8))
        let router = APIRecoveryRouter(recoveryRuntime: runtime, recoveryInitiallySuspendedForFormalVPN: false)
        let fetcher = SubscriptionFetcher(transport: direct, recoveryRouter: router)
        let result = try await fetcher.fetchSubscription(
            from: "https://subscription.example.invalid/synthetic",
            userAgent: "NetworkClient-Test", builtInProxy: [ss]
        )
        XCTAssertEqual(result, "proxies: []")
        let directCalls = await direct.calls
        XCTAssertEqual(directCalls.count, 2)
        let counts = await runtime.counts
        XCTAssertEqual(counts.starts, 1)
        XCTAssertEqual(counts.stops, 1)
    }

    func testFormalVPNGateDefaultsFailClosedForReadAndWriteButPreservesPrimarySuccess() async throws {
        let runtime = FakeRecoveryRuntime()
        let router = APIRecoveryRouter(recoveryRuntime: runtime)
        let plan = APIRecoveryPlan(targets: ["primary"], builtInProxy: [ss])

        let direct: String = try await router.safeRetry(plan: plan) { route in
            XCTAssertEqual(route.path, .normal)
            return "primary-success"
        }
        XCTAssertEqual(direct, "primary-success")

        do {
            let _: String = try await router.safeRetry(plan: plan) { _ in
                throw NetworkClientError.transport("primary down")
            }
            XCTFail("Unknown formal VPN state must fail closed for reads")
        } catch let error as NetworkClientError {
            XCTAssertEqual(error.logCategory, "transport")
        }

        do {
            let _: String = try await router.singleAttemptWrite(
                plan: plan,
                probe: { _ in throw NetworkClientError.transport("primary down") },
                submit: { _ in "must not submit" }
            )
            XCTFail("Unknown formal VPN state must fail closed for writes")
        } catch let error as NetworkClientError {
            XCTAssertEqual(error.logCategory, "transport")
        }

        let counts = await runtime.counts
        XCTAssertEqual(counts.starts, 0)
        XCTAssertEqual(counts.stops, 0)
    }

    func testExplicitDisconnectedReopensReadAndWriteRecovery() async throws {
        let runtime = FakeRecoveryRuntime()
        let router = APIRecoveryRouter(recoveryRuntime: runtime)
        await router.finishSystemVPNTakeover(keepSuspended: false)
        let plan = APIRecoveryPlan(targets: ["primary"], builtInProxy: [ss])

        let read: String = try await router.safeRetry(plan: plan) { route in
            if route.path == .normal { throw NetworkClientError.transport("primary down") }
            return "read-recovered"
        }
        let write: String = try await router.singleAttemptWrite(
            plan: plan,
            probe: { route in
                if route.path == .normal { throw NetworkClientError.transport("primary down") }
            },
            submit: { _ in "write-recovered" }
        )

        XCTAssertEqual(read, "read-recovered")
        XCTAssertEqual(write, "write-recovered")
        let counts = await runtime.counts
        XCTAssertEqual(counts.starts, 2)
        XCTAssertEqual(counts.stops, 2)
    }

    func testFormalVPNTakeoverCancelsQueuedRecoveryAndDrainsActiveRequest() async throws {
        let runtime = FakeRecoveryRuntime()
        let router = APIRecoveryRouter(
            recoveryRuntime: runtime,
            recoveryInitiallySuspendedForFormalVPN: false
        )
        let operationGate = RecoveryOperationGate()
        let entered = expectation(description: "active recovery request entered")
        let closeCompleted = RecoverySubmitCounter()
        let plan = APIRecoveryPlan(targets: ["primary"], builtInProxy: [ss])

        let active = Task {
            try await router.safeRetry(plan: plan) { route -> String in
                if route.path == .normal { throw NetworkClientError.transport("primary down") }
                entered.fulfill()
                await operationGate.wait()
                return "stale recovery"
            }
        }
        await fulfillment(of: [entered], timeout: 2)

        let queued = Task {
            try await router.safeRetry(plan: plan) { route -> String in
                if route.path == .normal { throw NetworkClientError.transport("primary down") }
                return "queued recovery"
            }
        }
        let deadline = Date().addingTimeInterval(2)
        while await router.recoveryWaiterCountForTesting() == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let queuedCount = await router.recoveryWaiterCountForTesting()
        XCTAssertEqual(queuedCount, 1)

        await router.beginSystemVPNTakeover()
        let close = Task {
            try await router.closeRecoveryForSystemVPN()
            await closeCompleted.increment()
        }
        try await Task.sleep(for: .milliseconds(20))
        let completedBeforeDrain = await closeCompleted.count
        XCTAssertEqual(completedBeforeDrain, 0, "Close cannot complete before the active request drains")

        do { _ = try await queued.value; XCTFail("Queued recovery must be rejected") }
        catch is CancellationError {}
        await operationGate.open()
        try await close.value
        let completedAfterDrain = await closeCompleted.count
        XCTAssertEqual(completedAfterDrain, 1)
        do { _ = try await active.value; XCTFail("The old recovery result must not escape takeover") }
        catch is CancellationError {}

        let counts = await runtime.counts
        XCTAssertEqual(counts.starts, 1)
        XCTAssertGreaterThanOrEqual(counts.stops, 1)
    }

    func testUnconfirmedRecoveryCloseKeepsFormalVPNTakeoverBlocked() async {
        let runtime = StopFailingRecoveryRuntime()
        let router = APIRecoveryRouter(
            recoveryRuntime: runtime,
            recoveryInitiallySuspendedForFormalVPN: false
        )
        await router.beginSystemVPNTakeover()
        do {
            try await router.closeRecoveryForSystemVPN()
            XCTFail("An unconfirmed Core close must be observable")
        } catch let error as TunnelDiagnostic {
            XCTAssertEqual(error.code, .recoveryCloseUnconfirmed)
        } catch {
            XCTFail("Unexpected close error: \(type(of: error))")
        }
        let state = await router.takeoverStateForTesting()
        XCTAssertTrue(state.suspended)
        XCTAssertTrue(state.cleanupBlocked)
        let starts = await runtime.starts
        XCTAssertEqual(starts, 0)
    }

    func testRemoteConfigPrimaryFailureCannotStartRecoveryWhileFormalVPNStateIsUnknown() async throws {
        let runtime = FakeRecoveryRuntime()
        let direct = RecordingNetworkTransport { _, _ in
            throw URLError(.notConnectedToInternet)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = RemoteConfigService(
            recoveryRouter: APIRecoveryRouter(recoveryRuntime: runtime),
            cacheRoot: directory,
            installationID: "formal-vpn-gate-fixture",
            networkTransport: direct
        )

        do {
            _ = try await service.loadConfig(forceRemote: true)
            XCTFail("No trusted configuration is available")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        let counts = await runtime.counts
        XCTAssertEqual(counts.starts, 0)
    }
}

private actor RecoverySubmitCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

actor CancellationRecoveryRuntime: BuiltInProxyRecoveryRuntimeProtocol {
    private let transport: any NetworkTransport
    private let cancelOnStop: Bool
    private var starts = 0
    private var stops = 0
    var counts: (starts: Int, stops: Int) { (starts, stops) }

    init(transport: any NetworkTransport, cancelOnStop: Bool = false) {
        self.transport = transport
        self.cancelOnStop = cancelOnStop
    }

    func start(endpoint: BuiltInProxyEndpoint) -> BuiltInProxyRecoveryRuntimeInfo {
        starts += 1
        return BuiltInProxyRecoveryRuntimeInfo(protocolName: endpoint.protocolName, mixedPort: 1)
    }
    func makeRecoveryTransport() -> any NetworkTransport { transport }
    func stopRecovery() {
        stops += 1
        if cancelOnStop { withUnsafeCurrentTask { $0?.cancel() } }
    }
}

/// Only the fake synchronous SDK boundary blocks. No real Core or worker
/// thread is created; the runtime keeps its existing actor and cleanup path.
private final class CancellationTestCore: MihomoRecoveryCore, @unchecked Sendable {
    let startEntered = XCTestExpectation(description: "synchronous start entered")
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private let blockStartup: Bool
    private let afterStart: @Sendable () -> Void
    private var service = false
    private var setups = 0
    private var starts = 0
    private var closes = 0

    init(blockStartup: Bool = false, afterStart: @escaping @Sendable () -> Void = {}) {
        self.blockStartup = blockStartup
        self.afterStart = afterStart
    }
    var hasService: Bool { lock.withLock { service } }
    var isRunning: Bool { hasService }
    var counts: (setups: Int, starts: Int, closes: Int) {
        lock.withLock { (setups, starts, closes) }
    }
    func setup(in base: URL, cache: URL) -> Int {
        lock.withLock { setups += 1 }
        return 0
    }
    func start(yaml: String) throws -> (configMS: Int, serviceStartMS: Int) {
        lock.withLock { starts += 1 }
        startEntered.fulfill()
        if blockStartup, release.wait(timeout: .now() + 5) == .timedOut {
            throw MihomoCoreFailure("synthetic-start-timeout", nil)
        }
        lock.withLock { service = true }
        afterStart()
        return (0, 0)
    }
    func releaseStartup() { release.signal() }
    func stop() -> MihomoCoreFailure? {
        lock.withLock {
            if service { closes += 1 }
            service = false
        }
        return nil
    }
    func httpDelay(proxyName: String) -> Int { 0 }
}

private actor FakeRecoveryRuntime: BuiltInProxyRecoveryRuntimeProtocol {
    private var starts = 0
    private var stops = 0
    private let payload: Data?
    var counts: (starts: Int, stops: Int) { (starts, stops) }

    init(payload: Data? = nil) { self.payload = payload }

    func start(endpoint: BuiltInProxyEndpoint) -> BuiltInProxyRecoveryRuntimeInfo {
        starts += 1
        return BuiltInProxyRecoveryRuntimeInfo(protocolName: endpoint.protocolName, mixedPort: 1)
    }
    func makeRecoveryTransport() -> any NetworkTransport { FakeRecoveryTransport(payload: payload) }
    func stopRecovery() { stops += 1 }
}

private actor SuspendedRecoveryRuntime: BuiltInProxyRecoveryRuntimeProtocol {
    private var starting = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var startContinuation: CheckedContinuation<Void, Never>?
    private(set) var stopCount = 0

    func start(endpoint: BuiltInProxyEndpoint) async -> BuiltInProxyRecoveryRuntimeInfo {
        starting = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { startContinuation = $0 }
        return BuiltInProxyRecoveryRuntimeInfo(protocolName: endpoint.protocolName, mixedPort: 1)
    }

    func waitUntilStarting() async {
        if starting { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func finishStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func makeRecoveryTransport() -> any NetworkTransport { FakeRecoveryTransport(payload: nil) }
    func stopRecovery() { stopCount += 1 }
}

private actor SerialRecoveryRuntime: BuiltInProxyRecoveryRuntimeProtocol {
    private var startCount = 0
    private var stopCount = 0
    private var active = 0
    private var maximum = 0

    var snapshot: (starts: Int, stops: Int, maximumActive: Int) {
        (startCount, stopCount, maximum)
    }

    func start(endpoint: BuiltInProxyEndpoint) -> BuiltInProxyRecoveryRuntimeInfo {
        startCount += 1
        active += 1
        maximum = max(maximum, active)
        return BuiltInProxyRecoveryRuntimeInfo(protocolName: endpoint.protocolName, mixedPort: 1)
    }

    func makeRecoveryTransport() -> any NetworkTransport {
        FakeRecoveryTransport(payload: nil)
    }

    func stopRecovery() {
        stopCount += 1
        active = max(0, active - 1)
    }

    func waitForStarts(_ count: Int) async {
        while startCount < count { await Task.yield() }
    }
}

private actor StopFailingRecoveryRuntime: BuiltInProxyRecoveryRuntimeProtocol {
    private(set) var starts = 0

    func start(endpoint: BuiltInProxyEndpoint) -> BuiltInProxyRecoveryRuntimeInfo {
        starts += 1
        return BuiltInProxyRecoveryRuntimeInfo(protocolName: endpoint.protocolName, mixedPort: 1)
    }

    func makeRecoveryTransport() -> any NetworkTransport {
        FakeRecoveryTransport(payload: nil)
    }

    func stopRecovery() throws {
        throw RecoveryRuntimeError.stopFailed
    }
}

private actor FirstStartFailingRecoveryRuntime: BuiltInProxyRecoveryRuntimeProtocol {
    private var startCount = 0
    private var stopCount = 0
    var snapshot: (starts: Int, stops: Int) { (startCount, stopCount) }

    func start(endpoint: BuiltInProxyEndpoint) throws -> BuiltInProxyRecoveryRuntimeInfo {
        startCount += 1
        if startCount == 1 { throw RecoveryRuntimeError.unavailable }
        return BuiltInProxyRecoveryRuntimeInfo(protocolName: endpoint.protocolName, mixedPort: 1)
    }

    func makeRecoveryTransport() -> any NetworkTransport {
        FakeRecoveryTransport(payload: nil)
    }

    func stopRecovery() {
        stopCount += 1
    }
}

actor RecoveryOperationGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private struct FakeRecoveryTransport: NetworkTransport {
    let payload: Data?

    func data(for request: URLRequest, kind: NetworkRequestKind) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (payload ?? Data(), response)
    }
}

final class OperationBudgetTests: XCTestCase {
    private let ss = "ss://" + Data("aes-128-gcm:synthetic-only".utf8).base64EncodedString()
        + "@198.51.100.20:443"
    private var candidates: [String] { [ss, ss.replacingOccurrences(of: ".20:", with: ".21:")] }

    private func expectTimeout<T>(_ operation: () async throws -> T) async {
        do { _ = try await operation(); XCTFail("Expected operation timeout") }
        catch NetworkClientError.timedOut {}
        catch { XCTFail("Expected timeout, got \(type(of: error))") }
    }

    func testReadTimeoutThenFastBackupSucceeds() async throws {
        let clock = BudgetTestClock()
        let transport = RecordingNetworkTransport { request, _ in
            if request.url!.host == "127.0.0.1" {
                clock.advance(.seconds(25)); throw URLError(.timedOut)
            }
            clock.advance(.seconds(1))
            return (Data(#"{"data":[]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        }
        let value = try await budgetTestAPI(clock: clock, transport: transport)
            .fetchPaymentMethods(config: budgetTestConfig(), session: budgetTestSession())
        let calls = await transport.calls
        XCTAssertTrue(value.isEmpty)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[1].timeout, 5)
        XCTAssertEqual(clock.now, .seconds(26))
        XCTAssertEqual(clock.sleeperCount, 0)
    }

    func testInsufficientRemainingBudgetNeverEntersRecovery() async {
        let clock = BudgetTestClock()
        let runtime = BudgetRecoveryRuntime()
        let router = APIRecoveryRouter(recoveryRuntime: runtime, recoveryInitiallySuspendedForFormalVPN: false, clock: clock.clock)
        await expectTimeout {
            try await router.safeRetry(plan: APIRecoveryPlan(targets: ["A"], builtInProxy: self.candidates)) { _ -> String in
                clock.advance(.milliseconds(29_500)); throw URLError(.timedOut)
            }
        }
        let counts = await runtime.counts
        XCTAssertEqual(counts.starts, 0)
    }

    func testQueueUsesRemainingBudgetAndRemovesTimedOutWaiter() async throws {
        let clock = BudgetTestClock()
        let runtime = BudgetRecoveryRuntime()
        let router = APIRecoveryRouter(recoveryRuntime: runtime, recoveryInitiallySuspendedForFormalVPN: false, clock: clock.clock)
        let ownerEntered = expectation(description: "owner has Core")
        let ownerGate = RecoveryOperationGate()
        let plan = APIRecoveryPlan(targets: ["A"], builtInProxy: [ss])
        let owner = Task {
            try await router.safeRetry(plan: plan, directAlreadyExhausted: .timedOut, budget: .seconds(120)) { _ in
                ownerEntered.fulfill(); await ownerGate.wait(); return "owner"
            }
        }
        await fulfillment(of: [ownerEntered], timeout: 2)
        let queueEntered = expectation(description: "six second queue timer installed")
        clock.notifySleep(at: .seconds(6), queueEntered)
        let waiter = Task {
            try await router.safeRetry(plan: plan, directAlreadyExhausted: .timedOut,
                budget: .seconds(6)) { _ in "must not run" }
        }
        await fulfillment(of: [queueEntered], timeout: 2)
        let before = await router.recoveryWaiterCountForTesting()
        XCTAssertEqual(before, 1)
        clock.advance(.seconds(6))
        await expectTimeout { try await waiter.value }
        let after = await router.recoveryWaiterCountForTesting()
        XCTAssertEqual(after, 0)
        await ownerGate.open()
        _ = try await owner.value
        let counts = await runtime.counts
        XCTAssertEqual(counts.starts, 1)
        XCTAssertEqual(clock.sleeperCount, 0)
    }

    func testExpiredRecoveryHTTPDoesNotTryNextCandidate() async {
        let clock = BudgetTestClock()
        let runtime = BudgetRecoveryRuntime()
        let router = APIRecoveryRouter(recoveryRuntime: runtime, recoveryInitiallySuspendedForFormalVPN: false, clock: clock.clock)
        await expectTimeout {
            try await router.safeRetry(plan: APIRecoveryPlan(targets: ["A", "B"], builtInProxy: self.candidates),
                directAlreadyExhausted: .timedOut) { _ -> String in
                clock.advance(.seconds(30)); throw URLError(.timedOut)
            }
        }
        let counts = await runtime.counts
        XCTAssertEqual(counts.starts, 1)
        XCTAssertEqual(counts.stops, 1)
    }

    func testProbePolicyHasDedicatedFourSecondRequestAndResourceTimeout() {
        XCTAssertEqual(NetworkTransportPolicy.requestTimeout(for: .writeRouteProbe), 4)
        let config = NetworkTransportPolicy.configuration(for: .writeRouteProbe)
        XCTAssertEqual(config.timeoutIntervalForRequest, 4)
        XCTAssertEqual(config.timeoutIntervalForResource, 4)
        XCTAssertEqual(NetworkTransportPolicy.requestTimeout(for: .apiRead), 25)
        XCTAssertEqual(NetworkTransportPolicy.configuration(for: .subscription).timeoutIntervalForResource, 90)
    }

    func testProbeFindsRouteAndSubmitsExactlyOnce() async throws {
        let clock = BudgetTestClock()
        let transport = RecordingNetworkTransport { request, kind in
            if kind == .writeRouteProbe {
                XCTAssertEqual(request.httpMethod, "GET")
                if request.url!.host == "127.0.0.1" {
                    clock.advance(.seconds(4)); throw URLError(.timedOut)
                }
                return (Data(#"{"data":{}}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
            }
            return (Data(#"{"type":1,"data":"synthetic-payment"}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        }
        let result = try await budgetTestAPI(clock: clock, transport: transport).checkoutOrder(
            config: budgetTestConfig(), session: budgetTestSession(), tradeNo: "synthetic", methodID: 1)
        let calls = await transport.calls
        XCTAssertEqual(result.data, "synthetic-payment")
        XCTAssertEqual(calls.map(\.kind), [.writeRouteProbe, .writeRouteProbe, .apiWrite])
        XCTAssertEqual(calls.last?.host, "127.0.0.2")
    }

    func testWritePreSubmitDeadlineStopsWithoutSubmitting() async {
        let clock = BudgetTestClock()
        let submits = RecoverySubmitCounter()
        let probes = RecoverySubmitCounter()
        let router = APIRecoveryRouter(clock: clock.clock)
        await expectTimeout {
            try await router.singleAttemptWrite(plan: APIRecoveryPlan(targets: ["A", "B", "C"], builtInProxy: []),
                probe: { _ in
                    await probes.increment(); clock.advance(.seconds(9)); throw URLError(.timedOut)
                }, submit: { _ in await submits.increment(); return "must not submit" })
        }
        let submissionCount = await submits.count
        let probeCount = await probes.count
        XCTAssertEqual(submissionCount, 0)
        XCTAssertEqual(probeCount, 2)
        XCTAssertEqual(clock.now, .seconds(18))
    }

    func testSubmittedTimeoutRemainsUnknownAndNeverReplays() async {
        let clock = BudgetTestClock()
        let submits = RecoverySubmitCounter()
        let probes = RecoverySubmitCounter()
        let router = APIRecoveryRouter(clock: clock.clock)
        do {
            _ = try await router.singleAttemptWrite(plan: APIRecoveryPlan(targets: ["A", "B"], builtInProxy: candidates),
                probe: { _ in await probes.increment(); clock.advance(.seconds(17)) },
                submit: { _ -> String in
                    await submits.increment(); clock.advance(.seconds(25)); throw URLError(.timedOut)
                })
            XCTFail("Submitted timeout must be unknown")
        } catch NetworkClientError.writeResultUnknown {}
        catch { XCTFail("Expected unknown write, got \(type(of: error))") }
        let submissionCount = await submits.count
        let probeCount = await probes.count
        XCTAssertEqual(submissionCount, 1)
        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(clock.now, .seconds(42))
    }

    func testKnownSubmitSuccessSurvivesPreSubmitDeadlinePassing() async throws {
        let clock = BudgetTestClock()
        let router = APIRecoveryRouter(clock: clock.clock)
        let value = try await router.singleAttemptWrite(plan: APIRecoveryPlan(targets: ["A"], builtInProxy: []),
            probe: { _ in clock.advance(.seconds(17)) },
            submit: { _ in clock.advance(.seconds(2)); return "confirmed" })
        XCTAssertEqual(value, "confirmed")
        XCTAssertEqual(clock.now, .seconds(19))
    }

    func testAmbiguousSubmittedResponseKeepsCommerceUnknownResult() async {
        let clock = BudgetTestClock()
        let transport = RecordingNetworkTransport { request, kind in
            let body = kind == .writeRouteProbe ? #"{"data":{}}"# : "{}"
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        }
        do {
            _ = try await budgetTestAPI(clock: clock, transport: transport).createOrder(config: budgetTestConfig(),
                session: budgetTestSession(), planID: 1, period: .month, couponCode: nil)
            XCTFail("Expected unknown order result")
        } catch PurchaseCommerceError.orderCreationResultUnknown {}
        catch { XCTFail("Expected commerce unknown result") }
        let calls = await transport.calls
        XCTAssertEqual(calls.filter { $0.method == "POST" }.count, 1)
    }

    func testSubscriptionExhaustionPreventsRecovery() async {
        let clock = BudgetTestClock(autoBackoff: true)
        let transport = RecordingNetworkTransport { _, _ in
            clock.advance(.seconds(90)); throw URLError(.timedOut)
        }
        let runtime = BudgetRecoveryRuntime()
        let fetcher = SubscriptionFetcher(transport: transport,
            recoveryRouter: APIRecoveryRouter(recoveryRuntime: runtime, recoveryInitiallySuspendedForFormalVPN: false, clock: clock.clock))
        await expectTimeout {
            try await fetcher.fetchSubscription(from: "https://subscription.example.invalid/synthetic",
                userAgent: "NetworkClient-Test", builtInProxy: self.candidates)
        }
        let calls = await transport.calls
        let counts = await runtime.counts
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(counts.starts, 0)
    }

    func testSubscriptionWithRemainingBudgetCanRecover() async throws {
        let clock = BudgetTestClock(autoBackoff: true)
        let direct = RecordingNetworkTransport { _, _ in throw URLError(.cannotConnectToHost) }
        let recovered = RecordingNetworkTransport { request, kind in
            XCTAssertEqual(kind, .subscription)
            return (Data("proxies: []".utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!)
        }
        let runtime = BudgetRecoveryRuntime(transport: recovered)
        let fetcher = SubscriptionFetcher(transport: direct,
            recoveryRouter: APIRecoveryRouter(recoveryRuntime: runtime, recoveryInitiallySuspendedForFormalVPN: false, clock: clock.clock))
        let value = try await fetcher.fetchSubscription(from: "https://subscription.example.invalid/synthetic",
            userAgent: "NetworkClient-Test", builtInProxy: [ss])
        let calls = await direct.calls
        let counts = await runtime.counts
        XCTAssertEqual(value, "proxies: []")
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(counts.starts, 1)
        XCTAssertEqual(counts.stops, 1)
        XCTAssertEqual(clock.now, .milliseconds(400))
    }

    func testSubscriptionRecoveryInheritsBodyBudgetRatherThanJSONBudget() async throws {
        let clock = BudgetTestClock(autoBackoff: true)
        let direct = RecordingNetworkTransport { _, _ in throw URLError(.cannotConnectToHost) }
        let recovered = RecordingNetworkTransport { request, _ in
            clock.advance(.seconds(40))
            return (Data("proxies: []".utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!)
        }
        let runtime = BudgetRecoveryRuntime(transport: recovered)
        let fetcher = SubscriptionFetcher(transport: direct,
            recoveryRouter: APIRecoveryRouter(recoveryRuntime: runtime, recoveryInitiallySuspendedForFormalVPN: false, clock: clock.clock))
        let value = try await fetcher.fetchSubscription(from: "https://subscription.example.invalid/synthetic",
            userAgent: "NetworkClient-Test", builtInProxy: [ss])
        XCTAssertEqual(value, "proxies: []")
    }

    func testCancellationWinsWhenDeadlineAlsoExpires() async throws {
        let clock = BudgetTestClock()
        let gate = RecoveryOperationGate()
        let entered = expectation(description: "request suspended")
        let router = APIRecoveryRouter(clock: clock.clock)
        let recoveryCandidates = candidates
        let task = Task {
            try await router.safeRetry(plan: APIRecoveryPlan(targets: ["A", "B"], builtInProxy: recoveryCandidates)) { _ in
                entered.fulfill(); await gate.wait(); return "stale success"
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel(); clock.advance(.seconds(30)); await gate.open()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
    }

    func testDeadlineCannotClearCleanupBlockedOrStartSecondCore() async {
        let clock = BudgetTestClock()
        let runtime = BudgetRecoveryRuntime(closeFails: true)
        let router = APIRecoveryRouter(recoveryRuntime: runtime, recoveryInitiallySuspendedForFormalVPN: false, clock: clock.clock)
        let plan = APIRecoveryPlan(targets: ["A"], builtInProxy: candidates)
        await expectTimeout {
            try await router.safeRetry(plan: plan, directAlreadyExhausted: .timedOut) { _ -> String in
                clock.advance(.seconds(30)); throw URLError(.timedOut)
            }
        }
        let state = await router.takeoverStateForTesting()
        XCTAssertTrue(state.cleanupBlocked)
        await expectTimeout {
            try await router.safeRetry(plan: plan, directAlreadyExhausted: .timedOut) { _ in "must not start" }
        }
        let counts = await runtime.counts
        XCTAssertEqual(counts.starts, 1)
        XCTAssertEqual(counts.stops, 2)
    }

    func testDeadlineAfterQuiesceNeverStartsCore() async throws {
        for elapsed in [Duration.seconds(30), .milliseconds(29_500)] {
            let clock = BudgetTestClock()
            let core = CancellationTestCore()
            let runtime = MihomoAppRecoveryRuntime(core: core)
            await runtime.beginBatchForCancellationTesting()
            let entered = expectation(description: "quiesce entered")
            let endpoint = try BuiltInProxyParser.parse(ss)
            let deadline = OperationDeadline(after: .seconds(30), clock: clock.clock, parent: nil)
            let task = Task {
                try await OperationDeadline.$current.withValue(deadline) {
                    entered.fulfill()
                    return try await runtime.start(endpoint: endpoint)
                }
            }
            await fulfillment(of: [entered], timeout: 2)
            let waiting = await runtime.batchDrainWaiterCountForTesting()
            XCTAssertEqual(waiting, 1, "The operation must actually suspend in quiesce")
            clock.advance(elapsed)
            await runtime.finishBatchForCancellationTesting()
            await expectTimeout { try await task.value }
            XCTAssertEqual(core.counts.starts, 0)
            XCTAssertEqual(core.counts.setups, 0)
        }
    }

    func testSynchronousStartupReturnsPastDeadlineThenCleansUp() async throws {
        let clock = BudgetTestClock()
        let core = CancellationTestCore(afterStart: { clock.advance(.seconds(31)) })
        let runtime = MihomoAppRecoveryRuntime(core: core)
        let endpoint = try BuiltInProxyParser.parse(ss)
        let deadline = OperationDeadline(after: .seconds(30), clock: clock.clock, parent: nil)
        await expectTimeout {
            try await OperationDeadline.$current.withValue(deadline) { try await runtime.start(endpoint: endpoint) }
        }
        XCTAssertEqual(core.counts.starts, 1)
        XCTAssertEqual(core.counts.closes, 1)
        XCTAssertFalse(core.hasService)
        let snapshot = await runtime.snapshot()
        XCTAssertFalse(snapshot.running)
        XCTAssertNil(snapshot.loopbackPort)
    }

    func testPlanDoublePathSharesOneDeadlineAcrossAllHosts() async {
        let clock = BudgetTestClock()
        let transport = RecordingNetworkTransport { request, _ in
            clock.advance(.seconds(min(10, request.timeoutInterval)))
            return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 503,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        }
        await expectTimeout {
            try await budgetTestAPI(clock: clock, transport: transport).fetchPlans(
                config: budgetTestConfig(), session: budgetTestSession())
        }
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 3, "Must not issue all six path requests")
        XCTAssertEqual(clock.now, .seconds(30))
    }

    func testLoginSerialWorkflowSharesSixtySecondBudgetWithoutReplayingPOST() async {
        let clock = BudgetTestClock()
        let transport = RecordingNetworkTransport { request, kind in
            var body = #"{"data":{}}"#
            if kind == .writeRouteProbe { clock.advance(.seconds(3)) }
            else if kind == .apiLogin {
                clock.advance(.seconds(23)); body = #"{"data":{"auth_data":"synthetic-only"}}"#
            } else if request.url!.path.hasSuffix(V2BoardAPIClient.subscriptionInfoPath) {
                if request.url!.host == "127.0.0.1" {
                    clock.advance(.seconds(25)); throw URLError(.timedOut)
                }
                clock.advance(.seconds(4)); body = #"{"data":{"subscribe_url":"https://subscription.example.invalid/synthetic"}}"#
            } else { clock.advance(.seconds(request.timeoutInterval)); throw URLError(.timedOut) }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        }
        await expectTimeout {
            try await budgetTestAPI(clock: clock, transport: transport).login(config: budgetTestConfig(),
                email: "fixture@example.invalid", password: "synthetic-only")
        }
        let calls = await transport.calls
        XCTAssertEqual(clock.now, .seconds(60))
        XCTAssertEqual(calls.filter { $0.method == "POST" }.count, 1)
        XCTAssertEqual(calls.last?.timeout, 5)
    }

    func testCooperativeNetworkWaitIsCancelledAtDeadline() async throws {
        let clock = BudgetTestClock()
        let ready = expectation(description: "request deadline timer ready")
        clock.notifySleep(at: .seconds(4), ready)
        let router = APIRecoveryRouter(clock: clock.clock)
        let task = Task {
            try await router.safeRetry(plan: APIRecoveryPlan(targets: ["A", "B"], builtInProxy: []),
                budget: .seconds(4)) { _ in
                try await clock.sleep(until: .seconds(100)); return "late"
            }
        }
        await fulfillment(of: [ready], timeout: 2)
        clock.advance(.seconds(4))
        await expectTimeout { try await task.value }
        XCTAssertEqual(clock.sleeperCount, 0)
    }

    func testCallerSpecificBudgetCanPreserveRemoteConfigPolicy() async {
        let clock = BudgetTestClock()
        let router = APIRecoveryRouter(clock: clock.clock)
        let attempts = RecoverySubmitCounter()
        await expectTimeout {
            try await router.safeRetry(plan: APIRecoveryPlan(targets: ["A", "B", "C"], builtInProxy: []),
                budget: .seconds(60)) { _ -> String in
                await attempts.increment(); clock.advance(.seconds(20)); throw URLError(.timedOut)
            }
        }
        let count = await attempts.count
        XCTAssertEqual(count, 3)
        XCTAssertEqual(clock.now, .seconds(60))
    }
}

private actor BudgetRecoveryRuntime: BuiltInProxyRecoveryRuntimeProtocol {
    private let transport: any NetworkTransport
    private let closeFails: Bool
    private(set) var counts = (starts: 0, stops: 0)
    init(transport: any NetworkTransport = RecordingNetworkTransport { _, _ in throw URLError(.timedOut) },
         closeFails: Bool = false) {
        self.transport = transport; self.closeFails = closeFails
    }
    func start(endpoint: BuiltInProxyEndpoint) -> BuiltInProxyRecoveryRuntimeInfo {
        counts.starts += 1
        return BuiltInProxyRecoveryRuntimeInfo(protocolName: endpoint.protocolName, mixedPort: 1)
    }
    func makeRecoveryTransport() -> any NetworkTransport { transport }
    func stopRecovery() throws {
        counts.stops += 1
        if closeFails { throw RecoveryRuntimeError.stopFailed }
    }
}
