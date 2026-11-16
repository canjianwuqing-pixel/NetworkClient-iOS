import Foundation

struct UserSession: Codable, Sendable, Equatable {
    let email: String
    let authData: String
    let accountToken: String?
    let subscriptionURL: String
    let uploadBytes: Int64
    let downloadBytes: Int64
    let transferEnableBytes: Int64
    let expiredAt: Int64
    let planID: Int?
    let planName: String
    let balanceCents: Int64?
    let verifiedAt: Date

    func applyingUserInfo(email: String?, balanceCents: Int64?) -> UserSession {
        UserSession(
            email: email?.trimmed.nilIfEmpty ?? self.email,
            authData: authData,
            accountToken: accountToken,
            subscriptionURL: subscriptionURL,
            uploadBytes: uploadBytes,
            downloadBytes: downloadBytes,
            transferEnableBytes: transferEnableBytes,
            expiredAt: expiredAt,
            planID: planID,
            planName: planName,
            balanceCents: balanceCents,
            verifiedAt: Date()
        )
    }
}
