
protocol NodeSelectionStoreProtocol: Sendable {
    func loadSelectedNodeID(accountScope: NodeSelectionAccountScope) async -> String?
    func saveSelectedNodeID(_ selectedNodeID: String, accountScope: NodeSelectionAccountScope) async
}
