import SwiftUI
import Combine
import CryptoKit

/// Installation resource keys live in Info.plist/xcconfig; none are brand display strings.
enum Installation {
    static func string(_ key: String, bundle: Bundle = .main) -> String {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String, !value.trimmed.isEmpty else {
            preconditionFailure("Missing installation setting: \(key)")
        }
        return value
    }
    static func url(_ key: String, extension ext: String = "json", bundle: Bundle = .main) -> URL {
        let name = string(key, bundle: bundle)
        guard let url = bundle.url(forResource: name, withExtension: ext) else { preconditionFailure("Missing configured resource: \(key)") }
        return url
    }
    static func decode<T: Decodable>(_ key: String, bundle: Bundle = .main) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: url(key, bundle: bundle)))
    }
    static var identity: String {
        let bootstrap = (try? Data(contentsOf: url("BrandBootstrapResource"))) ?? Data()
        let installation = Bundle.main.bundleIdentifier ?? "unidentified-installation"
        let contract = Data("\0remote-config-cache-schema-3\0\(installation)".utf8)
        return SHA256.hash(data: bootstrap + contract).map { String(format: "%02x", $0) }.joined()
    }

    #if DEBUG
    /// Explicit UI-test/offline configuration. Production startup never reads
    /// this fixture and never substitutes the bundled business fallback.
    static var testFixture: AppConfig {
        get throws {
            guard let url = Bundle.main.url(forResource: "BrandA", withExtension: "json") else {
                throw NetworkClientError.configUnavailable("Missing DEBUG configuration fixture")
            }
            return try BrandProvider.validate(
                JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))
            )
        }
    }
    #endif
}

struct BrandTheme: Codable, Sendable, Equatable {
    let colors: [String: [String]]
    static let tokens = ["background", "card", "field", "text", "secondary", "tertiary", "border", "divider", "accent", "emphasis", "tint", "error", "website", "support", "warning", "onAccent", "announcement", "success", "shadow"]
    func validated() throws -> Self {
        guard Self.tokens.allSatisfy({ key in
            guard let values = colors[key], values.count == 2 else { return false }
            return values.allSatisfy { $0.range(of: "^[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$", options: .regularExpression) != nil }
        }) else { throw BrandFailure.invalidTheme }
        return self
    }
    func color(_ token: String) -> Color {
        let pair = colors[token]!
        return Color(uiColor: UIColor { trait in
            let text = pair[trait.userInterfaceStyle == .dark ? 1 : 0]
            let value = UInt32(text, radix: 16)!
            let rgb = text.count == 8 ? value >> 8 : value
            let alpha = text.count == 8 ? CGFloat(value & 255) / 255 : 1
            return UIColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: alpha)
        })
    }
    var background: Color { color("background") }; var card: Color { color("card") }
    var field: Color { color("field") }; var text: Color { color("text") }
    var secondary: Color { color("secondary") }; var tertiary: Color { color("tertiary") }
    var border: Color { color("border") }; var divider: Color { color("divider") }
    var accent: Color { color("accent") }; var emphasis: Color { color("emphasis") }
    var tint: Color { color("tint") }; var error: Color { color("error") }
    var website: Color { color("website") }; var support: Color { color("support") }
    var shadow: Color { color("shadow") }
    var warning: Color { color("warning") }; var onAccent: Color { color("onAccent") }
}

enum BrandFailure: Error { case invalidTheme, invalidName, invalidLogo }
struct BrandSnapshot {
    let config: AppConfig?
    let theme: BrandTheme
    let logo: UIImage
    let configurationSource: ConfigLoadResult.Source?
    let source: String
    var name: String { config?.appName ?? "" }
    var isRemoteConfiguration: Bool { configurationSource == .remote }
    var visibleLoginTitle: String? {
        guard configurationSource == .remote || configurationSource == .cache else { return nil }
        let title = config?.displayLoginTitle ?? ""
        return title.isEmpty ? nil : title
    }
    var sourceLocalizationKey: String {
        if configurationSource == .fixture { return "config.source.offline_test" }
        if source.contains("Logo 缓存") {
            return isRemoteConfiguration ? "config.source.remote_logo_cache" : "config.source.cache_logo_cache"
        }
        if source.contains("安装 Logo") {
            return isRemoteConfiguration ? "config.source.remote_installed_logo" : "config.source.cache_installed_logo"
        }
        if isRemoteConfiguration { return "config.source.remote" }
        if source.hasPrefix("本地缓存") { return "config.source.cache" }
        return "config.source.installed"
    }
}

