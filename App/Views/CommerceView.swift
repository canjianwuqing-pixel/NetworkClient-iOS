import SwiftUI
import CoreImage.CIFilterBuiltins

enum CommercePlansLayout {
    static let sectionSpacing: CGFloat = 10

    static func showsFixedRefreshIndicator(
        loadState: BusinessDataLoadState,
        hasPlans: Bool
    ) -> Bool {
        loadState.isLoading && hasPlans
    }
}

enum CommerceActionAppearance {
    static let minimumTapSize: CGFloat = 44
}

private extension View {
    func commerceInlineActionLabel() -> some View {
        frame(
            minWidth: CommerceActionAppearance.minimumTapSize,
            minHeight: CommerceActionAppearance.minimumTapSize
        )
        .contentShape(Rectangle())
    }
}

#if DEBUG
private enum CommerceUITestFixture {
    enum Mode {
        case initialPlansFailure
        case stalePlansFailure
        case pendingReady
        case pendingFailure
    }

    static var mode: Mode? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--offline"), arguments.contains("--ui-sample") else {
            return nil
        }
        if arguments.contains("--ui-purchase-initial-error") { return .initialPlansFailure }
        if arguments.contains("--ui-purchase-stale-error") { return .stalePlansFailure }
        if arguments.contains("--ui-purchase-pending-ready") { return .pendingReady }
        if arguments.contains("--ui-purchase-pending-error") { return .pendingFailure }
        return nil
    }

    static let pendingDetail = PurchaseOrderDetail(
        tradeNo: "ui-purchase-pending",
        status: 0,
        checkoutType: nil,
        planID: 1,
        planName: "UI Fixture Plan",
        period: "month_price",
        planPriceCents: 1_800,
        totalAmountCents: 1_800,
        discountAmountCents: 0,
        surplusAmountCents: 0,
        balanceAmountCents: 0,
        refundAmountCents: 0,
        handlingAmountCents: 0
    )
}
#endif

struct PurchaseOrderModalSubmission: Equatable {
    let couponCode: String?
}

enum PurchaseOrderModalPresentation {
    static func request(
        plan: PurchasePlan,
        cycle: PurchasePlanCycle,
        locale: Locale
    ) -> GlobalModalRequest {
        GlobalModalRequest.purchaseOrder(
            planName: plan.name,
            period: .localized(cycle.period.localizationKey),
            price: CommerceView.price(cycle.priceCents, locale: locale)
        )
    }

    static func submission(for choice: GlobalModalChoice) -> PurchaseOrderModalSubmission? {
        guard case let .purchaseOrder(couponCode) = choice else { return nil }
        return PurchaseOrderModalSubmission(couponCode: couponCode)
    }
}

enum PaymentOrderDetailState: Equatable {
    case idle
    case loading
    case loaded(PurchaseOrderDetail)
    case failed(LocalizedMessage)
}

enum CommerceOrderCreationNavigation {
    static func paymentTradeNo(
        for outcome: PurchaseOrderCreationOutcome
    ) -> String? {
        guard case let .created(tradeNo) = outcome else { return nil }
        return tradeNo
    }

    static func checkoutTradeNo(
        tradeNo: String,
        checkout: PurchaseCheckoutResult?
    ) -> String? {
        guard checkout != nil else { return nil }
        return tradeNo
    }
}

enum CommercePendingPaymentState: Equatable {
    case idle
    case loading(tradeNo: String)
    case ready(PurchaseOrderDetail)
    case failed(tradeNo: String, LocalizedMessage)
}

enum PaymentMethodModalPresentation {
    static func request(
        detail: PurchaseOrderDetail,
        methods: [PurchasePaymentMethod],
        locale: Locale
    ) -> GlobalModalRequest {
        GlobalModalRequest.paymentMethod(
            tradeNo: detail.tradeNo,
            summaryRows: summaryRows(detail: detail, locale: locale),
            methods: methods.map { option(method: $0, detail: detail, locale: locale) },
            baseAmountDue: CommerceView.price(detail.amountDueCents, locale: locale)
        )
    }

    static func selectedMethodID(for choice: GlobalModalChoice) -> Int? {
        guard case let .paymentMethod(methodID) = choice else { return nil }
        return methodID
    }

    static func summaryRows(
        detail: PurchaseOrderDetail,
        locale: Locale
    ) -> [GlobalModalPaymentSummaryRow] {
        var rows: [GlobalModalPaymentSummaryRow] = []
        if !detail.planName.isEmpty {
            rows.append(.init(
                id: "plan",
                label: .localized("purchase.payment.plan"),
                value: detail.planName
            ))
        }
        rows.append(.init(
            id: "period",
            label: .localized("purchase.payment.period"),
            value: periodName(detail.period, locale: locale)
        ))
        rows.append(.init(
            id: "plan-price",
            label: .localized("purchase.payment.plan_price"),
            value: CommerceView.price(detail.planPriceCents, locale: locale)
        ))
        appendDeduction(
            id: "discount",
            key: "purchase.payment.discount",
            cents: detail.discountAmountCents,
            locale: locale,
            to: &rows
        )
        appendDeduction(
            id: "surplus",
            key: "purchase.payment.subscription_credit",
            cents: detail.surplusAmountCents,
            locale: locale,
            to: &rows
        )
        appendDeduction(
            id: "balance",
            key: "purchase.payment.balance_applied",
            cents: detail.balanceAmountCents,
            locale: locale,
            to: &rows
        )
        if detail.refundAmountCents > 0 {
            rows.append(.init(
                id: "refund",
                label: .localized("purchase.payment.balance_refund"),
                value: "+\(CommerceView.price(detail.refundAmountCents, locale: locale))"
            ))
        }
        return rows
    }

    private static func appendDeduction(
        id: String,
        key: String,
        cents: Int64,
        locale: Locale,
        to rows: inout [GlobalModalPaymentSummaryRow]
    ) {
        guard cents > 0 else { return }
        rows.append(.init(
            id: id,
            label: .localized(key),
            value: "−\(CommerceView.price(cents, locale: locale))"
        ))
    }

    private static func option(
        method: PurchasePaymentMethod,
        detail: PurchaseOrderDetail,
        locale: Locale
    ) -> GlobalModalPaymentMethodOption {
        let handling = method.handlingAmountCents(for: detail.totalAmountCents)
        let amountDue = handling.flatMap { amount in
            let result = detail.totalAmountCents.addingReportingOverflow(amount)
            return result.overflow ? nil : max(0, result.partialValue)
        }
        let isEnabled = method.isSupportedByCurrentClient && amountDue != nil
        let disabledReason: LocalizedMessage? = if method.isStripeCredit {
            .localized("purchase.payment.unsupported")
        } else if amountDue == nil {
            .localized("purchase.payment.invalid_fee")
        } else {
            nil
        }
        return GlobalModalPaymentMethodOption(
            id: method.id,
            name: method.name,
            iconURL: method.iconURL,
            feeDescription: feeDescription(method: method, locale: locale),
            handlingAmount: handling.flatMap { $0 > 0
                ? "+\(CommerceView.price($0, locale: locale))" : nil
            },
            amountDue: amountDue.map { CommerceView.price($0, locale: locale) } ?? "--",
            isEnabled: isEnabled,
            disabledReason: disabledReason
        )
    }

    private static func feeDescription(
        method: PurchasePaymentMethod,
        locale: Locale
    ) -> LocalizedMessage? {
        var parts: [String] = []
        if method.handlingFeePercent > 0 {
            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 3
            formatter.minimumFractionDigits = 0
            let percent = formatter.string(from: NSNumber(value: method.handlingFeePercent))
                ?? String(method.handlingFeePercent)
            parts.append("\(percent)%")
        }
        if method.handlingFeeFixedCents > 0 {
            parts.append(CommerceView.price(method.handlingFeeFixedCents, locale: locale))
        }
        guard !parts.isEmpty else { return nil }
        return .verbatim(AppLocalization.string(
            "purchase.payment.fee_description %@",
            locale: locale,
            arguments: [parts.joined(separator: " + ")]
        ))
    }

    static func periodName(_ rawValue: String, locale: Locale) -> String {
        guard let period = PurchasePlanPeriod(rawValue: rawValue) else { return rawValue }
        return AppLocalization.string(period.localizationKey, locale: locale)
    }
}

enum PaymentStatusModalPresentation {
    static func request(
        id: UUID,
        detail: PurchaseOrderDetail,
        status: PurchasePaymentStatus,
        feedback: LocalizedMessage?,
        locale: Locale
    ) -> GlobalModalRequest {
        GlobalModalRequest.paymentStatus(
            id: id,
            tradeNo: detail.tradeNo,
            summaryRows: [
                .init(
                    id: "plan",
                    label: .localized("purchase.payment.plan"),
                    value: detail.planName
                ),
                .init(
                    id: "period",
                    label: .localized("purchase.payment.period"),
                    value: PaymentMethodModalPresentation.periodName(
                        detail.period,
                        locale: locale
                    )
                ),
                .init(
                    id: "plan-price",
                    label: .localized("purchase.payment.plan_price"),
                    value: CommerceView.price(detail.planPriceCents, locale: locale)
                ),
                .init(
                    id: "order-amount",
                    label: .localized("purchase.payment.order_amount"),
                    value: CommerceView.price(detail.totalAmountCents, locale: locale)
                )
            ],
            amountDue: CommerceView.price(detail.amountDueCents, locale: locale),
            status: modalStatus(status),
            feedback: feedback
        )
    }

