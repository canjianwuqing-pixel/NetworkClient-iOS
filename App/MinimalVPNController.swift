import Combine
import Foundation
import NetworkExtension

/// The system connection is authoritative; the token only ignores stale awaits.
@MainActor
final class MinimalVPNController: ObservableObject {
    enum State: Equatable, Sendable { case disconnected, connecting, connected }
    enum Operation: Equatable, Sendable { case idle, connecting, disconnecting }
    enum Failure: Swift.Error, Equatable {
        case configuration, preferences, start
        case connection(VPNLastDisconnectError)
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var lastError: Failure?
    @Published private(set) var operation: Operation = .idle
    @Published private(set) var uploadBytesPerSecond: Int64 = 0
    @Published private(set) var downloadBytesPerSecond: Int64 = 0
    private let providerBundleIdentifier: String?
    private let backend: NETunnelProviderAccess.Backend
    private let saveConfiguration: @MainActor (MihomoTunnelConfiguration) throws -> Void
    private let removeConfiguration: @MainActor (UUID) throws -> Void
    private let prepareRecoveryForFormalVPN: @MainActor () async throws -> Void
    private let setRecoveryAllowedForFormalVPN: @MainActor (Bool) async -> Void
    private var preference: NETunnelProviderAccess.Preference?
    private var stopObserving: (@MainActor () -> Void)?
    private var sessionToken = UUID()
    private var lastObservedSystemStatus: NEVPNStatus?
    private(set) var activeCandidatePoolRevision: String?
    private(set) var trafficObservationID: UUID?
    private var trafficTask: Task<Void, Never>?

    init(providerBundleIdentifier: String? = Bundle.main.object(forInfoDictionaryKey: "TunnelExtensionBundleID") as? String,
         backend: NETunnelProviderAccess.Backend = .live,
         saveConfiguration: @escaping @MainActor (MihomoTunnelConfiguration) throws -> Void = { try MihomoTunnelStore.save($0) },
         removeConfiguration: @escaping @MainActor (UUID) throws -> Void = { try MihomoTunnelStore.remove(expectedGeneration: $0) },
         prepareRecoveryForFormalVPN: @escaping @MainActor () async throws -> Void = {},
         setRecoveryAllowedForFormalVPN: @escaping @MainActor (Bool) async -> Void = { _ in }) {
        self.providerBundleIdentifier = providerBundleIdentifier
        self.backend = backend
        self.saveConfiguration = saveConfiguration
        self.removeConfiguration = removeConfiguration
        self.prepareRecoveryForFormalVPN = prepareRecoveryForFormalVPN
        self.setRecoveryAllowedForFormalVPN = setRecoveryAllowedForFormalVPN
    }

    nonisolated static func state(for status: NEVPNStatus) -> State {
        switch status {
        case .disconnected, .invalid: .disconnected
        case .connecting, .reasserting, .disconnecting: .connecting
        case .connected: .connected
        @unknown default: .disconnected
        }
    }

    func connect(prepare: @escaping @MainActor () async throws -> MihomoTunnelConfiguration) async throws {
        guard operation == .idle, state == .disconnected else { return }
        let token = UUID()
        sessionToken = token
        stopObserving?(); stopObserving = nil
        stopTrafficObservation()
        activeCandidatePoolRevision = nil
        operation = .connecting
        state = .connecting
        lastError = nil
        SafeLog.info("[VPN] vpn connect requested")
        var failure = Failure.configuration
        var saved: UUID?
        var started = false
        var preflightCompleted = false
        defer { if !started, let saved { try? removeConfiguration(saved) } }
        do {
            try await prepareRecoveryForFormalVPN()
            guard sessionToken == token else {
                await restoreRecoveryAfterAbandonedConnectIfSafe()
                return
            }
            try Task.checkCancellation()
            let configuration = try await prepare()
            preflightCompleted = true
            guard sessionToken == token else {
                await restoreRecoveryAfterAbandonedConnectIfSafe()
                return
            }
            try Task.checkCancellation()
            try saveConfiguration(configuration)
            saved = configuration.generation
            failure = .preferences
            guard let identifier = providerBundleIdentifier, !identifier.isEmpty else { throw failure }
            let loaded = try await NETunnelProviderAccess.prepareCurrent(
                providerBundleIdentifier: identifier, backend: backend,
                isCurrent: { self.sessionToken == token && !Task.isCancelled }
            )
            guard sessionToken == token else { return }
            preference = loaded
            if [.connected, .connecting, .reasserting, .disconnecting].contains(loaded.status()) {
                bind(loaded, token: token)
                receiveStatus(from: loaded, token: token)
                return
            }
            loaded.configure(identifier, configuration.serverIPv4)
            try await loaded.save()
            guard sessionToken == token else { return }
            try await loaded.reload()
            guard sessionToken == token else { return }
            try Task.checkCancellation()
            NETunnelProviderAccess.logSummary(of: loaded)
            failure = .start
            bind(loaded, token: token)
            try loaded.start(["configurationGeneration": configuration.generation.uuidString as NSString])
            started = true
            activeCandidatePoolRevision = configuration.candidatePoolRevision
            // The request can return before NE emits its first transition.
            // A local successful start call never establishes connected.
            if loaded.status() != .disconnected && loaded.status() != .invalid {
                receiveStatus(from: loaded, token: token)
            }
        } catch {
            guard sessionToken == token else {
                await restoreRecoveryAfterAbandonedConnectIfSafe()
                return
            }
            activeCandidatePoolRevision = nil
            operation = .idle
            let status = preference?.status() ?? lastObservedSystemStatus
            if let status { lastObservedSystemStatus = status }
            state = Self.state(for: status ?? .invalid)
            await synchronizeRecoveryGate(for: status, token: token)
            if error is CancellationError { throw CancellationError() }
            lastError = failure
            if !preflightCompleted { throw error }
            throw failure
        }
    }

