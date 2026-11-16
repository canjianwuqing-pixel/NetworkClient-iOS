import Foundation

/// Resolves node location visuals without changing node identity or persistence data.
enum CountryFlagResolver {
    enum Visual: Equatable {
        case taiwanImage
        case emoji(String)
    }
    private static let availableCodes = Set(Locale.Region.isoRegions.map(\.identifier).filter {
        $0.unicodeScalars.count == 2 &&
        $0.unicodeScalars.allSatisfy { (65...90).contains($0.value) }
    } + ["XK"])

    private static let codeAliases: [String: String] = [
        "UK": "GB",
        "GBR": "GB",
        "USA": "US",
        "HKG": "HK",
        "TWN": "TW",
        "MAC": "MO",
        "JPN": "JP",
        "KOR": "KR",
        "SGP": "SG",
        "VNM": "VN",
        "THA": "TH",
        "UAE": "AE",
        "KSA": "SA",
        "DPRK": "KP"
    ]

    /// City and alternate-name aliases mirror the Windows resolver's maintained rules.
    private static let nameAliases: [(code: String, aliases: [String])] = [
        ("CN", ["中国大陆", "大陆", "大陸", "Mainland", "北京", "上海", "广州", "深圳", "杭州", "成都", "重庆", "青岛", "南京", "武汉", "PEK", "PVG", "CAN", "SZX"]),
        ("HK", ["香港", "Hong Kong", "HONGKONG", "HKG", "九龙", "九龍"]),
        ("TW", ["台湾", "台灣", "臺灣", "Taiwan", "Taipei", "台北", "高雄", "TPE", "KHH"]),
        ("MO", ["澳门", "澳門", "Macao", "Macau", "MFM"]),
        ("JP", ["日本", "Japan", "Tokyo", "东京", "東京", "Osaka", "大阪", "Nagoya", "名古屋", "Fukuoka", "福冈", "福岡", "Sapporo", "札幌", "NRT", "HND", "KIX"]),
        ("KR", ["韩国", "韓國", "南韩", "南韓", "Korea", "South Korea", "Republic of Korea", "Seoul", "首尔", "首爾", "Busan", "釜山", "ICN", "GMP"]),
        ("KP", ["朝鲜", "北朝鲜", "北韓", "North Korea", "DPRK"]),
        ("SG", ["新加坡", "Singapore", "狮城", "獅城", "SIN"]),
        ("MY", ["马来西亚", "Malaysia", "Kuala Lumpur", "吉隆坡", "KUL"]),
        ("TH", ["泰国", "Thailand", "Bangkok", "曼谷", "BKK"]),
        ("KH", ["柬埔寨", "Cambodia", "Kampuchea"]),
        ("VN", ["越南", "Vietnam", "Viet Nam", "Hanoi", "河内", "河內", "Ho Chi Minh", "胡志明"]),
        ("PH", ["菲律宾", "Philippines", "Manila", "马尼拉", "馬尼拉", "MNL"]),
        ("ID", ["印度尼西亚", "Indonesia", "印尼", "Jakarta", "雅加达", "雅加達"]),
        ("IN", ["印度", "India", "Mumbai", "孟买", "孟買", "Delhi", "德里", "Chennai", "Bangalore", "班加罗尔"]),
        ("AE", ["阿联酋", "阿聯酋", "UAE", "Dubai", "迪拜", "Abu Dhabi", "阿布扎比", "DXB"]),
        ("SA", ["沙特", "沙特阿拉伯", "Saudi", "Saudi Arabia", "KSA"]),
        ("TR", ["土耳其", "Türkiye", "Turkey", "Istanbul", "伊斯坦布尔", "伊斯坦堡"]),
        ("US", ["美国", "United States", "USA", "America", "Los Angeles", "洛杉矶", "洛杉磯", "San Jose", "圣何塞", "聖荷西", "Seattle", "西雅图", "西雅圖", "New York", "纽约", "紐約", "Chicago", "芝加哥", "Dallas", "达拉斯", "達拉斯", "Miami", "迈阿密", "邁阿密", "Washington", "华盛顿", "華盛頓", "Silicon Valley", "硅谷", "矽谷", "LAX", "SJC", "SFO", "SEA", "JFK", "IAD", "ORD", "DFW"]),
        ("CA", ["加拿大", "Canada", "Toronto", "多伦多", "多倫多", "Vancouver", "温哥华", "溫哥華", "Montreal", "蒙特利尔", "蒙特利爾", "YYZ", "YVR"]),
        ("MX", ["墨西哥", "Mexico", "Mexico City", "墨西哥城"]),
        ("BR", ["巴西", "Brazil", "São Paulo", "Sao Paulo", "圣保罗", "聖保羅", "Rio de Janeiro", "里约", "里約"]),
        ("AR", ["阿根廷", "Argentina", "Buenos Aires", "布宜诺斯艾利斯", "布宜諾斯艾利斯"]),
        ("CL", ["智利", "Chile", "Santiago", "圣地亚哥", "聖地牙哥"]),
        ("CO", ["哥伦比亚", "Colombia", "Bogota", "Bogotá", "波哥大"]),
        ("GB", ["英国", "United Kingdom", "UK", "Great Britain", "Britain", "England", "London", "伦敦", "倫敦", "Manchester", "曼彻斯特", "曼徹斯特", "LHR"]),
        ("IE", ["爱尔兰", "Ireland", "Dublin", "都柏林"]),
        ("FR", ["法国", "France", "Paris", "巴黎", "Marseille", "马赛", "馬賽", "CDG"]),
        ("DE", ["德国", "Germany", "Frankfurt", "法兰克福", "法蘭克福", "Berlin", "柏林", "Munich", "慕尼黑", "FRA"]),
        ("NL", ["荷兰", "Netherlands", "Holland", "Amsterdam", "阿姆斯特丹", "AMS"]),
        ("BE", ["比利时", "Belgium", "Brussels", "布鲁塞尔", "布魯塞爾"]),
        ("CH", ["瑞士", "Switzerland", "Zurich", "苏黎世", "蘇黎世", "Geneva", "日内瓦", "日內瓦"]),
        ("AT", ["奥地利", "Austria", "Vienna", "维也纳", "維也納"]),
        ("IT", ["意大利", "Italy", "Milan", "米兰", "米蘭", "Rome", "罗马", "羅馬"]),
        ("ES", ["西班牙", "Spain", "Madrid", "马德里", "Barcelona", "巴塞罗那", "巴塞隆納"]),
        ("PT", ["葡萄牙", "Portugal", "Lisbon", "里斯本"]),
        ("CZ", ["捷克", "Czechia", "Czech Republic", "Prague", "布拉格"]),
        ("PL", ["波兰", "Poland", "Warsaw", "华沙", "華沙"]),
        ("FI", ["芬兰", "Finland", "Helsinki", "赫尔辛基", "赫爾辛基"]),
        ("SE", ["瑞典", "Sweden", "Stockholm", "斯德哥尔摩", "斯德哥爾摩"]),
        ("NO", ["挪威", "Norway", "Oslo", "奥斯陆", "奧斯陸"]),
        ("DK", ["丹麦", "Denmark", "Copenhagen", "哥本哈根"]),
        ("RU", ["俄罗斯", "Russia", "Russian Federation", "Moscow", "莫斯科", "Saint Petersburg", "圣彼得堡", "聖彼得堡"]),
        ("UA", ["乌克兰", "Ukraine", "Kyiv", "Kiev", "基辅", "基輔"]),
        ("AU", ["澳大利亚", "Australia", "澳洲", "Sydney", "悉尼", "雪梨", "Melbourne", "墨尔本", "墨爾本", "Brisbane", "布里斯班"]),
        ("NZ", ["新西兰", "New Zealand", "Auckland", "奥克兰", "奧克蘭"]),
        ("ZA", ["南非", "South Africa", "Johannesburg", "约翰内斯堡", "約翰尼斯堡", "Cape Town", "开普敦", "開普敦"]),
        ("EG", ["埃及", "Egypt", "Cairo", "开罗", "開羅"]),
        ("MA", ["摩洛哥", "Morocco", "Casablanca", "卡萨布兰卡", "卡薩布蘭卡"]),
        ("NG", ["尼日利亚", "Nigeria", "Lagos", "拉各斯"]),
        ("KE", ["肯尼亚", "Kenya", "Nairobi", "内罗毕", "奈洛比"]),
        ("XK", ["Kosovo", "科索沃"])
    ]

