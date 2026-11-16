import Foundation

struct TunnelDiagnostic: Error, Equatable, Sendable, LocalizedError {
    enum Code: String, Codable, Sendable {
        case coreNotIntegrated, signatureNotVerified, unsupportedProtocol, missingNode, invalidTransition
        case proxyUnavailable, tunnelStoppedUnexpectedly
        case recoveryCloseUnconfirmed
    }
    let code: Code
    let message: String
    var errorDescription: String? { message }
    var userFacingKey: String {
        switch code {
        case .coreNotIntegrated: L10nKey.tunnelCoreNotIntegrated
        case .signatureNotVerified: L10nKey.tunnelSignatureNotVerified
        case .unsupportedProtocol: L10nKey.tunnelUnsupportedProtocol
        case .missingNode: L10nKey.tunnelMissingNode
        case .invalidTransition: L10nKey.tunnelInvalidTransition
        case .proxyUnavailable: "vpn.error.proxy_unavailable"
        case .tunnelStoppedUnexpectedly: "vpn.error.tunnel_stopped"
        case .recoveryCloseUnconfirmed: "vpn.error.recovery_close_unconfirmed"
        }
    }
}

struct TunnelRequest: Sendable, Equatable {
    let nodeID: String
    let mode: ProxyMode
    let configurationRevision: String
}

enum ProtocolReadiness: String, Sendable { case unverified, unsupported }
struct ProtocolCapability: Sendable, Equatable {
    let protocolName: String
    let readiness: ProtocolReadiness
    let diagnosticKey: String
}

protocol ProtocolCapabilityChecking: Sendable {
    func capability(for record: RuntimeProxyRecord) -> ProtocolCapability
}

struct PendingProtocolCapabilities: ProtocolCapabilityChecking {
    // Recognition only exposes a candidate in the node list. The selected
    // mapper and pinned Core still have to validate it before connection.
    private static let reviewedTypes: Set<String> = [
        "vless", "trojan", "hysteria2", "ss", "vmess", "tuic",
        "ssr", "snell", "hysteria", "anytls", "socks5", "http", "ssh", "shadowquic",
        "gost-relay", "trusttunnel", "mieru", "sudoku"
    ]

    static func recognizes(_ rawType: String) -> Bool {
        reviewedTypes.contains(rawType.lowercased())
    }

    func capability(for record: RuntimeProxyRecord) -> ProtocolCapability {
        let type: String
        if case let .string(value)? = record.originalProxy["type"] { type = value.lowercased() } else { type = "unknown" }
        let known = Self.recognizes(type)
        return ProtocolCapability(protocolName: type, readiness: known ? .unverified : .unsupported,
            diagnosticKey: known ? L10nKey.tunnelCapabilityUnverified : L10nKey.tunnelCapabilityUnsupported)
    }
}