    static func modalStatus(
        _ status: PurchasePaymentStatus
    ) -> GlobalModalPaymentStatus {
        switch status {
        case .pending: .pending
        case .activating: .activating
        case .completed: .completed
        case .cancelled: .cancelled
        case .offset: .offset
        case .unknown: .unknown
        }
    }
}

/// Binds a multi-step Commerce view operation to the authenticated account
/// that started it and, when applicable, to one order. It deliberately exposes
/// neither the credential nor the account hash to the view.
@MainActor
struct CommerceOperationContext: Sendable {
    private let account: AppModel.CommerceAccountContext
    private let tradeNo: String?

    init(model: AppModel, tradeNo: String? = nil) {
        account = model.captureCommerceContext()
        self.tradeNo = tradeNo
    }

    private init(account: AppModel.CommerceAccountContext, tradeNo: String?) {
        self.account = account
        self.tradeNo = tradeNo
    }

    func binding(tradeNo: String) -> CommerceOperationContext {
        CommerceOperationContext(account: account, tradeNo: tradeNo)
    }

    func isCurrent(in model: AppModel, tradeNo currentTradeNo: String? = nil) -> Bool {
        guard model.isCurrentCommerceContext(account) else { return false }
        guard let tradeNo else { return true }
        return currentTradeNo == tradeNo
    }

    func performIfCurrent<Result>(
        in model: AppModel,
        tradeNo currentTradeNo: String? = nil,
        _ operation: @MainActor () async -> Result
    ) async -> Result? {
        guard isCurrent(in: model, tradeNo: currentTradeNo) else { return nil }
        return await operation()
    }
}

@MainActor
final class PaymentStatusCoordinator: ObservableObject {
    private enum CheckTrigger { case automatic, manual, foreground, restored }

    private struct Session {
        let requestID: UUID
        let detail: PurchaseOrderDetail
        let payment: PurchasePendingPayment
        let accountContext: AppModel.CommerceAccountContext
        let accountGeneration: UUID
        let checkoutOperationID: UUID?
        var status: PurchasePaymentStatus
        var feedback: LocalizedMessage?
        var didRefreshCompletedPurchase = false
    }

    private weak var model: AppModel?
    private weak var presenter: GlobalModalPresenter?
    private var locale = Locale.current
    private var session: Session?
    private var presentationTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var pollingOperationID: UUID?
    private var recoveryOperationID: UUID?
    private var recoveryGeneration: UUID?
    private var recoveryContext: AppModel.CommerceAccountContext?
    private var sceneIsActive = true
    private let beforeExternalOpen: @MainActor @Sendable () async -> Void

    init(
        beforeExternalOpen: @escaping @MainActor @Sendable () async -> Void = {
            await Task.yield()
        }
    ) {
        self.beforeExternalOpen = beforeExternalOpen
    }

    var isMonitoring: Bool { session != nil }

    func accountContextChanged(
        session currentSession: UserSession?,
        generation: UUID
    ) {
        if let active = session, let model,
           !isCurrent(active, in: model) {
            dismissAndStop(active)
            return
        }
        let owner = currentSession.map(PendingPaymentStore.accountIdentifier(for:))
        if let active = session,
           active.payment.accountIdentifier != owner
            || active.accountGeneration != generation {
            stop()
            return
        }
        if recoveryGeneration != nil, recoveryGeneration != generation {
            recoveryOperationID = nil
            recoveryGeneration = nil
            recoveryContext = nil
        }
        if let recoveryContext, let model,
           !model.isCurrentCommerceContext(recoveryContext) {
            recoveryOperationID = nil
            recoveryGeneration = nil
            self.recoveryContext = nil
        }
        if currentSession == nil { stop() }
    }

    /// Reconciles persisted payment state before publishing recovery UI. This
    /// is read-only until a terminal server status clears the pending record;
    /// it never creates an order or starts checkout.
    func recoverPendingPaymentIfNeeded(
        model: AppModel,
        presenter: GlobalModalPresenter,
        locale: Locale
    ) async {
        guard session == nil, recoveryOperationID == nil, !model.busy else { return }
        let operationID = UUID()
        let generation = model.commerceRecoveryGeneration
        let context = model.captureCommerceContext()
        recoveryOperationID = operationID
        recoveryGeneration = generation
        recoveryContext = context
        defer {
            if recoveryOperationID == operationID {
                recoveryOperationID = nil
                recoveryGeneration = nil
                recoveryContext = nil
            }
        }

        guard let payment = await model.restoredPaymentMonitoring(),
              recoveryOperationID == operationID,
              model.commerceRecoveryGeneration == generation,
              model.isCurrentCommerceContext(context) else { return }

        let verifiedStatus: PurchasePaymentStatus
        switch await model.checkPaymentStatus(trade: payment.tradeNo) {
        case let .status(status):
            guard status == .pending || status == .activating else {
                // Terminal statuses were cleared by AppModel. Unknown remains
                // persisted but is not presented as a verified payable state.
                return
            }
            verifiedStatus = status
        case .unavailable, .cancelled:
            return
        }
        guard recoveryOperationID == operationID,
              model.commerceRecoveryGeneration == generation,
              model.isCurrentCommerceContext(context),
              model.session.map(PendingPaymentStore.accountIdentifier(for:))
                == payment.accountIdentifier else { return }

        guard case let .loaded(detail) = await model.loadOrderDetail(
            trade: payment.tradeNo
        ), recoveryOperationID == operationID,
           model.commerceRecoveryGeneration == generation,
           model.isCurrentCommerceContext(context),
           detail.tradeNo == payment.tradeNo else { return }

        await restore(
            detail: detail,
            payment: payment,
            verifiedStatus: verifiedStatus,
            model: model,
            presenter: presenter,
            locale: locale
        )
    }

    func start(
        detail: PurchaseOrderDetail,
        checkout: AppModel.OwnedPurchaseCheckout,
        model: AppModel,
        presenter: GlobalModalPresenter,
        locale: Locale,
        openURL: @escaping @MainActor (URL) -> Bool
    ) async -> Bool {
        guard session == nil,
              isOrderPayable(detail, in: model),
              model.isCurrentCheckout(checkout, tradeNo: detail.tradeNo) else {
            return false
        }
        let accountContext = model.captureCommerceContext()
        let payment: PurchasePendingPayment
        switch await model.beginPaymentMonitoring(detail: detail) {
        case let .ready(ready): payment = ready
        case let .unavailable(message):
            guard model.isCurrentCommerceContext(accountContext),
                  model.isCurrentCheckout(checkout, tradeNo: detail.tradeNo) else {
                return false
            }
            model.message = message
            return false
        case .cancelled:
            return false
        }
        guard model.isCurrentCommerceContext(accountContext),
              model.isCurrentCheckout(checkout, tradeNo: detail.tradeNo),
              payment.tradeNo == detail.tradeNo else { return false }

        configure(
            detail: detail,
            payment: payment,
            accountContext: accountContext,
            checkoutOperationID: checkout.operationID,
            model: model,
            presenter: presenter,
            locale: locale
        )
        startPresentation()
        startPollingIfNeeded()
        guard let active = session, isCurrent(active, in: model) else { return false }
        await beforeExternalOpen()

        guard let current = session,
              current.requestID == active.requestID,
              current.status == .pending,
              isOrderPayable(current.detail, in: model),
              isCurrent(current, in: model),
              model.isCurrentCheckout(checkout, tradeNo: detail.tradeNo) else {
            dismissAndStop(active)
            return false
        }

        guard checkout.result.type == 1,
              let text = checkout.result.data,
              let url = URL(string: text),
              url.scheme?.lowercased() == "https",
              openURL(url) else {
            updateFeedback(.localized("purchase.payment.open_page_failed"))
            return true
        }
        return true
    }

