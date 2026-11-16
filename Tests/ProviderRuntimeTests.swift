import Foundation
import XCTest
import Darwin
@testable import NetworkClient

private final class BlockingProviderProbeGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var permits = 0
    private(set) var started = 0
    private(set) var active = 0
    private(set) var maximumActive = 0

    func run() {
        condition.lock()
        started += 1
        active += 1
        maximumActive = max(maximumActive, active)
        condition.broadcast()
        while permits == 0 { condition.wait() }
        permits -= 1
        active -= 1
        condition.broadcast()
        condition.unlock()
    }

    func waitUntilStarted(_ expected: Int, timeout: TimeInterval = 2) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while started < expected {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func release(_ count: Int = 1) {
        condition.lock()
        permits += count
        condition.broadcast()
        condition.unlock()
    }

    func snapshot() -> (started: Int, active: Int, maximum: Int) {
        condition.lock()
        defer { condition.unlock() }
        return (started, active, maximumActive)
    }
}

final class NetworkInterfaceInventoryTests: XCTestCase {
    func testCurrentPathFactsProduceRealIPv4AndIPv6Inventory() throws {
        let pathInterface = DefaultPathInterface(name: "en-test", index: 7, kind: .wifi)
        let path = DefaultPathSnapshot(
            interface: pathInterface,
            availableInterfaces: [pathInterface],
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true
        )
        let raw = NetworkInterfaceInventory.RawRecord(
            name: "en-test", index: 7, mtu: 1_500,
            addresses: ["192.0.2.10", "2001:db8::10"],
            systemFlags: UInt32(IFF_UP | IFF_RUNNING | IFF_MULTICAST)
        )
        let records = NetworkInterfaceInventory.records(
            from: [raw], path: path, tunnelAddresses: []
        )
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.name, "en-test")
        XCTAssertEqual(record.index, 7)
        XCTAssertEqual(record.kind, .wifi)
        XCTAssertEqual(record.addresses, ["192.0.2.10", "2001:db8::10"])
        XCTAssertFalse(record.metered)
    }

    func testTunnelAddressIsReportedAsTunnelNotPhysicalEgress() throws {
        let pathInterface = DefaultPathInterface(name: "utun-test", index: 9, kind: .other)
        let path = DefaultPathSnapshot(
            interface: pathInterface,
            availableInterfaces: [pathInterface],
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: false
        )
        let raw = NetworkInterfaceInventory.RawRecord(
            name: "utun-test", index: 9, mtu: 1_500,
            addresses: ["198.18.0.1"],
            systemFlags: UInt32(IFF_UP | IFF_RUNNING | IFF_POINTOPOINT)
        )
        let record = try XCTUnwrap(NetworkInterfaceInventory.records(
            from: [raw], path: path, tunnelAddresses: ["198.18.0.1"]
        ).first)
        XCTAssertEqual(record.kind, .tunnel)
    }

    func testIteratorReturnsEveryInventoryRecord() throws {
        let raw = NetworkInterfaceInventory.RawRecord(
            name: "lo-test", index: 1, mtu: 16_384,
            addresses: ["127.0.0.1"],
            systemFlags: UInt32(IFF_UP | IFF_RUNNING | IFF_LOOPBACK)
        )
        let iterator = NetworkInterfaceIterator(
            NetworkInterfaceInventory.records(from: [raw], path: nil, tunnelAddresses: [])
        )
        XCTAssertEqual(iterator.len(), 1)
        XCTAssertTrue(iterator.hasNext())
        XCTAssertEqual(iterator.next()?.name, "lo-test")
        XCTAssertFalse(iterator.hasNext())
    }

    func testAppOnlyPlatformAlsoPublishesCurrentSystemInterfaces() throws {
        let iterator = try MihomoAppPlatform().getInterfaces()
        XCTAssertGreaterThan(iterator.len(), 0)
        var observed = 0
        while iterator.hasNext() {
            let value = try XCTUnwrap(iterator.next())
            XCTAssertGreaterThan(value.index, 0)
            XCTAssertFalse(value.name.isEmpty)
            observed += 1
        }
        XCTAssertGreaterThan(observed, 0)
    }
}


