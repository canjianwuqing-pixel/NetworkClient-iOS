import SwiftUI

struct VPNConnectionErrorPresentation: Equatable {
    enum Action: Equatable { case openNodeList, dismiss }

    let titleKey: String
    let message: LocalizedMessage
    let actionKey: String
    let action: Action

    static func makeIfPresentable(_ error: Error) -> VPNConnectionErrorPresentation? {
        guard !(error is CancellationError) else { return nil }
        return make(error)
    }

    static func make(_ error: Error) -> VPNConnectionErrorPresentation {
        if let preflight = error as? VPNConnectionPreflightError {
            switch preflight {
            case .noNodeSelected:
                return .init(
                    titleKey: L10nKey.vpnPreflightNoNodeTitle,
                    message: .localized(L10nKey.vpnPreflightNoNodeMessage),
                    actionKey: L10nKey.vpnPreflightSelectNodeAction,
                    action: .openNodeList
                )
            case .selectedNodeMissing:
                return .init(
                    titleKey: L10nKey.vpnPreflightSelectedNodeMissingTitle,
                    message: .localized(L10nKey.vpnPreflightSelectedNodeMissingMessage),
                    actionKey: L10nKey.vpnPreflightChooseAnotherNodeAction,
                    action: .openNodeList
                )
            case .nodeConfigurationInvalid:
                return .init(
                    titleKey: L10nKey.vpnPreflightInvalidConfigurationTitle,
                    message: .localized(L10nKey.vpnPreflightInvalidConfigurationMessage),
                    actionKey: L10nKey.vpnPreflightReplaceNodeAction,
                    action: .openNodeList
                )
            }
        }
        let message: LocalizedMessage
        if let client = error as? NetworkClientError {
            message = client.userFacingMessage
        } else if let diagnostic = error as? TunnelDiagnostic {
            message = .localized(diagnostic.userFacingKey)
        } else if let localized = error as? LocalizedError,
                  let description = localized.errorDescription?.nilIfEmpty {
            message = .verbatim(description)
        } else {
            message = .localized(L10nKey.vpnConnectUnableMessage)
        }
        return .init(
            titleKey: L10nKey.vpnConnectUnableTitle,
            message: message,
            actionKey: L10nKey.commonClose,
            action: .dismiss
        )
    }

    var modalRequest: GlobalModalRequest {
        switch action {
        case .openNodeList:
            return GlobalModalRequest(
                kind: .result(.error),
                title: .localized(titleKey),
                message: message,
                primary: GlobalModalButton(
                    title: .localized(actionKey),
                    identifier: "global.modal.primary"
                ),
                secondary: GlobalModalButton(
                    title: .localized(L10nKey.commonClose),
                    role: .cancel,
                    identifier: "global.modal.secondary"
                )
            )
        case .dismiss:
            return .result(
                style: .error,
                title: .localized(titleKey),
                message: message,
                primaryTitle: .localized(actionKey)
            )
        }
    }

    func ownerAction(for choice: GlobalModalChoice) -> Action {
        action == .openNodeList && choice == .primary ? .openNodeList : .dismiss
    }
}

enum HomeNoticePresentation {
    static func request(
        for notice: HomeNotice,
        timeZone: TimeZone = .current
    ) -> GlobalModalRequest {
        GlobalModalRequest.announcement(
            title: notice.title.isEmpty
                ? .localized(L10nKey.homeNoticeFallbackTitle)
                : .verbatim(notice.title),
            detail: dateMessage(for: notice.createdAt, timeZone: timeZone),
            message: notice.plainContent.isEmpty
                ? .localized("home.notice.empty_content")
                : .verbatim(notice.plainContent),
            copyText: notice.plainContent
        )
    }

    private static func dateMessage(
        for timestamp: Int64,
        timeZone: TimeZone
    ) -> LocalizedMessage? {
        guard timestamp > 0 else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return .verbatim(formatter.string(
            from: Date(timeIntervalSince1970: TimeInterval(timestamp))
        ))
    }
}