    func restore(
        detail: PurchaseOrderDetail,
        payment: PurchasePendingPayment,
        verifiedStatus: PurchasePaymentStatus? = nil,
        model: AppModel,
        presenter: GlobalModalPresenter,
        locale: Locale
    ) async {
        let accountContext = model.captureCommerceContext()
        guard session == nil, payment.paymentStartedAt != nil,
              model.isCurrentCommerceContext(accountContext),
              detail.tradeNo == payment.tradeNo,
              model.session.map(PendingPaymentStore.accountIdentifier(for:))
                == payment.accountIdentifier else { return }
        configure(
            detail: detail,
            payment: payment,
            accountContext: accountContext,
            checkoutOperationID: nil,
            initialStatus: verifiedStatus,
            model: model,
            presenter: presenter,
            locale: locale
        )
        startPresentation()
        if verifiedStatus == nil { await performCheck(.restored) }
        startPollingIfNeeded()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        sceneIsActive = phase == .active
        guard let active = session else { return }
        if sceneIsActive {
            Task { [weak self] in
                guard let self else { return }
                guard let model = self.model,
                      self.isCurrent(active, in: model) else {
                    self.dismissAndStop(active)
                    return
                }
                await self.performCheck(.foreground)
                guard let current = self.session,
                      current.requestID == active.requestID,
                      self.isCurrent(current, in: model) else { return }
                self.startPollingIfNeeded()
            }
        } else {
            pollingTask?.cancel()
            pollingTask = nil
            pollingOperationID = nil
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        pollingOperationID = nil
        presentationTask?.cancel()
        presentationTask = nil
        session = nil
        recoveryOperationID = nil
        recoveryGeneration = nil
        recoveryContext = nil
        model = nil
        presenter = nil
    }

    private func configure(
        detail: PurchaseOrderDetail,
        payment: PurchasePendingPayment,
        accountContext: AppModel.CommerceAccountContext,
        checkoutOperationID: UUID?,
        initialStatus: PurchasePaymentStatus? = nil,
        model: AppModel,
        presenter: GlobalModalPresenter,
        locale: Locale
    ) {
        self.model = model
        self.presenter = presenter
        self.locale = locale
        session = Session(
            requestID: UUID(),
            detail: detail,
            payment: payment,
            accountContext: accountContext,
            accountGeneration: model.commerceRecoveryGeneration,
            checkoutOperationID: checkoutOperationID,
            status: initialStatus ?? PurchasePaymentStatus(serverValue: detail.status),
            feedback: nil
        )
    }

    private func startPresentation() {
        guard let session, let presenter, let model,
              isCurrent(session, in: model) else { return }
        let request = request(for: session)
        presentationTask = Task { [weak self, weak presenter] in
            guard let self, let presenter else { return }
            _ = await presenter.present(request) { [weak self] interaction in
                guard let self else { return .cancelled }
                switch interaction {
                case .checkPaymentStatus:
                    await self.performCheck(.manual)
                    return .completed
                case .cancelPendingOrder:
                    await self.cancelOrder()
                    return .completed
                case .validatePurchaseCoupon:
                    return .cancelled
                }
            }
            self.presentationEnded(requestID: request.id)
        }
    }

    private func presentationEnded(requestID: UUID) {
        guard session?.requestID == requestID else { return }
        pollingTask?.cancel()
        pollingTask = nil
        pollingOperationID = nil
        presentationTask = nil
        session = nil
        model = nil
        presenter = nil
    }

    private func startPollingIfNeeded() {
        guard pollingTask == nil, sceneIsActive,
              let session, let model,
              isCurrent(session, in: model),
              !session.status.isTerminal,
              PaymentStatusPollingPolicy.delaySeconds(
                  startedAt: session.payment.paymentStartedAt ?? session.payment.createdAt
              ) != nil else { return }
        let requestID = session.requestID
        let operationID = UUID()
        pollingOperationID = operationID
        pollingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.session?.requestID == requestID,
                   self.pollingOperationID == operationID {
                    self.pollingTask = nil
                    self.pollingOperationID = nil
                }
            }
            while !Task.isCancelled {
                guard let active = self.session,
                      active.requestID == requestID,
                      self.pollingOperationID == operationID,
                      self.isCurrent(active, in: model),
                      !active.status.isTerminal,
                      self.sceneIsActive,
                      let delay = PaymentStatusPollingPolicy.delaySeconds(
                          startedAt: active.payment.paymentStartedAt
                              ?? active.payment.createdAt
                      ) else { return }
                let nanoseconds = UInt64((delay * 1_000_000_000).rounded())
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled, self.sceneIsActive,
                      self.pollingOperationID == operationID,
                      let current = self.session,
                      current.requestID == requestID,
                      self.isCurrent(current, in: model) else { return }
                await self.performCheck(.automatic)
            }
        }
    }

    private func performCheck(_ trigger: CheckTrigger) async {
        guard let active = session, let model else { return }
        guard isCurrent(active, in: model) else {
            dismissAndStop(active)
            return
        }

        switch await model.checkPaymentStatus(trade: active.detail.tradeNo) {
        case let .status(status):
            guard var current = session,
                  current.requestID == active.requestID,
                  isCurrent(current, in: model) else { return }
            if current.status == .activating, status == .pending { return }
            current.status = status
            current.feedback = trigger == .manual && status == .pending
                ? .localized("purchase.payment.not_paid") : nil
            session = current
            updatePresentation()
            if status.isTerminal {
                pollingTask?.cancel()
                pollingTask = nil
                pollingOperationID = nil
            }
            if status == .completed, !current.didRefreshCompletedPurchase {
                current.didRefreshCompletedPurchase = true
                session = current
                let context = current.accountContext
                Task { [weak model] in
                    guard let model,
                          model.isCurrentCommerceContext(context) else { return }
                    await model.refreshAccount()
                    guard model.isCurrentCommerceContext(context) else { return }
                    await model.loadCommerce()
                }
            }
        case let .unavailable(message):
            guard let current = session,
                  current.requestID == active.requestID,
                  isCurrent(current, in: model) else { return }
            if trigger == .manual || trigger == .restored {
                updateFeedback(message, requestID: current.requestID)
            }
        case .cancelled:
            break
        }
    }

    private func cancelOrder() async {
        guard let active = session, let model else { return }
        guard isCurrent(active, in: model) else {
            dismissAndStop(active)
            return
        }
        pollingTask?.cancel()
        pollingTask = nil
        pollingOperationID = nil
        switch await model.cancelPendingOrder(trade: active.detail.tradeNo) {
        case .cancelledOrder:
            guard var current = session,
                  current.requestID == active.requestID,
                  isCurrent(current, in: model) else { return }
            current.status = .cancelled
            current.feedback = nil
            session = current
            updatePresentation()
        case let .unavailable(message):
            guard let current = session,
                  current.requestID == active.requestID,
                  isCurrent(current, in: model) else { return }
            updateFeedback(message, requestID: current.requestID)
            startPollingIfNeeded()
        case .cancelled:
            guard let current = session,
                  current.requestID == active.requestID,
                  isCurrent(current, in: model) else { return }
            startPollingIfNeeded()
        }
    }

    private func updateFeedback(
        _ feedback: LocalizedMessage,
        requestID: UUID? = nil
    ) {
        guard var current = session,
              requestID == nil || current.requestID == requestID,
              let model, isCurrent(current, in: model) else { return }
        current.feedback = feedback
        session = current
        updatePresentation()
    }

    private func updatePresentation() {
        guard let session, let model, isCurrent(session, in: model) else { return }
        presenter?.update(request(for: session), requestID: session.requestID)
    }

    private func isCurrent(_ active: Session, in model: AppModel) -> Bool {
        guard session?.requestID == active.requestID,
              active.detail.tradeNo == active.payment.tradeNo,
              model.isCurrentCommerceContext(active.accountContext),
              model.commerceRecoveryGeneration == active.accountGeneration,
              model.session.map(PendingPaymentStore.accountIdentifier(for:))
                == active.payment.accountIdentifier else { return false }
        guard let operationID = active.checkoutOperationID else { return true }
        return model.isCurrentCheckoutOperation(
            operationID,
            tradeNo: active.detail.tradeNo
        )
    }

    private func isOrderPayable(
        _ detail: PurchaseOrderDetail,
        in model: AppModel
    ) -> Bool {
        OrderDetailPaymentAccessPolicy.canPresent(
            status: PurchasePaymentStatus(serverValue: detail.status),
            order: model.orders.first { $0.tradeNo == detail.tradeNo }
        )
    }

    private func dismissAndStop(_ active: Session) {
        guard session?.requestID == active.requestID else { return }
        presenter?.resolve(.dismissed, requestID: active.requestID)
        stop()
    }

    private func request(for session: Session) -> GlobalModalRequest {
        PaymentStatusModalPresentation.request(
            id: session.requestID,
            detail: session.detail,
            status: session.status,
            feedback: session.feedback,
            locale: locale
        )
    }
}

