import CryptoKit
import Foundation
import XCTest
@testable import NetworkClient

final class GeoDataLowMemoryArchitectureTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0
        func increment() { lock.lock(); storage += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return storage }
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ value: String) { lock.lock(); storage.append(value); lock.unlock() }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var sources: URL { root.appendingPathComponent("sources", isDirectory: true) }
        var store: URL { root.appendingPathComponent("store", isDirectory: true) }

        init() throws {
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        func source(versionCharacter: Character = "a", byte: UInt8 = 0x4a) throws -> GeoDataPreparer.Source {
            let specifications = [
                ("geoip", "geoip.metadb", 4_097),
                ("geosite", "geosite.dat", 8_193),
                ("compiled-geosite-cn", "compiled-geosite/cn.mrs", 2_049),
            ]
            let resources = try specifications.enumerated().map { index, specification in
                let url = sources.appendingPathComponent("\(versionCharacter)-\(index)")
                if !FileManager.default.fileExists(atPath: url.path) {
                    try Data(repeating: byte &+ UInt8(index), count: specification.2).write(to: url)
                }
                return GeoDataPreparer.Resource(
                    logicalName: specification.0, source: url,
                    publishedRelativePath: specification.1,
                    expectedSize: Int64(specification.2),
                    expectedSHA256: try GeoDataPreparer.streamingDigest(at: url),
                    sourceIdentity: "fixture-\(versionCharacter)-\(index)",
                    validate: { _ in }
                )
            }
            return .init(
                geoDataVersion: String(repeating: String(versionCharacter), count: 64),
                sourceIdentity: "fixture-source-\(versionCharacter)",
                resources: resources
            )
        }
    }

    func testManifestAndCurrentPointerRoundTrip() throws {
        let identifier = UUID().uuidString
        let manifest = GeoDataManifest(
            schemaVersion: 1, geoDataVersion: String(repeating: "a", count: 64),
            publicationIdentifier: identifier, publicationState: .ready,
            sourceIdentity: "fixture", files: [.init(
                logicalName: "geoip", publishedRelativePath: "geoip.metadb",
                expectedSize: 9, expectedSHA256: String(repeating: "b", count: 64),
                sourceIdentity: "fixture-geoip"
            )]
        )
        XCTAssertEqual(try JSONDecoder().decode(
            GeoDataManifest.self, from: JSONEncoder().encode(manifest)
        ), manifest)
        let pointer = GeoDataCurrentPointer(
            schemaVersion: 1, publicationIdentifier: identifier,
            geoDataVersion: manifest.geoDataVersion,
            manifestRelativePath: GeoDataStore.manifestRelativePath(publicationIdentifier: identifier)
        )
        XCTAssertEqual(try JSONDecoder().decode(
            GeoDataCurrentPointer.self, from: JSONEncoder().encode(pointer)
        ), pointer)
    }

    func testInitialPreparePublishesImmutableVersionAndReadinessPasses() throws {
        let fixture = try Fixture()
        let result = try GeoDataPreparer.prepareIfNeeded(
            source: fixture.source(), storeRoot: fixture.store
        )
        XCTAssertEqual(result.outcome, .published)
        let ready = try GeoDataReadiness.requireCurrent(
            in: fixture.store,
            expectedPublicationIdentifier: result.publication.publicationIdentifier
        )
        XCTAssertEqual(ready, result.publication)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.store.appendingPathComponent("current.json").path
        ))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.store.path)
            .contains(where: { $0.hasPrefix(".staging-") }))
    }

    func testSecondPrepareUsesNoOpWithoutCopyHashMoveOrWrite() throws {
        let fixture = try Fixture(), source = try fixture.source()
        let first = try GeoDataPreparer.prepareIfNeeded(source: source, storeRoot: fixture.store)
        let copies = Counter(), hashes = Counter(), moves = Counter(), writes = Counter()
        let live = GeoDataPreparer.IO()
        var io = live
        io.copy = { copies.increment(); try live.copy($0, $1) }
        io.digest = { hashes.increment(); return try live.digest($0) }
        io.move = { moves.increment(); try live.move($0, $1) }
        io.write = { writes.increment(); try live.write($0, $1, $2) }
        let second = try GeoDataPreparer.prepareIfNeeded(
            source: source, storeRoot: fixture.store, io: io
        )
        XCTAssertEqual(second.outcome, .noOpFastPath)
        XCTAssertEqual(second.publication.publicationIdentifier,
                       first.publication.publicationIdentifier)
        XCTAssertEqual(copies.value, 0); XCTAssertEqual(hashes.value, 0)
        XCTAssertEqual(moves.value, 0); XCTAssertEqual(writes.value, 0)
    }

    func testVersionChangePublishesNewCurrentAndPreservesOldVersion() throws {
        let fixture = try Fixture()
        let old = try GeoDataPreparer.prepareIfNeeded(
            source: fixture.source(), storeRoot: fixture.store
        )
        let new = try GeoDataPreparer.prepareIfNeeded(
            source: fixture.source(versionCharacter: "b", byte: 0x5b), storeRoot: fixture.store
        )
        XCTAssertNotEqual(old.publication.publicationIdentifier,
                          new.publication.publicationIdentifier)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.publication.directory.path))
        XCTAssertEqual(try GeoDataReadiness.requireCurrent(in: fixture.store), new.publication)
    }

    func testReadinessRejectsMissingPointerInvalidPointerAndVersionMismatch() throws {
        let fixture = try Fixture()
        XCTAssertThrowsError(try GeoDataReadiness.requireCurrent(in: fixture.store)) {
            XCTAssertEqual($0 as? GeoDataContractError, .missingPointer)
        }
        try FileManager.default.createDirectory(at: fixture.store, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: fixture.store.appendingPathComponent("current.json"))
        XCTAssertThrowsError(try GeoDataReadiness.requireCurrent(in: fixture.store)) {
            XCTAssertEqual($0 as? GeoDataContractError, .invalidPointer)
        }
        let result = try GeoDataPreparer.prepareIfNeeded(
            source: fixture.source(), storeRoot: fixture.store
        )
        let pointer = GeoDataCurrentPointer(
            schemaVersion: 1,
            publicationIdentifier: result.publication.publicationIdentifier,
            geoDataVersion: String(repeating: "b", count: 64),
            manifestRelativePath: GeoDataStore.manifestRelativePath(
                publicationIdentifier: result.publication.publicationIdentifier
            )
        )
        try JSONEncoder().encode(pointer).write(
            to: fixture.store.appendingPathComponent("current.json"), options: .atomic
        )
        XCTAssertThrowsError(try GeoDataReadiness.requireCurrent(in: fixture.store)) {
            XCTAssertEqual($0 as? GeoDataContractError, .versionMismatch)
        }
    }

    func testReadinessRejectsMissingAndSizeMismatchedPublishedFile() throws {
        let fixture = try Fixture()
        let result = try GeoDataPreparer.prepareIfNeeded(
            source: fixture.source(), storeRoot: fixture.store
        )
        let file = result.publication.directory.appendingPathComponent("geoip.metadb")
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try GeoDataReadiness.requireCurrent(in: fixture.store)) {
            XCTAssertEqual($0 as? GeoDataContractError, .missingFile)
        }
        try Data(repeating: 0, count: 1).write(to: file)
        XCTAssertThrowsError(try GeoDataReadiness.requireCurrent(in: fixture.store)) {
            XCTAssertEqual($0 as? GeoDataContractError, .sizeMismatch)
        }
    }

    func testHashMismatchAndCopyFailureLeaveNoCurrentOrStaging() throws {
        for failure in ["hash", "copy"] {
            let fixture = try Fixture(), source = try fixture.source()
            var io = GeoDataPreparer.IO()
            if failure == "hash" {
                io.digest = { _ in String(repeating: "0", count: 64) }
            } else {
                io.copy = { _, destination in
                    try Data("partial".utf8).write(to: destination)
                    throw POSIXError(.ENOSPC)
                }
            }
            XCTAssertThrowsError(try GeoDataPreparer.prepareIfNeeded(
                source: source, storeRoot: fixture.store, io: io
            ))
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: fixture.store.appendingPathComponent("current.json").path
            ))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.store.path)
                .contains(where: { $0.hasPrefix(".staging-") }))
        }
    }

    func testManifestWriteAndDirectoryPublishFailuresPreserveOldCurrent() throws {
        for failure in ["manifest", "move"] {
            let fixture = try Fixture()
            let old = try GeoDataPreparer.prepareIfNeeded(
                source: fixture.source(), storeRoot: fixture.store
            )
            let live = GeoDataPreparer.IO()
            var io = live
            if failure == "manifest" {
                io.write = { data, url, options in
                    if url.lastPathComponent == GeoDataStore.manifestName {
                        throw POSIXError(.ENOSPC)
                    }
                    try live.write(data, url, options)
                }
            } else {
                io.move = { _, _ in throw POSIXError(.EROFS) }
            }
            XCTAssertThrowsError(try GeoDataPreparer.prepareIfNeeded(
                source: fixture.source(versionCharacter: "b", byte: 0x5b),
                storeRoot: fixture.store, io: io
            ))
            XCTAssertEqual(try GeoDataReadiness.requireCurrent(in: fixture.store), old.publication)
        }
    }

    func testPointerPublishFailureLeavesOldCurrentAndCompleteOrphanVersion() throws {
        let fixture = try Fixture()
        let old = try GeoDataPreparer.prepareIfNeeded(
            source: fixture.source(), storeRoot: fixture.store
        )
        let live = GeoDataPreparer.IO()
        var io = live
        io.write = { data, url, options in
            if url.lastPathComponent == GeoDataStore.currentPointerName {
                throw POSIXError(.ENOSPC)
            }
            try live.write(data, url, options)
        }
        XCTAssertThrowsError(try GeoDataPreparer.prepareIfNeeded(
            source: fixture.source(versionCharacter: "b", byte: 0x5b),
            storeRoot: fixture.store, io: io
        ))
        XCTAssertEqual(try GeoDataReadiness.requireCurrent(in: fixture.store), old.publication)
        let versions = fixture.store.appendingPathComponent("versions")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: versions.path).count, 2)
    }

    func testStreamingDigestIsCorrectAndEveryReadIsBounded() throws {
        let fixture = try Fixture()
        let large = fixture.sources.appendingPathComponent("large-fixture")
        let bytes = Data((0..<(2 * 1_024 * 1_024 + 17)).map { UInt8($0 % 251) })
        try bytes.write(to: large)
        var maximum = 0
        let streamed = try GeoDataPreparer.streamingDigest(at: large) {
            maximum = max(maximum, $0)
        }
        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(streamed, expected)
        XCTAssertLessThanOrEqual(maximum, GeoDataPreparer.streamingChunkSize)
        XCTAssertEqual(GeoDataPreparer.streamingChunkSize, 128 * 1_024)
    }

    func testReadinessRejectsExpectedPublicationMismatch() throws {
        let fixture = try Fixture()
        _ = try GeoDataPreparer.prepareIfNeeded(
            source: fixture.source(), storeRoot: fixture.store
        )
        XCTAssertThrowsError(try GeoDataReadiness.requireCurrent(
            in: fixture.store, expectedPublicationIdentifier: UUID().uuidString
        )) {
            XCTAssertEqual($0 as? GeoDataContractError, .publicationMismatch)
        }
    }

    func testReadinessRejectsInvalidManifestMetadata() throws {
        let fixture = try Fixture()
        let result = try GeoDataPreparer.prepareIfNeeded(
            source: fixture.source(), storeRoot: fixture.store
        )
        let invalid = GeoDataManifest(
            schemaVersion: GeoDataManifest.currentSchemaVersion,
            geoDataVersion: result.publication.geoDataVersion,
            publicationIdentifier: result.publication.publicationIdentifier,
            publicationState: .ready,
            sourceIdentity: "fixture", files: []
        )
        try JSONEncoder().encode(invalid).write(
            to: result.publication.directory.appendingPathComponent(GeoDataStore.manifestName),
            options: .atomic
        )
        XCTAssertThrowsError(try GeoDataReadiness.requireCurrent(in: fixture.store)) {
            XCTAssertEqual($0 as? GeoDataContractError, .invalidManifest)
        }
    }

    func testReadinessRejectsSymlinkPointerAndPublishedFile() throws {
        let fixture = try Fixture()
        let result = try GeoDataPreparer.prepareIfNeeded(
            source: fixture.source(), storeRoot: fixture.store
        )
        let pointer = fixture.store.appendingPathComponent(GeoDataStore.currentPointerName)
        let savedPointer = fixture.store.appendingPathComponent("saved-current.json")
        try FileManager.default.moveItem(at: pointer, to: savedPointer)
        try FileManager.default.createSymbolicLink(at: pointer, withDestinationURL: savedPointer)
        XCTAssertThrowsError(try GeoDataReadiness.requireCurrent(in: fixture.store)) {
            XCTAssertEqual($0 as? GeoDataContractError, .invalidPointer)
        }

        try FileManager.default.removeItem(at: pointer)
        try FileManager.default.moveItem(at: savedPointer, to: pointer)
        let published = result.publication.directory.appendingPathComponent("geoip.metadb")
        let savedFile = fixture.root.appendingPathComponent("saved-geoip")
        try FileManager.default.moveItem(at: published, to: savedFile)
        try FileManager.default.createSymbolicLink(at: published, withDestinationURL: savedFile)
        XCTAssertThrowsError(try GeoDataReadiness.requireCurrent(in: fixture.store)) {
            XCTAssertEqual($0 as? GeoDataContractError, .invalidFile)
        }
    }

    func testOversizedCurrentPointerIsRejectedWithoutDecoding() throws {
        let fixture = try Fixture()
        try FileManager.default.createDirectory(at: fixture.store, withIntermediateDirectories: true)
        try Data(repeating: 0x20, count: 16 * 1_024 + 1).write(
            to: fixture.store.appendingPathComponent(GeoDataStore.currentPointerName)
        )
        XCTAssertThrowsError(try GeoDataReadiness.requireCurrent(in: fixture.store)) {
            XCTAssertEqual($0 as? GeoDataContractError, .invalidPointer)
        }
    }

    func testInvalidSourceMetadataFailsBeforeAnyCopy() throws {
        let fixture = try Fixture(), valid = try fixture.source()
        let copies = Counter()
        var io = GeoDataPreparer.IO()
        io.copy = { _, _ in copies.increment() }
        let invalidResources = valid.resources.enumerated().map { index, resource in
            GeoDataPreparer.Resource(
                logicalName: resource.logicalName,
                source: resource.source,
                publishedRelativePath: resource.publishedRelativePath,
                expectedSize: resource.expectedSize + (index == 0 ? 1 : 0),
                expectedSHA256: resource.expectedSHA256,
                sourceIdentity: resource.sourceIdentity,
                validate: resource.validate
            )
        }
        let invalid = GeoDataPreparer.Source(
            geoDataVersion: valid.geoDataVersion,
            sourceIdentity: valid.sourceIdentity,
            resources: invalidResources
        )
        XCTAssertThrowsError(try GeoDataPreparer.prepareIfNeeded(
            source: invalid, storeRoot: fixture.store, io: io
        )) {
            XCTAssertEqual($0 as? GeoDataContractError, .sourceMetadataInvalid)
        }
        XCTAssertEqual(copies.value, 0)
    }

    func testSDKValidationFailurePreservesOldCurrent() throws {
        enum ValidationFailure: Error { case rejected }
        let fixture = try Fixture()
        let old = try GeoDataPreparer.prepareIfNeeded(
            source: fixture.source(), storeRoot: fixture.store
        )
        let next = try fixture.source(versionCharacter: "b", byte: 0x5b)
        let rejecting = GeoDataPreparer.Source(
            geoDataVersion: next.geoDataVersion,
            sourceIdentity: next.sourceIdentity,
            resources: next.resources.map { resource in
                GeoDataPreparer.Resource(
                    logicalName: resource.logicalName,
                    source: resource.source,
                    publishedRelativePath: resource.publishedRelativePath,
                    expectedSize: resource.expectedSize,
                    expectedSHA256: resource.expectedSHA256,
                    sourceIdentity: resource.sourceIdentity,
                    validate: { _ in throw ValidationFailure.rejected }
                )
            }
        )
        XCTAssertThrowsError(try GeoDataPreparer.prepareIfNeeded(
            source: rejecting, storeRoot: fixture.store
        )) {
            XCTAssertEqual($0 as? GeoDataContractError, .validationFailed)
        }
        XCTAssertEqual(try GeoDataReadiness.requireCurrent(in: fixture.store), old.publication)
    }

    func testInvalidPublicationIdentifierFailsBeforeStaging() throws {
        let fixture = try Fixture(), source = try fixture.source()
        var io = GeoDataPreparer.IO()
        io.publicationIdentifier = { "not-a-uuid" }
        XCTAssertThrowsError(try GeoDataPreparer.prepareIfNeeded(
            source: source, storeRoot: fixture.store, io: io
        )) {
            XCTAssertEqual($0 as? GeoDataContractError, .publicationFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.store.appendingPathComponent(GeoDataStore.currentPointerName).path
        ))
    }

    func testImmutableDirectoryMovePrecedesCurrentPointerPublication() throws {
        let fixture = try Fixture(), source = try fixture.source()
        let recorder = Recorder(), live = GeoDataPreparer.IO()
        var io = live
        io.copy = { source, destination in
            recorder.append("copy"); try live.copy(source, destination)
        }
        io.digest = { url in recorder.append("hash"); return try live.digest(url) }
        io.write = { data, url, options in
            recorder.append("write:\(url.lastPathComponent)")
            try live.write(data, url, options)
        }
        io.move = { source, destination in
            recorder.append("move-version"); try live.move(source, destination)
        }
        _ = try GeoDataPreparer.prepareIfNeeded(
            source: source, storeRoot: fixture.store, io: io
        )
        let operations = recorder.values
        XCTAssertEqual(operations.last, "write:\(GeoDataStore.currentPointerName)")
        XCTAssertLessThan(
            try XCTUnwrap(operations.firstIndex(of: "move-version")),
            try XCTUnwrap(operations.firstIndex(of: "write:\(GeoDataStore.currentPointerName)"))
        )
        XCTAssertEqual(operations.filter { $0 == "copy" }.count, source.resources.count)
        XCTAssertEqual(operations.filter { $0 == "hash" }.count, source.resources.count)
    }

}
