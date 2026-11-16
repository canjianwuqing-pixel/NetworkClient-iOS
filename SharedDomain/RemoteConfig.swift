import Foundation

struct BootstrapConfig: Decodable, Sendable {
    let cloudConfig: [String]
    let cloudUpdateHours: Int

    enum CodingKeys: String, CodingKey {
        case cloudConfig = "CloudConfig"
        case cloudUpdateHours = "CloudUpdateHours"
    }

    init(cloudConfig: [String], cloudUpdateHours: Int) {
        self.cloudConfig = cloudConfig
        self.cloudUpdateHours = max(1, cloudUpdateHours)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cloudConfig = try container.decodeIfPresent([String].self, forKey: .cloudConfig) ?? []
        cloudUpdateHours = max(
            1,
            try container.decodeIfPresent(Int.self, forKey: .cloudUpdateHours) ?? 3
        )
    }
}

struct AppConfig: Codable, Sendable, Equatable {
    static let defaultLatencyDisplayRatio = 1.0

    let appName: String
    let loginTitle: String?
    let appLogo: String?
    let homePage: String?
    let privacyPolicyURL: String?
    let telegramGroup: String?
    let supportAPI: String?
    var customerService: CustomerServiceState
    let updateURL: String?
    let userAgent: String
    let latencyDisplayRatio: Double
    let inviteLink: String?
    let apiBaseURLs: [String]
    let activeAPIBaseURL: String?
    let builtInProxy: [String]
    let mihomoDns: String?

    enum CodingKeys: String, CodingKey {
        case appName = "AppName"
        case loginTitle = "LoginTitle"
        case appLogo = "AppLogo"
        case homePage = "HomePage"
        case privacyPolicyURL = "PrivacyPolicyURL"
        case telegramGroup = "TelegramGroup"
        case supportAPI = "SupportApi"
        case customerService = "CustomerService"
        case updateURL = "UpdateUrl"
        case userAgent = "UserAgent"
        case latencyDisplayRatio = "LatencyDisplayRatio"
        case inviteLink = "InviteLink"
        case apiBaseURLs = "ApiBaseUrls"
        case activeAPIBaseURL = "ActiveApiBaseUrl"
        case builtInProxy = "BuiltInProxy"
        case mihomoDns = "MihomoDns"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appName = try container.decodeIfPresent(String.self, forKey: .appName) ?? ""
        loginTitle = try container.decodeIfPresent(String.self, forKey: .loginTitle)
        appLogo = try? container.decodeIfPresent(String.self, forKey: .appLogo)
        homePage = try container.decodeIfPresent(String.self, forKey: .homePage)
        privacyPolicyURL = try? container.decodeIfPresent(String.self, forKey: .privacyPolicyURL)
        telegramGroup = try container.decodeIfPresent(String.self, forKey: .telegramGroup)
        supportAPI = try container.decodeIfPresent(String.self, forKey: .supportAPI)
        if !container.contains(.customerService) {
            customerService = .absent
        } else {
            do {
                let fields = try container.nestedContainer(keyedBy: CustomerServiceKeys.self, forKey: .customerService)
                let enabled = try fields.decode(Bool.self, forKey: .enabled)
                if !enabled {
                    customerService = .disabled
                } else {
                    let mode = try fields.decode(CustomerServiceConfig.Mode.self, forKey: .mode)
                    let content = try fields.decode(String.self, forKey: .content)
                    if content.trimmed.isEmpty || (mode == .url && CustomerServiceResolver.httpsURL(content) == nil) {
                        customerService = .invalid
                    } else {
                        customerService = .valid(CustomerServiceConfig(enabled: true, mode: mode, content: content))
                    }
                }
            } catch {
                customerService = .invalid
            }
        }
        updateURL = try container.decodeIfPresent(String.self, forKey: .updateURL)
        userAgent = try container.decodeIfPresent(String.self, forKey: .userAgent) ?? ""
        inviteLink = try container.decodeIfPresent(String.self, forKey: .inviteLink)
        apiBaseURLs = try container.decodeIfPresent([String].self, forKey: .apiBaseURLs) ?? []
        activeAPIBaseURL = try container.decodeIfPresent(String.self, forKey: .activeAPIBaseURL)
        builtInProxy = try container.decodeIfPresent([String].self, forKey: .builtInProxy) ?? []
        let decodedMihomoDns: String?
        do {
            decodedMihomoDns = try container.decodeIfPresent(String.self, forKey: .mihomoDns)
        } catch {
            decodedMihomoDns = nil
        }
        mihomoDns = Self.normalizeMihomoDns(decodedMihomoDns)

