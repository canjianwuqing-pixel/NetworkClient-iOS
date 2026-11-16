import SwiftUI

enum NodesLoadingPresentation: Equatable {
    case none
    case initial
    case refreshing

    static func phase(hasNodes: Bool, loadState: BusinessDataLoadState) -> Self {
        guard loadState.isLoading else { return .none }
        return hasNodes ? .refreshing : .initial
    }
}

struct NodesView: View {
    @EnvironmentObject private var brand: BrandProvider
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var vpn: MinimalVPNController
    @Environment(\.dismiss) private var dismiss

    private var loadingPresentation: NodesLoadingPresentation {
        .phase(hasNodes: !model.nodes.nodes.isEmpty, loadState: model.nodesLoadState)
    }

    var body: some View {
        Group {
            if model.session == nil { AccountRequiredView() }
            else { nodeContent }
        }
        .navigationTitle(LocalizedStringKey("destination.nodes"))
        .toolbar(.visible, for: .navigationBar)
        .onAppear { NodeInteractionTrace.record("page-appeared") }
    }

    private var nodeContent: some View {
        VStack(spacing: 0) {
            actionButtons
            if !model.nodes.nodes.isEmpty,
               let failure = model.nodesLoadState.failureMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    LocalizedMessageText(message: failure)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.footnote).foregroundStyle(brand.theme.secondary)
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
            if model.nodes.nodes.isEmpty { nodesStatus }
            else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 8) {
                        ForEach(model.nodes.nodes) { node in nodeRow(node) }
                            .transaction { $0.disablesAnimations = true }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 12)
                }
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button {
                NodeInteractionTrace.record("refresh-button-tapped")
                Task { await model.refreshNodes() }
            } label: {
                HStack(spacing: 8) {
                    Group {
                        if loadingPresentation == .refreshing {
                            ProgressView()
                                .controlSize(.small)
                                .tint(brand.theme.accent)
                                .accessibilityIdentifier("nodes.refresh.progress")
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .accessibilityIdentifier("nodes.refresh.icon")
                        }
                    }
                    .frame(width: 16, height: 16)
                    Text(LocalizedStringKey("nodes.action.refresh"))
                        .lineLimit(1).minimumScaleFactor(0.75)
                }
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: 44)
                .background(brand.theme.card, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(brand.theme.border))
            }
            .buttonStyle(.plain)
            .disabled(model.nodesLoadState.isLoading || model.testingAllNodes)
            .accessibilityLabel(LocalizedStringKey(
                loadingPresentation == .refreshing
                    ? "nodes.status.updating" : "nodes.action.refresh"
            ))
            .accessibilityIdentifier("nodes.refresh")

            Button {
                NodeInteractionTrace.record("latency-button-tapped")
                if model.testingAllNodes { model.cancelAllNodeLatencies() }
                else { Task { await model.testAllNodeLatencies() } }
            } label: {
                HStack(spacing: 6) {
                    if model.testingAllNodes { ProgressView().controlSize(.small).tint(brand.theme.onAccent) }
                    else { Image(systemName: "bolt.fill") }
                    Text(LocalizedStringKey(model.testingAllNodes
                        ? "nodes.latency.cancel_all" : "nodes.action.test_latency"))
                        .lineLimit(1).minimumScaleFactor(0.75)
                }
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: 44)
            }
            .buttonStyle(BrandButtonStyle())
            .disabled(!model.testingAllNodes &&
                (model.nodes.nodes.isEmpty || model.nodesLoadState.isLoading))
            .accessibilityIdentifier(model.testingAllNodes
                ? "nodes.latency.cancel_all" : "nodes.latency.test_all")
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 12)
    }

    private func nodeRow(_ node: ProxyNode) -> some View {
        let selected = model.nodes.selectedNodeID == node.id
        return Button { select(node.id) } label: {
            HStack(spacing: 12) {
                NodeCountryFlag(countryCode: node.countryCode, nodeName: node.displayName)
                Text(verbatim: node.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(LocalizedStringKey("nodes.badge.current"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(brand.theme.emphasis)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(brand.theme.tint, in: Capsule())
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(!selected)
                    .frame(width: 62)
                if node.available { latencyLabel(node.id) }
                else {
                    Text(LocalizedStringKey("nodes.latency.unavailable"))
                        .foregroundStyle(brand.theme.tertiary)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 14)
            .frame(height: 60).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("nodes.row.\(node.id)")
        .disabled((model.busy && model.showsGlobalBusyIndicator)
            || model.nodeSwitchInFlight)
        .allowsHitTesting(!model.testingAllNodes && !model.nodesLoadState.isLoading)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .frame(height: 60)
        .background(selected ? brand.theme.tint : brand.theme.card,
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(selected ? brand.theme.accent : brand.theme.border))
    }

    private func select(_ nodeID: String) {
        NodeInteractionTrace.record("node-row-tapped")
        if vpn.state == .connected {
            NodeSelectionPresentationFlow.perform(
                begin: { model.beginConnectedNodeSwitch(nodeID) },
                dismiss: { dismiss() }
            )
        } else {
            Task { await applyNodeSelection(nodeID) }
        }
    }

    @ViewBuilder private func latencyLabel(_ id: String) -> some View {
        if model.testingNodeIDs.contains(id) {
            ProgressView().controlSize(.small)
        } else {
            switch model.nodeLatencies[id] {
            case .testing: ProgressView().controlSize(.small)
            case let .measured(reading):
                Text(verbatim: "\(reading.displayMilliseconds) ms")
                    .foregroundStyle(reading.displayMilliseconds < 500
                        ? brand.theme.emphasis : brand.theme.warning)
            case .timedOut:
                Text(LocalizedStringKey("nodes.latency.timeout"))
                    .foregroundStyle(brand.theme.error)
            case .failed:
                Text(LocalizedStringKey("nodes.latency.failed_short"))
                    .foregroundStyle(brand.theme.error)
            case .unavailable:
                Text(LocalizedStringKey("nodes.latency.unavailable"))
                    .foregroundStyle(brand.theme.tertiary)
            case nil:
                Text(LocalizedStringKey("nodes.latency.not_tested"))
                    .foregroundStyle(brand.theme.tertiary)
            }
        }
    }

    private func applyNodeSelection(_ nodeID: String) async {
        await model.selectNode(nodeID)
    }

    @ViewBuilder
    private var nodesStatus: some View {
        switch model.nodesLoadState {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                    .accessibilityIdentifier("nodes.initial-loading.progress")
                Text(LocalizedStringKey("nodes.status.loading"))
            }
            .accessibilityIdentifier("nodes.initial-loading")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .idle, .empty, .loaded:
            ContentUnavailableView {
                Label(LocalizedStringKey("nodes.status.empty"), systemImage: "globe")
            } description: {
                Text(LocalizedStringKey("vpn.nodes.empty_notice"))
            } actions: {
                Button(LocalizedStringKey("nodes.action.retry")) { Task { await model.refreshNodes() } }
            }
        case .failed, .stale:
            ContentUnavailableView {
                Label(LocalizedStringKey("nodes.status.failed"), systemImage: "exclamationmark.triangle")
            } actions: {
                Button(LocalizedStringKey("nodes.action.retry")) {
                    Task { await model.refreshNodes() }
                }
                .disabled(model.nodesLoadState.isLoading)
            }
        }
    }
}

enum NodeSelectionPresentationFlow {
    static func perform(begin: () -> Bool, dismiss: () -> Void) {
        if begin() { dismiss() }
    }
}

struct NodeCountryFlag: View {
    let countryCode: String?
    let nodeName: String

    var body: some View {
        Group {
            switch CountryFlagResolver.visual(countryCode: countryCode, nodeName: nodeName) {
            case .taiwanImage:
                Image("TaiwanFlag")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 16)
            case let .emoji(flag):
                Text(verbatim: flag).font(.system(size: 23))
            }
        }
        .frame(width: 32, height: 22)
        .accessibilityHidden(true)
    }
}

private enum NodeInteractionTrace {
    static func record(_ event: String) {
        #if DEBUG || ROUTE_VALIDATION
        SafeLog.info("[NodeTrace] event=\(event)")
        #endif
    }
}
