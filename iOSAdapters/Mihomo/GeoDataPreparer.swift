import Clash
import CryptoKit
import Darwin
import Foundation

/// App-side owner for every heavyweight GeoData operation. A Provider never
/// invokes this type and receives only the immutable publication identifier.
enum GeoDataPreparer {
    static let streamingChunkSize = 128 * 1_024

    enum Outcome: Equatable, Sendable { case noOpFastPath, published }

    struct Result: Equatable, Sendable {
        let outcome: Outcome
        let publication: GeoDataPublication
    }

    struct Resource: @unchecked Sendable {
        let logicalName: String
        let source: URL
        let publishedRelativePath: String
        let expectedSize: Int64
        let expectedSHA256: String
        let sourceIdentity: String
        let validate: @Sendable (URL) throws -> Void
    }

    struct Source: @unchecked Sendable {
        let geoDataVersion: String
        let sourceIdentity: String
        let resources: [Resource]
    }

    struct IO: @unchecked Sendable {
        var publicationIdentifier: @Sendable () -> String = { UUID().uuidString }
        var copy: @Sendable (URL, URL) throws -> Void = {
            try FileManager.default.copyItem(at: $0, to: $1)
        }
        var digest: @Sendable (URL) throws -> String = { try streamingDigest(at: $0) }
        var write: @Sendable (Data, URL, Data.WritingOptions) throws -> Void = {
            try $0.write(to: $1, options: $2)
        }
        var move: @Sendable (URL, URL) throws -> Void = {
            try FileManager.default.moveItem(at: $0, to: $1)
        }
        var remove: @Sendable (URL) throws -> Void = {
            try FileManager.default.removeItem(at: $0)
        }
    }

    private struct Provenance: Decodable {
        let schema: Int
        let candidateFiles: [String: String]
    }

    static func prepareIfNeeded(bundle: Bundle = .main) async throws -> Result {
        let source = try bundledSource(in: bundle)
        let root = try GeoDataStore.root(in: bundle)
        return try await Task.detached(priority: .userInitiated) {
            try prepareIfNeeded(source: source, storeRoot: root)
        }.value
    }