        if let numericRatio = try? container.decode(Double.self, forKey: .latencyDisplayRatio) {
            latencyDisplayRatio = numericRatio
        } else {
            latencyDisplayRatio = Self.defaultLatencyDisplayRatio
        }
    }

    init(
        appName: String,
        loginTitle: String?,
        appLogo: String?,
        homePage: String?,
        privacyPolicyURL: String? = nil,
        telegramGroup: String?,
        supportAPI: String?,
        updateURL: String?,
        userAgent: String,
        latencyDisplayRatio: Double,
        inviteLink: String?,
        apiBaseURLs: [String],
        activeAPIBaseURL: String?,
        builtInProxy: [String],
        mihomoDns: String? = nil,
        customerService: CustomerServiceState = .absent
    ) {
        self.appName = appName
        self.loginTitle = loginTitle
        self.appLogo = appLogo
        self.homePage = homePage
        self.privacyPolicyURL = privacyPolicyURL
        self.telegramGroup = telegramGroup
        self.supportAPI = supportAPI
        self.customerService = customerService
        self.updateURL = updateURL
        self.userAgent = userAgent
        self.latencyDisplayRatio = latencyDisplayRatio
        self.inviteLink = inviteLink
        self.apiBaseURLs = apiBaseURLs
        self.activeAPIBaseURL = activeAPIBaseURL
        self.builtInProxy = builtInProxy
        self.mihomoDns = Self.normalizeMihomoDns(mihomoDns)
    }

    private enum CustomerServiceKeys: String, CodingKey { case enabled, mode, content }

