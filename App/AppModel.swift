import SwiftUI
import Combine
import Network

enum VPNConnectionPreflightError: Error, Equatable, Sendable {
    case noNodeSelected
    case selectedNodeMissing
    case nodeConfigurationInvalid
}

enum PasswordChangeSessionInvalidationOutcome: Equatable, Sendable {
    case invalidated(storageCleared: Bool)
    case stale
}

/// Read-only bridge used only by subscription routing policy. It never starts,
/// stops, or otherwise mutates the system VPN controller.
@MainActor
private final class SubscriptionVPNStateReader: @unchecked Sendable {
    private weak var controller: MinimalVPNController?

    func attach(_ controller: MinimalVPNController) {
        self.controller = controller
    }

    func isSystemVPNActive() -> Bool {
        controller?.state != .disconnected
    }
}

protocol NodeHTTPProbing: Sendable {
    func probeNode(yaml: String, coreName: String) async throws -> Int
    func probeBatch(
        _ candidates: [NodeProbeCandidate],
        onStart: @escaping @Sendable (NodeProbeCandidate) async -> Bool,
        onResult: @escaping @Sendable (NodeProbeResult) async -> Void
    ) async throws
    func quiesce() async
}

extension NodeHTTPProbing {
    func quiesce() async {}

    // Fakes and alternative implementations retain a safe sequential default.
    // The production runtime overrides this to load one Core and probe its
    // named outbounds with a bounded worker pool.
    func probeBatch(
        _ candidates: [NodeProbeCandidate],
        onStart: @escaping @Sendable (NodeProbeCandidate) async -> Bool,
        onResult: @escaping @Sendable (NodeProbeResult) async -> Void
    ) async throws {
        for candidate in candidates {
            try Task.checkCancellation()
            guard await onStart(candidate) else { throw CancellationError() }
            let outcome: NodeProbeOutcome
            do {
                outcome = .measured(try await probeNode(
                    yaml: candidate.yaml, coreName: candidate.coreName
                ))
            } catch MihomoNodeProbeError.timeout {
                outcome = .timedOut
            } catch is RecoveryRuntimeError {
                outcome = .unavailable
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                outcome = .failed
            }
            await onResult(NodeProbeResult(
                nodeID: candidate.nodeID, revision: candidate.revision,
                outcome: outcome
            ))
        }
    }
}

extension MihomoAppRecoveryRuntime: NodeHTTPProbing {}

@MainActor
protocol ConnectedNodeProbing: AnyObject, Sendable {
    var nodeProbeState: MinimalVPNController.State { get }
    var nodeProbeCandidatePoolRevision: String? { get }
    func probeNodes(
        coreNames: [String], candidatePoolRevision: String?
    ) async throws -> [MihomoTunnelNodeProbeResult]
}

extension MinimalVPNController: @unchecked Sendable, ConnectedNodeProbing {
    var nodeProbeState: State { state }
    var nodeProbeCandidatePoolRevision: String? { activeCandidatePoolRevision }
}

struct NodeProbeCandidate: Sendable {
    let nodeID: String
    let revision: String
    let coreName: String
    let yaml: String
}

enum NodeProbeOutcome: Sendable, Equatable {
    case measured(Int), timedOut, failed, unavailable
}

struct NodeProbeResult: Sendable {
    let nodeID: String
    let revision: String
    let outcome: NodeProbeOutcome
}

/// A rolling pool limits active Core HTTP requests and starts a replacement
/// only after one result has been delivered. Cancelled work is never replaced.
enum NodeProbePool {
    static let maximumConcurrent = 10

    @discardableResult
    static func run(
        _ candidates: [NodeProbeCandidate],
        maximumConcurrent: Int = 10,
        stagger: @escaping @Sendable () -> UInt64 = { 0 },
        probe: @escaping @Sendable (String) async -> NodeProbeOutcome,
        shouldContinue: @escaping @Sendable () async -> Bool = { true },
        onStart: @escaping @Sendable (NodeProbeCandidate) async -> Bool = { _ in true },
        onResult: @escaping @Sendable (NodeProbeResult) async -> Void
    ) async -> Int {
        var nextIndex = 0
        let activity = NodeProbeActivity()
        await withTaskGroup(of: NodeProbeResult?.self) { group in
            func addNext() {
                guard nextIndex < candidates.count, !Task.isCancelled else { return }
                let candidate = candidates[nextIndex]
                nextIndex += 1
                group.addTask {
                    do {
                        try await Task.sleep(nanoseconds: stagger())
                        try Task.checkCancellation()
                        guard await onStart(candidate) else { return nil }
                        try Task.checkCancellation()
                        await activity.begin()
                        let outcome = await probe(candidate.coreName)
                        await activity.end()
                        try Task.checkCancellation()
                        return NodeProbeResult(
                            nodeID: candidate.nodeID, revision: candidate.revision,
                            outcome: outcome
                        )
                    } catch { return nil }
                }
            }
            for _ in 0..<min(Self.maximumConcurrent, max(1, maximumConcurrent),
                             candidates.count) { addNext() }
            while let result = await group.next() {
                guard !Task.isCancelled, await shouldContinue() else {
                    group.cancelAll()
                    break
                }
                if let result { await onResult(result) }
                addNext()
            }
            group.cancelAll()
        }
        return await activity.maximum()
    }
}

private actor NodeProbeActivity {
    private var active = 0
    private var peak = 0
    func begin() {
        active += 1
        peak = max(peak, active)
    }
    func end() { active -= 1 }
    func maximum() -> Int { peak }
}

struct NodeLatencyReading: Equatable, Sendable {
    let actualMilliseconds: Int
    let displayMilliseconds: Int

    init?(actualMilliseconds: Int, displayRatio: Double) {
        guard actualMilliseconds >= 0 else { return nil }
        let ratio = displayRatio.isFinite && (0.1...10.0).contains(displayRatio)
            ? displayRatio : 1.0
        let rounded = (Double(actualMilliseconds) * ratio).rounded()
        self.actualMilliseconds = actualMilliseconds
        self.displayMilliseconds = rounded.isFinite && rounded < Double(Int.max)
            ? max(0, Int(rounded)) : Int.max
    }
}

enum NodeLatencyState: Equatable, Sendable {
    case testing, measured(NodeLatencyReading), timedOut, failed, unavailable
}

struct NodeLatencyProgress: Equatable, Sendable {
    let completed: Int
    let total: Int
    static let idle = NodeLatencyProgress(completed: 0, total: 0)
}

protocol AuthenticatedBusinessDataProviding: Sendable {
    func refreshHomeAccount(
        config: AppConfig,
        session: UserSession
    ) async throws -> HomeAccountRefreshResult
    func fetchPlans(config: AppConfig, session: UserSession) async throws -> [PurchasePlan]
    func fetchHomeNotices(config: AppConfig, session: UserSession) async throws -> [HomeNotice]
}

extension V2BoardAPIClient: AuthenticatedBusinessDataProviding {}

protocol TrafficLogProviding: Sendable {
    func fetchTrafficLog(
        config: AppConfig,
        session: UserSession
    ) async throws -> [ProfileTrafficLogRecord]
}

extension V2BoardAPIClient: TrafficLogProviding {}

protocol StoredSessionVerifying: Sendable {
    func verifyStoredSession(
        config: AppConfig,
        session: UserSession
    ) async throws -> UserSession
}

extension V2BoardAPIClient: StoredSessionVerifying {}

enum AuthenticatedSessionSource: String, Sendable {
    case login
    case restored
}

enum AuthTaskKind: Sendable, Equatable {
    case login, registrationConfig, registerCode, resetCode, register, reset
}

enum BusinessRefreshPolicy {
    static let accountInterval: TimeInterval = 3 * 60
    static let plansInterval: TimeInterval = 10 * 60
    static let noticesInterval: TimeInterval = 15 * 60
    static let failedAttemptCooldown: TimeInterval = 30
}

