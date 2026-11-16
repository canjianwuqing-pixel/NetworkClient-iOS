import XCTest
import NetworkExtension
import Combine
@testable import NetworkClient

/// A replacement only for the actual NE public-call boundary. All state,
/// duplicate handling and callback checks run in production objects below.
@MainActor
private final class MinimalNEFixture {
    static let provider = "org.example.synthetic.PacketTunnel"
    enum Injected: Error { case failure }
    @MainActor final class Preference {
        let provider: String?
        let cleanRoomPreferenceVersion: Int?
        var enabled: Bool
        var status: NEVPNStatus
        var configured: [(String, String)] = []
        var saveCalls = 0, reloadCalls = 0, removeCalls = 0, starts = 0, stops = 0
        var saveFails = false, reloadFails = false, startFails = false
        var options: [[String: NSObject]] = []
        var listener: (@MainActor () -> Void)?
        var trace: ((String) -> Void)?
        var disconnectError: VPNLastDisconnectError?
        var sentMessages: [MihomoTunnelControlRequest] = []
        var sendHandler: ((MihomoTunnelControlRequest) async throws -> MihomoTunnelControlResponse)?
        init(provider: String? = MinimalNEFixture.provider, enabled: Bool = true,
             status: NEVPNStatus = .disconnected, version: Int? = 1) {
            self.provider = provider; self.enabled = enabled; self.status = status
            cleanRoomPreferenceVersion = version
        }
        var boundary: NETunnelProviderAccess.Preference {
            var value = NETunnelProviderAccess.Preference(providerBundleIdentifier: provider, cleanRoomPreferenceVersion: cleanRoomPreferenceVersion,
                  isEnabled: enabled, status: { self.status },
                  configure: { identifier, server in
                self.trace?("configure"); self.configured.append((identifier, server))
            }, save: {
                self.trace?("preferences.save"); self.saveCalls += 1
                if self.saveFails { throw Injected.failure }
            }, reload: {
                self.trace?("preferences.reload"); self.reloadCalls += 1
                if self.reloadFails { throw Injected.failure }
            }, remove: { self.trace?("preferences.remove"); self.removeCalls += 1 }, start: { options in
                self.trace?("session.start"); self.starts += 1; self.options.append(options)
                if self.startFails { throw Injected.failure }
                self.status = .connecting
            }, stop: { self.stops += 1; self.status = .disconnecting }, observe: { listener in
                self.listener = listener
                return { self.listener = nil }
            }, lastDisconnectError: { self.disconnectError })
            value.send = { data in
                guard let request = MihomoTunnelControlCodec.decodeRequest(data) else {
                    throw Injected.failure
                }
                self.sentMessages.append(request)
                guard let response = try await self.sendHandler?(request) else {
                    throw Injected.failure
                }
                return MihomoTunnelControlCodec.encode(response)
            }
            return value
        }
        func emit(_ status: NEVPNStatus) { self.status = status; listener?() }
    }
    var preferences: [Preference]
    let created = Preference(provider: nil, enabled: false, status: .invalid, version: nil)
    var loads = 0, makes = 0
    var saved: [MihomoTunnelConfiguration] = []
    var trace: [String] = []
    init(_ preferences: [Preference] = [Preference()]) {
        self.preferences = preferences
        for preference in preferences { preference.trace = { [weak self] in self?.trace.append($0) } }
        created.trace = { [weak self] in self?.trace.append($0) }
    }
    var backend: NETunnelProviderAccess.Backend {
        .init(loadAll: {
            self.loads += 1; self.trace.append("preferences.load")
            return self.preferences.map(\.boundary)
        }, make: { self.makes += 1; self.trace.append("preferences.make"); return self.created.boundary })
    }
    func controller(
        prepareRecoveryForFormalVPN: @escaping @MainActor () async throws -> Void = {},
        setRecoveryAllowedForFormalVPN: @escaping @MainActor (Bool) async -> Void = { _ in }
    ) -> MinimalVPNController {
        MinimalVPNController(providerBundleIdentifier: Self.provider, backend: backend,
            saveConfiguration: { self.trace.append("configuration.save"); self.saved.append($0) },
            removeConfiguration: { _ in },
            prepareRecoveryForFormalVPN: prepareRecoveryForFormalVPN,
            setRecoveryAllowedForFormalVPN: setRecoveryAllowedForFormalVPN)
    }
    static func configuration() -> MihomoTunnelConfiguration {
        .init(generation: UUID(), nodeID: "synthetic-selected", serverIPv4: "192.0.2.1",
              yaml: "# synthetic runtime fixture", createdAt: Date())
    }
}

@MainActor
private final class MinimalConfigurationGate {
    let entered = XCTestExpectation(description: "configuration preparation suspended")
    private var continuation: CheckedContinuation<MihomoTunnelConfiguration, Error>?
    func prepare() async throws -> MihomoTunnelConfiguration {
        entered.fulfill()
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish() {
        continuation?.resume(returning: MinimalNEFixture.configuration()); continuation = nil
    }
}

@MainActor
final class MinimalVPNControllerTests: XCTestCase {
    private func eventually(
        timeout: Duration = .seconds(2),
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(predicate())
    }

    func testInitialStateIsDisconnected() {
        let fixture = MinimalNEFixture(), controller = fixture.controller()
        XCTAssertEqual(controller.state, .disconnected); XCTAssertNil(controller.lastError)
        XCTAssertEqual(fixture.loads, 0)
    }
    func testDisconnectedMapsToDisconnected() {
        XCTAssertEqual(MinimalVPNController.state(for: .disconnected), .disconnected)
    }
    func testInvalidMapsToDisconnected() {
        XCTAssertEqual(MinimalVPNController.state(for: .invalid), .disconnected)
    }
    func testConnectingMapsToConnecting() {
        XCTAssertEqual(MinimalVPNController.state(for: .connecting), .connecting)
    }
    func testReassertingMapsToConnecting() {
        XCTAssertEqual(MinimalVPNController.state(for: .reasserting), .connecting)
    }
    func testDisconnectingMapsToConnecting() {
        XCTAssertEqual(MinimalVPNController.state(for: .disconnecting), .connecting)
    }
    func testConnectedMapsToConnected() {
        XCTAssertEqual(MinimalVPNController.state(for: .connected), .connected)
    }
    func testErrorRemainsSeparateFromMainState() async {
        let fixture = MinimalNEFixture(), controller = fixture.controller()
        do {
            try await controller.connect(prepare: { throw MinimalNEFixture.Injected.failure })
            XCTFail("Configuration failure must reach the caller")
        } catch {}
        XCTAssertNotNil(controller.lastError); XCTAssertEqual(controller.state, .disconnected)
        XCTAssertEqual(fixture.preferences.first?.starts, 0); XCTAssertTrue(fixture.saved.isEmpty)
    }
    func testTypedPreflightFailuresArePreservedWithoutTouchingNE() async {
        for expected in [VPNConnectionPreflightError.noNodeSelected,
                         .selectedNodeMissing, .nodeConfigurationInvalid] {
            let fixture = MinimalNEFixture(), controller = fixture.controller()
            do {
                try await controller.connect(prepare: { throw expected })
                XCTFail("Typed preflight failure must reach HomeView")
            } catch let error as VPNConnectionPreflightError {
                XCTAssertEqual(error, expected)
            } catch {
                XCTFail("Expected typed preflight error, got \(error)")
            }
            XCTAssertEqual(controller.state, .disconnected)
            XCTAssertEqual(controller.operation, .idle)
            XCTAssertEqual(fixture.loads, 0)
            XCTAssertTrue(fixture.saved.isEmpty)
            XCTAssertEqual(fixture.preferences.first?.starts, 0)
        }
    }
    func testConnectShowsConnectingThenUsesActualSaveReloadStartOrder() async throws {
        let fixture = MinimalNEFixture(), controller = fixture.controller(), gate = MinimalConfigurationGate()
        let work = Task { try await controller.connect(prepare: { try await gate.prepare() }) }
        await fulfillment(of: [gate.entered], timeout: 3)
        XCTAssertEqual(controller.state, .connecting); XCTAssertTrue(fixture.saved.isEmpty)
        gate.finish(); try await work.value
        XCTAssertEqual(fixture.trace, ["configuration.save", "preferences.load", "configure", "preferences.save", "preferences.reload", "session.start"])
        XCTAssertEqual(fixture.saved.count, 1); XCTAssertEqual(fixture.preferences.first?.starts, 1)
        XCTAssertEqual(controller.state, .connecting, "startVPNTunnel return is not NE connected")
    }