    var effectiveCustomerService: EffectiveCustomerService {
        CustomerServiceResolver.resolve(self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(appName, forKey: .appName)
        try container.encodeIfPresent(loginTitle, forKey: .loginTitle)
        try container.encodeIfPresent(appLogo, forKey: .appLogo)
        try container.encodeIfPresent(homePage, forKey: .homePage)
        try container.encodeIfPresent(privacyPolicyURL, forKey: .privacyPolicyURL)
        try container.encodeIfPresent(telegramGroup, forKey: .telegramGroup)
        try container.encodeIfPresent(supportAPI, forKey: .supportAPI)
        try container.encodeIfPresent(updateURL, forKey: .updateURL)
        try container.encode(userAgent, forKey: .userAgent)
        try container.encode(latencyDisplayRatio, forKey: .latencyDisplayRatio)
        try container.encodeIfPresent(inviteLink, forKey: .inviteLink)
        try container.encode(apiBaseURLs, forKey: .apiBaseURLs)
        try container.encodeIfPresent(activeAPIBaseURL, forKey: .activeAPIBaseURL)
        try container.encode(builtInProxy, forKey: .builtInProxy)
        try container.encodeIfPresent(mihomoDns, forKey: .mihomoDns)
        switch customerService {
        case .absent: break
        case .invalid: try container.encodeNil(forKey: .customerService)
        case .disabled:
            var fields = container.nestedContainer(keyedBy: CustomerServiceKeys.self, forKey: .customerService)
            try fields.encode(false, forKey: .enabled)
        case let .valid(value): try container.encode(value, forKey: .customerService)
        }
    }

    var displayAppName: String {
        appName.trimmed
    }

    var displayLoginTitle: String {
        loginTitle?.trimmed ?? ""
    }

    var appLogoURL: URL? {
        Self.optionalHTTPURL(appLogo)
    }

    var homePageURL: URL? {
        Self.optionalHTTPURL(homePage)
    }

    var safeUserAgent: String {
        Self.sanitizeUserAgent(userAgent) ?? ""
    }

    func validatedForRuntime() throws -> AppConfig {
        guard let normalizedAppName = appName.trimmed.nilIfEmpty else {
            throw NetworkClientError.configInvalid("远程配置缺少 AppName")
        }
        guard let normalizedUserAgent = Self.sanitizeUserAgent(userAgent) else {
            throw NetworkClientError.configInvalid("远程配置缺少 UserAgent")
        }

        let normalizedAPIURLs = Self.normalizeAPIBaseURLs(apiBaseURLs)
        guard !normalizedAPIURLs.isEmpty else {
            throw NetworkClientError.configInvalid("远程配置缺少有效的 ApiBaseUrls")
        }

        try Self.validateOptionalHTTPURL(homePage, field: "HomePage")
        try Self.validateOptionalHTTPURL(telegramGroup, field: "TelegramGroup")
        try Self.validateOptionalHTTPURL(updateURL, field: "UpdateUrl")
        try Self.validateOptionalHTTPURL(inviteLink, field: "InviteLink")

        let ratio = latencyDisplayRatio.isFinite && latencyDisplayRatio > 0
            ? latencyDisplayRatio
            : Self.defaultLatencyDisplayRatio

        return AppConfig(
            appName: normalizedAppName,
            loginTitle: loginTitle?.trimmed.nilIfEmpty,
            appLogo: Self.optionalHTTPURL(appLogo)?.absoluteString,
            homePage: homePage?.trimmed.nilIfEmpty,
            privacyPolicyURL: privacyPolicyURL?.trimmed.nilIfEmpty,
            telegramGroup: telegramGroup?.trimmed.nilIfEmpty,
            supportAPI: supportAPI?.trimmed.nilIfEmpty,
            updateURL: updateURL?.trimmed.nilIfEmpty,
            userAgent: normalizedUserAgent,
            latencyDisplayRatio: ratio,
            inviteLink: inviteLink?.trimmed.nilIfEmpty,
            apiBaseURLs: normalizedAPIURLs,
            activeAPIBaseURL: Self.normalizeAPIBaseURL(activeAPIBaseURL),
            builtInProxy: Self.uniqueTrimmedValues(builtInProxy),
            mihomoDns: mihomoDns,
            customerService: customerService
        )
    }

    static func orderedAPIBaseURLs(from config: AppConfig) -> [String] {
        let hosts = normalizeAPIBaseURLs(config.apiBaseURLs)
        let preferredHost = normalizeAPIBaseURL(config.activeAPIBaseURL)
        guard let preferredHost,
              hosts.contains(where: { $0.caseInsensitiveCompare(preferredHost) == .orderedSame }) else {
            return hosts
        }
        return [preferredHost] + hosts.filter {
            $0.caseInsensitiveCompare(preferredHost) != .orderedSame
        }
    }

    static func apiURL(baseURL: String, relativePath: String) throws -> URL {
        guard let normalizedBaseURL = normalizeAPIBaseURL(baseURL) else {
            throw NetworkClientError.configInvalid("API 地址无效")
        }
        let apiRoot = normalizedBaseURL.lowercased().hasSuffix(NetworkEndpoints.apiRoot)
            ? normalizedBaseURL
            : normalizedBaseURL + NetworkEndpoints.apiRoot
        let path = relativePath.hasPrefix("/") ? relativePath : "/" + relativePath
        guard let url = URL(string: apiRoot + path) else {
            throw NetworkClientError.configInvalid("API 地址无效")
        }
        return url
    }

    private static func normalizeAPIBaseURLs(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            guard let normalized = normalizeAPIBaseURL(value) else { return nil }
            let key = normalized.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return normalized
        }
    }