    func disconnect() async throws {
        guard operation != .disconnecting, state != .disconnected else { return }
        let token = UUID()
        sessionToken = token
        operation = .disconnecting
        lastError = nil
        if let preference {
            bind(preference, token: token)
            preference.stop()
            receiveStatus(from: preference, token: token)
        } else {
            // Preparation has not obtained any NE session to stop.
            state = Self.state(for: .invalid)
            operation = .idle
            activeCandidatePoolRevision = nil
            stopTrafficObservation()
        }
    }

    func refreshSystemStatus() async throws {
        guard operation == .idle else { return }
        let token = UUID()
        sessionToken = token
        operation = .connecting
        defer { if sessionToken == token, operation == .connecting { operation = .idle } }
        do {
            guard let identifier = providerBundleIdentifier, !identifier.isEmpty else { throw Failure.preferences }
            let loaded = try await NETunnelProviderAccess.loadCurrent(
                providerBundleIdentifier: identifier, backend: backend,
                isCurrent: { self.sessionToken == token && !Task.isCancelled }
            )
            guard sessionToken == token else { return }
            stopObserving?(); stopObserving = nil
            guard let loaded else {
                preference = nil
                lastObservedSystemStatus = nil
                state = .disconnected
                lastError = nil
                activeCandidatePoolRevision = nil
                stopTrafficObservation()
                await synchronizeRecoveryGate(for: nil, token: token)
                return
            }
            try Task.checkCancellation()
            preference = loaded
            bind(loaded, token: token)
            receiveStatus(from: loaded, token: token)
            await synchronizeRecoveryGate(for: loaded.status(), token: token)
        } catch {
            guard sessionToken == token else { return }
            lastObservedSystemStatus = nil
            await synchronizeRecoveryGate(for: nil, token: token)
            if error is CancellationError { throw CancellationError() }
            lastError = .preferences
            throw Failure.preferences
        }
    }

    private func bind(_ preference: NETunnelProviderAccess.Preference, token: UUID) {
        stopObserving?()
        stopObserving = preference.observe { [weak self] in self?.receiveStatus(from: preference, token: token) }
    }

    private func receiveStatus(from preference: NETunnelProviderAccess.Preference, token: UUID) {
        guard sessionToken == token else { return }
        let status = preference.status()
        lastObservedSystemStatus = status
        let previouslyActive = state != .disconnected
        state = Self.state(for: status)
        Task { [weak self] in
            await self?.synchronizeRecoveryGate(for: status, token: token)
        }
        SafeLog.info("[VPN] NE status changed status=\(status.rawValue)")
        if status == .connected { startTrafficObservationIfNeeded() }
        else { stopTrafficObservation() }
        if status == .connected, operation == .connecting { operation = .idle }
        guard status == .disconnected || status == .invalid else { return }
        operation = .idle
        activeCandidatePoolRevision = nil
        guard previouslyActive else { return }
        Task { [weak self] in
            let error = await preference.lastDisconnectError()
            guard let self, self.sessionToken == token, let error else { return }
            self.lastError = .connection(error)
            SafeLog.info("[VPN] lastDisconnectError domain=\(error.domain.rawValue) code=\(error.code) category=\(error.category.rawValue)")
        }
    }