@MainActor
enum NodeHotSwitchFinalizer {
    @discardableResult
    static func apply(
        requestID: UUID,
        currentRequestID: UUID?,
        targetCoreName: String,
        result: MihomoTunnelControlResult,
        contextMatches: Bool,
        commit: @MainActor () async throws -> Void,
        rollback: @MainActor () async -> Void
    ) async -> Bool {
        guard currentRequestID == requestID,
              contextMatches,
              result.switchApplied == true,
              result.confirmedTargetCoreName == targetCoreName else { return false }
        do {
            try await commit()
            return true
        } catch {
            await rollback()
            return false
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var config: AppConfig?
    @Published private(set) var configSourceKey = L10nKey.configSourceNotLoaded
    @Published private(set) var configurationStatus = ConfigurationRuntimeStatus()
    @Published private(set) var session: UserSession?
    @Published private(set) var nodes = NodeRepositorySnapshot.empty
    @Published private(set) var selectedTunnelRevision: String?
    @Published private(set) var plans: [PurchasePlan] = []
    @Published private(set) var orders: [PurchaseOrderRecord] = []
    @Published private(set) var notices: [HomeNotice] = []
    /// Advances only after a current authenticated notice network response is
    /// successfully committed. Presentation uses it as an in-memory load-round
    /// token; it is not a read/seen marker and is never persisted.
    @Published private(set) var noticesLoadRevision: UInt64 = 0
    @Published private(set) var invitations: ProfileInviteInfo?
    @Published private(set) var dailyTraffic: [ProfileDailyTraffic] = []
    @Published private(set) var trafficLoadState = ProfileTrafficState.idle
    @Published private(set) var invitationActionInProgress = false
    @Published private(set) var invitationFeedback: LocalizedMessage?
    @Published private(set) var registration: V2BoardRegistrationConfig?
    @Published private(set) var paymentMethods: [PurchasePaymentMethod] = []
    @Published private(set) var ordersLoadState = BusinessDataLoadState.idle
    @Published private(set) var invitationsLoadState = BusinessDataLoadState.idle
    @Published private(set) var paymentMethodsLoadState = BusinessDataLoadState.idle
    @Published private(set) var checkout: OwnedPurchaseCheckout?
    @Published private(set) var accountLoadState = BusinessDataLoadState.idle
    @Published private(set) var plansLoadState = BusinessDataLoadState.idle
    @Published private(set) var nodesLoadState = BusinessDataLoadState.idle
    @Published private var latencyReadingsSnapshot: [String: NodeLatencyState] = [:]
    private let latencyCoordinator = NodeLatencyCoordinator()
    private(set) var nodeLatencies: [String: NodeLatencyState] {
        get { latencyCoordinator.readings }
        set {
            latencyCoordinator.replaceReadings(newValue)
            latencyReadingsSnapshot = newValue
        }
    }
    @Published private(set) var testingAllNodes = false
    @Published private(set) var testingNodeIDs: Set<String> = []
    @Published private(set) var nodeLatencyProgress = NodeLatencyProgress.idle
    @Published private(set) var nodeSwitchInFlight = false
    @Published private(set) var noticesLoadState = BusinessDataLoadState.idle
    @Published private(set) var changePasswordState = ProfileChangePasswordState.idle
    @Published private(set) var accountDeletionRequestState = ProfileAccountDeletionRequestState.idle
    @Published private(set) var appUpdateCheckState = AppUpdateCheckState.idle
    @Published private(set) var busy = false
    @Published private(set) var showsGlobalBusyIndicator = false
    @Published var message: LocalizedMessage?
    @Published var authMessage: LocalizedMessage?
    @Published private(set) var authTask: AuthTaskKind?
    @Published private(set) var authFeedbackKind: AuthTaskKind?
    let brand: BrandProvider
    let api: V2BoardAPIClient
    let sessions: SessionStore
    let repository: any NodeRepositoryProtocol
    let remote: RemoteConfigService
    let apiHealthMonitor: APIHealthMonitor
    let pendingPayments: PendingPaymentStore
    let userSystemLogger: UserSystemLogger
    let offline: Bool
    private weak var vpnController: MinimalVPNController?
    private weak var connectedNodeProber: (any ConnectedNodeProbing)?
    private var activeNodeSwitchRequestID: UUID?
    private let nodeSession = NodeSessionCoordinator()
    private let nodeProber: any NodeHTTPProbing
    private let appOnlyRuntime: MihomoAppRecoveryRuntime
    private let apiRecoveryRouter: APIRecoveryRouter
    private let subscriptionVPNStateReader: SubscriptionVPNStateReader
    private let hasInjectedInitialConfig: Bool
    private let businessDataAPI: any AuthenticatedBusinessDataProviding
    private let trafficLogAPI: any TrafficLogProviding
    private let sessionVerifier: any StoredSessionVerifying
    private let appUpdateService: any AppUpdateChecking
    private var started = false
    /// A valid persisted credential may outlive a temporary configuration
    /// outage. It stays in secure storage and is verified only after a trusted
    /// remote/cache configuration becomes available again.
    private var pendingStoredSession: UserSession?
    private var configForeground = true
    private var configNetworkMonitor: NWPathMonitor?
    private var configNetworkRefreshTask: Task<Void, Never>?
    private var configRefreshTask: Task<Void, Never>?
    private var configRefreshGeneration: UInt64 = 0
    private var brandLogoTask: Task<Void, Never>?
    private var logoRecoveryTask: Task<Void, Never>?
    private var authenticatedGeneration = UUID()
    /// Opaque identity for UI recovery work. It lets a payment recovery task
    /// reject a completion from an older authenticated generation without
    /// exposing credentials or persistence details to the presentation layer.
    var commerceRecoveryGeneration: UUID { authenticatedGeneration }
    var noticePresentationAccountScope: String? {
        session.map(Self.accountScope(for:))
    }
    var noticePresentationGeneration: UUID? {
        session == nil ? nil : authenticatedGeneration
    }
    private var activeAccountScope: String?
    private var accountRefreshTask: Task<Void, Never>?
    private struct PaymentStatusCheckKey: Hashable {
        let generation: UUID
        let accountScope: String?
        let authData: String?
        let tradeNo: String
    }

    private var paymentStatusChecks: [PaymentStatusCheckKey: (
        id: UUID,
        task: Task<PurchasePaymentStatusCheckOutcome, Never>
    )] = [:]
    private var plansRefreshTask: Task<Void, Never>?
    private var noticesRefreshTask: Task<Void, Never>?
    private var trafficRefreshTask: (id: UUID, task: Task<Void, Never>)?
    private var appUpdateCheckTask: (
        id: UUID,
        identity: AppUpdateConfigurationIdentity,
        task: Task<AppUpdateRelease, Error>
    )?
    private var registrationConfigTask: (
        id: UUID,
        config: AppConfig,
        task: Task<V2BoardRegistrationConfig, Error>
    )?
    private var accountRefreshedAt: Date?
    private var plansRefreshedAt: Date?
    private var nodesRefreshedAt: Date?
    var lastNodesRefreshedAt: Date? { nodesRefreshedAt }
    #if DEBUG
    func setNodeRefreshDateForTesting(_ date: Date) { nodesRefreshedAt = date }
    var latencyWillCommitForTesting: (@MainActor (String) async -> Void)?
    var nodeRefreshDidCommitForTesting: (@MainActor () async -> Void)?
    var nodeSelectionDidPersistForTesting: (@MainActor () async -> Void)?
    #endif
    private var noticesRefreshedAt: Date?
    private var accountAttemptedAt: Date?
    private var plansAttemptedAt: Date?
    private var nodesAttemptedAt: Date?
    private var noticesAttemptedAt: Date?
    #if DEBUG
    private let startupDiagnosticOperationID = DeveloperDiagnosticOperation.make("startup")
    private var activeAuthDiagnosticOperationID: String?
    #endif

    private struct CachedValue<Value> {
        let value: Value
        let refreshedAt: Date
    }

    private var plansCache: [String: CachedValue<[PurchasePlan]>] = [:]
    private var noticesCache: [String: CachedValue<[HomeNotice]>] = [:]

    func attachVPNController(_ controller: MinimalVPNController) {
        vpnController = controller
        connectedNodeProber = controller
        subscriptionVPNStateReader.attach(controller)
    }

    /// The formal tunnel cannot start beside the App-only recovery Core.
    /// Freeze admission before joining probes and require the Router's close
    /// confirmation before MinimalVPNController is allowed to touch NE start.
    func prepareAppRecoveryForFormalVPN() async throws {
        await apiRecoveryRouter.beginSystemVPNTakeover()
        await appOnlyRuntime.quiesce()
        try await apiRecoveryRouter.closeRecoveryForSystemVPN()
    }

    /// Only an explicit system `.disconnected` observation may reopen recovery.
    /// Unknown, unavailable and every transitional/active state stay fail-closed.
    func setAppRecoveryAllowedForFormalVPN(_ allowed: Bool) async {
        await apiRecoveryRouter.finishSystemVPNTakeover(keepSuspended: !allowed)
    }

    init(
        offline: Bool = ProcessInfo.processInfo.arguments.contains("--offline")
            || ProcessInfo.processInfo.environment["NETWORKCLIENT_OFFLINE"] == "1",
        businessDataAPI: (any AuthenticatedBusinessDataProviding)? = nil,
        trafficLogAPI: (any TrafficLogProviding)? = nil,
        sessionVerifier: (any StoredSessionVerifying)? = nil,
        nodeRepository: (any NodeRepositoryProtocol)? = nil,
        apiHealthMonitor: APIHealthMonitor? = nil,
        remoteConfigService: RemoteConfigService? = nil,
        sessionStore: SessionStore? = nil,
        initialConfig: AppConfig? = nil,
        nodeProber: (any NodeHTTPProbing)? = nil,
        connectedNodeProber: (any ConnectedNodeProbing)? = nil,
        recoveryRouter: APIRecoveryRouter? = nil,
        apiClient: V2BoardAPIClient? = nil,
        appUpdateService: (any AppUpdateChecking)? = nil,
        pendingPaymentStore: PendingPaymentStore? = nil,
        userSystemLogger: UserSystemLogger = .shared
    ) {
        self.offline = offline
        hasInjectedInitialConfig = initialConfig != nil
        brand = BrandProvider.installed(transport: URLSessionNetworkTransport(profile: .brandResource))
        let healthMonitor = apiHealthMonitor ?? APIHealthMonitor()
        self.apiHealthMonitor = healthMonitor
        let appOnlyRuntime = MihomoAppRecoveryRuntime()
        self.appOnlyRuntime = appOnlyRuntime
        self.nodeProber = nodeProber ?? appOnlyRuntime
        self.connectedNodeProber = connectedNodeProber
        let router = recoveryRouter ?? APIRecoveryRouter(
            recoveryRuntime: appOnlyRuntime,
            recoveryInitiallySuspendedForFormalVPN: true
        )
        apiRecoveryRouter = router
        let subscriptionVPNStateReader = SubscriptionVPNStateReader()
        self.subscriptionVPNStateReader = subscriptionVPNStateReader
        let liveAPI = apiClient ?? V2BoardAPIClient(
            recoveryRouter: router,
            transport: URLSessionNetworkTransport(profile: .api)
        )
        api = liveAPI
        remote = remoteConfigService ?? RemoteConfigService(
            recoveryRouter: router,
            networkTransport: URLSessionNetworkTransport(profile: .remoteConfiguration)
        )
        sessions = sessionStore ?? SessionStore()
        let liveRepository = nodeRepository ?? NodeRepository(
            subscriptionInfoProvider: liveAPI,
            subscriptionFetcher: SubscriptionFetcher(
                transport: URLSessionNetworkTransport(profile: .subscription),
                physicalNetworkTransport: PhysicalNetworkSubscriptionTransport(),
                isSystemVPNActive: {
                    await subscriptionVPNStateReader.isSystemVPNActive()
                },
                recoveryRouter: router
            )
        )
        repository = liveRepository
        self.businessDataAPI = businessDataAPI ?? liveAPI
        self.trafficLogAPI = trafficLogAPI ?? liveAPI
        self.sessionVerifier = sessionVerifier ?? liveAPI
        self.appUpdateService = appUpdateService ?? AppUpdateService()
        pendingPayments = pendingPaymentStore ?? PendingPaymentStore()
        self.userSystemLogger = userSystemLogger
        if let initialConfig {
            config = initialConfig
            configSourceKey = L10nKey.configSourceTest
            configurationStatus.source = .fixture
            _ = brand.applyConfiguration(ConfigLoadResult(
                config: initialConfig,
                source: .fixture,
                cloudConfigIndex: nil,
                cloudConfigURL: nil,
                cacheAgeSeconds: nil,
                cacheFresh: true
            ))
        }
    }

    deinit {
        appUpdateCheckTask?.task.cancel()
    }

    func start() async {
        guard !started else { return }
        started = true
        #if DEBUG
        DeveloperDiagnostics.shared.record(.init(
            operationID: startupDiagnosticOperationID,
            module: .app,
            stage: "cold-start",
            outcome: "started"
        ))
        #endif
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-config-unavailable") {
            config = nil
            configurationStatus.source = .unavailable
            configurationStatus.refresh = .failed
            return
        }
        #endif
        if offline {
            #if DEBUG
            if config == nil {
                do {
                    let fixture = try Installation.testFixture
                    await acceptConfiguration(ConfigLoadResult(
                        config: fixture,
                        source: .fixture,
                        cloudConfigIndex: nil,
                        cloudConfigURL: nil,
                        cacheAgeSeconds: nil,
                        cacheFresh: true
                    ))
                } catch {
                    configurationStatus.source = .unavailable
                    configurationStatus.refresh = .failed
                    authMessage = .localized(L10nKey.offlineFixtureFailed)
                }
            }
            configSourceKey = L10nKey.configSourceOffline
            DeveloperDiagnostics.shared.record(.init(
                operationID: startupDiagnosticOperationID,
                module: .configuration,
                stage: "bootstrap",
                outcome: "offline-fixture"
            ))
            if ProcessInfo.processInfo.arguments.contains("--ui-sample") { loadInterfaceFixture() }
            #else
            configurationStatus.source = .unavailable
            configurationStatus.refresh = .failed
            #endif
            return
        }
        var restoredSession: UserSession?
        authFeedbackKind = .login
        await perform(authFeedback: true, showBusyIndicator: false) {
            if self.config == nil {
                do {
                    #if DEBUG
                    DeveloperDiagnostics.shared.record(.init(
                        operationID: startupDiagnosticOperationID,
                        module: .configuration,
                        stage: "local-config-load",
                        outcome: "started"
                    ))
                    #endif
                    let local = try await self.remote.loadLocalConfig()
                    await self.acceptConfiguration(local)
                    if !local.cacheFresh {
                        await self.refreshConfigurationIfNeeded(force: false)
                    }
                } catch {
                    #if DEBUG
                    DeveloperDiagnostics.shared.record(.init(
                        operationID: startupDiagnosticOperationID,
                        module: .configuration,
                        level: .warning,
                        stage: "local-config-load",
                        outcome: "failed",
                        detail: "category=configuration"
                    ))
                    #endif
                    self.configurationStatus.source = .initializing
                    await self.refreshConfigurationIfNeeded(force: true)
                }
            } else if let config = self.config {
                await self.apiHealthMonitor.configure(config)
            }
            self.startConfigNetworkObservationIfNeeded()
            if let saved = try await self.sessions.read() {
                if let config = self.config {
                    restoredSession = try await self.sessionVerifier.verifyStoredSession(
                        config: config,
                        session: saved
                    )
                } else {
                    self.pendingStoredSession = saved
                }
            }
        }
        if let restoredSession {
            await establishAuthenticatedSession(restoredSession, source: .restored)
        }
        if config != nil, !hasInjectedInitialConfig { await refreshConfigurationIfNeeded(force: false) }
        #if DEBUG
        await runRecoveryAcceptanceIfRequested()
        #endif
        #if DEBUG
        DeveloperDiagnostics.shared.record(.init(
            operationID: startupDiagnosticOperationID,
            module: .app,
            level: config == nil ? .error : .success,
            stage: "startup-initialization",
            outcome: config == nil ? "configuration-unavailable" : "ready",
            detail: restoredSession == nil ? "session=none" : "session=restored"
        ))
        #endif
    }

    #if DEBUG
    private func runRecoveryAcceptanceIfRequested() async {
        guard let requested = DeveloperRecoveryAcceptance.requestedKind(), let config else { return }
        await DeveloperRecoveryAcceptance.run(
            kind: requested,
            config: config,
            router: apiRecoveryRouter,
            runtime: appOnlyRuntime
        )
    }
    #endif

    private func acceptConfiguration(_ result: ConfigLoadResult) async {
        if Self.appUpdateIdentity(config) != Self.appUpdateIdentity(result.config) {
            cancelAppUpdateCheck()
        }
        config = result.config
        updateLatencyDisplayRatio()
        let logoGeneration = brand.applyConfiguration(result)
        configSourceKey = brand.snapshot.sourceLocalizationKey
        switch result.source {
        case .remote: configurationStatus.source = .remote
        case .cache: configurationStatus.source = result.cacheFresh ? .cache : .staleCache
        case .fixture: configurationStatus.source = .fixture
        }
        #if DEBUG
        DeveloperDiagnostics.shared.record(.init(
            operationID: startupDiagnosticOperationID,
            module: .configuration,
            level: .success,
            stage: "configuration-accepted",
            outcome: result.source.rawValue,
            detail: "apiCandidates=\(result.config.apiBaseURLs.count) cacheFresh=\(result.cacheFresh)"
        ))
        #endif
        await apiHealthMonitor.configure(result.config)
        brandLogoTask?.cancel()
        brandLogoTask = Task { [weak self] in
            guard let self else { return }
            await self.brand.resolveLogo(for: result.config, operation: logoGeneration)
        }
    }

    private func refreshConfigurationIfNeeded(force: Bool) async {
        // An explicitly injected configuration is authoritative for offline tests.
        // Never let those tests fetch a production bootstrap behind their fake API.
        guard !hasInjectedInitialConfig else { return }
        if let configRefreshTask { await configRefreshTask.value; return }
        guard configForeground else { return }
        if config == nil { configurationStatus.source = .initializing }
        configRefreshGeneration &+= 1
        let generation = configRefreshGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            let previousRefresh = self.configurationStatus.refresh
            self.configurationStatus.refresh = .checking
            do {
                if let result = try await self.remote.refreshIfNeeded(force: force) {
                    guard !Task.isCancelled, self.configRefreshGeneration == generation else { return }
                    await self.acceptConfiguration(result)
                    await self.restoreDeferredSessionIfNeeded()
                    SafeLog.info("[Config] applied source=remote apiCandidates=\(result.config.apiBaseURLs.count)")
                    self.configurationStatus.refresh = .idle
                } else {
                    guard !Task.isCancelled, self.configRefreshGeneration == generation else { return }
                    if self.config == nil {
                        self.configurationStatus.source = .unavailable
                        self.configurationStatus.refresh = .failed
                    } else {
                        self.configurationStatus.refresh = previousRefresh == .failed ? .failed : .idle
                    }
                }
            } catch is CancellationError {
                guard self.configRefreshGeneration == generation else { return }
                self.configurationStatus.refresh = .idle
            } catch {
                guard !Task.isCancelled, self.configRefreshGeneration == generation else { return }
                self.configurationStatus.refresh = .failed
                if self.config == nil { self.configurationStatus.source = .unavailable }
                SafeLog.warning("[Config] refreshFailed category=remote_configuration")
                // The login screen observes configurationStatus; no global alert.
            }
        }
        configRefreshTask = task
        await task.value
        if configRefreshGeneration == generation { configRefreshTask = nil }
    }

    func reloadConfiguration() async {
        guard !offline else { return }
        if config == nil {
            configurationStatus.source = .initializing
            configurationStatus.refresh = .checking
        }
        await refreshConfigurationIfNeeded(force: true)
    }

    private func restoreDeferredSessionIfNeeded() async {
        guard session == nil,
              let stored = pendingStoredSession,
              let config else { return }
        do {
            let restored = try await sessionVerifier.verifyStoredSession(
                config: config,
                session: stored
            )
            try Task.checkCancellation()
            guard self.config == config, session == nil else { return }
            pendingStoredSession = nil
            await establishAuthenticatedSession(restored, source: .restored)
        } catch is CancellationError {
            return
        } catch let error as NetworkClientError {
            authMessage = error.userFacingMessage
        } catch {
            authMessage = .localized(L10nKey.errorServiceUnavailable)
        }
    }

    var isCheckingForUpdates: Bool { appUpdateCheckState == .checking }

    func checkForUpdates(currentVersion: String) async throws -> AppUpdateCheckOutcome {
        guard !offline,
              let config,
              let identity = Self.appUpdateIdentity(config),
              let manifestURL = AppUpdateURLPolicy.manifestURL(config.updateURL),
              let localVersion = AppNumericVersion(currentVersion) else {
            userSystemLogger.log(.warning, module: .update, key: UserLogKey.updateFailed)
            throw AppUpdateError.invalidConfiguration
        }

        let entry: (
            id: UUID,
            identity: AppUpdateConfigurationIdentity,
            task: Task<AppUpdateRelease, Error>
        )
        if let existing = appUpdateCheckTask, existing.identity == identity {
            entry = existing
        } else {
            appUpdateCheckTask?.task.cancel()
            let id = UUID()
            let service = appUpdateService
            let task = Task<AppUpdateRelease, Error> {
                try await service.fetchRelease(from: manifestURL)
            }
            entry = (id, identity, task)
            appUpdateCheckTask = entry
            appUpdateCheckState = .checking
            userSystemLogger.log(.info, module: .update, key: UserLogKey.updateChecking)
        }

        do {
            let release = try await entry.task.value
            try Task.checkCancellation()
            guard Self.appUpdateIdentity(self.config) == entry.identity else {
                throw CancellationError()
            }
            if appUpdateCheckTask?.id == entry.id {
                appUpdateCheckTask = nil
                appUpdateCheckState = .idle
            }
            guard let remoteVersion = AppNumericVersion(release.version) else {
                throw AppUpdateError.invalidManifest
            }
            if remoteVersion > localVersion {
                userSystemLogger.log(
                    .info,
                    module: .update,
                    key: UserLogKey.updateAvailable,
                    arguments: [currentVersion, release.version]
                )
                return .updateAvailable(release)
            }
            userSystemLogger.log(.info, module: .update, key: UserLogKey.updateLatest)
            return .upToDate
        } catch is CancellationError {
            if appUpdateCheckTask?.id == entry.id {
                appUpdateCheckTask = nil
                appUpdateCheckState = .idle
            }
            throw CancellationError()
        } catch {
            if appUpdateCheckTask?.id == entry.id {
                appUpdateCheckTask = nil
                appUpdateCheckState = .idle
            }
            userSystemLogger.log(.warning, module: .update, key: UserLogKey.updateFailed)
            throw error
        }
    }

    func cancelAppUpdateCheck() {
        appUpdateCheckTask?.task.cancel()
        appUpdateCheckTask = nil
        appUpdateCheckState = .idle
    }

    func recordAppUpdatePageOpened() {
        userSystemLogger.log(.info, module: .update, key: UserLogKey.updateOpened)
    }

    private static func appUpdateIdentity(_ config: AppConfig?) -> AppUpdateConfigurationIdentity? {
        guard let config,
              let manifestURL = AppUpdateURLPolicy.manifestURL(config.updateURL) else { return nil }
        return AppUpdateConfigurationIdentity(
            appName: config.appName.trimmed,
            manifestURL: manifestURL.absoluteString
        )
    }

    func retryAuthenticationConnectivity(registrationNeeded: Bool = false) async {
        guard !offline else { return }
        clearAuthenticationFeedback()
        if config == nil {
            await refreshConfigurationIfNeeded(force: true)
        } else {
            await apiHealthMonitor.retryProbeIfNeeded()
        }
        if registrationNeeded, config != nil, registration == nil { await loadRegistration() }
    }

