import Foundation

/// The Home data returned by the existing V2Board API boundary.
struct HomeAccountRefreshResult: Sendable {
    let session: UserSession
    let resolvedPlanName: String?
}

enum BusinessDataLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case empty
    case failed(LocalizedMessage)
    case stale(LocalizedMessage)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var failureMessage: LocalizedMessage? {
        switch self {
        case let .failed(message), let .stale(message): message
        default: nil
        }
    }

    var hasUsableResult: Bool {
        switch self {
        case .loaded, .empty, .stale: true
        default: false
        }
    }
}

struct HomeNotice: Identifiable, Equatable, Sendable {
    let id: Int
    let title: String
    let content: String
    let imageURL: String?
    let tags: [String]
    let createdAt: Int64

    var isImportant: Bool {
        hasTag("重要")
    }

    var isPopup: Bool {
        hasTag("弹窗")
    }

    var plainContent: String {
        HTMLPlainTextConverter.convert(content)
    }

    private func hasTag(_ expectedTag: String) -> Bool {
        tags.contains {
            $0.trimmed.caseInsensitiveCompare(expectedTag.trimmed) == .orderedSame
        }
    }
}

private enum HTMLPlainTextConverter {
    static func convert(_ html: String) -> String {
        guard !html.isEmpty else { return "" }

        var text = html.replacingOccurrences(of: "\r\n", with: "\n")
        text = replacingMatches(
            in: text,
            pattern: #"<\s*(script|style)\b[^>]*>.*?</\s*\1\s*>"#,
            with: ""
        )
        text = replacingMatches(
            in: text,
            pattern: #"<\s*br\b[^>]*>"#,
            with: "\n"
        )
        text = replacingMatches(
            in: text,
            pattern: #"</\s*(p|div|li|h[1-6]|tr)\s*>"#,
            with: "\n"
        )
        text = replacingMatches(
            in: text,
            pattern: #"<\s*li\b[^>]*>"#,
            with: "• "
        )
        text = replacingMatches(
            in: text,
            pattern: #"<\s*(p|div|h[1-6]|tr)\b[^>]*>"#,
            with: ""
        )
        text = replacingMatches(in: text, pattern: #"<[^>]+>"#, with: " ")
        text = decodeHTMLEntities(text)
            .replacingOccurrences(of: "\u{00A0}", with: " ")

        let lines = text.components(separatedBy: .newlines).map { line in
            replacingMatches(in: line, pattern: #"[ \t]+"#, with: " ")
                .trimmingCharacters(in: .whitespaces)
        }

        var normalizedLines: [String] = []
        for line in lines {
            if line.isEmpty, normalizedLines.last?.isEmpty == true {
                continue
            }
            normalizedLines.append(line)
        }

        while normalizedLines.first?.isEmpty == true {
            normalizedLines.removeFirst()
        }
        while normalizedLines.last?.isEmpty == true {
            normalizedLines.removeLast()
        }
        return normalizedLines.joined(separator: "\n")
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        var result = text
        for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        if let expression = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
            for match in expression.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let numberRange = Range(match.range(at: 1), in: result), let fullRange = Range(match.range, in: result) else { continue }
                let number = String(result[numberRange])
                let value = number.hasPrefix("x") ? UInt32(number.dropFirst(), radix: 16) : UInt32(number)
                if let value, let scalar = UnicodeScalar(value) { result.replaceSubrange(fullRange, with: String(scalar)) }
            }
        }
        return result
    }

    private static func replacingMatches(
        in text: String,
        pattern: String,
        with replacement: String
    ) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: replacement
        )
    }
}

struct FormattedTraffic: Equatable, Sendable {
    let value: String
    let unit: String

    var combined: String {
        "\(value) \(unit)"
    }
}
