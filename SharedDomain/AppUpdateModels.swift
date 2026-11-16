import Foundation

enum AppUpdateManifestLimits {
    static let maximumResponseBytes = 256 * 1_024
    static let maximumVersionCharacters = 64
    static let maximumBodyCharacters = 32 * 1_024
}

struct AppUpdateManifest: Decodable, Sendable, Equatable {
    let platforms: Platforms

    struct Platforms: Decodable, Sendable, Equatable {
        let ios: Platform?
    }

    struct Platform: Decodable, Sendable, Equatable {
        let version: String
        let body: String
        let downloadURL: String?

        enum CodingKeys: String, CodingKey {
            case version
            case body
            case downloadURL = "download_url"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(String.self, forKey: .version)
            body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
            downloadURL = try container.decodeIfPresent(String.self, forKey: .downloadURL)
        }
    }
}

struct AppUpdateRelease: Sendable, Equatable {
    let version: String
    let body: String
    let updateURL: URL?
}

enum AppUpdateCheckOutcome: Sendable, Equatable {
    case upToDate
    case updateAvailable(AppUpdateRelease)
}

enum AppUpdateCheckState: Sendable, Equatable {
    case idle
    case checking
}

enum AppUpdateError: Error, Sendable, Equatable {
    case invalidConfiguration
    case invalidResponse
    case invalidManifest
    case invalidLocalVersion
}

struct AppUpdateConfigurationIdentity: Sendable, Equatable {
    let appName: String
    let manifestURL: String
}

struct AppNumericVersion: Sendable, Equatable, Comparable {
    private let components: [Int]

    init?(_ value: String) {
        let text = value.trimmed
        guard !text.isEmpty,
              text.count <= AppUpdateManifestLimits.maximumVersionCharacters else { return nil }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 16 else { return nil }
        var values: [Int] = []
        values.reserveCapacity(parts.count)
        for part in parts {
            guard !part.isEmpty,
                  part.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }),
                  let value = Int(part) else { return nil }
            values.append(value)
        }
        while values.count > 1, values.last == 0 { values.removeLast() }
        components = values
    }

    static func < (lhs: AppNumericVersion, rhs: AppNumericVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

enum AppUpdateURLPolicy {
    enum Environment: Sendable {
        case debug
        case release

        static var current: Self {
            #if DEBUG
            .debug
            #else
            .release
            #endif
        }
    }

    static func manifestURL(_ value: String?) -> URL? {
        AboutSupportExternalLinkValidator.httpsURL(value)
    }

    static func updateTargetURL(
        _ value: String?,
        environment: Environment = .current
    ) -> URL? {
        switch environment {
        case .debug:
            return AboutSupportExternalLinkValidator.httpsURL(value)
        case .release:
            return appStoreProductURL(value)
        }
    }

    static func appStoreProductURL(_ value: String?) -> URL? {
        guard let url = AboutSupportExternalLinkValidator.httpsURL(value),
              url.host?.lowercased() == "apps.apple.com",
              url.port == nil else { return nil }
        let hasProductID = url.pathComponents.contains { component in
            guard component.count > 2, component.hasPrefix("id") else { return false }
            return component.dropFirst(2).unicodeScalars.allSatisfy {
                (48...57).contains($0.value)
            }
        }
        return hasProductID ? url : nil
    }
}

extension AppUpdateManifest {
    func validatedIOSRelease(
        environment: AppUpdateURLPolicy.Environment = .current
    ) throws -> AppUpdateRelease {
        guard let ios = platforms.ios else { throw AppUpdateError.invalidManifest }
        let version = ios.version.trimmed
        let body = ios.body.trimmed
        guard version.count <= AppUpdateManifestLimits.maximumVersionCharacters,
              AppNumericVersion(version) != nil,
              body.count <= AppUpdateManifestLimits.maximumBodyCharacters,
              body.unicodeScalars.allSatisfy({ scalar in
                  !CharacterSet.controlCharacters.contains(scalar)
                      || scalar == "\n" || scalar == "\r" || scalar == "\t"
              }) else { throw AppUpdateError.invalidManifest }
        return AppUpdateRelease(
            version: version,
            body: body,
            updateURL: AppUpdateURLPolicy.updateTargetURL(
                ios.downloadURL,
                environment: environment
            )
        )
    }
}
