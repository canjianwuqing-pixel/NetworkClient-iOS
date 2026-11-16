import CoreFoundation
import Foundation

enum RecoveryMappingError: Error, Equatable {
    case malformed
    case unsupportedProtocol
    case unsupportedFields([String])
    case unsupportedValue(String)
}

/// A deliberately narrow app-recovery capability. It accepts only the fields
/// that this locked Mihomo version maps below; it never treats CheckConfig as
/// proof that subscription fields were applied.
struct RecoveryNode: Sendable, Equatable {
    private static let supportedShadowsocksCiphers: Set<String> = [
        "aes-128-gcm", "aes-256-gcm",
    ]
    enum Kind: String, Sendable { case vmess, shadowsocks }
    let kind: Kind
    let server: String
    let port: Int
    let secret: String
    let cipher: String
    let alterID: Int
    let network: String
    let tls: Bool
    let serverName: String
    let alpn: [String]
    let fingerprint: String
    let wsHost: String
    let path: String

    static func parse(_ share: String) throws -> RecoveryNode {
        let text = share.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("vmess://") { return try parseVMess(String(text.dropFirst(8))) }
        if text.hasPrefix("ss://") { return try parseSS(String(text.dropFirst(5))) }
        throw RecoveryMappingError.unsupportedProtocol
    }

    private static func parseVMess(_ encoded: String) throws -> RecoveryNode {
        let decorated = String(encoded.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        guard !decorated.contains("?"), let data = decodeBase64(decorated),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw RecoveryMappingError.malformed }
        let allowed: Set<String> = ["v", "ps", "add", "port", "id", "aid", "scy", "net", "type", "host", "path", "tls", "sni", "alpn", "fp"]
        let unknown = root.keys.filter { !allowed.contains($0) }.sorted()
        guard unknown.isEmpty else { throw RecoveryMappingError.unsupportedFields(unknown) }
        for (key, value) in root {
            if key == "alpn", value is [String] { continue }
            if value is String { continue }
            if ["v", "port", "aid"].contains(key), let number = value as? NSNumber,
               CFGetTypeID(number) != CFBooleanGetTypeID() { continue }
            throw RecoveryMappingError.unsupportedValue(key)
        }
        let server = try required(root, "add")
        let shareVersion = string(root, "v")
        guard shareVersion.isEmpty || shareVersion == "2" else { throw RecoveryMappingError.unsupportedValue("v") }
        let port = try number(root, "port", range: 1...65_535)
        let uuid = try required(root, "id")
        guard UUID(uuidString: uuid) != nil else { throw RecoveryMappingError.unsupportedValue("id") }
        let alterID = try number(root, "aid", range: 0...65_535, fallback: 0)
        let cipher = string(root, "scy").isEmpty ? "auto" : string(root, "scy")
        guard cipher == "auto" else { throw RecoveryMappingError.unsupportedValue("scy") }
        let network = string(root, "net").isEmpty ? "tcp" : string(root, "net").lowercased()
        guard ["tcp", "ws", "grpc"].contains(network) else { throw RecoveryMappingError.unsupportedValue("net") }
        let headerType = string(root, "type")
        guard headerType.isEmpty || headerType == "none" else { throw RecoveryMappingError.unsupportedValue("type") }
        let tlsText = string(root, "tls").lowercased()
        guard ["", "none", "tls"].contains(tlsText) else { throw RecoveryMappingError.unsupportedValue("tls") }
        let fingerprint = string(root, "fp").lowercased()
        let fingerprints: Set<String> = ["", "none", "chrome", "firefox", "safari", "ios", "android", "edge", "360", "qq", "random"]
        guard fingerprints.contains(fingerprint) else { throw RecoveryMappingError.unsupportedValue("fp") }
        let alpn: [String]
        if let values = root["alpn"] as? [String] {
            alpn = values
        } else {
            alpn = string(root, "alpn").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        }
        guard alpn.allSatisfy({ !$0.isEmpty }) else { throw RecoveryMappingError.unsupportedValue("alpn") }
        let host = string(root, "host")
        let path = string(root, "path")
        if tlsText != "tls", (!string(root, "sni").isEmpty || !alpn.isEmpty || !fingerprint.isEmpty) {
            throw RecoveryMappingError.unsupportedValue("tls-dependent-fields")
        }
        if network == "tcp" && (!host.isEmpty || !path.isEmpty) { throw RecoveryMappingError.unsupportedValue("host/path") }
        if network == "grpc" && (!host.isEmpty || path.isEmpty) { throw RecoveryMappingError.unsupportedValue("grpc-service-name") }
        return RecoveryNode(
            kind: .vmess, server: server, port: port, secret: uuid, cipher: cipher,
            alterID: alterID, network: network, tls: tlsText == "tls",
            serverName: string(root, "sni"), alpn: alpn, fingerprint: fingerprint,
            wsHost: host, path: path
        )
    }

