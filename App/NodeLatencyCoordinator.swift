import Foundation
import Network

/// The one owner of raw latency readings, probe generation and task lifetime.
/// AppModel publishes a snapshot of `readings` for SwiftUI, but never keeps a
/// second mutable latency cache.
@MainActor
final class NodeLatencyCoordinator {
    private(set) var readings: [String: NodeLatencyState] = [:]
    private(set) var generation = UUID()
    private(set) var active = false
    private(set) var task: Task<Void, Never>?
    private var owner: UUID?
    private var baseline: [String: NodeLatencyState] = [:]
    private var physicalInterfaces: Set<NWInterface.InterfaceType>?

    func replaceReadings(_ readings: [String: NodeLatencyState]) {
        self.readings = readings
    }

    func begin() -> UUID? {
        guard !active else { return nil }
        generation = UUID()
        owner = generation
        active = true
        baseline = readings
        return generation
    }

    func track(_ task: Task<Void, Never>) {
        self.task = task
    }

    func isCurrent(_ generation: UUID) -> Bool {
        active && owner == generation && self.generation == generation
            && task?.isCancelled != true
    }

    @discardableResult
    func finish(generation completedGeneration: UUID) -> Bool {
        // Cancellation changes the generation, but the old owner still has
        // to release its activity slot after it drains.
        guard owner == completedGeneration else { return false }
        owner = nil
        task = nil
        active = false
        baseline = [:]
        return true
    }

    /// Completed values remain visible on cancellation; only unfinished
    /// `testing` rows return to their pre-test state.
    @discardableResult
    func cancelActive() -> Bool {
        guard active || task != nil else { return false }
        generation = UUID()
        task?.cancel()
        for (id, state) in readings where state == .testing {
            if let previous = baseline[id] { readings[id] = previous }
            else { readings.removeValue(forKey: id) }
        }
        return true
    }

    func invalidate() {
        cancelActive()
        generation = UUID()
        readings = [:]
        baseline = [:]
    }

    /// Empty/virtual-only snapshots are not evidence of a physical network
    /// switch while Packet Tunnel path observation is settling.
    func physicalPathChanged(_ path: APIHealthNetworkPath) -> Bool {
        let physical: Set<NWInterface.InterfaceType> = [.wifi, .cellular, .wiredEthernet]
        let current = path.usedInterfaceTypes.intersection(physical)
        guard !current.isEmpty else { return false }
        defer { physicalInterfaces = current }
        guard let previous = physicalInterfaces else { return false }
        return previous != current
    }

    func reconcile(
        previousNodes: [ProxyNode], previousSubscription: ParsedSubscription?,
        refreshedNodes: [ProxyNode], refreshedSubscription: ParsedSubscription?
    ) -> Bool {
        let previousByID = Dictionary(uniqueKeysWithValues: previousNodes.map { ($0.id, $0) })
        let refreshedByID = Dictionary(uniqueKeysWithValues: refreshedNodes.map { ($0.id, $0) })
        func unchanged(_ id: String) -> Bool {
            guard let old = previousByID[id], let new = refreshedByID[id],
                  old.fingerprint == new.fingerprint, old.available == new.available,
                  let oldRevision = try? SelectedNodeConfigurationIdentity.revision(
                    in: previousSubscription, nodeID: id
                  ),
                  let newRevision = try? SelectedNodeConfigurationIdentity.revision(
                    in: refreshedSubscription, nodeID: id
                  ) else { return false }
            return oldRevision == newRevision
        }
        let oldIDs = Set(previousByID.keys)
        let newIDs = Set(refreshedByID.keys)
        guard oldIDs != newIDs || oldIDs.contains(where: { !unchanged($0) }) else {
            return false
        }
        cancelActive()
        readings = readings.filter { entry in
            entry.value != .testing && unchanged(entry.key)
        }
        return true
    }
}