    private struct NameEntry: Sendable {
        let code: String
        let words: [String]
        let compact: String
        let hasNonASCII: Bool
        let priority: Int

        var length: Int { compact.count }
    }

    private enum CharacterKind {
        case asciiLetter
        case otherLetter
        case digit
    }

    private static let namesByLength = makeNameEntries(availableCodes: availableCodes)

    static func resolvedCode(countryCode: String?, nodeName: String) -> String? {
        let nameCode = Self.countryCode(from: nodeName)
        if nameCode == "TW" { return "TW" }
        if Self.codeFromFlagEmoji(nodeName) != nil, let nameCode { return nameCode }
        if let direct = normalizedCode(countryCode), availableCodes.contains(direct) {
            return direct
        }
        return nameCode
    }

    static func countryCode(from nodeName: String) -> String? {
        resolve(nodeName, availableCodes: availableCodes, names: namesByLength)
    }

    static func flagEmoji(countryCode: String?, nodeName: String) -> String {
        guard let code = resolvedCode(countryCode: countryCode, nodeName: nodeName) else {
            return "🌐"
        }
        let scalars = code.unicodeScalars.compactMap { scalar -> UnicodeScalar? in
            guard (65...90).contains(scalar.value) else { return nil }
            return UnicodeScalar(0x1F1E6 + scalar.value - 65)
        }
        guard scalars.count == 2 else { return "🌐" }
        return String(String.UnicodeScalarView(scalars))
    }

    static func visual(countryCode: String?, nodeName: String) -> Visual {
        if resolvedCode(countryCode: countryCode, nodeName: nodeName) == "TW" {
            return .taiwanImage
        }
        return .emoji(flagEmoji(countryCode: countryCode, nodeName: nodeName))
    }

