import Foundation

/// The parser rejects SS query options before normalization; this second pass
/// refuses any field that the pinned recovery Core cannot safely reproduce.
enum BuiltInProxyBridge {
    static func map(_ original: String) throws -> RecoveryNode {
        let endpoint = try BuiltInProxyParser.parse(original)
        let node = try RecoveryNode.parse(original)
        guard node.server == endpoint.server, node.port == endpoint.port else {
            throw RecoveryMappingError.malformed
        }
        switch (endpoint.kind, node.kind) {
        case (.vmess, .vmess):
            guard let source = endpoint.vmess,
                  endpoint.shadowsocks == nil,
                  node.secret.caseInsensitiveCompare(source.uuid.uuidString) == .orderedSame,
                  node.alterID == source.alterID,
                  node.cipher == source.cipher,
                  node.network == source.network,
                  node.tls == source.tls,
                  node.serverName == source.serverName,
                  node.alpn == source.alpn,
                  node.fingerprint == source.clientFingerprint.lowercased(),
                  node.wsHost == source.host,
                  node.path == source.path,
                  source.headerType.isEmpty || source.headerType == "none"
            else { throw RecoveryMappingError.malformed }
        case (.shadowsocks, .shadowsocks):
            guard let source = endpoint.shadowsocks,
                  endpoint.vmess == nil,
                  node.cipher == source.method,
                  node.secret == source.password
            else { throw RecoveryMappingError.malformed }
        default:
            throw RecoveryMappingError.unsupportedProtocol
        }
        return node
    }

    static func mapMany(_ shares: [String]) -> [RecoveryNode] {
        shares.compactMap { try? map($0) }
    }
}