struct CommerceView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var brand: BrandProvider
    @EnvironmentObject private var modalPresenter: GlobalModalPresenter
    @EnvironmentObject private var usageTermsConsent: UsageTermsConsentCoordinator
    @EnvironmentObject private var paymentStatusCoordinator: PaymentStatusCoordinator
    @Environment(\.locale) private var locale
    @Environment(\.openURL) private var openURL
    @State private var periods: [Int: PurchasePlanPeriod] = [:]
    @State private var expanded = Set<Int>()
    @State private var pendingPaymentState = CommercePendingPaymentState.idle
    @State private var paymentPreparationID: UUID?
    @State private var paymentResultTradeNo: String?
    @State private var didAttemptPaymentRestore = false

    private var displayedPlans: [PurchasePlan] {
        #if DEBUG
        if case .initialPlansFailure = CommerceUITestFixture.mode { return [] }
        #endif
        return model.plans
    }

    private var displayedPlansLoadState: BusinessDataLoadState {
        #if DEBUG
        switch CommerceUITestFixture.mode {
        case .initialPlansFailure:
            return .failed(.localized("purchase.status.failed"))
        case .stalePlansFailure:
            return .stale(.localized("purchase.status.failed"))
        default:
            break
        }
        #endif
        return model.plansLoadState
    }

    private var displayedPendingPaymentState: CommercePendingPaymentState {
        #if DEBUG
        switch CommerceUITestFixture.mode {
        case .pendingReady:
            return .ready(CommerceUITestFixture.pendingDetail)
        case .pendingFailure:
            return .failed(
                tradeNo: CommerceUITestFixture.pendingDetail.tradeNo,
                .localized("purchase.status.failed")
            )
        default:
            break
        }
        #endif
        return pendingPaymentState
    }

    private var showsFixedRefreshIndicator: Bool {
        CommercePlansLayout.showsFixedRefreshIndicator(
            loadState: displayedPlansLoadState,
            hasPlans: !displayedPlans.isEmpty
        )
    }
    var body: some View {
        BrandScreen {
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    HStack(alignment: .top, spacing: 11) {
                        Image(systemName: "info.circle.fill").foregroundStyle(brand.theme.emphasis)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(LocalizedStringKey("purchase.notice.title")).font(.system(size: 14, weight: .semibold))
                            Text(LocalizedStringKey("purchase.notice.message")).font(.system(size: 12)).foregroundStyle(brand.theme.secondary)
                        }
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(brand.theme.field).clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(brand.theme.border, lineWidth: 1))
                    HStack {
                        ZStack(alignment: .leading) {
                            if showsFixedRefreshIndicator {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text(LocalizedStringKey("purchase.status.refreshing"))
                                }
                                .accessibilityIdentifier("purchase.plans.refreshing")
                            } else {
                                Button {
                                    Task { await model.refreshPlans() }
                                } label: {
                                    Text(LocalizedStringKey("purchase.action.refresh"))
                                        .commerceInlineActionLabel()
                                }
                                    .disabled(displayedPlansLoadState.isLoading || model.offline)
                                    .accessibilityIdentifier("purchase.plans.refresh")
                            }
                        }
                        .frame(minHeight: 18, alignment: .leading)
                        Spacer()
                        NavigationLink {
                            model.session == nil
                                ? AnyView(AccountRequiredView()) : AnyView(OrdersView())
                        } label: {
                            Text("我的订单")
                                .commerceInlineActionLabel()
                        }
                        .accessibilityIdentifier("purchase.orders.open")
                    }.font(.system(size: 12)).foregroundStyle(brand.theme.emphasis).padding(.horizontal, 4)
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, CommercePlansLayout.sectionSpacing)

                ScrollView {
                    VStack(spacing: 10) {
                        pendingPaymentCard
                        ForEach(displayedPlans) { plan in planCard(plan) }
                        if displayedPlans.isEmpty {
                            if model.session == nil { AccountRequiredView() }
                            else { plansStatus }
                        } else if let failure = displayedPlansLoadState.failureMessage {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle")
                                LocalizedMessageText(message: failure).lineLimit(2)
                                Spacer(minLength: 4)
                                Button {
                                    Task { await model.refreshPlans() }
                                } label: {
                                    Text(LocalizedStringKey("purchase.action.retry"))
                                        .commerceInlineActionLabel()
                                }
                                .accessibilityIdentifier("purchase.plans.retry")
                            }.font(.system(size: 11)).foregroundStyle(brand.theme.secondary).padding(12).surfaceCard()
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                .accessibilityIdentifier("purchase.plans.scroll")
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .task {
            let context = CommerceOperationContext(model: model)
            await model.refreshPlansIfNeeded()
            guard context.isCurrent(in: model) else { return }
            await restorePaymentStatusIfNeeded(context: context)
        }
        .onChange(of: model.commerceRecoveryGeneration) { _, _ in
            paymentPreparationID = nil
            pendingPaymentState = .idle
            paymentResultTradeNo = nil
            didAttemptPaymentRestore = false
        }
        .navigationDestination(item: $paymentResultTradeNo) { tradeNo in
            PaymentView(tradeNo: tradeNo)
        }
    }

    @ViewBuilder
    private var plansStatus: some View {
        switch displayedPlansLoadState {
        case .idle, .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text(LocalizedStringKey("purchase.status.loading"))
            }
        case .empty, .loaded:
            ContentUnavailableView(LocalizedStringKey("purchase.status.empty"), systemImage: "shippingbox")
        case let .failed(message), let .stale(message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                Text(LocalizedStringKey("purchase.status.failed")).font(.headline)
                LocalizedMessageText(message: message).font(.footnote)
                Button {
                    Task { await model.refreshPlans() }
                } label: {
                    Text(LocalizedStringKey("purchase.action.retry"))
                        .commerceInlineActionLabel()
                }
                .accessibilityIdentifier("purchase.plans.retry")
            }
        }
    }
    private func planCard(_ plan: PurchasePlan) -> some View {
        let selected = periods[plan.id] ?? plan.cycles.first?.period
        return VStack(alignment: .leading, spacing: 14) {
            HStack { Text(verbatim: plan.name).font(.system(size: 17, weight: .bold)); Spacer(); if model.session?.planID == plan.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(brand.theme.emphasis) } }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array((expanded.contains(plan.id) ? plan.features : Array(plan.features.prefix(4))).enumerated()), id: \.offset) { _, feature in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: feature.isSupported ? "checkmark" : "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(feature.isSupported ? brand.theme.emphasis : brand.theme.error).frame(width: 12)
                        Text(verbatim: feature.text).font(.system(size: 12)).foregroundStyle(brand.theme.secondary)
                    }
                }
                if plan.features.count > 4 {
                    Button {
                        if expanded.contains(plan.id) {
                            expanded.remove(plan.id)
                        } else {
                            expanded.insert(plan.id)
                        }
                    } label: {
                        Text(LocalizedStringKey(
                            expanded.contains(plan.id)
                                ? "purchase.action.show_less" : "purchase.action.show_more"
                        ))
                        .commerceInlineActionLabel()
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(brand.theme.emphasis)
                    .accessibilityIdentifier("purchase.plan.\(plan.id).disclosure")
                }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(plan.cycles) { cycle in
                    Button { periods[plan.id] = cycle.period } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(LocalizedStringKey(cycle.period.localizationKey)).font(.system(size: 12, weight: .semibold)); Spacer(minLength: 0); if selected == cycle.period { Image(systemName: "checkmark.circle.fill").font(.system(size: 12)) } }.foregroundStyle(selected == cycle.period ? brand.theme.emphasis : brand.theme.secondary)
                            Text(Self.price(cycle.priceCents, locale: locale)).font(.system(size: 15, weight: .bold)).foregroundStyle(brand.theme.text)
                        }.padding(.horizontal, 11).frame(maxWidth: .infinity, alignment: .leading).frame(height: 60)
                            .background(selected == cycle.period ? brand.theme.tint : brand.theme.field).clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected == cycle.period ? brand.theme.accent : brand.theme.border, lineWidth: 1))
                    }.buttonStyle(.plain)
                }
            }
            Button(LocalizedStringKey("purchase.action.buy")) {
                guard let cycle = plan.cycles.first(where: { $0.period == selected }) else { return }
                let context = CommerceOperationContext(model: model)
                Task { await presentPurchaseOrder(plan: plan, cycle: cycle, context: context) }
            }
                .buttonStyle(BrandButtonStyle())
                .disabled(
                    model.busy
                        || (model.offline && !allowsOfflineDisclosurePurchaseFixture)
                        || plan.cycles.isEmpty
                )
                .accessibilityIdentifier("purchase.plan.\(plan.id).buy")
        }.padding(16).surfaceCard()
    }
    private func presentPurchaseOrder(
        plan: PurchasePlan,
        cycle: PurchasePlanCycle,
        context: CommerceOperationContext
    ) async {
        guard context.isCurrent(in: model),
              await usageTermsConsent.authorize(
                  presenter: modalPresenter
              ),
              context.isCurrent(in: model) else { return }
        let request = PurchaseOrderModalPresentation.request(
            plan: plan,
            cycle: cycle,
            locale: locale
        )
        let choice = await modalPresenter.present(request) { interaction in
            guard case let .validatePurchaseCoupon(code) = interaction else {
                return .cancelled
            }
            guard let outcome = await context.performIfCurrent(in: model, {
                await model.validateCoupon(code: code, planID: plan.id)
            }), context.isCurrent(in: model) else {
                return .cancelled
            }
            switch outcome {
            case let .available(coupon):
                return .couponAvailable(name: coupon.name)
            case let .unavailable(message):
                return .couponUnavailable(message)
            case .cancelled:
                return .cancelled
            }
        }
        guard context.isCurrent(in: model) else { return }
        guard let submission = PurchaseOrderModalPresentation.submission(for: choice) else {
            return
        }
        guard let outcome = await context.performIfCurrent(in: model, {
            await model.createOrder(
                plan: plan,
                cycle: cycle,
                couponCode: submission.couponCode
            )
        }), context.isCurrent(in: model) else { return }
        guard let tradeNo = CommerceOrderCreationNavigation.paymentTradeNo(for: outcome) else {
            return
        }
        await loadAndPresentPayment(
            tradeNo: tradeNo,
            context: context.binding(tradeNo: tradeNo)
        )
    }

    @ViewBuilder
    private var pendingPaymentCard: some View {
        switch displayedPendingPaymentState {
        case .idle:
            EmptyView()
        case let .loading(tradeNo):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey("purchase.payment.pending"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(verbatim: tradeNo)
                        .font(.caption2.monospaced())
                        .foregroundStyle(brand.theme.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(12)
            .surfaceCard()
        case let .ready(detail):
            HStack(spacing: 10) {
                Image(systemName: "creditcard.fill")
                    .foregroundStyle(brand.theme.emphasis)
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey("purchase.payment.pending"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(verbatim: detail.tradeNo)
                        .font(.caption2.monospaced())
                        .foregroundStyle(brand.theme.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    let context = CommerceOperationContext(
                        model: model,
                        tradeNo: detail.tradeNo
                    )
                    Task { await continuePayment(detail: detail, context: context) }
                } label: {
                    Text(LocalizedStringKey("profile.orders.continue_payment"))
                        .commerceInlineActionLabel()
                }
                .font(.system(size: 12, weight: .semibold))
                .disabled(model.busy)
                .accessibilityIdentifier("purchase.pending.continue")
            }
            .padding(12)
            .surfaceCard()
        case let .failed(tradeNo, message):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(brand.theme.error)
                LocalizedMessageText(message: message)
                    .font(.system(size: 12))
                    .foregroundStyle(brand.theme.secondary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button {
                    let context = CommerceOperationContext(model: model, tradeNo: tradeNo)
                    Task { await loadAndPresentPayment(tradeNo: tradeNo, context: context) }
                } label: {
                    Text(LocalizedStringKey("purchase.action.retry"))
                        .commerceInlineActionLabel()
                }
                .font(.system(size: 12, weight: .semibold))
                .disabled(model.busy || paymentPreparationID != nil)
                .accessibilityIdentifier("purchase.pending.retry")
            }
            .padding(12)
            .surfaceCard()
        }
    }

    private func loadAndPresentPayment(
        tradeNo: String,
        context: CommerceOperationContext
    ) async {
        guard paymentPreparationID == nil,
              context.isCurrent(in: model, tradeNo: tradeNo) else { return }
        let operationID = UUID()
        paymentPreparationID = operationID
        pendingPaymentState = .loading(tradeNo: tradeNo)
        defer {
            if paymentPreparationID == operationID { paymentPreparationID = nil }
        }

        let detail: PurchaseOrderDetail
        guard let detailOutcome = await context.performIfCurrent(
            in: model,
            tradeNo: tradeNo,
            { await model.loadOrderDetail(trade: tradeNo) }
        ), context.isCurrent(in: model, tradeNo: tradeNo) else { return }
        switch detailOutcome {
        case let .loaded(loaded):
            detail = loaded
        case let .unavailable(message):
            guard paymentPreparationID == operationID,
                  context.isCurrent(in: model, tradeNo: tradeNo) else { return }
            pendingPaymentState = .failed(tradeNo: tradeNo, message)
            return
        case .cancelled:
            return
        }
        guard detail.tradeNo == tradeNo,
              paymentPreparationID == operationID,
              context.isCurrent(in: model, tradeNo: detail.tradeNo) else { return }
        guard await context.performIfCurrent(
            in: model,
            tradeNo: detail.tradeNo,
            { await model.loadPaymentMethods() }
        ) != nil else { return }
        guard paymentPreparationID == operationID,
              context.isCurrent(in: model, tradeNo: detail.tradeNo) else { return }
        if let failure = model.paymentMethodsLoadState.failureMessage {
            pendingPaymentState = .failed(tradeNo: tradeNo, failure)
            return
        }
        guard !model.paymentMethods.isEmpty else {
            pendingPaymentState = .failed(
                tradeNo: tradeNo,
                .localized("purchase.payment.no_methods")
            )
            return
        }
        pendingPaymentState = .ready(detail)
        await presentPaymentMethods(detail: detail, context: context)
    }

    private func presentPaymentMethods(
        detail: PurchaseOrderDetail,
        context: CommerceOperationContext
    ) async {
        guard context.isCurrent(in: model, tradeNo: detail.tradeNo),
              await usageTermsConsent.authorize(
                  presenter: modalPresenter
              ),
              context.isCurrent(in: model, tradeNo: detail.tradeNo) else { return }
        let request = PaymentMethodModalPresentation.request(
            detail: detail,
            methods: model.paymentMethods,
            locale: locale
        )
        let choice = await modalPresenter.present(request)
        guard context.isCurrent(in: model, tradeNo: detail.tradeNo) else { return }
        guard let methodID = PaymentMethodModalPresentation.selectedMethodID(for: choice) else {
            return
        }
        guard context.isCurrent(in: model, tradeNo: detail.tradeNo),
              let checkout = await model.beginCheckout(
                trade: detail.tradeNo,
                method: methodID
              ),
              context.isCurrent(in: model, tradeNo: detail.tradeNo),
              model.isCurrentCheckout(checkout, tradeNo: detail.tradeNo) else { return }
        if checkout.result.type == 1 {
            let started = await paymentStatusCoordinator.start(
                detail: detail,
                checkout: checkout,
                model: model,
                presenter: modalPresenter,
                locale: locale,
                openURL: { url in
                    openURL(url)
                    return true
                }
            )
            guard context.isCurrent(in: model, tradeNo: detail.tradeNo) else { return }
            if started { pendingPaymentState = .ready(detail) }
        } else {
            guard context.isCurrent(in: model, tradeNo: detail.tradeNo) else { return }
            paymentResultTradeNo = CommerceOrderCreationNavigation.checkoutTradeNo(
                tradeNo: detail.tradeNo,
                checkout: checkout.result
            )
        }
    }

    private var allowsOfflineDisclosurePurchaseFixture: Bool {
        #if DEBUG
        UnifiedConsentUITestFixture.allowsOfflinePurchase
        #else
        false
        #endif
    }

    private func continuePayment(
        detail: PurchaseOrderDetail,
        context: CommerceOperationContext
    ) async {
        guard context.isCurrent(in: model, tradeNo: detail.tradeNo) else { return }
        guard let restored = await context.performIfCurrent(
            in: model,
            tradeNo: detail.tradeNo,
            { await model.restoredPaymentMonitoring() }
        ), context.isCurrent(in: model, tradeNo: detail.tradeNo) else { return }
        if let payment = restored,
           payment.tradeNo == detail.tradeNo {
            await paymentStatusCoordinator.restore(
                detail: detail,
                payment: payment,
                model: model,
                presenter: modalPresenter,
                locale: locale
            )
            return
        }
        guard let detailOutcome = await context.performIfCurrent(
            in: model,
            tradeNo: detail.tradeNo,
            { await model.loadOrderDetail(trade: detail.tradeNo) }
        ), context.isCurrent(in: model, tradeNo: detail.tradeNo) else { return }
        switch detailOutcome {
        case let .loaded(current) where current.status == 0:
            guard current.tradeNo == detail.tradeNo else { return }
            pendingPaymentState = .ready(current)
            await presentPaymentMethods(detail: current, context: context)
        case .loaded:
            pendingPaymentState = .idle
        case let .unavailable(message):
            pendingPaymentState = .failed(tradeNo: detail.tradeNo, message)
        case .cancelled:
            break
        }
    }

    private func restorePaymentStatusIfNeeded(context: CommerceOperationContext) async {
        guard !didAttemptPaymentRestore, context.isCurrent(in: model) else { return }
        didAttemptPaymentRestore = true
        guard let restored = await context.performIfCurrent(
            in: model,
            { await model.restoredPaymentMonitoring() }
        ), context.isCurrent(in: model), let payment = restored else { return }
        let paymentContext = context.binding(tradeNo: payment.tradeNo)
        guard let detailOutcome = await paymentContext.performIfCurrent(
            in: model,
            tradeNo: payment.tradeNo,
            { await model.loadOrderDetail(trade: payment.tradeNo) }
        ), paymentContext.isCurrent(in: model, tradeNo: payment.tradeNo) else { return }
        switch detailOutcome {
        case let .loaded(detail):
            guard detail.tradeNo == payment.tradeNo else { return }
            pendingPaymentState = .ready(detail)
            await paymentStatusCoordinator.restore(
                detail: detail,
                payment: payment,
                model: model,
                presenter: modalPresenter,
                locale: locale
            )
        case let .unavailable(message):
            guard paymentContext.isCurrent(in: model, tradeNo: payment.tradeNo) else { return }
            pendingPaymentState = .failed(tradeNo: payment.tradeNo, message)
        case .cancelled:
            break
        }
    }
    nonisolated static func price(_ cents: Int64, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "CNY"
        formatter.locale = locale
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: Double(cents) / 100)) ?? "--"
    }
}