enum HomeNoticeAutoPresentation {
    static func popupQueue(from notices: [HomeNotice]) -> [HomeNotice] {
        var queuedIDs = Set<Int>()
        return notices
            .filter(\.isPopup)
            .sorted { $0.id > $1.id }
            .filter { queuedIDs.insert($0.id).inserted }
    }
}

/// Owns only the current runtime announcement round. It intentionally has no
/// UserDefaults or other persistence: every successful notice network load is
/// evaluated again solely from the server-provided `弹窗` tag.
@MainActor
final class HomeNoticeAutoPresentationCoordinator: ObservableObject {
    private struct SessionContext: Equatable {
        let accountScope: String
        let generation: UUID
    }

    private struct LoadRound: Equatable {
        let session: SessionContext
        let revision: UInt64
    }

    private var loadRound: LoadRound?
    private var pendingNotices: [HomeNotice] = []
    private var pendingNoticeIDs = Set<Int>()
    private var automaticTask: Task<Void, Never>?
    private var manualTask: Task<Void, Never>?
    private var resumeTask: Task<Void, Never>?
    private var activeAutomaticNoticeID: Int?
    private var isHomeVisible = false
    private var isAppActive = false
    private var sessionContext: SessionContext?
    private weak var presenter: GlobalModalPresenter?

    var pendingIDs: [Int] { pendingNotices.map(\.id) }

    func receiveSuccessfulLoad(
        revision: UInt64,
        notices: [HomeNotice],
        accountScope: String?,
        generation: UUID?,
        presenter: GlobalModalPresenter
    ) {
        guard revision > 0,
              let accountScope,
              let generation else { return }
        let session = SessionContext(accountScope: accountScope, generation: generation)
        updateSessionContext(session)
        self.presenter = presenter

        let round = LoadRound(session: session, revision: revision)
        guard round != loadRound else {
            scheduleResume()
            return
        }

        loadRound = round
        pendingNotices = HomeNoticeAutoPresentation.popupQueue(from: notices)
        pendingNoticeIDs = Set(pendingNotices.map(\.id))
        scheduleResume()
    }

    func updateAvailability(
        homeVisible: Bool,
        appActive: Bool,
        accountScope: String?,
        generation: UUID?,
        presenter: GlobalModalPresenter
    ) {
        self.presenter = presenter
        isHomeVisible = homeVisible
        isAppActive = appActive

        guard let accountScope, let generation else {
            clearRuntimeRound()
            return
        }
        updateSessionContext(SessionContext(
            accountScope: accountScope,
            generation: generation
        ))
        scheduleResume()
    }

    func modalAvailabilityChanged(presenter: GlobalModalPresenter) {
        self.presenter = presenter
        guard presenter.activeRequest == nil else { return }
        scheduleResume()
    }

    func presentManually(
        _ notice: HomeNotice,
        timeZone: TimeZone,
        presenter: GlobalModalPresenter
    ) {
        self.presenter = presenter
        guard activeAutomaticNoticeID != notice.id,
              automaticTask == nil,
              manualTask == nil,
              presenter.activeRequest == nil else { return }

        let round = loadRound
        let wasQueued = removePendingNotice(id: notice.id)
        let request = HomeNoticePresentation.request(for: notice, timeZone: timeZone)
        manualTask = Task { @MainActor [weak self, weak presenter] in
            guard let self, let presenter else { return }
            let choice = await presenter.present(request)
            self.manualTask = nil

            if choice == .alreadyPresenting,
               wasQueued,
               self.loadRound == round {
                self.insertPendingNotice(notice)
            }
            self.scheduleResume()
        }
    }

    private func updateSessionContext(_ context: SessionContext) {
        guard sessionContext != context else { return }
        sessionContext = context
        clearRuntimeRound(keepingSessionContext: true)
    }

    private func clearRuntimeRound(keepingSessionContext: Bool = false) {
        automaticTask?.cancel()
        manualTask?.cancel()
        resumeTask?.cancel()
        automaticTask = nil
        manualTask = nil
        resumeTask = nil
        activeAutomaticNoticeID = nil
        loadRound = nil
        pendingNotices = []
        pendingNoticeIDs = []
        if !keepingSessionContext { sessionContext = nil }
    }

