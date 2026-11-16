import XCTest
@testable import NetworkClient

final class MihomoTunnelControlTests: XCTestCase {
    func testCurrentSchemaVersionIsOne() {
        XCTAssertEqual(MihomoTunnelControlRequest.currentSchemaVersion, 1)
    }

    func testSwitchNodeRoundTripKeepsOnlyFinitePayload() throws {
        let id = UUID(), revision = String(repeating: "a", count: 64)
        let value = MihomoTunnelControlRequest(
            requestID: id, command: .switchNode,
            payload: .init(targetCoreName: "synthetic-core",
                           candidatePoolRevision: revision)
        )
        let decoded = try XCTUnwrap(MihomoTunnelControlCodec.decodeRequest(
            try MihomoTunnelControlCodec.encode(value)
        ))
        XCTAssertEqual(decoded, value)
        XCTAssertTrue(decoded.isWellFormed)
        XCTAssertEqual(decoded.knownCommand, .switchNode)
    }

    func testSwitchModeRoundTripAcceptsOnlyRuleOrGlobal() throws {
        for mode in ["rule", "global"] {
            let value = MihomoTunnelControlRequest(
                command: .switchMode, payload: .init(mode: mode)
            )
            XCTAssertEqual(
                MihomoTunnelControlCodec.decodeRequest(
                    try MihomoTunnelControlCodec.encode(value)
                ), value
            )
            XCTAssertTrue(value.isWellFormed)
        }
        XCTAssertFalse(MihomoTunnelControlRequest(
            command: .switchMode, payload: .init(mode: "direct")
        ).isWellFormed)
    }

    func testTrafficSnapshotHasNoPayload() throws {
        let value = MihomoTunnelControlRequest(command: .trafficSnapshot)
        XCTAssertTrue(value.isWellFormed)
        XCTAssertNil(try XCTUnwrap(MihomoTunnelControlCodec.decodeRequest(
            MihomoTunnelControlCodec.encode(value)
        )).payload)
    }

    func testStep261ProbeNodesRoundTripHasOnlyFiniteCandidateNames() throws {
        let revision = String(repeating: "a", count: 64)
        let value = MihomoTunnelControlRequest(
            command: .probeNodes,
            payload: .init(
                candidatePoolRevision: revision,
                probeCoreNames: ["core-a", "core-b"]
            )
        )
        let encoded = try MihomoTunnelControlCodec.encode(value)
        let decoded = try XCTUnwrap(MihomoTunnelControlCodec.decodeRequest(encoded))
        XCTAssertEqual(decoded, value)
        XCTAssertTrue(decoded.isWellFormed)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        XCTAssertEqual(Set(payload.keys), ["candidatePoolRevision", "probeCoreNames"])
        XCTAssertNil(payload["url"])
        XCTAssertNil(payload["operation"])
    }

    func testStep261ProbeNodesRejectsEmptyDuplicateAndOversizedTargets() {
        XCTAssertFalse(MihomoTunnelControlRequest(
            command: .probeNodes, payload: .init(probeCoreNames: [])
        ).isWellFormed)
        XCTAssertFalse(MihomoTunnelControlRequest(
            command: .probeNodes,
            payload: .init(probeCoreNames: ["core-a", "core-a"])
        ).isWellFormed)
        XCTAssertFalse(MihomoTunnelControlRequest(
            command: .probeNodes,
            payload: .init(probeCoreNames: (0...MihomoTunnelControlRequest.maximumProbeTargets).map {
                "core-\($0)"
            })
        ).isWellFormed)
        XCTAssertFalse(MihomoTunnelControlRequest(
            command: .probeNodes,
            payload: .init(probeCoreNames: [String(repeating: "a", count: 257)])
        ).isWellFormed)
    }

    func testStep261ProbeResponseRoundTripKeepsOnlyDelayAndStatus() throws {
        let value = MihomoTunnelControlResponse(
            requestID: UUID(),
            result: .init(status: .applied, nodeProbeResults: [
                .init(coreName: "core-a", status: .measured, delayMilliseconds: 41),
                .init(coreName: "core-b", status: .timedOut),
            ])
        )
        let data = try XCTUnwrap(MihomoTunnelControlCodec.encode(value))
        XCTAssertEqual(MihomoTunnelControlCodec.decodeResponse(data), value)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("http://"))
        XCTAssertFalse(text.contains("https://"))
        XCTAssertFalse(text.contains("server"))
    }

    func testResponseRoundTripKeepsTrafficAndIdentity() throws {
        let id = UUID()
        let value = MihomoTunnelControlResponse(
            requestID: id,
            result: .init(status: .applied,
                          uploadBytesPerSecond: 123,
                          downloadBytesPerSecond: 456,
                          sampledAtUnixMilliseconds: 789)
        )
        let encoded = try XCTUnwrap(MihomoTunnelControlCodec.encode(value))
        XCTAssertEqual(MihomoTunnelControlCodec.decodeResponse(encoded), value)
    }

    func testUnknownCommandIsNotMappedToAnyCoreOperation() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "requestID": UUID().uuidString,
            "command": "reload",
        ])
        let request = try XCTUnwrap(MihomoTunnelControlCodec.decodeRequest(data))
        XCTAssertNil(request.knownCommand)
        XCTAssertTrue(request.isWellFormed)
    }

    func testMalformedAndOversizedRequestsAreRejectedSafely() {
        XCTAssertNil(MihomoTunnelControlCodec.decodeRequest(Data("{".utf8)))
        XCTAssertNil(MihomoTunnelControlCodec.decodeRequest(
            Data(repeating: 0x61,
                 count: MihomoTunnelControlRequest.maximumMessageBytes + 1)
        ))
    }

    func testNodePayloadRejectsEmptyTargetAndInvalidRevision() {
        XCTAssertFalse(MihomoTunnelControlRequest(
            command: .switchNode, payload: .init(targetCoreName: "")
        ).isWellFormed)
        XCTAssertFalse(MihomoTunnelControlRequest(
            command: .switchNode,
            payload: .init(targetCoreName: "synthetic", candidatePoolRevision: "bad")
        ).isWellFormed)
    }
}