/// SDK and filesystem calls are replaced only at the operations used by the
/// actual PacketTunnel start path. The production runtime owns all decisions.
final class ProviderRuntimeTests: XCTestCase {
    private typealias Runtime = ProviderRuntime
    private enum Injected: Error { case failure }
    private final class Fixture {
        let runtime: Runtime
        var calls: [String] = []
        var loadFails = false, prepareFails = false, geoFails = false
        var setupResult = true
        var setupError: NSError?, serviceError: NSError?
        var serviceIsNil = false, startFails = false
        var selectionSucceeds = true, selectionError: NSError?
        var selections: [String] = []
        var starts = 0, closes = 0, cleanups = 0
        var completions = 0
        var completionError: Error?
        init(runtime: Runtime = Runtime()) { self.runtime = runtime }
        var service: Runtime.Service {
            .init(start: {
                try Runtime.startService(start: {
                    self.calls.append("service.start"); self.starts += 1
                    if self.startFails { throw Injected.failure }
                }, coreName: "synthetic-core", select: { group, name in
                    self.calls.append("select:\(group)"); self.selections.append("\(group)=\(name)")
                    return (self.selectionSucceeds, self.selectionError)
                })
            }, close: { self.calls.append("service.close"); self.closes += 1 })
        }
        var operations: Runtime.Operations {
            .init(loadConfiguration: {
                self.calls.append("load")
                if self.loadFails { throw Injected.failure }
            }, prepareRuntime: {
                self.calls.append("runtime")
                if self.prepareFails { throw Injected.failure }
            }, ensureGeoData: {
                self.calls.append("geodata")
                if self.geoFails { throw Injected.failure }
            }, setup: {
                self.calls.append("setup"); return (self.setupResult, self.setupError)
            }, createService: {
                self.calls.append("create")
                return (self.serviceIsNil ? nil : self.service, self.serviceError)
            }, cleanup: { self.calls.append("cleanup"); self.cleanups += 1 })
        }
        @discardableResult func run() throws -> UUID {
            let id = try XCTUnwrap(runtime.beginStart())
            runtime.start(id: id, operations: operations) { error in self.complete(error) }
            return id
        }
        func complete(_ error: Error?) {
            calls.append("completion"); completions += 1; completionError = error
        }
    }

    private final class ControlFixture {
        var selected = "core-a"
        var currentMode = "rule"
        var setNodeSucceeds = true
        var nodeReadbackChanges = true
        var setModeSucceeds = true
        var modeReadbackChanges = true
        var closeSucceeds = true
        var selectedTargets: [String] = []
        var setModes: [String] = []
        var closeCalls = 0
        var selectorMembers: Set<String>? = ["core-a", "core-b"]
        var probeMeasurements: [String: Runtime.ProbeMeasurement] = [
            "core-a": .measured(41), "core-b": .measured(42)
        ]
        private let probeLock = NSLock()
        private var recordedProbeTargets: [String] = []

        var probeTargets: [String] {
            probeLock.lock()
            defer { probeLock.unlock() }
            return recordedProbeTargets
        }

        var service: Runtime.Service {
            Runtime.Service(
                start: {}, close: {},
                candidateCoreNames: ["core-a", "core-b"],
                candidatePoolRevision: String(repeating: "a", count: 64),
                selectorCandidateCoreNames: { self.selectorMembers },
                selectedNode: { self.selected },
                selectNode: { target in
                    self.selectedTargets.append(target)
                    if self.setNodeSucceeds && self.nodeReadbackChanges {
                        self.selected = target
                    }
                    return self.setNodeSucceeds
                },
                mode: { self.currentMode },
                setMode: { target in
                    self.setModes.append(target)
                    if self.setModeSucceeds && self.modeReadbackChanges {
                        self.currentMode = target
                    }
                    return self.setModeSucceeds
                },
                closeConnections: {
                    self.closeCalls += 1
                    return self.closeSucceeds
                },
                trafficSnapshot: {
                    .init(uploadBytesPerSecond: 123,
                          downloadBytesPerSecond: 456,
                          sampledAtUnixMilliseconds: 789)
                },
                probeNode: { target in
                    self.probeLock.lock()
                    self.recordedProbeTargets.append(target)
                    let measurement = self.probeMeasurements[target] ?? .failed
                    self.probeLock.unlock()
                    return measurement
                }
            )
        }
    }

