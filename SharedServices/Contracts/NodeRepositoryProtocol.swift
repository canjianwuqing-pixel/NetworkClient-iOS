
protocol NodeRuntimeSourceProtocol: Sendable {
    func parsedSubscription() async -> ParsedSubscription?
}

protocol NodeRepositoryProtocol: NodeRuntimeSourceProtocol, Sendable {
    func snapshot() async -> NodeRepositorySnapshot
    func refresh(config: AppConfig, session: UserSession) async throws -> NodeRepositorySnapshot
    func prepareRefresh(config: AppConfig, session: UserSession) async throws -> PreparedNodeRefresh
    func commitRefresh(_ prepared: PreparedNodeRefresh) async throws -> NodeRepositorySnapshot
    func selectNode(id: String, session: UserSession) async throws -> NodeRepositorySnapshot
    func clear() async
}

struct PreparedNodeRefresh: Sendable {
    let snapshot: NodeRepositorySnapshot
    let subscription: ParsedSubscription?
    let accountScope: NodeSelectionAccountScope?
    let generation: UInt64?
}

// Existing injected repositories can keep their single-step behavior. The
// production repository stages the subscription until Core confirms a change.
extension NodeRepositoryProtocol {
    func prepareRefresh(config: AppConfig, session: UserSession) async throws -> PreparedNodeRefresh {
        let snapshot = try await refresh(config: config, session: session)
        return PreparedNodeRefresh(snapshot: snapshot, subscription: await parsedSubscription(),
                                   accountScope: session.nodeSelectionAccountScope, generation: nil)
    }
    func commitRefresh(_ prepared: PreparedNodeRefresh) async throws -> NodeRepositorySnapshot {
        prepared.snapshot
    }
}
