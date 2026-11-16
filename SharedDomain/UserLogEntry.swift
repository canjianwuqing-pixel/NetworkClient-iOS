import Foundation

enum UserLogLevel: String, Codable, Sendable {
    case info
    case success
    case warning
    case error
}

enum UserLogModule: String, Codable, Sendable {
    case app = "APP"
    case config = "CONFIG"
    case auth = "AUTH"
    case account = "ACCOUNT"
    case proxy = "PROXY"
    case recovery = "RECOVERY"
    case order = "ORDER"
    case payment = "PAYMENT"
    case invitation = "INVITATION"
    case traffic = "TRAFFIC"
    case announcement = "ANNOUNCEMENT"
    case update = "UPDATE"
}

struct UserLogEntry: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let timestamp: Date
    let level: UserLogLevel
    let module: UserLogModule
    let message: String

    init(
        id: UUID = UUID(),
        timestamp: Date,
        level: UserLogLevel,
        module: UserLogModule,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.module = module
        self.message = message
    }
}
