import Foundation

enum NodeSelectionIdentityKind: String, Codable, Sendable {
    case uniqueName, fingerprint, collision
}

enum RuntimeProxyRecordIssue: Equatable, Sendable {
    case ambiguousReference(field: String)
    case unresolvedReference(field: String)
}

struct RuntimeProxyRecord: Equatable, Sendable {
    let nodeID: String
    let originalName: String
    let coreName: String
    let originalProxy: [String: YAMLValue]
    let runtimeProxy: [String: YAMLValue]?
    let issue: RuntimeProxyRecordIssue?
}

struct ParsedSubscription: Equatable, Sendable {
    let nodes: [ProxyNode]
    let runtimeProxyRecords: [String: RuntimeProxyRecord]

    static let empty = ParsedSubscription(nodes: [], runtimeProxyRecords: [:])

    func selectionKind(for node: ProxyNode) -> NodeSelectionIdentityKind {
        let names = nodes.filter { $0.originalName == node.originalName }
        if names.count == 1 { return .uniqueName }
        return names.filter { $0.fingerprint == node.fingerprint }.count > 1
            ? .collision : .fingerprint
    }
}
// Shared with selectedTunnelRevision: preserve its existing sorted-JSON bytes.
enum OriginalProxyCanonicalization {
    static func digest(_ proxy: [String: YAMLValue]) throws -> String {
        let canonical = try JSONSerialization.data(
            withJSONObject: YAMLValue.object(proxy).foundationValue,
            options: [.sortedKeys]
        )
        return NodeHash.sha256Hex(String(decoding: canonical, as: UTF8.self))
    }
}