/// New entries bind both brand identity and URL. Legacy URL-only images are
/// accepted only for the unchanged installation brand and are never deleted.
actor BrandImageCache {
    private struct Entry: Codable { let sourceURL: String; let brandName: String?; let data: Data }
    private let directory: URL
    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("brand-images-v1")) { self.directory = directory }
    private func file(_ url: URL, brandName: String?) -> URL {
        let key = brandName.map { $0 + "\u{0}" + url.absoluteString } ?? url.absoluteString
        return directory.appendingPathComponent(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".json")
    }
    func load(_ url: URL, brandName: String, allowLegacy: Bool) -> Data? {
        func read(_ path: URL, expectedBrand: String?) -> Data? {
            guard let bytes = try? Data(contentsOf: path),
                  let entry = try? JSONDecoder().decode(Entry.self, from: bytes),
                  entry.sourceURL == url.absoluteString,
                  entry.brandName == expectedBrand,
                  entry.data.count <= 8 * 1024 * 1024 else { return nil }
            return entry.data
        }
        return read(file(url, brandName: brandName), expectedBrand: brandName)
            ?? (allowLegacy ? read(file(url, brandName: nil), expectedBrand: nil) : nil)
    }
    func save(_ data: Data, for url: URL, brandName: String) throws {
        guard !data.isEmpty, data.count <= 8 * 1024 * 1024 else { throw BrandFailure.invalidLogo }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(Entry(sourceURL: url.absoluteString, brandName: brandName, data: data))
            .write(to: file(url, brandName: brandName), options: .atomic)
    }
}

@MainActor
final class BrandProvider: ObservableObject {
    typealias ImageDownload = @Sendable (URL) async throws -> Data
    @Published private(set) var snapshot: BrandSnapshot
    var theme: BrandTheme { snapshot.theme }
    var logoFingerprint: String { SHA256.hash(data: snapshot.logo.pngData() ?? Data()).map { String(format: "%02x", $0) }.joined() }
    private let installed: BrandSnapshot
    private let images: BrandImageCache
    private let download: ImageDownload
    private var generation = UUID()
    private var logoLoadingGeneration: UUID?
    private var lastLogoAttemptAt: Date?
    private let logoRetryCooldown: TimeInterval

