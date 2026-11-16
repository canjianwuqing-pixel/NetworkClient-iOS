import Darwin
import Foundation
import XCTest
@testable import NetworkClient

final class MihomoTunnelStoreTests: XCTestCase {
    private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let generation = UUID()
        init() throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        var file: URL { path(generation) }
        func path(_ id: UUID) -> URL { directory.appendingPathComponent("tunnel-\(id.uuidString).json") }
        func value(yaml: String = "proxies: []\n# synthetic unicode 测试\n", pool: Bool = false) -> MihomoTunnelConfiguration {
            .init(generation: generation, nodeID: "synthetic-node", serverIPv4: "192.0.2.1", yaml: yaml,
                  createdAt: Date(timeIntervalSince1970: 1_000), accountScope: String(repeating: "a", count: 64),
                  coreName: "synthetic-core", configurationRevision: String(repeating: "b", count: 64),
                  mode: "rule",
                  candidatePool: pool ? [.init(nodeID: "synthetic-node", revision: String(repeating: "b", count: 64), coreName: "synthetic-core")] : nil,
                  candidatePoolRevision: pool ? String(repeating: "d", count: 64) : nil)
        }
        func write(_ data: Data) throws {
            try data.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        func object() throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value(pool: true))) as? [String: Any])
        }
        func writeObject(_ edit: (inout [String: Any]) -> Void) throws {
            var object = try object(); edit(&object)
            try write(JSONSerialization.data(withJSONObject: object))
        }
        func load(io: MihomoTunnelStore.ReadIO = .init()) throws -> MihomoTunnelConfiguration {
            try MihomoTunnelStore.load(expectedGeneration: generation, directory: directory, io: io)
        }
        func roundtrip(_ value: MihomoTunnelConfiguration? = nil) throws -> MihomoTunnelConfiguration {
            try MihomoTunnelStore.save(value ?? self.value(), directory: directory)
            return try load()
        }
    }
    private func expect(_ error: MihomoTunnelStoreError, _ work: () throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) {
        do { try work(); XCTFail("Expected a classified rejection", file: file, line: line) }
        catch let actual as MihomoTunnelStoreError { XCTAssertEqual(actual, error, file: file, line: line) }
        catch { XCTFail("Unclassified store error", file: file, line: line) }
    }
    private func invalid(_ error: MihomoTunnelStoreError, edit: (inout [String: Any]) -> Void,
                         file: StaticString = #filePath, line: UInt = #line) throws {
        let f = try Fixture(); try f.writeObject(edit)
        expect(error, { _ = try f.load() }, file: file, line: line)
    }
    func testProductionAppGroupSaveLoadRoundtrip() throws {
        let f = try Fixture(), value = f.value()
        try MihomoTunnelStore.save(value)
        defer { try? MihomoTunnelStore.remove(expectedGeneration: value.generation) }
        let loaded = try MihomoTunnelStore.load(expectedGeneration: value.generation)
        XCTAssertEqual(try JSONEncoder().encode(loaded).count, try JSONEncoder().encode(value).count)
        XCTAssertEqual(loaded.generation, value.generation); XCTAssertEqual(loaded.yaml, value.yaml)
    }
    func testAllCurrentFieldsRoundtrip() throws {
        let f = try Fixture(), value = f.value(pool: true), loaded = try f.roundtrip(value)
        let a = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? NSDictionary
        let b = try JSONSerialization.jsonObject(with: JSONEncoder().encode(loaded)) as? NSDictionary
        XCTAssertEqual(a, b)
    }
    func testGenerationPreserved() throws { let f = try Fixture(); XCTAssertEqual(try f.roundtrip().generation, f.generation) }
    func testScopePreserved() throws { let f = try Fixture(); XCTAssertEqual(try f.roundtrip().accountScope, f.value().accountScope) }
    func testRevisionPreserved() throws { let f = try Fixture(); XCTAssertEqual(try f.roundtrip().configurationRevision, f.value().configurationRevision) }
    func testCandidateInventoryPreserved() throws { let f = try Fixture(); XCTAssertEqual(try f.roundtrip(f.value(pool: true)).candidatePool, f.value(pool: true).candidatePool) }
    func testYAMLExactUnicodeAndEscapesPreserved() throws {
        let f = try Fixture(), text = "# 引号 \\\" [,{:]\n\u{0001}\tend e\u{0301} é"
        let loaded = try f.roundtrip(f.value(yaml: text))
        XCTAssertEqual(loaded.yaml, text)
        XCTAssertEqual(Data(loaded.yaml.utf8), Data(text.utf8))
    }
    func testMissingFile() throws { let f = try Fixture(); expect(.missingConfiguration) { _ = try f.load() } }
    func testDirectoryInsteadOfFile() throws {
        let f = try Fixture(); try FileManager.default.createDirectory(at: f.file, withIntermediateDirectories: false)
        expect(.invalidFileType) { _ = try f.load() }
    }
    func testSymlinkRejected() throws {
        let f = try Fixture(), target = f.directory.appendingPathComponent("target")
        try Data("synthetic".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: f.file, withDestinationURL: target)
        expect(.invalidFileType) { _ = try f.load() }
    }
    func testFIFORejectedWithoutBlocking() throws {
        let f = try Fixture(); XCTAssertEqual(mkfifo(f.file.path, 0o600), 0)
        expect(.invalidFileType) { _ = try f.load() }
    }
    func testSymlinkDirectoryRejected() throws {
        let f = try Fixture(), alias = f.directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.directory)
        expect(.untrustedDirectory) { _ = try MihomoTunnelStore.load(expectedGeneration: f.generation, directory: alias) }
    }
    func testWrongOwnerUsingExpectedUIDBoundary() throws {
        let f = try Fixture(); try f.write(JSONEncoder().encode(f.value()))
        var io = MihomoTunnelStore.ReadIO(); io.expectedOwner = getuid() ^ 1
        expect(.invalidOwner) { _ = try f.load(io: io) }
    }
    func testGroupReadablePermissionsRejected() throws {
        let f = try Fixture(); try f.write(JSONEncoder().encode(f.value()))
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: f.file.path)
        expect(.invalidPermissions) { _ = try f.load() }
    }
    func testOwnerReadOnlyPrivateFileAccepted() throws {
        let f = try Fixture(); try f.write(JSONEncoder().encode(f.value()))
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: f.file.path)
        XCTAssertEqual(try f.load().generation, f.generation)
    }
    func testZeroByteRejected() throws { let f = try Fixture(); try f.write(Data()); expect(.emptyFile) { _ = try f.load() } }
    func testOversizedFileRejectedBeforeAnyRead() throws {
        let f = try Fixture(); try f.write(Data()); let h = try FileHandle(forWritingTo: f.file)
        try h.truncate(atOffset: UInt64(MihomoTunnelStore.maximumFileBytes + 1)); try h.close()
        var reads = 0, io = MihomoTunnelStore.ReadIO(); io.read = { _, _, _ in reads += 1; return 0 }
        expect(.fileTooLarge) { _ = try f.load(io: io) }; XCTAssertEqual(reads, 0)
    }
    func testShortReadRejected() throws {
        let f = try Fixture(); try f.write(JSONEncoder().encode(f.value()))
        var io = MihomoTunnelStore.ReadIO(); io.afterFileStat = {
            let h = try? FileHandle(forWritingTo: f.file); try? h?.truncate(atOffset: 0); try? h?.close()
        }
        expect(.fileReadFailed) { _ = try f.load(io: io) }
    }
    func testGrowthDuringReadRejected() throws {
        let f = try Fixture(); try f.write(JSONEncoder().encode(f.value()))
        var io = MihomoTunnelStore.ReadIO(); io.afterFileStat = {
            let h = try? FileHandle(forWritingTo: f.file); _ = try? h?.seekToEnd(); try? h?.write(contentsOf: Data([32])); try? h?.close()
        }
        expect(.fileChanged) { _ = try f.load(io: io) }
    }
    func testSameFDDoesNotReadReplacementPath() throws {
        let f = try Fixture(); try f.write(JSONEncoder().encode(f.value()))
        var io = MihomoTunnelStore.ReadIO(); io.afterFileStat = {
            try? Data("replacement".utf8).write(to: f.file, options: .atomic)
        }
        expect(.fileChanged) { _ = try f.load(io: io) }
    }
    func testPartialReadsJoinExactlyTheBoundedFile() throws {
        let f = try Fixture(); try f.write(JSONEncoder().encode(f.value()))
        var io = MihomoTunnelStore.ReadIO(); io.read = { Darwin.read($0, $1, min($2, 7)) }
        XCTAssertEqual(try f.load(io: io).yaml, f.value().yaml)
    }
    func testInterruptedReadRetriesWithoutLosingBytes() throws {
        let f = try Fixture(); try f.write(JSONEncoder().encode(f.value()))
        var once = true, io = MihomoTunnelStore.ReadIO(); io.read = {
            if once { once = false; errno = EINTR; return -1 }; return Darwin.read($0, $1, $2)
        }
        XCTAssertEqual(try f.load(io: io).generation, f.generation)
    }
    func testReadFailureIsClassified() throws {
        let f = try Fixture(); try f.write(JSONEncoder().encode(f.value()))
        var io = MihomoTunnelStore.ReadIO(); io.read = { _, _, _ in errno = EIO; return -1 }
        expect(.fileReadFailed) { _ = try f.load(io: io) }
    }
    func testMalformedJSON() throws { let f = try Fixture(); try f.write(Data("{".utf8)); expect(.decodeFailed) { _ = try f.load() } }
    func testGenerationMismatch() throws { try invalid(.staleGeneration) { $0["generation"] = UUID().uuidString } }
    func testInvalidGeneration() throws { try invalid(.decodeFailed) { $0["generation"] = "not-a-generation" } }
    func testInvalidRevision() throws { try invalid(.invalidRevision) { $0["configurationRevision"] = "invalid" } }
    func testEmptyRevision() throws { try invalid(.invalidRevision) { $0["configurationRevision"] = "" } }
    func testInvalidScope() throws { try invalid(.invalidScope) { $0["accountScope"] = "invalid" } }
    func testInvalidCandidateRevision() throws {
        try invalid(.invalidCandidates) { object in
            var rows = object["candidatePool"] as? [[String: Any]] ?? []; rows[0]["revision"] = "invalid"; object["candidatePool"] = rows
        }
    }
    func testDuplicateCandidatesRejected() throws {
        try invalid(.invalidCandidates) { object in
            let rows = object["candidatePool"] as? [[String: Any]] ?? []; object["candidatePool"] = rows + rows
        }
    }
    func testExcessiveCandidateCountRejected() throws {
        try invalid(.invalidCandidates) { object in
            let row = (object["candidatePool"] as? [[String: Any]])?.first ?? [:]; object["candidatePool"] = Array(repeating: row, count: 129)
        }
    }
    func testEmptyCandidateInventoryRejected() throws { try invalid(.invalidCandidates) { $0["candidatePool"] = [] } }
    func testCandidateCannotOmitCurrentSelection() throws {
        try invalid(.invalidCandidates) { object in
            var rows = object["candidatePool"] as? [[String: Any]] ?? []; rows[0]["nodeID"] = "different"; object["candidatePool"] = rows
        }
    }
    func testInvalidIPv4() throws { try invalid(.invalidIPv4) { $0["serverIPv4"] = "999.1.1.1" } }
    func testEmptyYAML() throws { try invalid(.emptyYAML) { $0["yaml"] = "" } }
    func testOversizedYAMLWithoutInventory() throws {
        try invalid(.oversizedYAML) { $0.removeValue(forKey: "candidatePool"); $0.removeValue(forKey: "candidatePoolRevision"); $0["yaml"] = String(repeating: "x", count: MihomoTunnelStore.maximumYAMLBytes + 1) }
    }
    func testEmptyNodeRejected() throws { try invalid(.invalidConfiguration) { $0["nodeID"] = "" } }
    func testSaveAndLoadUseSameValidation() throws {
        let f = try Fixture(), invalid = f.value(yaml: "")
        expect(.emptyYAML) { try MihomoTunnelStore.save(invalid, directory: f.directory) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.file.path))
    }
    func testCurrentOptionalWireFieldsRemainOptionalWithoutFallbackDecoder() throws {
        let f = try Fixture(), value = MihomoTunnelConfiguration(generation: f.generation, nodeID: "synthetic", serverIPv4: "192.0.2.1", yaml: "synthetic", createdAt: Date())
        XCTAssertNil(try f.roundtrip(value).accountScope)
    }
    func testDeterministicMalformedInputMatrixThrowsOnlyClassifiedErrors() throws {
        let samples = [Data(), Data([0xff, 0xfe]), Data("[]".utf8), Data("null".utf8), Data("{}".utf8),
                       Data("{\"generation\":null}".utf8), Data("{\"generation\":[]}".utf8), Data("{\"generation\":\"\\uD800\"}".utf8),
                       Data(String(repeating: "[", count: 20_000).utf8), Data(("[" + String(repeating: "0,", count: 30_000) + "0]").utf8)]
        for sample in samples {
            let f = try Fixture(); try f.write(sample)
            do { _ = try f.load(); XCTFail("Malformed matrix accepted") }
            catch is MihomoTunnelStoreError { }
            catch { XCTFail("Unclassified matrix error") }
        }
    }
    func testDeepUnknownJSONRejectedBeforeDecoderExpansion() throws {
        let f = try Fixture(); var object = try f.object(); object["unknown"] = "MARKER"
        let data = try JSONSerialization.data(withJSONObject: object), text = String(decoding: data, as: UTF8.self)
        try f.write(Data(text.replacingOccurrences(of: "\"MARKER\"", with: String(repeating: "[", count: 100) + "0" + String(repeating: "]", count: 100)).utf8))
        expect(.decodeFailed) { _ = try f.load() }
    }
    func testImmediateProductionSaveLoadTwentyTimesWithoutSleep() throws {
        let f = try Fixture()
        for _ in 0..<20 {
            try MihomoTunnelStore.save(f.value(pool: true), directory: f.directory)
            XCTAssertEqual(try f.load().generation, f.generation)
            try MihomoTunnelStore.remove(expectedGeneration: f.generation, directory: f.directory)
        }
    }
    func testRemovingOneConfigurationLeavesOtherConfigurationUntouched() throws {
        let f = try Fixture(), g2 = UUID(), first = f.value()
        let second = MihomoTunnelConfiguration(generation: g2, nodeID: first.nodeID, serverIPv4: first.serverIPv4,
            yaml: first.yaml, createdAt: first.createdAt)
        try MihomoTunnelStore.save(first, directory: f.directory); try MihomoTunnelStore.save(second, directory: f.directory)
        let bytes = try Data(contentsOf: f.path(g2))
        try MihomoTunnelStore.remove(expectedGeneration: f.generation, directory: f.directory)
        try MihomoTunnelStore.remove(expectedGeneration: f.generation, directory: f.directory)
        XCTAssertEqual(try Data(contentsOf: f.path(g2)), bytes)
        XCTAssertEqual(try MihomoTunnelStore.load(expectedGeneration: g2, directory: f.directory).generation, g2)
    }
    func testSaveCannotReplaceExistingGeneration() throws {
        let f = try Fixture(); _ = try f.roundtrip(); let bytes = try Data(contentsOf: f.file)
        expect(.invalidConfiguration) { try MihomoTunnelStore.save(f.value(yaml: "replacement"), directory: f.directory) }
        XCTAssertEqual(try Data(contentsOf: f.file), bytes)
    }
    func testMalformedPrivateFileCanBeCleanedWithoutDecoding() throws {
        let f = try Fixture(); try f.write(Data("damaged".utf8))
        try MihomoTunnelStore.remove(expectedGeneration: f.generation, directory: f.directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.file.path))
    }
    func testCleanupRefusesSymlinkAndPreservesTarget() throws {
        let f = try Fixture(), target = f.directory.appendingPathComponent("target")
        try Data("synthetic".utf8).write(to: target); try FileManager.default.createSymbolicLink(at: f.file, withDestinationURL: target)
        expect(.invalidFileType) { try MihomoTunnelStore.remove(expectedGeneration: f.generation, directory: f.directory) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }
    func testWorstCaseEscapedRuntimeFitsChosenFileLimit() throws {
        let f = try Fixture(), value = f.value(yaml: String(repeating: "\u{0001}", count: MihomoTunnelStore.maximumYAMLBytes), pool: true)
        let size = try JSONEncoder().encode(value).count
        XCTAssertGreaterThan(size, 3 * 1_024 * 1_024); XCTAssertLessThan(size, MihomoTunnelStore.maximumFileBytes)
        XCTAssertEqual(try f.roundtrip(value).yaml.utf8.count, MihomoTunnelStore.maximumYAMLBytes)
    }
    func testExistingProtocolFixturesAndMaximumInventorySerializationSizes() throws {
        let fixtures = [("ss", "cipher: aes-256-gcm\n    password: synthetic-only"),
                        ("vmess", "uuid: 00000000-0000-4000-8000-000000000001\n    alterId: 0\n    cipher: auto\n    network: ws\n    ws-opts:\n      path: /synthetic"),
                        ("vless", "uuid: 00000000-0000-4000-8000-000000000001\n    tls: true\n    servername: synthetic.example\n    flow: xtls-rprx-vision\n    client-fingerprint: chrome\n    reality-opts:\n      public-key: \(String(repeating: "A", count: 43))\n      short-id: abcd"),
                        ("trojan", "password: synthetic-only\n    sni: synthetic.example\n    network: grpc\n    grpc-opts:\n      grpc-service-name: synthetic"),
                        ("hysteria2", "password: synthetic-only\n    sni: synthetic.example\n    obfs: salamander\n    obfs-password: synthetic-only\n    alpn: [h3]")]
        var sizes: [String: Int] = [:]
        let dns = try XCTUnwrap(URL(string: "https://1.1.1.1/dns-query"))
        for (type, fields) in fixtures {
            let sub = try SubscriptionParser().parse("proxies:\n  - name: synthetic\n    type: \(type)\n    server: 192.0.2.1\n    port: 443\n    \(fields)\n")
            let node = try XCTUnwrap(sub.nodes.first)
            let revision = try XCTUnwrap(SelectedNodeConfigurationIdentity.revision(in: sub, nodeID: node.id))
            let value = try SelectedNodeTunnelMapper().makeConfiguration(subscription: sub,
                request: .init(nodeID: node.id, mode: .rule, configurationRevision: revision), dnsEndpoint: dns)
            sizes[type] = try JSONEncoder().encode(value).count
            let f = try Fixture(); try MihomoTunnelStore.save(value, directory: f.directory)
            XCTAssertEqual(try MihomoTunnelStore.load(expectedGeneration: value.generation, directory: f.directory).yaml, value.yaml)
        }
        let f = try Fixture(), base = f.value()
        var inventory = [MihomoCandidateDescriptor(nodeID: base.nodeID, revision: try XCTUnwrap(base.configurationRevision), coreName: try XCTUnwrap(base.coreName))]
        inventory += (1..<128).map { .init(nodeID: "synthetic-\($0)", revision: String(repeating: "b", count: 64), coreName: "core-\($0)") }
        let max = base.withCandidatePool(yaml: base.yaml, candidates: inventory, revision: String(repeating: "d", count: 64))
        sizes["128-inventory"] = try JSONEncoder().encode(max).count
        XCTAssertEqual(try f.roundtrip(max).candidatePool?.count, 128)
        let data = try JSONSerialization.data(withJSONObject: sizes, options: [.sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "configuration-fixture-sizes.sanitized.json"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertLessThan(sizes.values.max() ?? 0, MihomoTunnelStore.maximumFileBytes)
    }
}