    private func startRuntime(with service: Runtime.Service) throws -> (Runtime, UUID) {
        let runtime = Runtime()
        let id = try XCTUnwrap(runtime.beginStart())
        var completionError: Error?
        runtime.start(id: id, operations: .init(
            loadConfiguration: {}, prepareRuntime: {}, ensureGeoData: {},
            setup: { (true, nil) }, createService: { (service, nil) }, cleanup: {}
        )) { completionError = $0 }
        XCTAssertNil(completionError)
        return (runtime, id)
    }

    func testControlSocketUsesOneShortRuntimePathIndependentOfGeoData() {
        let runtime = URL(fileURLWithPath: "/tmp/provider-session", isDirectory: true)
        let socket = ProviderRuntimePaths.controlSocket(in: runtime)
        XCTAssertEqual(socket.lastPathComponent, "c.sock")
        XCTAssertEqual(socket.deletingLastPathComponent(), runtime)
        XCTAssertLessThanOrEqual(socket.path.utf8.count, 103)
        XCTAssertFalse(socket.path.contains("/GeoData/versions/"))
    }
    private func assertFailure(_ f: Fixture, _ category: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(f.completions, 1, file: file, line: line)
        guard let error = f.completionError as? Runtime.Failure else {
            return XCTFail("Expected a finite Provider error", file: file, line: line)
        }
        XCTAssertEqual(String(describing: error), category, file: file, line: line)
        XCTAssertEqual(f.cleanups, 1, file: file, line: line)
    }
    func testSuccessfulStraightLinePublishesServiceAfterStartAndCompletesNilOnce() throws {
        let f = Fixture(); _ = try f.run()
        XCTAssertEqual(f.calls, ["load", "runtime", "geodata", "setup", "create", "service.start", "select:VPN", "select:GLOBAL", "completion"])
        XCTAssertEqual(f.selections, ["VPN=synthetic-core", "GLOBAL=VPN"])
        XCTAssertEqual(f.starts, 1); XCTAssertEqual(f.completions, 1)
        XCTAssertNil(f.completionError); XCTAssertEqual(f.closes, 0); XCTAssertEqual(f.cleanups, 0)
    }
    func testConfigurationLoadFailureCompletesErrorOnceBeforeSDK() throws {
        let f = Fixture(); f.loadFails = true; _ = try f.run()
        assertFailure(f, "configuration")
        XCTAssertEqual(f.calls, ["load", "cleanup", "completion"]); XCTAssertEqual(f.starts, 0)
    }
    func testRuntimePreparationFailureCompletesErrorWithoutCreatingService() throws {
        let f = Fixture(); f.prepareFails = true; _ = try f.run()
        assertFailure(f, "runtime")
        XCTAssertFalse(f.calls.contains("geodata")); XCTAssertFalse(f.calls.contains("create"))
    }
    func testGeoDataFailureCompletesErrorOnceWithoutSetup() throws {
        let f = Fixture(); f.geoFails = true; _ = try f.run()
        assertFailure(f, "geoData"); XCTAssertFalse(f.calls.contains("setup"))
    }
    func testSetupFalseBecomesOrdinaryProviderError() throws {
        let f = Fixture(); f.setupResult = false; _ = try f.run()
        assertFailure(f, "setup"); XCTAssertFalse(f.calls.contains("create")); XCTAssertEqual(f.starts, 0)
    }
    func testSetupNSErrorFailsEvenWhenBoolIsTrue() throws {
        let f = Fixture(); f.setupError = NSError(domain: "synthetic-provider-fixture", code: 1)
        _ = try f.run(); assertFailure(f, "setup")
        XCTAssertFalse(f.calls.contains("create")); XCTAssertEqual(f.starts, 0)
    }
    func testNilServiceBecomesOrdinaryProviderError() throws {
        let f = Fixture(); f.serviceIsNil = true; _ = try f.run()
        assertFailure(f, "serviceCreation"); XCTAssertEqual(f.starts, 0); XCTAssertEqual(f.closes, 0)
    }
    func testServiceNSErrorClosesReturnedCandidateWithoutStartingIt() throws {
        let f = Fixture(); f.serviceError = NSError(domain: "synthetic-provider-fixture", code: 2)
        _ = try f.run(); assertFailure(f, "serviceCreation")
        XCTAssertEqual(f.starts, 0); XCTAssertEqual(f.closes, 1)
    }
    func testServiceStartFailureClosesCandidateAndCompletesErrorOnce() throws {
        let f = Fixture(); f.startFails = true; _ = try f.run()
        assertFailure(f, "serviceStart"); XCTAssertEqual(f.starts, 1); XCTAssertEqual(f.closes, 1)
        XCTAssertTrue(f.selections.isEmpty)
        // Cold-start selector application is part of the same real service
        // helper; false and NSError cannot publish an incorrectly routed start.
        for hasError in [false, true] {
            let selection = Fixture()
            selection.selectionSucceeds = hasError
            selection.selectionError = hasError ? NSError(domain: "synthetic-provider-fixture", code: 3) : nil
            _ = try selection.run(); assertFailure(selection, "serviceStart")
            XCTAssertEqual(selection.starts, 1); XCTAssertEqual(selection.closes, 1)
            XCTAssertEqual(selection.selections, ["VPN=synthetic-core"])
        }
    }
    func testStopClosesCurrentServiceAndCompletesOnce() throws {
        let f = Fixture(), id = try f.run()
        var stopped = 0
        f.runtime.stop(id: id) { stopped += 1 }
        XCTAssertEqual(stopped, 1); XCTAssertEqual(f.closes, 1); XCTAssertEqual(f.cleanups, 1)
        XCTAssertEqual(f.completions, 1)
    }
    func testStopWithoutServiceStillCompletesOnce() {
        let runtime = Runtime(); var stopped = 0
        runtime.stop(id: nil) { stopped += 1 }
        XCTAssertEqual(stopped, 1)
    }
    func testOldSessionStopCannotCloseReplacementService() throws {
        let runtime = Runtime(), old = Fixture(runtime: runtime), new = Fixture(runtime: runtime)
        let oldID = try old.run()
        runtime.stop(id: oldID) {}
        let newID = try new.run()
        var completed = 0
        runtime.stop(id: oldID) { completed += 1 }
        XCTAssertEqual(completed, 1); XCTAssertEqual(old.closes, 1); XCTAssertEqual(new.closes, 0)
        runtime.stop(id: newID) {}
        XCTAssertEqual(new.closes, 1)
    }
    func testLateOldStartCannotPublishOrCloseReplacementService() throws {
        let runtime = Runtime(), old = Fixture(runtime: runtime), new = Fixture(runtime: runtime)
        let oldID = try XCTUnwrap(runtime.beginStart())
        _ = runtime.cancelStart()
        let newID = try new.run()
        runtime.start(id: oldID, operations: old.operations) { old.complete($0) }
        XCTAssertEqual(old.completions, 1); XCTAssertNotNil(old.completionError)
        XCTAssertEqual(old.starts, 0); XCTAssertEqual(new.starts, 1); XCTAssertEqual(new.closes, 0)
        runtime.stop(id: newID) {}
        XCTAssertEqual(new.closes, 1)
    }