    func testFormalVPNConnectClosesRecoveryBeforeConfigurationAndNEStart() async throws {
        let fixture = MinimalNEFixture()
        let controller = fixture.controller(prepareRecoveryForFormalVPN: {
            fixture.trace.append("recovery.suspend")
            fixture.trace.append("recovery.closed")
        })

        try await controller.connect(prepare: {
            fixture.trace.append("configuration.prepare")
            return MinimalNEFixture.configuration()
        })

        XCTAssertEqual(fixture.trace, [
            "recovery.suspend", "recovery.closed", "configuration.prepare",
            "configuration.save", "preferences.load", "configure",
            "preferences.save", "preferences.reload", "session.start",
        ])
        XCTAssertEqual(fixture.preferences.first?.starts, 1)
    }

    func testRecoveryCloseFailureBlocksConfigurationAndNEStart() async {
        let fixture = MinimalNEFixture()
        let controller = fixture.controller(prepareRecoveryForFormalVPN: {
            fixture.trace.append("recovery.suspend")
            throw TunnelDiagnostic(
                code: .recoveryCloseUnconfirmed,
                message: "synthetic recovery close failure"
            )
        })

        do {
            try await controller.connect(prepare: {
                fixture.trace.append("configuration.prepare")
                return MinimalNEFixture.configuration()
            })
            XCTFail("An unconfirmed recovery close must block formal VPN start")
        } catch {}

        XCTAssertEqual(fixture.trace, ["recovery.suspend"])
        XCTAssertTrue(fixture.saved.isEmpty)
        XCTAssertEqual(fixture.loads, 0)
        XCTAssertEqual(fixture.preferences.first?.starts, 0)
    }

    func testRecoveryGateFailsClosedUntilSystemExplicitlyReportsDisconnected() async throws {
        for status in [NEVPNStatus.connecting, .connected, .reasserting, .disconnecting, .invalid] {
            let preference = MinimalNEFixture.Preference(status: status)
            let fixture = MinimalNEFixture([preference])
            var allowed: [Bool] = []
            let controller = fixture.controller(
                setRecoveryAllowedForFormalVPN: { allowed.append($0) }
            )
            try await controller.refreshSystemStatus()
            XCTAssertFalse(allowed.isEmpty, "status=\(status.rawValue)")
            XCTAssertTrue(allowed.allSatisfy { !$0 }, "status=\(status.rawValue)")
        }

        let unavailable = MinimalNEFixture([])
        var unavailableAllowed: [Bool] = []
        let controller = unavailable.controller(
            setRecoveryAllowedForFormalVPN: { unavailableAllowed.append($0) }
        )
        try await controller.refreshSystemStatus()
        XCTAssertEqual(unavailableAllowed, [false])
    }

