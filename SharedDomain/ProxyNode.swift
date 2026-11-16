
struct ProxyNode: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let fingerprint: String
    let originalName: String
    let displayName: String
    let coreName: String
    let protocolType: String
    let server: String
    let port: Int
    let countryCode: String?
    let available: Bool
}
