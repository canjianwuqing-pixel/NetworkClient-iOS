import CoreFoundation
import Darwin
import Foundation
import NetworkExtension

private struct LoadedTunnelPreferences: @unchecked Sendable {
    let managers: [NETunnelProviderManager]
}

/// Direct NE preference/session operations; no historical state or restore policy.
@MainActor
enum NETunnelProviderAccess {
    static let preferenceVersionKey = "cleanRoomPreferenceVersion"
    static let cleanRoomPreferenceVersion = 1
    struct Summary {
        let version: Int?
        let isEnabled: Bool
        let isOnDemandEnabled: Bool
        let onDemandRuleCount: Int
        let allowedKeysOnly: Bool
    }

    struct Preference {
        let providerBundleIdentifier: String?
        let cleanRoomPreferenceVersion: Int?
        let isEnabled: Bool
        let status: @MainActor () -> NEVPNStatus
        let configure: @MainActor (String, String) -> Void
        let save: @MainActor () async throws -> Void
        let reload: @MainActor () async throws -> Void
        let remove: @MainActor () async throws -> Void
        let start: @MainActor ([String: NSObject]) throws -> Void
        let stop: @MainActor () -> Void
        let observe: @MainActor (@escaping @MainActor () -> Void) -> (@MainActor () -> Void)
        let lastDisconnectError: @MainActor () async -> VPNLastDisconnectError?
        var send: @MainActor (Data) async throws -> Data? = { _ in nil }
        var summary: (@MainActor () -> Summary)? = nil
    }

    struct Backend {
        let loadAll: @MainActor () async throws -> [Preference]
        let make: @MainActor () -> Preference
        static var live: Self {
            .init(loadAll: { try await NETunnelProviderAccess.loadAll().map(NETunnelProviderAccess.wrap) },
                  make: { NETunnelProviderAccess.wrap(NETunnelProviderManager()) })
        }
    }

    static func loadCurrent(
        providerBundleIdentifier: String,
        backend: Backend = .live,
        isCurrent: @MainActor () -> Bool = { true }
    ) async throws -> Preference? {
        let all = try await backend.loadAll()
        guard isCurrent() else { throw CancellationError() }
        let matching = all.filter { $0.providerBundleIdentifier == providerBundleIdentifier }
        let clean = matching.filter { $0.cleanRoomPreferenceVersion == cleanRoomPreferenceVersion }
        let selectedIndex = preferredIndex(in: clean)
        return selectedIndex.map { clean[$0] }
    }

    static func prepareCurrent(
        providerBundleIdentifier: String,
        backend: Backend = .live,
        isCurrent: @MainActor () -> Bool = { true }
    ) async throws -> Preference {
        let all = try await backend.loadAll()
        guard isCurrent() else { throw CancellationError() }
        let matching = all.filter { $0.providerBundleIdentifier == providerBundleIdentifier }
        let old = matching.filter { $0.cleanRoomPreferenceVersion != cleanRoomPreferenceVersion }
        let clean = matching.filter { $0.cleanRoomPreferenceVersion == cleanRoomPreferenceVersion }
        for preference in old {
            guard isCurrent() else { throw CancellationError() }
            try await preference.remove()
            guard isCurrent() else { throw CancellationError() }
        }
        let selectedIndex = preferredIndex(in: clean)
        for index in clean.indices where index != selectedIndex {
            guard isCurrent() else { throw CancellationError() }
            try await clean[index].remove()
            guard isCurrent() else { throw CancellationError() }
        }
        SafeLog.info("[VPN] preference inventory oldRemoved=\(old.count) duplicateRemoved=\(max(0, clean.count - 1)) loadedForeignCount=\(all.count - matching.count)")
        guard let selectedIndex else { return backend.make() }
        return clean[selectedIndex]
    }

    private static func preferredIndex(in preferences: [Preference]) -> Int? {
        preferences.firstIndex {
            [.connected, .connecting, .reasserting, .disconnecting].contains($0.status())
        } ?? preferences.firstIndex { $0.isEnabled } ?? preferences.indices.first
    }

