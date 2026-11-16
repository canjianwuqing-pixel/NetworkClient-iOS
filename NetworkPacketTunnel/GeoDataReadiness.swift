import Darwin
import Foundation

/// Provider-safe GeoData gate. It reads only bounded JSON and file metadata;
/// it never copies, hashes, repairs, replaces or asks the SDK to load GeoData.
enum GeoDataReadiness {
    private static let maximumPointerBytes: Int64 = 16 * 1_024
    private static let maximumManifestBytes: Int64 = 64 * 1_024

    static func requireCurrent(
        in storeRoot: URL,
        expectedPublicationIdentifier: String? = nil
    ) throws -> GeoDataPublication {
        let pointerURL = storeRoot.appendingPathComponent(GeoDataStore.currentPointerName)
        let pointer: GeoDataCurrentPointer
        do {
            pointer = try decodeSmallJSON(
                GeoDataCurrentPointer.self, at: pointerURL, maximumBytes: maximumPointerBytes
            )
        } catch GeoDataContractError.missingFile {
            throw GeoDataContractError.missingPointer
        } catch {
            throw GeoDataContractError.invalidPointer
        }
        guard pointer.schemaVersion == GeoDataCurrentPointer.currentSchemaVersion,
              UUID(uuidString: pointer.publicationIdentifier) != nil,
              expectedPublicationIdentifier.map({ $0 == pointer.publicationIdentifier }) ?? true,
              pointer.manifestRelativePath == GeoDataStore.manifestRelativePath(
                publicationIdentifier: pointer.publicationIdentifier
              ) else {
            if let expectedPublicationIdentifier,
               expectedPublicationIdentifier != pointer.publicationIdentifier {
                throw GeoDataContractError.publicationMismatch
            }
            throw GeoDataContractError.invalidPointer
        }

        let versionDirectory = try GeoDataStore.versionDirectory(
            in: storeRoot, publicationIdentifier: pointer.publicationIdentifier
        )
        let manifestURL = versionDirectory.appendingPathComponent(GeoDataStore.manifestName)
        let manifest: GeoDataManifest
        do {
            manifest = try decodeSmallJSON(
                GeoDataManifest.self, at: manifestURL, maximumBytes: maximumManifestBytes
            )
        } catch GeoDataContractError.missingFile {
            throw GeoDataContractError.missingManifest
        } catch {
            throw GeoDataContractError.invalidManifest
        }
        guard manifest.schemaVersion == GeoDataManifest.currentSchemaVersion,
              manifest.publicationState == .ready,
              manifest.publicationIdentifier == pointer.publicationIdentifier,
              !manifest.sourceIdentity.isEmpty,
              !manifest.files.isEmpty,
              Set(manifest.files.map(\.logicalName)).count == manifest.files.count,
              Set(manifest.files.map(\.publishedRelativePath)).count == manifest.files.count else {
            throw GeoDataContractError.invalidManifest
        }
        guard manifest.geoDataVersion == pointer.geoDataVersion else {
            throw GeoDataContractError.versionMismatch
        }
        for file in manifest.files {
            guard !file.logicalName.isEmpty,
                  GeoDataStore.isSafeRelativePath(file.publishedRelativePath),
                  file.expectedSize > 0,
                  GeoDataStore.isLowercaseSHA256(file.expectedSHA256),
                  !file.sourceIdentity.isEmpty else {
                throw GeoDataContractError.invalidManifest
            }
            let url = versionDirectory.appendingPathComponent(file.publishedRelativePath)
            let metadata = try regularFileMetadata(at: url)
            guard metadata.size == file.expectedSize else {
                throw GeoDataContractError.sizeMismatch
            }
        }
        return GeoDataPublication(
            publicationIdentifier: pointer.publicationIdentifier,
            geoDataVersion: pointer.geoDataVersion,
            directory: versionDirectory,
            manifest: manifest
        )
    }

    private static func decodeSmallJSON<Value: Decodable>(
        _ type: Value.Type, at url: URL, maximumBytes: Int64
    ) throws -> Value {
        let metadata = try regularFileMetadata(at: url)
        guard metadata.size > 0, metadata.size <= maximumBytes else {
            throw GeoDataContractError.invalidFile
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard Int64(data.count) == metadata.size else { throw GeoDataContractError.invalidFile }
        return try JSONDecoder().decode(type, from: data)
    }

    private static func regularFileMetadata(at url: URL) throws -> (size: Int64, inode: UInt64) {
        var metadata = stat()
        while Darwin.lstat(url.path, &metadata) != 0 {
            if errno == EINTR { continue }
            if errno == ENOENT { throw GeoDataContractError.missingFile }
            throw GeoDataContractError.invalidFile
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw GeoDataContractError.invalidFile
        }
        return (Int64(metadata.st_size), UInt64(metadata.st_ino))
    }
}
