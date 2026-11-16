import Foundation

enum UserLogKey {
    static let appStarted = "user_log.app.started"
    static let configLoaded = "user_log.config.loaded"
    static let configFailed = "user_log.config.failed"
    static let loginSucceeded = "user_log.auth.login_succeeded"
    static let loginFailed = "user_log.auth.login_failed"
    static let authenticationExpired = "user_log.auth.expired"
    static let signedOut = "user_log.auth.signed_out"
    static let passwordChanged = "user_log.auth.password_changed"
    static let passwordChangeFailed = "user_log.auth.password_change_failed"
    static let accountRefreshed = "user_log.account.refreshed"
    static let accountRefreshFailed = "user_log.account.refresh_failed"
    static let connectionStarting = "user_log.proxy.connection_starting"
    static let connectionSucceeded = "user_log.proxy.connection_succeeded"
    static let connectionFailed = "user_log.proxy.connection_failed"
    static let disconnected = "user_log.proxy.disconnected"
    static let disconnectFailed = "user_log.proxy.disconnect_failed"
    static let smartModeEnabled = "user_log.proxy.smart_enabled"
    static let globalModeEnabled = "user_log.proxy.global_enabled"
    static let tunEnabled = "user_log.proxy.tun_enabled"
    static let tunDisabled = "user_log.proxy.tun_disabled"
    static let nodeSwitched = "user_log.proxy.node_switched"
    static let nodeSwitchFailed = "user_log.proxy.node_switch_failed"
    static let recoveryStarting = "user_log.recovery.starting"
    static let recoverySucceeded = "user_log.recovery.succeeded"
    static let recoveryFailed = "user_log.recovery.failed"
    static let ordersLoaded = "user_log.order.list_loaded"
    static let orderCreated = "user_log.order.created"
    static let orderUnknown = "user_log.order.unknown"
    static let orderCancelled = "user_log.order.cancelled"
    static let orderCancelFailed = "user_log.order.cancel_failed"
    static let paymentOpened = "user_log.payment.opened"
    static let paymentActivating = "user_log.payment.activating"
    static let paymentSucceeded = "user_log.payment.succeeded"
    static let paymentCheckFailed = "user_log.payment.check_failed"
    static let invitationsLoaded = "user_log.invitation.loaded"
    static let invitationCreated = "user_log.invitation.created"
    static let invitationsFailed = "user_log.invitation.failed"
    static let trafficLoaded = "user_log.traffic.loaded"
    static let trafficFailed = "user_log.traffic.failed"
    static let announcementsLoaded = "user_log.announcement.loaded"
    static let announcementsFailed = "user_log.announcement.failed"
    static let updateChecking = "user_log.update.checking"
    static let updateLatest = "user_log.update.latest"
    static let updateAvailable = "user_log.update.available"
    static let updateOpened = "user_log.update.opened"
    static let updateFailed = "user_log.update.failed"
}

