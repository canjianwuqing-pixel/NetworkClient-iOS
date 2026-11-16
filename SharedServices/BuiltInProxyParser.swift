import CoreFoundation
import Foundation

enum BuiltInProxyParser {
    private static let supportedVmessNetworks = Set(["tcp", "ws", "grpc"])

    static func parseMany(_ values: [String]) -> [BuiltInProxyEndpoint] {
        var seen = Set<String>()
        var endpoints: [BuiltInProxyEndpoint] = []
        endpoints.reserveCapacity(values.count)

        for value in values {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let endpoint = try? parse(text) else { continue }
            guard seen.insert(endpoint.normalizedValue).inserted else { continue }
            endpoints.append(endpoint)
        }

        return endpoints
    }

    static func parse(_ value: String) throws -> BuiltInProxyEndpoint {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw BuiltInProxyFormatError.invalid }

        if text.lowercased().hasPrefix("vmess://") {
            return try parseVmess(text)
        }
        if text.lowercased().hasPrefix("ss://") {
            return try parseShadowsocks(text)
        }
        throw BuiltInProxyFormatError.unsupportedScheme
    }

    private static func parseVmess(_ value: String) throws -> BuiltInProxyEndpoint {
        let encoded = stripShareDecorations(String(value.dropFirst("vmess://".count))).payload
        let decoded = try decodeBase64(encoded)
        let object = try JSONSerialization.jsonObject(with: decoded)
        guard let root = object as? [String: Any] else {
            throw BuiltInProxyFormatError.invalidVmess
        }

        let server = try requiredString(root, key: "add")
        let port = try requiredPort(root, key: "port")
        let uuidText = try requiredString(root, key: "id")
        guard let uuid = UUID(uuidString: uuidText) else {
            throw BuiltInProxyFormatError.invalidVmess
        }

        let networkText = optionalString(root, key: "net")
        let network = networkText.isEmpty ? "tcp" : networkText.lowercased()
        guard supportedVmessNetworks.contains(network) else {
            throw BuiltInProxyFormatError.invalidVmess
        }

        let tlsText = optionalString(root, key: "tls").lowercased()
        let tls: Bool
        switch tlsText {
        case "", "none": tls = false
        case "tls": tls = true
        default: throw BuiltInProxyFormatError.invalidVmess
        }

        let cipherText = optionalString(root, key: "scy")
        let cipher = cipherText.isEmpty || cipherText.caseInsensitiveCompare("auto") == .orderedSame
            ? "auto"
            : cipherText
        let settings = VmessProxySettings(
            version: optionalString(root, key: "v"),
            name: optionalString(root, key: "ps"),
            server: server,
            port: port,
            uuid: uuid,
            alterID: optionalInt(root, key: "aid") ?? 0,
            cipher: cipher,
            network: network,
            headerType: optionalString(root, key: "type"),
            host: optionalString(root, key: "host"),
            path: optionalString(root, key: "path"),
            tls: tls,
            serverName: optionalString(root, key: "sni"),
            alpn: alpn(root),
            clientFingerprint: optionalString(root, key: "fp")
        )

        return BuiltInProxyEndpoint(
            kind: .vmess,
            normalizedValue: value.trimmingCharacters(in: .whitespacesAndNewlines),
            server: server,
            port: port,
            vmess: settings,
            shadowsocks: nil
        )
    }

    private static func parseShadowsocks(_ value: String) throws -> BuiltInProxyEndpoint {
        let decorated = stripShareDecorations(String(value.dropFirst("ss://".count)))
        // Some configuration producers append `type=tcp` as import metadata.
        // TCP is already the only transport supported by this narrow SS
        // recovery mapping, so normalizing it away does not change semantics.
        // Every other option remains rejected instead of being silently lost.
        guard queryIsIgnorableShadowsocksMetadata(decorated.query) else {
            throw BuiltInProxyFormatError.invalidShadowsocks
        }

        let payload = percentDecode(decorated.payload).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { throw BuiltInProxyFormatError.invalidShadowsocks }

        let credentialsText: String
        let serverText: String
        if let separator = payload.lastIndex(of: "@"), separator != payload.startIndex {
            credentialsText = try decodeBase64OrPlain(String(payload[..<separator]))
            serverText = String(payload[payload.index(after: separator)...])
        } else {
            let decoded = try decodeBase64OrPlain(payload)
            guard let separator = decoded.lastIndex(of: "@"), separator != decoded.startIndex else {
                throw BuiltInProxyFormatError.invalidShadowsocks
            }
            credentialsText = String(decoded[..<separator])
            serverText = String(decoded[decoded.index(after: separator)...])
        }

        guard let credentialSeparator = credentialsText.firstIndex(of: ":"),
              credentialSeparator != credentialsText.startIndex else {
            throw BuiltInProxyFormatError.invalidShadowsocks
        }
        let method = percentDecode(String(credentialsText[..<credentialSeparator]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let password = percentDecode(String(credentialsText[credentialsText.index(after: credentialSeparator)...]))
        guard !method.isEmpty, !password.isEmpty else {
            throw BuiltInProxyFormatError.invalidShadowsocks
        }

        let address = try parseHostPort(serverText)
        let normalizedCredentials = base64URLNoPadding("\(method):\(password)")
        let normalizedHost = address.host.contains(":") ? "[\(address.host)]" : address.host
        let normalized = "ss://\(normalizedCredentials)@\(normalizedHost):\(address.port)"
        let settings = ShadowsocksProxySettings(
            method: method,
            password: password,
            server: address.host,
            port: address.port
        )

        return BuiltInProxyEndpoint(
            kind: .shadowsocks,
            normalizedValue: normalized,
            server: address.host,
            port: address.port,
            vmess: nil,
            shadowsocks: settings
        )
    }

    private static func stripShareDecorations(_ value: String) -> (payload: String, query: String) {
        var payload = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fragmentIndex = payload.firstIndex(of: "#") {
            payload = String(payload[..<fragmentIndex])
        }

        var query = ""
        if let queryIndex = payload.firstIndex(of: "?") {
            query = String(payload[payload.index(after: queryIndex)...])
            payload = String(payload[..<queryIndex])
        }
        return (payload.trimmingCharacters(in: .whitespacesAndNewlines), query)
    }

    private static func queryIsIgnorableShadowsocksMetadata(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return query.split(separator: "&", omittingEmptySubsequences: false).allSatisfy { item in
            let fields = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { return false }
            let key = percentDecode(String(fields[0])).lowercased()
            let value = percentDecode(String(fields[1])).lowercased()
            return key == "type" && value == "tcp"
        }
    }

    private static func decodeBase64OrPlain(_ value: String) throws -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.contains(":") ? text : try String(decoding: decodeBase64(text), as: UTF8.self)
    }

    private static func decodeBase64(_ value: String) throws -> Data {
        var normalized = value.filter { !$0.isWhitespace }
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        guard remainder != 1 else { throw BuiltInProxyFormatError.invalidBase64 }
        if remainder > 0 {
            normalized.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: normalized) else {
            throw BuiltInProxyFormatError.invalidBase64
        }
        return data
    }

    private static func requiredString(_ root: [String: Any], key: String) throws -> String {
        let value = optionalString(root, key: key)
        guard !value.isEmpty else { throw BuiltInProxyFormatError.invalidVmess }
        return value
    }

    private static func optionalString(_ root: [String: Any], key: String) -> String {
        switch root[key] {
        case let value as String:
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        case let value as NSNumber where !isBoolean(value):
            return value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            return ""
        }
    }

    private static func requiredPort(_ root: [String: Any], key: String) throws -> Int {
        guard let port = optionalInt(root, key: key), (1...65_535).contains(port) else {
            throw BuiltInProxyFormatError.invalidVmess
        }
        return port
    }

    private static func optionalInt(_ root: [String: Any], key: String) -> Int? {
        switch root[key] {
        case let value as NSNumber where !isBoolean(value):
            let number = value.doubleValue
            guard number.isFinite, number.rounded() == number else { return nil }
            return Int(exactly: number)
        case let value as String:
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private static func alpn(_ root: [String: Any]) -> [String] {
        let values: [String]
        if let array = root["alpn"] as? [Any] {
            values = array.compactMap { item in
                guard let text = item as? String else { return nil }
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else {
            values = optionalString(root, key: "alpn")
                .split(whereSeparator: { $0 == "," || $0 == "|" || $0 == ";" })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }

        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func parseHostPort(_ value: String) throws -> (host: String, port: Int) {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: "tcp://\(text)"),
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty,
              let port = components.port,
              (1...65_535).contains(port) else {
            throw BuiltInProxyFormatError.invalidShadowsocks
        }
        return (host, port)
    }

    private static func percentDecode(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }

    private static func base64URLNoPadding(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=+$", with: "", options: .regularExpression)
    }

    private static func isBoolean(_ value: NSNumber) -> Bool {
        CFGetTypeID(value) == CFBooleanGetTypeID()
    }
}

private enum BuiltInProxyFormatError: Error {
    case invalid
    case unsupportedScheme
    case invalidBase64
    case invalidVmess
    case invalidShadowsocks
}