    func testRecoveryGateReopensOnlyAfterActualDisconnectedCallback() async throws {
        let preference = MinimalNEFixture.Preference(status: .connected)
        let fixture = MinimalNEFixture([preference])
        var allowed: [Bool] = []
        let controller = fixture.controller(
            setRecoveryAllowedForFormalVPN: { allowed.append($0) }
        )

        try await controller.refreshSystemStatus()
        XCTAssertFalse(allowed.last ?? true)

        try await controller.disconnect()
        await eventually { allowed.last == false }
        XCTAssertEqual(preference.status, .disconnecting)
        XCTAssertFalse(allowed.contains(true))

        preference.emit(.disconnected)
        await eventually { allowed.last == true }
        XCTAssertEqual(controller.state, .disconnected)
    }
    func testRepeatedConnectDuringPreparationIsIgnored() async throws {
        let fixture = MinimalNEFixture(), controller = fixture.controller(), gate = MinimalConfigurationGate()
        let work = Task { try await controller.connect(prepare: { try await gate.prepare() }) }
        await fulfillment(of: [gate.entered], timeout: 3)
        var secondPrepared = false
        try await controller.connect(prepare: { secondPrepared = true; return MinimalNEFixture.configuration() })
        XCTAssertFalse(secondPrepared)
        gate.finish(); try await work.value
        XCTAssertEqual(fixture.saved.count, 1); XCTAssertEqual(fixture.preferences.first?.starts, 1)
    }
    func testConnectWhileNEConnectedDoesNotStartAnotherTunnel() async throws {
        for alreadyObserved in [true, false] {
            let preference = MinimalNEFixture.Preference(status: .connected)
            let fixture = MinimalNEFixture([preference]), controller = fixture.controller()
            if alreadyObserved { try await controller.refreshSystemStatus() }
            var prepared = false
            try await controller.connect(prepare: { prepared = true; return MinimalNEFixture.configuration() })
            if alreadyObserved { XCTAssertFalse(prepared); XCTAssertTrue(fixture.saved.isEmpty) }
            // A cold controller can discover the active NE session only after
            // prepare/load. It must adopt that status without another start.
            XCTAssertEqual(preference.starts, 0)
            XCTAssertEqual(preference.saveCalls, 0)
            XCTAssertEqual(preference.reloadCalls, 0)
            XCTAssertEqual(controller.state, .connected)
        }
    }
    func testDisconnectStopsCurrentSessionAndWaitsForNEToDeclareDisconnected() async throws {
        let preference = MinimalNEFixture.Preference(status: .connected)
        let fixture = MinimalNEFixture([preference]), controller = fixture.controller()
        try await controller.refreshSystemStatus(); try await controller.disconnect()
        XCTAssertEqual(preference.stops, 1)
        XCTAssertNotEqual(controller.state, .disconnected)
        preference.emit(.disconnected)
        XCTAssertEqual(controller.state, .disconnected)
    }
    func testRepeatedDisconnectDoesNotSendAnotherStopBeforeNETerminal() async throws {
        let preference = MinimalNEFixture.Preference(status: .connected)
        let fixture = MinimalNEFixture([preference]), controller = fixture.controller()
        try await controller.refreshSystemStatus()
        try await controller.disconnect(); try await controller.disconnect()
        XCTAssertEqual(preference.stops, 1)
        preference.emit(.disconnected)
        XCTAssertEqual(controller.state, .disconnected)
    }
    func testCurrentNECallbacksAreTheOnlyConnectedAuthority() async throws {
        let preference = MinimalNEFixture.Preference()
        let fixture = MinimalNEFixture([preference]), controller = fixture.controller()
        try await controller.connect(prepare: { MinimalNEFixture.configuration() })
        XCTAssertEqual(controller.state, .connecting)
        for (status, expected) in [(NEVPNStatus.connected, MinimalVPNController.State.connected),
                                   (.reasserting, .connecting), (.disconnected, .disconnected), (.invalid, .disconnected)] {
            preference.emit(status); XCTAssertEqual(controller.state, expected)
        }
    }
    func testStartErrorSetsFiniteLastErrorWithoutAConnectedState() async {
        let preference = MinimalNEFixture.Preference(); preference.startFails = true
        let fixture = MinimalNEFixture([preference]), controller = fixture.controller()
        do {
            try await controller.connect(prepare: { MinimalNEFixture.configuration() })
            XCTFail("A real start boundary error must propagate")
        } catch {}
        guard case .start? = controller.lastError else { return XCTFail("Expected a finite start error") }
        XCTAssertEqual(controller.state, .disconnected); XCTAssertEqual(preference.starts, 1)
    }
    func testLateOldNECallbackCannotReplaceNewSessionObservation() async throws {
        let old = MinimalNEFixture.Preference(status: .connected), current = MinimalNEFixture.Preference(status: .reasserting)
        let fixture = MinimalNEFixture([old]), controller = fixture.controller()
        try await controller.refreshSystemStatus()
        let lateCallback = try XCTUnwrap(old.listener)
        fixture.preferences = [current]
        try await controller.refreshSystemStatus()
        XCTAssertEqual(controller.state, .connecting)
        old.status = .disconnected; lateCallback()
        XCTAssertEqual(controller.state, .connecting); XCTAssertNil(controller.lastError)
        current.emit(.connected); XCTAssertEqual(controller.state, .connected)
    }
    func testRefreshReadsOnlyCurrentNEStatusWithoutCreatingOrMutatingPreferences() async throws {
        let current = MinimalNEFixture.Preference(status: .reasserting), duplicate = MinimalNEFixture.Preference()
        let fixture = MinimalNEFixture([current, duplicate]), controller = fixture.controller()
        try await controller.refreshSystemStatus()
        XCTAssertEqual(controller.state, .connecting); XCTAssertEqual(fixture.loads, 1); XCTAssertEqual(fixture.makes, 0)
        XCTAssertEqual(current.saveCalls, 0); XCTAssertEqual(current.reloadCalls, 0)
        XCTAssertEqual(duplicate.saveCalls + duplicate.reloadCalls, 0)
        XCTAssertEqual(current.removeCalls, 0); XCTAssertEqual(duplicate.removeCalls, 0)
        XCTAssertTrue(current.configured.isEmpty); XCTAssertTrue(duplicate.configured.isEmpty)
        XCTAssertTrue(fixture.saved.isEmpty)
        XCTAssertEqual(current.starts + duplicate.starts, 0)
    }

    func testConnectedNodeSwitchUsesCurrentSessionWithoutStartOrStop() async throws {
        let preference = MinimalNEFixture.Preference(status: .connected)
        preference.sendHandler = { request in
            let target = request.payload?.targetCoreName
            return .init(requestID: request.requestID, result: .init(
                status: .applied, switchApplied: true,
                confirmedTargetCoreName: target,
                connectionRefreshSucceeded: true
            ))
        }
        let fixture = MinimalNEFixture([preference]), controller = fixture.controller()
        try await controller.refreshSystemStatus()
        let result = try await controller.switchNode(
            requestID: UUID(), targetCoreName: "core-b",
            candidatePoolRevision: String(repeating: "a", count: 64)
        )
        XCTAssertEqual(result.confirmedTargetCoreName, "core-b")
        XCTAssertEqual(preference.sentMessages.filter {
            $0.knownCommand == .switchNode
        }.count, 1)
        XCTAssertEqual(preference.starts, 0)
        XCTAssertEqual(preference.stops, 0)
        preference.emit(.disconnected)
    }

    func testConnectedModeSwitchUsesCurrentSessionWithoutStartOrStop() async throws {
        let preference = MinimalNEFixture.Preference(status: .connected)
        preference.sendHandler = { request in
            .init(requestID: request.requestID, result: .init(
                status: .applied, switchApplied: true,
                confirmedMode: request.payload?.mode,
                connectionRefreshSucceeded: true
            ))
        }
        let fixture = MinimalNEFixture([preference]), controller = fixture.controller()
        try await controller.refreshSystemStatus()
        let didSwitchMode = try await controller.switchMode(.global)
        XCTAssertTrue(didSwitchMode)
        XCTAssertEqual(preference.sentMessages.filter {
            $0.knownCommand == .switchMode
        }.count, 1)
        XCTAssertEqual(preference.starts, 0)
        XCTAssertEqual(preference.stops, 0)
        preference.emit(.disconnected)
    }

    func testDisconnectedModeChangeDoesNotSendProviderMessage() async throws {
        let preference = MinimalNEFixture.Preference(status: .disconnected)
        let fixture = MinimalNEFixture([preference]), controller = fixture.controller()
        let didSwitchMode = try await controller.switchMode(.global)
        XCTAssertFalse(didSwitchMode)
        XCTAssertTrue(preference.sentMessages.isEmpty)
    }

    func testStep261ConnectedProbeUsesCurrentSessionWithoutStartOrStop() async throws {
        let preference = MinimalNEFixture.Preference(status: .connected)
        preference.sendHandler = { request in
            if request.knownCommand == .probeNodes {
                return .init(requestID: request.requestID, result: .init(
                    status: .applied,
                    nodeProbeResults: request.payload?.probeCoreNames?.map {
                        .init(coreName: $0, status: .measured, delayMilliseconds: 55)
                    }
                ))
            }
            return .init(requestID: request.requestID, result: .init(
                status: .applied, uploadBytesPerSecond: 0,
                downloadBytesPerSecond: 0, sampledAtUnixMilliseconds: 1
            ))
        }
        let fixture = MinimalNEFixture([preference]), controller = fixture.controller()
        try await controller.refreshSystemStatus()

        let results = try await controller.probeNodes(
            coreNames: ["core-a", "core-b"],
            candidatePoolRevision: String(repeating: "a", count: 64)
        )

        XCTAssertEqual(results, [
            .init(coreName: "core-a", status: .measured, delayMilliseconds: 55),
            .init(coreName: "core-b", status: .measured, delayMilliseconds: 55),
        ])
        let probes = preference.sentMessages.filter { $0.knownCommand == .probeNodes }
        XCTAssertEqual(probes.count, 1)
        XCTAssertEqual(probes[0].payload?.probeCoreNames, ["core-a", "core-b"])
        XCTAssertEqual(preference.starts, 0)
        XCTAssertEqual(preference.stops, 0)
        preference.emit(.disconnected)
    }

