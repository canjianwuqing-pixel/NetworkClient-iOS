import Foundation

struct PurchaseCoupon: Sendable, Equatable {
    let id: Int?
    let name: String
}

enum PurchaseCouponValidationOutcome: Sendable, Equatable {
    case available(PurchaseCoupon)
    case unavailable(LocalizedMessage)
    case cancelled
}

enum PurchaseOrderCreationOutcome: Sendable, Equatable {
    case created(tradeNo: String)
    case unknownResult
    case unavailable(LocalizedMessage)
    case cancelled
}

enum PurchaseOrderDetailLoadOutcome: Sendable, Equatable {
    case loaded(PurchaseOrderDetail)
    case unavailable(LocalizedMessage)
    case cancelled
}

struct PurchaseOrderDetail: Sendable, Equatable {
    let tradeNo: String
    let status: Int
    let checkoutType: Int?
    let planID: Int
    let planName: String
    let period: String
    let planPriceCents: Int64
    let totalAmountCents: Int64
    let discountAmountCents: Int64
    let surplusAmountCents: Int64
    let balanceAmountCents: Int64
    let refundAmountCents: Int64
    let handlingAmountCents: Int64

    var amountDueCents: Int64 {
        let result = totalAmountCents.addingReportingOverflow(handlingAmountCents)
        return result.overflow ? Int64.max : max(0, result.partialValue)
    }
}

struct PurchaseOrderRecord: Identifiable, Sendable, Equatable {
    let tradeNo: String
    var status: Int
    let planID: Int
    let planName: String
    let period: String
    let planPriceCents: Int64?
    let totalAmountCents: Int64?
    let discountAmountCents: Int64?
    let surplusAmountCents: Int64?
    let balanceAmountCents: Int64?
    let refundAmountCents: Int64?
    let handlingAmountCents: Int64?
    let paymentMethodName: String?
    let createdAtUnix: Int64?
    let paidAtUnix: Int64?
    let expiresAtUnix: Int64?

    var id: String { tradeNo }

    var isPending: Bool { status == 0 }

    func isExpired(at date: Date = Date()) -> Bool {
        guard isPending, let expiresAtUnix, expiresAtUnix > 0 else { return false }
        return expiresAtUnix <= Int64(date.timeIntervalSince1970)
    }

    func canContinuePayment(at date: Date = Date()) -> Bool {
        isPending && !isExpired(at: date)
    }

    var canCancel: Bool { isPending }
}

struct PurchasePaymentMethod: Identifiable, Sendable, Equatable {
    let id: Int
    let name: String
    let payment: String
    let iconURL: URL?
    let handlingFeeFixedCents: Int64
    let handlingFeePercent: Double

    var isStripeCredit: Bool {
        payment.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "") == "stripecredit"
    }

    var isSupportedByCurrentClient: Bool { !isStripeCredit }

    /// Mirrors V2Board's checkout calculation for non-negative cent amounts:
    /// round(total * percent / 100 + fixed).
    func handlingAmountCents(for orderAmountCents: Int64) -> Int64? {
        guard orderAmountCents >= 0,
              handlingFeeFixedCents >= 0,
              handlingFeePercent.isFinite,
              handlingFeePercent >= 0 else { return nil }

        var raw = Decimal(orderAmountCents)
            * Decimal(handlingFeePercent) / Decimal(100)
            + Decimal(handlingFeeFixedCents)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &raw, 0, .plain)
        guard rounded >= 0, rounded <= Decimal(Int64.max) else { return nil }
        return NSDecimalNumber(decimal: rounded).int64Value
    }
}

struct PurchaseCheckoutResult: Sendable, Equatable {
    let type: Int
    let data: String?
}

struct PurchasePendingPayment: Codable, Identifiable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case tradeNo
        case accountIdentifier
        case planID
        case period
        case createdAt
        case paymentStartedAt
    }

    let tradeNo: String
    let accountIdentifier: String
    let planID: Int
    let period: String
    let createdAt: Date
    let paymentStartedAt: Date?

    var id: String { tradeNo }

    init(
        tradeNo: String,
        accountIdentifier: String,
        planID: Int,
        period: String,
        createdAt: Date,
        paymentStartedAt: Date?
    ) {
        self.tradeNo = tradeNo
        self.accountIdentifier = accountIdentifier
        self.planID = planID
        self.period = period
        self.createdAt = createdAt
        self.paymentStartedAt = paymentStartedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tradeNo = try container.decode(String.self, forKey: .tradeNo)
        accountIdentifier = try container.decode(String.self, forKey: .accountIdentifier)
        planID = try container.decode(Int.self, forKey: .planID)
        period = try container.decode(String.self, forKey: .period)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        paymentStartedAt = try container.decodeIfPresent(Date.self, forKey: .paymentStartedAt)
    }
}

enum PurchasePaymentStatus: Sendable, Equatable {
    case pending
    case activating
    case cancelled
    case completed
    case offset
    case unknown(Int)

    init(serverValue: Int) {
        switch serverValue {
        case 0: self = .pending
        case 1: self = .activating
        case 2: self = .cancelled
        case 3: self = .completed
        case 4: self = .offset
        default: self = .unknown(serverValue)
        }
    }

    var isTerminal: Bool {
        switch self {
        case .cancelled, .completed, .offset: true
        case .pending, .activating, .unknown: false
        }
    }
}

