import SwiftUI
import UIKit

enum GlobalModalResultStyle: Equatable, Sendable {
    case success
    case error
}

enum GlobalModalKind: Equatable, Sendable {
    case information
    case confirmation
    case destructive
    case result(GlobalModalResultStyle)
    case announcement
    case selection
    case purchaseOrder
    case paymentMethod
    case paymentStatus
}

enum GlobalModalButtonRole: Equatable, Sendable {
    case normal
    case cancel
    case destructive
    case tonal

    var swiftUIRole: ButtonRole? {
        switch self {
        case .normal: nil
        case .cancel: .cancel
        case .destructive: .destructive
        case .tonal: nil
        }
    }
}

struct GlobalModalButton: Equatable, Sendable {
    let title: LocalizedMessage
    let role: GlobalModalButtonRole
    let identifier: String

    init(
        title: LocalizedMessage,
        role: GlobalModalButtonRole = .normal,
        identifier: String
    ) {
        self.title = title
        self.role = role
        self.identifier = identifier
    }
}

struct GlobalModalSelectionOption: Identifiable, Equatable, Sendable {
    let id: String
    let title: LocalizedMessage
    let message: LocalizedMessage?
    let systemImage: String?

    init(
        id: String,
        title: LocalizedMessage,
        message: LocalizedMessage? = nil,
        systemImage: String? = nil
    ) {
        self.id = id
        self.title = title
        self.message = message
        self.systemImage = systemImage
    }
}

enum GlobalModalSelectionBehavior: Equatable, Sendable {
    case confirm
    case immediate
}

struct GlobalModalSelectionState: Equatable, Sendable {
    private let optionIDs: Set<String>
    private(set) var pendingID: String?

    init(
        options: [GlobalModalSelectionOption],
        initialSelectionID: String?
    ) {
        optionIDs = Set(options.map(\.id))
        pendingID = initialSelectionID.flatMap {
            optionIDs.contains($0) ? $0 : nil
        }
    }

    mutating func select(_ id: String) {
        guard optionIDs.contains(id) else { return }
        pendingID = id
    }
}

struct GlobalModalPurchaseOrderContent: Equatable, Sendable {
    let planName: String
    let period: LocalizedMessage
    let price: String
}

struct GlobalModalPaymentSummaryRow: Identifiable, Equatable, Sendable {
    let id: String
    let label: LocalizedMessage
    let value: String
}

struct GlobalModalPaymentMethodOption: Identifiable, Equatable, Sendable {
    let id: Int
    let name: String
    let iconURL: URL?
    let feeDescription: LocalizedMessage?
    let handlingAmount: String?
    let amountDue: String
    let isEnabled: Bool
    let disabledReason: LocalizedMessage?
}

struct GlobalModalPaymentMethodContent: Equatable, Sendable {
    let tradeNo: String
    let summaryRows: [GlobalModalPaymentSummaryRow]
    let methods: [GlobalModalPaymentMethodOption]
    let baseAmountDue: String
}

enum GlobalModalPaymentStatus: Equatable, Sendable {
    case pending
    case activating
    case completed
    case cancelled
    case offset
    case unknown

    var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .offset: true
        case .pending, .activating, .unknown: false
        }
    }
}

struct GlobalModalPaymentStatusContent: Equatable, Sendable {
    let tradeNo: String
    let summaryRows: [GlobalModalPaymentSummaryRow]
    let amountDue: String
    let status: GlobalModalPaymentStatus
    let feedback: LocalizedMessage?
}

struct GlobalModalPaymentMethodState: Equatable, Sendable {
    private let methods: [GlobalModalPaymentMethodOption]
    private(set) var pendingMethodID: Int?

    init(
        methods: [GlobalModalPaymentMethodOption],
        initialMethodID: Int? = nil
    ) {
        self.methods = methods
        if let initialMethodID,
           methods.contains(where: { $0.id == initialMethodID && $0.isEnabled }) {
            pendingMethodID = initialMethodID
        } else {
            pendingMethodID = methods.first(where: \.isEnabled)?.id
        }
    }

    var selectedMethod: GlobalModalPaymentMethodOption? {
        guard let pendingMethodID else { return nil }
        return methods.first(where: { $0.id == pendingMethodID })
    }

    mutating func select(_ id: Int) {
        guard methods.contains(where: { $0.id == id && $0.isEnabled }) else { return }
        pendingMethodID = id
    }
}

enum GlobalModalInteraction: Equatable, Sendable {
    case validatePurchaseCoupon(String)
    case checkPaymentStatus
    case cancelPendingOrder
}

enum GlobalModalInteractionResult: Equatable, Sendable {
    case couponAvailable(name: String)
    case couponUnavailable(LocalizedMessage)
    case completed
    case cancelled
}

enum GlobalModalCouponValidationState: Equatable, Sendable {
    case idle
    case validating(code: String)
    case available(code: String, name: String)
    case unavailable(code: String, message: LocalizedMessage)
}

struct GlobalModalCouponInputState: Equatable, Sendable {
    private(set) var text = ""
    private(set) var validation = GlobalModalCouponValidationState.idle

    var normalizedCode: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canSubmit: Bool {
        if normalizedCode.isEmpty { return true }
        guard case let .available(code, _) = validation else { return false }
        return code == normalizedCode
    }

    var submittedCode: String? {
        guard canSubmit, !normalizedCode.isEmpty else { return nil }
        return normalizedCode
    }

    mutating func updateText(_ value: String) {
        text = value
        switch validation {
        case let .validating(code), let .available(code, _), let .unavailable(code, _):
            if code != normalizedCode { validation = .idle }
        case .idle:
            break
        }
    }

    mutating func beginValidation() -> String? {
        let code = normalizedCode
        guard !code.isEmpty else { return nil }
        validation = .validating(code: code)
        return code
    }

    mutating func finishValidation(
        code: String,
        result: GlobalModalInteractionResult
    ) {
        guard code == normalizedCode else { return }
        switch result {
        case let .couponAvailable(name):
            validation = .available(code: code, name: name)
        case let .couponUnavailable(message):
            validation = .unavailable(code: code, message: message)
        case .completed, .cancelled:
            validation = .idle
        }
    }
}

