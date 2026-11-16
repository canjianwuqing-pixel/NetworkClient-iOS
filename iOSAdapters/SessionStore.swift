import Foundation
import Security

enum SessionCredentialInvalidationResult: Equatable, Sendable {
    case invalidated(storageCleared: Bool)
    case stale
}

actor SessionStore {
    #if NETWORKCLIENT_VPN_TEST
    // VPNTest derives its service from its Bundle ID instead of using the fixed
    // Production namespace, so it never reads the formal App's session.
    static let currentKeychainService = (Bundle.main.bundleIdentifier ?? "NetworkClientVPNTest") + ".auth-session.v1"
    #else
    static let currentKeychainService = "com.networkclient.ios.auth-session.v1"
    #endif

    private static let autoLoginEnabledKey = "login.autoLoginEnabled"
    private static let rememberedEmailKey = "login.rememberedEmail"

    private let account = "v2board.authenticated-session"
    private let keychain: any SessionKeychainAccess
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var disabledSessionCleared = false
    /// The AppModel generation that currently owns persisted-session
    /// mutations in this process. The actor is the compare-and-swap boundary:
    /// a stale save or clear can never race a newer authenticated generation.
    private var currentGeneration: UUID?

    private var signedOutMarkerKey: String {
        "\(Self.currentKeychainService).session.explicitly-signed-out"
    }

    init() {
        keychain = SystemSessionKeychainAccess()
        defaults = .standard
    }

    init(keychain: any SessionKeychainAccess, defaultsSuiteName: String) {
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            preconditionFailure("Unable to create isolated session preferences")
        }
        self.keychain = keychain
        self.defaults = defaults
    }

    nonisolated static func autoLoginEnabledSnapshot() -> Bool {
        autoLoginEnabledSnapshot(defaults: .standard)
    }

    private static func autoLoginEnabledSnapshot(defaults: UserDefaults) -> Bool {
        if let enabled = defaults.object(forKey: autoLoginEnabledKey) as? Bool {
            return enabled
        }
        let rememberedEmail = defaults.string(forKey: rememberedEmailKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let enabled = !rememberedEmail.isEmpty
        defaults.set(enabled, forKey: autoLoginEnabledKey)
        return enabled
    }

    func autoLoginEnabled() -> Bool {
        if defaults.object(forKey: Self.autoLoginEnabledKey) == nil,
           hasPersistedSessionEvidence() {
            defaults.set(true, forKey: Self.autoLoginEnabledKey)
            disabledSessionCleared = false
            SafeLog.info("[Login] auto-login preference migrated source=existing_session")
            return true
        }

        let enabled = Self.autoLoginEnabledSnapshot(defaults: defaults)
        if !enabled {
            clearDisabledSessionIfNeeded()
        }
        return enabled
    }

    func setAutoLoginEnabled(_ enabled: Bool) throws {
        if enabled {
            if !autoLoginEnabled() {
                try clear()
            }
            defaults.set(true, forKey: Self.autoLoginEnabledKey)
            disabledSessionCleared = false
        } else {
            defaults.set(false, forKey: Self.autoLoginEnabledKey)
            defaults.removeObject(forKey: Self.rememberedEmailKey)
            disabledSessionCleared = false
            try clear()
            disabledSessionCleared = true
        }
    }

    /// Atomically replaces the persisted session for a newly accepted
    /// authenticated generation. `replacing` is the generation observed when
    /// the authentication operation began; a newer owner wins.
    @discardableResult
    func replace(
        _ session: UserSession,
        generation: UUID,
        replacing expectedGeneration: UUID?
    ) throws -> Bool {
        guard currentGeneration == expectedGeneration || currentGeneration == generation else {
            SafeLog.info("[Login] stale session replacement discarded")
            return false
        }

        guard autoLoginEnabled() else {
            SafeLog.info("[Login] session persistence skipped reason=auto_login_disabled")
            currentGeneration = generation
            return true
        }

        try persistSessionData(encoder.encode(session))
        clearSignedOutMarkers()
        currentGeneration = generation
        return true
    }

    /// Claims an already-persisted session for AppModel's current generation.
    /// This does not rewrite Keychain data.
    @discardableResult
    func adopt(generation: UUID, replacing expectedGeneration: UUID?) -> Bool {
        guard currentGeneration == expectedGeneration || currentGeneration == generation else {
            SafeLog.info("[Login] stale session adoption discarded")
            return false
        }
        currentGeneration = generation
        return true
    }

    /// A restored session belongs to a new AppModel process lifetime. There
    /// are no surviving operations from the previous process, so it can claim
    /// the in-memory persistence owner without rewriting the stored session.
    func adoptRestoredSession(generation: UUID) {
        currentGeneration = generation
    }

    /// Updates metadata for the generation that originally issued the
    /// request. The ownership check and Keychain mutation are actor-atomic.
    @discardableResult
    func save(_ session: UserSession, ifCurrent generation: UUID) throws -> Bool {
        guard currentGeneration == generation else {
            SafeLog.info("[Login] stale session save discarded")
            return false
        }
        guard autoLoginEnabled() else {
            // autoLoginEnabled() may clear disabled persistence. The live
            // session still owns later conditional mutations in this process.
            currentGeneration = generation
            SafeLog.info("[Login] session persistence skipped reason=auto_login_disabled")
            return true
        }

        try persistSessionData(encoder.encode(session))
        clearSignedOutMarkers()
        return true
    }

    private func persistSessionData(_ data: Data) throws {
        let updateStatus = keychain.update(
            data,
            service: Self.currentKeychainService,
            account: account
        )
        if updateStatus == errSecSuccess {
            SafeLog.info("[Login] session persisted operation=replace authorization_present=true")
            return
        }
        guard updateStatus == errSecItemNotFound else {
            SafeLog.warning("[Login] session persistence failed operation=update status=\(updateStatus)")
            throw NetworkClientError.secureStorage("无法保存登录状态，请稍后重试")
        }

        let addStatus = keychain.add(
            data,
            service: Self.currentKeychainService,
            account: account
        )
        guard addStatus == errSecSuccess else {
            SafeLog.warning("[Login] session persistence failed operation=add status=\(addStatus)")
            throw NetworkClientError.secureStorage("无法保存登录状态，请稍后重试")
        }
        SafeLog.info("[Login] session persisted operation=create authorization_present=true")
    }

    func read() throws -> UserSession? {
        guard autoLoginEnabled() else {
            SafeLog.info("[Login] saved session ignored reason=auto_login_disabled")
            return nil
        }

        if defaults.bool(forKey: signedOutMarkerKey) {
            SafeLog.info("[Login] saved session ignored reason=explicit_sign_out")
            return nil
        }

        let current = keychain.read(service: Self.currentKeychainService, account: account)
        if current.status == errSecItemNotFound {
            return nil
        }
        return try decodedSession(from: current, source: "current")
    }

    private func decodedSession(
        from result: SessionKeychainReadResult,
        source: String
    ) throws -> UserSession? {
        guard result.status == errSecSuccess else {
            let reason: String
            switch result.status {
            case errSecItemNotFound: reason = "item_not_found"
            case errSecAuthFailed: reason = "auth_failed"
            case errSecInteractionNotAllowed: reason = "interaction_not_allowed"
            case errSecUserCanceled: reason = "user_cancelled"
            default: reason = "keychain_error"
            }
            SafeLog.warning(
                "[Login] session read failed source=\(source) reason=\(reason) status=\(result.status)"
            )
            throw NetworkClientError.secureStorage("无法读取登录状态，请稍后重试")
        }
        guard let data = result.data else {
            SafeLog.warning("[Login] session read failed source=\(source) reason=missing_data")
            throw NetworkClientError.secureStorage("无法读取登录状态，请稍后重试")
        }
        if data.isEmpty {
            SafeLog.info("[Login] saved session ignored reason=invalidated")
            return nil
        }
        do {
            return try decoder.decode(UserSession.self, from: data)
        } catch {
            SafeLog.warning("[Login] session read failed source=\(source) reason=decode_failed")
            throw NetworkClientError.secureStorage("无法读取登录状态，请稍后重试")
        }
    }

    @discardableResult
    func clearForSignOut(ifCurrent generation: UUID) throws -> Bool {
        guard currentGeneration == generation else {
            SafeLog.info("[Login] stale session clear discarded")
            return false
        }
        setSignedOutMarkers()
        try clear()
        return true
    }

    /// Password changes revoke every server-side session. Unlike ordinary
    /// sign-out, the live UI must become unauthenticated even if Keychain
    /// cleanup fails. The marker prevents a retained item from being restored
    /// after relaunch; releasing the owner allows a new login to persist.
    func invalidateAfterCredentialChange(
        ifCurrent generation: UUID
    ) -> SessionCredentialInvalidationResult {
        guard currentGeneration == generation else {
            SafeLog.info("[Login] stale credential invalidation discarded")
            return .stale
        }

        setSignedOutMarkers()
        let currentCleared = clearSessionItem(
            service: Self.currentKeychainService,
            source: "current"
        )
        let storageCleared = currentCleared
        if storageCleared {
            clearSignedOutMarkers()
        }
        currentGeneration = nil
        return .invalidated(storageCleared: storageCleared)
    }

    func clear() throws {
        let currentCleared = clearSessionItem(service: Self.currentKeychainService, source: "current")
        guard currentCleared else {
            setSignedOutMarkers()
            throw NetworkClientError.secureStorage("无法清理登录状态，请稍后重试")
        }
        clearSignedOutMarkers()
        currentGeneration = nil
    }

    private func clearSessionItem(service: String, source: String) -> Bool {
        let status = keychain.delete(service: service, account: account)
        if status == errSecSuccess || status == errSecItemNotFound {
            SafeLog.info("[Login] session cleared source=\(source)")
            return true
        }

        if status == errSecInvalidOwnerEdit {
            let invalidateStatus = keychain.invalidate(service: service, account: account)
            if invalidateStatus == errSecSuccess || invalidateStatus == errSecItemNotFound {
                SafeLog.info("[Login] session invalidated reason=keychain_owner_mismatch")
                return true
            }
            SafeLog.warning(
                "[Login] session invalidation failed delete_status=\(status) "
                    + "update_status=\(invalidateStatus)"
            )
            return false
        }

        SafeLog.warning("[Login] session clear failed source=\(source) status=\(status)")
        return false
    }

    private func setSignedOutMarkers() {
        defaults.set(true, forKey: signedOutMarkerKey)
    }

    private func clearSignedOutMarkers() {
        defaults.removeObject(forKey: signedOutMarkerKey)
    }

    private func clearDisabledSessionIfNeeded() {
        guard !disabledSessionCleared else { return }
        do {
            try clear()
            disabledSessionCleared = true
        } catch {
            SafeLog.warning("[Login] disabled session cleanup deferred")
        }
    }

    private func hasPersistedSessionEvidence() -> Bool {
        let result = keychain.read(service: Self.currentKeychainService, account: account)
        switch result.status {
        case errSecSuccess:
            return result.data?.isEmpty == false
        case errSecItemNotFound:
            return false
        default:
            // A read failure is not evidence that the user disabled automatic login.
            // Preserve the item and let the normal read path surface the storage error.
            SafeLog.warning(
                "[Login] auto-login preference migration deferred status=\(result.status)"
            )
            return true
        }
    }
}

