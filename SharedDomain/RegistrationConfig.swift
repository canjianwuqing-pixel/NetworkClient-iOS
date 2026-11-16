
struct V2BoardRegistrationConfig: Sendable, Equatable {
    let requiresEmailVerification: Bool
    let requiresInvitation: Bool
    let requiresRecaptcha: Bool
    let emailWhitelistEnabled: Bool
    let emailWhitelistSuffixes: [String]
    let termsOfServiceURL: URL?

    init(
        requiresEmailVerification: Bool,
        requiresInvitation: Bool,
        requiresRecaptcha: Bool,
        emailWhitelistEnabled: Bool,
        emailWhitelistSuffixes: [String],
        termsOfServiceURL: URL? = nil
    ) {
        self.requiresEmailVerification = requiresEmailVerification
        self.requiresInvitation = requiresInvitation
        self.requiresRecaptcha = requiresRecaptcha
        self.emailWhitelistEnabled = emailWhitelistEnabled
        self.emailWhitelistSuffixes = emailWhitelistSuffixes
        self.termsOfServiceURL = termsOfServiceURL
    }

    static let clientFallback = V2BoardRegistrationConfig(
        requiresEmailVerification: true,
        requiresInvitation: false,
        requiresRecaptcha: false,
        emailWhitelistEnabled: false,
        emailWhitelistSuffixes: []
    )

    var usesEmailSuffixSelector: Bool {
        emailWhitelistEnabled && !emailWhitelistSuffixes.isEmpty
    }
}