    static func prepareIfNeeded(
        source: Source,
        storeRoot: URL,
        io: IO = .init()
    ) throws -> Result {
        try validateSourceMetadata(source)
        if let current = try? GeoDataReadiness.requireCurrent(in: storeRoot),
           manifest(current.manifest, matches: source) {
            return Result(outcome: .noOpFastPath, publication: current)
        }

        let fileManager = FileManager.default
        let versions = storeRoot.appendingPathComponent(
            GeoDataStore.versionsDirectoryName, isDirectory: true
        )
        try createPrivateDirectory(storeRoot)
        try createPrivateDirectory(versions)

        let publicationIdentifier = io.publicationIdentifier()
        guard UUID(uuidString: publicationIdentifier) != nil else {
            throw GeoDataContractError.publicationFailed
        }
        let staging = storeRoot.appendingPathComponent(
            ".staging-\(publicationIdentifier)", isDirectory: true
        )
        let published = try GeoDataStore.versionDirectory(
            in: storeRoot, publicationIdentifier: publicationIdentifier
        )
        guard !fileManager.fileExists(atPath: staging.path),
              !fileManager.fileExists(atPath: published.path) else {
            throw GeoDataContractError.publicationFailed
        }
        try createPrivateDirectory(staging)
        var moved = false
        defer { if !moved { try? io.remove(staging) } }

        var entries: [GeoDataManifest.File] = []
        entries.reserveCapacity(source.resources.count)
        for resource in source.resources {
            let destination = staging.appendingPathComponent(resource.publishedRelativePath)
            try createPrivateDirectory(destination.deletingLastPathComponent())
            try io.copy(resource.source, destination)
            try setPrivateFileAttributes(destination)
            let digest = try io.digest(destination)
            guard digest == resource.expectedSHA256,
                  try regularFileSize(destination) == resource.expectedSize else {
                throw GeoDataContractError.digestMismatch
            }
            do { try resource.validate(destination) }
            catch { throw GeoDataContractError.validationFailed }
            entries.append(.init(
                logicalName: resource.logicalName,
                publishedRelativePath: resource.publishedRelativePath,
                expectedSize: resource.expectedSize,
                expectedSHA256: resource.expectedSHA256,
                sourceIdentity: resource.sourceIdentity
            ))
        }

        let manifest = GeoDataManifest(
            schemaVersion: GeoDataManifest.currentSchemaVersion,
            geoDataVersion: source.geoDataVersion,
            publicationIdentifier: publicationIdentifier,
            publicationState: .ready,
            sourceIdentity: source.sourceIdentity,
            files: entries
        )
        let manifestData = try stableJSONEncoder().encode(manifest)
        let stagingManifest = staging.appendingPathComponent(GeoDataStore.manifestName)
        try io.write(
            manifestData, stagingManifest,
            [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        try setPrivateFileAttributes(stagingManifest)
        try io.move(staging, published)
        moved = true

        let pointer = GeoDataCurrentPointer(
            schemaVersion: GeoDataCurrentPointer.currentSchemaVersion,
            publicationIdentifier: publicationIdentifier,
            geoDataVersion: source.geoDataVersion,
            manifestRelativePath: GeoDataStore.manifestRelativePath(
                publicationIdentifier: publicationIdentifier
            )
        )
        let pointerData = try stableJSONEncoder().encode(pointer)
        let pointerURL = storeRoot.appendingPathComponent(GeoDataStore.currentPointerName)
        do {
            // This small atomic pointer is deliberately published last.
            try io.write(
                pointerData, pointerURL,
                [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            try setPrivateFileAttributes(pointerURL)
        } catch {
            throw GeoDataContractError.publicationFailed
        }
        return Result(
            outcome: .published,
            publication: .init(
                publicationIdentifier: publicationIdentifier,
                geoDataVersion: source.geoDataVersion,
                directory: published,
                manifest: manifest
            )
        )
    }

    static func streamingDigest(
        at url: URL,
        chunkSize: Int = streamingChunkSize,
        observedChunk: ((Int) -> Void)? = nil
    ) throws -> String {
        guard chunkSize > 0, chunkSize <= 1_024 * 1_024 else {
            throw GeoDataContractError.sourceMetadataInvalid
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            observedChunk?(chunk.count)
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func bundledSource(in bundle: Bundle) throws -> Source {
        guard let provenanceURL = bundle.url(forResource: "PROVENANCE", withExtension: "json"),
              let provenanceSize = try? regularFileSize(provenanceURL),
              provenanceSize > 0, provenanceSize <= 64 * 1_024 else {
            throw GeoDataContractError.sourceUnavailable
        }
        let provenanceData = try Data(contentsOf: provenanceURL)
        let provenance = try JSONDecoder().decode(Provenance.self, from: provenanceData)
        guard provenance.schema == 1 else { throw GeoDataContractError.sourceMetadataInvalid }
        let provenanceDigest = SHA256.hash(data: provenanceData)
            .map { String(format: "%02x", $0) }.joined()
        let sourceIdentity = "PROVENANCE.json#sha256=\(provenanceDigest)"

        let specifications: [(
            logicalName: String, resource: String, extension: String,
            relativePath: String, minimumSize: Int64,
            validate: @Sendable (URL) throws -> Void
        )] = [
            ("geoip", "geoip", "metadb", "geoip.metadb", 256 * 1_024, { url in
                var error: NSError?
                guard ClashValidateGeodataForIOS("geoip", "mmdb", url.path, &error),
                      error == nil else { throw error ?? GeoDataContractError.validationFailed }
            }),
            ("geosite", "geosite", "dat", "geosite.dat", 1_024 * 1_024, { url in
                var error: NSError?
                guard ClashValidateGeodataCodesForIOS("geosite", "dat", url.path, "cn", &error),
                      error == nil else { throw error ?? GeoDataContractError.validationFailed }
            }),
            ("compiled-geosite-cn", "cn", "mrs", "compiled-geosite/cn.mrs", 1_024, { _ in })
        ]
        let resources = try specifications.map { specification -> Resource in
            let filename = "\(specification.resource).\(specification.extension)"
            guard let source = bundle.url(
                forResource: specification.resource, withExtension: specification.extension
            ), let expectedSHA256 = provenance.candidateFiles[filename],
               GeoDataStore.isLowercaseSHA256(expectedSHA256) else {
                throw GeoDataContractError.sourceUnavailable
            }
            let size = try regularFileSize(source)
            guard size >= specification.minimumSize else {
                throw GeoDataContractError.sourceMetadataInvalid
            }
            return Resource(
                logicalName: specification.logicalName,
                source: source,
                publishedRelativePath: specification.relativePath,
                expectedSize: size,
                expectedSHA256: expectedSHA256,
                sourceIdentity: "\(sourceIdentity)#candidateFiles/\(filename)",
                validate: specification.validate
            )
        }
        return Source(
            geoDataVersion: provenanceDigest,
            sourceIdentity: sourceIdentity,
            resources: resources
        )
    }

    private static func validateSourceMetadata(_ source: Source) throws {
        guard GeoDataStore.isLowercaseSHA256(source.geoDataVersion),
              !source.sourceIdentity.isEmpty,
              !source.resources.isEmpty,
              Set(source.resources.map(\.logicalName)).count == source.resources.count,
              Set(source.resources.map(\.publishedRelativePath)).count == source.resources.count else {
            throw GeoDataContractError.sourceMetadataInvalid
        }
        for resource in source.resources {
            guard !resource.logicalName.isEmpty,
                  GeoDataStore.isSafeRelativePath(resource.publishedRelativePath),
                  resource.expectedSize > 0,
                  GeoDataStore.isLowercaseSHA256(resource.expectedSHA256),
                  !resource.sourceIdentity.isEmpty,
                  try regularFileSize(resource.source) == resource.expectedSize else {
                throw GeoDataContractError.sourceMetadataInvalid
            }
        }
    }

    private static func manifest(_ manifest: GeoDataManifest, matches source: Source) -> Bool {
        guard manifest.geoDataVersion == source.geoDataVersion,
              manifest.sourceIdentity == source.sourceIdentity,
              manifest.files.count == source.resources.count else { return false }
        let expected = Dictionary(uniqueKeysWithValues: source.resources.map {
            ($0.logicalName, ($0.publishedRelativePath, $0.expectedSize, $0.expectedSHA256, $0.sourceIdentity))
        })
        return manifest.files.allSatisfy { file in
            guard let value = expected[file.logicalName] else { return false }
            return file.publishedRelativePath == value.0
                && file.expectedSize == value.1
                && file.expectedSHA256 == value.2
                && file.sourceIdentity == value.3
        }
    }

    private static func regularFileSize(_ url: URL) throws -> Int64 {
        var metadata = stat()
        while Darwin.lstat(url.path, &metadata) != 0 {
            if errno == EINTR { continue }
            throw GeoDataContractError.sourceUnavailable
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw GeoDataContractError.sourceUnavailable
        }
        return Int64(metadata.st_size)
    }

    private static func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: url.path
        )
    }

    private static func setPrivateFileAttributes(_ url: URL) throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        #if !targetEnvironment(simulator)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
    }

    private static func stableJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