enum PurchasePaymentStatusCheckOutcome: Sendable, Equatable {
    case status(PurchasePaymentStatus)
    case unavailable(LocalizedMessage)
    case cancelled
}

enum PurchasePaymentMonitoringStartOutcome: Sendable, Equatable {
    case ready(PurchasePendingPayment)
    case unavailable(LocalizedMessage)
    case cancelled
}

enum PurchasePaymentRecoveryPolicy {
    static func shouldRestoreMonitoring(
        payment: PurchasePendingPayment?,
        tradeNo: String
    ) -> Bool {
        payment?.tradeNo == tradeNo && payment?.paymentStartedAt != nil
    }
}

enum PurchaseOrderContinuation: Equatable, Sendable {
    case none
    case paymentMethods
    case monitoring
}

enum PurchaseOrderActionPolicy {
    static func continuation(
        status: PurchasePaymentStatus,
        hasStartedPayment: Bool
    ) -> PurchaseOrderContinuation {
        switch status {
        case .pending:
            hasStartedPayment ? .monitoring : .paymentMethods
        case .activating:
            .monitoring
        case .cancelled, .completed, .offset, .unknown:
            .none
        }
    }

    static func canCancel(status: PurchasePaymentStatus) -> Bool {
        status == .pending
    }
}

enum PurchaseOrderCancellationOutcome: Sendable, Equatable {
    case cancelledOrder
    case unavailable(LocalizedMessage)
    case cancelled
}

enum PaymentStatusPollingPolicy {
    static let deadline: TimeInterval = 10 * 60

    static func delaySeconds(
        startedAt: Date,
        now: Date = Date()
    ) -> TimeInterval? {
        let elapsed = max(0, now.timeIntervalSince(startedAt))
        let remaining = deadline - elapsed
        guard remaining > 0 else { return nil }

        let interval: TimeInterval
        switch elapsed {
        case ..<60: interval = 3
        case ..<(5 * 60): interval = 5
        default: interval = 10
        }
        return min(interval, remaining)
    }
}

enum PurchaseCommerceError: Error, Sendable, Equatable {
    case invalidResponse
    case orderCreationResultUnknown
    case checkoutResultUnknown
    case cancellationResultUnknown
}

/// Written before submission. A crash/cancellation cannot turn an unconfirmed
/// write back into permission to send it again. No credentials are persisted.
struct PurchaseWriteIntent: Codable, Sendable, Equatable {
    enum Operation: String, Codable, Sendable { case create, checkout }
    let id: UUID
    let accountIdentifier: String
    let operation: Operation
    let tradeNo: String?
    let planID: Int?
    let period: String?
    let priceCents: Int64?
    let baselineTradeNos: Set<String>
    let startedAt: Date
    var submissionEndedAt: Date?
    var adoptedTradeNo: String?
    var resolvedStatus: Int?

    /// Existing unpaid orders can satisfy this purchase, but order/fetch cannot
    /// prove causal attribution or "not created". Missing fields fail closed.
    func matchingOrder(in orders: [PurchaseOrderRecord]) -> PurchaseOrderRecord? {
        guard operation == .create else { return nil }
        if let adoptedTradeNo { return orders.first { $0.tradeNo == adoptedTradeNo } }
        // A crash before observing submission completion has no trustworthy
        // end of the matching window. Keep that operation unknown.
        guard let submissionEndedAt else { return nil }
        let lower = startedAt.timeIntervalSince1970.rounded(.down)
        let upper = submissionEndedAt.timeIntervalSince1970.rounded(.up)
        guard lower.isFinite, upper.isFinite, lower >= 0, upper >= lower,
              upper < Double(Int64.max) else { return nil }
        let start = Int64(lower)
        let end = Int64(upper)
        let candidates = orders.filter {
            !baselineTradeNos.contains($0.tradeNo)
                && ($0.planID == planID || $0.planID == 0)
                && ($0.period == period || $0.period.isEmpty)
                && ($0.createdAtUnix.map { $0 >= start && $0 <= end } ?? true)
        }
        guard candidates.count == 1, let order = candidates.first,
              let priceCents, priceCents >= 0,
              order.planID == planID, order.period == period,
              order.createdAtUnix != nil, order.canContinuePayment(),
              order.planPriceCents == priceCents, order.totalAmountCents == priceCents,
              order.discountAmountCents == 0, order.surplusAmountCents == 0,
              order.balanceAmountCents == 0, order.refundAmountCents == 0,
              order.handlingAmountCents == 0,
              order.paidAtUnix == nil || order.paidAtUnix == 0 else { return nil }
        return order
    }
}

struct PurchaseSheetPresentation: Identifiable, Sendable {
    let plan: PurchasePlan?
    let cycle: PurchasePlanCycle?
    let pendingPayment: PurchasePendingPayment?

    var id: String {
        pendingPayment?.tradeNo ?? "new-\(plan?.id ?? 0)-\(cycle?.period.rawValue ?? "")"
    }

    static func new(plan: PurchasePlan, cycle: PurchasePlanCycle) -> PurchaseSheetPresentation {
        PurchaseSheetPresentation(
            plan: plan,
            cycle: cycle,
            pendingPayment: nil
        )
    }

    static func restored(_ payment: PurchasePendingPayment) -> PurchaseSheetPresentation {
        PurchaseSheetPresentation(
            plan: nil,
            cycle: nil,
            pendingPayment: payment
        )
    }
}
