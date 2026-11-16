import Foundation

struct ProfileInviteCode: Identifiable, Sendable, Equatable {
    let id: Int
    let code: String
    let status: Int
    let pageViews: Int
    let createdAtUnix: Int64?
}

struct ProfileInviteInfo: Sendable, Equatable {
    let codes: [ProfileInviteCode]
    let registeredCount: Int
    let validCommissionCents: Int64
    let pendingCommissionCents: Int64
    let commissionRate: Int
    let availableCommissionCents: Int64
}

enum ProfileInviteLinkBuilder {
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    static func url(inviteLink: String?, code: String) -> URL? {
        guard let prefix = inviteLink?.trimmed.nilIfEmpty,
              prefix.unicodeScalars.allSatisfy(\.isASCII),
              let components = URLComponents(string: prefix),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.isEmpty == false,
              let code = code.trimmed.nilIfEmpty,
              let encodedCode = code.addingPercentEncoding(withAllowedCharacters: unreserved)
        else { return nil }

        // InviteLink is a server-controlled prefix. Match the desktop client:
        // encode only the code, then append it without inventing a separator.
        return URL(string: prefix + encodedCode)
    }
}

struct ProfileTrafficLogRecord: Sendable, Equatable {
    let uploadBytes: Int64
    let downloadBytes: Int64
    let recordAtUnix: Int64
    let serverRate: Double
}

struct ProfileDailyTraffic: Identifiable, Sendable, Equatable {
    let recordAtUnix: Int64
    let uploadBytes: Int64
    let downloadBytes: Int64

    var id: Int64 { recordAtUnix }

    var totalBytes: Int64 {
        let result = uploadBytes.addingReportingOverflow(downloadBytes)
        return result.overflow ? Int64.max : result.partialValue
    }
}

enum ProfileTrafficState: Equatable {
    case idle
    case loading
    case loaded
    case empty
    case stale(LocalizedMessage)
    case failed(LocalizedMessage)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var failureMessage: LocalizedMessage? {
        switch self {
        case let .stale(message), let .failed(message): message
        default: nil
        }
    }
}

enum ProfileTrafficAggregation {
    static func daily(
        _ records: [ProfileTrafficLogRecord],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [ProfileDailyTraffic] {
        var totals: [Date: (upload: Int64, download: Int64)] = [:]
        for record in records {
            let date = Date(timeIntervalSince1970: TimeInterval(record.recordAtUnix))
            let day = calendar.startOfDay(for: date)
            let current = totals[day, default: (upload: 0, download: 0)]
            totals[day] = (
                upload: addingClamped(current.upload, max(0, record.uploadBytes)),
                download: addingClamped(current.download, max(0, record.downloadBytes))
            )
        }

        return totals.map { day, traffic in
            ProfileDailyTraffic(
                recordAtUnix: Int64(day.timeIntervalSince1970),
                uploadBytes: traffic.upload,
                downloadBytes: traffic.download
            )
        }
        .sorted { $0.recordAtUnix > $1.recordAtUnix }
    }

    private static func addingClamped(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int64.max : result.partialValue
    }
}

enum ProfileChangePasswordState: Equatable {
    case idle
    case submitting
    case succeeded
    case failed(LocalizedMessage)
}

enum ProfileAccountDeletionRequestState: Equatable {
    case idle
    case submitting
    case failed(LocalizedMessage)
}