    private func startConfigNetworkObservationIfNeeded() {
        guard configNetworkMonitor == nil, !offline, !hasInjectedInitialConfig else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let snapshot = APIHealthNetworkPath(path)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !snapshot.isReachable { self.configNetworkRefreshTask?.cancel() }
                self.observeLatencyNetworkPath(snapshot)
                let changed = await self.remote.networkDidChange(path: snapshot)
                guard changed, self.configForeground else { return }
                self.configNetworkRefreshTask?.cancel()
                self.configNetworkRefreshTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(750))
                    guard !Task.isCancelled, let self else { return }
                    await self.refreshConfigurationIfNeeded(force: false)
                    self.scheduleLogoRecovery()
                    if self.configurationStatus.refresh == .failed,
                       let wait = await self.remote.remainingFailureCooldown() {
                        try? await Task.sleep(for: .seconds(wait + 0.05))
                        guard !Task.isCancelled else { return }
                        await self.refreshConfigurationIfNeeded(force: false)
                    }
                }
            }
        }
        configNetworkMonitor = monitor
        monitor.start(queue: DispatchQueue(label: "NetworkClient.Config.Path"))
    }

    private func scheduleLogoRecovery() {
        logoRecoveryTask?.cancel()
        logoRecoveryTask = Task { [weak self] in
            guard let self else { return }
            await self.brand.retryRemoteLogoIfNeeded()
            if let remaining = self.brand.remainingLogoRetryCooldown() {
                try? await Task.sleep(for: .seconds(remaining + 0.05))
                guard !Task.isCancelled else { return }
                await self.brand.retryRemoteLogoIfNeeded()
            }
        }
    }

    func setAPIHealthForeground(_ active: Bool) async {
        guard !offline else { return }
        configForeground = active
        await apiHealthMonitor.setForeground(active)
        await apiRecoveryRouter.setRecoveryForeground(active)
        if active {
            await refreshConfigurationIfNeeded(force: false)
            scheduleLogoRecovery()
        } else {
            configNetworkRefreshTask?.cancel()
            logoRecoveryTask?.cancel()
            configRefreshGeneration &+= 1
            configRefreshTask?.cancel()
            configRefreshTask = nil
            await remote.cancelRefresh()
        }
    }

    @discardableResult
    func perform(
        authFeedback: Bool = false,
        reportGlobal: Bool = true,
        showBusyIndicator: Bool = true,
        _ operation: () async throws -> Void
    ) async -> LocalizedMessage? {
        guard !busy else { return nil }
        let context = requestAccountContext()
        showsGlobalBusyIndicator = showBusyIndicator
        busy = true
        defer {
            // A new authenticated generation releases the old busy owner.
            // A metadata/token refresh alone has not started another operation.
            if authenticatedGeneration == context.generation {
                busy = false
                showsGlobalBusyIndicator = false
            }
        }
        do {
            guard !offline else { throw NetworkClientError.validation(L10nKey.offlineRequestUnavailable) }
            try await operation()
            return nil
        } catch is CancellationError {
            // Cancellation is not a business failure.
            #if DEBUG
            DeveloperDiagnostics.shared.record(.init(
                operationID: activeAuthDiagnosticOperationID ?? startupDiagnosticOperationID,
                module: .userInterface,
                level: .warning,
                stage: "operation-result",
                outcome: "cancelled",
                cancelled: true
            ))
            #endif
            return nil
        } catch let error as NetworkClientError {
            guard !Task.isCancelled, isCurrent(context) else { return nil }
            if case .authenticationExpired = error {
                guard let cleared = await invalidateAuthenticatedSession(ifCurrent: context),
                      isCurrent(cleared) else { return nil }
                authMessage = error.userFacingMessage
                return error.userFacingMessage
            }
            let feedback = error.userFacingMessage
            if authFeedback { authMessage = feedback }
            else if reportGlobal { message = feedback }
            #if DEBUG
            DeveloperDiagnostics.shared.record(.init(
                operationID: activeAuthDiagnosticOperationID ?? startupDiagnosticOperationID,
                module: .userInterface,
                level: .error,
                stage: "error-to-user-message",
                outcome: error.logCategory,
                detail: authFeedback ? "destination=auth" : "destination=global"
            ))
            #endif
            return feedback
        } catch let error as PurchaseCommerceError {
            guard !Task.isCancelled, isCurrent(context) else { return nil }
            let feedback: LocalizedMessage
            switch error {
            case .orderCreationResultUnknown: feedback = .localized("purchase.payment.unknown_order")
            case .checkoutResultUnknown: feedback = .localized("purchase.payment.unknown_checkout")
            case .cancellationResultUnknown: feedback = .localized(L10nKey.purchaseCancellationUnknown)
            case .invalidResponse: feedback = .localized(L10nKey.purchaseInvalidResponse)
            }
            if reportGlobal { message = feedback }
            return feedback
        } catch {
            guard !Task.isCancelled, isCurrent(context) else { return nil }
            let feedback = LocalizedMessage.localized(L10nKey.commonOperationFailed)
            if authFeedback { authMessage = feedback }
            else if reportGlobal { message = feedback }
            SafeLog.warning("iOS operation failed type=\(String(describing: type(of: error)))")
            return feedback
        }
    }

    private func performAuthentication(
        _ task: AuthTaskKind,
        _ operation: () async throws -> Void
    ) async {
        guard !busy else { return }
        #if DEBUG
        let diagnosticOperation = DeveloperDiagnosticOperation.make("auth")
        activeAuthDiagnosticOperationID = diagnosticOperation
        DeveloperDiagnostics.shared.record(.init(
            operationID: diagnosticOperation,
            module: .api,
            stage: "authentication-operation",
            outcome: "started",
            detail: "kind=\(String(describing: task))"
        ))
        #endif
        authMessage = nil
        authTask = task
        authFeedbackKind = task
        defer {
            authTask = nil
            #if DEBUG
            DeveloperDiagnostics.shared.record(.init(
                operationID: diagnosticOperation,
                module: .api,
                level: authMessage == nil ? .success : .warning,
                stage: "authentication-operation",
                outcome: authMessage == nil ? "completed" : "failed"
            ))
            activeAuthDiagnosticOperationID = nil
            #endif
        }
        await perform(
            authFeedback: true,
            showBusyIndicator: false,
            operation
        )
    }

    func clearAuthenticationFeedback() {
        authMessage = nil
        authFeedbackKind = nil
        #if DEBUG
        DeveloperDiagnostics.shared.record(.init(
            operationID: activeAuthDiagnosticOperationID ?? startupDiagnosticOperationID,
            module: .userInterface,
            level: .success,
            stage: "auth-error-state",
            outcome: "cleared"
        ))
        #endif
    }

    private func requireConfig() throws -> AppConfig {
        guard let config else { throw NetworkClientError.configUnavailable(L10nKey.commonConfigurationRequired) }
        return config
    }
    private func requireAccount() throws -> (AppConfig, UserSession) {
        guard let session else { throw NetworkClientError.validation(L10nKey.commonAccountRequired) }
        return (try requireConfig(), session)
    }

    /// An in-memory snapshot of the existing session identity, never logged or
    /// persisted. Metadata refreshes do not change request ownership.
    fileprivate struct RequestAccountContext: Sendable, Equatable {
        let generation: UUID
        let accountScope: String?
        let authData: String?
    }

    /// An opaque account identity for Commerce view continuations. The
    /// credential remains file-private; views can only capture and validate
    /// the token through AppModel.
    struct CommerceAccountContext: Sendable {
        fileprivate let request: RequestAccountContext
    }

    /// A checkout response that remains consumable only by the authenticated
    /// session, trade and write operation that produced it. Credentials stay
    /// private to AppModel and are never exposed to views or diagnostics.
    struct OwnedPurchaseCheckout: Sendable, Equatable {
        let tradeNo: String
        let operationID: UUID
        let result: PurchaseCheckoutResult
        fileprivate let account: RequestAccountContext

        var type: Int { result.type }
        var data: String? { result.data }
    }

    private func requestAccountContext() -> RequestAccountContext {
        RequestAccountContext(
            generation: authenticatedGeneration,
            accountScope: session.map(Self.accountScope(for:)),
            authData: session?.authData
        )
    }

    func captureCommerceContext() -> CommerceAccountContext {
        CommerceAccountContext(request: requestAccountContext())
    }

    func isCurrentCommerceContext(_ context: CommerceAccountContext) -> Bool {
        !Task.isCancelled && isCurrent(context.request)
    }

    func currentCheckout(for tradeNo: String) -> OwnedPurchaseCheckout? {
        guard let checkout, isCurrentCheckout(checkout, tradeNo: tradeNo) else {
            return nil
        }
        return checkout
    }

    func isCurrentCheckout(
        _ checkout: OwnedPurchaseCheckout,
        tradeNo: String
    ) -> Bool {
        isCurrent(checkout.account)
            && checkout.tradeNo == tradeNo
            && self.checkout?.operationID == checkout.operationID
    }

    func isCurrentCheckoutOperation(
        _ operationID: UUID,
        tradeNo: String
    ) -> Bool {
        guard let checkout else { return false }
        return checkout.operationID == operationID
            && isCurrentCheckout(checkout, tradeNo: tradeNo)
    }

    private func isCurrent(_ context: RequestAccountContext) -> Bool {
        authenticatedGeneration == context.generation
            && session.map(Self.accountScope(for:)) == context.accountScope
            && session?.authData == context.authData
    }

    private func requireCurrent(_ context: RequestAccountContext) throws {
        try Task.checkCancellation()
        guard isCurrent(context) else { throw CancellationError() }
    }

    func login(email: String, password: String, remember: Bool) async {
        let expectedPersistenceGeneration = session == nil ? nil : authenticatedGeneration
        var authenticatedSession: (session: UserSession, generation: UUID)?
        await performAuthentication(.login) {
            try AuthValidation.validate(email: email, password: password)
            let config = try self.requireConfig()
            let authenticated = try await self.api.login(config: config, email: email, password: password)
            try await self.sessions.setAutoLoginEnabled(remember)
            let generation = UUID()
            guard try await self.sessions.replace(
                authenticated,
                generation: generation,
                replacing: expectedPersistenceGeneration
            ) else { throw CancellationError() }
            authenticatedSession = (authenticated, generation)
        }
        if let authenticatedSession {
            await establishAuthenticatedSession(
                authenticatedSession.session,
                source: .login,
                generation: authenticatedSession.generation
            )
        }
    }

    func loadRegistration() async {
        guard registration == nil else { return }
        await performAuthentication(.registrationConfig) {
            let config = try self.requireConfig()
            let loaded = try await self.registrationConfigValue(for: config)
            try Task.checkCancellation()
            guard self.config == config else { throw CancellationError() }
            self.registration = loaded
        }
    }

    /// Resolves Terms through the existing public guest-config lifecycle.
    /// The shared task preserves single-flight behavior with registration while
    /// successful data remains cached in the existing registration state.
    func aboutSupportTermsURL() async throws -> URL? {
        if let registration { return registration.termsOfServiceURL }
        guard !offline, session != nil, let config else { return nil }
        let context = requestAccountContext()
        let loaded = try await registrationConfigValue(for: config)
        try Task.checkCancellation()
        guard isCurrent(context), self.config == config else { throw CancellationError() }
        registration = loaded
        return loaded.termsOfServiceURL
    }

    private func registrationConfigValue(
        for requestedConfig: AppConfig
    ) async throws -> V2BoardRegistrationConfig {
        if let active = registrationConfigTask, active.config == requestedConfig {
            return try await active.task.value
        }

        registrationConfigTask?.task.cancel()
        let id = UUID()
        let task = Task {
            try await api.fetchRegistrationConfig(config: requestedConfig)
        }
        registrationConfigTask = (id, requestedConfig, task)
        do {
            let value = try await task.value
            if registrationConfigTask?.id == id { registrationConfigTask = nil }
            return value
        } catch {
            if registrationConfigTask?.id == id { registrationConfigTask = nil }
            throw error
        }
    }
    func sendCode(email: String, reset: Bool) async {
        await performAuthentication(reset ? .resetCode : .registerCode) {
            try AuthValidation.validate(email: email, password: "validation-only")
            let config = try self.requireConfig()
            if reset { try await self.api.sendPasswordResetEmailCode(config: config, email: email) }
            else {
                guard let rules = self.registration, !rules.requiresRecaptcha else { throw NetworkClientError.validation(L10nKey.registerStatusRecaptchaUnsupported) }
                try await self.api.sendRegistrationEmailCode(config: config, email: email)
            }
            self.authMessage = .localized(reset ? L10nKey.forgotStatusCodeSent : L10nKey.registerStatusCodeSent)
        }
    }
    func submitRegistration(email: String, password: String, confirmation: String, code: String, invite: String) async {
        await performAuthentication(.register) {
            guard let registration = self.registration else { throw NetworkClientError.validation(L10nKey.registerStatusRegistrationConfigUnavailable) }
            try AuthValidation.validate(email: email, password: password, confirmation: confirmation, registration: registration, emailCode: code, inviteCode: invite)
            try await self.api.register(config: self.requireConfig(), email: email, emailCode: code, password: password, inviteCode: invite)
            self.authMessage = .localized(L10nKey.registerStatusSucceeded)
        }
    }
    func resetPassword(email: String, password: String, confirmation: String, code: String) async {
        await performAuthentication(.reset) {
            try AuthValidation.validatePasswordReset(
                email: email,
                password: password,
                confirmation: confirmation
            )
            guard !code.trimmed.isEmpty else { throw NetworkClientError.validation(L10nKey.forgotValidationEmailCodeRequired) }
            try await self.api.resetPassword(config: self.requireConfig(), email: email, emailCode: code, password: password)
            self.authMessage = .localized(L10nKey.forgotStatusResetSucceeded)
        }
    }

    private struct AuthenticatedLoadContext: Sendable {
        let config: AppConfig
        let session: UserSession
        let generation: UUID
        let accountScope: String
    }

    func establishAuthenticatedSession(
        _ authenticatedSession: UserSession,
        source: AuthenticatedSessionSource,
        generation suppliedGeneration: UUID? = nil
    ) async {
        let previousGeneration = session == nil ? nil : authenticatedGeneration
        let nextGeneration = suppliedGeneration ?? UUID()
        let adopted: Bool
        if source == .restored, session == nil {
            await sessions.adoptRestoredSession(generation: nextGeneration)
            adopted = true
        } else {
            adopted = await sessions.adopt(
                generation: nextGeneration,
                replacing: previousGeneration
            )
        }
        guard adopted else { return }

        nodeSession.cancelAll()
        cancelAuthenticatedRefreshes()
        cancelActiveNodeLatencyTests()
        authenticatedGeneration = nextGeneration
        busy = false
        showsGlobalBusyIndicator = false
        message = nil
        changePasswordState = .idle
        accountDeletionRequestState = .idle
        invitationActionInProgress = false
        invitationFeedback = nil

        let newScope = Self.accountScope(for: authenticatedSession)
        let accountChanged = activeAccountScope != newScope
        if accountChanged {
            invalidateNodeLatencies(reason: .accountChange)
            await repository.clear()
            orders = []
            ordersLoadState = .idle
            invitations = nil
            invitationsLoadState = .idle
            dailyTraffic = []
            trafficLoadState = .idle
            checkout = nil
            paymentMethods = []
            paymentMethodsLoadState = .idle
            nodes = .empty
            selectedTunnelRevision = nil
            nodesLoadState = .idle
            nodesRefreshedAt = nil
            nodesAttemptedAt = nil

            if let cache = plansCache[newScope] {
                plans = cache.value
                plansLoadState = cache.value.isEmpty ? .empty : .loaded
                plansRefreshedAt = cache.refreshedAt
            } else {
                plans = []
                plansLoadState = .idle
                plansRefreshedAt = nil
            }
            plansAttemptedAt = nil

            if let cache = noticesCache[newScope] {
                notices = cache.value
                noticesLoadState = cache.value.isEmpty ? .empty : .loaded
                noticesRefreshedAt = cache.refreshedAt
            } else {
                notices = []
                noticesLoadState = .idle
                noticesRefreshedAt = nil
            }
            noticesAttemptedAt = nil
        } else if trafficLoadState.isLoading {
            // A new authenticated generation cancels the old read even when it
            // belongs to the same account. Keep committed rows, but never leave
            // the replacement session stuck in an in-flight presentation state.
            trafficLoadState = dailyTraffic.isEmpty ? .idle : .loaded
        }

        activeAccountScope = newScope
        session = authenticatedSession
        accountLoadState = .loaded
        accountRefreshedAt = nil
        accountAttemptedAt = nil
        SafeLog.info(
            "[Bootstrap] authenticated session accepted source=\(source.rawValue) "
                + "account_changed=\(accountChanged)"
        )
        await initializeAuthenticatedData(force: true)
    }

    func initializeAuthenticatedData(force: Bool = true) async {
        guard !offline, session != nil, config != nil else { return }
        async let account: Void = refreshAccount(force: force)
        async let plans: Void = refreshPlans(force: force)
        async let notices: Void = refreshNotices(force: force)
        if force {
            async let nodes: Void = refreshNodes(force: true)
            _ = await (account, plans, nodes, notices)
        } else {
            _ = await (account, plans, notices)
        }
    }

    func refreshAuthenticatedDataIfNeeded() async {
        await initializeAuthenticatedData(force: false)
    }

    func refreshAccount() async {
        await refreshAccount(force: true)
    }

    func refreshAccountIfNeeded() async {
        await refreshAccount(force: false)
    }

    private func refreshAccount(force: Bool) async {
        if let accountRefreshTask {
            await accountRefreshTask.value
            return
        }
        guard let context = authenticatedLoadContext(), shouldRefresh(
            force: force,
            lastSuccess: accountRefreshedAt,
            lastAttempt: accountAttemptedAt,
            interval: BusinessRefreshPolicy.accountInterval
        ) else { return }

        let hadUsableValue = session != nil
        accountLoadState = .loading
        accountAttemptedAt = Date()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runAccountRefresh(context: context, hadUsableValue: hadUsableValue)
        }
        accountRefreshTask = task
        await task.value
        if authenticatedGeneration == context.generation {
            accountRefreshTask = nil
        }
    }

    func refreshPlans() async {
        await refreshPlans(force: true)
    }

    func refreshPlansIfNeeded() async {
        await refreshPlans(force: false)
    }

    private func refreshPlans(force: Bool) async {
        if let plansRefreshTask {
            await plansRefreshTask.value
            return
        }
        guard let context = authenticatedLoadContext(), shouldRefresh(
            force: force,
            lastSuccess: plansRefreshedAt,
            lastAttempt: plansAttemptedAt,
            interval: BusinessRefreshPolicy.plansInterval
        ) else { return }

        let hadUsableValue = plansLoadState.hasUsableResult || !plans.isEmpty
        plansLoadState = .loading
        plansAttemptedAt = Date()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runPlansRefresh(context: context, hadUsableValue: hadUsableValue)
        }
        plansRefreshTask = task
        await task.value
        if authenticatedGeneration == context.generation {
            plansRefreshTask = nil
        }
    }

    func refreshNodes() async {
        await nodeSession.refresh(manual: true) { [weak self] manual in
            await self?.runCoordinatedNodesRefresh(clearAllLatenciesOnSuccess: manual)
        }
    }

    /// Immutable ownership of one round, reusing the existing in-memory request
    /// identity. It creates no persistence or second latency cache.
    private struct LatencyOperationContext: Sendable {
        let generation: UUID
        let account: RequestAccountContext
        let repositoryGeneration: NodeLatencySubscriptionGeneration?
    }

    private struct LatencyTarget: Sendable {
        let node: ProxyNode
        let revision: String?
    }

    private var latencyRepositoryGeneration: NodeLatencySubscriptionGeneration? {
        (repository as? any NodeRepositoryGenerationReading)?.latencySubscriptionGeneration
    }

    private func latencyContext(generation: UUID) -> LatencyOperationContext? {
        guard !Task.isCancelled, !offline, session != nil else { return nil }
        return LatencyOperationContext(
            generation: generation, account: requestAccountContext(),
            repositoryGeneration: latencyRepositoryGeneration
        )
    }

    private func isCurrentLatencyOperation(_ context: LatencyOperationContext) -> Bool {
        !Task.isCancelled && latencyCoordinator.isCurrent(context.generation)
            && isCurrent(context.account) && context.account.accountScope == activeAccountScope
            && latencyRepositoryGeneration == context.repositoryGeneration
    }

    private func beginNodeLatency(
        _ target: LatencyTarget, context: LatencyOperationContext
    ) -> Bool {
        guard isCurrentLatencyOperation(context),
              nodes.nodes.contains(where: {
                  $0.id == target.node.id && $0.fingerprint == target.node.fingerprint
                    && $0.available == target.node.available
              }) else { return false }
        testingNodeIDs.insert(target.node.id)
        return true
    }

    /// Snapshot first, then the last synchronous guard and writes on MainActor.
    /// All terminal outcomes, including mapping/catch/completion failures, use it.
    @discardableResult
    private func commitNodeLatency(
        _ outcome: NodeProbeOutcome, target: LatencyTarget,
        context: LatencyOperationContext, total: Int? = nil, phase: String
    ) async -> Bool {
        let subscription = await repository.parsedSubscription()
        #if DEBUG
        if let latencyWillCommitForTesting { await latencyWillCommitForTesting(phase) }
        #endif
        let revision = try? SelectedNodeConfigurationIdentity.revision(
            in: subscription, nodeID: target.node.id
        )
        guard isCurrentLatencyOperation(context), testingNodeIDs.contains(target.node.id),
              nodes.nodes.contains(where: {
                  $0.id == target.node.id && $0.fingerprint == target.node.fingerprint
                    && $0.available == target.node.available
              }), revision == target.revision else { return false }
        // No await from this guard through cache/progress publication.
        switch outcome {
        case let .measured(milliseconds): recordMeasuredLatency(milliseconds, for: target.node.id)
        case .timedOut: nodeLatencies[target.node.id] = .timedOut
        case .failed: nodeLatencies[target.node.id] = .failed
        case .unavailable: nodeLatencies[target.node.id] = .unavailable
        }
        testingNodeIDs.remove(target.node.id)
        if let total {
            nodeLatencyProgress = NodeLatencyProgress(
                completed: nodeLatencyProgress.completed + 1, total: total
            )
        }
        return true
    }

    private func finishNodeLatency(_ context: LatencyOperationContext, batch: Bool) {
        // Only this drained owner can restore unfinished rows and release the
        // activity flag. Cancelled generations already restored their baseline.
        if latencyCoordinator.generation == context.generation, isCurrent(context.account),
           !testingNodeIDs.isEmpty {
            cancelActiveNodeLatencyTests()
        }
        if latencyCoordinator.finish(generation: context.generation), batch { testingAllNodes = false }
    }

    private enum NodeProbeRoute {
        case appOnly
        case provider(any ConnectedNodeProbing)
        case unavailable
    }

    private func nodeProbeRoute() -> NodeProbeRoute {
        guard let connectedNodeProber else { return .appOnly }
        switch connectedNodeProber.nodeProbeState {
        case .disconnected: return .appOnly
        case .connected: return .provider(connectedNodeProber)
        case .connecting: return .unavailable
        }
    }

    private func appOnlyProbeStillSafe() -> Bool {
        connectedNodeProber?.nodeProbeState != .connected
            && connectedNodeProber?.nodeProbeState != .connecting
    }

    nonisolated private static func nodeProbeOutcome(
        _ result: MihomoTunnelNodeProbeResult
    ) -> NodeProbeOutcome {
        switch result.status {
        case .measured:
            guard let delay = result.delayMilliseconds, delay >= 0 else { return .failed }
            return .measured(delay)
        case .timedOut: return .timedOut
        case .failed: return .failed
        case .unavailable, .invalidTarget: return .unavailable
        }
    }

    private func probeProviderNodesIncrementally(
        _ candidates: [NodeProbeCandidate], prober: any ConnectedNodeProbing,
        onStart: @escaping @Sendable (NodeProbeCandidate) async -> Bool,
        onResult: @escaping @Sendable (NodeProbeResult) async -> Void
    ) async throws {
        let revision = prober.nodeProbeCandidatePoolRevision
        var nextIndex = 0
        try await withThrowingTaskGroup(of: NodeProbeResult.self) { group in
            func addNext() {
                guard nextIndex < candidates.count, !Task.isCancelled else { return }
                let candidate = candidates[nextIndex]
                nextIndex += 1
                group.addTask {
                    try Task.checkCancellation()
                    guard await onStart(candidate) else { throw CancellationError() }
                    try Task.checkCancellation()
                    guard await prober.nodeProbeState == .connected else {
                        return .init(
                            nodeID: candidate.nodeID, revision: candidate.revision,
                            outcome: .unavailable
                        )
                    }
                    do {
                        let response = try await prober.probeNodes(
                            coreNames: [candidate.coreName],
                            candidatePoolRevision: revision
                        )
                        let result = response.count == 1
                            ? response.first(where: { $0.coreName == candidate.coreName })
                            : nil
                        return .init(
                            nodeID: candidate.nodeID, revision: candidate.revision,
                            outcome: result.map(Self.nodeProbeOutcome) ?? .unavailable
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as URLError where error.code == .cancelled {
                        throw CancellationError()
                    } catch {
                        let stillConnected = await prober.nodeProbeState == .connected
                        return .init(
                            nodeID: candidate.nodeID, revision: candidate.revision,
                            outcome: stillConnected ? .failed : .unavailable
                        )
                    }
                }
            }

            for _ in 0..<min(
                MihomoTunnelControlRequest.maximumProbeTargets,
                candidates.count
            ) {
                addNext()
            }
            while let result = try await group.next() {
                try Task.checkCancellation()
                await onResult(result)
                addNext()
            }
            group.cancelAll()
        }
    }

    func testNodeLatency(_ nodeID: String) async {
        guard !testingAllNodes, let generation = latencyCoordinator.begin() else { return }
        guard let context = latencyContext(generation: generation) else {
            latencyCoordinator.finish(generation: generation)
            return
        }
        defer { finishNodeLatency(context, batch: false) }
        await probeNodeLatency(nodeID, context: context)
    }

    func testAllNodeLatencies() async {
        guard !testingAllNodes else { return }
        let candidates = nodes.nodes.filter(\.available)
        guard !candidates.isEmpty, let generation = latencyCoordinator.begin() else { return }
        guard let context = latencyContext(generation: generation) else {
            latencyCoordinator.finish(generation: generation)
            return
        }
        #if DEBUG || ROUTE_VALIDATION
        SafeLog.info("[NodeTrace] event=batch-latency-started count=\(candidates.count)")
        #endif
        testingAllNodes = true
        nodeLatencyProgress = NodeLatencyProgress(completed: 0, total: candidates.count)
        let task = Task { [weak self] in
            guard let self else { return }
            let subscription = await self.repository.parsedSubscription()
            guard self.isCurrentLatencyOperation(context) else { return }
            let route = self.nodeProbeRoute()
            let targets = candidates.map { node in
                LatencyTarget(node: node, revision: try? SelectedNodeConfigurationIdentity.revision(
                    in: subscription, nodeID: node.id
                ))
            }
            if case .unavailable = route {
                for target in targets {
                    guard self.beginNodeLatency(target, context: context) else { break }
                    await self.commitNodeLatency(
                        .unavailable, target: target, context: context,
                        total: candidates.count, phase: "state-unavailable"
                    )
                }
                return
            }
            var prepared: [NodeProbeCandidate] = []
            for target in targets {
                guard self.isCurrentLatencyOperation(context) else { break }
                let id = target.node.id
                do {
                    guard let revision = target.revision, let subscription,
                          self.nodesLoadState.hasUsableResult else { throw SelectedNodeTunnelError.missingNode }
                    let coreName: String
                    let yaml: String
                    switch route {
                    case .appOnly:
                        let configuration = try await self.candidateMihomoTunnelConfiguration(
                            nodeID: id, mode: .rule, subscription: subscription
                        )
                        guard self.isCurrentLatencyOperation(context) else { return }
                        guard configuration.configurationRevision == revision,
                              let mappedCoreName = configuration.coreName else {
                            throw SelectedNodeTunnelError.missingNode
                        }
                        coreName = mappedCoreName
                        yaml = try MihomoNodeProbeConfiguration.yaml(from: configuration.yaml)
                    case .provider:
                        // The running Provider already owns the fully mapped and
                        // validated fixed candidate pool. Rebuilding one Tunnel
                        // YAML per visible node here delayed the first probe and
                        // could repeat DNS/DoH work that startup already finished.
                        // Snapshot only its non-secret identity; the pool revision
                        // and Provider selector-membership check remain authoritative.
                        guard let record = subscription.runtimeProxyRecords[id],
                              record.nodeID == id, record.issue == nil,
                              record.runtimeProxy != nil,
                              record.coreName == target.node.coreName else {
                            throw SelectedNodeTunnelError.missingNode
                        }
                        coreName = record.coreName
                        yaml = ""
                    case .unavailable:
                        return
                    }
                    prepared.append(NodeProbeCandidate(
                        nodeID: id, revision: revision, coreName: coreName,
                        yaml: yaml
                    ))
                } catch is CancellationError { return }
                catch {
                    if (error as? URLError)?.code == .cancelled { return }
                    guard self.beginNodeLatency(target, context: context) else { return }
                    await self.commitNodeLatency(.failed, target: target, context: context,
                        total: candidates.count, phase: "mapper-failure")
                }
            }
            guard self.isCurrentLatencyOperation(context) else { return }
            var probeCancelled = false
            do {
                let onStart: @Sendable (NodeProbeCandidate) async -> Bool = { [weak self] candidate in
                    guard let target = targets.first(where: {
                        $0.node.id == candidate.nodeID && $0.revision == candidate.revision
                    }) else { return false }
                    return await self?.beginNodeLatency(target, context: context) == true
                }
                let onResult: @Sendable (NodeProbeResult) async -> Void = { [weak self] result in
                    guard let target = targets.first(where: { $0.node.id == result.nodeID }),
                          target.revision == result.revision else { return }
                    await self?.recordBatchNodeLatency(result, target: target, context: context, total: candidates.count)
                }
                switch route {
                case .appOnly:
                    guard self.appOnlyProbeStillSafe() else {
                        for candidate in prepared {
                            if await onStart(candidate) {
                                await onResult(.init(
                                    nodeID: candidate.nodeID, revision: candidate.revision,
                                    outcome: .unavailable
                                ))
                            }
                        }
                        break
                    }
                    try await self.nodeProber.probeBatch(
                        prepared, onStart: onStart, onResult: onResult
                    )
                case let .provider(prober):
                    try await self.probeProviderNodesIncrementally(
                        prepared, prober: prober, onStart: onStart, onResult: onResult
                    )
                case .unavailable:
                    break
                }
            } catch is CancellationError {
                // Cancellation is never a failed/timed-out reading.
                probeCancelled = true
                self.cancelActiveNodeLatencyTests()
            } catch {
                probeCancelled = (error as? URLError)?.code == .cancelled
                if probeCancelled {
                    self.cancelActiveNodeLatencyTests()
                } else {
                    for target in targets where self.testingNodeIDs.contains(target.node.id) {
                        await self.commitNodeLatency(error is RecoveryRuntimeError ? .unavailable : .failed,
                            target: target, context: context, total: candidates.count, phase: "batch-failure")
                    }
                }
            }
            for target in targets where !probeCancelled && self.testingNodeIDs.contains(target.node.id) {
                await self.commitNodeLatency(.unavailable, target: target, context: context,
                    total: candidates.count, phase: "batch-completion")
            }
        }
        latencyCoordinator.track(task)
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        finishNodeLatency(context, batch: true)
    }

    private func recordBatchNodeLatency(
        _ result: NodeProbeResult, target: LatencyTarget,
        context: LatencyOperationContext, total: Int
    ) async {
        await commitNodeLatency(result.outcome, target: target, context: context,
            total: total, phase: "batch-result")
    }

    func cancelAllNodeLatencies() { cancelActiveNodeLatencyTests() }

    private func recordMeasuredLatency(_ milliseconds: Int, for nodeID: String) {
        guard let reading = NodeLatencyReading(
            actualMilliseconds: milliseconds,
            displayRatio: config?.latencyDisplayRatio ?? 1.0
        ) else {
            nodeLatencies[nodeID] = .failed
            return
        }
        nodeLatencies[nodeID] = .measured(reading)
    }

    private func updateLatencyDisplayRatio() {
        let ratio = config?.latencyDisplayRatio ?? 1.0
        for (nodeID, state) in nodeLatencies {
            guard case let .measured(reading) = state,
                  let updated = NodeLatencyReading(
                    actualMilliseconds: reading.actualMilliseconds,
                    displayRatio: ratio
                  ) else { continue }
            nodeLatencies[nodeID] = .measured(updated)
        }
    }

    private enum NodeLatencyInvalidationReason: String {
        case networkPath, accountChange, manualRefresh, subscriptionChange, sessionClear
    }

    func observeLatencyNetworkPath(_ path: APIHealthNetworkPath) {
        if latencyCoordinator.physicalPathChanged(path) {
            invalidateNodeLatencies(reason: .networkPath)
        }
    }

    /// Stops in-flight URLTests without discarding measurements that completed
    /// under the current account, subscription revision and physical path.
    private func cancelActiveNodeLatencyTests() {
        guard latencyCoordinator.cancelActive() else { return }
        testingNodeIDs.removeAll()
        latencyReadingsSnapshot = latencyCoordinator.readings
        nodeLatencyProgress = .idle
        #if DEBUG || ROUTE_VALIDATION
        SafeLog.info("[NodeTrace] event=latency-task-cancelled cache=retained")
        #endif
    }

    private func invalidateNodeLatencies(reason: NodeLatencyInvalidationReason) {
        #if DEBUG || ROUTE_VALIDATION
        SafeLog.info("[NodeTrace] event=latencies-invalidated reason=\(reason.rawValue)")
        #endif
        latencyCoordinator.invalidate()
        testingNodeIDs.removeAll()
        latencyReadingsSnapshot = latencyCoordinator.readings
        nodeLatencyProgress = .idle
    }

    private func reconcileNodeLatencies(
        previousNodes: [ProxyNode], previousSubscription: ParsedSubscription?,
        refreshedNodes: [ProxyNode], refreshedSubscription: ParsedSubscription?
    ) {
        guard latencyCoordinator.reconcile(
            previousNodes: previousNodes, previousSubscription: previousSubscription,
            refreshedNodes: refreshedNodes, refreshedSubscription: refreshedSubscription
        ) else { return }
        testingNodeIDs.removeAll()
        latencyReadingsSnapshot = latencyCoordinator.readings
        nodeLatencyProgress = .idle
        #if DEBUG || ROUTE_VALIDATION
        SafeLog.info("[NodeTrace] event=latencies-reconciled retained=\(nodeLatencies.count)")
        #endif
    }

    private func probeNodeLatency(_ nodeID: String, context: LatencyOperationContext) async {
        guard let node = nodes.nodes.first(where: { $0.id == nodeID }) else { return }
        let subscription = await repository.parsedSubscription()
        guard isCurrentLatencyOperation(context) else { return }
        let target = LatencyTarget(node: node, revision: try? SelectedNodeConfigurationIdentity.revision(
            in: subscription, nodeID: nodeID
        ))
        guard beginNodeLatency(target, context: context) else { return }
        guard node.available else {
            await commitNodeLatency(.unavailable, target: target, context: context, phase: "single-result")
            return
        }
        let route = nodeProbeRoute()
        if case .unavailable = route {
            await commitNodeLatency(
                .unavailable, target: target, context: context,
                phase: "state-unavailable"
            )
            return
        }
        #if ROUTE_VALIDATION
        RouteValidationNodeLatencyEvidence.write(stage: "candidate-started")
        #endif
        do {
            guard let revision = target.revision else { throw SelectedNodeTunnelError.missingNode }
            guard let subscription, nodesLoadState.hasUsableResult else { throw SelectedNodeTunnelError.missingNode }
            let configuration = try await candidateMihomoTunnelConfiguration(
                nodeID: nodeID, mode: .rule, subscription: subscription
            )
            guard isCurrentLatencyOperation(context),
                  configuration.configurationRevision == revision else { return }
            guard let coreName = configuration.coreName else { throw SelectedNodeTunnelError.missingNode }
            #if ROUTE_VALIDATION
            RouteValidationNodeLatencyEvidence.write(stage: "candidate-created")
            #endif
            let outcome: NodeProbeOutcome
            switch route {
            case .appOnly:
                guard appOnlyProbeStillSafe() else {
                    outcome = .unavailable
                    break
                }
                let probeYAML = try MihomoNodeProbeConfiguration.yaml(from: configuration.yaml)
                #if ROUTE_VALIDATION
                RouteValidationNodeLatencyEvidence.write(stage: "probe-yaml-ready")
                RouteValidationNodeLatencyEvidence.write(stage: "core-probe-started")
                #endif
                outcome = .measured(try await nodeProber.probeNode(
                    yaml: probeYAML, coreName: coreName
                ))
            case let .provider(prober):
                guard prober.nodeProbeState == .connected else {
                    outcome = .unavailable
                    break
                }
                let result = try await prober.probeNodes(
                    coreNames: [coreName],
                    candidatePoolRevision: prober.nodeProbeCandidatePoolRevision
                ).first(where: { $0.coreName == coreName })
                outcome = result.map(Self.nodeProbeOutcome) ?? .unavailable
            case .unavailable:
                outcome = .unavailable
            }
            let published = await commitNodeLatency(outcome, target: target,
                context: context, phase: "single-result")
            #if ROUTE_VALIDATION
            if published, case let .measured(delay) = outcome {
                RouteValidationNodeLatencyEvidence.write(stage: "passed", delayMS: delay)
            }
            #else
            _ = published
            #endif
        } catch is CancellationError {
            // Drained-owner cleanup restores unfinished UI without a failure.
        } catch {
            guard (error as? URLError)?.code != .cancelled else { return }
            let outcome: NodeProbeOutcome = (error as? MihomoNodeProbeError) == .timeout
                ? .timedOut : (error is RecoveryRuntimeError ? .unavailable : .failed)
            let published = await commitNodeLatency(outcome, target: target, context: context, phase: "single-result")
            guard published else { return }
            let category: String
            if let failure = error as? MihomoCoreFailure { category = "core-\(failure.stage)" }
            else if let failure = error as? MihomoNodeProbeError {
                category = failure == .timeout ? "timeout" : "unreachable"
            } else if error is RecoveryRuntimeError { category = "runtime-unavailable" }
            else if let failure = error as? SelectedNodeTunnelError {
                switch failure {
                case .missingNode: category = "candidate-missing-node"
                case .unresolvedReference: category = "candidate-unresolved-reference"
                case .unsupportedProtocol: category = "candidate-unsupported-protocol"
                case .unsupportedField: category = "candidate-unsupported-field"
                case .unsupportedValue: category = "candidate-unsupported-value"
                case .endpointRequiresIPv4: category = "candidate-needs-ipv4"
                case .endpointResolutionFailed: category = "candidate-endpoint-resolution"
                case .unsupportedMode: category = "candidate-mode"
                }
            }
            else { category = "other" }
            SafeLog.warning("[Latency] probe failed category=\(category)")
            #if ROUTE_VALIDATION
            RouteValidationNodeLatencyEvidence.write(stage: "failed", category: category)
            #endif
        }
    }

    private func refreshNodes(force: Bool) async {
        guard force else { return }
        await nodeSession.refresh(manual: false) { [weak self] manual in
            await self?.runCoordinatedNodesRefresh(clearAllLatenciesOnSuccess: manual)
        }
    }

    private func runCoordinatedNodesRefresh(clearAllLatenciesOnSuccess: Bool) async {
        // Only authenticated initialization and an explicit refresh own a
        // subscription download. The coordinator joins/cancels in-flight work.
        guard !Task.isCancelled, let context = authenticatedLoadContext() else { return }
        #if DEBUG || ROUTE_VALIDATION
        SafeLog.info("[NodeTrace] event=catalog-start manual=\(clearAllLatenciesOnSuccess)")
        #endif
        let hadUsableValue = nodesLoadState.hasUsableResult || !nodes.nodes.isEmpty
        nodesLoadState = .loading
        nodesAttemptedAt = Date()
        await runNodesRefresh(
            context: context, hadUsableValue: hadUsableValue,
            clearAllLatenciesOnSuccess: clearAllLatenciesOnSuccess
        )
    }

    func refreshNotices() async {
        await refreshNotices(force: true)
    }

    func refreshNoticesIfNeeded() async {
        await refreshNotices(force: false)
    }

    private func refreshNotices(force: Bool) async {
        if let noticesRefreshTask {
            await noticesRefreshTask.value
            return
        }
        guard let context = authenticatedLoadContext(), shouldRefresh(
            force: force,
            lastSuccess: noticesRefreshedAt,
            lastAttempt: noticesAttemptedAt,
            interval: BusinessRefreshPolicy.noticesInterval
        ) else { return }

        let hadUsableValue = noticesLoadState.hasUsableResult || !notices.isEmpty
        noticesLoadState = .loading
        noticesAttemptedAt = Date()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runNoticesRefresh(context: context, hadUsableValue: hadUsableValue)
        }
        noticesRefreshTask = task
        await task.value
        if authenticatedGeneration == context.generation {
            noticesRefreshTask = nil
        }
    }

    func selectNode(_ id: String) async {
        #if DEBUG
        // UI-only fixture: no subscription or network call is permitted.
        if offline, ProcessInfo.processInfo.arguments.contains("--ui-node-sample"),
           nodes.nodes.contains(where: { $0.id == id }) {
            nodes = NodeRepositorySnapshot(nodes: nodes.nodes, selectedNodeID: id)
            return
        }
        #endif
        await perform(showBusyIndicator: false) {
            try await self.commitSelectedNode(id)
        }
    }

    /// Starts the connected-tunnel transaction and returns synchronously so
    /// NodesView can dismiss before any Provider response is awaited.
    @discardableResult
    func beginConnectedNodeSwitch(_ targetNodeID: String) -> Bool {
        guard vpnController?.state == .connected,
              let oldNodeID = nodes.selectedNodeID else { return false }
        if targetNodeID == oldNodeID { return true }
        guard !nodeSwitchInFlight,
              nodes.nodes.contains(where: { $0.id == targetNodeID }),
              let account = session else { return false }
        let requestID = UUID()
        let accountGeneration = authenticatedGeneration
        let catalogGeneration = latencyRepositoryGeneration
        nodeSwitchInFlight = true
        activeNodeSwitchRequestID = requestID
        Task { [weak self] in
            await self?.performConnectedNodeSwitch(
                requestID: requestID,
                oldNodeID: oldNodeID,
                targetNodeID: targetNodeID,
                account: account,
                accountGeneration: accountGeneration,
                catalogGeneration: catalogGeneration
            )
        }
        return true
    }

    private func performConnectedNodeSwitch(
        requestID: UUID, oldNodeID: String, targetNodeID: String,
        account: UserSession, accountGeneration: UUID,
        catalogGeneration: NodeLatencySubscriptionGeneration?
    ) async {
        defer {
            if activeNodeSwitchRequestID == requestID {
                activeNodeSwitchRequestID = nil
                nodeSwitchInFlight = false
            }
        }
        guard let controller = vpnController,
              activeNodeSwitchRequestID == requestID,
              controller.state == .connected,
              session == account,
              authenticatedGeneration == accountGeneration,
              latencyRepositoryGeneration == catalogGeneration,
              let subscription = await repository.parsedSubscription(),
              let targetRevision = try? SelectedNodeConfigurationIdentity.revision(
                in: subscription, nodeID: targetNodeID
              ),
              let targetCoreName = subscription.runtimeProxyRecords[targetNodeID]?.coreName,
              let oldCoreName = subscription.runtimeProxyRecords[oldNodeID]?.coreName else { return }
        do {
            let result = try await controller.switchNode(
                requestID: requestID,
                targetCoreName: targetCoreName,
                candidatePoolRevision: controller.activeCandidatePoolRevision
            )
            let current = await repository.parsedSubscription()
            let contextMatches = controller.state == .connected
                && session == account
                && authenticatedGeneration == accountGeneration
                && latencyRepositoryGeneration == catalogGeneration
                && current?.nodes.contains(where: { $0.id == targetNodeID }) == true
                && (try? SelectedNodeConfigurationIdentity.revision(
                    in: current, nodeID: targetNodeID
                )) == targetRevision
                && current?.runtimeProxyRecords[targetNodeID]?.coreName == targetCoreName
            await NodeHotSwitchFinalizer.apply(
                requestID: requestID,
                currentRequestID: activeNodeSwitchRequestID,
                targetCoreName: targetCoreName,
                result: result,
                contextMatches: contextMatches,
                commit: {
                    try await self.commitSelectedNode(
                    targetNodeID,
                    expectedRevision: targetRevision,
                    expectedCoreName: targetCoreName
                    )
                },
                rollback: {
                    // Core has already acknowledged B. One best-effort A
                    // readback is the only rollback attempt.
                    _ = try? await controller.switchNode(
                        requestID: UUID(),
                        targetCoreName: oldCoreName,
                        candidatePoolRevision: controller.activeCandidatePoolRevision
                    )
                }
            )
        } catch {
            // Connected node switching is intentionally silent. The old
            // selectedNodeID remains the user-visible formal state.
        }
    }

    /// Persist the user's selected node without starting or switching a tunnel.
    func commitSelectedNode(_ id: String, expectedRevision: String? = nil,
                            expectedCoreName: String? = nil) async throws {
        let (_, account) = try requireAccount()
        let accountGeneration = authenticatedGeneration
        let initialSubscription = await repository.parsedSubscription()
        guard let requestedRevision = try expectedRevision ?? SelectedNodeConfigurationIdentity.revision(
            in: initialSubscription, nodeID: id
        ), let requestedCoreName = expectedCoreName ?? initialSubscription?.runtimeProxyRecords[id]?.coreName else {
            throw SelectedNodeTunnelError.missingNode
        }
        try Task.checkCancellation()
        guard session == account, authenticatedGeneration == accountGeneration else { throw CancellationError() }
        let selected: NodeRepositorySnapshot
        if let repository = repository as? any NodeSelectionIdentitySelecting {
            selected = try await repository.selectNode(id: id, session: account,
                expectedRevision: requestedRevision, expectedCoreName: requestedCoreName)
        } else {
            selected = try await repository.selectNode(id: id, session: account)
        }
        let selectionCatalog = latencyRepositoryGeneration
        #if DEBUG
        if let nodeSelectionDidPersistForTesting { await nodeSelectionDidPersistForTesting() }
        #endif
        let subscription = await repository.parsedSubscription()
        let revision = try SelectedNodeConfigurationIdentity.revision(in: subscription, nodeID: id)
        // The same display ID may identify another collision member after a
        // catalog refresh. Publish only the entity requested before persistence.
        guard !Task.isCancelled, session == account, authenticatedGeneration == accountGeneration,
              latencyRepositoryGeneration == selectionCatalog, selected.selectedNodeID == id,
              revision == requestedRevision,
              subscription?.runtimeProxyRecords[id]?.coreName == requestedCoreName else {
            throw CancellationError()
        }
        nodes = selected
        selectedTunnelRevision = requestedRevision
        // A successful newer choice owns this snapshot and supersedes a
        // suspended refresh, including that refresh's loading indicator.
        if nodesLoadState.isLoading { nodesLoadState = .loaded }
    }

    /// Builds one fully reviewed candidate without changing the visible or
    /// persisted selection. The Extension receives it through the protected
    /// App Group only after this account and subscription revision are checked.
    func candidateMihomoTunnelConfiguration(
        nodeID: String, mode: ProxyMode
    ) async throws -> MihomoTunnelConfiguration {
        // A failed manual download may leave an account-verified subscription
        // intact. Its stale warning must not invalidate that Core candidate.
        guard nodesLoadState.hasUsableResult,
              let subscription = await repository.parsedSubscription() else {
            throw SelectedNodeTunnelError.missingNode
        }
        let candidate = try await candidateMihomoTunnelConfiguration(
            nodeID: nodeID, mode: mode, subscription: subscription
        )
        guard candidate.configurationRevision == (try SelectedNodeConfigurationIdentity.revision(
            in: await repository.parsedSubscription(), nodeID: nodeID
        )) else { throw CancellationError() }
        return candidate
    }

    /// The remote plaintext DNS path is isolated until an on-device packet
    /// routing check proves it safe. Normal builds keep the previously
    /// validated authenticated DoH path for Core DNS.
    private var remoteCoreDNSValidationEnabled: Bool {
        #if ROUTE_VALIDATION
        ProcessInfo.processInfo.arguments.contains("--route-mihomo-dns")
        #else
        false
        #endif
    }

    private func candidateMihomoTunnelConfiguration(
        nodeID: String, mode: ProxyMode, subscription: ParsedSubscription,
        requireAvailable: Bool = true
    ) async throws -> MihomoTunnelConfiguration {
        let (currentConfig, account) = try requireAccount()
        let generation = authenticatedGeneration
        guard !offline,
              let node = subscription.nodes.first(where: {
                  $0.id == nodeID && (!requireAvailable || $0.available)
              }),
              let revision = try SelectedNodeConfigurationIdentity.revision(
                in: subscription, nodeID: nodeID
              ),
              let rawDNS = Bundle.main.object(forInfoDictionaryKey: "TunnelDoHEndpoint") as? String,
              let dnsEndpoint = URL(string: rawDNS) else {
            throw SelectedNodeTunnelError.missingNode
        }
        guard !IPv4AddressValidator.looksLikeLiteral(node.server)
                || IPv4AddressValidator.publicUnicast(node.server) else {
            throw SelectedNodeTunnelError.endpointRequiresIPv4
        }
        let request = TunnelRequest(
            nodeID: nodeID, mode: mode, configurationRevision: revision
        )
        let mapper = SelectedNodeTunnelMapper()
        let accountScope = account.nodeSelectionAccountScope?.rawValue
        let configuration: MihomoTunnelConfiguration
        do {
            configuration = try mapper.makeConfiguration(
                subscription: subscription, request: request,
                dnsEndpoint: dnsEndpoint, accountScope: accountScope,
                mihomoDns: currentConfig.mihomoDns,
                remoteMihomoDNSValidated: remoteCoreDNSValidationEnabled
            )
        } catch SelectedNodeTunnelError.endpointRequiresIPv4 {
            let resolver = SelectedNodeEndpointResolver()
            // A connected tunnel may route libc DNS into itself. Candidate
            // replacement then uses the authenticated DoH path through the
            // working tunnel. With VPN disconnected, match the cold-start
            // resolver: accept a validated public system A record, or fall
            // back to the configured authenticated DoH endpoint.
            let resolved: String
            if vpnController?.state == .connected {
                resolved = try await resolver.resolveUsingConfiguredDoH(
                    node.server, endpoint: dnsEndpoint
                )
            } else {
                resolved = try await SelectedNodeEndpointResolver.resolvePublicIPv4(
                    system: { try await resolver.resolve(node.server) },
                    configuredDoH: {
                        try await resolver.resolveUsingConfiguredDoH(
                            node.server, endpoint: dnsEndpoint
                        )
                    }
                )
            }
            configuration = try mapper.makeConfiguration(
                subscription: subscription, request: request,
                dnsEndpoint: dnsEndpoint, accountScope: accountScope,
                resolvedServerIPv4: resolved, mihomoDns: currentConfig.mihomoDns,
                remoteMihomoDNSValidated: remoteCoreDNSValidationEnabled
            )
        }
        guard session == account, authenticatedGeneration == generation,
              config?.mihomoDns == currentConfig.mihomoDns,
              revision == (try SelectedNodeConfigurationIdentity.revision(
                in: subscription, nodeID: nodeID
              )) else { throw CancellationError() }
        return configuration
    }
    func tunnelRequest(mode: ProxyMode) async throws -> TunnelRequest {
        guard config != nil else {
            throw NetworkClientError.configUnavailable("客户端配置暂时无法获取，请检查网络后重试")
        }
        // A visible node is only display data. Join an already-running initial
        // read, but never start another subscription download from the power button.
        let generation = authenticatedGeneration
        guard let context = authenticatedLoadContext() else {
            throw nodes.selectedNodeID == nil
                ? VPNConnectionPreflightError.noNodeSelected
                : VPNConnectionPreflightError.selectedNodeMissing
        }
        await nodeSession.waitForRefresh()
        try Task.checkCancellation()
        guard authenticatedGeneration == generation, isCurrent(context) else {
            throw CancellationError()
        }
        return try await validatedTunnelRequest(mode: mode, context: context)
    }

    /// Side-effect-free connection snapshot check, also used after asynchronous
    /// mapping work. It never cancels probes or schedules a subscription read.
    private func validatedTunnelRequest(
        mode: ProxyMode, context: AuthenticatedLoadContext
    ) async throws -> TunnelRequest {
        guard isCurrent(context) else { throw CancellationError() }
        // Only a missing verified snapshot blocks connection. A failed manual
        // refresh retains the last committed subscription for this account.
        guard nodesLoadState.hasUsableResult else {
            throw VPNConnectionPreflightError.selectedNodeMissing
        }
        guard let nodeID = nodes.selectedNodeID else {
            throw VPNConnectionPreflightError.noNodeSelected
        }
        guard nodes.nodes.contains(where: { $0.id == nodeID }),
              let subscription = await repository.parsedSubscription(),
              isCurrent(context),
              subscription.nodes.contains(where: { $0.id == nodeID }) else {
            throw VPNConnectionPreflightError.selectedNodeMissing
        }
        guard let revision = try SelectedNodeConfigurationIdentity.revision(
            in: subscription, nodeID: nodeID
        ) else {
            throw VPNConnectionPreflightError.nodeConfigurationInvalid
        }
        return TunnelRequest(nodeID: nodeID, mode: mode, configurationRevision: revision)
    }

    func minimalVPNConfiguration(mode: ProxyMode) async throws -> MihomoTunnelConfiguration {
        let request = try await tunnelRequest(mode: mode)
        let configuration: MihomoTunnelConfiguration
        do {
            configuration = try await selectedMihomoTunnelConfiguration(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let current = await repository.parsedSubscription()
            guard nodes.selectedNodeID == request.nodeID,
                  current?.nodes.contains(where: { $0.id == request.nodeID }) == true else {
                throw VPNConnectionPreflightError.selectedNodeMissing
            }
            throw VPNConnectionPreflightError.nodeConfigurationInvalid
        }
        let geoData = try await GeoDataPreparer.prepareIfNeeded()
        try Task.checkCancellation()
        return configuration.withGeoDataPublication(
            geoData.publication.publicationIdentifier
        )
    }

    /// Reads the current account's parsed subscription at connection time.
    /// No node secret is retained by the visible ProxyNode list or VPN settings.
    func selectedMihomoTunnelConfiguration(for request: TunnelRequest) async throws -> MihomoTunnelConfiguration {
        guard let account = session else { throw SelectedNodeTunnelError.missingNode }
        let generation = authenticatedGeneration
        guard let context = authenticatedLoadContext(),
              request == (try await validatedTunnelRequest(mode: request.mode, context: context)),
              session == account, authenticatedGeneration == generation,
              let subscription = await repository.parsedSubscription() else {
            throw SelectedNodeTunnelError.missingNode
        }
        guard session == account, authenticatedGeneration == generation else {
            throw SelectedNodeTunnelError.missingNode
        }
        guard let node = subscription.nodes.first(where: { $0.id == request.nodeID }) else {
            throw SelectedNodeTunnelError.missingNode
        }
        guard !IPv4AddressValidator.looksLikeLiteral(node.server)
                || IPv4AddressValidator.publicUnicast(node.server) else {
            throw SelectedNodeTunnelError.endpointRequiresIPv4
        }
        guard let rawDNS = Bundle.main.object(forInfoDictionaryKey: "TunnelDoHEndpoint") as? String,
              let dnsEndpoint = URL(string: rawDNS) else {
            throw SelectedNodeTunnelError.unsupportedValue
        }
        let mapper = SelectedNodeTunnelMapper()
        let accountScope = account.nodeSelectionAccountScope?.rawValue
        do {
            let configuration = try mapper.makeConfiguration(
                subscription: subscription, request: request, dnsEndpoint: dnsEndpoint,
                accountScope: accountScope, mihomoDns: context.config.mihomoDns,
                remoteMihomoDNSValidated: remoteCoreDNSValidationEnabled
            )
            let prepared = try await attachFixedCandidatePoolIfEnabled(
                to: configuration, subscription: subscription, account: account,
                accountGeneration: generation
            )
            return prepared
        } catch SelectedNodeTunnelError.endpointRequiresIPv4 {
            // Only a fully reviewed node can reach this branch. Resolve it
            // before NE starts, then pin that exact IP in the outbound and
            // the tunnel's excluded /32 route. Never resolve inside Core.
            let resolver = SelectedNodeEndpointResolver()
            // A non-routable system DNS answer cannot be pinned as the
            // physical server. The configured TLS-validated numeric DoH
            // endpoint is the sole fallback, and its strict parser accepts
            // only this node's matching public A record before NE starts.
            let resolved = try await SelectedNodeEndpointResolver.resolvePublicIPv4(
                system: { try await resolver.resolve(node.server) },
                configuredDoH: {
                    try await resolver.resolveUsingConfiguredDoH(
                        node.server, endpoint: dnsEndpoint
                    )
                }
            )
            guard session == account, authenticatedGeneration == generation,
                  config?.mihomoDns == context.config.mihomoDns,
                  request == (try await validatedTunnelRequest(mode: request.mode, context: context)) else {
                throw SelectedNodeTunnelError.missingNode
            }
            let configuration = try mapper.makeConfiguration(
                subscription: subscription, request: request, dnsEndpoint: dnsEndpoint,
                accountScope: accountScope, resolvedServerIPv4: resolved,
                mihomoDns: context.config.mihomoDns,
                remoteMihomoDNSValidated: remoteCoreDNSValidationEnabled
            )
            let prepared = try await attachFixedCandidatePoolIfEnabled(
                to: configuration, subscription: subscription, account: account,
                accountGeneration: generation
            )
            return prepared
        }
    }

    private func attachFixedCandidatePoolIfEnabled(
        to selected: MihomoTunnelConfiguration,
        subscription: ParsedSubscription,
        account: UserSession,
        accountGeneration: UUID,
        validateCommittedSubscription: Bool = true
    ) async throws -> MihomoTunnelConfiguration {
        // Production prepares only mapper-approved proxies in the App. Probe
        // availability and cached latency never decide Core membership.
        let selectedMode: ProxyMode = selected.mode == "global" ? .global : .rule
        let ordered = [subscription.nodes.first { $0.id == selected.nodeID }].compactMap { $0 }
            + subscription.nodes.filter { $0.id != selected.nodeID }
        let bounded = Array(ordered.prefix(MihomoStableCandidatePoolBuilder.maximumCandidates))
        guard !bounded.isEmpty else { return selected }
        var candidates: [NodeProbeCandidate] = []
        var skipped = 0
        var candidateNodeIDs = Set<String>()
        var candidateCoreNames = Set<String>()
        do {
            for node in bounded {
                try Task.checkCancellation()
                do {
                    let mapped = node.id == selected.nodeID ? selected
                        : try await candidateMihomoTunnelConfiguration(
                            nodeID: node.id, mode: selectedMode,
                            subscription: subscription, requireAvailable: false
                        )
                    guard let coreName = mapped.coreName,
                          let revision = mapped.configurationRevision else {
                        throw SelectedNodeTunnelError.missingNode
                    }
                    guard candidateNodeIDs.insert(node.id).inserted,
                          candidateCoreNames.insert(coreName).inserted else {
                        skipped += 1
                        continue
                    }
                    candidates.append(NodeProbeCandidate(
                        nodeID: node.id, revision: revision, coreName: coreName,
                        yaml: try MihomoNodeProbeConfiguration.yaml(from: mapped.yaml)
                    ))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    skipped += 1
                }
            }
            guard candidates.contains(where: { $0.nodeID == selected.nodeID }) else {
                return selected
            }
            guard session == account,
                  authenticatedGeneration == accountGeneration else {
                throw CancellationError()
            }
            if validateCommittedSubscription {
                guard let current = await repository.parsedSubscription(),
                      current.nodes.map(\.id) == subscription.nodes.map(\.id) else {
                    throw CancellationError()
                }
                for candidate in candidates {
                    guard candidate.revision == (try SelectedNodeConfigurationIdentity.revision(
                        in: current, nodeID: candidate.nodeID
                    )) else { throw CancellationError() }
                }
            }
            let pool = try MihomoStableCandidatePoolBuilder.build(
                selected: selected, candidates: candidates
            )
            SafeLog.info("[FixedPool] prepared candidates=\(pool.candidates.count) skipped=\(skipped) truncated=\(max(0, ordered.count - bounded.count)) bytes=\(pool.yaml.utf8.count)")
            return selected.withCandidatePool(
                yaml: pool.yaml, candidates: pool.candidates, revision: pool.revision
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Unsupported or unreachable candidates cannot be silently
            // reported as an all-node test. Keep the established VPN path.
            SafeLog.warning("[FixedPool] unavailable category=preparation")
            return selected
        }
    }

    func loadCommerce() async {
        let context = requestAccountContext()
        await refreshPlans(force: true)
        guard !Task.isCancelled, isCurrent(context), !busy else { return }
        ordersLoadState = .loading
        let failure = await perform(reportGlobal: false, showBusyIndicator: false) {
            let (config, session) = try self.requireAccount()
            // Older builds persisted an uncertain create reservation. V2Board
            // now owns duplicate-order rejection, so this legacy gate must not
            // block a new, explicit user action. Checkout reservations remain.
            try? await self.pendingPayments.clearCreationIntents(for: session)
            try self.requireCurrent(context)
            let fetched = try await self.api.fetchOrders(config: config, session: session)
            try self.requireCurrent(context)
            self.orders = fetched
        }
        guard isCurrent(context) else { return }
        ordersLoadState = failure.map { failureState($0, retaining: !orders.isEmpty) }
            ?? (orders.isEmpty ? .empty : .loaded)
    }
    func validateCoupon(code: String, planID: Int) async -> PurchaseCouponValidationOutcome {
        let context = requestAccountContext()
        let normalizedCode = code.trimmed
        guard !normalizedCode.isEmpty else {
            return .unavailable(.localized("purchase.payment.coupon_invalid"))
        }
        var validatedCoupon: PurchaseCoupon?
        var businessFeedback: LocalizedMessage?
        let failure = await perform(reportGlobal: false, showBusyIndicator: false) {
            let (config, session) = try self.requireAccount()
            let coupon: PurchaseCoupon
            do {
                coupon = try await self.api.checkCoupon(
                    config: config,
                    session: session,
                    code: normalizedCode,
                    planID: planID
                )
            } catch let error as NetworkClientError {
                businessFeedback = Self.couponBusinessFeedback(for: error)
                throw error
            }
            try self.requireCurrent(context)
            validatedCoupon = coupon
        }
        if let failure,
           failure == .localized(L10nKey.errorAuthenticationExpired),
           session == nil {
            return .unavailable(failure)
        }
        guard !Task.isCancelled, isCurrent(context) else { return .cancelled }
        if let validatedCoupon { return .available(validatedCoupon) }
        if let businessFeedback { return .unavailable(businessFeedback) }
        if let failure { return .unavailable(failure) }
        return .cancelled
    }

    static func couponBusinessFeedback(
        for error: NetworkClientError
    ) -> LocalizedMessage? {
        guard case let .backendBusinessError(message) = error else { return nil }
        let normalized = message.trimmed.lowercased()
        let expiredMessages = [
            "this coupon has expired",
            "优惠券已过期"
        ]
        if expiredMessages.contains(normalized) {
            return .localized("purchase.payment.coupon_expired")
        }
        return .localized("purchase.payment.coupon_unavailable")
    }

    @discardableResult
    func createOrder(
        plan: PurchasePlan,
        cycle: PurchasePlanCycle,
        couponCode: String? = nil
    ) async -> PurchaseOrderCreationOutcome {
        var outcome = PurchaseOrderCreationOutcome.cancelled
        let failure = await perform {
            let (config, session) = try self.requireAccount()
            let context = self.requestAccountContext()
            // One in-flight operation is still enforced by perform()/busy, but
            // no create reservation survives a completed user action.
            try? await self.pendingPayments.clearCreationIntents(for: session)
            try self.requireCurrent(context)
            let trade = try await self.api.createOrder(config: config, session: session,
                planID: plan.id, period: cycle.period, couponCode: couponCode)
            try self.requireCurrent(context)
            do {
                try await self.pendingPayments.save(self.pendingPayment(
                    trade: trade, session: session, planID: plan.id,
                    period: cycle.period.rawValue))
            } catch {
                // The server already returned a definite trade number. Local
                // recovery persistence must not turn that success into another
                // order submission opportunity.
                SafeLog.warning("Order created; pending payment persistence unavailable")
            }
            try self.requireCurrent(context)
            // Refreshing the list is ancillary once order/save has returned a
            // definite trade number. Payment preparation reads the new order
            // directly; a list-read outage must never invite another POST.
            do {
                let fetched = try await self.api.fetchOrders(config: config, session: session)
                try self.requireCurrent(context)
                self.orders = fetched
            } catch {
                try self.requireCurrent(context)
                if case NetworkClientError.authenticationExpired = error { throw error }
                SafeLog.warning("Order created; list refresh deferred category=read_unavailable")
            }
            try self.requireCurrent(context)
            outcome = .created(tradeNo: trade)
        }
        if case .created = outcome { return outcome }
        if let failure {
            if failure == .localized("purchase.payment.unknown_order") {
                return .unknownResult
            }
            return .unavailable(failure)
        }
        return outcome
    }
    func loadPaymentMethods() async {
        guard !busy else { return }
        let context = requestAccountContext()
        paymentMethodsLoadState = .loading
        let failure = await perform(reportGlobal: false) {
            let (config, session) = try self.requireAccount()
            self.checkout = nil
            let fetched = try await self.api.fetchPaymentMethods(config: config, session: session)
            try self.requireCurrent(context)
            self.paymentMethods = fetched
        }
        guard isCurrent(context) else { return }
        paymentMethodsLoadState = failure.map { failureState($0, retaining: !paymentMethods.isEmpty) }
            ?? (paymentMethods.isEmpty ? .empty : .loaded)
    }
    func loadOrderDetail(trade: String) async -> PurchaseOrderDetailLoadOutcome {
        guard !busy else { return .cancelled }
        let context = requestAccountContext()
        var loaded: PurchaseOrderDetail?
        let failure = await perform(reportGlobal: false, showBusyIndicator: false) {
            let (config, session) = try self.requireAccount()
            let detail = try await self.api.fetchOrderDetail(
                config: config,
                session: session,
                tradeNo: trade
            )
            try self.requireCurrent(context)
            loaded = detail
        }
        guard isCurrent(context), !Task.isCancelled else { return .cancelled }
        if let loaded { return .loaded(loaded) }
        if let failure { return .unavailable(failure) }
        return .cancelled
    }
    @discardableResult
    func beginCheckout(
        trade: String,
        method: Int
    ) async -> OwnedPurchaseCheckout? {
        var outcome: OwnedPurchaseCheckout?
        await perform {
            let (config, session) = try self.requireAccount()
            let context = self.requestAccountContext()
            let proposed = PurchaseWriteIntent(id: UUID(),
                accountIdentifier: PendingPaymentStore.accountIdentifier(for: session), operation: .checkout,
                tradeNo: trade, planID: nil, period: nil, priceCents: nil,
                baselineTradeNos: [], startedAt: Date())
            var intent = try await self.pendingPayments.reserve(proposed)
            try self.requireCurrent(context)
            self.checkout = nil
            guard intent.id == proposed.id else {
                try await self.reconcileCheckout(intent, config: config, session: session, context: context)
                return
            }
            let result: PurchaseCheckoutResult
            do {
                result = try await self.api.checkoutOrder(config: config, session: session, tradeNo: trade, methodID: method)
            } catch {
                try self.requireCurrent(context)
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                if self.isDefiniteWriteFailure(error) {
                    try await self.pendingPayments.finish(intent, retainingIntent: false)
                    throw error
                }
                intent.submissionEndedAt = Date()
                try await self.pendingPayments.finish(intent, retainingIntent: true)
                try self.requireCurrent(context)
                try await self.reconcileCheckout(intent, config: config, session: session, context: context)
                return
            }
            try self.requireCurrent(context)
            try await self.pendingPayments.finish(intent, retainingIntent: false)
            try self.requireCurrent(context)
            let owned = OwnedPurchaseCheckout(
                tradeNo: trade,
                operationID: proposed.id,
                result: result,
                account: context
            )
            self.checkout = owned
            outcome = owned
        }
        guard let outcome, isCurrentCheckout(outcome, tradeNo: trade) else {
            return nil
        }
        return outcome
    }

    func beginPaymentMonitoring(
        detail: PurchaseOrderDetail
    ) async -> PurchasePaymentMonitoringStartOutcome {
        guard let session else {
            return .unavailable(.localized(L10nKey.commonAccountRequired))
        }
        let context = requestAccountContext()
        let owner = PendingPaymentStore.accountIdentifier(for: session)
        let existing = await pendingPayments.payment(for: session)
        guard isCurrent(context), !Task.isCancelled else { return .cancelled }

        let payment = PurchasePendingPayment(
            tradeNo: detail.tradeNo,
            accountIdentifier: owner,
            planID: detail.planID,
            period: detail.period,
            createdAt: existing?.tradeNo == detail.tradeNo
                ? existing?.createdAt ?? Date() : Date(),
            paymentStartedAt: existing?.tradeNo == detail.tradeNo
                ? existing?.paymentStartedAt ?? Date() : Date()
        )
        do {
            try await pendingPayments.save(payment)
            guard isCurrent(context), !Task.isCancelled else { return .cancelled }
            return .ready(payment)
        } catch is CancellationError {
            return .cancelled
        } catch let error as NetworkClientError {
            return .unavailable(error.userFacingMessage)
        } catch {
            return .unavailable(.localized(L10nKey.commonOperationFailed))
        }
    }

    func restoredPaymentMonitoring() async -> PurchasePendingPayment? {
        guard let session else { return nil }
        let context = requestAccountContext()
        let payment = await pendingPayments.payment(for: session)
        guard isCurrent(context), !Task.isCancelled,
              payment?.paymentStartedAt != nil else { return nil }
        return payment
    }

    func checkPaymentStatus(
        trade: String
    ) async -> PurchasePaymentStatusCheckOutcome {
        let context = requestAccountContext()
        let key = PaymentStatusCheckKey(
            generation: context.generation,
            accountScope: context.accountScope,
            authData: context.authData,
            tradeNo: trade
        )
        if let current = paymentStatusChecks[key] {
            return await current.task.value
        }

        let operationID = UUID()
        let task = Task { [weak self] in
            guard let self else { return PurchasePaymentStatusCheckOutcome.cancelled }
            return await self.runPaymentStatusCheck(trade: trade, context: context)
        }
        paymentStatusChecks[key] = (operationID, task)
        let outcome = await task.value
        if paymentStatusChecks[key]?.id == operationID {
            paymentStatusChecks.removeValue(forKey: key)
        }
        return outcome
    }

    func cancelPendingOrder(
        trade: String,
        status: PurchasePaymentStatus = .pending
    ) async -> PurchaseOrderCancellationOutcome {
        guard PurchaseOrderActionPolicy.canCancel(status: status) else {
            return .cancelled
        }
        var outcome = PurchaseOrderCancellationOutcome.cancelled
        let failure = await perform(reportGlobal: false, showBusyIndicator: false) {
            let (config, session) = try self.requireAccount()
            let context = self.requestAccountContext()
            try await self.api.cancelOrder(
                config: config,
                session: session,
                tradeNo: trade
            )
            try self.requireCurrent(context)
            try await self.pendingPayments.clear(tradeNo: trade, for: session)
            try self.requireCurrent(context)
            self.updateOrderStatus(trade: trade, status: 2)
            outcome = .cancelledOrder
        }
        if outcome == .cancelledOrder { return outcome }
        if let failure { return .unavailable(failure) }
        return .cancelled
    }

    private func runPaymentStatusCheck(
        trade: String,
        context: RequestAccountContext
    ) async -> PurchasePaymentStatusCheckOutcome {
        do {
            let (config, session) = try requireAccount()
            try requireCurrent(context)
            let serverStatus = try await api.checkOrderStatus(
                config: config,
                session: session,
                tradeNo: trade
            )
            try requireCurrent(context)
            let status = PurchasePaymentStatus(serverValue: serverStatus)
            updateOrderStatus(trade: trade, status: serverStatus)
            if status.isTerminal {
                try await pendingPayments.clear(tradeNo: trade, for: session)
                try requireCurrent(context)
            }
            return .status(status)
        } catch is CancellationError {
            return .cancelled
        } catch let error as NetworkClientError {
            guard !Task.isCancelled, isCurrent(context) else { return .cancelled }
            if case .authenticationExpired = error {
                guard let cleared = await invalidateAuthenticatedSession(ifCurrent: context),
                      isCurrent(cleared) else { return .cancelled }
                authMessage = error.userFacingMessage
                return .cancelled
            }
            return .unavailable(error.userFacingMessage)
        } catch let error as PurchaseCommerceError {
            guard !Task.isCancelled, isCurrent(context) else { return .cancelled }
            let feedback: LocalizedMessage = switch error {
            case .orderCreationResultUnknown: .localized("purchase.payment.unknown_order")
            case .checkoutResultUnknown: .localized("purchase.payment.unknown_checkout")
            case .cancellationResultUnknown: .localized(L10nKey.purchaseCancellationUnknown)
            case .invalidResponse: .localized(L10nKey.purchaseInvalidResponse)
            }
            return .unavailable(feedback)
        } catch {
            guard !Task.isCancelled, isCurrent(context) else { return .cancelled }
            return .unavailable(.localized(L10nKey.commonOperationFailed))
        }
    }

    private func updateOrderStatus(trade: String, status: Int) {
        guard let index = orders.firstIndex(where: { $0.tradeNo == trade }) else { return }
        orders[index].status = status
    }
    func checkOrder(_ trade: String) async {
        await perform {
            let (config, session) = try self.requireAccount()
            let context = self.requestAccountContext()
            let serverStatus = try await self.api.checkOrderStatus(
                config: config,
                session: session,
                tradeNo: trade
            )
            try self.requireCurrent(context)
            let checkoutIntent = try await self.pendingPayments.intent(for: session, operation: .checkout, tradeNo: trade)
            try self.requireCurrent(context)
            let status = PurchasePaymentStatus(serverValue: serverStatus)
            if status.isTerminal {
                if var intent = checkoutIntent {
                    intent.resolvedStatus = serverStatus
                    try await self.pendingPayments.finish(intent, retainingIntent: true)
                }
                try self.requireCurrent(context)
                try await self.pendingPayments.clear(tradeNo: trade, for: session)
            }
            try self.requireCurrent(context)
            let fetched = try await self.api.fetchOrders(config: config, session: session)
            try self.requireCurrent(context)
            self.orders = fetched
            self.message = .localized(checkoutIntent != nil && status == .pending
                ? "purchase.payment.unknown_checkout" : Self.orderStatusKey(serverStatus))
        }
    }

    private func pendingPayment(trade: String, session: UserSession, planID: Int, period: String) -> PurchasePendingPayment {
        PurchasePendingPayment(tradeNo: trade, accountIdentifier: PendingPaymentStore.accountIdentifier(for: session),
            planID: planID, period: period, createdAt: Date(), paymentStartedAt: nil)
    }

    /// The API maps every ambiguous post-submit response to Unknown. Other
    /// NetworkClientErrors here are pre-submit failures or explicit rejections.
    /// Cancellation never reaches this classifier: requireCurrent checks it first.
    private func isDefiniteWriteFailure(_ error: Error) -> Bool {
        guard let error = error as? NetworkClientError else { return false }
        if case .writeResultUnknown = error { return false }
        return true
    }

    private func reconcileCheckout(_ intent: PurchaseWriteIntent, config: AppConfig,
                                   session: UserSession, context: RequestAccountContext) async throws {
        guard let trade = intent.tradeNo else { throw PurchaseCommerceError.checkoutResultUnknown }
        do {
            let serverStatus = try await api.checkOrderStatus(
                config: config,
                session: session,
                tradeNo: trade
            )
            try requireCurrent(context)
            // Pending (0) says nothing about whether checkout produced a payment
            // session. Unknown statuses also never release permission to POST.
            let status = PurchasePaymentStatus(serverValue: serverStatus)
            guard status == .activating || status.isTerminal else {
                message = .localized("purchase.payment.unknown_checkout")
                return
            }
            var resolved = intent
            resolved.resolvedStatus = serverStatus
            try await pendingPayments.finish(resolved, retainingIntent: true)
            try requireCurrent(context)
            if status.isTerminal {
                try await pendingPayments.clear(tradeNo: trade, for: session)
                try requireCurrent(context)
            }
            if let index = orders.firstIndex(where: { $0.tradeNo == trade }) {
                orders[index].status = serverStatus
            }
            checkout = nil // A status read cannot reconstruct a payment URL/QR.
            message = .localized(Self.orderStatusKey(serverStatus))
        } catch {
            try requireCurrent(context)
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if case NetworkClientError.authenticationExpired = error { throw error }
            message = .localized("purchase.payment.unknown_checkout")
        }
    }
    func loadInvitationsIfNeeded() async {
        guard invitationsLoadState == .idle else { return }
        await loadInvitations()
    }

    func loadTrafficIfNeeded() async {
        guard trafficLoadState == .idle else { return }
        await refreshTraffic()
    }

    func refreshTraffic() async {
        if let current = trafficRefreshTask {
            await current.task.value
            return
        }
        guard let context = authenticatedLoadContext() else { return }

        let requestID = UUID()
        let previousState = trafficLoadState
        trafficLoadState = .loading
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runTrafficRefresh(context: context, previousState: previousState)
        }
        trafficRefreshTask = (requestID, task)
        await task.value
        if trafficRefreshTask?.id == requestID {
            trafficRefreshTask = nil
        }
    }

    private func runTrafficRefresh(
        context: AuthenticatedLoadContext,
        previousState: ProfileTrafficState
    ) async {
        do {
            let records = try await trafficLogAPI.fetchTrafficLog(
                config: context.config,
                session: context.session
            )
            try Task.checkCancellation()
            guard isCurrent(context) else { return }
            dailyTraffic = ProfileTrafficAggregation.daily(records)
            trafficLoadState = dailyTraffic.isEmpty ? .empty : .loaded
        } catch is CancellationError {
            guard isCurrent(context) else { return }
            trafficLoadState = previousState
        } catch let error as NetworkClientError {
            if case .authenticationExpired = error {
                await expireSessionIfCurrent(context)
                return
            }
            guard isCurrent(context) else { return }
            trafficLoadState = dailyTraffic.isEmpty
                ? .failed(error.userFacingMessage)
                : .stale(error.userFacingMessage)
        } catch {
            guard isCurrent(context) else { return }
            let message = LocalizedMessage.localized("profile.traffic.load_failed")
            trafficLoadState = dailyTraffic.isEmpty ? .failed(message) : .stale(message)
        }
    }

    func loadInvitations() async {
        guard !busy else { return }
        let context = requestAccountContext()
        invitationsLoadState = .loading
        let failure = await perform(reportGlobal: false, showBusyIndicator: false) {
            let (config, session) = try self.requireAccount()
            let fetched = try await self.api.fetchInviteInfo(config: config, session: session)
            try self.requireCurrent(context)
            self.invitations = fetched
        }
        guard isCurrent(context) else { return }
        invitationsLoadState = failure.map { failureState($0, retaining: invitations != nil) }
            ?? (invitations?.codes.isEmpty == true ? .empty : .loaded)
    }

    @discardableResult
    func generateInviteCode() async -> Bool {
        guard !invitationActionInProgress, !busy else { return false }
        let context = requestAccountContext()
        invitationActionInProgress = true
        invitationFeedback = nil
        var created = false

        let failure = await perform(reportGlobal: false, showBusyIndicator: false) {
            let (config, session) = try self.requireAccount()
            try await self.api.createInviteCode(config: config, session: session)
            try self.requireCurrent(context)
            created = true
        }
        guard isCurrent(context) else { return false }

        if let failure {
            invitationActionInProgress = false
            invitationFeedback = failure
            return false
        }
        guard created else {
            invitationActionInProgress = false
            return false
        }

        await loadInvitations()
        guard isCurrent(context) else { return false }
        invitationActionInProgress = false
        invitationFeedback = .localized("profile.invites.generated")
        return true
    }

    @discardableResult
    func changePassword(
        currentPassword: String,
        newPassword: String,
        confirmation: String
    ) async -> Bool {
        if case .submitting = changePasswordState { return false }
        if let validationKey = Self.changePasswordValidationFailure(
            currentPassword: currentPassword,
            newPassword: newPassword,
            confirmation: confirmation
        ) {
            changePasswordState = .failed(.localized(validationKey))
            return false
        }
        guard let config, let session else {
            changePasswordState = .failed(.localized(L10nKey.commonAccountRequired))
            return false
        }

        let context = requestAccountContext()
        changePasswordState = .submitting
        var failureLogLevel: UserLogLevel = .error
        do {
            try await api.changePassword(
                config: config,
                session: session,
                oldPassword: currentPassword,
                newPassword: newPassword
            )
            try requireCurrent(context)
            changePasswordState = .succeeded
            userSystemLogger.log(
                .success,
                module: .auth,
                key: UserLogKey.passwordChanged
            )
            return true
        } catch is CancellationError {
            if isCurrent(context) { changePasswordState = .idle }
            return false
        } catch let error as NetworkClientError {
            guard isCurrent(context) else { return false }
            changePasswordState = .failed(error.userFacingMessage)
            failureLogLevel = Self.changePasswordFailureLogLevel(error)
        } catch {
            guard isCurrent(context) else { return false }
            changePasswordState = .failed(.localized(L10nKey.commonOperationFailed))
        }
        userSystemLogger.log(
            failureLogLevel,
            module: .auth,
            key: UserLogKey.passwordChangeFailed
        )
        return false
    }

    func clearChangePasswordFeedback() {
        guard case .submitting = changePasswordState else {
            changePasswordState = .idle
            return
        }
    }

    @discardableResult
    func requestAccountDeletion() async -> Bool {
        if case .submitting = accountDeletionRequestState { return false }
        guard let config, let session else {
            accountDeletionRequestState = .failed(
                .localized(L10nKey.commonAccountRequired)
            )
            return false
        }

        let context = requestAccountContext()
        accountDeletionRequestState = .submitting
        do {
            try await api.requestAccountDeletion(config: config, session: session)
            try requireCurrent(context)
            accountDeletionRequestState = .idle
            return true
        } catch is CancellationError {
            if isCurrent(context) { accountDeletionRequestState = .idle }
            return false
        } catch let error as NetworkClientError {
            guard isCurrent(context) else { return false }
            accountDeletionRequestState = .failed(error.userFacingMessage)
        } catch {
            guard isCurrent(context) else { return false }
            accountDeletionRequestState = .failed(
                .localized(L10nKey.commonOperationFailed)
            )
        }
        return false
    }

    func clearAccountDeletionRequestFeedback() {
        guard case .submitting = accountDeletionRequestState else {
            accountDeletionRequestState = .idle
            return
        }
    }

    @discardableResult
    func invalidateSessionAfterPasswordChange() async -> PasswordChangeSessionInvalidationOutcome {
        guard session != nil else { return .stale }
        let context = requestAccountContext()
        guard isCurrent(context) else { return .stale }
        cancelAuthenticatedRefreshes()

        let persistence = await sessions.invalidateAfterCredentialChange(
            ifCurrent: context.generation
        )
        guard case let .invalidated(storageCleared) = persistence,
              isCurrent(context) else {
            return .stale
        }

        await clearAuthenticatedState(discardCurrentAccountCache: true)
        if !storageCleared {
            SafeLog.warning(
                "[Login] password-change session cleanup incomplete "
                    + "restore_blocked=true cleanup_complete=false"
            )
        }
        return .invalidated(storageCleared: storageCleared)
    }

    func reportPasswordChangeVPNDisconnectFailure() {
        message = .localized("profile.change_password.vpn_disconnect_failed")
        userSystemLogger.log(
            .error,
            module: .proxy,
            key: UserLogKey.disconnectFailed
        )
    }

    func signOut() async {
        // Sign-out must invalidate an in-flight request even while its UI is busy.
        let context = requestAccountContext()
        cancelAuthenticatedRefreshes()
        do {
            guard try await sessions.clearForSignOut(ifCurrent: context.generation) else { return }
            guard isCurrent(context) else { return }
            await clearAuthenticatedState(discardCurrentAccountCache: true)
        } catch {
            guard isCurrent(context) else { return }
            message = (error as? NetworkClientError)?.userFacingMessage
                ?? .localized(L10nKey.commonOperationFailed)
        }
    }

    private func runAccountRefresh(
        context: AuthenticatedLoadContext,
        hadUsableValue: Bool
    ) async {
        do {
            let result = try await businessDataAPI.refreshHomeAccount(
                config: context.config,
                session: context.session
            )
            try Task.checkCancellation()
            guard isCurrent(context) else {
                SafeLog.info("[Bootstrap] discarded stale account result account_changed=true")
                return
            }
            guard try await sessions.save(result.session, ifCurrent: context.generation) else { return }
            try Task.checkCancellation()
            guard isCurrent(context) else { return }
            session = result.session
            accountRefreshedAt = Date()
            accountLoadState = .loaded
        } catch is CancellationError {
            return
        } catch let error as NetworkClientError {
            if case .authenticationExpired = error {
                await expireSessionIfCurrent(context)
                return
            }
            guard isCurrent(context) else { return }
            accountLoadState = failureState(error.userFacingMessage, retaining: hadUsableValue)
            SafeLog.warning(
                "[Bootstrap] account refresh failed category=\(error.logCategory) cached_data_retained=\(hadUsableValue)"
            )
        } catch {
            guard isCurrent(context) else { return }
            accountLoadState = failureState(
                .localized(L10nKey.errorServiceUnavailable),
                retaining: hadUsableValue
            )
            SafeLog.warning("[Bootstrap] account refresh failed category=unexpected")
        }
    }

    private func runPlansRefresh(
        context: AuthenticatedLoadContext,
        hadUsableValue: Bool
    ) async {
        do {
            let refreshedPlans = try await businessDataAPI.fetchPlans(
                config: context.config,
                session: context.session
            )
            try Task.checkCancellation()
            guard isCurrent(context) else {
                SafeLog.info("[Bootstrap] discarded stale plans result account_changed=true")
                return
            }
            plans = refreshedPlans
            let refreshedAt = Date()
            plansRefreshedAt = refreshedAt
            plansCache[context.accountScope] = CachedValue(
                value: refreshedPlans,
                refreshedAt: refreshedAt
            )
            plansLoadState = refreshedPlans.isEmpty ? .empty : .loaded
        } catch is CancellationError {
            return
        } catch let error as NetworkClientError {
            if case .authenticationExpired = error {
                await expireSessionIfCurrent(context)
                return
            }
            guard isCurrent(context) else { return }
            plansLoadState = failureState(error.userFacingMessage, retaining: hadUsableValue)
            SafeLog.warning(
                "[Bootstrap] plans refresh failed category=\(error.logCategory) cached_data_retained=\(hadUsableValue)"
            )
        } catch {
            guard isCurrent(context) else { return }
            plansLoadState = failureState(
                .localized(L10nKey.errorServiceUnavailable),
                retaining: hadUsableValue
            )
            SafeLog.warning("[Bootstrap] plans refresh failed category=unexpected")
        }
    }

    private func runNodesRefresh(
        context: AuthenticatedLoadContext,
        hadUsableValue: Bool,
        clearAllLatenciesOnSuccess: Bool
    ) async {
        let started = Date()
        #if DEBUG || ROUTE_VALIDATION
        SafeLog.info("[NodeTrace] event=catalog-fetch")
        #endif
        let previousSelection = nodes.selectedNodeID
        let previousRevision = selectedTunnelRevision
        let previousNodes = nodes.nodes
        let previousSubscription = await repository.parsedSubscription()
        do {
            #if DEBUG || ROUTE_VALIDATION
            SafeLog.info("[NodeTrace] event=subscription-prepare-start")
            #endif
            let prepared = try await repository.prepareRefresh(
                config: context.config,
                session: context.session
            )
            let refreshedNodes = prepared.snapshot
            let subscription = prepared.subscription
            #if DEBUG || ROUTE_VALIDATION
            SafeLog.info("[NodeTrace] event=subscription-prepared elapsedMs=\(Int(Date().timeIntervalSince(started) * 1_000)) count=\(refreshedNodes.nodes.count)")
            #endif
            try Task.checkCancellation()
            guard isCurrent(context) else {
                SafeLog.info("[Bootstrap] discarded stale nodes result account_changed=true")
                return
            }
            guard nodes.selectedNodeID == previousSelection,
                  selectedTunnelRevision == previousRevision else {
                throw CancellationError()
            }
            let revision = try SelectedNodeConfigurationIdentity.revision(
                in: subscription, nodeID: refreshedNodes.selectedNodeID
            )
            _ = try await repository.commitRefresh(prepared)
            #if DEBUG
            if let nodeRefreshDidCommitForTesting { await nodeRefreshDidCommitForTesting() }
            #endif
            // Publish only the account and selection that committed this catalog.
            guard canPublishNodeRefresh(
                prepared, context: context,
                previousSelection: previousSelection, previousRevision: previousRevision
            ) else { return }
            // No await is allowed between this final guard and these writes.
            nodes = refreshedNodes
            // Only a successfully committed subscription may clear readings.
            // Even an identical manual download invalidates the old test run.
            if clearAllLatenciesOnSuccess {
                invalidateNodeLatencies(reason: .manualRefresh)
            } else {
                reconcileNodeLatencies(
                    previousNodes: previousNodes, previousSubscription: previousSubscription,
                    refreshedNodes: refreshedNodes.nodes, refreshedSubscription: subscription
                )
            }
            selectedTunnelRevision = revision
            nodesRefreshedAt = Date()
            nodesLoadState = refreshedNodes.nodes.isEmpty ? .empty : .loaded
            #if DEBUG || ROUTE_VALIDATION
            SafeLog.info("[NodeTrace] event=catalog-done elapsedMs=\(Int(Date().timeIntervalSince(started) * 1_000)) count=\(refreshedNodes.nodes.count)")
            #endif
        } catch is CancellationError {
            #if DEBUG || ROUTE_VALIDATION
            SafeLog.info("[NodeTrace] event=catalog-cancel")
            #endif
            if isCurrent(context) {
                nodesLoadState = hadUsableValue ? .loaded : .idle
            }
            return
        } catch let error as NetworkClientError {
            if case .authenticationExpired = error {
                await expireSessionIfCurrent(context)
                return
            }
            guard isCurrent(context) else { return }
            nodesLoadState = failureState(error.userFacingMessage, retaining: hadUsableValue)
            SafeLog.warning(
                "[Bootstrap] nodes refresh failed category=\(error.logCategory) cached_data_retained=\(hadUsableValue)"
            )
        } catch let error as SubscriptionFetchError {
            guard isCurrent(context) else { return }
            nodesLoadState = failureState(
                .localized(error.userFacingKey),
                retaining: hadUsableValue
            )
            SafeLog.warning(
                "[Bootstrap] nodes refresh failed category=\(Self.subscriptionFetchCategory(error)) "
                    + "cached_data_retained=\(hadUsableValue)"
            )
        } catch let error as SubscriptionParserError {
            guard isCurrent(context) else { return }
            nodesLoadState = failureState(
                .localized(error.userFacingKey),
                retaining: hadUsableValue
            )
            SafeLog.warning(
                "[Bootstrap] nodes refresh failed category=\(Self.subscriptionParserCategory(error)) "
                    + "cached_data_retained=\(hadUsableValue)"
            )
        } catch {
            guard isCurrent(context) else { return }
            nodesLoadState = failureState(
                .localized("nodes.status.failed"),
                retaining: hadUsableValue
            )
            SafeLog.warning("[Bootstrap] nodes refresh failed category=unexpected")
        }
    }

    private func canPublishNodeRefresh(
        _ prepared: PreparedNodeRefresh, context: AuthenticatedLoadContext,
        previousSelection: String?, previousRevision: String?
    ) -> Bool {
        guard !Task.isCancelled, isCurrent(context),
              prepared.accountScope == context.session.nodeSelectionAccountScope,
              prepared.accountScope == session?.nodeSelectionAccountScope,
              nodes.selectedNodeID == previousSelection,
              selectedTunnelRevision == previousRevision else { return false }
        // Legacy single-step injected repositories have no transaction token.
        // A versioned repository must affirm the exact existing generation.
        guard prepared.generation != nil else { return true }
        return (repository as? any NodeRefreshPublicationChecking)?
            .isCurrentRefresh(prepared) == true
    }

    private func runNoticesRefresh(
        context: AuthenticatedLoadContext,
        hadUsableValue: Bool
    ) async {
        do {
            let refreshedNotices = try await businessDataAPI.fetchHomeNotices(
                config: context.config,
                session: context.session
            )
            try Task.checkCancellation()
            guard isCurrent(context) else {
                SafeLog.info("[Bootstrap] discarded stale notices result account_changed=true")
                return
            }
            notices = refreshedNotices
            noticesLoadRevision &+= 1
            let refreshedAt = Date()
            noticesRefreshedAt = refreshedAt
            noticesCache[context.accountScope] = CachedValue(
                value: refreshedNotices,
                refreshedAt: refreshedAt
            )
            noticesLoadState = refreshedNotices.isEmpty ? .empty : .loaded
        } catch is CancellationError {
            return
        } catch let error as NetworkClientError {
            if case .authenticationExpired = error {
                await expireSessionIfCurrent(context)
                return
            }
            guard isCurrent(context) else { return }
            noticesLoadState = failureState(error.userFacingMessage, retaining: hadUsableValue)
            SafeLog.warning(
                "[Bootstrap] notices refresh failed category=\(error.logCategory) cached_data_retained=\(hadUsableValue)"
            )
        } catch {
            guard isCurrent(context) else { return }
            noticesLoadState = failureState(
                .localized(L10nKey.errorServiceUnavailable),
                retaining: hadUsableValue
            )
            SafeLog.warning("[Bootstrap] notices refresh failed category=unexpected")
        }
    }

    private func authenticatedLoadContext() -> AuthenticatedLoadContext? {
        guard let config, let session, let activeAccountScope else { return nil }
        return AuthenticatedLoadContext(
            config: config,
            session: session,
            generation: authenticatedGeneration,
            accountScope: activeAccountScope
        )
    }

    private func isCurrent(_ context: AuthenticatedLoadContext) -> Bool {
        authenticatedGeneration == context.generation
            && activeAccountScope == context.accountScope
            && session?.authData == context.session.authData
    }

    private func shouldRefresh(
        force: Bool,
        lastSuccess: Date?,
        lastAttempt: Date?,
        interval: TimeInterval,
        now: Date = Date()
    ) -> Bool {
        if force { return true }
        if let lastSuccess, now.timeIntervalSince(lastSuccess) < interval { return false }
        if lastSuccess == nil,
           let lastAttempt,
           now.timeIntervalSince(lastAttempt) < BusinessRefreshPolicy.failedAttemptCooldown {
            return false
        }
        return true
    }

    private func failureState(
        _ message: LocalizedMessage,
        retaining cachedData: Bool
    ) -> BusinessDataLoadState {
        cachedData ? .stale(message) : .failed(message)
    }

    private func expireSessionIfCurrent(_ context: AuthenticatedLoadContext) async {
        guard isCurrent(context) else { return }
        guard let cleared = await invalidateAuthenticatedSession(ifCurrent: requestAccountContext()),
              isCurrent(cleared) else { return }
        authMessage = .localized(L10nKey.errorAuthenticationExpired)
    }

    private func invalidateAuthenticatedSession(ifCurrent context: RequestAccountContext) async -> RequestAccountContext? {
        guard isCurrent(context) else { return nil }
        cancelAuthenticatedRefreshes()
        guard (try? await sessions.clearForSignOut(ifCurrent: context.generation)) == true else {
            return nil
        }
        guard isCurrent(context) else { return nil }
        return await clearAuthenticatedState(discardCurrentAccountCache: true)
    }

    @discardableResult
    private func clearAuthenticatedState(discardCurrentAccountCache: Bool) async -> RequestAccountContext {
        nodeSession.cancelAll()
        invalidateNodeLatencies(reason: .sessionClear)
        let scope = activeAccountScope
        authenticatedGeneration = UUID()
        busy = false
        showsGlobalBusyIndicator = false
        message = nil
        activeAccountScope = nil
        session = nil
        nodes = .empty
        selectedTunnelRevision = nil
        plans = []
        orders = []
        ordersLoadState = .idle
        notices = []
        invitations = nil
        invitationsLoadState = .idle
        dailyTraffic = []
        trafficLoadState = .idle
        invitationActionInProgress = false
        invitationFeedback = nil
        checkout = nil
        paymentMethods = []
        paymentMethodsLoadState = .idle
        accountLoadState = .idle
        plansLoadState = .idle
        nodesLoadState = .idle
        noticesLoadState = .idle
        changePasswordState = .idle
        accountDeletionRequestState = .idle
        accountRefreshedAt = nil
        plansRefreshedAt = nil
        nodesRefreshedAt = nil
        noticesRefreshedAt = nil
        accountAttemptedAt = nil
        plansAttemptedAt = nil
        nodesAttemptedAt = nil
        noticesAttemptedAt = nil
        if discardCurrentAccountCache, let scope {
            plansCache.removeValue(forKey: scope)
            noticesCache.removeValue(forKey: scope)
        }
        let cleared = requestAccountContext()
        await repository.clear()
        return cleared
    }

    private func cancelAuthenticatedRefreshes() {
        accountRefreshTask?.cancel()
        plansRefreshTask?.cancel()
        nodeSession.cancelAll()
        noticesRefreshTask?.cancel()
        trafficRefreshTask?.task.cancel()
        accountRefreshTask = nil
        plansRefreshTask = nil
        noticesRefreshTask = nil
        trafficRefreshTask = nil
    }

    private static func accountScope(for session: UserSession) -> String {
        session.nodeSelectionAccountScope?.rawValue
            ?? NodeHash.sha256Hex(session.email.trimmed.lowercased())
    }

    private static func changePasswordValidationFailure(
        currentPassword: String,
        newPassword: String,
        confirmation: String
    ) -> String? {
        if currentPassword.isEmpty {
            return "profile.change_password.validation.current_required"
        }
        if newPassword.isEmpty {
            return "profile.change_password.validation.new_required"
        }
        if confirmation.isEmpty {
            return "profile.change_password.validation.confirm_required"
        }
        if newPassword.count < 8 {
            return "profile.change_password.validation.minimum_length"
        }
        if newPassword != confirmation {
            return "profile.change_password.validation.mismatch"
        }
        if newPassword == currentPassword {
            return "profile.change_password.validation.unchanged"
        }
        return nil
    }

    private static func changePasswordFailureLogLevel(
        _ error: NetworkClientError
    ) -> UserLogLevel {
        switch error {
        case .changePasswordRejected, .validation, .rateLimited:
            .warning
        default:
            .error
        }
    }

    private static func subscriptionFetchCategory(_ error: SubscriptionFetchError) -> String {
        switch error {
        case .missingSubscriptionURL: "missing_url"
        case .invalidSubscriptionURL: "invalid_url"
        case .invalidUserAgent: "invalid_user_agent"
        case .downloadFailed: "download_failed"
        case let .invalidHTTPResponse(statusCode): statusCode.map { "http_\($0)" } ?? "non_http"
        case .invalidEncoding: "invalid_encoding"
        }
    }

    private static func subscriptionParserCategory(_ error: SubscriptionParserError) -> String {
        switch error {
        case .invalidYAML: "invalid_yaml"
        case .invalidRootStructure: "invalid_root"
        case .noValidNodes: "empty_or_unsupported"
        case .identityFailure: "identity_failure"
        }
    }

    static func orderStatusKey(_ status: Int) -> String {
        switch status {
        case 0: "profile.orders.status.pending"
        case 1: "profile.orders.status.activating"
        case 2: "profile.orders.status.cancelled"
        case 3: "profile.orders.status.completed"
        case 4: "profile.orders.status.offset"
        default: "profile.orders.status.unknown"
        }
    }
}

#if DEBUG
enum TrafficInterfaceFixture {
    static let longListLaunchArgument = "--ui-traffic-long-list"
    static let longListCount = 40

    static func longList(
        arguments: [String],
        calendar suppliedCalendar: Calendar = .autoupdatingCurrent
    ) -> [ProfileDailyTraffic]? {
        guard arguments.contains(longListLaunchArgument) else { return nil }

        var calendar = suppliedCalendar
        calendar.timeZone = suppliedCalendar.timeZone
        guard let referenceDate = calendar.date(from: DateComponents(
            year: 2026,
            month: 10,
            day: 31
        )) else { return [] }

        return (0..<longListCount).compactMap { index in
            guard let date = calendar.date(byAdding: .day, value: -index, to: referenceDate) else {
                return nil
            }
            let traffic = bytes(for: index)
            return ProfileDailyTraffic(
                recordAtUnix: Int64(calendar.startOfDay(for: date).timeIntervalSince1970),
                uploadBytes: traffic.upload,
                downloadBytes: traffic.download
            )
        }
    }

    private static func bytes(for index: Int) -> (upload: Int64, download: Int64) {
        switch index % 4 {
        case 0:
            return (1_258_291 + Int64(index), 3_565_158 + Int64(index))
        case 1:
            return (12 * 1_048_576 + Int64(index), 25 * 1_048_576 + Int64(index))
        case 2:
            return (300 * 1_024 + Int64(index), 1_181_116_006 + Int64(index))
        default:
            return (1_099_511_627_776 + Int64(index), 549_755_813_888 + Int64(index))
        }
    }
}

extension AppModel {
    private struct InterfaceFixture: Decodable {
        struct Plan: Decodable { struct Cycle: Decodable { let period: String; let price: Int64 }; let id: Int; let name: String; let features: [String]; let cycles: [Cycle] }
        let account: UserSession
        let plans: [Plan]
        let notice: HomeNoticeFixture
    }
    private struct HomeNoticeFixture: Decodable { let id: Int; let title: String; let content: String; let imageURL: String?; let tags: [String]; let createdAt: Int64 }
    fileprivate func loadInterfaceFixture() {
        guard offline, ProcessInfo.processInfo.arguments.contains("--ui-sample") else { return }
        do {
            let fixture: InterfaceFixture = try Installation.decode("UIFixtureResource")
            session = fixture.account
            plans = fixture.plans.map { item in
                PurchasePlan(id: item.id, name: item.name, content: "", sort: 0, cycles: item.cycles.compactMap { cycle in PurchasePlanPeriod(rawValue: cycle.period).map { PurchasePlanCycle(period: $0, priceCents: cycle.price) } }, features: item.features.map { PurchasePlanFeature(text: $0, isSupported: true) })
            }
            let notice = fixture.notice
            notices = [HomeNotice(id: notice.id, title: notice.title, content: notice.content, imageURL: notice.imageURL, tags: notice.tags, createdAt: notice.createdAt)]
            let arguments = ProcessInfo.processInfo.arguments
            if let longList = TrafficInterfaceFixture.longList(arguments: arguments) {
                dailyTraffic = longList
            } else {
                let calendar = Calendar.autoupdatingCurrent
                let today = calendar.startOfDay(for: Date())
                let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
                dailyTraffic = [
                    ProfileDailyTraffic(
                        recordAtUnix: Int64(today.timeIntervalSince1970),
                        uploadBytes: 548_731,
                        downloadBytes: 5_075_845
                    ),
                    ProfileDailyTraffic(
                        recordAtUnix: Int64(yesterday.timeIntervalSince1970),
                        uploadBytes: 806_218_301,
                        downloadBytes: 3_768_096_154
                    ),
                ]
            }
            trafficLoadState = .loaded
            if arguments.contains("--ui-node-initial-loading") {
                nodes = .empty
                nodesLoadState = .loading
            } else if arguments.contains("--ui-node-sample") {
                let sampleNodes = [
                    ProxyNode(id: "ui-node-tw", fingerprint: "fixture-tw", originalName: "Taiwan sample",
                              displayName: "Taiwan sample", coreName: "Taiwan sample", protocolType: "ss",
                              server: "example.invalid", port: 443, countryCode: "TW", available: true),
                    ProxyNode(id: "ui-node-jp", fingerprint: "fixture-jp", originalName: "Japan sample",
                              displayName: "Japan sample", coreName: "Japan sample", protocolType: "ss",
                              server: "example.invalid", port: 443, countryCode: "JP", available: true)
                ]
                nodes = NodeRepositorySnapshot(nodes: sampleNodes, selectedNodeID: sampleNodes[0].id)
                nodesLoadState = arguments.contains("--ui-node-refreshing") ? .loading : .loaded
                if let reading = NodeLatencyReading(actualMilliseconds: 42, displayRatio: 1) {
                    nodeLatencies = Dictionary(uniqueKeysWithValues: sampleNodes.map { ($0.id, .measured(reading)) })
                }
                if arguments.contains("--ui-node-testing-all") {
                    testingAllNodes = true
                    testingNodeIDs = Set(sampleNodes.map(\.id))
                    nodeLatencyProgress = NodeLatencyProgress(completed: 0, total: sampleNodes.count)
                }
            } else if arguments.contains("--ui-node-failure") {
                nodes = .empty
                nodesLoadState = .failed(.localized("nodes.status.failed"))
            }
        } catch { message = .localized(L10nKey.offlineFixtureFailed) }
    }
}
#endif

#if ROUTE_VALIDATION
private enum RouteValidationNodeLatencyEvidence {
    static func write(stage: String, category: String = "none", delayMS: Int? = nil) {
        guard let group = try? MihomoTunnelStore.appGroup(),
              let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: group
              ) else { return }
        let directory = container.appendingPathComponent("Library/Caches", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var record: [String: Any] = [
            "stage": stage, "category": category,
            "recordedAt": Date().timeIntervalSince1970,
        ]
        if let delayMS { record["delayMS"] = delayMS }
        guard let data = try? JSONSerialization.data(withJSONObject: record) else { return }
        try? data.write(to: directory.appendingPathComponent("node-latency-evidence.json"),
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
#endif
