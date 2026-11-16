
/// User-selected routing behavior. This does not change any system or VPN state by itself.
enum ProxyMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case rule
    case global

    var id: Self { self }

    var titleKey: String {
        switch self {
        case .rule:
            L10nKey.proxyModeRule
        case .global:
            L10nKey.proxyModeGlobal
        }
    }
}