enum UserLogSanitizer {
    private static let replacements: [(String, String)] = [
        (#"(?i)[\"']?\bAuthorization\b[\"']?\s*[:=]\s*(?:\"[^\"\r\n]*\"|'[^'\r\n]*')"#, "Authorization [REDACTED]"),
        (#"(?i)[\"']?\bAuthorization\b[\"']?\s*[:=]\s*(?:Bearer\s+)?[\"']?[^\s,;\"'<>]+"#, "Authorization [REDACTED]"),
        (#"(?i)[\"']?\b(?:old_password|new_password|password|passwd|pwd|auth_data|access_token|refresh_token|token|cookie|secret|uuid|email_code|verification_code)\b[\"']?\s*[:=]\s*(?:\"[^\"\r\n]*\"|'[^'\r\n]*')"#, "secret [REDACTED]"),
        (#"(?i)[\"']?\b(?:old_password|new_password|password|passwd|pwd|auth_data|access_token|refresh_token|token|cookie|secret|uuid|email_code|verification_code)\b[\"']?\s*[:=]\s*[\"']?[^\s,;&\"'<>]+"#, "secret [REDACTED]"),
        (#"(?i)[\"']?\btrade_no\b[\"']?\s*[:=]\s*[\"']?[^\s,;&\"'<>]+"#, "trade [REDACTED]"),
        (#"(?i)\b(?:https?|vless|trojan|hysteria2|hy2|tuic|vmess|ssr?|socks(?:4a?|5)?|crisp)://[^\s\"'<>，。；、)）]+"#, "[url]"),
        (#"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}\b"#, "[secret]"),
        (#"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#, "[secret]"),
        (#"\b(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\b"#, "[ip]"),
        (#"(?i)(?<![0-9a-f])(?:\[[0-9a-f:]+(?:%[a-z0-9_.-]+)?\](?::\d{1,5})?|(?:[0-9a-f]{1,4}:){7}[0-9a-f]{1,4}|[0-9a-f:]*::[0-9a-f:]*)(?:%[a-z0-9_.-]+)?(?![0-9a-f])"#, "[ip]"),
        (#"(?<!@)\b(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}(?::\d+)?\b"#, "[host]"),
        (#"\b[A-Za-z0-9_+/=-]{32,}\b"#, "[secret]"),
        (#"\b\d{12,}\b"#, "******")
    ]

    private static let emailPattern = #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#

    static func sanitize(_ value: String) -> String {
        var result = value
        if let expression = try? NSRegularExpression(
            pattern: emailPattern,
            options: [.caseInsensitive]
        ) {
            let range = NSRange(result.startIndex..., in: result)
            let matches = expression.matches(in: result, range: range).reversed()
            for match in matches {
                guard let swiftRange = Range(match.range, in: result) else { continue }
                result.replaceSubrange(swiftRange, with: maskedEmail(String(result[swiftRange])))
            }
        }

        for (pattern, replacement) in replacements {
            result = result.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func maskedEmail(_ value: String) -> String {
        guard let at = value.firstIndex(of: "@") else { return "***" }
        let local = value[..<at]
        let domain = value[at...]
        let prefix = local.prefix(local.count > 2 ? 2 : 1)
        return String(prefix) + "***" + String(domain)
    }
}

actor UserSystemLogger {
    enum ClearError: Error, Equatable {
        case deletionFailed
    }

    static let shared = UserSystemLogger()
    static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60
    static let cleanupInterval: TimeInterval = 5 * 60
    static let duplicateInterval: TimeInterval = 10
    static let maxFileBytes: Int64 = 5 * 1024 * 1024
    static let maxTotalBytes: Int64 = 50 * 1024 * 1024
    static let maxVisibleEntries = 300

    nonisolated static var defaultDirectoryURL: URL {
        let library = (try? FileManager.default.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return defaultDirectoryURL(libraryDirectory: library)
    }

    nonisolated static func defaultDirectoryURL(libraryDirectory: URL) -> URL {
        libraryDirectory
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("NetworkClient", isDirectory: true)
    }

    private let directoryURL: URL
    private let nowProvider: @Sendable () -> Date
    private let fileRemover: @Sendable (URL) throws -> Void
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileDateFormatter: DateFormatter
    private let rotationDateFormatter: DateFormatter
    private let exportDateFormatter: DateFormatter
    private var entries: [UserLogEntry] = []
    private var hasLoaded = false
    private var lastCleanupAt = Date.distantPast
    private var lastDuplicateKey: String?
    private var lastDuplicateAt = Date.distantPast
    private var continuations: [UUID: AsyncStream<[UserLogEntry]>.Continuation] = [:]

    init(
        directoryURL: URL = UserSystemLogger.defaultDirectoryURL,
        nowProvider: @escaping @Sendable () -> Date = { Date() },
        fileRemover: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.removeItem(at: $0)
        }
    ) {
        self.directoryURL = directoryURL
        self.nowProvider = nowProvider
        self.fileRemover = fileRemover
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let fileFormatter = DateFormatter()
        fileFormatter.calendar = Calendar(identifier: .gregorian)
        fileFormatter.locale = Locale(identifier: "en_US_POSIX")
        fileFormatter.timeZone = .current
        fileFormatter.dateFormat = "yyyy-MM-dd"
        fileDateFormatter = fileFormatter
        let rotationFormatter = DateFormatter()
        rotationFormatter.calendar = Calendar(identifier: .gregorian)
        rotationFormatter.locale = Locale(identifier: "en_US_POSIX")
        rotationFormatter.timeZone = .current
        rotationFormatter.dateFormat = "HHmmss"
        rotationDateFormatter = rotationFormatter
        let exportFormatter = DateFormatter()
        exportFormatter.calendar = Calendar(identifier: .gregorian)
        exportFormatter.locale = Locale(identifier: "en_US_POSIX")
        exportFormatter.timeZone = .current
        exportFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        exportDateFormatter = exportFormatter
    }

    nonisolated func log(
        _ level: UserLogLevel,
        module: UserLogModule,
        key: String,
        arguments: [String] = []
    ) {
        Task(priority: .utility) {
            await self.storeLocalized(
                level: level,
                module: module,
                key: key,
                arguments: arguments
            )
        }
    }

    func snapshots() async -> AsyncStream<[UserLogEntry]> {
        await loadIfNeeded()
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.yield(entries)
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeContinuation(id) }
            }
        }
    }

    func currentEntries() async -> [UserLogEntry] {
        await loadIfNeeded()
        return entries
    }

    func exportText() async -> String {
        await loadIfNeeded()
        return entries.map { entry in
            let timestamp = exportDateFormatter.string(from: entry.timestamp)
            return UserLogSanitizer.sanitize("\(timestamp) \(entry.message)")
        }
        .joined(separator: "\n")
    }

    func clear() async throws {
        await loadIfNeeded()
        let files: [URL]
        do {
            files = try userLogFiles()
        } catch {
            SafeLog.warning("[UserSystemLog] clear failed category=local_io")
            throw ClearError.deletionFailed
        }

        var deletionFailed = false
        for url in files {
            do {
                try fileRemover(url)
            } catch {
                deletionFailed = true
            }
        }

        if deletionFailed {
            do {
                entries = try loadEntries(
                    cutoff: nowProvider().addingTimeInterval(-Self.retentionInterval)
                )
                lastDuplicateKey = nil
                lastDuplicateAt = .distantPast
                yieldSnapshot()
            } catch {
                SafeLog.warning("[UserSystemLog] clear reload failed category=local_io")
            }
            SafeLog.warning("[UserSystemLog] clear failed category=local_io")
            throw ClearError.deletionFailed
        }

        entries.removeAll()
        lastDuplicateKey = nil
        lastDuplicateAt = .distantPast
        yieldSnapshot()
    }

    func logAndWaitForTesting(
        _ level: UserLogLevel,
        module: UserLogModule,
        message: String,
        timestamp: Date? = nil
    ) async {
        await store(
            level: level,
            module: module,
            message: message,
            timestamp: timestamp ?? nowProvider()
        )
    }

    private func store(
        level: UserLogLevel,
        module: UserLogModule,
        message: String,
        timestamp: Date
    ) async {
        await loadIfNeeded()
        if timestamp.timeIntervalSince(lastCleanupAt) >= Self.cleanupInterval {
            await performMaintenance(now: timestamp)
        }

        let safeMessage = UserLogSanitizer.sanitize(message)
        guard !safeMessage.isEmpty else { return }
        let duplicateKey = "\(level.rawValue)|\(module.rawValue)|\(safeMessage)"
        if duplicateKey == lastDuplicateKey,
           timestamp.timeIntervalSince(lastDuplicateAt) <= Self.duplicateInterval {
            return
        }
        lastDuplicateKey = duplicateKey
        lastDuplicateAt = timestamp

        let entry = UserLogEntry(
            timestamp: timestamp,
            level: level,
            module: module,
            message: safeMessage
        )
        do {
            try append(entry)
            entries.insert(entry, at: 0)
            if entries.count > Self.maxVisibleEntries {
                entries.removeLast(entries.count - Self.maxVisibleEntries)
            }
            yieldSnapshot()
        } catch {
            SafeLog.warning("[UserSystemLog] write failed category=local_io")
        }
    }

    private func storeLocalized(
        level: UserLogLevel,
        module: UserLogModule,
        key: String,
        arguments: [String]
    ) async {
        await store(
            level: level,
            module: module,
            message: localizedMessage(key: key, arguments: arguments),
            timestamp: nowProvider()
        )
    }

    private func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        let now = nowProvider()
        await performMaintenance(now: now)
    }

    private func performMaintenance(now: Date) async {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            try pruneExpiredEntries(cutoff: now.addingTimeInterval(-Self.retentionInterval))
            try enforceTotalCapacity()
            entries = try loadEntries(
                cutoff: now.addingTimeInterval(-Self.retentionInterval)
            )
            lastCleanupAt = now
            yieldSnapshot()
        } catch {
            lastCleanupAt = now
            SafeLog.warning("[UserSystemLog] maintenance failed category=local_io")
        }
    }

    private func append(_ entry: UserLogEntry) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let baseURL = directoryURL.appendingPathComponent(
            "user-\(fileDateFormatter.string(from: entry.timestamp)).jsonl"
        )
        if let attributes = try? FileManager.default.attributesOfItem(atPath: baseURL.path),
           let size = attributes[.size] as? NSNumber,
           size.int64Value >= Self.maxFileBytes {
            let rotatedURL = directoryURL.appendingPathComponent(
                "user-\(fileDateFormatter.string(from: entry.timestamp))-"
                    + "\(rotationDateFormatter.string(from: entry.timestamp))-"
                    + "\(UUID().uuidString.prefix(8)).jsonl"
            )
            try FileManager.default.moveItem(at: baseURL, to: rotatedURL)
        }

        var data = try encoder.encode(entry)
        data.append(0x0A)
        if FileManager.default.fileExists(atPath: baseURL.path) {
            let handle = try FileHandle(forWritingTo: baseURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: baseURL, options: .atomic)
        }
    }

    private func pruneExpiredEntries(cutoff: Date) throws {
        for url in try userLogFiles() {
            let original = try readEntries(from: url)
            let retained = original.filter { $0.timestamp >= cutoff }
            if retained.isEmpty {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            if retained.count != original.count {
                try writeEntries(retained, to: url)
            }
        }
    }

    private func enforceTotalCapacity() throws {
        var files = try userLogFiles().map { url -> (url: URL, size: Int64, oldest: Date) in
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let oldest = (try? readEntries(from: url).map(\.timestamp).min())
                ?? values.contentModificationDate
                ?? .distantPast
            return (url, Int64(values.fileSize ?? 0), oldest)
        }
        files.sort { $0.oldest < $1.oldest }
        var total = files.reduce(Int64(0)) { $0 + $1.size }
        for file in files where total > Self.maxTotalBytes {
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }

    private func loadEntries(cutoff: Date) throws -> [UserLogEntry] {
        var loaded: [UserLogEntry] = []
        for url in try userLogFiles() {
            loaded.append(contentsOf: try readEntries(from: url))
        }
        return loaded.filter { $0.timestamp >= cutoff }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(Self.maxVisibleEntries)
            .map { $0 }
    }

    private func readEntries(from url: URL) throws -> [UserLogEntry] {
        let data = try Data(contentsOf: url)
        return data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(UserLogEntry.self, from: Data(line))
        }
    }

    private func writeEntries(_ values: [UserLogEntry], to url: URL) throws {
        var data = Data()
        for value in values {
            data.append(try encoder.encode(value))
            data.append(0x0A)
        }
        try data.write(to: url, options: .atomic)
    }

    private func userLogFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.lastPathComponent.hasPrefix("user-") && $0.pathExtension == "jsonl" }
    }

    private func localizedMessage(key: String, arguments: [String]) -> String {
        let preference = UserDefaults.standard.string(forKey: "preferredLanguage")
        let language = preference == "zh-Hans" || preference == "en" ? preference : nil
        let bundle: Bundle
        if let language,
           let path = Bundle.main.path(forResource: language, ofType: "lproj"),
           let localizedBundle = Bundle(path: path) {
            bundle = localizedBundle
        } else {
            bundle = .main
        }
        let format = bundle.localizedString(forKey: key, value: key, table: nil)
        guard !arguments.isEmpty else { return format }
        let locale = language.map(Locale.init(identifier:)) ?? .autoupdatingCurrent
        return String(
            format: format,
            locale: locale,
            arguments: arguments.map { $0 as NSString }
        )
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func yieldSnapshot() {
        for continuation in continuations.values {
            continuation.yield(entries)
        }
    }

}
