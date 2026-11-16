import Foundation

struct BuiltInProxyRecoveryRuntimeInfo: Sendable {
    let protocolName: String
    let mixedPort: UInt16
}

/// Keeps API retry policy independent of any desktop core. No system permission is requested.
actor UnavailableRecoveryRuntime: BuiltInProxyRecoveryRuntimeProtocol {
    func start(endpoint: BuiltInProxyEndpoint) throws -> BuiltInProxyRecoveryRuntimeInfo {
        throw TunnelDiagnostic(code: .coreNotIntegrated, message: "iOS 备用代理通道尚未接入，请使用可直连网络")
    }
    func makeRecoveryTransport() throws -> any NetworkTransport {
        throw TunnelDiagnostic(code: .coreNotIntegrated, message: "备用传输不可用")
    }
    func stopRecovery() throws {}
}