    func testConnectedStartsTrafficObservationAndPublishesSnapshot() async throws {
        let preference = MinimalNEFixture.Preference(status: .connected)
        preference.sendHandler = { request in
            .init(requestID: request.requestID, result: .init(
                status: .applied, uploadBytesPerSecond: 123,
                downloadBytesPerSecond: 456,
                sampledAtUnixMilliseconds: 789
            ))
        }
        let fixture = MinimalNEFixture([preference]), controller = fixture.controller()
        try await controller.refreshSystemStatus()
        await eventually { controller.uploadBytesPerSecond == 123
            && controller.downloadBytesPerSecond == 456 }
        XCTAssertNotNil(controller.trafficObservationID)
        XCTAssertTrue(preference.sentMessages.contains {
            $0.knownCommand == .trafficSnapshot
        })
        preference.emit(.disconnected)
    }

    func testDisconnectingStopsTrafficObservationAndClearsRates() async throws {
        let preference = MinimalNEFixture.Preference(status: .connected)
        preference.sendHandler = { request in
            .init(requestID: request.requestID, result: .init(
                status: .applied, uploadBytesPerSecond: 1,
                downloadBytesPerSecond: 2,
                sampledAtUnixMilliseconds: 3
            ))
        }
        let fixture = MinimalNEFixture([preference]), controller = fixture.controller()
        try await controller.refreshSystemStatus()
        await eventually { controller.downloadBytesPerSecond == 2 }
        try await controller.disconnect()
        XCTAssertNil(controller.trafficObservationID)
        XCTAssertEqual(controller.uploadBytesPerSecond, 0)
        XCTAssertEqual(controller.downloadBytesPerSecond, 0)
        preference.emit(.disconnected)
    }

    func testTrafficQueryFailureDoesNotChangeVPNState() async throws {
        let preference = MinimalNEFixture.Preference(status: .connected)
        preference.sendHandler = { _ in throw MinimalNEFixture.Injected.failure }
        let fixture = MinimalNEFixture([preference]), controller = fixture.controller()
        try await controller.refreshSystemStatus()
        let observation = try XCTUnwrap(controller.trafficObservationID)
        await controller.pollTraffic(observationID: observation)
        XCTAssertEqual(controller.state, .connected)
        XCTAssertEqual(controller.uploadBytesPerSecond, 0)
        XCTAssertEqual(preference.starts + preference.stops, 0)
        preference.emit(.disconnected)
    }

    func testOldTrafficObservationCannotPublishAfterDisconnect() async throws {
        let preference = MinimalNEFixture.Preference(status: .connected)
        preference.sendHandler = { request in
            .init(requestID: request.requestID, result: .init(
                status: .applied, uploadBytesPerSecond: 900,
                downloadBytesPerSecond: 800,
                sampledAtUnixMilliseconds: 700
            ))
        }
        let fixture = MinimalNEFixture([preference]), controller = fixture.controller()
        try await controller.refreshSystemStatus()
        let old = try XCTUnwrap(controller.trafficObservationID)
        preference.emit(.disconnected)
        await controller.pollTraffic(observationID: old)
        XCTAssertEqual(controller.uploadBytesPerSecond, 0)
        XCTAssertEqual(controller.downloadBytesPerSecond, 0)
    }

    func testNewSessionRejectsOldObservationIDSnapshot() async throws {
        let preference = MinimalNEFixture.Preference(status: .connected)
        preference.sendHandler = { request in
            .init(requestID: request.requestID, result: .init(
                status: .applied, uploadBytesPerSecond: 11,
                downloadBytesPerSecond: 22,
                sampledAtUnixMilliseconds: 33
            ))
        }
        let fixture = MinimalNEFixture([preference]), controller = fixture.controller()
        try await controller.refreshSystemStatus()
        let old = try XCTUnwrap(controller.trafficObservationID)
        preference.emit(.disconnected)
        preference.emit(.connected)
        let current = try XCTUnwrap(controller.trafficObservationID)
        XCTAssertNotEqual(old, current)
        await eventually { controller.uploadBytesPerSecond == 11 }
        preference.sendHandler = { request in
            .init(requestID: request.requestID, result: .init(
                status: .applied, uploadBytesPerSecond: 999,
                downloadBytesPerSecond: 888,
                sampledAtUnixMilliseconds: 777
            ))
        }
        await controller.pollTraffic(observationID: old)
        XCTAssertEqual(controller.uploadBytesPerSecond, 11)
        await controller.pollTraffic(observationID: current)
        XCTAssertEqual(controller.uploadBytesPerSecond, 999)
        preference.emit(.disconnected)
    }

    func testNodeAndModeHotSwitchKeepTrafficObservationIdentity() async throws {
        let preference = MinimalNEFixture.Preference(status: .connected)
        preference.sendHandler = { request in
            switch request.knownCommand {
            case .switchNode:
                return .init(requestID: request.requestID, result: .init(
                    status: .applied, switchApplied: true,
                    confirmedTargetCoreName: request.payload?.targetCoreName,
                    connectionRefreshSucceeded: true
                ))
            case .switchMode:
                return .init(requestID: request.requestID, result: .init(
                    status: .applied, switchApplied: true,
                    confirmedMode: request.payload?.mode,
                    connectionRefreshSucceeded: true
                ))
            case .trafficSnapshot, .probeNodes, nil:
                return .init(requestID: request.requestID, result: .init(
                    status: .applied, uploadBytesPerSecond: 1,
                    downloadBytesPerSecond: 2,
                    sampledAtUnixMilliseconds: 3
                ))
            }
        }
        let fixture = MinimalNEFixture([preference]), controller = fixture.controller()
        try await controller.refreshSystemStatus()
        let observation = try XCTUnwrap(controller.trafficObservationID)
        _ = try await controller.switchNode(
            requestID: UUID(), targetCoreName: "core-b",
            candidatePoolRevision: nil
        )
        let didSwitchMode = try await controller.switchMode(.global)
        XCTAssertTrue(didSwitchMode)
        XCTAssertEqual(controller.trafficObservationID, observation)
        preference.emit(.disconnected)
    }

    func testLiveTrafficFormatterUsesCompactBinaryUnits() {
        XCTAssertEqual(LiveTrafficFormatter.bytesPerSecond(0), "0 B/s")
        XCTAssertEqual(LiveTrafficFormatter.bytesPerSecond(512), "512 B/s")
        XCTAssertEqual(LiveTrafficFormatter.bytesPerSecond(1_536), "1.5 KB/s")
        XCTAssertEqual(LiveTrafficFormatter.bytesPerSecond(2 * 1_024 * 1_024), "2 MB/s")
        XCTAssertEqual(LiveTrafficFormatter.bytesPerSecond(3 * 1_024 * 1_024 * 1_024), "3 GB/s")
    }