    private func scheduleResume() {
        guard resumeTask == nil else { return }
        resumeTask = Task { @MainActor [weak self] in
            // Give root-level message/payment coordination the first chance to
            // claim the single Global Modal slot.
            await Task.yield()
            guard let self else { return }
            self.resumeTask = nil
            self.resumeIfPossible()
        }
    }

    private func resumeIfPossible() {
        guard automaticTask == nil,
              manualTask == nil,
              isHomeVisible,
              isAppActive,
              let sessionContext,
              loadRound?.session == sessionContext,
              let presenter,
              presenter.activeRequest == nil,
              let notice = pendingNotices.first else { return }

        pendingNotices.removeFirst()
        pendingNoticeIDs.remove(notice.id)
        activeAutomaticNoticeID = notice.id
        let round = loadRound
        let request = HomeNoticePresentation.request(for: notice)

        automaticTask = Task { @MainActor [weak self, weak presenter] in
            guard let self, let presenter else { return }
            let choice = await presenter.present(request)
            self.automaticTask = nil
            self.activeAutomaticNoticeID = nil

            if choice == .alreadyPresenting,
               self.loadRound == round {
                self.insertPendingNotice(notice)
            }
            self.scheduleResume()
        }
    }

    @discardableResult
    private func removePendingNotice(id: Int) -> Bool {
        guard pendingNoticeIDs.remove(id) != nil else { return false }
        pendingNotices.removeAll { $0.id == id }
        return true
    }

    private func insertPendingNotice(_ notice: HomeNotice) {
        guard notice.isPopup,
              pendingNoticeIDs.insert(notice.id).inserted else { return }
        pendingNotices.append(notice)
        pendingNotices.sort { $0.id > $1.id }
    }
}

enum ProxyModeModalPresentation {
    static func request(currentMode: ProxyMode) -> GlobalModalRequest {
        .selection(
            title: .localized(L10nKey.proxyModeDialogTitle),
            options: [
                GlobalModalSelectionOption(
                    id: ProxyMode.rule.rawValue,
                    title: .localized(L10nKey.proxyModeRule),
                    message: .localized(L10nKey.proxyModeDialogRuleDescription),
                    systemImage: "arrow.triangle.branch"
                ),
                GlobalModalSelectionOption(
                    id: ProxyMode.global.rawValue,
                    title: .localized(L10nKey.proxyModeGlobal),
                    message: .localized(L10nKey.proxyModeDialogGlobalDescription),
                    systemImage: "globe"
                )
            ],
            initialSelectionID: currentMode.rawValue,
            primaryTitle: .localized(L10nKey.proxyModeDialogApply),
            secondaryTitle: .localized(L10nKey.proxyModeDialogCancel)
        )
    }

    static func selectedMode(for choice: GlobalModalChoice) -> ProxyMode? {
        guard case let .selection(id) = choice else { return nil }
        return ProxyMode(rawValue: id)
    }

    @MainActor
    static func appliedMode(
        selectedMode: ProxyMode,
        currentMode: ProxyMode,
        isConnected: Bool,
        switchMode: (ProxyMode) async throws -> Bool
    ) async -> ProxyMode? {
        guard selectedMode != currentMode else { return nil }
        guard isConnected else { return selectedMode }
        do {
            return try await switchMode(selectedMode) ? selectedMode : nil
        } catch {
            return nil
        }
    }
}

enum HomeVPNPresentation {
    static func statusTitleKey(
        state: MinimalVPNController.State,
        operation: MinimalVPNController.Operation,
        disconnectActionPending: Bool
    ) -> String {
        disconnectActionPending || operation == .disconnecting
            ? "vpn.state.disconnecting"
            : state.titleKey
    }

    static func isPowerButtonDisabled(
        state: MinimalVPNController.State,
        operation: MinimalVPNController.Operation,
        disconnectActionPending: Bool
    ) -> Bool {
        disconnectActionPending
            || operation == .disconnecting
            || (state == .disconnected && operation == .connecting)
    }