    func testNodeSwitchSetReadbackThenClosesConnections() {
        let f = ControlFixture()
        let result = Runtime.switchNode(target: "core-b", expectedPoolRevision: nil,
                                        service: f.service)
        XCTAssertEqual(f.selectedTargets, ["core-b"])
        XCTAssertEqual(f.closeCalls, 1)
        XCTAssertEqual(result.status, .applied)
        XCTAssertEqual(result.switchApplied, true)
        XCTAssertEqual(result.confirmedTargetCoreName, "core-b")
        XCTAssertEqual(result.connectionRefreshSucceeded, true)
    }

    func testNodeSwitchSetFailureKeepsOldSelectionWithoutClose() {
        let f = ControlFixture(); f.setNodeSucceeds = false
        let result = Runtime.switchNode(target: "core-b", expectedPoolRevision: nil,
                                        service: f.service)
        XCTAssertEqual(f.selected, "core-a")
        XCTAssertEqual(f.closeCalls, 0)
        XCTAssertEqual(result.switchApplied, false)
    }

    func testNodeSwitchReadbackMismatchKeepsFormalFailureWithoutClose() {
        let f = ControlFixture(); f.nodeReadbackChanges = false
        let result = Runtime.switchNode(target: "core-b", expectedPoolRevision: nil,
                                        service: f.service)
        XCTAssertEqual(f.selected, "core-a")
        XCTAssertEqual(f.closeCalls, 0)
        XCTAssertEqual(result.status, .rejected)
    }