struct GlobalModalRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: GlobalModalKind
    let title: LocalizedMessage?
    let detail: LocalizedMessage?
    let message: LocalizedMessage?
    let primary: GlobalModalButton
    let secondary: GlobalModalButton?
    let copyText: String?
    let selectionOptions: [GlobalModalSelectionOption]
    let initialSelectionID: String?
    let selectionBehavior: GlobalModalSelectionBehavior
    let allowsBackdropDismiss: Bool
    let purchaseOrderContent: GlobalModalPurchaseOrderContent?
    let paymentMethodContent: GlobalModalPaymentMethodContent?
    let paymentStatusContent: GlobalModalPaymentStatusContent?

    init(
        id: UUID = UUID(),
        kind: GlobalModalKind,
        title: LocalizedMessage? = nil,
        detail: LocalizedMessage? = nil,
        message: LocalizedMessage? = nil,
        primary: GlobalModalButton,
        secondary: GlobalModalButton? = nil,
        copyText: String? = nil,
        selectionOptions: [GlobalModalSelectionOption] = [],
        initialSelectionID: String? = nil,
        selectionBehavior: GlobalModalSelectionBehavior = .confirm,
        allowsBackdropDismiss: Bool = false,
        purchaseOrderContent: GlobalModalPurchaseOrderContent? = nil,
        paymentMethodContent: GlobalModalPaymentMethodContent? = nil,
        paymentStatusContent: GlobalModalPaymentStatusContent? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.message = message
        self.primary = primary
        self.secondary = secondary
        self.copyText = copyText
        self.selectionOptions = selectionOptions
        self.initialSelectionID = initialSelectionID
        self.selectionBehavior = selectionBehavior
        self.allowsBackdropDismiss = allowsBackdropDismiss
        self.purchaseOrderContent = purchaseOrderContent
        self.paymentMethodContent = paymentMethodContent
        self.paymentStatusContent = paymentStatusContent
    }

    static func information(
        id: UUID = UUID(),
        title: LocalizedMessage? = nil,
        message: LocalizedMessage? = nil,
        primaryTitle: LocalizedMessage = .localized("确定")
    ) -> GlobalModalRequest {
        GlobalModalRequest(
            id: id,
            kind: .information,
            title: title,
            message: message,
            primary: GlobalModalButton(
                title: primaryTitle,
                identifier: "global.modal.primary"
            )
        )
    }

    static func confirmation(
        id: UUID = UUID(),
        title: LocalizedMessage? = nil,
        message: LocalizedMessage? = nil,
        primaryTitle: LocalizedMessage,
        secondaryTitle: LocalizedMessage = .localized("取消")
    ) -> GlobalModalRequest {
        GlobalModalRequest(
            id: id,
            kind: .confirmation,
            title: title,
            message: message,
            primary: GlobalModalButton(
                title: primaryTitle,
                identifier: "global.modal.primary"
            ),
            secondary: GlobalModalButton(
                title: secondaryTitle,
                role: .cancel,
                identifier: "global.modal.secondary"
            )
        )
    }

    static func usageTermsConsent(
        id: UUID = UUID()
    ) -> GlobalModalRequest {
        GlobalModalRequest(
            id: id,
            kind: .confirmation,
            title: .localized("consent.modal.title"),
            message: .localized("consent.modal.message"),
            primary: GlobalModalButton(
                title: .localized("consent.action.agree"),
                identifier: "unified.consent.agree"
            ),
            secondary: GlobalModalButton(
                title: .localized("consent.action.decline"),
                role: .cancel,
                identifier: "unified.consent.decline"
            )
        )
    }

    static func destructive(
        id: UUID = UUID(),
        title: LocalizedMessage? = nil,
        message: LocalizedMessage? = nil,
        primaryTitle: LocalizedMessage,
        secondaryTitle: LocalizedMessage = .localized("取消")
    ) -> GlobalModalRequest {
        GlobalModalRequest(
            id: id,
            kind: .destructive,
            title: title,
            message: message,
            primary: GlobalModalButton(
                title: primaryTitle,
                role: .destructive,
                identifier: "global.modal.primary"
            ),
            secondary: GlobalModalButton(
                title: secondaryTitle,
                role: .cancel,
                identifier: "global.modal.secondary"
            )
        )
    }

    static func orderCancellation(
        id: UUID = UUID()
    ) -> GlobalModalRequest {
        .destructive(
            id: id,
            title: .localized("profile.orders.cancel.title"),
            message: .localized("profile.orders.cancel.message"),
            primaryTitle: .localized("profile.orders.cancel.confirm"),
            secondaryTitle: .localized("purchase.payment.cancel")
        )
    }

    static func result(
        id: UUID = UUID(),
        style: GlobalModalResultStyle,
        title: LocalizedMessage? = nil,
        message: LocalizedMessage? = nil,
        primaryTitle: LocalizedMessage = .localized("确定")
    ) -> GlobalModalRequest {
        GlobalModalRequest(
            id: id,
            kind: .result(style),
            title: title,
            message: message,
            primary: GlobalModalButton(
                title: primaryTitle,
                identifier: "global.modal.primary"
            )
        )
    }

    static func announcement(
        id: UUID = UUID(),
        title: LocalizedMessage,
        detail: LocalizedMessage? = nil,
        message: LocalizedMessage,
        copyText: String,
        primaryTitle: LocalizedMessage = .localized("home.notice.dismiss"),
        secondaryTitle: LocalizedMessage = .localized("home.notice.copy_content")
    ) -> GlobalModalRequest {
        GlobalModalRequest(
            id: id,
            kind: .announcement,
            title: title,
            detail: detail,
            message: message,
            primary: GlobalModalButton(
                title: primaryTitle,
                identifier: "global.modal.primary"
            ),
            secondary: GlobalModalButton(
                title: secondaryTitle,
                role: .tonal,
                identifier: "global.modal.announcement.copy"
            ),
            copyText: copyText
        )
    }

    static func selection(
        id: UUID = UUID(),
        title: LocalizedMessage,
        options: [GlobalModalSelectionOption],
        initialSelectionID: String,
        primaryTitle: LocalizedMessage,
        secondaryTitle: LocalizedMessage
    ) -> GlobalModalRequest {
        GlobalModalRequest(
            id: id,
            kind: .selection,
            title: title,
            primary: GlobalModalButton(
                title: primaryTitle,
                identifier: "global.modal.primary"
            ),
            secondary: GlobalModalButton(
                title: secondaryTitle,
                role: .cancel,
                identifier: "global.modal.secondary"
            ),
            selectionOptions: options,
            initialSelectionID: initialSelectionID
        )
    }

    static func immediateSelection(
        id: UUID = UUID(),
        title: LocalizedMessage,
        options: [GlobalModalSelectionOption],
        initialSelectionID: String,
        allowsBackdropDismiss: Bool = false
    ) -> GlobalModalRequest {
        GlobalModalRequest(
            id: id,
            kind: .selection,
            title: title,
            primary: GlobalModalButton(
                title: .localized("确定"),
                identifier: "global.modal.primary"
            ),
            selectionOptions: options,
            initialSelectionID: initialSelectionID,
            selectionBehavior: .immediate,
            allowsBackdropDismiss: allowsBackdropDismiss
        )
    }

    static func purchaseOrder(
        id: UUID = UUID(),
        planName: String,
        period: LocalizedMessage,
        price: String
    ) -> GlobalModalRequest {
        GlobalModalRequest(
            id: id,
            kind: .purchaseOrder,
            title: .localized("purchase.payment.confirm_title"),
            primary: GlobalModalButton(
                title: .localized("purchase.payment.create_order"),
                identifier: "global.modal.primary"
            ),
            secondary: GlobalModalButton(
                title: .localized("purchase.payment.cancel"),
                role: .cancel,
                identifier: "global.modal.secondary"
            ),
            purchaseOrderContent: GlobalModalPurchaseOrderContent(
                planName: planName,
                period: period,
                price: price
            )
        )
    }

    static func paymentMethod(
        id: UUID = UUID(),
        tradeNo: String,
        summaryRows: [GlobalModalPaymentSummaryRow],
        methods: [GlobalModalPaymentMethodOption],
        baseAmountDue: String
    ) -> GlobalModalRequest {
        GlobalModalRequest(
            id: id,
            kind: .paymentMethod,
            title: .localized("purchase.payment.checkout_title"),
            primary: GlobalModalButton(
                title: .localized("purchase.payment.proceed"),
                identifier: "global.modal.primary"
            ),
            secondary: GlobalModalButton(
                title: .localized("purchase.payment.cancel"),
                role: .cancel,
                identifier: "global.modal.secondary"
            ),
            paymentMethodContent: GlobalModalPaymentMethodContent(
                tradeNo: tradeNo,
                summaryRows: summaryRows,
                methods: methods,
                baseAmountDue: baseAmountDue
            )
        )
    }

    static func paymentStatus(
        id: UUID,
        tradeNo: String,
        summaryRows: [GlobalModalPaymentSummaryRow],
        amountDue: String,
        status: GlobalModalPaymentStatus,
        feedback: LocalizedMessage? = nil
    ) -> GlobalModalRequest {
        GlobalModalRequest(
            id: id,
            kind: .paymentStatus,
            title: .localized("purchase.payment.status_title"),
            primary: GlobalModalButton(
                title: .localized(status.isTerminal
                    ? "purchase.payment.close" : "purchase.payment.paid"),
                identifier: "global.modal.primary"
            ),
            secondary: status == .pending ? GlobalModalButton(
                title: .localized("purchase.payment.cancel_order"),
                role: .tonal,
                identifier: "global.modal.secondary"
            ) : nil,
            paymentStatusContent: GlobalModalPaymentStatusContent(
                tradeNo: tradeNo,
                summaryRows: summaryRows,
                amountDue: amountDue,
                status: status,
                feedback: feedback
            )
        )
    }
}