    init(config: AppConfig? = nil, theme: BrandTheme, logo: UIImage, cache: BrandImageCache = BrandImageCache(), transport: any NetworkTransport = URLSessionNetworkTransport(profile: .brandResource), download: ImageDownload? = nil, logoRetryCooldown: TimeInterval = 10) throws {
        let validatedConfig = try config.map(Self.validate)
        installed = BrandSnapshot(
            config: nil, theme: try theme.validated(), logo: logo,
            configurationSource: nil, source: "安装资源"
        )
        snapshot = BrandSnapshot(
            config: validatedConfig, theme: installed.theme, logo: logo,
            configurationSource: validatedConfig == nil ? nil : .fixture,
            source: validatedConfig == nil ? "安装资源" : "测试配置"
        )
        images = cache
        self.download = download ?? { url in try await Self.downloadImage(url, transport: transport) }
        self.logoRetryCooldown = logoRetryCooldown
    }
    static func decodeLogo(_ data: Data) -> UIImage? {
        guard data.count <= 8 * 1024 * 1024, let image = UIImage(data: data), image.size.width >= 8, image.size.height >= 8, let cgImage = image.cgImage else { return nil }
        var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            return true
        }
        guard rendered, stride(from: 3, to: pixels.count, by: 4).contains(where: { pixels[$0] > 16 }) else { return nil }
        return image
    }
    static func installed(transport: any NetworkTransport = URLSessionNetworkTransport(profile: .brandResource)) -> BrandProvider {
        do {
            let theme: BrandTheme = try Installation.decode("BrandThemeResource")
            guard let logo = decodeLogo(try Data(contentsOf: Installation.url("BrandLocalLogoResource", extension: "png"))) else { throw BrandFailure.invalidLogo }
            return try BrandProvider(theme: theme, logo: logo, transport: transport)
        } catch { preconditionFailure("Installation branding must pass build preflight: \(error)") }
    }
    nonisolated static func validate(_ config: AppConfig) throws -> AppConfig {
        let config = try config.validatedForRuntime()
        guard config.appName.rangeOfCharacter(from: .controlCharacters) == nil else { throw BrandFailure.invalidName }
        return config
    }
    @discardableResult
    func applyConfiguration(_ result: ConfigLoadResult) -> UUID {
        let operation = UUID(); generation = operation
        lastLogoAttemptAt = nil
        guard let config = try? Self.validate(result.config) else { return operation }
        let source: String
        switch result.source {
        case .remote: source = "远程配置"
        case .cache: source = "本地缓存"
        case .fixture: source = "测试配置"
        }
        let currentMatches = snapshot.config?.appName.precomposedStringWithCanonicalMapping == config.appName.precomposedStringWithCanonicalMapping
            && snapshot.config?.appLogoURL == config.appLogoURL
        let suffix = currentMatches && snapshot.source.contains("Logo 缓存") ? " · Logo 缓存"
            : currentMatches && !snapshot.source.contains("安装 Logo") ? "" : " · 安装 Logo"
        // Network settings and all brand links commit before any image request.
        // The build-selected installation logo is the only fallback, even if
        // the remote brand name changes. No textual or generic logo is used.
        snapshot = BrandSnapshot(
            config: config, theme: installed.theme,
            logo: currentMatches ? snapshot.logo : installed.logo,
            configurationSource: result.source,
            source: source + suffix
        )
        return operation
    }

    func apply(_ result: ConfigLoadResult, networkAllowed: Bool = true) async {
        let operation = applyConfiguration(result)
        await resolveLogo(for: result.config, operation: operation, networkAllowed: networkAllowed)
    }

    func resolveLogo(for config: AppConfig, operation: UUID, networkAllowed: Bool = true) async {
        guard generation == operation, logoLoadingGeneration != operation else { return }
        logoLoadingGeneration = operation
        defer { if logoLoadingGeneration == operation { logoLoadingGeneration = nil } }
        let source = snapshot.source.components(separatedBy: " · ").first ?? snapshot.source
        // Explicit fixtures use only the build-selected image.
        if snapshot.configurationSource == .fixture {
            snapshot = BrandSnapshot(config: config, theme: installed.theme,
                                     logo: installed.logo, configurationSource: snapshot.configurationSource,
                                     source: source + " · 安装 Logo")
            return
        }
        if let url = config.appLogoURL {
            if let bytes = await images.load(url, brandName: config.appName, allowLegacy: false),
               let logo = Self.decodeLogo(bytes), generation == operation {
                snapshot = BrandSnapshot(
                    config: config, theme: installed.theme, logo: logo,
                    configurationSource: snapshot.configurationSource,
                    source: source + " · Logo 缓存"
                )
            }
            if networkAllowed {
                do {
                    lastLogoAttemptAt = Date()
                    let bytes = try await download(url)
                    guard bytes.count <= 8 * 1024 * 1024, let logo = Self.decodeLogo(bytes), generation == operation, !Task.isCancelled else { throw BrandFailure.invalidLogo }
                    snapshot = BrandSnapshot(
                        config: config, theme: installed.theme, logo: logo,
                        configurationSource: snapshot.configurationSource, source: source
                    )
                    try? await images.save(bytes, for: url, brandName: config.appName)
                    return
                } catch { /* Keep only a cache matching this URL, otherwise installed fallback. */ }
            }
            guard generation == operation else { return }
            if snapshot.source == source + " · Logo 缓存" { return }
        }
        guard generation == operation else { return }
        snapshot = BrandSnapshot(
            config: config, theme: installed.theme, logo: installed.logo,
            configurationSource: snapshot.configurationSource,
            source: source + " · 安装 Logo"
        )
    }

    /// Retry the same configured remote asset after reachability returns.
    /// This never reloads AppConfig or changes the active API candidates.
    func retryRemoteLogoIfNeeded() async {
        guard let config = snapshot.config,
              snapshot.configurationSource == .remote || snapshot.configurationSource == .cache,
              config.appLogoURL != nil,
              logoLoadingGeneration != generation,
              snapshot.source.contains("安装 Logo") || snapshot.source.contains("Logo 缓存"),
              lastLogoAttemptAt.map({ Date().timeIntervalSince($0) >= logoRetryCooldown }) ?? true else { return }
        await resolveLogo(for: config, operation: generation)
    }

    func remainingLogoRetryCooldown() -> TimeInterval? {
        guard snapshot.source.contains("安装 Logo") || snapshot.source.contains("Logo 缓存"),
              let lastLogoAttemptAt else { return nil }
        let remaining = logoRetryCooldown - Date().timeIntervalSince(lastLogoAttemptAt)
        return remaining > 0 ? remaining : nil
    }
    nonisolated static func downloadImage(_ url: URL, transport: any NetworkTransport) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = NetworkTransportPolicy.requestTimeout(for: .brandResource)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await transport.data(for: request, kind: .brandResource)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode), data.count <= 8 * 1024 * 1024 else { throw BrandFailure.invalidLogo }
        return data
    }
    #if DEBUG
    struct FixtureProfile: Decodable { let config: String; let theme: String; let logo: String }
    func selectTestProfile(_ index: Int) throws {
        guard ProcessInfo.processInfo.arguments.contains("--brand-switch-tests") else { return }
        let profiles: [FixtureProfile] = try Installation.decode("BrandFixtureProfilesResource")
        guard profiles.indices.contains(index) else { return }
        let profile = profiles[index]
        func bytes(_ name: String, _ ext: String) throws -> Data {
            guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { throw BrandFailure.invalidLogo }
            return try Data(contentsOf: url)
        }
        let config = try JSONDecoder().decode(AppConfig.self, from: bytes(profile.config, "json"))
        let theme = try JSONDecoder().decode(BrandTheme.self, from: bytes(profile.theme, "json"))
        guard let logo = UIImage(data: try bytes(profile.logo, "png")) else { throw BrandFailure.invalidLogo }
        try selectTestInstallation(config: config, theme: theme, logo: logo)
    }
    #endif
    #if DEBUG
    /// Only explicit offline UI tests may exchange installation profiles.
    func selectTestInstallation(config: AppConfig, theme: BrandTheme, logo: UIImage) throws {
        generation = UUID()
        snapshot = BrandSnapshot(
            config: try Self.validate(config), theme: try theme.validated(), logo: logo,
            configurationSource: .fixture, source: "离线测试配置"
        )
    }
    #endif
}

/// Endpoint overrides are local installation data, not additions to the remote AppConfig schema.
enum NetworkEndpoints {
    private struct Values: Decodable { let apiRoot: String; let paths: [String: String]; let customerServiceEmbed: String }
    private static let values: Values = {
        do { return try Installation.decode("BrandNetworkResource") }
        catch { preconditionFailure("Invalid endpoint installation configuration") }
    }()
    static var apiRoot: String { values.apiRoot }
    static var customerServiceEmbed: String { values.customerServiceEmbed }
    static func path(_ key: String) -> String {
        guard let path = values.paths[key], path.hasPrefix("/"), !path.contains("://"), !path.contains("..") else { preconditionFailure("Invalid endpoint path: \(key)") }
        return path
    }
}
