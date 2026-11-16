import XCTest
import UIKit
import Network
@testable import NetworkClient

private final class OfflineTransport: URLProtocol, @unchecked Sendable {
    static let registry = Registry()
    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var payload: Data?
        func set(_ value: Data?) { lock.withLock { payload = value } }
        func read() -> Data? { lock.withLock { payload } }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let data = Self.registry.read() else { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor ConfigCallCounter {
    private var value = 0
    func next() -> Int { value += 1; return value }
    func count() -> Int { value }
}

private actor LogoAvailability {
    private var available = false
    func restore() { available = true }
    func isAvailable() -> Bool { available }
}

@MainActor
final class BrandTests: XCTestCase {
    func testMihomoDnsFieldValidatesIPv4AndRoundTrips() throws {
        let base = try fixture("A")
        let encoded = try JSONEncoder().encode(base)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        fields["MihomoDns"] = "203.0.113.7"
        let valid = try JSONDecoder().decode(
            AppConfig.self, from: JSONSerialization.data(withJSONObject: fields)
        )
        XCTAssertEqual(valid.mihomoDns, "203.0.113.7")
        XCTAssertEqual(try JSONDecoder().decode(
            AppConfig.self, from: JSONEncoder().encode(valid)
        ).mihomoDns, "203.0.113.7")

        for invalid in ["", "  ", "https://203.0.113.7/dns-query", "203.0.113.7:53"] {
            fields["MihomoDns"] = invalid
            let decoded = try JSONDecoder().decode(
                AppConfig.self, from: JSONSerialization.data(withJSONObject: fields)
            )
            XCTAssertNil(decoded.mihomoDns)
        }
        fields["MihomoDns"] = ["address": "203.0.113.7"]
        let wrongType = try JSONDecoder().decode(
            AppConfig.self, from: JSONSerialization.data(withJSONObject: fields)
        )
        XCTAssertNil(wrongType.mihomoDns)
    }

    func testSettingsCommunityLinkValidation() {
        XCTAssertNil(SettingsLinks.communityURL(nil))
        XCTAssertNil(SettingsLinks.communityURL("  "))
        XCTAssertNil(SettingsLinks.communityURL("javascript:alert(1)"))
        XCTAssertNil(SettingsLinks.communityURL("https:///"))
        XCTAssertNil(SettingsLinks.communityURL("https://user:password@community.example.invalid"))
        XCTAssertEqual(SettingsLinks.communityURL(" https://community.example.invalid/group ")?.host, "community.example.invalid")
        XCTAssertNil(SettingsLinks.communityURL("http://community.example.invalid/group"))
    }

    func testPrivacyPolicyRemoteConfigDecodesTrimsAndRemainsBackwardCompatible() throws {
        let base = try fixture("A")
        var fields = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any]
        )
        fields["PrivacyPolicyURL"] = " https://legal.example.invalid/privacy "
        let decoded = try JSONDecoder().decode(
            AppConfig.self,
            from: JSONSerialization.data(withJSONObject: fields)
        )
        XCTAssertEqual(
            try decoded.validatedForRuntime().privacyPolicyURL,
            "https://legal.example.invalid/privacy"
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                AppConfig.self,
                from: JSONEncoder().encode(decoded)
            ).privacyPolicyURL,
            " https://legal.example.invalid/privacy "
        )

        fields.removeValue(forKey: "PrivacyPolicyURL")
        let legacy = try JSONDecoder().decode(
            AppConfig.self,
            from: JSONSerialization.data(withJSONObject: fields)
        )
        XCTAssertNil(legacy.privacyPolicyURL)