    private static func resolve(
        _ nodeName: String,
        availableCodes: Set<String>,
        names: [NameEntry]
    ) -> String? {
        if let code = codeFromFlagEmoji(nodeName), availableCodes.contains(code) {
            return code
        }
        let normalizedName = normalizedName(nodeName)
        let words = normalizedName.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }

        // A leading country token is explicit in common subscription naming schemes.
        if let first = words.first,
           let code = normalizedCode(first),
           availableCodes.contains(code),
           !leadingWordIsAbbreviation(first, in: nodeName) {
            return code
        }

        let compactName = normalizedName.replacingOccurrences(of: " ", with: "")
        for entry in names where matches(entry, words: words, compactName: compactName) {
            return entry.code
        }

        // Remaining ISO codes must be complete tokens, never substrings of names.
        for word in words.dropFirst() {
            if let code = normalizedCode(word), availableCodes.contains(code) {
                return code
            }
        }

        return nil
    }

    private static func leadingWordIsAbbreviation(_ word: String, in name: String) -> Bool {
        // CLDR names such as "St. Lucia" and "So. Georgia" must be matched as
        // full region names, rather than as the ST and SO country-code tokens.
        let leadingText = String(name.drop(while: { !$0.isLetter }))
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        return leadingText.hasPrefix(word + ".")
    }

    private static func codeFromFlagEmoji(_ name: String) -> String? {
        let scalars = Array(name.unicodeScalars)
        guard scalars.count >= 2 else { return nil }
        for index in 0..<(scalars.count - 1) {
            let first = scalars[index].value
            let second = scalars[index + 1].value
            guard (0x1F1E6...0x1F1FF).contains(first),
                  (0x1F1E6...0x1F1FF).contains(second) else { continue }
            let a = UnicodeScalar(65 + first - 0x1F1E6)!
            let b = UnicodeScalar(65 + second - 0x1F1E6)!
            let code = String(String.UnicodeScalarView([a, b]))
            if availableCodes.contains(code) { return code }
        }
        return nil
    }

    private static func makeNameEntries(availableCodes: Set<String>) -> [NameEntry] {
        var entries: [NameEntry] = []

        for item in nameAliases where availableCodes.contains(item.code) {
            for alias in item.aliases {
                if let entry = nameEntry(code: item.code, alias: alias, priority: 0) {
                    entries.append(entry)
                }
            }
        }

        let standardCodes = Set(Locale.Region.isoRegions.map(\.identifier).map { $0.uppercased() })
        let locales = [Locale(identifier: "en_US"), Locale(identifier: "zh_Hans_CN"),
                       Locale(identifier: "zh_Hant_TW")]
        for code in availableCodes.intersection(standardCodes).sorted() {
            for locale in locales {
                guard let name = locale.localizedString(forRegionCode: code),
                      name.caseInsensitiveCompare(code) != .orderedSame,
                      let entry = nameEntry(code: code, alias: name, priority: 1) else {
                    continue
                }
                entries.append(entry)
            }
        }

        return entries.sorted {
            if $0.length != $1.length { return $0.length > $1.length }
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            if $0.code != $1.code { return $0.code < $1.code }
            return $0.compact < $1.compact
        }
    }

    private static func nameEntry(code: String, alias: String, priority: Int) -> NameEntry? {
        let normalized = normalizedName(alias)
        let words = normalized.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }
        let compact = words.joined()
        return NameEntry(
            code: code,
            words: words,
            compact: compact,
            hasNonASCII: compact.unicodeScalars.contains { $0.value > 127 },
            priority: priority
        )
    }

    private static func matches(_ entry: NameEntry, words: [String], compactName: String) -> Bool {
        if entry.hasNonASCII {
            return compactName.contains(entry.compact)
        }
        guard entry.words.count <= words.count else { return false }
        for start in 0...(words.count - entry.words.count) {
            if words[start..<(start + entry.words.count)].elementsEqual(entry.words) {
                return true
            }
        }
        return false
    }

    private static func normalizedName(_ rawValue: String) -> String {
        let folded = rawValue
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        var result = ""
        var previousKind: CharacterKind?

        for scalar in folded.unicodeScalars {
            let kind: CharacterKind?
            if CharacterSet.letters.contains(scalar) {
                kind = scalar.value < 128 ? .asciiLetter : .otherLetter
            } else if CharacterSet.decimalDigits.contains(scalar) {
                kind = .digit
            } else {
                kind = nil
            }

            guard let kind else {
                if !result.isEmpty && !result.hasSuffix(" ") { result.append(" ") }
                previousKind = nil
                continue
            }
            if let previousKind, previousKind != kind,
               !result.isEmpty && !result.hasSuffix(" ") {
                result.append(" ")
            }
            result.unicodeScalars.append(scalar)
            previousKind = kind
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func normalizedCode(_ rawValue: String?) -> String? {
        guard let value = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased(),
            !value.isEmpty else {
            return nil
        }

        if let alias = codeAliases[value] {
            return alias
        }

        guard value.count == 2,
              value.unicodeScalars.allSatisfy({ (65...90).contains($0.value) }) else {
            return nil
        }
        return value
    }
}
