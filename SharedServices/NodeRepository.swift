import Foundation

struct CurrentSubscriptionInfo: Equatable, Sendable {
    let subscriptionURL: String?
}

protocol CurrentSubscriptionInfoProviding: Sendable {
    func fetchCurrentSubscriptionInfo(
        config: AppConfig,
        session: UserSession
    ) async throws -> CurrentSubscriptionInfo
}

extension V2BoardAPIClient: CurrentSubscriptionInfoProviding {}

struct NodeRepositorySnapshot: Equatable, Sendable {
    let nodes: [ProxyNode]
    let selectedNodeID: String?

    var selectedNode: ProxyNode? {
        guard let selectedNodeID else { return nil }
        return nodes.first { $0.id == selectedNodeID }
    }

    static let empty = NodeRepositorySnapshot(nodes: [], selectedNodeID: nil)
}

enum NodeRepositoryError: Error, Equatable, Sendable {
    case accountScopeUnavailable
    case accountMismatch
    case nodeNotFound
}

/// Versioned repositories expose a synchronous final-publication check so the
/// MainActor does not introduce another suspension between checking and writing UI.
protocol NodeRefreshPublicationChecking: Sendable {
    func isCurrentRefresh(_ prepared: PreparedNodeRefresh) -> Bool
}

/// Also stamp the last committed transaction: a probe can begin while a
/// refresh is prepared but has not committed. This uses existing transaction
/// numbers, not another counter or a second catalog.
struct NodeLatencySubscriptionGeneration: Equatable, Sendable {
    let transaction: UInt64
    let committed: UInt64?
}

protocol NodeRepositoryGenerationReading: Sendable {
    var latencySubscriptionGeneration: NodeLatencySubscriptionGeneration { get }
}

protocol NodeSelectionIdentitySelecting: Sendable {
    func selectNode(id: String, session: UserSession, expectedRevision: String,
                    expectedCoreName: String) async throws -> NodeRepositorySnapshot
}

private final class NodeRefreshGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    private var committed: UInt64?

    func advance() -> UInt64 {
        lock.withLock {
            value &+= 1
            return value
        }
    }

    func latencySnapshot() -> NodeLatencySubscriptionGeneration {
        lock.withLock { NodeLatencySubscriptionGeneration(transaction: value, committed: committed) }
    }

    func recordCommit(_ generation: UInt64) {
        lock.withLock { committed = generation }
    }

    func matches(_ generation: UInt64) -> Bool {
        lock.withLock { value == generation }
    }
}