struct SessionKeychainReadResult: Sendable {
    let status: OSStatus
    let data: Data?
}

protocol SessionKeychainAccess: Sendable {
    func read(service: String, account: String) -> SessionKeychainReadResult
    func update(_ data: Data, service: String, account: String) -> OSStatus
    func add(_ data: Data, service: String, account: String) -> OSStatus
    func delete(service: String, account: String) -> OSStatus
    func invalidate(service: String, account: String) -> OSStatus
}

private struct SystemSessionKeychainAccess: SessionKeychainAccess {
    func read(service: String, account: String) -> SessionKeychainReadResult {
        var query = query(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return SessionKeychainReadResult(status: status, data: item as? Data)
    }

    func update(_ data: Data, service: String, account: String) -> OSStatus {
        SecItemUpdate(
            query(service: service, account: account) as CFDictionary,
            attributes(data: data) as CFDictionary
        )
    }

    func add(_ data: Data, service: String, account: String) -> OSStatus {
        var query = query(service: service, account: account)
        attributes(data: data).forEach { query[$0.key] = $0.value }
        return SecItemAdd(query as CFDictionary, nil)
    }

    func delete(service: String, account: String) -> OSStatus {
        SecItemDelete(query(service: service, account: account) as CFDictionary)
    }

    func invalidate(service: String, account: String) -> OSStatus {
        SecItemUpdate(
            query(service: service, account: account) as CFDictionary,
            [kSecValueData as String: Data()] as CFDictionary
        )
    }

    private func query(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func attributes(data: Data) -> [String: Any] {
        [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
    }
}
