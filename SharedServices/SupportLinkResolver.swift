import CryptoKit
import Foundation

/// Resolves the existing RemoteConfig.SupportApi formats without performing network work.
enum SupportLinkResolver {
    static func url(from value: String?) -> URL? {
        guard let text = value?.trimmed.nilIfEmpty,
              text.unicodeScalars.allSatisfy({ $0.isASCII }),
              let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased() else {
            return nil
        }

        if scheme == "http" || scheme == "https" {
            guard components.host?.isEmpty == false else { return nil }
            return components.url
        }

        guard scheme == "crisp" else { return nil }
        let websiteID = (components.host?.nilIfEmpty
            ?? components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).nilIfEmpty)?
            .trimmed
        guard let websiteID,
              (8...80).contains(websiteID.count),
              websiteID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            return nil
        }

        var target = URLComponents(string: NetworkEndpoints.customerServiceEmbed)
        target?.queryItems = [URLQueryItem(name: "website_id", value: websiteID)]
        return target?.url
    }
}

// All provider-specific behavior stays in the legacy adapter above.
enum CustomerServiceState: Equatable, Sendable {
    case absent, disabled, invalid
    case valid(CustomerServiceConfig)
}

struct CustomerServiceConfig: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable { case url, html }
    let enabled: Bool
    let mode: Mode
    let content: String
}

enum EffectiveCustomerService: Hashable, Sendable {
    enum Source: Hashable, Sendable { case customerService, legacy }
    case disabled, unavailable
    case url(URL, Source)
    case html(String)

    var canOpen: Bool { self != .disabled }
    var browserURL: URL? {
        if case let .url(url, _) = self { return url }
        return nil
    }
}

enum CustomerServiceAccountScope: Hashable, Sendable {
    case guest
    case account(String)

    fileprivate var identityMaterial: String {
        switch self {
        case .guest: "guest"
        case let .account(identifier): "account:\(identifier)"
        }
    }
}

struct CustomerServiceIdentity: Hashable, Sendable {
    enum Mode: String, Sendable { case url, html }

    let mode: Mode
    private let digest: String
    let dataStoreIdentifier: UUID

    var safeSummary: String {
        "\(mode.rawValue)-\(digest.prefix(12))"
    }

    fileprivate init(
        mode: Mode,
        brandScope: String,
        accountScope: CustomerServiceAccountScope,
        content: String
    ) {
        self.mode = mode
        let material = "customer-service\u{0}\(brandScope.precomposedStringWithCanonicalMapping)"
            + "\u{0}\(accountScope.identityMaterial)\u{0}\(mode.rawValue)\u{0}\(content)"
        let bytes = Array(SHA256.hash(data: Data(material.utf8)))
        digest = bytes.map { String(format: "%02x", $0) }.joined()

        var identifierBytes = Array(bytes.prefix(16))
        // Use a deterministic RFC 4122 variant/version so the same identity
        // receives the same isolated persistent WebKit data store.
        identifierBytes[6] = (identifierBytes[6] & 0x0f) | 0x50
        identifierBytes[8] = (identifierBytes[8] & 0x3f) | 0x80
        dataStoreIdentifier = UUID(uuid: (
            identifierBytes[0], identifierBytes[1], identifierBytes[2], identifierBytes[3],
            identifierBytes[4], identifierBytes[5], identifierBytes[6], identifierBytes[7],
            identifierBytes[8], identifierBytes[9], identifierBytes[10], identifierBytes[11],
            identifierBytes[12], identifierBytes[13], identifierBytes[14], identifierBytes[15]
        ))
    }
}

enum CustomerServiceResolver {
    static let cacheVersion = 3

    static func resolve(_ config: AppConfig?) -> EffectiveCustomerService {
        guard let config else { return .unavailable }
        switch config.customerService {
        case .absent:
            guard let url = SupportLinkResolver.url(from: config.supportAPI) else { return .unavailable }
            return .url(url, .legacy)
        case .disabled: return .disabled
        case .invalid: return .unavailable
        case let .valid(value):
            guard value.enabled else { return .disabled }
            guard !value.content.trimmed.isEmpty else { return .unavailable }
            switch value.mode {
            case .url:
                guard let url = httpsURL(value.content) else { return .unavailable }
                return .url(url, .customerService)
            case .html: return .html(value.content)
            }
        }
    }

    static func identity(
        for service: EffectiveCustomerService,
        brandScope: String,
        accountScope: CustomerServiceAccountScope
    ) -> CustomerServiceIdentity? {
        switch service {
        case let .url(url, source):
            // Preserve the complete resolved URL. Query and fragment changes
            // may carry routing or session identity and must never be reused.
            let sourceScope = source == .customerService ? "customer-service" : "legacy"
            return CustomerServiceIdentity(
                mode: .url,
                brandScope: brandScope,
                accountScope: accountScope,
                content: "\(sourceScope)\u{0}\(url.absoluteString)"
            )
        case let .html(content):
            return CustomerServiceIdentity(
                mode: .html,
                brandScope: brandScope,
                accountScope: accountScope,
                content: "customer-service\u{0}\(content)"
            )
        case .disabled, .unavailable:
            return nil
        }
    }

    static func accountScope(for session: UserSession?) -> CustomerServiceAccountScope {
        guard let session else { return .guest }
        return .account(PendingPaymentStore.accountIdentifier(for: session))
    }

    static func httpsURL(_ value: String) -> URL? {
        // Check before trimming so control characters cannot be hidden at the edges.
        guard value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        let text = value.trimmed
        guard !text.isEmpty,
              let parts = URLComponents(string: text), parts.scheme == "https",
              parts.host?.isEmpty == false, parts.user == nil, parts.password == nil,
              let url = parts.url else { return nil }
        return url
    }

    static func htmlDocument(_ content: String) -> String {
        let text = content.trimmed
        if text.range(of: #"(?is)^(?:<!--.*?-->\s*)*(?:<!doctype\s+html\b|<html(?:\s|>))"#,
                      options: .regularExpression) != nil { return content }
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html, body { margin: 0; width: 100%; min-height: 100%; }</style>
        </head><body>
        \(content)
        </body></html>
        """
    }

    enum NavigationDecision: Equatable { case allow, external, reject }
    static func navigation(_ url: URL?, service: EffectiveCustomerService,
                           userActivated: Bool) -> NavigationDecision {
        guard let url else { return .reject }
        let scheme = url.scheme?.lowercased()
        if scheme == "mailto" || scheme == "tel" {
            return userActivated ? .external : .reject
        }
        if httpsURL(url.absoluteString) != nil { return .allow }
        if case .url(_, .legacy) = service, scheme == "http", url.host?.isEmpty == false {
            return .allow
        }
        return .reject
    }

    static func configFromCache(_ config: AppConfig, version: Int) -> AppConfig? {
        guard version == cacheVersion || version == 2 else { return nil }
        var config = config
        // Version 2 erased unknown fields. Keep business data, but never infer absence.
        if version == 2 { config.customerService = .invalid }
        return config
    }
}