    private static func parseSS(_ link: String) throws -> RecoveryNode {
        var decorated = link
        if let fragment = decorated.firstIndex(of: "#") { decorated = String(decorated[..<fragment]) }
        guard !decorated.contains("?") else { throw RecoveryMappingError.unsupportedFields(["query"]) }
        guard let decodedLink = decorated.removingPercentEncoding else { throw RecoveryMappingError.malformed }
        let credentialPart: String
        let addressPart: String
        if let at = decodedLink.lastIndex(of: "@") {
            credentialPart = String(decodedLink[..<at])
            addressPart = String(decodedLink[decodedLink.index(after: at)...])
        } else {
            guard let full = decodeBase64(decodedLink).flatMap({ String(data: $0, encoding: .utf8) }),
                  let at = full.lastIndex(of: "@") else { throw RecoveryMappingError.malformed }
            credentialPart = String(full[..<at])
            addressPart = String(full[full.index(after: at)...])
        }
        let credentials = credentialPart.contains(":") ? credentialPart : String(data: decodeBase64(credentialPart) ?? Data(), encoding: .utf8) ?? ""
        guard let colon = credentials.firstIndex(of: ":"),
              let address = URLComponents(string: "tcp://\(addressPart)"),
              let host = address.host, !host.isEmpty,
              let port = address.port, (1...65_535).contains(port),
              address.user == nil, address.password == nil,
              address.path.isEmpty, address.query == nil, address.fragment == nil
        else { throw RecoveryMappingError.malformed }
        guard let cipher = String(credentials[..<colon]).removingPercentEncoding,
              let password = String(credentials[credentials.index(after: colon)...]).removingPercentEncoding
        else { throw RecoveryMappingError.malformed }
        guard supportedShadowsocksCiphers.contains(cipher), !password.isEmpty else {
            throw RecoveryMappingError.unsupportedValue("cipher/password")
        }
        return RecoveryNode(
            kind: .shadowsocks, server: host, port: port, secret: password,
            cipher: cipher, alterID: 0, network: "tcp", tls: false,
            serverName: "", alpn: [], fingerprint: "", wsHost: "", path: ""
        )
    }

    /// This template is for the app's authenticated loopback transport only.
    /// No TUN, DNS listener, external controller, LAN exposure, or certificate bypass.
    func appOnlyYAML(localPort: Int, username: String, password: String) throws -> String {
        guard (1...65_535).contains(localPort), !username.isEmpty, !password.isEmpty else {
            throw RecoveryMappingError.malformed
        }
        var rows = [
            "mode: rule", "log-level: error", "mixed-port: \(localPort)",
            "allow-lan: false", "bind-address: 127.0.0.1",
            "authentication:", "  - \(try Self.quote("\(username):\(password)"))",
            "tun:", "  enable: false", "dns:", "  enable: false",
            "proxies:", "  - name: recovery", "    type: \(kind == .vmess ? "vmess" : "ss")",
            "    server: \(try Self.quote(server))", "    port: \(port)",
        ]
        switch kind {
        case .shadowsocks:
            rows += ["    cipher: \(try Self.quote(cipher))", "    password: \(try Self.quote(secret))"]
        case .vmess:
            rows += [
                "    uuid: \(try Self.quote(secret))", "    alterId: \(alterID)",
                "    cipher: \(try Self.quote(cipher))", "    network: \(network)",
                "    tls: \(tls)",
            ]
            if !serverName.isEmpty { rows.append("    servername: \(try Self.quote(serverName))") }
            if !alpn.isEmpty { rows.append("    alpn: [\(try alpn.map(Self.quote).joined(separator: ", "))]") }
            if !fingerprint.isEmpty { rows.append("    client-fingerprint: \(try Self.quote(fingerprint))") }
            if network == "ws" {
                rows += ["    ws-opts:", "      path: \(try Self.quote(path.isEmpty ? "/" : path))"]
                if !wsHost.isEmpty { rows += ["      headers:", "        Host: \(try Self.quote(wsHost))"] }
            }
            if network == "grpc" { rows += ["    grpc-opts:", "      grpc-service-name: \(try Self.quote(path))"] }
        }
        rows += ["rules:", "  - MATCH,recovery"]
        return rows.joined(separator: "\n") + "\n"
    }

    private static func required(_ values: [String: Any], _ key: String) throws -> String {
        let value = string(values, key)
        guard !value.isEmpty else { throw RecoveryMappingError.malformed }
        return value
    }

    private static func string(_ values: [String: Any], _ key: String) -> String {
        if let text = values[key] as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let number = values[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.stringValue }
        return ""
    }

    private static func number(_ values: [String: Any], _ key: String, range: ClosedRange<Int>, fallback: Int? = nil) throws -> Int {
        if values[key] == nil, let fallback { return fallback }
        guard let value = Int(string(values, key)), range.contains(value) else { throw RecoveryMappingError.unsupportedValue(key) }
        return value
    }

    private static func decodeBase64(_ raw: String) -> Data? {
        var value = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        return Data(base64Encoded: value)
    }

    private static func quote(_ value: String) throws -> String {
        let encoded = try JSONEncoder().encode(value)
        // Foundation escapes '/' as '\/' for JSON, which Mihomo's YAML parser
        // rejects in double-quoted scalars. A literal slash is safe here.
        return String(decoding: encoded, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
    }
}
