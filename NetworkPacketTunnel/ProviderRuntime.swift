import Foundation

/// Executes Provider URLTest requests without serializing independent nodes
/// behind one slow peer. Target-count accounting keeps the total Core load at
/// the same ten probes allowed by the control contract.
final class ProviderProbeExecutor: @unchecked Sendable {
    static let maximumConcurrentTargets = MihomoTunnelControlRequest.maximumProbeTargets

    private let condition = NSCondition()
    private let queue = DispatchQueue(
        label: "NetworkClient.MihomoPacketTunnel.probes",
        attributes: .concurrent
    )
    private let group = DispatchGroup()
    private let maximumConcurrentTargets: Int
    private var activeTargets = 0
    private var maximumObservedTargets = 0

    init(maximumConcurrentTargets: Int = ProviderProbeExecutor.maximumConcurrentTargets) {
        self.maximumConcurrentTargets = max(1, maximumConcurrentTargets)
    }

    @discardableResult
    func submit(
        targetCount: Int,
        operation: @escaping @Sendable () -> Void
    ) -> Bool {
        guard (1...maximumConcurrentTargets).contains(targetCount) else { return false }
        group.enter()
        queue.async { [self] in
            condition.lock()
            while activeTargets + targetCount > maximumConcurrentTargets {
                condition.wait()
            }
            activeTargets += targetCount
            maximumObservedTargets = max(maximumObservedTargets, activeTargets)
            condition.unlock()

            operation()

            condition.lock()
            activeTargets -= targetCount
            condition.broadcast()
            condition.unlock()
            group.leave()
        }
        return true
    }

    /// Called only from the Provider's serial lifecycle/control queue. New App
    /// messages cannot be submitted on that queue until this drain completes.
    func waitForAll() {
        group.wait()
    }

    func concurrencySnapshot() -> (active: Int, maximum: Int) {
        condition.lock()
        defer { condition.unlock() }
        return (activeTargets, maximumObservedTargets)
    }
}

enum ProviderControlScheduling {
    static func requiresProbeDrain(before command: MihomoTunnelControlCommand?) -> Bool {
        command == .switchNode || command == .switchMode
    }
}

enum ProviderRuntimePaths {
    static let controlSocketFileName = "c.sock"

    static func controlSocket(in runtimeDirectory: URL) -> URL {
        let socket = runtimeDirectory.appendingPathComponent(controlSocketFileName, isDirectory: false)
        #if DEBUG
        // The fixed SDK remains authoritative for Darwin's 103-byte Unix
        // socket gate. This assertion catches any future path-shape drift
        // without duplicating that limit in release business logic.
        assert(socket.path.utf8.count <= 103)
        #endif
        return socket
    }
}

/// Owns exactly one volatile Core service and its current start token.
final class ProviderRuntime: @unchecked Sendable {
    struct TrafficSnapshot: Equatable, Sendable {
        let uploadBytesPerSecond: Int64
        let downloadBytesPerSecond: Int64
        let sampledAtUnixMilliseconds: Int64
    }

    struct ProbeMeasurement: Equatable, Sendable {
        let status: MihomoTunnelNodeProbeStatus
        let delayMilliseconds: Int?

        static func measured(_ milliseconds: Int) -> Self {
            .init(status: .measured, delayMilliseconds: milliseconds)
        }
        static let timedOut = Self(status: .timedOut, delayMilliseconds: nil)
        static let failed = Self(status: .failed, delayMilliseconds: nil)
        static let unavailable = Self(status: .unavailable, delayMilliseconds: nil)
    }