    private static func normalizeAPIBaseURL(_ value: String?) -> String? {
        guard let text = value?.trimmed.nilIfEmpty,
              text.unicodeScalars.allSatisfy({ $0.isASCII }),
              !containsPlaceholderText(text),
              let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              !host.isEmpty else {
            return nil
        }

        let isLocal = host == "localhost" || host.contains(":") || isIPv4(host)
        guard scheme == "https" || (scheme == "http" && isLocal) else { return nil }
        if !isLocal {
            guard host.contains("."),
                  !host.split(separator: ".").contains(where: { $0.lowercased().hasPrefix("xn--") }),
                  host.split(separator: ".").allSatisfy({ label in
                      guard !label.isEmpty, label.count <= 63,
                            label.first != "-", label.last != "-" else { return false }
                      return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
                  }) else {
                return nil
            }
        }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func validateOptionalHTTPURL(_ value: String?, field: String) throws {
        guard value?.trimmed.nilIfEmpty != nil else { return }
        guard optionalHTTPURL(value) != nil else {
            throw NetworkClientError.configInvalid("\(field) 地址无效")
        }
    }

    private static func optionalHTTPURL(_ value: String?) -> URL? {
        guard let text = value?.trimmed.nilIfEmpty,
              text.count <= 2_048,
              text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }),
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    private static func sanitizeUserAgent(_ value: String?) -> String? {
        guard let text = value?.trimmed.nilIfEmpty,
              text.count <= 128,
              text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else {
            return nil
        }

        let unsafeWords = [
            "authorization", "bearer", "token", "password", "passwd", "uuid",
            "user_id", "userid", "account", "email", "android_id", "serial"
        ]
        guard !unsafeWords.contains(where: { text.localizedCaseInsensitiveContains($0) }),
              !text.contains("@") else {
            return nil
        }
        return text
    }

    private static func normalizeMihomoDns(_ value: String?) -> String? {
        guard let text = value?.trimmed.nilIfEmpty,
              text.count <= 2_048,
              text.rangeOfCharacter(from: .controlCharacters) == nil,
              text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              isIPv4(text) else {
            return nil
        }
        return text
    }

    private static func uniqueTrimmedValues(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            guard let text = value.trimmed.nilIfEmpty, seen.insert(text).inserted else { return nil }
            return text
        }
    }

    private static func containsPlaceholderText(_ value: String) -> Bool {
        ["example", "placeholder", "备用", "后台域名", "占位"].contains {
            value.localizedCaseInsensitiveContains($0)
        }
    }

    private static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy {
            guard !$0.isEmpty, $0.count <= 3, $0.allSatisfy(\.isNumber),
                  let number = Int($0) else { return false }
            return (0...255).contains(number)
        }
    }
}

struct ConfigLoadResult: Sendable {
    enum Source: String, Sendable {
        case remote
        case cache
        case fixture
    }

    let config: AppConfig
    let source: Source
    let cloudConfigIndex: Int?
    let cloudConfigURL: String?
    let cacheAgeSeconds: Int64?
    let cacheFresh: Bool
}

/// Only validated configuration availability controls the authentication UI.
/// Background API observations are deliberately excluded from business state.
struct ConfigurationRuntimeStatus: Sendable, Equatable {
    enum Source: Sendable, Equatable {
        case initializing
        case remote
        case cache
        case staleCache
        case fixture
        case unavailable
    }
    enum Refresh: Sendable, Equatable {
        case idle
        case checking
        case failed
    }
    var source: Source = .initializing
    var refresh: Refresh = .idle

    var loginPresentation: LoginConfigurationPresentation {
        if source == .unavailable { return .configurationUnavailable }
        if source == .initializing { return .initializing }
        return .ready
    }
}

enum LoginConfigurationPresentation: Sendable, Equatable {
    case initializing, ready, configurationUnavailable

    var localizedKey: String {
        switch self {
        case .initializing: L10nKey.loginStatusInitializing
        case .ready: L10nKey.loginStatusReady
        case .configurationUnavailable: L10nKey.loginStatusConfigFailed
        }
    }

    var needsRetry: Bool {
        self == .configurationUnavailable
    }
}

enum V2BoardAuthEndpoint: String, Sendable, Equatable, CaseIterable {
    case login
    case register
    case forget
    case emailVerification = "email_verification"
}

enum NetworkClientError: LocalizedError, Sendable {
    case bootstrapInvalid(String)
    case configInvalid(String)
    case configUnavailable(String)
    case validation(String)
    case transport(String)
    case server(String, retryable: Bool)
    case backendBusinessError(String)
    case authenticationExpired(String)
    case serviceUnavailable(String, retryable: Bool)
    case responseInvalid(String)
    case secureStorage(String)
    case dnsFailure
    case tlsFailure
    case timedOut
    case noConnection
    case rateLimited
    case invitationRejected(String)
    case orderCreationRejected(String)
    case changePasswordRejected(String)
    case authBusinessRejected(endpoint: V2BoardAuthEndpoint, message: String)
    case writeResultUnknown