        fields["PrivacyPolicyURL"] = ["unexpected": "shape"]
        let malformedOptional = try JSONDecoder().decode(
            AppConfig.self,
            from: JSONSerialization.data(withJSONObject: fields)
        )
        XCTAssertNil(malformedOptional.privacyPolicyURL)
    }

    private func fixture(_ letter: String) throws -> AppConfig {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "Brand" + letter, withExtension: "json"))
        return try BrandProvider.validate(JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url)))
    }
    private func theme(_ letter: String) throws -> BrandTheme {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "Theme" + letter, withExtension: "json"))
        return try JSONDecoder().decode(BrandTheme.self, from: Data(contentsOf: url)).validated()
    }
    private func logo(_ letter: String) throws -> UIImage {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "Logo" + letter, withExtension: "png"))
        return try XCTUnwrap(UIImage(contentsOfFile: url.path))
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func transport() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [OfflineTransport.self]
        return URLSession(configuration: configuration)
    }
    private func result(
        _ config: AppConfig,
        source: ConfigLoadResult.Source = .remote,
        cacheFresh: Bool = true
    ) -> ConfigLoadResult {
        ConfigLoadResult(
            config: config, source: source, cloudConfigIndex: 1,
            cloudConfigURL: nil, cacheAgeSeconds: 0, cacheFresh: cacheFresh
        )
    }
    private func replacingLoginTitle(_ config: AppConfig, with loginTitle: String?) -> AppConfig {
        AppConfig(
            appName: config.appName, loginTitle: loginTitle, appLogo: config.appLogo,
            homePage: config.homePage, privacyPolicyURL: config.privacyPolicyURL,
            telegramGroup: config.telegramGroup, supportAPI: config.supportAPI,
            updateURL: config.updateURL, userAgent: config.userAgent,
            latencyDisplayRatio: config.latencyDisplayRatio, inviteLink: config.inviteLink,
            apiBaseURLs: config.apiBaseURLs, activeAPIBaseURL: config.activeAPIBaseURL,
            builtInProxy: config.builtInProxy, mihomoDns: config.mihomoDns,
            customerService: config.customerService
        )
    }
    func testLoginTitleVisibilityUsesTypedConfigurationSource() throws {
        let base = try fixture("A")
        let titled = replacingLoginTitle(base, with: "Remote Login Title")
        let provider = try BrandProvider(config: titled, theme: theme("A"), logo: logo("A"))

        XCTAssertEqual(provider.snapshot.configurationSource, .fixture)
        XCTAssertNil(provider.snapshot.visibleLoginTitle)

        provider.applyConfiguration(result(titled, source: .remote))
        XCTAssertEqual(provider.snapshot.configurationSource, .remote)
        XCTAssertEqual(provider.snapshot.visibleLoginTitle, "Remote Login Title")

        provider.applyConfiguration(result(titled, source: .cache, cacheFresh: true))
        XCTAssertEqual(provider.snapshot.configurationSource, .cache)
        XCTAssertEqual(provider.snapshot.visibleLoginTitle, "Remote Login Title")

        provider.applyConfiguration(result(titled, source: .cache, cacheFresh: false))
        XCTAssertEqual(provider.snapshot.configurationSource, .cache)
        XCTAssertEqual(provider.snapshot.visibleLoginTitle, "Remote Login Title")

    }
    func testRemoteAndCachedEmptyLoginTitlesRemainHidden() throws {
        let base = try fixture("A")
        for value in [nil, "", "   "] as [String?] {
            let config = replacingLoginTitle(base, with: value)
            let provider = try BrandProvider(config: config, theme: theme("A"), logo: logo("A"))
            provider.applyConfiguration(result(config, source: .remote))
            XCTAssertNil(provider.snapshot.visibleLoginTitle)
            provider.applyConfiguration(result(config, source: .cache))
            XCTAssertNil(provider.snapshot.visibleLoginTitle)
        }
    }
    func testInstalledProviderStartsWithoutBusinessConfiguration() {
        let provider = BrandProvider.installed()
        XCTAssertNil(provider.snapshot.configurationSource)
        XCTAssertNil(provider.snapshot.config)
        XCTAssertTrue(provider.snapshot.name.isEmpty)
        XCTAssertNil(provider.snapshot.visibleLoginTitle)
    }
    func testAsyncRemoteRefreshMakesLoginTitleVisibleOnExistingProvider() async throws {
        let base = try fixture("A")
        let remote = replacingLoginTitle(base, with: "Remote Login Title")
        let provider = try BrandProvider(config: base, theme: theme("A"), logo: logo("A"))
        let identity = ObjectIdentifier(provider)

        XCTAssertNil(provider.snapshot.visibleLoginTitle)
        await provider.apply(result(remote, source: .remote), networkAllowed: false)

        XCTAssertEqual(ObjectIdentifier(provider), identity)
        XCTAssertEqual(provider.snapshot.visibleLoginTitle, "Remote Login Title")
    }
    func testTransparentRemoteLogoIsRejectedButDecodableUniformImageIsAllowed() async throws {
        let a = try fixture("A"), b = try fixture("B"), dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transparent = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).pngData { _ in }
        XCTAssertNil(BrandProvider.decodeLogo(transparent))
        let uniform = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).pngData { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        XCTAssertNotNil(BrandProvider.decodeLogo(uniform))
        let provider = try BrandProvider(config: a, theme: theme("A"), logo: logo("A"), cache: BrandImageCache(directory: dir), download: { _ in transparent })
        await provider.apply(result(b))
        XCTAssertEqual(provider.snapshot.name, b.appName)
        XCTAssertEqual(provider.snapshot.config?.apiBaseURLs, b.apiBaseURLs)
        XCTAssertEqual(provider.snapshot.logo.pngData(), try logo("A").pngData())
    }
    func testLatePreviousLogoDownloadCannotOverwriteNewBrand() async throws {
        let a = try fixture("A"), b = try fixture("B"), dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dataA = try XCTUnwrap(logo("A").pngData()), dataB = try XCTUnwrap(logo("B").pngData())
        let urlA = try XCTUnwrap(a.appLogoURL)
        let provider = try BrandProvider(config: a, theme: theme("A"), logo: logo("A"), cache: BrandImageCache(directory: dir), download: { url in
            try await Task.sleep(for: .milliseconds(url == urlA ? 100 : 10))
            return url == urlA ? dataA : dataB
        })
        let old = Task { await provider.apply(self.result(a)) }
        await Task.yield()
        await provider.apply(result(b))
        await old.value
        XCTAssertEqual(provider.snapshot.name, b.appName)
        XCTAssertEqual(provider.snapshot.logo.pngData(), try logo("B").pngData())
    }
    func testInvalidThemeRejected() {
        XCTAssertThrowsError(try BrandTheme(colors: [:]).validated())
    }
    func testLegacyCacheWithoutInstallationIdentityIsRejected() async throws {
        let a = try fixture("A"), b = try fixture("B"), dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = transport(); defer { session.invalidateAndCancel() }
        OfflineTransport.registry.set(nil)
        func writeLegacy(_ config: AppConfig) throws {
            let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config))
            let envelope: [String: Any] = ["cacheVersion":3, "updatedAt":Int64(Date().timeIntervalSince1970 * 1000), "cloudConfigIndex":1, "cloudConfigURL":"legacy", "config":value]
            try JSONSerialization.data(withJSONObject: envelope).write(to: dir.appendingPathComponent("config-cache.json"))
        }
        let service = RemoteConfigService(cacheRoot: dir, installationID: "new", transport: session)
        try writeLegacy(a)
        do {
            _ = try await service.loadConfig(forceRemote: true)
            XCTFail("Legacy cache without an installation identity must be rejected")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        try writeLegacy(b)
        do {
            _ = try await service.loadConfig(forceRemote: true)
            XCTFail("A foreign legacy cache must not become runtime configuration")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
    }
    func testInstallationResourcesValidAndLogoPresent() throws {
        let theme: BrandTheme = try Installation.decode("BrandThemeResource"); _ = try theme.validated()
        XCTAssertNotNil(UIImage(contentsOfFile: Installation.url("BrandLocalLogoResource", extension: "png").path))
        XCTAssertTrue(NetworkEndpoints.path("loginPath").hasPrefix("/"))
    }
    func testSingleSourceLogoBuildContract() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fileManager = FileManager.default
        let appIcon = root.appendingPathComponent(
            "Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
        )
        let contentsURL = appIcon.deletingLastPathComponent()
            .appendingPathComponent("Contents.json")
        let legacyLocalLogo = root.appendingPathComponent("Resources/BrandLocalLogo.png")
        let generatorURL = root.appendingPathComponent("Scripts/generate-brand-local-logo.sh")

        XCTAssertTrue(fileManager.fileExists(atPath: appIcon.path))
        XCTAssertFalse(fileManager.fileExists(atPath: legacyLocalLogo.path))
        XCTAssertTrue(fileManager.isReadableFile(atPath: generatorURL.path))

        let contentsData = try Data(contentsOf: contentsURL)
        let contents = try XCTUnwrap(
            JSONSerialization.jsonObject(with: contentsData) as? [String: Any]
        )
        let images = try XCTUnwrap(contents["images"] as? [[String: Any]])
        XCTAssertEqual(images.compactMap { $0["filename"] as? String }, ["AppIcon.png"])

        let baseConfiguration = try String(contentsOf: root.appendingPathComponent(
            "Configuration/Base.xcconfig"
        ))
        XCTAssertTrue(baseConfiguration.contains(
            "BRAND_LOCAL_LOGO_RESOURCE = BrandLocalLogo"
        ))
        let publicConfiguration = try String(contentsOf: root.appendingPathComponent(
            "Configuration/Public.xcconfig"
        ))
        XCTAssertTrue(publicConfiguration.contains("#include \"Base.xcconfig\""))
        XCTAssertTrue(publicConfiguration.contains("BRAND_DISPLAY_NAME = NetworkClient"))
        XCTAssertTrue(publicConfiguration.contains(
            "APP_BASE_BUNDLE_ID = org.example.networkclient.ios"
        ))
        let generator = try String(contentsOf: generatorURL)
        XCTAssertTrue(generator.contains("AppIcon.appiconset/AppIcon.png"))
        XCTAssertTrue(generator.contains("${BRAND_LOCAL_LOGO_RESOURCE}.png"))
        XCTAssertTrue(generator.contains("/usr/bin/cmp -s"))

        let project = try String(contentsOf: root.appendingPathComponent(
            "NetworkClient-iOS.xcodeproj/project.pbxproj"
        ))
        XCTAssertEqual(
            project.components(separatedBy: "name = \"Generate Brand Local Logo\";").count - 1,
            2
        )
        XCTAssertEqual(
            project.components(separatedBy: "Scripts/generate-brand-local-logo.sh").count - 1,
            4
        )
        XCTAssertEqual(
            project.components(separatedBy: "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/$(BRAND_LOCAL_LOGO_RESOURCE).png").count - 1,
            2
        )
        XCTAssertFalse(project.contains("Resources/BrandLocalLogo.png in Resources"))
        XCTAssertTrue(project.contains("B6A100000000000000000001 /* Generate Brand Local Logo */"))
        XCTAssertTrue(project.contains("B6A100000000000000000002 /* Generate Brand Local Logo */"))

        let provider = try String(contentsOf: root.appendingPathComponent(
            "iOSAdapters/BrandProvider.swift"
        ))
        XCTAssertTrue(provider.contains(
            "Installation.url(\"BrandLocalLogoResource\", extension: \"png\")"
        ))
    }
    func testAtomicInstallationSwitchUpdatesAllBrandValues() throws {
        let a = try fixture("A"), b = try fixture("B")
        let provider = try BrandProvider(config: a, theme: theme("A"), logo: logo("A"))
        let oldLogo = provider.logoFingerprint
        try provider.selectTestInstallation(config: b, theme: theme("B"), logo: logo("B"))
        XCTAssertEqual(provider.snapshot.name, b.appName)
        XCTAssertNotEqual(provider.logoFingerprint, oldLogo)
        XCTAssertEqual(provider.theme, try theme("B"))
        XCTAssertEqual(provider.snapshot.config?.homePage, b.homePage)
        XCTAssertEqual(provider.snapshot.config?.telegramGroup, b.telegramGroup)
        XCTAssertEqual(CustomerServiceResolver.resolve(try XCTUnwrap(provider.snapshot.config)), CustomerServiceResolver.resolve(b))
        XCTAssertFalse(provider.snapshot.name.contains(a.appName))
    }
    func testRemoteFailureUsesOnlyURLMatchingLogoCache() async throws {
        let a = try fixture("A"), b = try fixture("B"), dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = BrandImageCache(directory: dir)
        try await cache.save(try XCTUnwrap(logo("B").pngData()), for: XCTUnwrap(b.appLogoURL), brandName: b.appName)
        let provider = try BrandProvider(config: a, theme: theme("A"), logo: logo("A"), cache: cache, download: { _ in throw URLError(.notConnectedToInternet) })
        await provider.apply(result(b))
        XCTAssertEqual(provider.snapshot.name, b.appName)
        XCTAssertTrue(provider.snapshot.source.contains("缓存"))
        XCTAssertEqual(provider.snapshot.logo.pngData(), try logo("B").pngData())
    }
    func testWrongLogoCacheNeverLeaksPreviousBrand() async throws {
        let a = try fixture("A"), b = try fixture("B"), dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = BrandImageCache(directory: dir)
        try await cache.save(try XCTUnwrap(logo("B").pngData()), for: XCTUnwrap(b.appLogoURL), brandName: b.appName)
        let provider = try BrandProvider(config: a, theme: theme("A"), logo: logo("A"), cache: cache, download: { _ in throw URLError(.notConnectedToInternet) })
        await provider.apply(result(a))
        XCTAssertEqual(provider.snapshot.name, a.appName)
        XCTAssertEqual(provider.snapshot.logo.pngData(), try logo("A").pngData())
    }
    func testNewRemoteBrandWithoutValidLogoKeepsRemoteNetworkConfiguration() async throws {
        let a = try fixture("A"), b = try fixture("B"), dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = try BrandProvider(config: a, theme: theme("A"), logo: logo("A"), cache: BrandImageCache(directory: dir), download: { _ in Data("not an image".utf8) })
        await provider.apply(result(b))
        XCTAssertEqual(provider.snapshot.name, b.appName)
        XCTAssertEqual(provider.snapshot.config?.homePage, b.homePage)
        XCTAssertEqual(provider.snapshot.config?.apiBaseURLs, b.apiBaseURLs)
        XCTAssertEqual(provider.snapshot.logo.pngData(), try logo("A").pngData())
    }
    func testOfflineConfigPrefersValidCacheThenBecomesUnavailableWhenCacheIsCorrupt() async throws {
        let b = try fixture("B"), dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = transport(); defer { session.invalidateAndCancel() }
        let service = RemoteConfigService(cacheRoot: dir, installationID: "installation-1", transport: session)
        OfflineTransport.registry.set(try JSONEncoder().encode(b))
        let remote = try await service.loadConfig(forceRemote: true); XCTAssertEqual(remote.source, .remote)
        OfflineTransport.registry.set(nil)
        let cached = try await service.loadConfig(forceRemote: true); XCTAssertEqual(cached.source, .cache); XCTAssertEqual(cached.config.appName, b.appName)
        try Data("corrupt cache".utf8).write(to: dir.appendingPathComponent("config-cache.json"))
        do {
            _ = try await service.loadConfig(forceRemote: true)
            XCTFail("A corrupt cache must not fall back to bundled business configuration")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
    }

    func testExistingConfigurationCacheIsProtectedWithoutRewritingItsContents() async throws {
        let b = try fixture("B"), dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = transport(); defer { session.invalidateAndCancel() }
        let service = RemoteConfigService(
            cacheRoot: dir, installationID: "protection-test", transport: session
        )
        OfflineTransport.registry.set(try JSONEncoder().encode(b))
        _ = try await service.loadConfig(forceRemote: true)
        let file = dir.appendingPathComponent("config-cache.json")
        let original = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

        let recovered = try await service.loadLocalConfig()
        XCTAssertEqual(recovered.source, .cache)
        XCTAssertEqual(try Data(contentsOf: file), original)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
        // Simulator file systems do not report the iOS data-protection class.
        // The write path still applies it; verify the reported class on device.
        #if !targetEnvironment(simulator)
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType,
                       .completeUntilFirstUserAuthentication)
        #endif
    }
    func testInstallationChangeRejectsOldCache() async throws {
        let a = try fixture("A"), dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = transport(); defer { session.invalidateAndCancel() }
        OfflineTransport.registry.set(try JSONEncoder().encode(a))
        _ = try await RemoteConfigService(cacheRoot: dir, installationID: "old", transport: session).loadConfig(forceRemote: true)
        OfflineTransport.registry.set(nil)
        do {
            _ = try await RemoteConfigService(cacheRoot: dir, installationID: "new", transport: session).loadConfig(forceRemote: true)
            XCTFail("A cache from another installation identity must be rejected")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
    }
    func testInvalidRemoteConfigBecomesUnavailableWithoutCache() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = transport(); defer { session.invalidateAndCancel() }
        OfflineTransport.registry.set(Data(#"{"AppName":"","ApiBaseUrls":[]}"#.utf8))
        do {
            _ = try await RemoteConfigService(cacheRoot: dir, installationID: "test", transport: session).loadConfig(forceRemote: true)
            XCTFail("Invalid remote configuration must not become a bundled success")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
    }

    func testInvalidBootstrapCannotReachNetworkOrBundledConfiguration() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("InvalidBootstrap.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "org.networkclient.tests.invalid-bootstrap",
            "CFBundlePackageType": "BNDL",
            "BrandBootstrapResource": "invalid-bootstrap",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundleURL.appendingPathComponent("Info.plist"))
        try Data(#"{"CloudConfig":[],"CloudUpdateHours":1}"#.utf8)
            .write(to: bundleURL.appendingPathComponent("invalid-bootstrap.json"))
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))
        let transport = RecordingNetworkTransport { _, _ in
            XCTFail("An invalid bootstrap must fail before any network request")
            throw URLError(.badURL)
        }
        let service = RemoteConfigService(
            bundle: bundle, cacheRoot: root, installationID: "invalid-bootstrap-test",
            networkTransport: transport
        )

        do {
            _ = try await service.loadConfig()
            XCTFail("An invalid bootstrap must not become bundled configuration")
        } catch let error as NetworkClientError {
            guard case .bootstrapInvalid = error else {
                return XCTFail("Expected bootstrapInvalid, got \(error)")
            }
        }
        let calls = await transport.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testInjectedRemoteConfigTransportPreservesSourceFailoverAndCache() async throws {
        let b = try fixture("B"), dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let counter = AttemptCounter()
        let payload = try JSONEncoder().encode(b)
        let transport = RecordingNetworkTransport { request, kind in
            XCTAssertEqual(kind, .remoteConfiguration)
            await counter.increment()
            if await counter.value == 1 { throw URLError(.cannotConnectToHost) }
            return (payload, HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!)
        }
        let service = RemoteConfigService(
            cacheRoot: dir, installationID: "offline-transport-test",
            networkTransport: transport
        )
        let loaded = try await service.loadConfig(forceRemote: true)
        XCTAssertEqual(loaded.source, .remote)
        XCTAssertEqual(loaded.config.appName, b.appName)
        XCTAssertEqual(loaded.cloudConfigIndex, 2)
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.allSatisfy { $0.timeout == 6 && $0.method == "GET" })
    }

    func testInjectedBrandResourceTransportPreservesLogoResult() async throws {
        let a = try fixture("A"), b = try fixture("B"), dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = try XCTUnwrap(logo("B").pngData())
        let transport = RecordingNetworkTransport { request, kind in
            XCTAssertEqual(kind, .brandResource)
            return (payload, HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "image/png"]
            )!)
        }
        let provider = try BrandProvider(
            config: a, theme: theme("A"), logo: logo("A"),
            cache: BrandImageCache(directory: dir), transport: transport
        )
        await provider.apply(result(b))
        XCTAssertEqual(provider.snapshot.name, b.appName)
        XCTAssertEqual(provider.snapshot.logo.pngData(), payload)
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.timeout, 8)
    }

    func testConfigurationCommitsBeforeLogoRequestAndKeepsNewBrandOnFailure() async throws {
        let a = try fixture("A"), b = try fixture("B"), dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = try BrandProvider(
            config: a, theme: theme("A"), logo: logo("A"),
            cache: BrandImageCache(directory: dir),
            download: { _ in throw URLError(.notConnectedToInternet) }
        )
        let generation = provider.applyConfiguration(result(b))
        XCTAssertEqual(provider.snapshot.config?.apiBaseURLs, b.apiBaseURLs)
        XCTAssertEqual(provider.snapshot.name, b.appName)
        XCTAssertEqual(provider.snapshot.logo.pngData(), try logo("A").pngData())
        await provider.resolveLogo(for: b, operation: generation)
        XCTAssertEqual(provider.snapshot.config?.apiBaseURLs, b.apiBaseURLs)
        XCTAssertEqual(provider.snapshot.logo.pngData(), try logo("A").pngData())
    }

    func testDifferentBrandCannotUseOldLogoCacheAtSameURL() async throws {
        let a = try fixture("A"), b = try fixture("B"), dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sharedURL = try XCTUnwrap(a.appLogoURL)
        let otherBrand = AppConfig(
            appName: b.appName, loginTitle: b.loginTitle, appLogo: sharedURL.absoluteString,
            homePage: b.homePage, telegramGroup: b.telegramGroup, supportAPI: b.supportAPI,
            updateURL: b.updateURL, userAgent: b.userAgent,
            latencyDisplayRatio: b.latencyDisplayRatio, inviteLink: b.inviteLink,
            apiBaseURLs: b.apiBaseURLs, activeAPIBaseURL: b.activeAPIBaseURL,
            builtInProxy: []
        )
        let cache = BrandImageCache(directory: dir)
        try await cache.save(try XCTUnwrap(logo("A").pngData()), for: sharedURL, brandName: a.appName)
        let provider = try BrandProvider(config: a, theme: theme("A"), logo: logo("A"),
                                         cache: cache, download: { _ in throw URLError(.notConnectedToInternet) })
        await provider.apply(result(otherBrand))
        XCTAssertEqual(provider.snapshot.name, b.appName)
        XCTAssertEqual(provider.snapshot.config?.apiBaseURLs, b.apiBaseURLs)
        XCTAssertEqual(provider.snapshot.logo.pngData(), try logo("A").pngData())
    }

    func testMissingRemoteLogoUsesConfiguredInstallationResource() async throws {
        let a = try fixture("A"), b = try fixture("B"), dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let withoutURL = AppConfig(
            appName: b.appName, loginTitle: b.loginTitle, appLogo: nil,
            homePage: b.homePage, telegramGroup: b.telegramGroup, supportAPI: b.supportAPI,
            updateURL: b.updateURL, userAgent: b.userAgent,
            latencyDisplayRatio: b.latencyDisplayRatio, inviteLink: b.inviteLink,
            apiBaseURLs: b.apiBaseURLs, activeAPIBaseURL: b.activeAPIBaseURL,
            builtInProxy: []
        )
        let provider = try BrandProvider(config: a, theme: theme("A"), logo: logo("A"),
                                         cache: BrandImageCache(directory: dir))
        await provider.apply(result(withoutURL))
        XCTAssertEqual(provider.snapshot.config?.apiBaseURLs, b.apiBaseURLs)
        XCTAssertEqual(provider.snapshot.name, b.appName)
        XCTAssertEqual(provider.snapshot.logo.pngData(), try logo("A").pngData())
    }

    func testFixtureConfigurationUsesOnlyBuildSelectedLogo() async throws {
        let a = try fixture("A"), b = try fixture("B"), dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let calls = ConfigCallCounter()
        let provider = try BrandProvider(config: a, theme: theme("A"), logo: logo("A"),
            cache: BrandImageCache(directory: dir), download: { _ in
                _ = await calls.next()
                return Data("unused".utf8)
            })
        await provider.apply(result(b, source: .fixture))
        await provider.retryRemoteLogoIfNeeded()
        let count = await calls.count()
        XCTAssertEqual(count, 0)
        XCTAssertEqual(provider.snapshot.logo.pngData(), try logo("A").pngData())
    }

    func testAppStartupAppliesRemoteAPIWithoutWaitingForUnavailableLogo() async throws {
        let b = try fixture("B"), dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let withoutLogo = AppConfig(
            appName: b.appName, loginTitle: b.loginTitle, appLogo: nil,
            homePage: b.homePage, telegramGroup: b.telegramGroup, supportAPI: b.supportAPI,
            updateURL: b.updateURL, userAgent: b.userAgent,
            latencyDisplayRatio: b.latencyDisplayRatio, inviteLink: b.inviteLink,
            apiBaseURLs: b.apiBaseURLs, activeAPIBaseURL: b.activeAPIBaseURL,
            builtInProxy: []
        )
        let payload = try JSONEncoder().encode(withoutLogo)
        let configTransport = RecordingNetworkTransport { request, _ in
            (payload, HTTPURLResponse(url: request.url!, statusCode: 200,
                                      httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        }
        let probeTransport = RecordingNetworkTransport { request, _ in
            (Data(#"{"data":{"is_email_verify":1}}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200,
                             httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        }
        let suite = "NetworkClient.config-bootstrap.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let model = AppModel(
            offline: false,
            apiHealthMonitor: APIHealthMonitor(transport: probeTransport, observeNetwork: false),
            remoteConfigService: RemoteConfigService(
                cacheRoot: dir, installationID: "startup-logo-test",
                networkTransport: configTransport
            ),
            sessionStore: SessionStore(keychain: MemorySessionKeychain(), defaultsSuiteName: suite)
        )
        await model.start()
        XCTAssertEqual(model.config?.apiBaseURLs, withoutLogo.apiBaseURLs)
        XCTAssertEqual(model.brand.snapshot.name, withoutLogo.appName)
        XCTAssertEqual(model.brand.logoFingerprint, BrandProvider.installed().logoFingerprint)
        XCTAssertEqual(model.configurationStatus.source, .remote)
        let calls = await configTransport.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testRemoteLogoTimeoutAndHTTP404UseInstallationLogo() async throws {
        let a = try fixture("A"), b = try fixture("B"), dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let timedOut = try BrandProvider(config: a, theme: theme("A"), logo: logo("A"),
                                         cache: BrandImageCache(directory: dir),
                                         download: { _ in throw URLError(.timedOut) })
        await timedOut.apply(result(b))
        XCTAssertEqual(timedOut.snapshot.logo.pngData(), try logo("A").pngData())

        let transport = RecordingNetworkTransport { request, _ in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 404,
                                     httpVersion: nil, headerFields: [:])!)
        }
        let notFound = try BrandProvider(config: a, theme: theme("A"), logo: logo("A"),
                                         cache: BrandImageCache(directory: dir), transport: transport)
        await notFound.apply(result(b))
        XCTAssertEqual(notFound.snapshot.name, b.appName)
        XCTAssertEqual(notFound.snapshot.config?.apiBaseURLs, b.apiBaseURLs)
        XCTAssertEqual(notFound.snapshot.logo.pngData(), try logo("A").pngData())
    }

    func testRemoteLogoRecoveryReplacesInstallationFallback() async throws {
        let a = try fixture("A"), b = try fixture("B"), dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let availability = LogoAvailability()
        let remoteLogo = try XCTUnwrap(logo("B").pngData())
        let provider = try BrandProvider(config: a, theme: theme("A"), logo: logo("A"),
            cache: BrandImageCache(directory: dir), download: { _ in
                guard await availability.isAvailable() else { throw URLError(.notConnectedToInternet) }
                return remoteLogo
            }, logoRetryCooldown: 0)
        await provider.apply(result(b))
        XCTAssertEqual(provider.snapshot.logo.pngData(), try logo("A").pngData())
        await availability.restore()
        await provider.retryRemoteLogoIfNeeded()
        XCTAssertEqual(provider.snapshot.logo.pngData(), remoteLogo)
        XCTAssertEqual(provider.snapshot.config?.apiBaseURLs, b.apiBaseURLs)
    }

    func testCachedRemoteLogoIsReplacedWhenItsSourceRecovers() async throws {
        let a = try fixture("A"), b = try fixture("B"), dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = BrandImageCache(directory: dir)
        let cachedLogo = try XCTUnwrap(logo("B").pngData())
        let refreshedLogo = try XCTUnwrap(logo("A").pngData())
        try await cache.save(cachedLogo, for: XCTUnwrap(b.appLogoURL), brandName: b.appName)
        let availability = LogoAvailability()
        let provider = try BrandProvider(config: a, theme: theme("A"), logo: logo("A"),
            cache: cache, download: { _ in
                guard await availability.isAvailable() else { throw URLError(.notConnectedToInternet) }
                return refreshedLogo
            }, logoRetryCooldown: 0)
        await provider.apply(result(b))
        XCTAssertEqual(provider.snapshot.logo.pngData(), cachedLogo)
        XCTAssertTrue(provider.snapshot.source.contains("Logo 缓存"))
        await availability.restore()
        await provider.retryRemoteLogoIfNeeded()
        XCTAssertEqual(provider.snapshot.logo.pngData(), refreshedLogo)
        XCTAssertFalse(provider.snapshot.source.contains("Logo 缓存"))
    }

    func testRuntimeFallbackLogoIsBuildSelectedResource() async throws {
        let provider = BrandProvider.installed()
        let installedBytes = try Data(contentsOf: Installation.url("BrandLocalLogoResource", extension: "png"))
        let expected = try XCTUnwrap(BrandProvider.decodeLogo(installedBytes))
        let remoteFixture = try fixture("B")
        await provider.apply(result(remoteFixture), networkAllowed: false)
        XCTAssertEqual(provider.snapshot.logo.pngData(), expected.pngData())
        XCTAssertEqual(provider.snapshot.config?.apiBaseURLs, remoteFixture.apiBaseURLs)
    }

    func testFreshCacheLoadsLocallyWithoutLogoOrInviteAndSkipsRefresh() async throws {
        let a = try fixture("A"), dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stripped = AppConfig(
            appName: a.appName, loginTitle: "Remote Login Title", appLogo: nil, homePage: nil,
            telegramGroup: nil, supportAPI: nil, updateURL: nil,
            userAgent: a.userAgent, latencyDisplayRatio: 1, inviteLink: nil,
            apiBaseURLs: a.apiBaseURLs, activeAPIBaseURL: a.activeAPIBaseURL,
            builtInProxy: []
        )
        let payload = try JSONEncoder().encode(stripped)
        let transport = RecordingNetworkTransport { request, _ in
            (payload, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                      headerFields: ["Content-Type": "application/json"])!)
        }
        let service = RemoteConfigService(cacheRoot: dir,
                                          installationID: "fresh-cache-test", networkTransport: transport)
        let remote = try await service.loadConfig(forceRemote: true)
        XCTAssertEqual(remote.source, .remote)
        let local = try await service.loadLocalConfig()
        XCTAssertEqual(local.source, .cache)
        XCTAssertTrue(local.cacheFresh)
        let provider = try BrandProvider(config: a, theme: theme("A"), logo: logo("A"))
        provider.applyConfiguration(local)
        XCTAssertEqual(provider.snapshot.visibleLoginTitle, "Remote Login Title")
        let skipped = try await service.refreshIfNeeded()
        XCTAssertNil(skipped)
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("config-cache.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testStaleValidatedCacheSurvivesFailureAndRefreshCooldown() async throws {
        let a = try fixture("A"), dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let success = RecordingNetworkTransport { request, _ in
            (try JSONEncoder().encode(a), HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        }
        let writer = RemoteConfigService(cacheRoot: dir,
                                         installationID: "stale-test", networkTransport: success)
        _ = try await writer.loadConfig(forceRemote: true)
        let cacheURL = dir.appendingPathComponent("config-cache.json")
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any])
        envelope["updatedAt"] = Int64(Date().addingTimeInterval(-7_200).timeIntervalSince1970 * 1_000)
        try JSONSerialization.data(withJSONObject: envelope).write(to: cacheURL, options: .atomic)
        let failing = RecordingNetworkTransport { _, _ in throw URLError(.notConnectedToInternet) }
        let service = RemoteConfigService(cacheRoot: dir,
                                          installationID: "stale-test", networkTransport: failing)
        let local = try await service.loadLocalConfig()
        XCTAssertEqual(local.source, .cache)
        XCTAssertFalse(local.cacheFresh)
        let provider = try BrandProvider(config: a, theme: theme("A"), logo: logo("A"))
        provider.applyConfiguration(local)
        XCTAssertEqual(provider.snapshot.visibleLoginTitle, a.displayLoginTitle)
        do { _ = try await service.refreshIfNeeded(); XCTFail("Expected a bounded refresh failure") }
        catch { XCTAssertFalse(error is CancellationError) }
        let failedCalls = await failing.calls.count
        XCTAssertGreaterThan(failedCalls, 0)
        let skipped = try await service.refreshIfNeeded()
        XCTAssertNil(skipped)
        let callsAfterCooldown = await failing.calls.count
        XCTAssertEqual(callsAfterCooldown, failedCalls)
        let retained = try await service.loadLocalConfig()
        XCTAssertEqual(retained.config.apiBaseURLs, a.apiBaseURLs)
    }

    func testStaleValidatedCacheIsUsableUntilRemoteRefreshReplacesIt() async throws {
        let a = try fixture("A"), b = try fixture("B"), dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writerTransport = RecordingNetworkTransport { request, _ in
            (try JSONEncoder().encode(a), HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!)
        }
        let writer = RemoteConfigService(
            cacheRoot: dir, installationID: "stale-success-test",
            networkTransport: writerTransport
        )
        _ = try await writer.loadConfig(forceRemote: true)
        let cacheURL = dir.appendingPathComponent("config-cache.json")
        var envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any]
        )
        envelope["updatedAt"] = Int64(
            Date().addingTimeInterval(-7_200).timeIntervalSince1970 * 1_000
        )
        try JSONSerialization.data(withJSONObject: envelope)
            .write(to: cacheURL, options: .atomic)

        let refreshTransport = RecordingNetworkTransport { request, _ in
            (try JSONEncoder().encode(b), HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!)
        }
        let service = RemoteConfigService(
            cacheRoot: dir, installationID: "stale-success-test",
            networkTransport: refreshTransport
        )
        let stale = try await service.loadLocalConfig()
        XCTAssertEqual(stale.source, .cache)
        XCTAssertFalse(stale.cacheFresh)
        XCTAssertEqual(stale.config.appName, a.appName)

        let refreshed = try await service.refreshIfNeeded()
        XCTAssertEqual(refreshed?.source, .remote)
        XCTAssertEqual(refreshed?.config.appName, b.appName)
    }

    func testConcurrentRefreshCallersShareOneDownloadAndEquivalentPathIsIgnored() async throws {
        let a = try fixture("A"), dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transport = RecordingNetworkTransport { request, _ in
            try await Task.sleep(for: .milliseconds(60))
            return (try JSONEncoder().encode(a), HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        }
        let service = RemoteConfigService(cacheRoot: dir,
                                          installationID: "shared-refresh-test", networkTransport: transport)
        async let first = service.refreshIfNeeded()
        async let second = service.refreshIfNeeded()
        let outcomes = try await [first, second]
        XCTAssertEqual(outcomes.compactMap { $0 }.count, 2)
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 1)
        let wifi = APIHealthNetworkPath(status: .satisfied, usedInterfaceTypes: [.wifi],
                                        usedInterfaceIdentifiers: ["wifi"])
        let initial = await service.networkDidChange(path: wifi)
        let duplicate = await service.networkDidChange(path: wifi)
        XCTAssertFalse(initial)
        XCTAssertFalse(duplicate)
        let cellular = APIHealthNetworkPath(status: .satisfied, usedInterfaceTypes: [.cellular],
                                            usedInterfaceIdentifiers: ["cell"], isExpensive: true)
        let changed = await service.networkDidChange(path: cellular)
        XCTAssertTrue(changed)
    }

    func testExpiredCacheRefreshesFromRemote() async throws {
        let b = try fixture("B"), dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transport = RecordingNetworkTransport { request, _ in
            (try JSONEncoder().encode(b), HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        }
        let service = RemoteConfigService(cacheRoot: dir,
                                          installationID: "expired-test", networkTransport: transport)
        do {
            _ = try await service.loadLocalConfig()
            XCTFail("No local cache should be available before the remote refresh")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        let remote = try await service.refreshIfNeeded()
        XCTAssertEqual(remote?.config.appName, b.appName)
        let cached = try await service.loadLocalConfig()
        XCTAssertEqual(cached.source, .cache)
        XCTAssertTrue(cached.cacheFresh)
    }

    func testHTMLResponseCannotCreateRuntimeConfiguration() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let html = RecordingNetworkTransport { request, _ in
            (Data("<html>unavailable</html>".utf8), HTTPURLResponse(url: request.url!,
                statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!)
        }
        let service = RemoteConfigService(cacheRoot: dir,
                                          installationID: "html-test", networkTransport: html)
        do { _ = try await service.refreshIfNeeded(); XCTFail("HTML must fail validation") }
        catch { XCTAssertFalse(error is CancellationError) }
        do {
            _ = try await service.loadLocalConfig()
            XCTFail("HTML must not create a local configuration")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
    }

    func testRemoteRefreshTotalBudgetCancelsSlowSource() async throws {
        let a = try fixture("A"), dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let slow = RecordingNetworkTransport { request, _ in
            try await Task.sleep(for: .seconds(1))
            return (try JSONEncoder().encode(a), HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        }
        let policy = RemoteConfigRefreshPolicy(singleSourceTimeout: 0.5, totalBudget: 0.04,
                                               failedCooldown: 0.1, manualCooldown: 0.1)
        let service = RemoteConfigService(cacheRoot: dir,
                                          installationID: "budget-test", networkTransport: slow,
                                          policy: policy)
        let start = ContinuousClock().now
        do { _ = try await service.refreshIfNeeded(); XCTFail("Expected timeout") }
        catch { XCTAssertFalse(error is CancellationError) }
        XCTAssertLessThan(start.duration(to: ContinuousClock().now), .milliseconds(300))
        do {
            _ = try await service.loadLocalConfig()
            XCTFail("A timed-out first refresh must not create local configuration")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
    }

    func testCancelledOldNetworkResultCannotOverwriteNewCache() async throws {
        let a = try fixture("A"), b = try fixture("B"), dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let counter = ConfigCallCounter()
        let transport = RecordingNetworkTransport { request, _ in
            let turn = await counter.next()
            if turn == 1 { try? await Task.sleep(for: .milliseconds(80)) }
            let payload = try JSONEncoder().encode(turn == 1 ? b : a)
            return (payload, HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        }
        let service = RemoteConfigService(cacheRoot: dir,
                                          installationID: "generation-test", networkTransport: transport)
        let wifi = APIHealthNetworkPath(status: .satisfied, usedInterfaceTypes: [.wifi],
                                        usedInterfaceIdentifiers: ["wifi"])
        let cellular = APIHealthNetworkPath(status: .satisfied, usedInterfaceTypes: [.cellular],
                                            usedInterfaceIdentifiers: ["cell"], isExpensive: true)
        _ = await service.networkDidChange(path: wifi)
        let old = Task { try? await service.refreshIfNeeded(force: true) }
        while await counter.count() == 0 { await Task.yield() }
        let changed = await service.networkDidChange(path: cellular)
        XCTAssertTrue(changed)
        let latest = try await service.refreshIfNeeded(force: false)
        XCTAssertEqual(latest?.config.appName, a.appName)
        _ = await old.value
        let retained = try await service.loadLocalConfig()
        XCTAssertEqual(retained.config.appName, a.appName)
    }

    func testConfigurationPresentationDependsOnlyOnValidatedConfiguration() {
        var status = ConfigurationRuntimeStatus()
        XCTAssertEqual(status.loginPresentation, .initializing)
        status.source = .cache
        XCTAssertEqual(status.loginPresentation, .ready)
        status.refresh = .failed
        XCTAssertEqual(status.loginPresentation, .ready)
        status.source = .unavailable
        XCTAssertEqual(status.loginPresentation, .configurationUnavailable)
        for source in [ConfigurationRuntimeStatus.Source.remote, .cache, .staleCache, .fixture] {
            status.source = source
            XCTAssertEqual(status.loginPresentation, .ready)
        }
    }

    func testAppStartupDoesNotReportServerUnavailableWhenDirectProbeTimesOut() async throws {
        let configured = try fixture("A")
        let probeTransport = RecordingNetworkTransport { _, _ in
            throw URLError(.timedOut)
        }
        let monitor = APIHealthMonitor(
            transport: probeTransport,
            policy: APIHealthPolicy(
                probeTimeout: 0.01,
                totalBudget: 0.05,
                healthyTTL: 120,
                retryCooldown: 10,
                networkDebounce: 0.01,
                maximumConcurrentProbes: 2
            ),
            observeNetwork: false
        )
        let suite = "NetworkClient.login-probe-timeout.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let model = AppModel(
            offline: false,
            apiHealthMonitor: monitor,
            sessionStore: SessionStore(
                keychain: MemorySessionKeychain(),
                defaultsSuiteName: suite
            ),
            initialConfig: configured
        )

        await model.start()
        await monitor.waitForCurrentProbe()
        XCTAssertEqual(model.configurationStatus.loginPresentation, .ready)
        XCTAssertNotNil(model.config)
        let calls = await probeTransport.calls
        XCTAssertEqual(calls.count, configured.apiBaseURLs.count)
    }
}
