import Foundation

enum AuthValidation {
    static func validate(email: String, password: String, confirmation: String? = nil,
                         registration: V2BoardRegistrationConfig? = nil, emailCode: String = "", inviteCode: String = "") throws {
        let value = email.trimmed
        guard value.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil else {
            throw NetworkClientError.validation(L10nKey.registerValidationEmailInvalid)
        }
        guard !password.isEmpty else { throw NetworkClientError.validation(L10nKey.registerValidationPasswordRequired) }
        if let confirmation, confirmation != password { throw NetworkClientError.validation(L10nKey.registerValidationPasswordMismatch) }
        if let registration {
            guard !registration.requiresRecaptcha else { throw NetworkClientError.validation(L10nKey.registerStatusRecaptchaUnsupported) }
            if registration.requiresEmailVerification && emailCode.trimmed.isEmpty { throw NetworkClientError.validation(L10nKey.registerValidationEmailCodeRequired) }
            if registration.requiresInvitation && inviteCode.trimmed.isEmpty { throw NetworkClientError.validation(L10nKey.registerValidationInviteRequired) }
            if registration.emailWhitelistEnabled {
                let suffix = value.components(separatedBy: "@").last?.lowercased() ?? ""
                guard registration.emailWhitelistSuffixes.contains(where: { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@")) == suffix }) else {
                    throw NetworkClientError.validation(L10nKey.registerValidationEmailSuffixNotAllowed)
                }
            }
        }
    }

    static func validatePasswordReset(
        email: String,
        password: String,
        confirmation: String
    ) throws {
        let value = email.trimmed
        guard value.range(
            of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#,
            options: .regularExpression
        ) != nil else {
            throw NetworkClientError.validation(L10nKey.forgotValidationEmailInvalid)
        }
        guard !password.isEmpty else {
            throw NetworkClientError.validation(L10nKey.forgotValidationNewPasswordRequired)
        }
        guard !confirmation.isEmpty else {
            throw NetworkClientError.validation(L10nKey.forgotValidationConfirmPasswordRequired)
        }
        guard password == confirmation else {
            throw NetworkClientError.validation(L10nKey.forgotValidationPasswordMismatch)
        }
    }
}