    func testNodeSwitchCloseFailureDoesNotRollbackConfirmedSelector() {
        let f = ControlFixture(); f.closeSucceeds = false
        let result = Runtime.switchNode(target: "core-b", expectedPoolRevision: nil,
                                        service: f.service)
        XCTAssertEqual(f.selected, "core-b")
        XCTAssertEqual(result.switchApplied, true)
        XCTAssertEqual(result.connectionRefreshSucceeded, false)
    }

    func testNodeSwitchCurrentTargetDoesNoCoreOperation() {
        let f = ControlFixture()
        let result = Runtime.switchNode(target: "core-a", expectedPoolRevision: nil,
                                        service: f.service)
        XCTAssertTrue(f.selectedTargets.isEmpty)
        XCTAssertEqual(f.closeCalls, 0)
        XCTAssertEqual(result.status, .noChange)
    }

    func testNodeSwitchRejectsTargetOutsideLoadedSelector() {
        let f = ControlFixture()
        let result = Runtime.switchNode(target: "core-c", expectedPoolRevision: nil,
                                        service: f.service)
        XCTAssertEqual(result.status, .targetNotLoaded)
        XCTAssertTrue(f.selectedTargets.isEmpty)
    }

    func testNodeSwitchRejectsDifferentCandidatePoolRevision() {
        let f = ControlFixture()
        let result = Runtime.switchNode(
            target: "core-b", expectedPoolRevision: String(repeating: "b", count: 64),
            service: f.service
        )
        XCTAssertEqual(result.status, .targetNotLoaded)
        XCTAssertTrue(f.selectedTargets.isEmpty)
    }

    func testModeSwitchRuleToGlobalSetReadbackThenCloses() {
        let f = ControlFixture()
        let result = Runtime.switchMode(target: "global", service: f.service)
        XCTAssertEqual(f.setModes, ["global"])
        XCTAssertEqual(f.currentMode, "global")
        XCTAssertEqual(f.closeCalls, 1)
        XCTAssertEqual(result.switchApplied, true)
        XCTAssertEqual(result.confirmedMode, "global")
    }

    func testModeSwitchGlobalToRuleSetReadbackThenCloses() {
        let f = ControlFixture(); f.currentMode = "global"
        let result = Runtime.switchMode(target: "rule", service: f.service)
        XCTAssertEqual(f.currentMode, "rule")
        XCTAssertEqual(result.confirmedMode, "rule")
    }

    func testModeSwitchSetFailurePreservesOldMode() {
        let f = ControlFixture(); f.setModeSucceeds = false
        let result = Runtime.switchMode(target: "global", service: f.service)
        XCTAssertEqual(f.currentMode, "rule")
        XCTAssertEqual(f.closeCalls, 0)
        XCTAssertEqual(result.switchApplied, false)
    }

    func testModeSwitchReadbackMismatchPreservesFormalFailure() {
        let f = ControlFixture(); f.modeReadbackChanges = false
        let result = Runtime.switchMode(target: "global", service: f.service)
        XCTAssertEqual(f.currentMode, "rule")
        XCTAssertEqual(f.closeCalls, 0)
        XCTAssertEqual(result.status, .rejected)
    }

    func testModeSwitchCloseFailureKeepsConfirmedMode() {
        let f = ControlFixture(); f.closeSucceeds = false
        let result = Runtime.switchMode(target: "global", service: f.service)
        XCTAssertEqual(f.currentMode, "global")
        XCTAssertEqual(result.switchApplied, true)
        XCTAssertEqual(result.connectionRefreshSucceeded, false)
    }