    static func preferenceVersion(of manager: NETunnelProviderManager) -> Int? {
        guard let tunnel = manager.protocolConfiguration as? NETunnelProviderProtocol,
              let number = tunnel.providerConfiguration?[preferenceVersionKey] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)),
              number == NSNumber(value: cleanRoomPreferenceVersion) else { return nil }
        return cleanRoomPreferenceVersion
    }

    static func configure(
        _ manager: NETunnelProviderManager,
        providerBundleIdentifier: String,
        serverAddress: String
    ) {
        let tunnel = NETunnelProviderProtocol()
        tunnel.providerBundleIdentifier = providerBundleIdentifier
        tunnel.serverAddress = serverAddress
        tunnel.providerConfiguration = [preferenceVersionKey: cleanRoomPreferenceVersion]
        tunnel.includeAllNetworks = false
        manager.protocolConfiguration = tunnel
        manager.localizedDescription = "VPN"
        manager.isEnabled = true
        manager.isOnDemandEnabled = false
        manager.onDemandRules = nil
    }

    static func logSummary(of preference: Preference) {
        guard let summary = preference.summary?() else { return }
        SafeLog.info("[VPN] preference ready version=\(summary.version ?? -1) enabled=\(summary.isEnabled) onDemand=\(summary.isOnDemandEnabled) ruleCount=\(summary.onDemandRuleCount) allowedKeysOnly=\(summary.allowedKeysOnly)")
    }

    static func loadAll() async throws -> [NETunnelProviderManager] {
        let loaded: LoadedTunnelPreferences = try await withCheckedThrowingContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: .init(managers: managers ?? [])) }
            }
        }
        return loaded.managers
    }

    static func lastDisconnectError(for connection: NEVPNConnection) async -> VPNLastDisconnectError? {
        await withCheckedContinuation { continuation in
            connection.fetchLastDisconnectError { error in
                continuation.resume(returning: error.map(VPNLastDisconnectError.init))
            }
        }
    }

    private static func wrap(_ manager: NETunnelProviderManager) -> Preference {
        let preference = Preference(providerBundleIdentifier: (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier,
              cleanRoomPreferenceVersion: preferenceVersion(of: manager),
              isEnabled: manager.isEnabled, status: { manager.connection.status }, configure: { identifier, server in
            configure(manager, providerBundleIdentifier: identifier, serverAddress: server)
        }, save: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                manager.saveToPreferences { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        }, reload: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                manager.loadFromPreferences { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        }, remove: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                manager.removeFromPreferences { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        }, start: { options in
            guard manager.connection is NETunnelProviderSession else {
                throw TunnelDiagnostic(code: .signatureNotVerified, message: "VPN session unavailable")
            }
            try manager.connection.startVPNTunnel(options: options)
        }, stop: { (manager.connection as? NETunnelProviderSession)?.stopVPNTunnel() }, observe: { callback in
            let observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange,
                object: manager.connection, queue: .main) { _ in Task { @MainActor in callback() } }
            return { NotificationCenter.default.removeObserver(observer) }
        }, lastDisconnectError: { await NETunnelProviderAccess.lastDisconnectError(for: manager.connection) }, send: { data in
            guard let session = manager.connection as? NETunnelProviderSession else {
                throw TunnelDiagnostic(code: .signatureNotVerified, message: "VPN session unavailable")
            }
            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data?, Error>) in
                do {
                    try session.sendProviderMessage(data) { response in
                        continuation.resume(returning: response)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }, summary: {
            let keys = (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?.keys
            return Summary(version: preferenceVersion(of: manager), isEnabled: manager.isEnabled,
                isOnDemandEnabled: manager.isOnDemandEnabled, onDemandRuleCount: manager.onDemandRules?.count ?? 0,
                allowedKeysOnly: keys.map { Set($0) == [preferenceVersionKey] } ?? false)
        })
        return preference
    }
}

/// Only finite categories and the numeric public error code leave the NE
/// callback. Error descriptions, userInfo and underlying errors are ignored.
struct VPNLastDisconnectError: Equatable, Sendable {
    enum Domain: String, Sendable { case networkExtension = "network-extension", vpn, posix, cocoa, provider, system, unknown }
    enum Category: String, Sendable { case provider, configuration, permission, system, networkExtension = "network-extension", cancelled, timeout, unknown }

    let domain: Domain
    let code: Int
    let category: Category

    var connectionError: String? {
        domain == .networkExtension && code == NEVPNConnectionError.pluginFailed.rawValue ? "plugin-failed" : nil
    }

    init(_ error: Error) {
        let value = error as NSError
        code = value.code
        switch value.domain {
        case NEVPNConnectionErrorDomain:
            domain = .networkExtension
            switch value.code {
            case 12: category = .provider
            case 4, 13, 14: category = .configuration
            case 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 15, 16, 17, 18, 19: category = .networkExtension
            default: category = .unknown
            }
        case NEVPNErrorDomain:
            domain = .vpn
            category = [1, 2, 4, 5, 6].contains(value.code) ? .configuration : .unknown
        case NSPOSIXErrorDomain:
            domain = .posix
            switch value.code {
            case Int(EACCES), Int(EPERM): category = .permission
            case Int(ECANCELED): category = .cancelled
            case Int(ETIMEDOUT): category = .timeout
            default: category = .system
            }
        case NSCocoaErrorDomain:
            domain = .cocoa
            category = [CocoaError.fileReadNoPermission.rawValue, CocoaError.fileWriteNoPermission.rawValue].contains(value.code)
                ? .permission : .unknown
        case NSURLErrorDomain:
            domain = .system
            switch value.code {
            case URLError.cancelled.rawValue: category = .cancelled
            case URLError.timedOut.rawValue: category = .timeout
            default: category = .unknown
            }
        case "NetworkClientVPNTest.TunnelStart":
            domain = .provider
            category = value.code == 16 ? .cancelled : .provider
        default:
            domain = .unknown
            category = .unknown
        }
    }
}