    func testConnectedNodeSelectionDismissesSynchronouslyAfterStartingTransaction() {
        var events: [String] = []
        NodeSelectionPresentationFlow.perform(begin: {
            events.append("transaction-started")
            return true
        }, dismiss: {
            events.append("dismissed")
        })
        events.append("provider-completed-later")
        XCTAssertEqual(events, ["transaction-started", "dismissed", "provider-completed-later"])
    }

    func testInFlightNodeSelectionIsIgnoredWithoutDismiss() {
        var dismissed = false
        NodeSelectionPresentationFlow.perform(begin: { false }, dismiss: {
            dismissed = true
        })
        XCTAssertFalse(dismissed)
    }

    func testConfirmedNodeSwitchCommitsOnlyAfterCoreReadback() async {
        let id = UUID()
        var commits = 0, rollbacks = 0
        let committed = await NodeHotSwitchFinalizer.apply(
            requestID: id, currentRequestID: id,
            targetCoreName: "core-b",
            result: .init(status: .applied, switchApplied: true,
                          confirmedTargetCoreName: "core-b",
                          connectionRefreshSucceeded: true),
            contextMatches: true,
            commit: { commits += 1 },
            rollback: { rollbacks += 1 }
        )
        XCTAssertTrue(committed)
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(rollbacks, 0)
    }

    func testUnconfirmedNodeSwitchPreservesOldFormalSelection() async {
        let id = UUID()
        var commits = 0
        let committed = await NodeHotSwitchFinalizer.apply(
            requestID: id, currentRequestID: id,
            targetCoreName: "core-b",
            result: .init(status: .rejected, switchApplied: false),
            contextMatches: true,
            commit: { commits += 1 }, rollback: {}
        )
        XCTAssertFalse(committed)
        XCTAssertEqual(commits, 0)
    }

    func testStaleNodeSwitchRequestIDCannotCommit() async {
        let id = UUID()
        var commits = 0
        _ = await NodeHotSwitchFinalizer.apply(
            requestID: id, currentRequestID: UUID(),
            targetCoreName: "core-b",
            result: .init(status: .applied, switchApplied: true,
                          confirmedTargetCoreName: "core-b"),
            contextMatches: true,
            commit: { commits += 1 }, rollback: {}
        )
        XCTAssertEqual(commits, 0)
    }

    func testChangedAccountOrCatalogCannotCommitNodeSwitch() async {
        let id = UUID()
        var commits = 0
        _ = await NodeHotSwitchFinalizer.apply(
            requestID: id, currentRequestID: id,
            targetCoreName: "core-b",
            result: .init(status: .applied, switchApplied: true,
                          confirmedTargetCoreName: "core-b"),
            contextMatches: false,
            commit: { commits += 1 }, rollback: {}
        )
        XCTAssertEqual(commits, 0)
    }

    func testNodeCommitFailurePerformsExactlyOneBestEffortRollback() async {
        let id = UUID()
        var rollbacks = 0
        let committed = await NodeHotSwitchFinalizer.apply(
            requestID: id, currentRequestID: id,
            targetCoreName: "core-b",
            result: .init(status: .applied, switchApplied: true,
                          confirmedTargetCoreName: "core-b",
                          connectionRefreshSucceeded: false),
            contextMatches: true,
            commit: { throw MinimalNEFixture.Injected.failure },
            rollback: { rollbacks += 1 }
        )
        XCTAssertFalse(committed)
        XCTAssertEqual(rollbacks, 1)
    }
}

@MainActor
final class VPNConnectionErrorPresentationTests: XCTestCase {
    private struct ActionableLocalizedError: LocalizedError {
        var errorDescription: String? { "Choose a different node." }
    }

    func testTypedPreflightErrorsKeepActionableReasonAndOpenNodeList() {
        let cases: [(VPNConnectionPreflightError, String, String, String)] = [
            (.noNodeSelected, L10nKey.vpnPreflightNoNodeTitle,
             L10nKey.vpnPreflightNoNodeMessage, L10nKey.vpnPreflightSelectNodeAction),
            (.selectedNodeMissing, L10nKey.vpnPreflightSelectedNodeMissingTitle,
             L10nKey.vpnPreflightSelectedNodeMissingMessage, L10nKey.vpnPreflightChooseAnotherNodeAction),
            (.nodeConfigurationInvalid, L10nKey.vpnPreflightInvalidConfigurationTitle,
             L10nKey.vpnPreflightInvalidConfigurationMessage, L10nKey.vpnPreflightReplaceNodeAction)
        ]
        for (error, title, message, action) in cases {
            let presentation = VPNConnectionErrorPresentation.make(error)
            XCTAssertEqual(presentation.titleKey, title)
            XCTAssertEqual(presentation.message, .localized(message))
            XCTAssertNotEqual(presentation.message, .localized(L10nKey.commonOperationFailed))
            XCTAssertEqual(presentation.actionKey, action)
            XCTAssertEqual(presentation.action, .openNodeList)
        }
    }

    func testUnknownConnectFailureUsesNeutralMessageWithoutPretendingItIsNetworkFailure() {
        let presentation = VPNConnectionErrorPresentation.make(MinimalNEFixture.Injected.failure)
        XCTAssertEqual(presentation.titleKey, L10nKey.vpnConnectUnableTitle)
        XCTAssertEqual(presentation.message, .localized(L10nKey.vpnConnectUnableMessage))
        XCTAssertNotEqual(presentation.message, .localized(L10nKey.commonOperationFailed))
        XCTAssertEqual(presentation.action, .dismiss)
    }

    func testLocalizedErrorKeepsItsActionableDescription() {
        let presentation = VPNConnectionErrorPresentation.make(ActionableLocalizedError())
        XCTAssertEqual(presentation.message, .verbatim("Choose a different node."))
        XCTAssertEqual(presentation.action, .dismiss)
    }

    func testOrdinaryConnectionErrorUsesErrorModalWithCloseOnly() {
        let presentation = VPNConnectionErrorPresentation.make(MinimalNEFixture.Injected.failure)
        let request = presentation.modalRequest

        XCTAssertEqual(request.kind, .result(.error))
        XCTAssertEqual(request.title, .localized(L10nKey.vpnConnectUnableTitle))
        XCTAssertEqual(request.message, .localized(L10nKey.vpnConnectUnableMessage))
        XCTAssertEqual(request.primary.title, .localized(L10nKey.commonClose))
        XCTAssertNil(request.secondary)
        XCTAssertEqual(presentation.ownerAction(for: .primary), .dismiss)
        XCTAssertEqual(presentation.ownerAction(for: .dismissed), .dismiss)
    }

    func testActionableConnectionErrorMapsPrimaryToNodeListAndSecondaryToClose() throws {
        let presentation = VPNConnectionErrorPresentation.make(VPNConnectionPreflightError.noNodeSelected)
        let request = presentation.modalRequest

        XCTAssertEqual(request.kind, .result(.error))
        XCTAssertEqual(request.primary.title, .localized(L10nKey.vpnPreflightSelectNodeAction))
        XCTAssertEqual(request.primary.role, .normal)
        let close = try XCTUnwrap(request.secondary)
        XCTAssertEqual(close.title, .localized(L10nKey.commonClose))
        XCTAssertEqual(close.role, .cancel)
        XCTAssertEqual(presentation.ownerAction(for: .primary), .openNodeList)
        XCTAssertEqual(presentation.ownerAction(for: .secondary), .dismiss)
        XCTAssertEqual(presentation.ownerAction(for: .dismissed), .dismiss)
    }