enum GlobalModalChoice: Equatable, Sendable {
    case primary
    case secondary
    case selection(String)
    case purchaseOrder(couponCode: String?)
    case paymentMethod(Int)
    case dismissed
    case alreadyPresenting
}

@MainActor
final class GlobalModalPresenter: ObservableObject {
    @Published private(set) var activeRequest: GlobalModalRequest?

    private var activeToken: UUID?
    private var continuation: CheckedContinuation<GlobalModalChoice, Never>?
    private var interactionHandler: (@MainActor (GlobalModalInteraction) async -> GlobalModalInteractionResult)?

    func present(
        _ request: GlobalModalRequest,
        onInteraction: (@MainActor (GlobalModalInteraction) async -> GlobalModalInteractionResult)? = nil
    ) async -> GlobalModalChoice {
        guard activeRequest == nil else { return .alreadyPresenting }
        let token = UUID()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .dismissed)
                    return
                }
                activeToken = token
                activeRequest = request
                self.continuation = continuation
                interactionHandler = onInteraction
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPresentation(token: token)
            }
        }
    }

    @discardableResult
    func resolve(
        _ choice: GlobalModalChoice,
        requestID: GlobalModalRequest.ID? = nil
    ) -> Bool {
        guard choice != .alreadyPresenting,
              let activeRequest,
              requestID == nil || requestID == activeRequest.id,
              let continuation else { return false }

        self.continuation = nil
        interactionHandler = nil
        activeToken = nil
        self.activeRequest = nil
        continuation.resume(returning: choice)
        return true
    }

    func perform(
        _ interaction: GlobalModalInteraction,
        requestID: GlobalModalRequest.ID
    ) async -> GlobalModalInteractionResult {
        guard activeRequest?.id == requestID,
              let interactionHandler else { return .cancelled }
        let token = activeToken
        let result = await interactionHandler(interaction)
        guard token == activeToken, activeRequest?.id == requestID else {
            return .cancelled
        }
        return result
    }

    func isPresenting(requestID: GlobalModalRequest.ID) -> Bool {
        activeRequest?.id == requestID
    }

    @discardableResult
    func update(
        _ request: GlobalModalRequest,
        requestID: GlobalModalRequest.ID
    ) -> Bool {
        guard activeRequest?.id == requestID,
              request.id == requestID,
              continuation != nil else { return false }
        activeRequest = request
        return true
    }

    private func cancelPresentation(token: UUID) {
        guard activeToken == token else { return }
        resolve(.dismissed)
    }

    deinit {
        continuation?.resume(returning: .dismissed)
    }
}

enum UsageTermsConsentPolicy {
    static let requiredVersion = 1
    static let acceptedVersionKey = "ios.usage_terms_privacy.accepted_version"
    static let legacyVPNDisclosureAcceptedVersionKey =
        "ios.vpn.data_disclosure.accepted_version"
}

@MainActor
final class UsageTermsConsentCoordinator: ObservableObject {
    @Published private(set) var acceptedVersion: Int

    private let defaults: UserDefaults
    private let requiredVersion: Int
    private var presentationInFlight = false

    init(
        defaults: UserDefaults = .standard,
        requiredVersion: Int = UsageTermsConsentPolicy.requiredVersion,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        self.defaults = defaults
        self.requiredVersion = requiredVersion
        #if DEBUG
        if arguments.contains("--ui-unified-consent-reset") {
            defaults.removeObject(forKey: UsageTermsConsentPolicy.acceptedVersionKey)
        }
        #endif
        acceptedVersion = defaults.integer(
            forKey: UsageTermsConsentPolicy.acceptedVersionKey
        )
    }

