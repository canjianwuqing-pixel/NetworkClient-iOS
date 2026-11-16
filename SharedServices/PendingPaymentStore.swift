import CryptoKit
import Foundation

actor PendingPaymentStore {
    private let defaults: UserDefaults
    private let storageKey = "purchase.pending-payment.v1"

    /// Same preference key; legacy single-payment JSON remains readable. Small
    /// owner-scoped maps prevent B's payment from erasing A's uncertain write.
    private struct Snapshot: Codable {
        var version = 2
        var payments: [String: PurchasePendingPayment] = [:]
        var writes: [PurchaseWriteIntent] = []
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func save(_ payment: PurchasePendingPayment) throws {
        var snapshot = try read()
        snapshot.payments[payment.accountIdentifier] = payment
        try write(snapshot)
    }

    func payment(for session: UserSession) -> PurchasePendingPayment? {
        let accountIdentifier = Self.accountIdentifier(for: session)
        guard let snapshot = try? read(),
              let payment = snapshot.payments[accountIdentifier],
              payment.accountIdentifier == accountIdentifier else {
            return nil
        }
        return payment
    }

    func clear(tradeNo: String, for session: UserSession) throws {
        var snapshot = try read()
        let owner = Self.accountIdentifier(for: session)
        guard snapshot.payments[owner]?.tradeNo == tradeNo else { return }
        snapshot.payments.removeValue(forKey: owner)
        try write(snapshot)
    }

    /// Order creation is now decided by V2Board on every completed user tap.
    /// Remove only legacy create reservations; checkout write safety remains.
    func clearCreationIntents(for session: UserSession) throws {
        var snapshot = try read()
        let owner = Self.accountIdentifier(for: session)
        let previousCount = snapshot.writes.count
        snapshot.writes.removeAll {
            $0.accountIdentifier == owner && $0.operation == .create
        }
        guard snapshot.writes.count != previousCount else { return }
        try write(snapshot)
    }

    func intent(for session: UserSession, operation: PurchaseWriteIntent.Operation,
                tradeNo: String? = nil) throws -> PurchaseWriteIntent? {
        try read().writes.first {
            $0.accountIdentifier == Self.accountIdentifier(for: session)
                && $0.operation == operation && $0.tradeNo == tradeNo
        }
    }

    /// Atomic reservation also protects two callers sharing this store.
    func reserve(_ intent: PurchaseWriteIntent) throws -> PurchaseWriteIntent {
        var snapshot = try read()
        if let existing = snapshot.writes.first(where: {
            $0.accountIdentifier == intent.accountIdentifier
                && $0.operation == intent.operation && $0.tradeNo == intent.tradeNo
        }) { return existing }
        snapshot.writes.append(intent)
        try write(snapshot)
        return intent
    }

    func finish(_ intent: PurchaseWriteIntent, payment: PurchasePendingPayment? = nil,
                retainingIntent: Bool) throws {
        var snapshot = try read()
        guard let index = snapshot.writes.firstIndex(where: { $0.id == intent.id }) else { return }
        if retainingIntent { snapshot.writes[index] = intent }
        else { snapshot.writes.remove(at: index) }
        if let payment, payment.accountIdentifier == intent.accountIdentifier {
            snapshot.payments[payment.accountIdentifier] = payment
        }
        try write(snapshot)
    }

    private func read() throws -> Snapshot {
        guard let data = defaults.data(forKey: storageKey) else { return Snapshot() }
        if let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data), snapshot.version == 2 {
            return snapshot
        }
        if let legacy = try? JSONDecoder().decode(PurchasePendingPayment.self, from: data) {
            return Snapshot(payments: [legacy.accountIdentifier: legacy])
        }
        // Damaged/unsupported persistence must never silently remove the gate.
        throw PurchaseCommerceError.invalidResponse
    }

    private func write(_ snapshot: Snapshot) throws {
        defaults.set(try JSONEncoder().encode(snapshot), forKey: storageKey)
        guard defaults.synchronize() else { throw PurchaseCommerceError.invalidResponse }
    }

    nonisolated static func accountIdentifier(for session: UserSession) -> String {
        let normalized = session.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

}