    func testActionableConnectionErrorNavigatesOnlyOnceAfterPrimaryChoice() async {
        let presenter = GlobalModalPresenter()
        let presentation = VPNConnectionErrorPresentation.make(VPNConnectionPreflightError.noNodeSelected)
        let request = presentation.modalRequest
        var navigationCount = 0
        let result = Task { await presenter.present(request) }
        await Task.yield()

        XCTAssertTrue(presenter.resolve(.primary, requestID: request.id))
        XCTAssertFalse(presenter.resolve(.primary, requestID: request.id))
        if presentation.ownerAction(for: await result.value) == .openNodeList {
            navigationCount += 1
        }

        XCTAssertEqual(navigationCount, 1)
        XCTAssertNil(presenter.activeRequest)
    }

    func testCancellationDoesNotCreateConnectionErrorPresentation() {
        XCTAssertNil(VPNConnectionErrorPresentation.makeIfPresentable(CancellationError()))
    }
}

@MainActor
final class MinimalVPNPreferenceTests: XCTestCase {
    func testLoadsAndReusesExistingSingleMatchingManager() async throws {
        let preference = MinimalNEFixture.Preference(status: .connected), fixture = MinimalNEFixture([preference])
        let current = try await NETunnelProviderAccess.prepareCurrent(providerBundleIdentifier: MinimalNEFixture.provider,
            backend: fixture.backend)
        XCTAssertEqual(current.status(), .connected); XCTAssertEqual(fixture.loads, 1); XCTAssertEqual(fixture.makes, 0)
        XCTAssertEqual(preference.removeCalls, 0)
    }
    func testCreatesManagerOnlyWhenNoMatchingPreferenceExists() async throws {
        let fixture = MinimalNEFixture([])
        let current = try await NETunnelProviderAccess.prepareCurrent(providerBundleIdentifier: MinimalNEFixture.provider,
            backend: fixture.backend)
        XCTAssertEqual(fixture.makes, 1)
        XCTAssertEqual(current.status(), .invalid)
    }
    func testPreferenceSaveFailurePreventsSessionStart() async {
        let preference = MinimalNEFixture.Preference(); preference.saveFails = true
        let fixture = MinimalNEFixture([preference]), controller = fixture.controller()
        do { try await controller.connect(prepare: { MinimalNEFixture.configuration() }); XCTFail("Save must fail") }
        catch {}
        XCTAssertEqual(preference.saveCalls, 1); XCTAssertEqual(preference.reloadCalls, 0); XCTAssertEqual(preference.starts, 0)
        guard case .preferences? = controller.lastError else { return XCTFail("Expected finite preference failure") }
    }
    func testPreferenceReloadFailurePreventsSessionStart() async {
        let preference = MinimalNEFixture.Preference(); preference.reloadFails = true
        let fixture = MinimalNEFixture([preference]), controller = fixture.controller()
        do { try await controller.connect(prepare: { MinimalNEFixture.configuration() }); XCTFail("Reload must fail") }
        catch {}
        XCTAssertEqual(preference.saveCalls, 1); XCTAssertEqual(preference.reloadCalls, 1); XCTAssertEqual(preference.starts, 0)
    }
    func testDuplicateCurrentProviderPreferencesKeepActiveAndRemoveOtherMatches() async throws {
        let inactive = MinimalNEFixture.Preference(), active = MinimalNEFixture.Preference(status: .connected)
        let duplicate = MinimalNEFixture.Preference(), fixture = MinimalNEFixture([inactive, active, duplicate])
        let current = try await NETunnelProviderAccess.prepareCurrent(providerBundleIdentifier: MinimalNEFixture.provider,
            backend: fixture.backend)
        XCTAssertEqual(current.status(), .connected)
        XCTAssertEqual(active.removeCalls, 0); XCTAssertEqual(inactive.removeCalls, 1); XCTAssertEqual(duplicate.removeCalls, 1)
        XCTAssertEqual(fixture.makes, 0)
    }
    func testStalePreferenceLoadCannotRemoveAnyDuplicateOrForeignPreference() async throws {
        let first = MinimalNEFixture.Preference(), duplicate = MinimalNEFixture.Preference()
        let foreign = MinimalNEFixture.Preference(provider: "org.example.synthetic.OtherProvider")
        let fixture = MinimalNEFixture([first, duplicate, foreign])
        let entered = XCTestExpectation(description: "NE preference load suspended")
        var pending: CheckedContinuation<[NETunnelProviderAccess.Preference], Never>?
        var current = true
        let backend = NETunnelProviderAccess.Backend(loadAll: {
            entered.fulfill()
            return await withCheckedContinuation { pending = $0 }
        }, make: { fixture.created.boundary })
        let work = Task {
            try await NETunnelProviderAccess.prepareCurrent(providerBundleIdentifier: MinimalNEFixture.provider,
                backend: backend, isCurrent: { current })
        }
        await fulfillment(of: [entered], timeout: 3)
        current = false
        let continuation = try XCTUnwrap(pending)
        continuation.resume(returning: fixture.preferences.map(\.boundary))
        do { _ = try await work.value; XCTFail("An obsolete load must be cancelled before deduplication") }
        catch is CancellationError {}
        catch { XCTFail("Expected cancellation, not a preference failure") }
        XCTAssertEqual(first.removeCalls, 0); XCTAssertEqual(duplicate.removeCalls, 0)
        XCTAssertEqual(foreign.removeCalls, 0); XCTAssertEqual(foreign.stops, 0)
        XCTAssertTrue(first.configured.isEmpty); XCTAssertTrue(duplicate.configured.isEmpty)
        XCTAssertTrue(foreign.configured.isEmpty)
    }
    func testOtherProviderPreferencesAreNeverRemovedOrAdopted() async throws {
        let foreign = MinimalNEFixture.Preference(provider: "org.example.synthetic.OtherProvider", status: .connected)
        let fixture = MinimalNEFixture([foreign])
        let current = try await NETunnelProviderAccess.prepareCurrent(providerBundleIdentifier: MinimalNEFixture.provider,
            backend: fixture.backend)
        XCTAssertNotNil(current); XCTAssertEqual(fixture.makes, 1)
        XCTAssertEqual(foreign.removeCalls, 0); XCTAssertEqual(foreign.stops, 0); XCTAssertTrue(foreign.configured.isEmpty)
    }

    func testUnversionedOwnPreferenceIsRemovedAndFreshManagerCreated() async throws {
        let old = MinimalNEFixture.Preference(version: nil), fixture = MinimalNEFixture()
        fixture.preferences = [old]
        let current = try await NETunnelProviderAccess.prepareCurrent(providerBundleIdentifier: MinimalNEFixture.provider,
            backend: fixture.backend)
        XCTAssertEqual(old.removeCalls, 1); XCTAssertEqual(fixture.makes, 1)
        XCTAssertEqual(current.status(), .invalid)
        XCTAssertEqual(old.saveCalls + old.reloadCalls + old.starts, 0)
    }

