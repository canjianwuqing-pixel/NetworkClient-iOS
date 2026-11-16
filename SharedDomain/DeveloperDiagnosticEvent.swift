#if DEBUG
import Foundation

enum DeveloperDiagnosticModule: String, Codable, Sendable, CaseIterable {
    case app
    case configuration
    case apiHealth = "api_health"
    case api
    case recovery
    case subscription
    case vpn
    case userInterface = "ui"
}

enum DeveloperDiagnosticLevel: String, Codable, Sendable, CaseIterable {
    case info
    case success
    case warning
    case error
}

struct DeveloperDiagnosticEvent: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let timestamp: Date
    let operationID: String
    let module: DeveloperDiagnosticModule
    let level: DeveloperDiagnosticLevel
    let stage: String
    let outcome: String
    let elapsedMilliseconds: Int?
    let timeoutMilliseconds: Int?
    let httpStatus: Int?
    let urlErrorCode: Int?
    let attempt: Int?
    let route: String?
    let generation: String?
    let cancelled: Bool
    let superseded: Bool
    let detail: String?

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, operationID, module, level, stage, outcome, elapsedMilliseconds
        case timeoutMilliseconds, httpStatus, urlErrorCode, attempt, route, generation, cancelled, superseded, detail
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let identity = try c.decode(String.self, forKey: .id)
        if let uuid = UUID(uuidString: identity) { id = uuid }
        else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Invalid diagnostic identity")
        }
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        operationID = try c.decode(String.self, forKey: .operationID)
        module = try c.decode(DeveloperDiagnosticModule.self, forKey: .module)
        level = try c.decode(DeveloperDiagnosticLevel.self, forKey: .level)
        stage = try c.decode(String.self, forKey: .stage)
        outcome = try c.decode(String.self, forKey: .outcome)
        elapsedMilliseconds = try c.decodeIfPresent(Int.self, forKey: .elapsedMilliseconds)
        timeoutMilliseconds = try c.decodeIfPresent(Int.self, forKey: .timeoutMilliseconds)
        httpStatus = try c.decodeIfPresent(Int.self, forKey: .httpStatus)
        urlErrorCode = try c.decodeIfPresent(Int.self, forKey: .urlErrorCode)
        attempt = try c.decodeIfPresent(Int.self, forKey: .attempt)
        route = try c.decodeIfPresent(String.self, forKey: .route)
        generation = try c.decodeIfPresent(String.self, forKey: .generation)
        cancelled = try c.decode(Bool.self, forKey: .cancelled)
        superseded = try c.decode(Bool.self, forKey: .superseded)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(operationID, forKey: .operationID)
        try c.encode(module, forKey: .module)
        try c.encode(level, forKey: .level)
        try c.encode(stage, forKey: .stage)
        try c.encode(outcome, forKey: .outcome)
        try c.encodeIfPresent(elapsedMilliseconds, forKey: .elapsedMilliseconds)
        try c.encodeIfPresent(timeoutMilliseconds, forKey: .timeoutMilliseconds)
        try c.encodeIfPresent(httpStatus, forKey: .httpStatus)
        try c.encodeIfPresent(urlErrorCode, forKey: .urlErrorCode)
        try c.encodeIfPresent(attempt, forKey: .attempt)
        try c.encodeIfPresent(route, forKey: .route)
        try c.encodeIfPresent(generation, forKey: .generation)
        try c.encode(cancelled, forKey: .cancelled)
        try c.encode(superseded, forKey: .superseded)
        try c.encodeIfPresent(detail, forKey: .detail)
    }

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        operationID: String,
        module: DeveloperDiagnosticModule,
        level: DeveloperDiagnosticLevel = .info,
        stage: String,
        outcome: String,
        elapsedMilliseconds: Int? = nil,
        timeoutMilliseconds: Int? = nil,
        httpStatus: Int? = nil,
        urlErrorCode: Int? = nil,
        attempt: Int? = nil,
        route: String? = nil,
        generation: String? = nil,
        cancelled: Bool = false,
        superseded: Bool = false,
        detail: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.operationID = operationID
        self.module = module
        self.level = level
        self.stage = stage
        self.outcome = outcome
        self.elapsedMilliseconds = elapsedMilliseconds
        self.timeoutMilliseconds = timeoutMilliseconds
        self.httpStatus = httpStatus
        self.urlErrorCode = urlErrorCode
        self.attempt = attempt
        self.route = route
        self.generation = generation
        self.cancelled = cancelled
        self.superseded = superseded
        self.detail = detail
    }
}

enum DeveloperDiagnosticOperation {
    static func make(_ prefix: String) -> String {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)
        return "\(prefix)-\(suffix)"
    }
}
#endif