    var hasAcceptedCurrentVersion: Bool {
        acceptedVersion >= requiredVersion
    }

    var requiresAcceptance: Bool {
        acceptedVersion < requiredVersion
    }

    func setAccepted(_ accepted: Bool) {
        if accepted {
            acceptCurrentVersion()
        } else {
            defaults.removeObject(forKey: UsageTermsConsentPolicy.acceptedVersionKey)
            acceptedVersion = 0
        }
    }

    func authorize(presenter: GlobalModalPresenter) async -> Bool {
        guard requiresAcceptance else { return true }
        guard !presentationInFlight else { return false }
        presentationInFlight = true
        defer { presentationInFlight = false }

        let choice = await presenter.present(.usageTermsConsent())
        guard !Task.isCancelled, choice == .primary else { return false }

        acceptCurrentVersion()
        return true
    }

    private func acceptCurrentVersion() {
        defaults.set(requiredVersion, forKey: UsageTermsConsentPolicy.acceptedVersionKey)
        acceptedVersion = requiredVersion
    }
}

#if DEBUG
enum UnifiedConsentUITestFixture {
    static var suppressesVPNConnect: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-unified-consent-only")
    }

    static var allowsOfflinePurchase: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-unified-consent-purchase")
    }

    static var allowsOfflineAuth: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-unified-consent-auth")
    }

    static var suppressesAuthSubmission: Bool {
        allowsOfflineAuth
    }
}
#endif

enum GlobalModalHostLayoutMetrics {
    static let horizontalPadding: CGFloat = 24
    static let verticalPadding: CGFloat = 20

    static func availableContentHeight(in viewportHeight: CGFloat) -> CGFloat {
        max(0, viewportHeight - verticalPadding * 2)
    }

    static func contentOverflows(
        _ contentHeight: CGFloat,
        in viewportHeight: CGFloat
    ) -> Bool {
        contentHeight > availableContentHeight(in: viewportHeight)
    }
}

enum GlobalModalPaymentCloseButtonMetrics {
    static let symbolSize: CGFloat = 14
    static let visualFrameSize: CGFloat = 32
    static let minimumHitTargetSize: CGFloat = 44
    static let titleSpacing: CGFloat = 12
    static let headerHeight: CGFloat = visualFrameSize
}

enum GlobalModalBackdropDismissal {
    static func shouldDismiss(
        allowsBackdropDismiss: Bool,
        modalFrame: CGRect,
        tapLocation: CGPoint
    ) -> Bool {
        allowsBackdropDismiss
            && modalFrame != .zero
            && !modalFrame.contains(tapLocation)
    }
}

private enum GlobalModalHostCoordinateSpace {
    static let name = "global.modal.host"
}

struct GlobalModalHost<Content: View>: View {
    @EnvironmentObject private var presenter: GlobalModalPresenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var modalCardFrame: CGRect = .zero
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            content
                .allowsHitTesting(presenter.activeRequest == nil)
                .accessibilityHidden(presenter.activeRequest != nil)

            if let request = presenter.activeRequest {
                Color.black.opacity(0.42)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .accessibilityHidden(true)
                    .transition(.opacity)
                    .zIndex(1)

                GeometryReader { geometry in
                    let availableContentHeight = GlobalModalHostLayoutMetrics
                        .availableContentHeight(in: geometry.size.height)
                    ScrollView {
                        VStack {
                            GlobalModalView(
                                request: request,
                                availableHeight: availableContentHeight
                            )
                                .frame(maxWidth: 390)
                                .onGeometryChange(for: CGRect.self) { proxy in
                                    proxy.frame(in: .named(
                                        GlobalModalHostCoordinateSpace.name
                                    ))
                                } action: { frame in
                                    modalCardFrame = frame
                                }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: availableContentHeight)
                        .padding(.horizontal, GlobalModalHostLayoutMetrics.horizontalPadding)
                        .padding(.vertical, GlobalModalHostLayoutMetrics.verticalPadding)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .coordinateSpace(name: GlobalModalHostCoordinateSpace.name)
                    .simultaneousGesture(
                        SpatialTapGesture().onEnded { value in
                            guard GlobalModalBackdropDismissal.shouldDismiss(
                                allowsBackdropDismiss: request.allowsBackdropDismiss,
                                modalFrame: modalCardFrame,
                                tapLocation: value.location
                            ) else { return }
                            presenter.resolve(.dismissed, requestID: request.id)
                        }
                    )
                }
                .transition(modalTransition)
                .zIndex(2)
            }
        }
        .animation(
            .easeOut(duration: reduceMotion ? 0.12 : 0.18),
            value: presenter.activeRequest?.id
        )
        .onChange(of: presenter.activeRequest?.id) { _, _ in
            modalCardFrame = .zero
        }
    }

    private var modalTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.97))
    }
}

private struct GlobalModalView: View {
    @EnvironmentObject private var presenter: GlobalModalPresenter
    @EnvironmentObject private var brand: BrandProvider
    @AccessibilityFocusState private var accessibilityFocused: Bool
    @State private var announcementMessageHeight: CGFloat = 0
    @State private var announcementCopySucceeded = false
    @State private var announcementCopyGeneration = 0
    @State private var selectionState: GlobalModalSelectionState
    @State private var couponInputState = GlobalModalCouponInputState()
    @State private var paymentMethodState: GlobalModalPaymentMethodState
    @State private var paymentBodyHeight: CGFloat = 0
    @State private var paymentStatusActionInFlight = false
    @State private var showsPaymentCancellationConfirmation = false
    let request: GlobalModalRequest
    let availableHeight: CGFloat

    init(request: GlobalModalRequest, availableHeight: CGFloat) {
        self.request = request
        self.availableHeight = availableHeight
        _selectionState = State(initialValue: GlobalModalSelectionState(
            options: request.selectionOptions,
            initialSelectionID: request.initialSelectionID
        ))
        _paymentMethodState = State(initialValue: GlobalModalPaymentMethodState(
            methods: request.paymentMethodContent?.methods ?? []
        ))
    }