    func testMultipleOldOwnPreferencesAreAllRemovedBeforeCreatingOneManager() async throws {
        let old = [MinimalNEFixture.Preference(version: nil), MinimalNEFixture.Preference(version: 0),
                   MinimalNEFixture.Preference(version: 2)]
        let fixture = MinimalNEFixture(old)
        _ = try await NETunnelProviderAccess.prepareCurrent(providerBundleIdentifier: MinimalNEFixture.provider,
            backend: fixture.backend)
        XCTAssertEqual(old.map(\.removeCalls), [1, 1, 1]); XCTAssertEqual(fixture.makes, 1)
        XCTAssertEqual(fixture.trace, ["preferences.load", "preferences.remove", "preferences.remove",
                                      "preferences.remove", "preferences.make"])
        XCTAssertTrue(old.allSatisfy { $0.starts == 0 && $0.configured.isEmpty })
    }

    func testUnsupportedPreferenceVersionsAreNeverReused() async throws {
        for version in [-1, 0, 2] {
            let old = MinimalNEFixture.Preference(version: version), fixture = MinimalNEFixture([old])
            _ = try await NETunnelProviderAccess.prepareCurrent(providerBundleIdentifier: MinimalNEFixture.provider,
                backend: fixture.backend)
            XCTAssertEqual(old.removeCalls, 1); XCTAssertEqual(fixture.makes, 1)
        }
    }

    func testCurrentVersionWinsOverOldActivePreferenceWithoutReadingLegacyFields() async throws {
        let old = MinimalNEFixture.Preference(status: .connected, version: nil)
        let current = MinimalNEFixture.Preference(status: .disconnected)
        let fixture = MinimalNEFixture([old, current])
        let selected = try await NETunnelProviderAccess.prepareCurrent(providerBundleIdentifier: MinimalNEFixture.provider,
            backend: fixture.backend)
        XCTAssertEqual(selected.cleanRoomPreferenceVersion, 1)
        XCTAssertEqual(selected.status(), .disconnected)
        XCTAssertEqual(old.removeCalls, 1); XCTAssertEqual(current.removeCalls, 0)
        XCTAssertEqual(fixture.makes, 0); XCTAssertEqual(old.stops, 0)
    }

    func testInactiveCurrentVersionDuplicatesKeepOnlyOneWithoutCreatingAnother() async throws {
        let disabled = MinimalNEFixture.Preference(enabled: false)
        let keep = MinimalNEFixture.Preference(), duplicate = MinimalNEFixture.Preference()
        let fixture = MinimalNEFixture([disabled, keep, duplicate])
        let selected = try await NETunnelProviderAccess.prepareCurrent(providerBundleIdentifier: MinimalNEFixture.provider,
            backend: fixture.backend)
        XCTAssertEqual(selected.cleanRoomPreferenceVersion, 1)
        XCTAssertEqual(disabled.removeCalls, 1); XCTAssertEqual(keep.removeCalls, 0)
        XCTAssertEqual(duplicate.removeCalls, 1); XCTAssertEqual(fixture.makes, 0)
    }

    func testForeignOldAndCurrentPreferencesRemainCompletelyUntouchedDuringCleanup() async throws {
        let foreignOld = MinimalNEFixture.Preference(provider: "org.example.synthetic.ForeignOld",
            status: .connected, version: nil)
        let foreignCurrent = MinimalNEFixture.Preference(provider: "org.example.synthetic.ForeignCurrent",
            status: .reasserting)
        let ownOld = MinimalNEFixture.Preference(version: nil)
        let ownCurrent = MinimalNEFixture.Preference()
        let fixture = MinimalNEFixture([foreignOld, ownOld, foreignCurrent, ownCurrent])
        _ = try await NETunnelProviderAccess.prepareCurrent(providerBundleIdentifier: MinimalNEFixture.provider,
            backend: fixture.backend)
        for foreign in [foreignOld, foreignCurrent] {
            XCTAssertEqual(foreign.removeCalls + foreign.saveCalls + foreign.reloadCalls, 0)
            XCTAssertEqual(foreign.starts + foreign.stops, 0); XCTAssertTrue(foreign.configured.isEmpty)
        }
        XCTAssertEqual(ownOld.removeCalls, 1); XCTAssertEqual(ownCurrent.removeCalls, 0)
        XCTAssertEqual(fixture.makes, 0)
    }

    func testStartupRefreshDoesNotRewriteOrRemoveOldPreference() async throws {
        let old = MinimalNEFixture.Preference(version: nil), fixture = MinimalNEFixture([old])
        let controller = fixture.controller()
        try await controller.refreshSystemStatus()
        XCTAssertEqual(old.removeCalls, 0); XCTAssertEqual(fixture.loads, 1); XCTAssertEqual(fixture.makes, 0)
        XCTAssertTrue(fixture.created.configured.isEmpty)
        XCTAssertEqual(fixture.created.saveCalls, 0); XCTAssertEqual(fixture.created.reloadCalls, 0)
        XCTAssertEqual(old.starts + fixture.created.starts, 0); XCTAssertTrue(fixture.saved.isEmpty)
        XCTAssertEqual(controller.operation, .idle); XCTAssertEqual(controller.state, .disconnected)
    }

    func testOneUserConnectAfterOldPreferenceRemovalSavesReloadsAndStartsExactlyOnce() async throws {
        let old = MinimalNEFixture.Preference(version: nil), fixture = MinimalNEFixture([old])
        let controller = fixture.controller()
        try await controller.connect(prepare: { MinimalNEFixture.configuration() })
        XCTAssertEqual(fixture.loads, 1); XCTAssertEqual(old.removeCalls, 1); XCTAssertEqual(fixture.makes, 1)
        XCTAssertEqual(fixture.created.saveCalls, 1); XCTAssertEqual(fixture.created.reloadCalls, 1)
        XCTAssertEqual(fixture.created.starts, 1); XCTAssertEqual(old.starts, 0)
        XCTAssertEqual(fixture.created.configured.first?.1, MinimalNEFixture.configuration().serverIPv4)
        XCTAssertEqual(fixture.trace, ["configuration.save", "preferences.load", "preferences.remove",
            "preferences.make", "configure", "preferences.save", "preferences.reload", "session.start"])
    }

    func testPluginFailedNeverAutomaticallyRetriesTheStartRequest() async throws {
        let preference = MinimalNEFixture.Preference(), fixture = MinimalNEFixture([preference])
        preference.disconnectError = VPNLastDisconnectError(
            NSError(domain: NEVPNConnectionErrorDomain, code: NEVPNConnectionError.pluginFailed.rawValue))
        let controller = fixture.controller()
        let published = expectation(description: "finite plugin failure published")
        let observation = controller.$lastError.sink {
            if case .connection(let error)? = $0, error.connectionError == "plugin-failed" { published.fulfill() }
        }
        defer { observation.cancel() }
        try await controller.connect(prepare: { MinimalNEFixture.configuration() })
        preference.emit(.disconnected)
        await fulfillment(of: [published], timeout: 3)
        XCTAssertEqual(controller.state, .disconnected); XCTAssertEqual(controller.operation, .idle)
        XCTAssertEqual(preference.starts, 1); XCTAssertEqual(fixture.loads, 1)
        XCTAssertEqual(preference.saveCalls, 1); XCTAssertEqual(preference.reloadCalls, 1)
        XCTAssertEqual(fixture.saved.count, 1)
    }