actor NodeRepository: NodeRepositoryProtocol, NodeRefreshPublicationChecking, NodeRepositoryGenerationReading,
                      NodeSelectionIdentitySelecting {
    private enum StagedSelectionPersistence {
        case binding(NodeSelectionBinding?)
        case legacy(String)
    }

    private let subscriptionInfoProvider: any CurrentSubscriptionInfoProviding
    private let subscriptionFetcher: any SubscriptionFetching
    private let subscriptionParser: any SubscriptionParsing
    private let selectionStore: any NodeSelectionStoreProtocol

    private var currentSnapshot = NodeRepositorySnapshot.empty
    private var currentParsedSubscription: ParsedSubscription?
    private var currentAccountScope: NodeSelectionAccountScope?
    private var stagedSelectionPersistence: (generation: UInt64, value: StagedSelectionPersistence)?
    // This is the existing refresh/selection generation, not a second counter.
    private nonisolated let refreshGeneration = NodeRefreshGeneration()

    init(
        subscriptionInfoProvider: any CurrentSubscriptionInfoProviding = V2BoardAPIClient(),
        subscriptionFetcher: any SubscriptionFetching = SubscriptionFetcher(),
        subscriptionParser: any SubscriptionParsing = SubscriptionParser(),
        selectionStore: any NodeSelectionStoreProtocol = NodeSelectionStore()
    ) {
        self.subscriptionInfoProvider = subscriptionInfoProvider
        self.subscriptionFetcher = subscriptionFetcher
        self.subscriptionParser = subscriptionParser
        self.selectionStore = selectionStore
    }

    func snapshot() -> NodeRepositorySnapshot {
        currentSnapshot
    }

    func parsedSubscription() -> ParsedSubscription? {
        currentParsedSubscription
    }

    nonisolated var latencySubscriptionGeneration: NodeLatencySubscriptionGeneration {
        refreshGeneration.latencySnapshot()
    }

    nonisolated func isCurrentRefresh(_ prepared: PreparedNodeRefresh) -> Bool {
        guard let generation = prepared.generation else { return false }
        return refreshGeneration.matches(generation)
    }

    func refresh(config: AppConfig, session: UserSession) async throws -> NodeRepositorySnapshot {
        let prepared = try await prepareRefresh(config: config, session: session)
        return try await commitRefresh(prepared)
    }

    func prepareRefresh(config: AppConfig, session: UserSession) async throws -> PreparedNodeRefresh {
        let expectedGeneration = refreshGeneration.advance()
        let started = Date()
        guard let accountScope = session.nodeSelectionAccountScope else {
            throw NodeRepositoryError.accountScopeUnavailable
        }

        let subscriptionInfo = try await subscriptionInfoProvider.fetchCurrentSubscriptionInfo(
            config: config,
            session: session
        )
        #if DEBUG || ROUTE_VALIDATION
        SafeLog.info("[NodeTrace] event=subscription-info-ready elapsedMs=\(Int(Date().timeIntervalSince(started) * 1_000))")
        #endif
        guard let subscriptionURL = subscriptionInfo.subscriptionURL else {
            try Task.checkCancellation()
            guard refreshGeneration.matches(expectedGeneration) else { throw CancellationError() }
            guard acceptsReplacementCatalog([], accountScope: accountScope) else {
                throw SubscriptionFetchError.missingSubscriptionURL
            }
            return PreparedNodeRefresh(snapshot: .empty, subscription: nil,
                                       accountScope: accountScope, generation: expectedGeneration)
        }

        #if DEBUG || ROUTE_VALIDATION
        SafeLog.info("[NodeTrace] event=yaml-download-start")
        #endif
        let rawYAML = try await subscriptionFetcher.fetchSubscription(
            from: subscriptionURL,
            userAgent: config.safeUserAgent,
            builtInProxy: config.builtInProxy
        )
        #if DEBUG || ROUTE_VALIDATION
        SafeLog.info("[NodeTrace] event=yaml-download-done elapsedMs=\(Int(Date().timeIntervalSince(started) * 1_000))")
        #endif
        try Task.checkCancellation()
        guard refreshGeneration.matches(expectedGeneration) else { throw CancellationError() }
        let parsedSubscription = try subscriptionParser.parse(rawYAML)
        #if DEBUG || ROUTE_VALIDATION
        SafeLog.info("[NodeTrace] event=yaml-parsed elapsedMs=\(Int(Date().timeIntervalSince(started) * 1_000)) count=\(parsedSubscription.nodes.count)")
        #endif
        guard acceptsReplacementCatalog(parsedSubscription.nodes, accountScope: accountScope) else {
            throw SubscriptionParserError.noValidNodes
        }
        let stored: StoredNodeSelection?
        if let store = selectionStore as? any NodeSelectionBindingStoring {
            stored = await store.loadSelection(accountScope: accountScope)
        } else {
            stored = await selectionStore.loadSelectedNodeID(accountScope: accountScope).map(StoredNodeSelection.legacy)
        }
        try Task.checkCancellation()
        guard refreshGeneration.matches(expectedGeneration) else { throw CancellationError() }
        let previous = currentAccountScope == accountScope ? currentParsedSubscription : nil
        let preferredID = currentAccountScope == accountScope
            ? (currentSnapshot.selectedNodeID ?? stored?.nodeID) : stored?.nodeID
        let resolvedID = try resolvedSelection(stored, accountScope: accountScope, in: parsedSubscription)
        // Preserve an explicit but now-missing selection as a stale ID. This
        // keeps "no selection" distinct from "the selected node disappeared"
        // without guessing or auto-selecting a replacement node.
        let selectedID = resolvedID ?? preferredID.flatMap { preferred in
            parsedSubscription.nodes.contains(where: { $0.id == preferred }) ? nil : preferred
        }
        var binding: NodeSelectionBinding?
        if let selectedID, parsedSubscription.nodes.contains(where: { $0.id == selectedID }) {
            binding = try selectionBinding(id: selectedID, in: parsedSubscription)
        } else if let selectedID {
            binding = try previousBinding(selectedID, stored: stored, previous: previous)
        }
        if let preferredID, let old = try previousBinding(preferredID, stored: stored, previous: previous),
           old.kind == .collision, let next = binding {
            // Keep exact-configuration identity after a collision shrinks. A
            // later singleton replacement must not revive logical-ID fallback.
            binding = NodeSelectionBinding(nodeID: next.nodeID, configurationDigest: next.configurationDigest, kind: .collision)
        }
        let persistence: StagedSelectionPersistence
        if let selectedID, binding == nil {
            persistence = .legacy(selectedID)
        } else {
            persistence = .binding(binding)
        }
        stagedSelectionPersistence = (expectedGeneration, persistence)
        let snapshot = NodeRepositorySnapshot(
            nodes: parsedSubscription.nodes,
            selectedNodeID: selectedID
        )
        return PreparedNodeRefresh(snapshot: snapshot, subscription: parsedSubscription,
                                   accountScope: accountScope, generation: expectedGeneration)
    }

    func commitRefresh(_ prepared: PreparedNodeRefresh) async throws -> NodeRepositorySnapshot {
        guard let generation = prepared.generation, refreshGeneration.matches(generation),
              let accountScope = prepared.accountScope else { throw CancellationError() }
        try Task.checkCancellation()
        if let store = selectionStore as? any NodeSelectionBindingStoring {
            let persistence = stagedSelectionPersistence?.generation == generation
                ? stagedSelectionPersistence?.value
                : .binding(try selectionBinding(id: prepared.snapshot.selectedNodeID, in: prepared.subscription))
            switch persistence {
            case let .binding(binding):
                await store.saveSelection(binding, accountScope: accountScope)
            case let .legacy(nodeID):
                await store.saveSelectedNodeID(nodeID, accountScope: accountScope)
            case nil:
                throw CancellationError()
            }
            try Task.checkCancellation()
            guard refreshGeneration.matches(generation) else { throw CancellationError() }
        } else if let selectedNodeID = prepared.snapshot.selectedNodeID {
            await selectionStore.saveSelectedNodeID(selectedNodeID, accountScope: accountScope)
            try Task.checkCancellation()
            guard refreshGeneration.matches(generation) else { throw CancellationError() }
        }
        currentParsedSubscription = prepared.subscription
        let snapshot = replaceSnapshot(nodes: prepared.snapshot.nodes,
                                       selectedNodeID: prepared.snapshot.selectedNodeID,
                                       accountScope: accountScope)
        refreshGeneration.recordCommit(generation)
        SafeLog.info("[Node] subscription refreshed nodeCount=\(snapshot.nodes.count)")
        return snapshot
    }

    func selectNode(id: String, session: UserSession) async throws -> NodeRepositorySnapshot {
        try await selectNode(id: id, session: session, expected: nil)
    }

    func selectNode(id: String, session: UserSession, expectedRevision: String,
                    expectedCoreName: String) async throws -> NodeRepositorySnapshot {
        try await selectNode(id: id, session: session, expected: (expectedRevision, expectedCoreName))
    }

    private func selectNode(id: String, session: UserSession,
                            expected: (revision: String, coreName: String)?) async throws -> NodeRepositorySnapshot {
        guard let accountScope = session.nodeSelectionAccountScope else {
            throw NodeRepositoryError.accountScopeUnavailable
        }
        guard currentAccountScope == accountScope else { throw NodeRepositoryError.accountMismatch }
        guard currentSnapshot.nodes.contains(where: { $0.id == id }) else {
            throw NodeRepositoryError.nodeNotFound
        }
        if let expected {
            guard currentParsedSubscription?.runtimeProxyRecords[id]?.coreName == expected.coreName,
                  try SelectedNodeConfigurationIdentity.revision(in: currentParsedSubscription, nodeID: id)
                    == expected.revision else { throw CancellationError() }
        }

        // A selection made while a subscription is staged supersedes that
        // preparation. Its later commit must not restore the old selection.
        let expectedGeneration = refreshGeneration.advance()
        if let store = selectionStore as? any NodeSelectionBindingStoring {
            let binding = try selectionBinding(id: id, in: currentParsedSubscription)
            await store.saveSelection(binding, accountScope: accountScope)
        } else {
            await selectionStore.saveSelectedNodeID(id, accountScope: accountScope)
        }
        // Storage crosses actors; clear, refresh, or a newer choice may have
        // superseded this transaction while its completion was suspended.
        guard currentAccountScope == accountScope,
              refreshGeneration.matches(expectedGeneration) else { throw CancellationError() }
        currentSnapshot = NodeRepositorySnapshot(nodes: currentSnapshot.nodes, selectedNodeID: id)
        return currentSnapshot
    }

    func clear() {
        _ = refreshGeneration.advance()
        currentSnapshot = .empty
        currentParsedSubscription = nil
        currentAccountScope = nil
        stagedSelectionPersistence = nil
    }

    private func acceptsReplacementCatalog(
        _ nodes: [ProxyNode], accountScope: NodeSelectionAccountScope
    ) -> Bool {
        guard currentAccountScope == accountScope, !currentSnapshot.nodes.isEmpty else { return true }
        // Preserve the existing empty-catalog rule even if the old list has no
        // available nodes. Reject zero-available only when it is a regression.
        guard !nodes.isEmpty else { return false }
        return !currentSnapshot.nodes.contains(where: \.available)
            || nodes.contains(where: \.available)
    }

    private func validSelectedNodeID(_ selectedNodeID: String?, in nodes: [ProxyNode]) -> String? {
        guard let selectedNodeID,
              nodes.contains(where: { $0.id == selectedNodeID }) else {
            return nil
        }
        return selectedNodeID
    }

    private func selectionBinding(id: String?, in subscription: ParsedSubscription?) throws -> NodeSelectionBinding? {
        guard let id else { return nil }
        guard let subscription, let node = subscription.nodes.first(where: { $0.id == id }),
              let record = subscription.runtimeProxyRecords[id] else {
            throw NodeRepositoryError.nodeNotFound
        }
        return NodeSelectionBinding(nodeID: id,
            configurationDigest: try OriginalProxyCanonicalization.digest(record.originalProxy),
            kind: subscription.selectionKind(for: node))
    }

    private func resolvedSelection(_ stored: StoredNodeSelection?, accountScope: NodeSelectionAccountScope,
                                   in replacement: ParsedSubscription) throws -> String? {
        let sameAccount = currentAccountScope == accountScope
        let preferredID = sameAccount ? (currentSnapshot.selectedNodeID ?? stored?.nodeID) : stored?.nodeID
        guard let preferredID else { return nil }
        let previous = sameAccount ? currentParsedSubscription : nil
        let binding = try previousBinding(preferredID, stored: stored, previous: previous)

        if let binding {
            let matches = try replacement.runtimeProxyRecords.values.filter {
                try OriginalProxyCanonicalization.digest($0.originalProxy) == binding.configurationDigest
            }
            let oldMatches = try previous?.runtimeProxyRecords.values.filter {
                try OriginalProxyCanonicalization.digest($0.originalProxy) == binding.configurationDigest
            }.count
            // Identical configuration occurrences cannot prove an entity.
            guard matches.count <= 1, oldMatches == nil || oldMatches == 1 else { return nil }
            if let match = matches.first {
                return validSelectedNodeID(match.nodeID, in: replacement.nodes)
            }
            // Preserve logical configuration updates outside collision groups.
            // Collision bindings NEVER fall through to the valid-ID path.
            if binding.kind != .collision,
               let node = replacement.nodes.first(where: { $0.id == preferredID }),
               replacement.selectionKind(for: node) == binding.kind {
                return node.id
            }
            return sameAccount ? uniquelyRenamedSelection(preferredID, in: replacement) : nil
        }
        // A metadata-free collision ordinal cannot identify the old entity.
        guard let node = replacement.nodes.first(where: { $0.id == preferredID }),
              replacement.selectionKind(for: node) != .collision else { return nil }
        return node.id
    }

    private func previousBinding(_ id: String, stored: StoredNodeSelection?,
                                 previous: ParsedSubscription?) throws -> NodeSelectionBinding? {
        if previous?.runtimeProxyRecords[id] != nil {
            let current = try selectionBinding(id: id, in: previous)
            if case let .bound(saved) = stored, saved.nodeID == id,
               saved.configurationDigest == current?.configurationDigest { return saved }
            return current
        }
        if case let .bound(saved) = stored, saved.nodeID == id { return saved }
        return nil
    }

    /// A name change alters the legacy node ID. Migrate only when the old and
    /// new subscriptions each contain exactly one otherwise identical proxy.
    /// Any duplicate or changed connection field is ambiguous and fails closed.
    private func uniquelyRenamedSelection(
        _ oldID: String?, in replacement: ParsedSubscription
    ) -> String? {
        guard let oldID, let previous = currentParsedSubscription,
              let original = previous.runtimeProxyRecords[oldID] else {
            return nil
        }
        let connection = original.originalProxy.filter { $0.key != "name" }
        let priorMatches = previous.runtimeProxyRecords.values.filter {
            $0.originalProxy.filter { $0.key != "name" } == connection
        }
        let newMatches = replacement.runtimeProxyRecords.values.filter {
            $0.originalProxy.filter { $0.key != "name" } == connection
        }
        guard priorMatches.count == 1, newMatches.count == 1,
              let candidate = newMatches.first,
              replacement.nodes.contains(where: { $0.id == candidate.nodeID }) else {
            return nil
        }
        return candidate.nodeID
    }

    @discardableResult
    private func replaceSnapshot(
        nodes: [ProxyNode],
        selectedNodeID: String?,
        accountScope: NodeSelectionAccountScope
    ) -> NodeRepositorySnapshot {
        currentSnapshot = NodeRepositorySnapshot(nodes: nodes, selectedNodeID: selectedNodeID)
        currentAccountScope = accountScope
        return currentSnapshot
    }
}