    var body: some View {
        Group {
            if request.kind == .selection {
                selectionContent
            } else if request.kind == .purchaseOrder {
                purchaseOrderContent
            } else if request.kind == .paymentMethod {
                paymentMethodContent
            } else if request.kind == .paymentStatus {
                if showsPaymentCancellationConfirmation {
                    paymentCancellationConfirmationContent
                } else {
                    paymentStatusContent
                }
            } else if request.kind == .announcement {
                announcementContent
            } else {
                standardContent
            }
        }
        .padding(24)
        .background(brand.theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(brand.theme.border, lineWidth: 1)
        }
        .shadow(color: brand.theme.shadow, radius: 18, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("global.modal")
        .accessibilityFocused($accessibilityFocused)
        .onAppear { accessibilityFocused = true }
        .onChange(of: request.paymentStatusContent?.status) { _, status in
            if status != .pending {
                showsPaymentCancellationConfirmation = false
            }
        }
    }

    private var standardContent: some View {
        VStack(spacing: 0) {
            if let resultStyle {
                Image(systemName: resultStyle == .success
                    ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                    .foregroundStyle(resultStyle == .success
                        ? brand.theme.color("success") : brand.theme.error)
                    .accessibilityHidden(true)
                    .padding(.bottom, 16)
            }

            if let title = request.title {
                GlobalModalText(message: title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(brand.theme.text)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("global.modal.title")
            }

            if let message = request.message {
                GlobalModalText(message: message)
                    .font(.body.weight(.regular))
                    .foregroundStyle(brand.theme.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, request.title == nil ? 0 : 12)
                    .accessibilityIdentifier("global.modal.message")
            }

            actionArea
                .padding(.top, request.title == nil && request.message == nil ? 0 : 24)
        }
    }

    private var announcementContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = request.title {
                GlobalModalText(message: title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(brand.theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("global.modal.title")
            }

            if let detail = request.detail {
                GlobalModalText(message: detail)
                    .font(.caption.weight(.regular))
                    .foregroundStyle(brand.theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, request.title == nil ? 0 : 6)
                    .accessibilityIdentifier("global.modal.announcement.date")
            }

            if let message = request.message {
                ScrollView {
                    announcementMessage(message)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { height in
                            announcementMessageHeight = height
                        }
                    }
                .scrollDisabled(announcementMessageHeight <= announcementBodyMaximumHeight)
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: announcementBodyHeight)
                .padding(.top, request.title == nil && request.detail == nil ? 0 : 16)
                .accessibilityIdentifier("global.modal.announcement.content")
            }

            announcementActionArea
                .padding(.top, request.title == nil && request.message == nil ? 0 : 24)
        }
    }

    private var selectionContent: some View {
        VStack(spacing: 0) {
            if let title = request.title {
                GlobalModalText(message: title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(brand.theme.text)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("global.modal.title")
            }

            VStack(spacing: 10) {
                ForEach(request.selectionOptions) { option in
                    selectionOption(option)
                }
            }
            .padding(.top, request.title == nil ? 0 : 18)

            if request.selectionBehavior == .confirm {
                selectionActionArea
                    .padding(.top, 24)
            }
        }
    }

    private var purchaseOrderContent: some View {
        VStack(spacing: 0) {
            if let title = request.title {
                GlobalModalText(message: title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(brand.theme.text)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("global.modal.title")
            }

            if let content = request.purchaseOrderContent {
                VStack(spacing: 10) {
                    purchaseOrderRow(
                        label: .localized("purchase.payment.plan"),
                        value: .verbatim(content.planName)
                    )
                    purchaseOrderRow(
                        label: .localized("purchase.payment.period"),
                        value: content.period
                    )
                    purchaseOrderRow(
                        label: .localized("purchase.payment.plan_price"),
                        value: .verbatim(content.price),
                        emphasized: true
                    )
                }
                .padding(14)
                .background(brand.theme.field)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(brand.theme.border, lineWidth: 1)
                }
                .padding(.top, request.title == nil ? 0 : 18)
            }

            purchaseCouponContent
                .padding(.top, 14)

            purchaseOrderActionArea
                .padding(.top, 24)
        }
    }

    private var paymentMethodContent: some View {
        VStack(spacing: 0) {
            paymentHeader

            if let content = request.paymentMethodContent {
                ScrollView {
                    paymentMethodBody(content)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { height in
                            paymentBodyHeight = height
                        }
                }
                .scrollDisabled(paymentBodyHeight <= paymentBodyMaximumHeight)
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: paymentBodyVisibleHeight)
                .padding(.top, request.title == nil ? 0 : 18)
                .accessibilityIdentifier("global.modal.payment.content")
            }

            paymentMethodActionArea
                .padding(.top, 24)
        }
    }

    private var paymentStatusContent: some View {
        VStack(spacing: 0) {
            paymentHeader

            if let content = request.paymentStatusContent {
                VStack(spacing: 9) {
                    paymentSummaryRow(
                        label: .localized("purchase.payment.trade_no"),
                        value: content.tradeNo
                    )
                    ForEach(content.summaryRows) { row in
                        paymentSummaryRow(label: row.label, value: row.value)
                    }
                    paymentSummaryRow(
                        label: .localized("purchase.payment.amount_due"),
                        value: content.amountDue,
                        emphasized: true
                    )
                }
                .padding(14)
                .background(brand.theme.field)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(brand.theme.border, lineWidth: 1)
                }
                .padding(.top, 18)

                paymentStatusLine(content.status)
                    .padding(.top, 16)

                if let feedback = content.feedback {
                    GlobalModalText(message: feedback)
                        .font(.footnote.weight(.regular))
                        .foregroundStyle(brand.theme.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                        .accessibilityIdentifier("global.modal.payment.status.feedback")
                }

                paymentStatusActionArea(content.status)
                    .padding(.top, 20)
            }
        }
    }

    private var paymentHeader: some View {
        ZStack(alignment: .trailing) {
            if let title = request.title {
                GlobalModalText(message: title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(brand.theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(
                        .trailing,
                        GlobalModalPaymentCloseButtonMetrics.visualFrameSize
                            + GlobalModalPaymentCloseButtonMetrics.titleSpacing
                    )
                    .accessibilityIdentifier("global.modal.title")
            }
            paymentCloseButton
        }
        .frame(height: GlobalModalPaymentCloseButtonMetrics.headerHeight)
    }

    private var paymentCloseButton: some View {
        Button {
            presenter.resolve(.dismissed, requestID: request.id)
        } label: {
            Image(systemName: "xmark")
                .font(.system(
                    size: GlobalModalPaymentCloseButtonMetrics.symbolSize,
                    weight: .medium
                ))
                .foregroundStyle(brand.theme.secondary)
                .frame(
                    width: GlobalModalPaymentCloseButtonMetrics.visualFrameSize,
                    height: GlobalModalPaymentCloseButtonMetrics.visualFrameSize
                )
                .frame(
                    width: GlobalModalPaymentCloseButtonMetrics.minimumHitTargetSize,
                    height: GlobalModalPaymentCloseButtonMetrics.minimumHitTargetSize,
                    alignment: .trailing
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel(Text("purchase.payment.close"))
        .accessibilityIdentifier("global.modal.payment.close")
    }

    private var paymentCancellationConfirmationContent: some View {
        let confirmation = GlobalModalRequest.orderCancellation(id: request.id)
        return VStack(spacing: 0) {
            if let title = confirmation.title {
                GlobalModalText(message: title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(brand.theme.text)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("global.modal.title")
            }

            if let message = confirmation.message {
                GlobalModalText(message: message)
                    .font(.body.weight(.regular))
                    .foregroundStyle(brand.theme.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                    .accessibilityIdentifier("global.modal.message")
            }

            if let secondary = confirmation.secondary {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        paymentCancellationButton(secondary)
                        paymentCancellationButton(confirmation.primary)
                    }
                    VStack(spacing: 10) {
                        paymentCancellationButton(confirmation.primary)
                        paymentCancellationButton(secondary)
                    }
                }
                .padding(.top, 24)
            }
        }
    }

    private func paymentCancellationButton(
        _ button: GlobalModalButton
    ) -> some View {
        Button {
            if button.role == .cancel {
                showsPaymentCancellationConfirmation = false
                return
            }
            guard !paymentStatusActionInFlight else { return }
            paymentStatusActionInFlight = true
            Task {
                _ = await presenter.perform(
                    .cancelPendingOrder,
                    requestID: request.id
                )
                guard presenter.isPresenting(requestID: request.id) else { return }
                showsPaymentCancellationConfirmation = false
                paymentStatusActionInFlight = false
            }
        } label: {
            if paymentStatusActionInFlight && button.role == .destructive {
                ProgressView().tint(Color.white)
            } else {
                GlobalModalText(message: button.title)
            }
        }
        .buttonStyle(GlobalModalActionButtonStyle(role: button.role))
        .disabled(paymentStatusActionInFlight)
        .accessibilityIdentifier(button.identifier)
    }

    private func paymentStatusLine(
        _ status: GlobalModalPaymentStatus
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: paymentStatusIcon(status))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(paymentStatusColor(status))
                .accessibilityHidden(true)
            GlobalModalText(message: .localized(paymentStatusKey(status)))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(paymentStatusColor(status))
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityIdentifier("global.modal.payment.status")
    }

    @ViewBuilder
    private func paymentStatusActionArea(
        _ status: GlobalModalPaymentStatus
    ) -> some View {
        if status.isTerminal {
            actionButton(request.primary, choice: .primary)
        } else if let secondary = request.secondary {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    paymentStatusCancellationButton(secondary)
                    paymentStatusInteractionButton(
                        request.primary,
                        interaction: .checkPaymentStatus
                    )
                }
                VStack(spacing: 10) {
                    paymentStatusInteractionButton(
                        request.primary,
                        interaction: .checkPaymentStatus
                    )
                    paymentStatusCancellationButton(secondary)
                }
            }
        } else {
            paymentStatusInteractionButton(
                request.primary,
                interaction: .checkPaymentStatus
            )
        }
    }

    private func paymentStatusCancellationButton(
        _ button: GlobalModalButton
    ) -> some View {
        Button {
            guard !paymentStatusActionInFlight else { return }
            showsPaymentCancellationConfirmation = true
        } label: {
            GlobalModalText(message: button.title)
        }
        .buttonStyle(GlobalModalActionButtonStyle(role: button.role))
        .disabled(paymentStatusActionInFlight)
        .accessibilityIdentifier(button.identifier)
    }

    private func paymentStatusInteractionButton(
        _ button: GlobalModalButton,
        interaction: GlobalModalInteraction
    ) -> some View {
        Button {
            guard !paymentStatusActionInFlight else { return }
            paymentStatusActionInFlight = true
            Task {
                _ = await presenter.perform(interaction, requestID: request.id)
                guard presenter.isPresenting(requestID: request.id) else { return }
                paymentStatusActionInFlight = false
            }
        } label: {
            if paymentStatusActionInFlight {
                ProgressView()
                    .tint(button.role == .tonal
                        ? brand.theme.emphasis : Color.white)
            } else {
                GlobalModalText(message: button.title)
            }
        }
        .buttonStyle(GlobalModalActionButtonStyle(role: button.role))
        .disabled(paymentStatusActionInFlight)
        .accessibilityIdentifier(button.identifier)
    }

    private func paymentStatusKey(
        _ status: GlobalModalPaymentStatus
    ) -> String {
        switch status {
        case .pending: "purchase.payment.pending"
        case .activating: "purchase.payment.activating"
        case .completed: "purchase.payment.success"
        case .cancelled: "purchase.payment.cancelled"
        case .offset: "purchase.payment.offset"
        case .unknown: "profile.orders.status.unknown"
        }
    }

    private func paymentStatusIcon(
        _ status: GlobalModalPaymentStatus
    ) -> String {
        switch status {
        case .pending: "clock"
        case .activating: "arrow.triangle.2.circlepath"
        case .completed: "checkmark.circle.fill"
        case .cancelled: "xmark.circle.fill"
        case .offset: "arrow.triangle.branch"
        case .unknown: "questionmark.circle"
        }
    }

    private func paymentStatusColor(
        _ status: GlobalModalPaymentStatus
    ) -> Color {
        switch status {
        case .completed: brand.theme.color("success")
        case .cancelled: brand.theme.error
        case .pending, .activating, .offset, .unknown: brand.theme.secondary
        }
    }

    private func paymentMethodBody(
        _ content: GlobalModalPaymentMethodContent
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 8) {
                ForEach(content.summaryRows) { row in
                    paymentSummaryRow(label: row.label, value: row.value)
                }
                if let handlingAmount = paymentMethodState.selectedMethod?.handlingAmount {
                    paymentSummaryRow(
                        label: .localized("purchase.payment.handling_fee"),
                        value: handlingAmount
                    )
                }
                paymentSummaryRow(
                    label: .localized("purchase.payment.amount_due"),
                    value: paymentMethodState.selectedMethod?.amountDue ?? content.baseAmountDue,
                    emphasized: true
                )
            }
            .padding(13)
            .background(brand.theme.field)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(brand.theme.border, lineWidth: 1)
            }

            GlobalModalText(message: .localized("purchase.payment.payment_method"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(brand.theme.text)

            VStack(spacing: 10) {
                ForEach(content.methods) { method in
                    paymentMethodOption(method)
                }
            }
        }
    }

    private func paymentSummaryRow(
        label: LocalizedMessage,
        value: String,
        emphasized: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            GlobalModalText(message: label)
                .font(.subheadline.weight(emphasized ? .semibold : .regular))
                .foregroundStyle(emphasized ? brand.theme.text : brand.theme.secondary)
            Spacer(minLength: 12)
            Text(verbatim: value)
                .font(.subheadline.weight(emphasized ? .semibold : .regular))
                .foregroundStyle(emphasized ? brand.theme.emphasis : brand.theme.text)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func paymentMethodOption(
        _ method: GlobalModalPaymentMethodOption
    ) -> some View {
        let isSelected = paymentMethodState.pendingMethodID == method.id
        return Button {
            paymentMethodState.select(method.id)
        } label: {
            HStack(spacing: 12) {
                paymentMethodIcon(method)

                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: method.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(method.isEnabled
                            ? brand.theme.text : brand.theme.tertiary)
                    if let feeDescription = method.feeDescription {
                        GlobalModalText(message: feeDescription)
                            .font(.footnote.weight(.regular))
                            .foregroundStyle(brand.theme.secondary)
                    }
                    if let disabledReason = method.disabledReason {
                        GlobalModalText(message: disabledReason)
                            .font(.footnote.weight(.regular))
                            .foregroundStyle(brand.theme.error)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(brand.theme.accent)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? brand.theme.tint : brand.theme.field)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? brand.theme.accent : brand.theme.border,
                            lineWidth: isSelected ? 1.5 : 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!method.isEnabled)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("global.modal.payment.method.\(method.id)")
    }

    @ViewBuilder
    private func paymentMethodIcon(
        _ method: GlobalModalPaymentMethodOption
    ) -> some View {
        if let iconURL = method.iconURL {
            AsyncImage(url: iconURL) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Image(systemName: "creditcard.fill")
                    .foregroundStyle(brand.theme.secondary)
            }
            .frame(width: 30, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
        } else {
            Image(systemName: "creditcard.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(method.isEnabled
                    ? brand.theme.emphasis : brand.theme.tertiary)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var paymentMethodActionArea: some View {
        if let secondary = request.secondary {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    actionButton(secondary, choice: .secondary)
                    paymentMethodSubmitButton
                }
                VStack(spacing: 10) {
                    paymentMethodSubmitButton
                    actionButton(secondary, choice: .secondary)
                }
            }
        } else {
            paymentMethodSubmitButton
        }
    }

    private var paymentMethodSubmitButton: some View {
        Button {
            guard let methodID = paymentMethodState.pendingMethodID else { return }
            presenter.resolve(.paymentMethod(methodID), requestID: request.id)
        } label: {
            GlobalModalText(message: request.primary.title)
        }
        .buttonStyle(GlobalModalActionButtonStyle(role: request.primary.role))
        .disabled(paymentMethodState.pendingMethodID == nil)
        .accessibilityIdentifier(request.primary.identifier)
    }

    private var paymentBodyMaximumHeight: CGFloat {
        min(520, max(220, availableHeight - 180))
    }

    private var paymentBodyVisibleHeight: CGFloat {
        guard paymentBodyHeight > 0 else { return paymentBodyMaximumHeight }
        return min(paymentBodyHeight, paymentBodyMaximumHeight)
    }

    private func purchaseOrderRow(
        label: LocalizedMessage,
        value: LocalizedMessage,
        emphasized: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            GlobalModalText(message: label)
                .font(.subheadline.weight(.regular))
                .foregroundStyle(brand.theme.secondary)
            Spacer(minLength: 12)
            GlobalModalText(message: value)
                .font(.subheadline.weight(emphasized ? .semibold : .regular))
                .foregroundStyle(brand.theme.text)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var purchaseCouponContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            GlobalModalText(message: .localized("purchase.payment.coupon"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(brand.theme.text)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    purchaseCouponField
                    purchaseCouponValidationButton
                        .frame(width: 88)
                }
                VStack(spacing: 10) {
                    purchaseCouponField
                    purchaseCouponValidationButton
                }
            }

            purchaseCouponFeedback
        }
    }

    private var purchaseCouponField: some View {
        TextField(
            LocalizedStringKey("purchase.payment.coupon_placeholder"),
            text: Binding(
                get: { couponInputState.text },
                set: { couponInputState.updateText($0) }
            )
        )
        .font(.body.weight(.regular))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .submitLabel(.done)
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
        .background(brand.theme.field)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(brand.theme.border, lineWidth: 1)
        }
        .accessibilityIdentifier("global.modal.purchase.coupon")
    }

    private var purchaseCouponValidationButton: some View {
        Button {
            guard let code = couponInputState.beginValidation() else { return }
            Task {
                let result = await presenter.perform(
                    .validatePurchaseCoupon(code),
                    requestID: request.id
                )
                guard presenter.isPresenting(requestID: request.id) else { return }
                couponInputState.finishValidation(code: code, result: result)
            }
        } label: {
            if case .validating = couponInputState.validation {
                ProgressView()
                    .tint(brand.theme.emphasis)
                    .accessibilityLabel(Text("purchase.payment.check_coupon"))
            } else {
                GlobalModalText(message: .localized("purchase.payment.check_coupon"))
            }
        }
        .buttonStyle(GlobalModalActionButtonStyle(role: .tonal))
        .disabled(couponInputState.normalizedCode.isEmpty || isCouponValidationInProgress)
        .accessibilityIdentifier("global.modal.purchase.validate_coupon")
    }

    @ViewBuilder
    private var purchaseCouponFeedback: some View {
        switch couponInputState.validation {
        case let .available(_, name):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(brand.theme.color("success"))
                    .accessibilityHidden(true)
                Text(verbatim: name)
            }
            .font(.footnote.weight(.regular))
            .foregroundStyle(brand.theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("global.modal.purchase.coupon_available")
        case let .unavailable(_, message):
            GlobalModalText(message: message)
                .font(.footnote.weight(.regular))
                .foregroundStyle(brand.theme.error)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("global.modal.purchase.coupon_error")
        case .idle, .validating:
            EmptyView()
        }
    }

    private var isCouponValidationInProgress: Bool {
        if case .validating = couponInputState.validation { return true }
        return false
    }

    @ViewBuilder
    private var purchaseOrderActionArea: some View {
        if let secondary = request.secondary {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    actionButton(secondary, choice: .secondary)
                    purchaseOrderCreateButton
                }
                VStack(spacing: 10) {
                    purchaseOrderCreateButton
                    actionButton(secondary, choice: .secondary)
                }
            }
        } else {
            purchaseOrderCreateButton
        }
    }