    func testRepeatedDisconnectedNotificationsNeverAutomaticallyRetry() async throws {
        let preference = MinimalNEFixture.Preference(), fixture = MinimalNEFixture([preference])
        let controller = fixture.controller()
        try await controller.connect(prepare: { MinimalNEFixture.configuration() })
        for status in [NEVPNStatus.disconnected, .disconnected, .invalid, .disconnected] {
            preference.emit(status)
        }
        await Task.yield()
        XCTAssertEqual(controller.state, .disconnected); XCTAssertEqual(controller.operation, .idle)
        XCTAssertEqual(preference.starts, 1); XCTAssertEqual(fixture.loads, 1)
        XCTAssertEqual(preference.saveCalls, 1); XCTAssertEqual(preference.reloadCalls, 1)
        XCTAssertEqual(fixture.saved.count, 1)
    }

    func testEachConfigurationCreatesARealFreshProtocolObject() throws {
        let manager = NETunnelProviderManager()
        let legacy = NETunnelProviderProtocol(); manager.protocolConfiguration = legacy
        NETunnelProviderAccess.configure(manager, providerBundleIdentifier: MinimalNEFixture.provider, serverAddress: "192.0.2.1")
        let first = try XCTUnwrap(manager.protocolConfiguration as? NETunnelProviderProtocol)
        NETunnelProviderAccess.configure(manager, providerBundleIdentifier: MinimalNEFixture.provider, serverAddress: "192.0.2.1")
        let second = try XCTUnwrap(manager.protocolConfiguration as? NETunnelProviderProtocol)
        XCTAssertFalse(first === legacy); XCTAssertFalse(second === first)
    }

    func testFreshProtocolDoesNotMergeAnyLegacyProviderConfiguration() throws {
        let manager = NETunnelProviderManager(), legacy = NETunnelProviderProtocol()
        legacy.providerConfiguration = ["syntheticLegacyKey": "synthetic-legacy-value",
            "generation": "synthetic-old-generation", "stage": "synthetic-old-stage"]
        manager.protocolConfiguration = legacy
        NETunnelProviderAccess.configure(manager, providerBundleIdentifier: MinimalNEFixture.provider, serverAddress: "192.0.2.1")
        let clean = try XCTUnwrap(manager.protocolConfiguration as? NETunnelProviderProtocol)
        XCTAssertNil(clean.providerConfiguration?["syntheticLegacyKey"])
        XCTAssertNil(clean.providerConfiguration?["generation"]); XCTAssertNil(clean.providerConfiguration?["stage"])
        XCTAssertEqual(legacy.providerConfiguration?["syntheticLegacyKey"] as? String, "synthetic-legacy-value")
    }

    func testRealProtocolProviderConfigurationContainsOnlyTheApprovedVersionKey() throws {
        let manager = NETunnelProviderManager()
        NETunnelProviderAccess.configure(manager, providerBundleIdentifier: MinimalNEFixture.provider, serverAddress: "192.0.2.1")
        let clean = try XCTUnwrap(manager.protocolConfiguration as? NETunnelProviderProtocol)
        XCTAssertEqual(Set(clean.providerConfiguration?.keys.map { $0 } ?? []),
                       [NETunnelProviderAccess.preferenceVersionKey])
    }

    func testRealProtocolCleanRoomPreferenceVersionIsOne() throws {
        let manager = NETunnelProviderManager()
        NETunnelProviderAccess.configure(manager, providerBundleIdentifier: MinimalNEFixture.provider, serverAddress: "192.0.2.1")
        XCTAssertEqual(NETunnelProviderAccess.cleanRoomPreferenceVersion, 1)
        XCTAssertEqual(NETunnelProviderAccess.preferenceVersion(of: manager), 1)
    }

    func testRealManagerIsExplicitlyEnabledBeforeSaving() {
        let manager = NETunnelProviderManager(); manager.isEnabled = false
        NETunnelProviderAccess.configure(manager, providerBundleIdentifier: MinimalNEFixture.provider, serverAddress: "192.0.2.1")
        XCTAssertTrue(manager.isEnabled)
    }

    func testRealManagerExplicitlyDisablesPreviouslyEnabledOnDemand() {
        let manager = NETunnelProviderManager(); manager.isOnDemandEnabled = true
        NETunnelProviderAccess.configure(manager, providerBundleIdentifier: MinimalNEFixture.provider, serverAddress: "192.0.2.1")
        XCTAssertFalse(manager.isOnDemandEnabled)
    }

    func testRealManagerClearsExistingOnDemandRules() {
        let manager = NETunnelProviderManager(); manager.onDemandRules = [NEOnDemandRuleConnect()]
        NETunnelProviderAccess.configure(manager, providerBundleIdentifier: MinimalNEFixture.provider, serverAddress: "192.0.2.1")
        XCTAssertTrue(manager.onDemandRules?.isEmpty ?? true)
    }

    func testRealProtocolUsesOnlyCurrentProviderGenericServerAndRoutingOption() throws {
        let manager = NETunnelProviderManager(), legacy = NETunnelProviderProtocol()
        legacy.providerBundleIdentifier = "org.example.synthetic.Obsolete"
        legacy.serverAddress = "synthetic-legacy.invalid"; legacy.username = "synthetic-legacy-user"
        legacy.passwordReference = Data("synthetic-legacy-reference".utf8)
        legacy.includeAllNetworks = false; manager.protocolConfiguration = legacy
        NETunnelProviderAccess.configure(manager, providerBundleIdentifier: MinimalNEFixture.provider, serverAddress: "192.0.2.1")
        let clean = try XCTUnwrap(manager.protocolConfiguration as? NETunnelProviderProtocol)
        XCTAssertEqual(clean.providerBundleIdentifier, MinimalNEFixture.provider)
        XCTAssertEqual(clean.serverAddress, "192.0.2.1")
        XCTAssertFalse(clean.includeAllNetworks)
        XCTAssertNil(clean.username); XCTAssertNil(clean.passwordReference)
    }

    func testRealVersionReaderRejectsMissingBooleanStringAndUnsupportedVersionValues() {
        let manager = NETunnelProviderManager(), tunnel = NETunnelProviderProtocol()
        manager.protocolConfiguration = tunnel
        XCTAssertNil(NETunnelProviderAccess.preferenceVersion(of: manager))
        for value: Any in [true, "1", 0, 2, NSNumber(value: 1.0), NSNull()] {
            tunnel.providerConfiguration = [NETunnelProviderAccess.preferenceVersionKey: value]
            manager.protocolConfiguration = tunnel
            XCTAssertNil(NETunnelProviderAccess.preferenceVersion(of: manager))
        }
        tunnel.providerConfiguration = [NETunnelProviderAccess.preferenceVersionKey: 1]
        manager.protocolConfiguration = tunnel
        XCTAssertEqual(NETunnelProviderAccess.preferenceVersion(of: manager), 1)
    }

}