enum PurchaseOrderStatusTone: Equatable {
    case pending
    case activating
    case completed
    case inactive
}

enum PurchaseOrderPresentation {
    static func statusKey(
        status: Int,
        isExpired: Bool = false
    ) -> String {
        if isExpired { return "profile.orders.status.expired" }
        switch status {
        case 0: return "profile.orders.status.pending"
        case 1: return "profile.orders.status.activating"
        case 2: return "profile.orders.status.cancelled"
        case 3: return "profile.orders.status.completed"
        case 4: return "profile.orders.status.offset"
        default: return "profile.orders.status.unknown"
        }
    }

    static func statusTone(
        status: Int,
        isExpired: Bool = false
    ) -> PurchaseOrderStatusTone {
        if isExpired { return .inactive }
        switch PurchasePaymentStatus(serverValue: status) {
        case .pending: return .pending
        case .activating: return .activating
        case .completed: return .completed
        case .cancelled, .offset, .unknown: return .inactive
        }
    }

    static func timestamp(
        _ unix: Int64?,
        locale: Locale
    ) -> String? {
        guard let unix, unix > 0 else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = locale
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }
}

enum PurchaseOrderCancellationPresentation {
    static func shouldCancel(
        choice: GlobalModalChoice,
        status: PurchasePaymentStatus
    ) -> Bool {
        choice == .primary && PurchaseOrderActionPolicy.canCancel(status: status)
    }
}

