import Foundation
import OSLog

enum SafeLog {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "NetworkClient",
        category: "Client"
    )

    static func info(_ message: String) {
        let safeMessage = UserLogSanitizer.sanitize(sanitize(message))
        logger.info("\(safeMessage, privacy: .public)")
        #if DEBUG
        print("[Client] \(safeMessage)")
        #endif
    }

    static func warning(_ message: String) {
        let safeMessage = UserLogSanitizer.sanitize(sanitize(message))
        logger.warning("\(safeMessage, privacy: .public)")
        #if DEBUG
        print("[Client][warning] \(safeMessage)")
        #endif
    }

    static func sanitize(_ value: String) -> String {
        var result = value
        result = result.replacingOccurrences(
            of: "(?i)(authorization\\s*[:=]\\s*)(bearer\\s+)?([^\\s,;]+)",
            with: "$1$2[redacted]",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "(?i)(\\b(?:token|auth_data|password|passwd|pwd|session|secret|key)\\b\\s*[:=]\\s*)\\\"?([^\\\"\\s,;&}]+)\\\"?",
            with: "$1[redacted]",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}",
            with: "[email]",
            options: .regularExpression
        )
        return result
    }
}
