import Foundation

/// Product traffic formatting shared by views without leaking byte arithmetic into UI code.
enum TrafficFormatter {
    private static let bytesPerGigabyte = 1_073_741_824.0
    private static let units = ["B", "KB", "MB", "GB", "TB"]

    static func gigabytes(_ bytes: Int64, locale: Locale = .current) -> FormattedTraffic {
        let nonnegativeBytes = max(0, bytes)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = false
        return FormattedTraffic(
            value: formatter.string(from: NSNumber(value: Double(nonnegativeBytes) / bytesPerGigabyte)) ?? "0.00",
            unit: "GB"
        )
    }

    static func adaptive(_ bytes: Int64, locale: Locale) -> FormattedTraffic {
        var value = Double(max(0, bytes))
        var unitIndex = 0
        while value >= 1_024, unitIndex < units.count - 1 {
            value /= 1_024
            unitIndex += 1
        }

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = unitIndex == 0 ? 0 : 2
        formatter.usesGroupingSeparator = false
        return FormattedTraffic(
            value: formatter.string(from: NSNumber(value: value)) ?? "0",
            unit: units[unitIndex]
        )
    }
}

enum TrafficDateFormatter {
    static func day(
        unixSeconds: Int64,
        locale: Locale,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = locale.language.languageCode?.identifier == "zh"
            ? "yyyy/MM/dd"
            : "MM/dd/yyyy"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(unixSeconds)))
    }
}
