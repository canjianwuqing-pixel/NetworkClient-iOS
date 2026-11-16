import SwiftUI

enum AppModelMessagePresentation {
    static func request(for message: LocalizedMessage) -> GlobalModalRequest {
        GlobalModalRequest.information(
            title: .localized("提示"),
            message: message,
            primaryTitle: .localized("确定")
        )
    }

    static func shouldConsume(for choice: GlobalModalChoice) -> Bool {
        choice == .primary || choice == .dismissed
    }
}

@MainActor
final class AppModelMessageBridge: ObservableObject {
    private var presentationTask: Task<Void, Never>?

    func synchronize(
        currentMessage: @escaping @MainActor () -> LocalizedMessage?,
        presenter: GlobalModalPresenter,
        consume: @escaping @MainActor (LocalizedMessage) -> Void
    ) {
        guard presentationTask == nil, currentMessage() != nil else { return }

        presentationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { presentationTask = nil }

            while let displayedMessage = currentMessage() {
                let choice = await presenter.present(
                    AppModelMessagePresentation.request(for: displayedMessage)
                )
                guard choice != .alreadyPresenting else { return }

                if AppModelMessagePresentation.shouldConsume(for: choice),
                   currentMessage() == displayedMessage {
                    consume(displayedMessage)
                }

                guard currentMessage() != displayedMessage else { return }
            }
        }
    }
}

@main
struct NetworkClientApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: AppModel
    @StateObject private var settings = AppSettings()
    @StateObject private var vpn: MinimalVPNController
    @StateObject private var modalPresenter = GlobalModalPresenter()
    @StateObject private var usageTermsConsent = UsageTermsConsentCoordinator()
    @StateObject private var messageBridge = AppModelMessageBridge()
    @StateObject private var paymentStatusCoordinator = PaymentStatusCoordinator()
    @State private var pendingPaymentRecoveryRequested = false

    init() {
        if let group = try? MihomoTunnelStore.appGroup(),
           let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
            _ = try? VPNObsoleteDataRemoval.remove(in: container)
        }
        let model = AppModel()
        let controller = MinimalVPNController(
            prepareRecoveryForFormalVPN: {
                try await model.prepareAppRecoveryForFormalVPN()
            },
            setRecoveryAllowedForFormalVPN: { allowed in
                await model.setAppRecoveryAllowedForFormalVPN(allowed)
            }
        )
        model.attachVPNController(controller)
        _model = StateObject(wrappedValue: model)
        _vpn = StateObject(wrappedValue: controller)
    }

    var body: some Scene {
        WindowGroup {
            GlobalModalHost {
                RootView()
            }
                .environmentObject(model)
                .environmentObject(model.brand)
                .environmentObject(settings)
                .environmentObject(vpn)
                .environmentObject(modalPresenter)
                .environmentObject(usageTermsConsent)
                .environmentObject(paymentStatusCoordinator)
                .environment(\.locale, Locale(identifier: settings.language))
                .preferredColorScheme(settings.colorScheme)
                .tint(model.brand.theme.accent)
                .task {
                    await model.start()
                    requestPendingPaymentRecovery()
                }
                .task { try? await vpn.refreshSystemStatus() }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        paymentStatusCoordinator.scenePhaseChanged(.active)
                        pendingPaymentRecoveryRequested = model.session != nil
                        Task {
                            await model.setAPIHealthForeground(true)
                            await model.refreshAuthenticatedDataIfNeeded()
                            await recoverPendingPaymentIfRequested()
                        }
                    case .background:
                        paymentStatusCoordinator.scenePhaseChanged(.background)
                        Task { await model.setAPIHealthForeground(false) }
                    default: break
                    }
                }
                .onReceive(model.$session) { session in
                    paymentStatusCoordinator.accountContextChanged(
                        session: session,
                        generation: model.commerceRecoveryGeneration
                    )
                    pendingPaymentRecoveryRequested = session != nil
                    requestPendingPaymentRecovery()
                }
                .onChange(of: model.busy) { _, isBusy in
                    guard !isBusy else { return }
                    requestPendingPaymentRecovery()
                }
                .onChange(of: model.message, initial: true) { _, _ in
                    synchronizeGlobalMessage()
                }
                .onChange(of: modalPresenter.activeRequest?.id) { _, requestID in
                    guard requestID == nil else { return }
                    synchronizeGlobalMessage()
                    requestPendingPaymentRecovery()
                }
        }
    }

    private func synchronizeGlobalMessage() {
        messageBridge.synchronize(
            currentMessage: { model.message },
            presenter: modalPresenter,
            consume: { displayedMessage in
                guard model.message == displayedMessage else { return }
                model.message = nil
            }
        )
    }

    private func requestPendingPaymentRecovery() {
        guard pendingPaymentRecoveryRequested,
              scenePhase == .active,
              model.session != nil,
              !model.busy,
              model.message == nil,
              modalPresenter.activeRequest == nil else { return }
        Task { await recoverPendingPaymentIfRequested() }
    }

    private func recoverPendingPaymentIfRequested() async {
        guard pendingPaymentRecoveryRequested,
              scenePhase == .active,
              model.session != nil,
              !model.busy,
              model.message == nil,
              modalPresenter.activeRequest == nil else { return }
        pendingPaymentRecoveryRequested = false
        await paymentStatusCoordinator.recoverPendingPaymentIfNeeded(
            model: model,
            presenter: modalPresenter,
            locale: Locale(identifier: settings.language)
        )
    }
}
