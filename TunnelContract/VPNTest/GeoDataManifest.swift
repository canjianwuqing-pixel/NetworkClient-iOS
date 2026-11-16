import Foundation

/// The small, non-secret contract published by the app and consumed by the
/// packet-tunnel extension. Large GeoData bytes never cross this boundary.
struct GeoDataManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    enum PublicationState: String, Codable, Sendable { case ready }

    struct File: Codable, Equatable, Sendable {
        let logicalName: String
        let publishedRelativePath: String
        let expectedSize: Int64
        let expectedSHA256: String
        let sourceIdentity: String
    }

    let schemaVersion: Int
    let geoDataVersion: String
    let publicationIdentifier: String
    let publicationState: PublicationState
    let sourceIdentity: String
    let files: [File]
}

struct GeoDataCurrentPointer: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let publicationIdentifier: String
    let geoDataVersion: String
    let manifestRelativePath: String
}

struct GeoDataPublication: Equatable, Sendable {
    let publicationIdentifier: String
    let geoDataVersion: String
    let directory: URL
    let manifest: GeoDataManifest
}

enum GeoDataContractError: String, Error, Equatable {
    case missingContainer = "geodata-missing-container"
    case missingPointer = "geodata-missing-current-pointer"
    case invalidPointer = "geodata-invalid-current-pointer"
    case publicationMismatch = "geodata-publication-mismatch"
    case missingManifest = "geodata-missing-manifest"
    case invalidManifest = "geodata-invalid-manifest"
    case versionMismatch = "geodata-version-mismatch"
    case missingFile = "geodata-missing-file"
    case invalidFile = "geodata-invalid-file"
    case sizeMismatch = "geodata-size-mismatch"
    case sourceUnavailable = "geodata-source-unavailable"
    case sourceMetadataInvalid = "geodata-source-metadata-invalid"
    case digestMismatch = "geodata-digest-mismatch"
    case validationFailed = "geodata-validation-failed"
    case publicationFailed = "geodata-publication-failed"
}

enum GeoDataStore {
    static let directoryName = "GeoData"
    static let versionsDirectoryName = "versions"
    static let currentPointerName = "current.json"
    static let manifestName = "manifest.json"

    static func root(in bundle: Bundle = .main) throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: try MihomoTunnelStore.appGroup(in: bundle)
        ) else { throw GeoDataContractError.missingContainer }
        return container.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func versionDirectory(
        in root: URL, publicationIdentifier: String
    ) throws -> URL {
        guard UUID(uuidString: publicationIdentifier) != nil else {
            throw GeoDataContractError.invalidPointer
        }
        return root.appendingPathComponent(versionsDirectoryName, isDirectory: true)
            .appendingPathComponent(publicationIdentifier, isDirectory: true)
    }

    static func manifestRelativePath(publicationIdentifier: String) -> String {
        "\(versionsDirectoryName)/\(publicationIdentifier)/\(manifestName)"
    }

    static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), value.utf8.count <= 256 else { return false }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}