    private final class ProbeAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: MihomoTunnelNodeProbeResult] = [:]

        func set(_ value: MihomoTunnelNodeProbeResult) {
            lock.lock()
            values[value.coreName] = value
            lock.unlock()
        }

        func value(for coreName: String) -> MihomoTunnelNodeProbeResult? {
            lock.lock()
            defer { lock.unlock() }
            return values[coreName]
        }
    }

    struct Service: @unchecked Sendable {
        let start: () throws -> Void
        let close: () throws -> Void
        let candidateCoreNames: Set<String>
        let candidatePoolRevision: String?
        let selectorCandidateCoreNames: () -> Set<String>?
        let selectedNode: () -> String?
        let selectNode: (String) -> Bool
        let mode: () -> String?
        let setMode: (String) -> Bool
        let closeConnections: () -> Bool
        let trafficSnapshot: () -> TrafficSnapshot?
        let probeNode: (String) -> ProbeMeasurement

        init(
            start: @escaping () throws -> Void,
            close: @escaping () throws -> Void,
            candidateCoreNames: Set<String> = [],
            candidatePoolRevision: String? = nil,
            selectorCandidateCoreNames: @escaping () -> Set<String>? = { nil },
            selectedNode: @escaping () -> String? = { nil },
            selectNode: @escaping (String) -> Bool = { _ in false },
            mode: @escaping () -> String? = { nil },
            setMode: @escaping (String) -> Bool = { _ in false },
            closeConnections: @escaping () -> Bool = { false },
            trafficSnapshot: @escaping () -> TrafficSnapshot? = { nil },
            probeNode: @escaping (String) -> ProbeMeasurement = { _ in .unavailable }
        ) {
            self.start = start
            self.close = close
            self.candidateCoreNames = candidateCoreNames
            self.candidatePoolRevision = candidatePoolRevision
            self.selectorCandidateCoreNames = selectorCandidateCoreNames
            self.selectedNode = selectedNode
            self.selectNode = selectNode
            self.mode = mode
            self.setMode = setMode
            self.closeConnections = closeConnections
            self.trafficSnapshot = trafficSnapshot
            self.probeNode = probeNode
        }
    }

    struct Operations {
        let loadConfiguration: () throws -> Void
        let prepareRuntime: () throws -> Void
        let ensureGeoData: () throws -> Void
        let setup: () throws -> (Bool, NSError?)
        let createService: () throws -> (Service?, NSError?)
        let cleanup: () -> Void
    }

    enum Failure: Error {
        case configuration
        case runtime
        case geoData
        case setup
        case serviceCreation
        case serviceStart
        case cancelled
    }

    private let lock = NSLock()
    private var currentStartID: UUID?
    private var current: (id: UUID, service: Service, cleanup: () -> Void)?

    func beginStart() -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard currentStartID == nil, current == nil else { return nil }
        let id = UUID()
        currentStartID = id
        return id
    }

    func cancelStart() -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        let id = currentStartID
        currentStartID = nil
        return id
    }

    func start(id: UUID, operations: Operations, completion: (Error?) -> Void) {
        var candidate: Service?
        var failure = Failure.configuration
        do {
            guard isCurrent(id) else { throw Failure.cancelled }
            try operations.loadConfiguration()
            failure = .runtime
            try operations.prepareRuntime()
            failure = .geoData
            try operations.ensureGeoData()
            failure = .setup
            let setup = try operations.setup()
            guard setup.0, setup.1 == nil else { throw Failure.setup }
            failure = .serviceCreation
            let created = try operations.createService()
            candidate = created.0
            guard let candidate, created.1 == nil else { throw Failure.serviceCreation }
            guard isCurrent(id) else { throw Failure.cancelled }
            failure = .serviceStart
            try candidate.start()
            lock.lock()
            let accepted = currentStartID == id
            if accepted { current = (id, candidate, operations.cleanup) }
            lock.unlock()
            guard accepted else { throw Failure.cancelled }
            completion(nil)
        } catch {
            try? candidate?.close()
            operations.cleanup()
            lock.lock()
            if currentStartID == id { currentStartID = nil }
            lock.unlock()
            completion(error is Failure ? error : failure)
        }
    }

    func stop(id: UUID?, completion: () -> Void) {
        lock.lock()
        let resource = id != nil && current?.id == id ? current : nil
        if current?.id == id { current = nil }
        if currentStartID == id { currentStartID = nil }
        lock.unlock()
        try? resource?.service.close()
        resource?.cleanup()
        completion()
    }

    func handle(_ request: MihomoTunnelControlRequest) -> MihomoTunnelControlResult {
        guard request.isWellFormed else {
            return .init(status: .malformed)
        }
        guard let command = request.knownCommand else {
            return .init(status: .unsupported)
        }
        lock.lock()
        let service = current?.service
        lock.unlock()
        guard let service else { return .init(status: .unavailable) }
        switch command {
        case .switchNode:
            return Self.switchNode(
                target: request.payload?.targetCoreName,
                expectedPoolRevision: request.payload?.candidatePoolRevision,
                service: service
            )
        case .switchMode:
            return Self.switchMode(target: request.payload?.mode, service: service)
        case .trafficSnapshot:
            guard let traffic = service.trafficSnapshot() else {
                return .init(status: .unavailable)
            }
            return .init(
                status: .applied,
                uploadBytesPerSecond: max(0, traffic.uploadBytesPerSecond),
                downloadBytesPerSecond: max(0, traffic.downloadBytesPerSecond),
                sampledAtUnixMilliseconds: traffic.sampledAtUnixMilliseconds
            )
        case .probeNodes:
            return Self.probeNodes(
                targets: request.payload?.probeCoreNames ?? [],
                expectedPoolRevision: request.payload?.candidatePoolRevision,
                service: service
            )
        }
    }

    static func probeNodes(
        targets: [String], expectedPoolRevision: String?, service: Service
    ) -> MihomoTunnelControlResult {
        guard expectedPoolRevision == nil
                || expectedPoolRevision == service.candidatePoolRevision else {
            return .init(status: .targetNotLoaded, nodeProbeResults: targets.map {
                .init(coreName: $0, status: .invalidTarget)
            })
        }
        guard let selectorMembers = service.selectorCandidateCoreNames() else {
            return .init(status: .unavailable, nodeProbeResults: targets.map {
                .init(coreName: $0, status: .unavailable)
            })
        }
        let allowed = service.candidateCoreNames.intersection(selectorMembers)
        let accumulator = ProbeAccumulator()
        let validTargets = targets.filter { target in
            guard allowed.contains(target) else {
                accumulator.set(.init(coreName: target, status: .invalidTarget))
                return false
            }
            return true
        }
        DispatchQueue.concurrentPerform(iterations: validTargets.count) { index in
            let target = validTargets[index]
            let measurement = service.probeNode(target)
            let normalizedDelay = measurement.status == .measured
                ? measurement.delayMilliseconds.flatMap { $0 >= 0 ? $0 : nil }
                : nil
            let status = measurement.status == .measured && normalizedDelay == nil
                ? MihomoTunnelNodeProbeStatus.failed : measurement.status
            accumulator.set(.init(
                coreName: target, status: status,
                delayMilliseconds: normalizedDelay
            ))
        }
        return .init(status: .applied, nodeProbeResults: targets.map { target in
            accumulator.value(for: target)
                ?? .init(coreName: target, status: .unavailable)
        })
    }

    static func candidateCoreNames(fromGroupMembersJSON json: String) -> Set<String>? {
        struct GroupMembers: Decodable {
            struct Member: Decodable { let name: String }
            let group: String
            let members: [Member]
        }
        guard let data = json.data(using: .utf8),
              let result = try? JSONDecoder().decode(GroupMembers.self, from: data),
              result.group == "VPN", !result.members.isEmpty else { return nil }
        return Set(result.members.map(\.name))
    }

    static func switchNode(
        target: String?, expectedPoolRevision: String?, service: Service
    ) -> MihomoTunnelControlResult {
        guard let target, service.candidateCoreNames.contains(target),
              expectedPoolRevision == nil
                || expectedPoolRevision == service.candidatePoolRevision else {
            return .init(status: .targetNotLoaded, switchApplied: false)
        }
        if service.selectedNode() == target {
            return .init(status: .noChange, switchApplied: true,
                         confirmedTargetCoreName: target,
                         connectionRefreshSucceeded: true)
        }
        guard service.selectNode(target), service.selectedNode() == target else {
            return .init(status: .rejected, switchApplied: false)
        }
        let refreshed = service.closeConnections()
        return .init(status: .applied, switchApplied: true,
                     confirmedTargetCoreName: target,
                     connectionRefreshSucceeded: refreshed)
    }

    static func switchMode(target: String?, service: Service) -> MihomoTunnelControlResult {
        guard let target, ["rule", "global"].contains(target) else {
            return .init(status: .malformed, switchApplied: false)
        }
        if service.mode()?.lowercased() == target {
            return .init(status: .noChange, switchApplied: true,
                         confirmedMode: target,
                         connectionRefreshSucceeded: true)
        }
        guard service.setMode(target), service.mode()?.lowercased() == target else {
            return .init(status: .rejected, switchApplied: false)
        }
        let refreshed = service.closeConnections()
        return .init(status: .applied, switchApplied: true,
                     confirmedMode: target,
                     connectionRefreshSucceeded: refreshed)
    }

    static func startService(
        start: () throws -> Void,
        coreName: String?,
        select: (String, String) -> (Bool, NSError?)
    ) throws {
        try start()
        guard let coreName, !coreName.isEmpty else { return }
        for (group, name) in [("VPN", coreName), ("GLOBAL", "VPN")] {
            let result = select(group, name)
            guard result.0, result.1 == nil else { throw Failure.serviceStart }
        }
    }

    private func isCurrent(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentStartID == id
    }
}
