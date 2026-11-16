import Darwin
import Foundation
import XCTest
@testable import NetworkClient

final class VPNObsoleteDataRemovalTests: XCTestCase {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vpn-removal-\(UUID().uuidString)")
        var container: URL { root.appendingPathComponent("app-group") }
        init() throws { try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: root) }
        func file(_ relative: String) -> URL { container.appendingPathComponent(relative) }
        func write(_ relative: String, _ data: Data) throws {
            let path = file(relative)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: path)
        }
    }
    func testAllowlistDeletesOnlyRetiredFilesAndPreservesBusinessAndCurrentRuntime() throws {
        let f = try Fixture(), identifier = UUID().uuidString
        let retired = ["tunnel-stage.json", "active-selection-\(identifier).json", "latency-batch-\(identifier).json",
                       "Library/Caches/tunnel-stage-evidence.json", "Library/Caches/developer-tunnel-events.jsonl",
                       "Library/Caches/route-client-\(identifier).json"]
        // Invalid JSON must still be removable: the helper uses names, never a
        // legacy decoder, migration reader, or persisted completion flag.
        for path in retired { try f.write(path, Data([0xFF, 0xFE, 0x00])) }
        let retained = ["tunnel-\(identifier).json", "tunnel-\(identifier).tmp", "account-settings.plist",
                        "purchase.pending-payment.v1", "nodeSelection.binding.v1.fixture",
                        "Library/Preferences/settings.plist", "Library/Caches/subscription-cache.json",
                        "Library/Application Support/NetworkClient/DeveloperDiagnostics/events.jsonl"]
        let sentinel = Data("synthetic-business-and-current-runtime".utf8)
        for path in retained { try f.write(path, sentinel) }
        XCTAssertEqual(try VPNObsoleteDataRemoval.remove(in: f.container), retired.count)
        for path in retired { XCTAssertFalse(FileManager.default.fileExists(atPath: f.file(path).path)) }
        for path in retained { XCTAssertEqual(try Data(contentsOf: f.file(path)), sentinel) }
    }
    func testMissingFilesAndRepeatedRemovalAreIdempotentWithoutCreatingState() throws {
        let f = try Fixture(), missing = f.root.appendingPathComponent("missing")
        XCTAssertEqual(try VPNObsoleteDataRemoval.remove(in: missing), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        try f.write("tunnel-stage.json", Data("not-a-schema".utf8))
        XCTAssertEqual(try VPNObsoleteDataRemoval.remove(in: f.container), 1)
        XCTAssertEqual(try VPNObsoleteDataRemoval.remove(in: f.container), 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.container.path).isEmpty)
    }
    func testSymlinkDirectoriesCannotDeleteExternalFilesAndFileLinksOnlyUnlinkThemselves() throws {
        for relative in ["Library", "Library/Caches"] {
            let f = try Fixture(), external = f.root.appendingPathComponent("external")
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            let sentinel = external.appendingPathComponent("developer-tunnel-events.jsonl")
            let bytes = Data("synthetic-external-sentinel".utf8); try bytes.write(to: sentinel)
            let link = f.file(relative)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
            XCTAssertThrowsError(try VPNObsoleteDataRemoval.remove(in: f.container)) {
                XCTAssertEqual(($0 as? POSIXError)?.code, .ENOTDIR)
            }
            XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), external.path)
        }
        let f = try Fixture(), external = f.root.appendingPathComponent("external-file")
        let bytes = Data("synthetic-external-file".utf8); try bytes.write(to: external)
        let link = f.file("tunnel-stage.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        XCTAssertEqual(try VPNObsoleteDataRemoval.remove(in: f.container), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
        XCTAssertEqual(try Data(contentsOf: external), bytes)
    }
    func testNearMatchesInvalidIdentifiersAndDirectoriesAreNotRemoved() throws {
        let f = try Fixture(), identifier = UUID().uuidString
        let keep = ["tunnel-stage.json.backup", "active-selection-not-a-uuid.json", "latency-batch-not-a-uuid.json",
                    "active-selection-\(identifier).json.bak", "latency-batch-\(identifier).jsonl",
                    "Library/Caches/tunnel-stage-evidence.json.backup",
                    "Library/Caches/developer-tunnel-events.jsonl.backup",
                    "Library/Caches/xroute-client-\(identifier).json", "Library/Caches/route-client-\(identifier).txt"]
        let bytes = Data("synthetic-near-match".utf8)
        for path in keep { try f.write(path, bytes) }
        let directory = f.file("active-selection-\(UUID().uuidString).json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let child = directory.appendingPathComponent("business-data")
        try bytes.write(to: child)
        XCTAssertEqual(try VPNObsoleteDataRemoval.remove(in: f.container), 0)
        for path in keep { XCTAssertEqual(try Data(contentsOf: f.file(path)), bytes) }
        XCTAssertEqual(try Data(contentsOf: child), bytes)
    }
}