    static func beginPowerAction(
        state: MinimalVPNController.State,
        operation: MinimalVPNController.Operation,
        disconnectActionPending: inout Bool
    ) -> Bool {
        guard !disconnectActionPending, operation != .disconnecting else { return false }
        if state == .connected, operation == .idle {
            disconnectActionPending = true
        }
        return true
    }

    static func endPowerAction(
        latchedDisconnectAction: Bool,
        disconnectActionPending: inout Bool
    ) {
        if latchedDisconnectAction {
            disconnectActionPending = false
        }
    }
}

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var brand: BrandProvider
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var vpn: MinimalVPNController
    @EnvironmentObject private var modalPresenter: GlobalModalPresenter
    @EnvironmentObject private var usageTermsConsent: UsageTermsConsentCoordinator
    @EnvironmentObject private var noticeAutoPresenter: HomeNoticeAutoPresentationCoordinator
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @State private var noticeIndex = 0
    @State private var showNodes = false
    @State private var disconnectActionPending = false
    private var notice: HomeNotice? { model.notices.isEmpty ? nil : model.notices[noticeIndex % model.notices.count] }
    private var selectedNodeLatency: LocalizedMessage {
        guard let id = model.nodes.selectedNodeID else { return .localized("nodes.latency.not_tested") }
        if model.testingNodeIDs.contains(id) { return .localized("nodes.latency.testing") }
        switch model.nodeLatencies[id] {
        case let .measured(reading): return .verbatim("\(reading.displayMilliseconds) ms")
        case .testing: return .localized("nodes.latency.testing")
        case .timedOut: return .localized("nodes.latency.timeout")
        case .failed: return .localized("nodes.latency.error.general")
        case .unavailable: return .localized("nodes.latency.unavailable")
        case nil: return .localized("nodes.latency.not_tested")
        }
    }
    private var selectedNodeLatencyColor: Color {
        guard let id = model.nodes.selectedNodeID else { return brand.theme.tertiary }
        if model.testingNodeIDs.contains(id) { return brand.theme.tertiary }
        switch model.nodeLatencies[id] {
        case let .measured(reading):
            return reading.displayMilliseconds < 500 ? brand.theme.emphasis : brand.theme.warning
        case .timedOut, .failed: return brand.theme.error
        default: return brand.theme.tertiary
        }
    }
    private var remaining: Int64? {
        guard let account = model.session else { return nil }
        return max(0, account.transferEnableBytes - min(account.transferEnableBytes, account.uploadBytes) - min(account.transferEnableBytes, account.downloadBytes))
    }
    private var ratio: Double {
        guard let account = model.session, account.transferEnableBytes > 0, let remaining else { return 0 }
        return min(1, max(0, Double(remaining) / Double(account.transferEnableBytes)))
    }
    var body: some View {
        BrandScreen {
            ScrollView {
                VStack(spacing: 0) {
                    Button {
                        if let notice {
                            noticeAutoPresenter.presentManually(
                                notice,
                                timeZone: .current,
                                presenter: modalPresenter
                            )
                        } else if model.noticesLoadState.failureMessage != nil {
                            Task { await model.refreshNotices() }
                        }
                    } label: {
                        HStack(spacing: 0) {
                            Image(systemName: "bell.fill").font(.system(size: 15)).foregroundStyle(brand.theme.emphasis)
                                .frame(width: 40, height: 40).background(brand.theme.tint, in: Circle()).frame(width: 50, alignment: .leading)
                            VStack(alignment: .leading, spacing: 4) {
                                noticeTitle.font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                Text(notice.map {
                                    Date(timeIntervalSince1970: Double($0.createdAt)).formatted(
                                        Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)
                                    )
                                } ?? "--").font(.system(size: 10)).foregroundStyle(brand.theme.tertiary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            if model.noticesLoadState.isLoading {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: notice == nil && model.noticesLoadState.failureMessage != nil ? "arrow.clockwise" : "chevron.right")
                                    .font(.system(size: 13)).foregroundStyle(brand.theme.tertiary)
                            }
                        }.padding(.horizontal, 12).frame(height: 64).surfaceCard()
                    }.buttonStyle(.plain).disabled(notice == nil && model.noticesLoadState.failureMessage == nil)
                    if notice != nil, let failure = model.noticesLoadState.failureMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                            LocalizedMessageText(message: failure).lineLimit(2)
                            Spacer(minLength: 4)
                            Button(LocalizedStringKey("home.notice.retry")) {
                                Task { await model.refreshNotices() }
                            }
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(brand.theme.secondary)
                        .padding(.horizontal, 12).padding(.top, 8)
                    }
                    if let failure = model.accountLoadState.failureMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                            LocalizedMessageText(message: failure).lineLimit(2)
                            Spacer(minLength: 4)
                            Button(LocalizedStringKey("home.notice.retry")) {
                                Task { await model.refreshAccount() }
                            }
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(brand.theme.secondary)
                        .padding(.horizontal, 12).padding(.top, 8)
                    }
                    trafficCard.padding(.top, 10)
                    connectionCard.padding(.top, 12)
                    Button { showNodes = true } label: {
                        actionRow(
                            "globe.asia.australia.fill",
                            title: model.nodes.selectedNode.map { .verbatim($0.displayName) } ?? .localized(L10nKey.homeNodeSelect),
                            trailing: selectedNodeLatency,
                            trailingColor: selectedNodeLatencyColor,
                            nodeFlag: model.nodes.selectedNode
                        )
                    }.buttonStyle(.plain).accessibilityIdentifier("home.nodes").padding(.top, 10)
                    Button { presentModeSelection() } label: {
                        actionRow(
                            settings.mode == .rule ? "arrow.triangle.branch" : "globe",
                            title: .localized(settings.mode.titleKey),
                            trailing: .verbatim("")
                        )
                    }.buttonStyle(.plain).padding(.top, 8)
                }.padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .navigationDestination(isPresented: $showNodes) { NodesView() }
        .task(id: model.notices.map(\.id)) {
            noticeIndex = 0
            while model.notices.count > 1 { try? await Task.sleep(for: .seconds(5)); guard !Task.isCancelled else { return }; noticeIndex += 1 }
        }
        .task {
            async let account: Void = model.refreshAccountIfNeeded()
            async let notices: Void = model.refreshNoticesIfNeeded()
            _ = await (account, notices)
        }
        .onAppear { updateNoticeAutoPresentation(homeVisible: true) }
        .onDisappear { updateNoticeAutoPresentation(homeVisible: false) }
        .onChange(of: scenePhase) { _, _ in
            updateNoticeAutoPresentation(homeVisible: true)
        }
        .onChange(of: model.noticePresentationAccountScope) { _, _ in
            updateNoticeAutoPresentation(homeVisible: true)
        }
        .onChange(of: model.noticePresentationGeneration) { _, _ in
            updateNoticeAutoPresentation(homeVisible: true)
        }
        .onChange(of: model.noticesLoadRevision, initial: true) { _, revision in
            noticeAutoPresenter.receiveSuccessfulLoad(
                revision: revision,
                notices: model.notices,
                accountScope: model.noticePresentationAccountScope,
                generation: model.noticePresentationGeneration,
                presenter: modalPresenter
            )
        }
        .onChange(of: modalPresenter.activeRequest?.id) { _, _ in
            noticeAutoPresenter.modalAvailabilityChanged(presenter: modalPresenter)
        }
    }

    private func updateNoticeAutoPresentation(homeVisible: Bool) {
        noticeAutoPresenter.updateAvailability(
            homeVisible: homeVisible,
            appActive: scenePhase == .active,
            accountScope: model.noticePresentationAccountScope,
            generation: model.noticePresentationGeneration,
            presenter: modalPresenter
        )
    }

    private func presentModeSelection() {
        let request = ProxyModeModalPresentation.request(currentMode: settings.mode)
        Task {
            let choice = await modalPresenter.present(request)
            guard let selectedMode = ProxyModeModalPresentation.selectedMode(
                for: choice
            ) else { return }
            guard let appliedMode = await ProxyModeModalPresentation.appliedMode(
                selectedMode: selectedMode,
                currentMode: settings.mode,
                isConnected: vpn.state == .connected,
                switchMode: { try await vpn.switchMode($0) }
            ) else { return }
            settings.mode = appliedMode
        }
    }

    @ViewBuilder
    private var noticeTitle: some View {
        if let notice {
            if notice.title.isEmpty {
                Text(LocalizedStringKey("home.notice.fallback_title"))
            } else {
                Text(verbatim: notice.title)
            }
        } else {
            switch model.noticesLoadState {
            case .idle, .loading:
                Text(LocalizedStringKey("home.notice.loading"))
            case .failed, .stale:
                Text(LocalizedStringKey("home.notice.failed"))
            case .loaded, .empty:
                Text(LocalizedStringKey("home.notice.empty"))
            }
        }
    }
    private var trafficCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                ZStack {
                    Circle().stroke(brand.theme.border, lineWidth: 8)
                    Circle().trim(from: 0, to: ratio).stroke(brand.theme.emphasis, style: StrokeStyle(lineWidth: 8, lineCap: .round)).rotationEffect(.degrees(-90))
                    VStack(spacing: 1) {
                        Text(remaining.map { TrafficFormatter.gigabytes($0, locale: locale).value } ?? "--").font(.system(size: 24, weight: .semibold)).monospacedDigit().foregroundStyle(brand.theme.emphasis)
                        Text("GB").font(.system(size: 12, weight: .semibold)).foregroundStyle(brand.theme.emphasis)
                        Text("剩余流量").font(.system(size: 11, weight: .semibold)).foregroundStyle(brand.theme.tertiary)
                    }
                }.frame(width: 128, height: 128).frame(maxWidth: .infinity)
                Rectangle().fill(brand.theme.divider).frame(width: 1, height: 144)
                VStack(alignment: .leading, spacing: 5) {
                    Text("当前套餐").font(.system(size: 12, weight: .semibold)).foregroundStyle(brand.theme.tertiary)
                    if let plan = model.session?.planName.nilIfEmpty { Text(verbatim: plan).font(.system(size: 14, weight: .semibold)) }
                    else { Text(LocalizedStringKey(L10nKey.homeTrafficNoPlan)).font(.system(size: 14, weight: .semibold)) }
                    Spacer(minLength: 0)
                }.padding(.top, 7).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 158)
            Rectangle().fill(brand.theme.divider).frame(height: 1)
            HStack {
                metric(L10nKey.homeTrafficTotal, model.session.map { .verbatim(TrafficFormatter.gigabytes($0.transferEnableBytes, locale: locale).combined) } ?? .verbatim("--"), accent: false)
                Rectangle().fill(brand.theme.divider).frame(width: 1, height: 36)
                metric(
                    L10nKey.homeTrafficExpiration,
                    model.session.map {
                        $0.expiredAt > 0
                            ? .verbatim(Date(timeIntervalSince1970: Double($0.expiredAt)).formatted(Date.FormatStyle(date: .numeric, time: .omitted).locale(locale)))
                            : .localized(L10nKey.homeTrafficLongTerm)
                    } ?? .verbatim("--"),
                    accent: true
                )
            }.padding(.top, 11)
        }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 16).frame(height: 244).surfaceCard()
    }
    private func metric(_ titleKey: String, _ value: LocalizedMessage, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(titleKey)).font(.system(size: 11, weight: .semibold)).foregroundStyle(brand.theme.tertiary)
            LocalizedMessageText(message: value).font(.system(size: 12, weight: accent ? .regular : .semibold)).foregroundStyle(accent ? brand.theme.emphasis : brand.theme.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var connectionCard: some View {
        VStack(spacing: 6) {
            Button {
                let powerActionState = vpn.state
                let powerActionOperation = vpn.operation
                guard HomeVPNPresentation.beginPowerAction(
                    state: powerActionState,
                    operation: powerActionOperation,
                    disconnectActionPending: &disconnectActionPending
                ) else { return }
                let latchedDisconnectAction = powerActionState == .connected
                    && powerActionOperation == .idle
                Task {
                    defer {
                        HomeVPNPresentation.endPowerAction(
                            latchedDisconnectAction: latchedDisconnectAction,
                            disconnectActionPending: &disconnectActionPending
                        )
                    }
                    do {
                        switch powerActionState {
                        case .disconnected:
                            guard await usageTermsConsent.authorize(
                                presenter: modalPresenter
                            ) else { return }
                            guard vpn.state == .disconnected,
                                  vpn.operation == .idle else { return }
                            #if DEBUG
                            if UnifiedConsentUITestFixture.suppressesVPNConnect {
                                return
                            }
                            #endif
                            let mode = settings.mode
                            try await vpn.connect { try await model.minimalVPNConfiguration(mode: mode) }
                        case .connecting, .connected:
                            try await vpn.disconnect()
                        }
                    } catch {
                        guard let presentation = VPNConnectionErrorPresentation.makeIfPresentable(error)
                        else { return }
                        let choice = await modalPresenter.present(presentation.modalRequest)
                        if presentation.ownerAction(for: choice) == .openNodeList {
                            showNodes = true
                        }
                    }
                }
            } label: {
                ZStack {
                    Circle().fill(brand.theme.card).overlay(Circle().stroke(brand.theme.accent, lineWidth: 2))
                    Circle().stroke(brand.theme.tint, lineWidth: 3).frame(width: 68, height: 68)
                    Image(systemName: "power").font(.system(size: 34)).foregroundStyle(brand.theme.emphasis)
                }.frame(width: 82, height: 82).shadow(color: brand.theme.shadow, radius: 9, y: 3)
            }.buttonStyle(.plain)
                .disabled(HomeVPNPresentation.isPowerButtonDisabled(
                    state: vpn.state,
                    operation: vpn.operation,
                    disconnectActionPending: disconnectActionPending
                ))
                .accessibilityIdentifier("vpn.connect")
            Text(LocalizedStringKey(HomeVPNPresentation.statusTitleKey(
                state: vpn.state,
                operation: vpn.operation,
                disconnectActionPending: disconnectActionPending
            )))
                .font(.system(size: 18, weight: .semibold))
            HStack(spacing: 24) {
                Text(verbatim: "↓ \(LiveTrafficFormatter.bytesPerSecond(vpn.downloadBytesPerSecond))")
                Text(verbatim: "↑ \(LiveTrafficFormatter.bytesPerSecond(vpn.uploadBytesPerSecond))")
            }
            .font(.system(size: 10)).foregroundStyle(brand.theme.secondary)
            .monospacedDigit()
        }.frame(maxWidth: .infinity).frame(height: HomeAppearance.connectionCardHeight).surfaceCard()
    }
    private func actionRow(
        _ icon: String, title: LocalizedMessage, trailing: LocalizedMessage,
        trailingColor: Color? = nil, nodeFlag: ProxyNode? = nil
    ) -> some View {
        HStack(spacing: 12) {
            if let nodeFlag {
                NodeCountryFlag(countryCode: nodeFlag.countryCode, nodeName: nodeFlag.displayName)
            } else {
                Image(systemName: icon).font(.system(size: 21))
                    .foregroundStyle(brand.theme.emphasis).frame(width: 22)
            }
            LocalizedMessageText(message: title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 4)
            LocalizedMessageText(message: trailing).font(.system(size: 11))
                .foregroundStyle(trailingColor ?? brand.theme.tertiary)
            Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(brand.theme.tertiary)
        }.padding(.horizontal, 18).frame(height: 54).surfaceCard()
    }
}

extension MinimalVPNController.State {
    var titleKey: String {
        switch self {
        case .disconnected: "vpn.state.disconnected"
        case .connecting: "vpn.state.connecting"
        case .connected: "vpn.state.connected"
        }
    }
}