    private var purchaseOrderCreateButton: some View {
        Button {
            presenter.resolve(
                .purchaseOrder(couponCode: couponInputState.submittedCode),
                requestID: request.id
            )
        } label: {
            GlobalModalText(message: request.primary.title)
        }
        .buttonStyle(GlobalModalActionButtonStyle(role: request.primary.role))
        .disabled(!couponInputState.canSubmit || isCouponValidationInProgress)
        .accessibilityIdentifier(request.primary.identifier)
    }

    private func selectionOption(
        _ option: GlobalModalSelectionOption
    ) -> some View {
        let isSelected = selectionState.pendingID == option.id
        return Button {
            if request.selectionBehavior == .immediate {
                presenter.resolve(.selection(option.id), requestID: request.id)
            } else {
                selectionState.select(option.id)
            }
        } label: {
            HStack(spacing: 12) {
                if let systemImage = option.systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(isSelected
                            ? brand.theme.emphasis : brand.theme.secondary)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 2) {
                    GlobalModalText(message: option.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(brand.theme.text)
                    if let message = option.message {
                        GlobalModalText(message: message)
                            .font(.footnote.weight(.regular))
                            .foregroundStyle(brand.theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(brand.theme.accent)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? brand.theme.tint : brand.theme.field)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected
                        ? brand.theme.accent : brand.theme.border,
                        lineWidth: isSelected ? 1.5 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("global.modal.selection.\(option.id)")
    }

    @ViewBuilder
    private var selectionActionArea: some View {
        if let secondary = request.secondary {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    actionButton(secondary, choice: .secondary)
                    selectionApplyButton
                }
                VStack(spacing: 10) {
                    selectionApplyButton
                    actionButton(secondary, choice: .secondary)
                }
            }
        } else {
            selectionApplyButton
        }
    }

    private var selectionApplyButton: some View {
        Button {
            guard let pendingID = selectionState.pendingID else { return }
            presenter.resolve(.selection(pendingID), requestID: request.id)
        } label: {
            GlobalModalText(message: request.primary.title)
        }
        .buttonStyle(GlobalModalActionButtonStyle(role: request.primary.role))
        .disabled(selectionState.pendingID == nil)
        .accessibilityIdentifier(request.primary.identifier)
    }

    private var announcementBodyMaximumHeight: CGFloat {
        min(480, max(120, min(availableHeight * 0.48, availableHeight - 190)))
    }

    private var announcementBodyHeight: CGFloat {
        guard announcementMessageHeight > 0 else { return announcementBodyMaximumHeight }
        return min(announcementMessageHeight, announcementBodyMaximumHeight)
    }

    private func announcementMessage(_ message: LocalizedMessage) -> some View {
        GlobalModalText(message: message)
            .font(.subheadline.weight(.regular))
            .foregroundStyle(brand.theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("global.modal.message")
    }

    @ViewBuilder
    private var announcementActionArea: some View {
        if let copyAction = request.secondary, let copyText = request.copyText {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    announcementCopyButton(copyAction, copyText: copyText)
                    actionButton(request.primary, choice: .primary)
                }
                VStack(spacing: 10) {
                    announcementCopyButton(copyAction, copyText: copyText)
                    actionButton(request.primary, choice: .primary)
                }
            }
        } else {
            actionButton(request.primary, choice: .primary)
        }
    }

    private func announcementCopyButton(
        _ action: GlobalModalButton,
        copyText: String
    ) -> some View {
        Button {
            UIPasteboard.general.string = copyText
            announcementCopySucceeded = true
            announcementCopyGeneration &+= 1
        } label: {
            GlobalModalText(message: announcementCopySucceeded
                ? .localized("home.notice.copied")
                : action.title)
        }
        .buttonStyle(GlobalModalActionButtonStyle(role: action.role))
        .accessibilityIdentifier(action.identifier)
        .task(id: announcementCopyGeneration) {
            guard announcementCopyGeneration > 0 else { return }
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            announcementCopySucceeded = false
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        if let secondary = request.secondary {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    actionButton(secondary, choice: .secondary)
                    actionButton(request.primary, choice: .primary)
                }
                VStack(spacing: 10) {
                    actionButton(request.primary, choice: .primary)
                    actionButton(secondary, choice: .secondary)
                }
            }
        } else {
            actionButton(request.primary, choice: .primary)
        }
    }