enum OrderDetailPaymentAccessPolicy {
    static func canPresent(
        status: PurchasePaymentStatus?,
        order: PurchaseOrderRecord?,
        at date: Date = Date()
    ) -> Bool {
        guard status == .pending else { return false }
        return order?.canContinuePayment(at: date) ?? true
    }

    static func checkoutURL(_ checkout: PurchaseCheckoutResult?) -> URL? {
        guard let data = checkout?.data,
              let url = URL(string: data),
              url.scheme?.lowercased() == "https" else { return nil }
        return url
    }

    @discardableResult
    static func openBrowserCheckoutIfAllowed(
        checkout: PurchaseCheckoutResult?,
        status: PurchasePaymentStatus?,
        order: PurchaseOrderRecord?,
        at date: Date = Date(),
        openURL: (URL) -> Bool
    ) -> Bool {
        guard canPresent(status: status, order: order, at: date),
              let url = checkoutURL(checkout) else { return false }
        return openURL(url)
    }
}

struct OrdersView: View {
    @EnvironmentObject private var brand: BrandProvider
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale

    private var isRefreshingOrders: Bool {
        RetainedContentLoadingPresentation.showsRefreshIndicator(
            isLoading: model.ordersLoadState.isLoading,
            hasContent: !model.orders.isEmpty
        )
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if model.orders.isEmpty,
                   model.ordersLoadState == .idle || model.ordersLoadState.isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(LocalizedStringKey("profile.orders.loading"))
                            .font(.subheadline)
                            .foregroundStyle(brand.theme.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }

                if let failure = model.ordersLoadState.failureMessage {
                    VStack(alignment: .leading, spacing: 10) {
                        LocalizedMessageText(message: failure)
                            .font(.subheadline)
                        Button(LocalizedStringKey("purchase.action.retry")) {
                            Task { await model.loadCommerce() }
                        }
                        .buttonStyle(BrandButtonStyle())
                        .disabled(model.busy)
                    }
                    .foregroundStyle(brand.theme.error)
                    .padding(14)
                    .surfaceCard()
                }

                if model.orders.isEmpty,
                   model.ordersLoadState != .idle,
                   !model.ordersLoadState.isLoading,
                   model.ordersLoadState.failureMessage == nil {
                    ContentUnavailableView(
                        LocalizedStringKey("profile.orders.empty.title"),
                        systemImage: "list.bullet.rectangle"
                    )
                    .padding(.top, 40)
                }

                ForEach(model.orders) { order in
                    NavigationLink {
                        PaymentView(order: order)
                    } label: {
                        orderCard(order)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 18)
        }
        .background(brand.theme.background.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Image(systemName: "list.bullet.clipboard")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(brand.theme.emphasis)
                    Text(LocalizedStringKey("profile.menu.orders"))
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(brand.theme.text)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                RefreshToolbarButton(
                    isRefreshing: isRefreshingOrders,
                    isDisabled: model.busy || model.ordersLoadState.isLoading,
                    labelKey: "profile.orders.refresh",
                    identifier: "profile.orders.refresh"
                ) {
                    Task { await model.loadCommerce() }
                }
            }
        }
        .task { if model.orders.isEmpty && !model.busy { await model.loadCommerce() } }
        .onChange(of: model.busy) { _, isBusy in
            if !isBusy, model.session != nil, model.ordersLoadState == .idle {
                Task { await model.loadCommerce() }
            }
        }
    }

    private func orderCard(_ order: PurchaseOrderRecord) -> some View {
        let expired = order.isExpired()
        let period = PaymentMethodModalPresentation.periodName(
            order.period,
            locale: locale
        )
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Group {
                    if order.planName.isEmpty {
                        Text(LocalizedStringKey("profile.orders.unnamed_plan"))
                    } else {
                        Text(verbatim: order.planName)
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(brand.theme.text)
                .lineLimit(2)
                Spacer(minLength: 8)
                statusBadge(status: order.status, isExpired: expired)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(spacing: 5) {
                    Text(LocalizedStringKey("purchase.payment.period"))
                        .foregroundStyle(brand.theme.secondary)
                    Text(verbatim: period)
                        .foregroundStyle(brand.theme.secondary)
                }
                Spacer(minLength: 8)
                if let amount = order.totalAmountCents {
                    HStack(spacing: 5) {
                        Text(LocalizedStringKey("purchase.payment.order_amount"))
                            .foregroundStyle(brand.theme.text)
                        Text(verbatim: CommerceView.price(amount, locale: locale))
                            .fontWeight(.semibold)
                            .foregroundStyle(brand.theme.text)
                    }
                }
            }
            .font(.caption.weight(.regular))

            if let created = PurchaseOrderPresentation.timestamp(
                order.createdAtUnix,
                locale: locale
            ) {
                HStack(spacing: 5) {
                    Text(LocalizedStringKey("profile.orders.field.created_at"))
                    Text(verbatim: created)
                }
                .font(.caption2.weight(.regular))
                .foregroundStyle(brand.theme.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard()
    }

    private func statusBadge(
        status: Int,
        isExpired: Bool
    ) -> some View {
        let tone = PurchaseOrderPresentation.statusTone(
            status: status,
            isExpired: isExpired
        )
        let color: Color = switch tone {
        case .pending: brand.theme.warning
        case .activating: brand.theme.emphasis
        case .completed: brand.theme.color("success")
        case .inactive: brand.theme.tertiary
        }
        return Text(LocalizedStringKey(PurchaseOrderPresentation.statusKey(
            status: status,
            isExpired: isExpired
        )))
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }
}

struct PaymentView: View {
    private let tradeNo: String
    private let initialOrder: PurchaseOrderRecord?
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var brand: BrandProvider
    @EnvironmentObject private var modalPresenter: GlobalModalPresenter
    @EnvironmentObject private var usageTermsConsent: UsageTermsConsentCoordinator
    @EnvironmentObject private var paymentStatusCoordinator: PaymentStatusCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale
    @Environment(\.openURL) private var openURL
    @State private var detailState = PaymentOrderDetailState.idle
    @State private var preparationID: UUID?
    @State private var cancellationID: UUID?
    @State private var actionFeedback: LocalizedMessage?
    @State private var commerceContext: CommerceOperationContext?

    init(order: PurchaseOrderRecord) {
        tradeNo = order.tradeNo
        initialOrder = order
    }

    init(tradeNo: String) {
        self.tradeNo = tradeNo
        initialOrder = nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if detailState == .loading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(LocalizedStringKey("profile.orders.loading"))
                            .font(.subheadline)
                            .foregroundStyle(brand.theme.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }

                orderDetailCard

                if case let .failed(message) = detailState {
                    VStack(alignment: .leading, spacing: 8) {
                        LocalizedMessageText(message: message)
                        Button(LocalizedStringKey("profile.orders.retry")) {
                            guard let context = commerceContext else { return }
                            Task { await loadOrderContext(context: context) }
                        }
                        .disabled(model.busy || preparationID != nil)
                    }
                    .foregroundStyle(brand.theme.error)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .surfaceCard()
                }

                orderActionArea
                checkoutInformation
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 18)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(brand.theme.background.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Image(systemName: "list.bullet.clipboard")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(brand.theme.emphasis)
                    Text(LocalizedStringKey("profile.orders.details"))
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(brand.theme.text)
                }
            }
        }
        .task {
            let context = commerceContext
                ?? CommerceOperationContext(model: model, tradeNo: tradeNo)
            if commerceContext == nil { commerceContext = context }
            await loadOrderContext(context: context)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && !model.busy,
               !paymentStatusCoordinator.isMonitoring,
               let context = commerceContext {
                Task { await checkOrder(context: context) }
            }
        }
    }

    private var currentOrder: PurchaseOrderRecord? {
        model.orders.first(where: { $0.tradeNo == tradeNo }) ?? initialOrder
    }

    private var currentDetail: PurchaseOrderDetail? {
        guard case let .loaded(detail) = detailState else { return nil }
        return detail
    }

    private var currentStatus: Int? {
        currentDetail?.status ?? currentOrder?.status
    }

    private var paymentStatus: PurchasePaymentStatus? {
        currentStatus.map(PurchasePaymentStatus.init(serverValue:))
    }

    private var canContinuePayment: Bool {
        guard paymentStatus == .pending else { return false }
        return currentOrder?.canContinuePayment() ?? true
    }

    private var currentCheckout: AppModel.OwnedPurchaseCheckout? {
        model.currentCheckout(for: tradeNo)
    }

    private var canPresentPaymentAccess: Bool {
        currentCheckout != nil && OrderDetailPaymentAccessPolicy.canPresent(
            status: paymentStatus,
            order: currentOrder
        )
    }

    @ViewBuilder
    private var orderActionArea: some View {
        if let status = paymentStatus,
           PurchaseOrderActionPolicy.canCancel(status: status) {
            HStack(spacing: 12) {
                Button {
                    guard let context = commerceContext else { return }
                    Task { await confirmCancellation(context: context) }
                } label: {
                    Text(LocalizedStringKey("purchase.payment.cancel_order"))
                        .font(.body.weight(.medium))
                        .foregroundStyle(brand.theme.emphasis)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(brand.theme.tint)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(model.busy || cancellationID != nil)

                if canContinuePayment {
                    Button {
                        guard let context = commerceContext else { return }
                        Task { await continuePayment(context: context) }
                    } label: {
                        Text(LocalizedStringKey("profile.orders.continue_payment"))
                            .font(.body.weight(.semibold))
                            .foregroundStyle(brand.theme.onAccent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(brand.theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.busy || preparationID != nil)
                }
            }
            .opacity(model.busy || cancellationID != nil ? 0.65 : 1)
        } else if let status = paymentStatus,
                  status == .activating || isUnknown(status) {
            Button {
                guard let context = commerceContext else { return }
                Task { await checkOrder(context: context) }
            } label: {
                Text("查询支付状态")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(brand.theme.onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(brand.theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(model.busy)
        }

        if let actionFeedback {
            LocalizedMessageText(message: actionFeedback)
                .font(.footnote)
                .foregroundStyle(brand.theme.error)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private var checkoutInformation: some View {
        if canPresentPaymentAccess, let ownedCheckout = currentCheckout {
            let checkout = ownedCheckout.result
            VStack(alignment: .leading, spacing: 12) {
                Text("支付信息")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(brand.theme.text)
                if OrderDetailPaymentAccessPolicy.checkoutURL(checkout) != nil {
                    Button {
                        guard let context = commerceContext else { return }
                        Task {
                            guard await usageTermsConsent.authorize(
                                presenter: modalPresenter
                            ),
                            context.isCurrent(in: model, tradeNo: tradeNo),
                            model.isCurrentCheckout(
                                ownedCheckout,
                                tradeNo: tradeNo
                            ) else { return }
                            _ = OrderDetailPaymentAccessPolicy.openBrowserCheckoutIfAllowed(
                                checkout: ownedCheckout.result,
                                status: paymentStatus,
                                order: currentOrder,
                                openURL: { url in
                                    openURL(url)
                                    return true
                                }
                            )
                        }
                    } label: {
                        Text("在浏览器中打开支付")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(brand.theme.onAccent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(brand.theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                } else if checkout.type == 0,
                          let data = checkout.data,
                          !data.isEmpty {
                    if let image = qrImage(data) {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 240)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel(Text(LocalizedStringKey("purchase.payment.qr_accessibility")))
                    }
                    Text("请使用对应支付应用扫描二维码，并返回查询订单状态。")
                        .font(.subheadline)
                        .foregroundStyle(brand.theme.secondary)
                } else {
                    Text("此支付响应需要额外适配，请查询订单状态或联系在线客服。")
                        .font(.subheadline)
                        .foregroundStyle(brand.theme.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfaceCard()
        }
    }

    private var orderDetailCard: some View {
        VStack(spacing: 0) {
            detailRow(
                label: "purchase.payment.plan",
                value: planName
            )
            detailDivider
            detailRow(
                label: "purchase.payment.period",
                value: periodName
            )
            if let status = currentStatus {
                detailDivider
                detailLocalizedRow(
                    label: "profile.orders.field.status",
                    value: PurchaseOrderPresentation.statusKey(
                        status: status,
                        isExpired: currentOrder?.isExpired() == true
                    )
                )
            }
            if let amount = planPriceCents {
                detailDivider
                detailRow(
                    label: "purchase.payment.plan_price",
                    value: CommerceView.price(amount, locale: locale)
                )
            }
            deductionRows
            if let amount = orderAmountCents {
                detailDivider
                detailRow(
                    label: "purchase.payment.order_amount",
                    value: CommerceView.price(amount, locale: locale),
                    emphasized: true
                )
            }
            detailDivider
            detailRow(
                label: "profile.orders.field.trade_no",
                value: tradeNo,
                monospaced: true
            )
            if let createdAt {
                detailDivider
                detailRow(
                    label: "profile.orders.field.created_at",
                    value: createdAt
                )
            }
        }
        .padding(.horizontal, 14)
        .surfaceCard()
    }

    private var detailDivider: some View {
        Divider().overlay(brand.theme.border)
    }

    @ViewBuilder
    private var deductionRows: some View {
        if let cents = positiveAmount(currentDetail?.discountAmountCents
            ?? currentOrder?.discountAmountCents) {
            detailDivider
            detailRow(
                label: "purchase.payment.discount",
                value: "−\(CommerceView.price(cents, locale: locale))"
            )
        }
        if let cents = positiveAmount(currentDetail?.surplusAmountCents
            ?? currentOrder?.surplusAmountCents) {
            detailDivider
            detailRow(
                label: "purchase.payment.subscription_credit",
                value: "−\(CommerceView.price(cents, locale: locale))"
            )
        }
        if let cents = positiveAmount(currentDetail?.balanceAmountCents
            ?? currentOrder?.balanceAmountCents) {
            detailDivider
            detailRow(
                label: "purchase.payment.balance_applied",
                value: "−\(CommerceView.price(cents, locale: locale))"
            )
        }
        if let cents = positiveAmount(currentDetail?.refundAmountCents
            ?? currentOrder?.refundAmountCents) {
            detailDivider
            detailRow(
                label: "purchase.payment.balance_refund",
                value: "+\(CommerceView.price(cents, locale: locale))"
            )
        }
        if let cents = positiveAmount(currentDetail?.handlingAmountCents
            ?? currentOrder?.handlingAmountCents) {
            detailDivider
            detailRow(
                label: "purchase.payment.handling_fee",
                value: "+\(CommerceView.price(cents, locale: locale))"
            )
        }
    }

    private var planName: String {
        let value = currentDetail?.planName ?? currentOrder?.planName ?? ""
        return value.isEmpty
            ? AppLocalization.string("profile.orders.unnamed_plan", locale: locale)
            : value
    }

    private var periodName: String {
        let value = currentDetail?.period ?? currentOrder?.period ?? ""
        return PaymentMethodModalPresentation.periodName(value, locale: locale)
    }

    private var planPriceCents: Int64? {
        currentDetail?.planPriceCents ?? currentOrder?.planPriceCents
    }

    private var orderAmountCents: Int64? {
        currentDetail?.totalAmountCents ?? currentOrder?.totalAmountCents
    }

    private var createdAt: String? {
        PurchaseOrderPresentation.timestamp(
            currentOrder?.createdAtUnix,
            locale: locale
        )
    }

    private func detailRow(
        label: String,
        value: String,
        emphasized: Bool = false,
        monospaced: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(LocalizedStringKey(label))
                .foregroundStyle(emphasized ? brand.theme.text : brand.theme.secondary)
            Spacer(minLength: 12)
            Text(verbatim: value)
                .font(monospaced
                    ? .caption.monospaced()
                    : .subheadline.weight(emphasized ? .semibold : .regular))
                .foregroundStyle(emphasized ? brand.theme.emphasis : brand.theme.text)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.subheadline.weight(emphasized ? .semibold : .regular))
        .padding(.vertical, 11)
    }

    private func detailLocalizedRow(
        label: String,
        value: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(LocalizedStringKey(label))
                .foregroundStyle(brand.theme.secondary)
            Spacer(minLength: 12)
            Text(LocalizedStringKey(value))
                .foregroundStyle(brand.theme.text)
        }
        .font(.subheadline.weight(.regular))
        .padding(.vertical, 11)
    }

    private func positiveAmount(_ cents: Int64?) -> Int64? {
        guard let cents, cents > 0 else { return nil }
        return cents
    }

    private func isUnknown(_ status: PurchasePaymentStatus) -> Bool {
        if case .unknown = status { return true }
        return false
    }

    private func loadOrderContext(context: CommerceOperationContext) async {
        guard !model.busy, preparationID == nil,
              context.isCurrent(in: model, tradeNo: tradeNo) else { return }
        let operationID = UUID()
        preparationID = operationID
        defer {
            if preparationID == operationID { preparationID = nil }
        }
        guard let payment = await context.performIfCurrent(
            in: model,
            tradeNo: tradeNo,
            { await model.restoredPaymentMonitoring() }
        ), context.isCurrent(in: model, tradeNo: tradeNo) else { return }
        detailState = .loading
        let detail: PurchaseOrderDetail
        guard let detailOutcome = await context.performIfCurrent(
            in: model,
            tradeNo: tradeNo,
            { await model.loadOrderDetail(trade: tradeNo) }
        ), context.isCurrent(in: model, tradeNo: tradeNo) else { return }
        switch detailOutcome {
        case let .loaded(loaded):
            guard loaded.tradeNo == tradeNo else { return }
            self.detailState = .loaded(loaded)
            self.actionFeedback = nil
            detail = loaded
        case let .unavailable(message):
            guard context.isCurrent(in: model, tradeNo: tradeNo) else { return }
            detailState = .failed(message)
            return
        case .cancelled:
            if context.isCurrent(in: model, tradeNo: tradeNo) { detailState = .idle }
            return
        }
        guard preparationID == operationID,
              context.isCurrent(in: model, tradeNo: detail.tradeNo) else { return }

        let status = PurchasePaymentStatus(serverValue: detail.status)
        let started = PurchasePaymentRecoveryPolicy.shouldRestoreMonitoring(
            payment: payment,
            tradeNo: tradeNo
        )
        switch PurchaseOrderActionPolicy.continuation(
            status: status,
            hasStartedPayment: started
        ) {
        case .monitoring:
            if let payment, started {
                guard context.isCurrent(in: model, tradeNo: detail.tradeNo) else { return }
                await paymentStatusCoordinator.restore(
                    detail: detail,
                    payment: payment,
                    verifiedStatus: status,
                    model: model,
                    presenter: modalPresenter,
                    locale: locale
                )
            } else if status == .activating {
                await startMonitoring(detail: detail, status: status, context: context)
            }
        case .paymentMethods, .none:
            break
        }
    }

    private func continuePayment(context: CommerceOperationContext) async {
        guard context.isCurrent(in: model, tradeNo: tradeNo) else { return }
        guard let detail = currentDetail,
              let status = paymentStatus else {
            await loadOrderContext(context: context)
            return
        }
        guard detail.tradeNo == tradeNo,
              context.isCurrent(in: model, tradeNo: detail.tradeNo) else { return }

        guard let payment = await context.performIfCurrent(
            in: model,
            tradeNo: detail.tradeNo,
            { await model.restoredPaymentMonitoring() }
        ), context.isCurrent(in: model, tradeNo: detail.tradeNo) else { return }
        let started = PurchasePaymentRecoveryPolicy.shouldRestoreMonitoring(
            payment: payment,
            tradeNo: tradeNo
        )
        switch PurchaseOrderActionPolicy.continuation(
            status: status,
            hasStartedPayment: started
        ) {
        case .monitoring:
            if let payment, started {
                guard context.isCurrent(in: model, tradeNo: detail.tradeNo) else { return }
                await paymentStatusCoordinator.restore(
                    detail: detail,
                    payment: payment,
                    verifiedStatus: status,
                    model: model,
                    presenter: modalPresenter,
                    locale: locale
                )
            } else if status == .activating {
                await startMonitoring(detail: detail, status: status, context: context)
            }
        case .paymentMethods:
            guard await context.performIfCurrent(
                in: model,
                tradeNo: detail.tradeNo,
                { await model.loadPaymentMethods() }
            ) != nil,
            context.isCurrent(in: model, tradeNo: detail.tradeNo) else { return }
            if let failure = model.paymentMethodsLoadState.failureMessage {
                actionFeedback = failure
                return
            }
            guard !model.paymentMethods.isEmpty else {
                actionFeedback = .localized("purchase.payment.no_methods")
                return
            }
            await presentPaymentMethods(detail: detail, context: context)
        case .none:
            break
        }
    }

    private func startMonitoring(
        detail: PurchaseOrderDetail,
        status: PurchasePaymentStatus,
        context: CommerceOperationContext
    ) async {
        guard let outcome = await context.performIfCurrent(
            in: model,
            tradeNo: detail.tradeNo,
            { await model.beginPaymentMonitoring(detail: detail) }
        ), context.isCurrent(in: model, tradeNo: detail.tradeNo) else { return }
        switch outcome {
        case let .ready(payment):
            await paymentStatusCoordinator.restore(
                detail: detail,
                payment: payment,
                verifiedStatus: status,
                model: model,
                presenter: modalPresenter,
                locale: locale
            )
        case let .unavailable(message):
            actionFeedback = message
        case .cancelled:
            break
        }
    }

    private func confirmCancellation(context: CommerceOperationContext) async {
        guard paymentStatus == .pending,
              cancellationID == nil,
              (currentDetail?.tradeNo ?? currentOrder?.tradeNo) == tradeNo,
              context.isCurrent(in: model, tradeNo: tradeNo) else { return }
        let choice = await modalPresenter.present(.orderCancellation())
        guard context.isCurrent(in: model, tradeNo: tradeNo),
              (currentDetail?.tradeNo ?? currentOrder?.tradeNo) == tradeNo else { return }
        guard let status = paymentStatus,
              PurchaseOrderCancellationPresentation.shouldCancel(
                choice: choice,
                status: status
              ) else { return }

        let operationID = UUID()
        cancellationID = operationID
        defer {
            if cancellationID == operationID { cancellationID = nil }
        }
        guard let outcome = await context.performIfCurrent(
            in: model,
            tradeNo: tradeNo,
            {
                await model.cancelPendingOrder(
                    trade: tradeNo,
                    status: .pending
                )
            }
        ), context.isCurrent(in: model, tradeNo: tradeNo) else { return }
        switch outcome {
        case .cancelledOrder:
            actionFeedback = nil
            guard await context.performIfCurrent(
                in: model,
                tradeNo: tradeNo,
                { await model.loadCommerce() }
            ) != nil,
            cancellationID == operationID,
            context.isCurrent(in: model, tradeNo: tradeNo) else { return }
            guard let detailOutcome = await context.performIfCurrent(
                in: model,
                tradeNo: tradeNo,
                { await model.loadOrderDetail(trade: tradeNo) }
            ), context.isCurrent(in: model, tradeNo: tradeNo) else { return }
            switch detailOutcome {
            case let .loaded(detail): detailState = .loaded(detail)
            case let .unavailable(message): detailState = .failed(message)
            case .cancelled: break
            }
        case let .unavailable(message):
            actionFeedback = message
        case .cancelled:
            break
        }
    }
    private func presentPaymentMethods(
        detail: PurchaseOrderDetail,
        context: CommerceOperationContext
    ) async {
        guard detail.tradeNo == tradeNo,
              context.isCurrent(in: model, tradeNo: tradeNo),
              await usageTermsConsent.authorize(
                  presenter: modalPresenter
              ),
              detail.tradeNo == tradeNo,
              context.isCurrent(in: model, tradeNo: tradeNo) else { return }
        let request = PaymentMethodModalPresentation.request(
            detail: detail,
            methods: model.paymentMethods,
            locale: locale
        )
        let choice = await modalPresenter.present(request)
        guard context.isCurrent(in: model, tradeNo: tradeNo),
              currentDetail?.tradeNo == tradeNo else { return }
        guard let methodID = PaymentMethodModalPresentation.selectedMethodID(for: choice) else {
            return
        }
        guard context.isCurrent(in: model, tradeNo: tradeNo),
              let checkout = await model.beginCheckout(
                trade: tradeNo,
                method: methodID
              ),
              context.isCurrent(in: model, tradeNo: tradeNo),
              model.isCurrentCheckout(checkout, tradeNo: tradeNo),
              checkout.result.type == 1 else { return }
        _ = await paymentStatusCoordinator.start(
            detail: detail,
            checkout: checkout,
            model: model,
            presenter: modalPresenter,
            locale: locale,
            openURL: { url in
                openURL(url)
                return true
            }
        )
    }

    private func checkOrder(context: CommerceOperationContext) async {
        guard await context.performIfCurrent(
            in: model,
            tradeNo: tradeNo,
            { await model.checkOrder(tradeNo) }
        ) != nil else { return }
    }
    private func qrImage(_ value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(value.utf8)
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 6, y: 6)), from: output.extent.applying(CGAffineTransform(scaleX: 6, y: 6))) else { return nil }
        return UIImage(cgImage: image)
    }
}
