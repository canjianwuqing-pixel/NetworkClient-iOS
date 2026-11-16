import Foundation

enum BuiltInProxyKind: Sendable {
    case vmess
    case shadowsocks
}

struct BuiltInProxyEndpoint: Sendable, Equatable {
    let kind: BuiltInProxyKind
    let normalizedValue: String
    let server: String
    let port: Int
    let vmess: VmessProxySettings?
    let shadowsocks: ShadowsocksProxySettings?

    var protocolName: String {
        switch kind {
        case .vmess: "vmess"
        case .shadowsocks: "ss"
        }
    }
}

struct VmessProxySettings: Sendable, Equatable {
    let version: String
    let name: String
    let server: String
    let port: Int
    let uuid: UUID
    let alterID: Int
    let cipher: String
    let network: String
    let headerType: String
    let host: String
    let path: String
    let tls: Bool
    let serverName: String
    let alpn: [String]
    let clientFingerprint: String
}

struct ShadowsocksProxySettings: Sendable, Equatable {
    let method: String
    let password: String
    let server: String
    let port: Int
}
