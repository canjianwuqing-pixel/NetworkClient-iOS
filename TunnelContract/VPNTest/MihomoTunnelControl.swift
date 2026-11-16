import Foundation

/// The only App-to-Provider controls exposed by the production tunnel.
/// Payloads are deliberately finite; raw Core commands and configuration are
/// not part of this contract.
enum MihomoTunnelControlCommand: String, Codable, Sendable, Equatable {
    case switchNode
    case switchMode
    case trafficSnapshot
    case probeNodes
}

struct MihomoTunnelControlPayload: Codable, Sendable, Equatable {
    let targetCoreName: String?
    let candidatePoolRevision: String?
    let mode: String?
    let probeCoreNames: [String]?

    init(targetCoreName: String? = nil, candidatePoolRevision: String? = nil,
         mode: String? = nil, probeCoreNames: [String]? = nil) {
        self.targetCoreName = targetCoreName
        self.candidatePoolRevision = candidatePoolRevision
        self.mode = mode
        self.probeCoreNames = probeCoreNames
    }
}

struct MihomoTunnelControlRequest: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1
    static let maximumMessageBytes = 4_096
    static let maximumProbeTargets = 10

    let schemaVersion: Int
    let requestID: UUID
    /// Kept as a string so an unknown future command can receive a finite
    /// `unsupported` response instead of becoming an unclassified decode error.
    let command: String
    let payload: MihomoTunnelControlPayload?

    init(requestID: UUID = UUID(), command: MihomoTunnelControlCommand,
         payload: MihomoTunnelControlPayload? = nil) {
        schemaVersion = Self.currentSchemaVersion
        self.requestID = requestID
        self.command = command.rawValue
        self.payload = payload
    }

    var knownCommand: MihomoTunnelControlCommand? {
        MihomoTunnelControlCommand(rawValue: command)
    }

    var isWellFormed: Bool {
        guard schemaVersion == Self.currentSchemaVersion else { return false }
        switch knownCommand {
        case .switchNode:
            guard let target = payload?.targetCoreName else { return false }
            return !target.isEmpty && target.utf8.count <= 256
                && payload?.mode == nil
                && payload?.probeCoreNames == nil
                && (payload?.candidatePoolRevision.map(Self.validRevision) ?? true)
        case .switchMode:
            return payload?.targetCoreName == nil
                && payload?.candidatePoolRevision == nil
                && payload?.probeCoreNames == nil
                && ["rule", "global"].contains(payload?.mode)
        case .trafficSnapshot:
            return payload == nil
        case .probeNodes:
            guard payload?.targetCoreName == nil, payload?.mode == nil,
                  let names = payload?.probeCoreNames,
                  !names.isEmpty, names.count <= Self.maximumProbeTargets,
                  Set(names).count == names.count,
                  names.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else {
                return false
            }
            return payload?.candidatePoolRevision.map(Self.validRevision) ?? true
        case nil:
            return true
        }
    }

    private static func validRevision(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

enum MihomoTunnelControlStatus: String, Codable, Sendable, Equatable {
    case applied
    case noChange
    case rejected
    case targetNotLoaded
    case unavailable
    case unsupported
    case malformed
}

enum MihomoTunnelNodeProbeStatus: String, Codable, Sendable, Equatable {
    case measured
    case timedOut
    case failed
    case unavailable
    case invalidTarget
}

struct MihomoTunnelNodeProbeResult: Codable, Sendable, Equatable {
    let coreName: String
    let status: MihomoTunnelNodeProbeStatus
    let delayMilliseconds: Int?

    init(coreName: String, status: MihomoTunnelNodeProbeStatus,
         delayMilliseconds: Int? = nil) {
        self.coreName = coreName
        self.status = status
        self.delayMilliseconds = delayMilliseconds
    }
}

struct MihomoTunnelControlResult: Codable, Sendable, Equatable {
    let status: MihomoTunnelControlStatus
    let switchApplied: Bool?
    let confirmedTargetCoreName: String?
    let confirmedMode: String?
    let connectionRefreshSucceeded: Bool?
    let uploadBytesPerSecond: Int64?
    let downloadBytesPerSecond: Int64?
    let sampledAtUnixMilliseconds: Int64?
    let nodeProbeResults: [MihomoTunnelNodeProbeResult]?

    init(status: MihomoTunnelControlStatus, switchApplied: Bool? = nil,
         confirmedTargetCoreName: String? = nil, confirmedMode: String? = nil,
         connectionRefreshSucceeded: Bool? = nil,
         uploadBytesPerSecond: Int64? = nil,
         downloadBytesPerSecond: Int64? = nil,
         sampledAtUnixMilliseconds: Int64? = nil,
         nodeProbeResults: [MihomoTunnelNodeProbeResult]? = nil) {
        self.status = status
        self.switchApplied = switchApplied
        self.confirmedTargetCoreName = confirmedTargetCoreName
        self.confirmedMode = confirmedMode
        self.connectionRefreshSucceeded = connectionRefreshSucceeded
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.sampledAtUnixMilliseconds = sampledAtUnixMilliseconds
        self.nodeProbeResults = nodeProbeResults
    }
}

struct MihomoTunnelControlResponse: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let requestID: UUID?
    let result: MihomoTunnelControlResult

    init(requestID: UUID?, result: MihomoTunnelControlResult) {
        schemaVersion = MihomoTunnelControlRequest.currentSchemaVersion
        self.requestID = requestID
        self.result = result
    }
}

enum MihomoTunnelControlCodec {
    static func encode(_ request: MihomoTunnelControlRequest) throws -> Data {
        let data = try JSONEncoder().encode(request)
        guard data.count <= MihomoTunnelControlRequest.maximumMessageBytes else {
            throw EncodingError.invalidValue(request, .init(
                codingPath: [], debugDescription: "tunnel control request too large"
            ))
        }
        return data
    }

    static func decodeRequest(_ data: Data) -> MihomoTunnelControlRequest? {
        guard !data.isEmpty,
              data.count <= MihomoTunnelControlRequest.maximumMessageBytes else { return nil }
        return try? JSONDecoder().decode(MihomoTunnelControlRequest.self, from: data)
    }

    static func encode(_ response: MihomoTunnelControlResponse) -> Data? {
        guard let data = try? JSONEncoder().encode(response),
              data.count <= MihomoTunnelControlRequest.maximumMessageBytes else { return nil }
        return data
    }

    static func decodeResponse(_ data: Data) -> MihomoTunnelControlResponse? {
        guard !data.isEmpty,
              data.count <= MihomoTunnelControlRequest.maximumMessageBytes else { return nil }
        return try? JSONDecoder().decode(MihomoTunnelControlResponse.self, from: data)
    }
}