    static func fromTransport(_ error: URLError) -> NetworkClientError {
        switch error.code {
        case .timedOut: .timedOut
        case .cannotFindHost, .dnsLookupFailed: .dnsFailure
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot: .tlsFailure
        case .notConnectedToInternet, .networkConnectionLost: .noConnection
        default: .transport("网络连接失败，请稍后重试")
        }
    }

    var errorDescription: String? {
        switch self {
        case let .bootstrapInvalid(message),
             let .configInvalid(message),
             let .configUnavailable(message),
             let .validation(message),
             let .transport(message),
             let .backendBusinessError(message),
             let .invitationRejected(message),
             let .orderCreationRejected(message),
             let .changePasswordRejected(message),
             let .authBusinessRejected(_, message),
             let .authenticationExpired(message),
             let .responseInvalid(message),
             let .secureStorage(message):
            message
        case let .server(message, _),
             let .serviceUnavailable(message, _):
            message
        case .dnsFailure: "DNS lookup failed"
        case .tlsFailure: "TLS connection failed"
        case .timedOut: "Request timed out"
        case .noConnection: "No network connection"
        case .rateLimited: "Request rate limited"
        case .writeResultUnknown: "Write result unknown"
        }
    }

    var userFacingMessage: LocalizedMessage {
        switch self {
        case .backendBusinessError:
            .localized(L10nKey.errorBusinessRejected)
        case .authenticationExpired:
            .localized(L10nKey.errorAuthenticationExpired)
        case let .validation(message):
            .localized(message)
        case .transport:
            .localized(L10nKey.errorNetworkUnavailable)
        case .dnsFailure: .localized(L10nKey.errorDNS)
        case .tlsFailure: .localized(L10nKey.errorTLS)
        case .timedOut: .localized(L10nKey.errorTimeout)
        case .noConnection: .localized(L10nKey.errorNetworkUnavailable)
        case .rateLimited: .localized(L10nKey.errorRateLimited)
        case let .invitationRejected(message): .verbatim(message)
        case let .orderCreationRejected(message): .verbatim(message)
        case let .changePasswordRejected(message): .verbatim(message)
        case let .authBusinessRejected(_, message): .verbatim(message)
        case .writeResultUnknown: .localized(L10nKey.errorWriteResultUnknown)
        case .serviceUnavailable, .responseInvalid:
            .localized(L10nKey.errorServiceUnavailable)
        case .secureStorage:
            .localized(L10nKey.errorSecureStorage)
        case .bootstrapInvalid, .configInvalid, .configUnavailable, .server:
            .localized(L10nKey.errorConfigurationUnavailable)
        }
    }

    var logCategory: String {
        switch self {
        case .backendBusinessError: "backend_business"
        case .authenticationExpired: "authentication_expired"
        case .transport: "transport"
        case .dnsFailure: "dns"
        case .tlsFailure: "tls"
        case .timedOut: "timeout"
        case .noConnection: "offline"
        case .rateLimited: "rate_limited"
        case .invitationRejected: "invitation_rejected"
        case .orderCreationRejected: "order_creation_rejected"
        case .changePasswordRejected: "change_password_rejected"
        case let .authBusinessRejected(endpoint, _): "auth_\(endpoint.rawValue)_rejected"
        case .writeResultUnknown: "write_result_unknown"
        case .serviceUnavailable: "service_unavailable"
        case .secureStorage: "secure_storage"
        case .validation: "validation"
        case .bootstrapInvalid, .configInvalid, .configUnavailable: "config"
        case .server: "server"
        case .responseInvalid: "response_invalid"
        }
    }

    var retryable: Bool {
        switch self {
        case .transport, .dnsFailure, .tlsFailure, .timedOut, .noConnection, .responseInvalid:
            true
        case let .server(_, retryable),
             let .serviceUnavailable(_, retryable):
            retryable
        default:
            false
        }
    }
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

/// Narrow external-link policy for the formal About & Support surface.
/// Customer service and the rest of RemoteConfig intentionally keep their
/// existing, separate validation semantics.
enum AboutSupportExternalLinkValidator {
    static func httpsURL(_ value: String?) -> URL? {
        guard let text = value?.trimmed.nilIfEmpty,
              text.count <= 2_048,
              !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let components = URLComponents(string: text),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              let url = components.url else { return nil }
        return url
    }
}