    func testStep261ProbeAcceptsOnlyCurrentSelectorMembersWithoutMutatingCore() {
        let f = ControlFixture()
        let result = Runtime.probeNodes(
            targets: ["core-a", "core-outside"], expectedPoolRevision: nil,
            service: f.service
        )
        XCTAssertEqual(result.status, .applied)
        XCTAssertEqual(result.nodeProbeResults, [
            .init(coreName: "core-a", status: .measured, delayMilliseconds: 41),
            .init(coreName: "core-outside", status: .invalidTarget),
        ])
        XCTAssertEqual(f.probeTargets, ["core-a"])
        XCTAssertEqual(f.selected, "core-a")
        XCTAssertEqual(f.currentMode, "rule")
        XCTAssertTrue(f.selectedTargets.isEmpty)
        XCTAssertTrue(f.setModes.isEmpty)
        XCTAssertEqual(f.closeCalls, 0)
    }

    func testStep261ProbeContinuesAfterOneNodeFails() {
        let f = ControlFixture()
        f.probeMeasurements["core-a"] = .timedOut
        f.probeMeasurements["core-b"] = .failed
        let result = Runtime.probeNodes(
            targets: ["core-a", "core-b"], expectedPoolRevision: nil,
            service: f.service
        )
        XCTAssertEqual(result.nodeProbeResults, [
            .init(coreName: "core-a", status: .timedOut),
            .init(coreName: "core-b", status: .failed),
        ])
        XCTAssertEqual(Set(f.probeTargets), ["core-a", "core-b"])
        XCTAssertEqual(f.closeCalls, 0)
    }

    func testStep261ProbeRejectsStalePoolAndUnavailableSelectorReadback() {
        let stale = ControlFixture()
        let staleResult = Runtime.probeNodes(
            targets: ["core-a"],
            expectedPoolRevision: String(repeating: "b", count: 64),
            service: stale.service
        )
        XCTAssertEqual(staleResult.status, .targetNotLoaded)
        XCTAssertEqual(staleResult.nodeProbeResults?.first?.status, .invalidTarget)
        XCTAssertTrue(stale.probeTargets.isEmpty)

        let missing = ControlFixture()
        missing.selectorMembers = nil
        let missingResult = Runtime.probeNodes(
            targets: ["core-a"], expectedPoolRevision: nil,
            service: missing.service
        )
        XCTAssertEqual(missingResult.status, .unavailable)
        XCTAssertEqual(missingResult.nodeProbeResults?.first?.status, .unavailable)
        XCTAssertTrue(missing.probeTargets.isEmpty)
    }

    func testFinalLatencyProbeContractUsesUnifiedMaximumTen() {
        XCTAssertEqual(MihomoTunnelControlRequest.maximumProbeTargets, 10)
    }

    func testStep261DecodesFixedSDKGroupMembersAsCandidateAllowlist() {
        let json = """
        {"revision":"redacted","group":"VPN","total":2,"members":[
          {"name":"core-a","type":"VLESS","inline":true},
          {"name":"core-b","type":"Hysteria2","inline":true}
        ]}
        """
        XCTAssertEqual(
            Runtime.candidateCoreNames(fromGroupMembersJSON: json),
            ["core-a", "core-b"]
        )
        XCTAssertNil(Runtime.candidateCoreNames(
            fromGroupMembersJSON: "{\"group\":\"GLOBAL\",\"members\":[{\"name\":\"core-a\"}]}"
        ))
        XCTAssertNil(Runtime.candidateCoreNames(
            fromGroupMembersJSON: "{\"group\":\"VPN\",\"members\":[]}"
        ))
    }