    private func synchronizeRecoveryGate(for status: NEVPNStatus?, token: UUID) async {
        guard sessionToken == token else { return }
        await setRecoveryAllowedForFormalVPN(status == .disconnected)
    }

    private func restoreRecoveryAfterAbandonedConnectIfSafe() async {
        guard operation == .idle, lastObservedSystemStatus == .disconnected else { return }
        await setRecoveryAllowedForFormalVPN(true)
    }

    func switchNode(
        requestID: UUID, targetCoreName: String,
        candidatePoolRevision: String?
    ) async throws -> MihomoTunnelControlResult {
        try await sendTunnelControl(.init(
            requestID: requestID,
            command: .switchNode,
            payload: .init(targetCoreName: targetCoreName,
                           candidatePoolRevision: candidatePoolRevision)
        ))
    }

    func switchMode(_ mode: ProxyMode, requestID: UUID = UUID()) async throws -> Bool {
        guard state == .connected else { return false }
        let target = mode == .rule ? "rule" : "global"
        let result = try await sendTunnelControl(.init(
            requestID: requestID,
            command: .switchMode,
            payload: .init(mode: target)
        ))
        return result.switchApplied == true && result.confirmedMode == target
    }

    func probeNodes(
        coreNames: [String], candidatePoolRevision: String?
    ) async throws -> [MihomoTunnelNodeProbeResult] {
        let result = try await sendTunnelControl(.init(
            command: .probeNodes,
            payload: .init(
                candidatePoolRevision: candidatePoolRevision,
                probeCoreNames: coreNames
            )
        ))
        guard let nodeProbeResults = result.nodeProbeResults else {
            throw TunnelDiagnostic(
                code: .signatureNotVerified,
                message: "VPN node probe response unavailable"
            )
        }
        return nodeProbeResults
    }

    func sendTunnelControl(
        _ request: MihomoTunnelControlRequest
    ) async throws -> MihomoTunnelControlResult {
        guard state == .connected, let preference,
              preference.status() == .connected else {
            throw TunnelDiagnostic(code: .signatureNotVerified, message: "VPN session unavailable")
        }
        let requestData = try MihomoTunnelControlCodec.encode(request)
        guard let responseData = try await preference.send(requestData),
              let response = MihomoTunnelControlCodec.decodeResponse(responseData),
              response.schemaVersion == MihomoTunnelControlRequest.currentSchemaVersion,
              response.requestID == request.requestID else {
            throw TunnelDiagnostic(code: .signatureNotVerified, message: "VPN control response unavailable")
        }
        return response.result
    }

    private func startTrafficObservationIfNeeded() {
        guard state == .connected, trafficTask == nil else { return }
        let observationID = UUID()
        trafficObservationID = observationID
        trafficTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollTraffic(observationID: observationID)
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }
    }

    private func stopTrafficObservation() {
        trafficObservationID = nil
        trafficTask?.cancel()
        trafficTask = nil
        uploadBytesPerSecond = 0
        downloadBytesPerSecond = 0
    }

    func pollTraffic(observationID: UUID) async {
        let request = MihomoTunnelControlRequest(command: .trafficSnapshot)
        do {
            let result = try await sendTunnelControl(request)
            guard trafficObservationID == observationID, state == .connected else { return }
            uploadBytesPerSecond = max(0, result.uploadBytesPerSecond ?? 0)
            downloadBytesPerSecond = max(0, result.downloadBytesPerSecond ?? 0)
        } catch {
            guard trafficObservationID == observationID, state == .connected else { return }
            uploadBytesPerSecond = 0
            downloadBytesPerSecond = 0
        }
    }
}

enum LiveTrafficFormatter {
    static func bytesPerSecond(_ bytes: Int64) -> String {
        let normalized = max(0, bytes)
        guard normalized > 0 else { return "0 B/s" }
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = Double(normalized)
        var unit = 0
        while value >= 1_024, unit < units.count - 1 {
            value /= 1_024
            unit += 1
        }
        guard unit > 0 else { return "\(normalized) \(units[unit])" }
        let rendered = String(format: "%.1f", value)
        let trimmed = rendered.hasSuffix(".0")
            ? String(rendered.dropLast(2)) : rendered
        return "\(trimmed) \(units[unit])"
    }
}
