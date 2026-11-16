import Foundation

struct NodeSelectionAccountScope: RawRepresentable, Hashable, Sendable {
    let rawValue: String

    init?(accountIdentifier: String) {
        let normalized = accountIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return nil }
        rawValue = NodeHash.sha256Hex(normalized)
    }

    init?(rawValue: String) {
        guard rawValue.count == 64, rawValue.allSatisfy(\.isHexDigit) else { return nil }
        self.rawValue = rawValue.lowercased()
    }
}

extension UserSession {
    var nodeSelectionAccountScope: NodeSelectionAccountScope? {
        NodeSelectionAccountScope(accountIdentifier: email)
    }
}

struct NodeSelectionBinding: Codable, Equatable, Sendable {
    let nodeID: String
    let configurationDigest: String
    let kind: NodeSelectionIdentityKind
}

enum StoredNodeSelection: Equatable, Sendable {
    case legacy(String)
    case bound(NodeSelectionBinding)
    case invalid

    var nodeID: String? {
        switch self {
        case let .legacy(id): id
        case let .bound(binding): binding.nodeID
        case .invalid: nil
        }
    }
}

// Existing injected legacy stores need not implement binding persistence.
protocol NodeSelectionBindingStoring: NodeSelectionStoreProtocol {
    func loadSelection(accountScope: NodeSelectionAccountScope) async -> StoredNodeSelection?
    func saveSelection(_ binding: NodeSelectionBinding?, accountScope: NodeSelectionAccountScope) async
}

actor NodeSelectionStore: NodeSelectionBindingStoring {
    private struct Record: Codable {
        let schemaVersion: Int
        let binding: NodeSelectionBinding?
    }
    private let defaults: UserDefaults

    init(suiteName: String? = nil) {
        defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    func loadSelectedNodeID(accountScope: NodeSelectionAccountScope) -> String? {
        defaults.string(forKey: preferenceKey(accountScope: accountScope))?.nodeSelectionNilIfEmpty
    }

    func saveSelectedNodeID(_ selectedNodeID: String, accountScope: NodeSelectionAccountScope) {
        let normalizedNodeID = selectedNodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedNodeID.isEmpty else { return }
        defaults.set(normalizedNodeID, forKey: preferenceKey(accountScope: accountScope))
        defaults.removeObject(forKey: bindingKey(accountScope: accountScope))
    }

    func loadSelection(accountScope: NodeSelectionAccountScope) -> StoredNodeSelection? {
        let key = bindingKey(accountScope: accountScope)
        guard defaults.object(forKey: key) != nil else {
            return loadSelectedNodeID(accountScope: accountScope).map(StoredNodeSelection.legacy)
        }
        guard let data = defaults.data(forKey: key),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.schemaVersion == 1 else { return .invalid }
        // A cleared record is a tombstone: never revive a legacy ordinal.
        guard let binding = record.binding else { return nil }
        guard !binding.nodeID.isEmpty,
              binding.configurationDigest.count == 64,
              binding.configurationDigest.allSatisfy(\.isHexDigit),
              loadSelectedNodeID(accountScope: accountScope) == binding.nodeID else { return .invalid }
        return .bound(binding)
    }

    func saveSelection(_ binding: NodeSelectionBinding?, accountScope: NodeSelectionAccountScope) {
        // One actor turn writes only this account's ID and digest sidecar.
        // A torn/mismatched pair is rejected, never downgraded to a legacy ID.
        guard let data = try? JSONEncoder().encode(Record(schemaVersion: 1, binding: binding)) else { return }
        defaults.set(data, forKey: bindingKey(accountScope: accountScope))
        if let binding {
            defaults.set(binding.nodeID, forKey: preferenceKey(accountScope: accountScope))
        } else {
            defaults.removeObject(forKey: preferenceKey(accountScope: accountScope))
        }
    }

    private func bindingKey(accountScope: NodeSelectionAccountScope) -> String {
        "nodeSelection.binding.v1.\(accountScope.rawValue)"
    }

    private func preferenceKey(accountScope: NodeSelectionAccountScope) -> String {
        "nodeSelection.selectedNodeId.\(accountScope.rawValue)"
    }
}

private extension String {
    var nodeSelectionNilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