    func testFinalLatencyProviderRunsTwentySingleNodeRequestsWithRollingMaximumTen() {
        let executor = ProviderProbeExecutor()
        let gate = BlockingProviderProbeGate()
        for _ in 0..<20 {
            XCTAssertTrue(executor.submit(targetCount: 1) { gate.run() })
        }

        XCTAssertTrue(gate.waitUntilStarted(10))
        XCTAssertEqual(gate.snapshot().started, 10)
        XCTAssertEqual(gate.snapshot().active, 10)
        XCTAssertEqual(gate.snapshot().maximum, 10)

        gate.release()
        XCTAssertTrue(gate.waitUntilStarted(11))
        XCTAssertEqual(gate.snapshot().active, 10)
        gate.release(19)
        executor.waitForAll()

        let final = gate.snapshot()
        XCTAssertEqual(final.started, 20)
        XCTAssertEqual(final.active, 0)
        XCTAssertEqual(final.maximum, 10, "MAX_OBSERVED_IN_FLIGHT=10")
        XCTAssertEqual(executor.concurrencySnapshot().active, 0)
        XCTAssertEqual(executor.concurrencySnapshot().maximum, 10)
    }

    func testStep263AProviderStopLeaseDrainsProbeBeforeCoreClose() {
        let executor = ProviderProbeExecutor()
        let gate = BlockingProviderProbeGate()
        XCTAssertTrue(executor.submit(targetCount: 1) { gate.run() })
        XCTAssertTrue(gate.waitUntilStarted(1))

        let closed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            executor.waitForAll()
            closed.signal()
        }
        XCTAssertEqual(closed.wait(timeout: .now()), .timedOut,
                       "Provider Core must stay leased while URLTest is active")
        gate.release()
        XCTAssertEqual(closed.wait(timeout: .now() + 2), .success)
    }

    func testStep263AOnlyNodeAndModeMutationsDrainConcurrentProbes() {
        XCTAssertTrue(ProviderControlScheduling.requiresProbeDrain(before: .switchNode))
        XCTAssertTrue(ProviderControlScheduling.requiresProbeDrain(before: .switchMode))
        XCTAssertFalse(ProviderControlScheduling.requiresProbeDrain(before: .probeNodes))
        XCTAssertFalse(ProviderControlScheduling.requiresProbeDrain(before: .trafficSnapshot))
        XCTAssertFalse(ProviderControlScheduling.requiresProbeDrain(before: nil))
    }

    func testStep263ATrafficSnapshotRemainsResponsiveDuringBlockedProbe() throws {
        let gate = BlockingProviderProbeGate()
        let service = Runtime.Service(
            start: {}, close: {},
            candidateCoreNames: ["core-a"],
            selectorCandidateCoreNames: { ["core-a"] },
            trafficSnapshot: {
                .init(uploadBytesPerSecond: 123,
                      downloadBytesPerSecond: 456,
                      sampledAtUnixMilliseconds: 789)
            },
            probeNode: { _ in gate.run(); return .measured(41) }
        )
        let (runtime, id) = try startRuntime(with: service)
        let executor = ProviderProbeExecutor()
        let probeFinished = DispatchSemaphore(value: 0)
        XCTAssertTrue(executor.submit(targetCount: 1) {
            let result = runtime.handle(.init(
                command: .probeNodes,
                payload: .init(probeCoreNames: ["core-a"])
            ))
            XCTAssertEqual(result.nodeProbeResults?.first?.delayMilliseconds, 41)
            probeFinished.signal()
        })
        XCTAssertTrue(gate.waitUntilStarted(1))

        let traffic = runtime.handle(.init(command: .trafficSnapshot))
        XCTAssertEqual(traffic.status, .applied)
        XCTAssertEqual(traffic.uploadBytesPerSecond, 123)
        XCTAssertEqual(traffic.downloadBytesPerSecond, 456)
        XCTAssertEqual(traffic.sampledAtUnixMilliseconds, 789)

        gate.release()
        XCTAssertEqual(probeFinished.wait(timeout: .now() + 2), .success)
        executor.waitForAll()
        runtime.stop(id: id) {}
    }

    func testUnknownCommandIsUnsupportedAndInactiveRuntimeUnavailable() throws {
        let runtime = Runtime()
        let unknownData = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "requestID": UUID().uuidString,
            "command": "restart",
        ])
        let unknown = try XCTUnwrap(MihomoTunnelControlCodec.decodeRequest(unknownData))
        XCTAssertEqual(runtime.handle(unknown).status, .unsupported)
        XCTAssertEqual(runtime.handle(.init(command: .trafficSnapshot)).status, .unavailable)
    }

}