    private func actionButton(
        _ action: GlobalModalButton,
        choice: GlobalModalChoice
    ) -> some View {
        Button(role: action.role.swiftUIRole) {
            presenter.resolve(choice, requestID: request.id)
        } label: {
            GlobalModalText(message: action.title)
        }
        .buttonStyle(GlobalModalActionButtonStyle(role: action.role))
        .accessibilityIdentifier(action.identifier)
    }

    private var resultStyle: GlobalModalResultStyle? {
        guard case let .result(style) = request.kind else { return nil }
        return style
    }
}

private struct GlobalModalText: View {
    let message: LocalizedMessage

    var body: some View {
        switch message {
        case let .localized(key): Text(LocalizedStringKey(key))
        case let .verbatim(value): Text(verbatim: value)
        }
    }
}

private struct GlobalModalActionButtonStyle: ButtonStyle {
    @EnvironmentObject private var brand: BrandProvider
    let role: GlobalModalButtonRole

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(buttonFont)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(foregroundColor)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(role == .cancel ? brand.theme.border : .clear, lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.76 : 1)
    }

    private var buttonFont: Font {
        switch role {
        case .normal, .destructive:
            .body.weight(.semibold)
        case .cancel, .tonal:
            .body.weight(.medium)
        }
    }

    private var foregroundColor: Color {
        switch role {
        case .normal, .destructive: brand.theme.onAccent
        case .cancel: brand.theme.text
        case .tonal: brand.theme.emphasis
        }
    }

    private var backgroundColor: Color {
        switch role {
        case .normal: brand.theme.accent
        case .cancel: brand.theme.field
        case .destructive: brand.theme.error
        case .tonal: brand.theme.tint
        }
    }
}
