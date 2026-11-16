import Foundation

struct RemoteConfigRefreshPolicy: Sendable {
    let singleSourceTimeout: TimeInterval
    let totalBudget: TimeInterval
    let failedCooldown: TimeInterval
    let manualCooldown: TimeInterval

    static let standard = RemoteConfigRefreshPolicy(
        singleSourceTimeout: NetworkTransportPolicy.requestTimeout(for: .remoteConfiguration),
        totalBudget: 30,
        failedCooldown: 30,
        manualCooldown: 0
    )
}

actor RemoteConfigService {
    private static let cacheVersion = CustomerServiceResolver.cacheVersion

    nonisolated static func defaultCacheDirectoryURL(applicationSupportDirectory: URL) -> URL {
        applicationSupportDirectory
            .appendingPathComponent("NetworkClient", isDirectory: true)
            .appendingPathComponent("Config", isDirectory: true)
    }

    private let networkTransport: any NetworkTransport
    private let policy: RemoteConfigRefreshPolicy
    private let recoveryRouter: APIRecoveryRouter
    private let bundle: Bundle
    private let cacheRoot: URL?
    private let installationID: String
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private var current: ConfigLoadResult?
    private var currentReadAt: Date?
    private var lastAttemptAt: Date?
    private var lastFailureAt: Date?
    private var refreshTask: Task<ConfigLoadResult, Error>?
    private var generation: UInt64 = 0
    private var networkPath: APIHealthNetworkPath?

    init(recoveryRouter: APIRecoveryRouter = .shared, bundle: Bundle = .main, cacheRoot: URL? = nil, installationID: String? = nil, transport: URLSession? = nil, networkTransport: (any NetworkTransport)? = nil, policy: RemoteConfigRefreshPolicy = .standard) {
        self.bundle = bundle
        self.cacheRoot = cacheRoot
        self.installationID = installationID ?? Installation.identity
        self.recoveryRouter = recoveryRouter
        self.policy = policy
        self.networkTransport = networkTransport
            ?? transport.map { URLSessionNetworkTransport(session: $0) }
            ?? URLSessionNetworkTransport(profile: .remoteConfiguration)

        decoder = JSONDecoder()
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func loadConfig(forceRemote: Bool = false) async throws -> ConfigLoadResult {
        #if DEBUG
        let diagnosticOperation = DeveloperDiagnosticOperation.make("config")
        DeveloperDiagnostics.shared.record(.init(
            operationID: diagnosticOperation,
            module: .configuration,
            stage: "load",
            outcome: "started",
            detail: "forceRemote=\(forceRemote)"
        ))
        #endif
        let bootstrap = try loadBootstrap()
        let cached = try? readCachedConfig(bootstrap: bootstrap)

        if !forceRemote,
           let cached,
           cached.cacheFresh {
            SafeLog.info(
                "Config load success source=cache cloudConfigIndex=\(cached.cloudConfigIndex ?? 0) "
                    + "cacheAgeSeconds=\(cached.cacheAgeSeconds ?? -1) cacheFresh=true"
            )
            #if DEBUG
            DeveloperDiagnostics.shared.record(.init(
                operationID: diagnosticOperation, module: .configuration, level: .success,
                stage: "cache", outcome: "fresh-hit",
                detail: "ageSeconds=\(cached.cacheAgeSeconds ?? -1)"
            ))
            #endif
            return cached
        }

        do {
            return try await refreshRemoteConfig(
                bootstrap: bootstrap,
                initialUserAgent: cached?.config.safeUserAgent.nilIfEmpty,
                // A first installation has no trusted recovery configuration.
                // Only a previously validated remote cache may contribute
                // recovery nodes during the next configuration refresh.
                cachedBuiltInProxy: cached?.config.builtInProxy ?? []
            )
        } catch {
            if let cached {
                SafeLog.warning(
                    "Config remote refresh failed; using cache cacheAgeSeconds=\(cached.cacheAgeSeconds ?? -1) "
                        + "errorCategory=remote_refresh"
                )
                #if DEBUG
                DeveloperDiagnostics.shared.record(.init(
                    operationID: diagnosticOperation, module: .configuration, level: .warning,
                    stage: "remote", outcome: "cache-fallback",
                    detail: "ageSeconds=\(cached.cacheAgeSeconds ?? -1)"
                ))
                #endif
                return cached
            }
            #if DEBUG
            DeveloperDiagnostics.shared.record(.init(
                operationID: diagnosticOperation, module: .configuration, level: .error,
                stage: "load", outcome: "unavailable"
            ))
            #endif
            throw NetworkClientError.configUnavailable("客户端配置暂时无法获取，请检查网络后重试")
        }
    }

    /// Validated local configuration is usable before any remote source or logo
    /// finishes. An expired cache remains distinct from a corrupt cache.
    func loadLocalConfig() throws -> ConfigLoadResult {
        #if DEBUG
        let diagnosticOperation = DeveloperDiagnosticOperation.make("bootstrap")
        #endif
        let bootstrap = try loadBootstrap()
        if let cached = try readCachedConfig(bootstrap: bootstrap) {
            current = cached
            currentReadAt = Date()
            #if DEBUG
            DeveloperDiagnostics.shared.record(.init(
                operationID: diagnosticOperation, module: .configuration, level: .success,
                stage: "local-config", outcome: cached.cacheFresh ? "cache-fresh" : "cache-stale"
            ))
            #endif
            return cached
        }
        #if DEBUG
        DeveloperDiagnostics.shared.record(.init(
            operationID: diagnosticOperation, module: .configuration, level: .warning,
            stage: "local-config", outcome: "unavailable"
        ))
        #endif
        throw NetworkClientError.configUnavailable("本地没有可用的服务配置")
    }

    /// Returns nil when a validated, fresh cache or a recent failed attempt
    /// makes another download unnecessary. Concurrent callers await one task.
    func refreshIfNeeded(force: Bool = false) async throws -> ConfigLoadResult? {
        if let refreshTask { return try await refreshTask.value }
        let bootstrap = try loadBootstrap()
        let now = Date()
        if !force, let current,
           let readAt = currentReadAt, let cachedAge = current.cacheAgeSeconds,
           Double(cachedAge) + now.timeIntervalSince(readAt) < Double(bootstrap.cloudUpdateHours) * 3_600 {
            return nil
        }
        let cooldown = force ? policy.manualCooldown : policy.failedCooldown
        if let lastFailureAt, now.timeIntervalSince(lastFailureAt) < cooldown { return nil }
        let expectedGeneration = generation
        lastAttemptAt = now
        SafeLog.info("[Config] refreshStart reason=\(force ? "manual" : "automatic") sourceCount=\(bootstrap.cloudConfig.count)")
        let task = Task<ConfigLoadResult, Error> {
            try await self.refreshRemoteConfig(
                bootstrap: bootstrap,
                initialUserAgent: self.current?.config.safeUserAgent.nilIfEmpty,
                cachedBuiltInProxy: self.current?.config.builtInProxy ?? [],
                expectedGeneration: expectedGeneration
            )
        }
        refreshTask = task
        do {
            let result = try await task.value
            if generation == expectedGeneration {
                refreshTask = nil
                current = result
                currentReadAt = Date()
                lastFailureAt = nil
            }
            return result
        } catch {
            if generation == expectedGeneration {
                refreshTask = nil
                if !(error is CancellationError) { lastFailureAt = Date() }
            }
            throw error
        }
    }

    /// A value comparison prevents repeated NWPath callbacks from invalidating
    /// the configuration task. The caller decides when to schedule a refresh.
    func networkDidChange(path: APIHealthNetworkPath) -> Bool {
        defer { networkPath = path }
        guard let previous = networkPath else { return false }
        guard previous != path else { return false }
        generation &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        SafeLog.info("[Config] pathChanged fields=\(path.safeChangedFields(from: previous)) link=\(path.safeInterfaceCategory)")
        return path.isReachable
    }

    func cancelRefresh() {
        generation &+= 1
        refreshTask?.cancel()
        refreshTask = nil
    }

    func remainingFailureCooldown() -> TimeInterval? {
        guard let lastFailureAt else { return nil }
        let remaining = policy.failedCooldown - Date().timeIntervalSince(lastFailureAt)
        return remaining > 0 ? remaining : nil
    }

    private func loadBootstrap() throws -> BootstrapConfig {
        guard let url = bundle.url(forResource: Installation.string("BrandBootstrapResource", bundle: bundle), withExtension: "json") else {
            throw NetworkClientError.bootstrapInvalid("应用包中缺少 bootstrap.json")
        }
        let data = try Data(contentsOf: url)
        let decoded: BootstrapConfig
        do {
            decoded = try decoder.decode(BootstrapConfig.self, from: data)
        } catch {
            throw NetworkClientError.bootstrapInvalid("bootstrap.json 格式错误")
        }

        var seen = Set<String>()
        let sources = decoded.cloudConfig.compactMap { value -> String? in
            let text = value.trimmed
            guard let url = URL(string: text),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || (scheme == "http" && Self.isLocalHost(url.host)) else {
                return nil
            }
            let key = text.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return text
        }
        guard !sources.isEmpty else {
            throw NetworkClientError.bootstrapInvalid("bootstrap.json 至少需要一个有效的 CloudConfig 地址")
        }

        return BootstrapConfig(
            cloudConfig: sources,
            cloudUpdateHours: decoded.cloudUpdateHours
        )
    }

    private func refreshRemoteConfig(
        bootstrap: BootstrapConfig,
        initialUserAgent: String?,
        cachedBuiltInProxy: [String],
        expectedGeneration: UInt64? = nil
    ) async throws -> ConfigLoadResult {
        #if DEBUG
        let diagnosticOperation = DeveloperDiagnosticOperation.make("config-refresh")
        let diagnosticStarted = Date()
        DeveloperDiagnostics.shared.record(.init(
            operationID: diagnosticOperation, module: .configuration,
            stage: "remote-refresh", outcome: "started",
            timeoutMilliseconds: Int((policy.totalBudget * 1_000).rounded()),
            detail: "sourceCount=\(bootstrap.cloudConfig.count) recoveryCandidates=\(cachedBuiltInProxy.count)"
        ))
        #endif
        SafeLog.info(
            "Config remote load started cloudConfigCount=\(bootstrap.cloudConfig.count) "
                + "singleTimeoutSeconds=\(policy.singleSourceTimeout) recoveryProxyCount=\(cachedBuiltInProxy.count)"
        )
        let plan = APIRecoveryPlan(
            targets: bootstrap.cloudConfig,
            builtInProxy: cachedBuiltInProxy
        )
        let downloaded: RoutedRemoteConfig = try await withThrowingTaskGroup(of: RoutedRemoteConfig.self) { group in
            group.addTask {
                try await self.recoveryRouter.safeRetry(plan: plan, budget: .seconds(self.policy.totalBudget)) { route in
            do {
                let config = try await self.downloadConfig(
                    source: route.target,
                    cloudConfigIndex: route.targetIndex,
                    userAgent: initialUserAgent,
                    timeout: self.policy.singleSourceTimeout,
                    routeTransport: route.transport
                )
                return RoutedRemoteConfig(
                    config: config,
                    source: route.target,
                    sourceIndex: route.targetIndex
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as NetworkClientError {
                SafeLog.warning(
                    "CloudConfig failed cloudConfigIndex=\(route.targetIndex) "
                        + "recovery=\(route.transport != nil) category=\(error.logCategory)"
                )
                throw error
            } catch {
                SafeLog.warning(
                    "CloudConfig failed cloudConfigIndex=\(route.targetIndex) "
                        + "recovery=\(route.transport != nil) category=transport"
                )
                throw NetworkClientError.transport("CloudConfig 网络请求失败")
            }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(self.policy.totalBudget))
                throw NetworkClientError.transport("配置刷新超时")
            }
            guard let first = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            return first
        }
        try Task.checkCancellation()
        if let expectedGeneration, expectedGeneration != generation { throw CancellationError() }
        try saveCache(
            config: downloaded.config,
            source: downloaded.source,
            sourceIndex: downloaded.sourceIndex
        )
        SafeLog.info(
            "Config load success source=remote cloudConfigIndex=\(downloaded.sourceIndex) "
                + "apiBaseUrlsCount=\(downloaded.config.apiBaseURLs.count) "
                + "builtInProxyCount=\(downloaded.config.builtInProxy.count)"
        )
        #if DEBUG
        DeveloperDiagnostics.shared.record(.init(
            operationID: diagnosticOperation, module: .configuration, level: .success,
            stage: "remote-refresh", outcome: "validated",
            elapsedMilliseconds: Int(Date().timeIntervalSince(diagnosticStarted) * 1_000),
            attempt: downloaded.sourceIndex,
            detail: "apiCandidates=\(downloaded.config.apiBaseURLs.count) recoveryCandidates=\(downloaded.config.builtInProxy.count)"
        ))
        #endif
        return ConfigLoadResult(
            config: downloaded.config,
            source: .remote,
            cloudConfigIndex: downloaded.sourceIndex,
            cloudConfigURL: downloaded.source,
            cacheAgeSeconds: 0,
            cacheFresh: true
        )
    }

    private func downloadConfig(
        source: String,
        cloudConfigIndex: Int,
        userAgent: String?,
        timeout: TimeInterval,
        routeTransport: (any NetworkTransport)?
    ) async throws -> AppConfig {
        guard let url = URL(string: source) else {
            throw NetworkClientError.configInvalid("CloudConfig 地址无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = max(1, timeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await (routeTransport ?? networkTransport).data(for: request, kind: .remoteConfiguration)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled || Task.isCancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw NetworkClientError.fromTransport(error)
        } catch {
            throw NetworkClientError.transport("CloudConfig 网络请求失败")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkClientError.configInvalid("CloudConfig 响应无效")
        }
        SafeLog.info(
            "CloudConfig response cloudConfigIndex=\(cloudConfigIndex) http=\(httpResponse.statusCode)"
        )
        guard (200...299).contains(httpResponse.statusCode) else {
            throw NetworkClientError.server(
                "CloudConfig 返回 HTTP \(httpResponse.statusCode)",
                retryable: httpResponse.statusCode >= 500
            )
        }

        do {
            return try BrandProvider.validate(decoder.decode(AppConfig.self, from: data))
        } catch let error as NetworkClientError {
            throw error
        } catch {
            throw NetworkClientError.configInvalid("CloudConfig JSON 格式错误")
        }
    }

    private func readCachedConfig(bootstrap: BootstrapConfig) throws -> ConfigLoadResult? {
        let url = try cacheFileURL(createDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let data = try Data(contentsOf: url)
        let envelope = try decoder.decode(CachedConfigEnvelope.self, from: data)
        guard envelope.updatedAt > 0,
              let cachedConfig = CustomerServiceResolver.configFromCache(envelope.config, version: envelope.cacheVersion) else {
            throw NetworkClientError.configInvalid("配置缓存版本无效")
        }

        let config = try BrandProvider.validate(cachedConfig)
        guard envelope.installationID == installationID else {
            throw NetworkClientError.configInvalid("缓存不属于当前配置安装")
        }
        // Tighten an existing compatible cache in place. Never delete or
        // rewrite legacy data merely to add file protection.
        try FileManager.default.setAttributes(Self.protectedFileAttributes, ofItemAtPath: url.path)
        try FileManager.default.setAttributes(Self.protectedDirectoryAttributes,
                                              ofItemAtPath: url.deletingLastPathComponent().path)
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let ageMilliseconds = max(0, now - envelope.updatedAt)
        let ttlMilliseconds = Int64(bootstrap.cloudUpdateHours) * 60 * 60 * 1_000
        return ConfigLoadResult(
            config: config,
            source: .cache,
            cloudConfigIndex: envelope.cloudConfigIndex,
            cloudConfigURL: envelope.cloudConfigURL,
            cacheAgeSeconds: ageMilliseconds / 1_000,
            cacheFresh: envelope.cacheVersion == Self.cacheVersion && ageMilliseconds < ttlMilliseconds
        )
    }

    private func saveCache(config: AppConfig, source: String, sourceIndex: Int) throws {
        let envelope = CachedConfigEnvelope(
            installationID: installationID,
            cacheVersion: Self.cacheVersion,
            updatedAt: Int64(Date().timeIntervalSince1970 * 1_000),
            cloudConfigIndex: sourceIndex,
            cloudConfigURL: source,
            config: config
        )
        let data = try encoder.encode(envelope)
        let url = try cacheFileURL(createDirectory: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(Self.protectedFileAttributes, ofItemAtPath: url.path)
        SafeLog.info("Config cache write result=true")
    }

    private func cacheFileURL(createDirectory: Bool) throws -> URL {
        if let cacheRoot {
            if createDirectory {
                try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true,
                                                        attributes: Self.protectedDirectoryAttributes)
            }
            return cacheRoot.appendingPathComponent("config-cache.json")
        }
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: createDirectory
        )
        let directory = Self.defaultCacheDirectoryURL(
            applicationSupportDirectory: applicationSupport
        )
        if createDirectory {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: Self.protectedDirectoryAttributes
            )
        }
        return directory.appendingPathComponent("config-cache.json")
    }

    private static var protectedDirectoryAttributes: [FileAttributeKey: Any] {
        [.posixPermissions: 0o700, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    }

    private static var protectedFileAttributes: [FileAttributeKey: Any] {
        [.posixPermissions: 0o600, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    }

    private static func isLocalHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

private struct CachedConfigEnvelope: Codable, Sendable {
    let installationID: String?
    let cacheVersion: Int
    let updatedAt: Int64
    let cloudConfigIndex: Int
    let cloudConfigURL: String
    let config: AppConfig
}

private struct RoutedRemoteConfig: Sendable {
    let config: AppConfig
    let source: String
    let sourceIndex: Int
}
