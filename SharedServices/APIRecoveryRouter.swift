import Foundation

struct APIRecoveryPlan: Sendable, Equatable {
    let targets: [String]
    let builtInProxy: [String]

    init(targets: [String], builtInProxy: [String]) {
        self.targets = Self.uniqueValues(targets)
        self.builtInProxy = builtInProxy
    }

    static func forAPI(_ config: AppConfig) -> APIRecoveryPlan {
        APIRecoveryPlan(
            targets: AppConfig.orderedAPIBaseURLs(from: config),
            builtInProxy: config.builtInProxy
        )
    }

    static func forAbsoluteURL(
        _ absoluteURL: String,
        builtInProxy: [String]
    ) -> APIRecoveryPlan {
        APIRecoveryPlan(targets: [absoluteURL], builtInProxy: builtInProxy)
    }

    private static func uniqueValues(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, seen.insert(text).inserted else { return nil }
            return text
        }
    }
}

enum APIRecoveryPath: Sendable, Equatable {
    case normal
    case builtIn(index: Int, protocolName: String)
}

struct APIRecoveryRoute: Sendable {
    let target: String
    let targetIndex: Int
    let path: APIRecoveryPath
    let transport: (any NetworkTransport)?
}

protocol BuiltInProxyRecoveryRuntimeProtocol: Actor {
    func start(endpoint: BuiltInProxyEndpoint) async throws -> BuiltInProxyRecoveryRuntimeInfo
    func makeRecoveryTransport() throws -> any NetworkTransport
    /// Confirms the single App-only Core owner has actually released its
    /// service. A failed close is observable and blocks another start.
    func stopRecovery() async throws
}



actor APIRecoveryRouter {
    typealias Operation<Result: Sendable> = @Sendable (APIRecoveryRoute) async throws -> Result

    static let shared = APIRecoveryRouter()

    private let recoveryRuntime: any BuiltInProxyRecoveryRuntimeProtocol
    private let writeTransportFactory: @Sendable () -> any ManagedNetworkTransport
    private let recoveryWaitTimeout: Duration
    private let clock: OperationClock
    private var recoveryInUse = false
    private var recoveryForeground = true
    private var recoveryEpoch: UInt64 = 0
    private var recoveryCleanupBlocked = false
    private var systemVPNTakeover: Bool
    private var recoveryDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private struct RecoveryWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
        let timer: Task<Void, Never>
    }
    private var recoveryWaiters: [RecoveryWaiter] = []

    #if DEBUG
    func recoveryWaiterCountForTesting() -> Int { recoveryWaiters.count }
    func takeoverStateForTesting() -> (suspended: Bool, inUse: Bool, cleanupBlocked: Bool) {
        (systemVPNTakeover, recoveryInUse, recoveryCleanupBlocked)
    }
    #endif

    init(
        recoveryRuntime: any BuiltInProxyRecoveryRuntimeProtocol = UnavailableRecoveryRuntime(),
        recoveryInitiallySuspendedForFormalVPN: Bool = true,
        recoveryWaitTimeout: Duration = .seconds(15),
        clock: OperationClock = .continuous,
        writeTransportFactory: @escaping @Sendable () -> any ManagedNetworkTransport = {
            URLSessionNetworkTransport(profile: .api)
        }
    ) {
        self.recoveryRuntime = recoveryRuntime
        systemVPNTakeover = recoveryInitiallySuspendedForFormalVPN
        self.recoveryWaitTimeout = recoveryWaitTimeout
        self.clock = clock
        self.writeTransportFactory = writeTransportFactory
    }

    func setRecoveryForeground(_ active: Bool) async {
        if recoveryForeground != active { recoveryEpoch &+= 1 }
        recoveryForeground = active
        // The awaited connection gate owns cleanup until handoff completes.
        // A scene/status notification must not reopen or race that handoff.
        guard !systemVPNTakeover else { return }
        guard !active else { return }
        // Cancel only the app-local recovery service. Direct transports and
        // cached business data are owned elsewhere and remain untouched.
        _ = await stopRecoveryRuntime(operationID: nil)
    }

    func beginSystemVPNTakeover() {
        systemVPNTakeover = true
        recoveryEpoch &+= 1
        let pending = recoveryWaiters
        recoveryWaiters.removeAll()
        pending.forEach { $0.timer.cancel(); $0.continuation.resume(throwing: CancellationError()) }
    }

    func finishSystemVPNTakeover(keepSuspended: Bool) {
        systemVPNTakeover = keepSuspended
    }

    /// Freeze first, quiesce the shared probe owner, then enter here. Closing
    /// the session interrupts HTTP; draining the router also joins a start that
    /// was already suspended before epoch invalidation. Its cleanup must finish
    /// before the system manager can receive a preparation request.
    func closeRecoveryForSystemVPN() async throws {
        guard systemVPNTakeover else { throw Self.unconfirmedRecoveryClose() }
        let stopped = await stopRecoveryRuntime(operationID: nil)
        try Task.checkCancellation()
        guard stopped else { throw Self.unconfirmedRecoveryClose() }
        if recoveryInUse {
            await withCheckedContinuation { recoveryDrainWaiters.append($0) }
        }
        try Task.checkCancellation()
        guard systemVPNTakeover, !recoveryCleanupBlocked else {
            throw Self.unconfirmedRecoveryClose()
        }
    }

    private static func unconfirmedRecoveryClose() -> TunnelDiagnostic {
        TunnelDiagnostic(code: .recoveryCloseUnconfirmed, message: "App recovery ownership was not released")
    }

    nonisolated func operationDeadline(_ budget: Duration) -> OperationDeadline {
        OperationDeadline(after: budget, clock: clock)
    }

    func safeRetry<Result: Sendable>(
        plan: APIRecoveryPlan,
        directAlreadyExhausted: NetworkClientError? = nil,
        budget: Duration = OperationBudget.read,
        operation: @escaping Operation<Result>
    ) async throws -> Result {
        let deadline = OperationDeadline(after: budget, clock: clock)
        return try await OperationDeadline.$current.withValue(deadline) {
            try await self.retryWithinDeadline(plan: plan,
                directAlreadyExhausted: directAlreadyExhausted, operation: operation)
        }
    }

    private func retryWithinDeadline<Result: Sendable>(
        plan: APIRecoveryPlan,
        directAlreadyExhausted: NetworkClientError? = nil,
        operation: @escaping Operation<Result>
    ) async throws -> Result {
        try OperationDeadline.checkCurrent()
        #if DEBUG
        let diagnosticOperation = DeveloperDiagnosticOperation.make("recovery-read")
        DeveloperDiagnostics.shared.record(.init(
            operationID: diagnosticOperation, module: .recovery,
            stage: "route-evaluation", outcome: "started",
            detail: "targets=\(plan.targets.count) recoveryCandidates=\(plan.builtInProxy.count) directPreflightDone=\(directAlreadyExhausted != nil)"
        ))
        #else
        let diagnosticOperation: String? = nil
        #endif
        guard !plan.targets.isEmpty else {
            throw NetworkClientError.configInvalid("未配置 API 地址")
        }

        var lastError: NetworkClientError
        if let directAlreadyExhausted {
            // The caller already completed its own bounded direct retry policy.
            // Avoid replaying a credential-bearing subscription URL directly.
            lastError = directAlreadyExhausted
        } else {
            do {
                let result = try await attemptTargets(
                    plan.targets,
                    path: .normal,
                    transport: nil,
                    operation: operation
                )
                #if DEBUG
                DeveloperDiagnostics.shared.record(.init(
                    operationID: diagnosticOperation, module: .recovery, level: .success,
                    stage: "route-evaluation", outcome: "direct-success", route: "direct"
                ))
                #endif
                return result
            } catch let exhausted as APIRecoveryRoutesExhausted {
                lastError = exhausted.lastError
                #if DEBUG
                DeveloperDiagnostics.shared.record(.init(
                    operationID: diagnosticOperation, module: .recovery, level: .warning,
                    stage: "direct-routes", outcome: "exhausted", route: "direct",
                    detail: "category=\(exhausted.lastError.logCategory)"
                ))
                #endif
            }
        }

        try OperationDeadline.checkCurrent()
        let endpoints = BuiltInProxyParser.parseMany(plan.builtInProxy)
        guard !endpoints.isEmpty else {
            if !plan.builtInProxy.isEmpty {
                SafeLog.warning(
                    "[Recovery] skipped reason=no-compatible-endpoints "
                        + "configuredCount=\(plan.builtInProxy.count)"
                )
            }
            #if DEBUG
            DeveloperDiagnostics.shared.record(.init(
                operationID: diagnosticOperation, module: .recovery, level: .error,
                stage: "recovery-routes", outcome: "no-compatible-endpoints",
                detail: "configured=\(plan.builtInProxy.count)"
            ))
            #endif
            throw lastError
        }
        guard recoveryForeground, !systemVPNTakeover else { throw lastError }
        let epoch = recoveryEpoch
        UserSystemLogger.shared.log(.warning, module: .recovery, key: UserLogKey.recoveryStarting)

        try OperationDeadline.checkCurrent(minimum: OperationBudget.minimumRecoveryStart)
        try await acquireRecoveryRuntime()
        defer { releaseRecoveryRuntime() }
        try OperationDeadline.checkCurrent()
        try requireRecovery(epoch)
        let runtimeAvailable = await recoverBlockedRuntimeIfPossible(operationID: diagnosticOperation)
        try OperationDeadline.checkCurrent()
        guard runtimeAvailable else {
            throw lastError
        }

        for (offset, endpoint) in endpoints.enumerated() {
            try requireRecovery(epoch)
            try OperationDeadline.checkCurrent(minimum: OperationBudget.minimumRecoveryStart)
            let path = APIRecoveryPath.builtIn(
                index: offset + 1,
                protocolName: endpoint.protocolName
            )
            do {
                #if DEBUG
                DeveloperDiagnostics.shared.record(.init(
                    operationID: diagnosticOperation, module: .recovery,
                    stage: "runtime-start", outcome: "started", attempt: offset + 1,
                    route: "built-in-\(endpoint.protocolName)"
                ))
                #endif
                _ = try await recoveryRuntime.start(endpoint: endpoint)
                try requireRecovery(epoch)
                let transport = try await recoveryRuntime.makeRecoveryTransport()
                try requireRecovery(epoch)
                let result = try await attemptTargets(
                    plan.targets,
                    path: path,
                    transport: transport,
                    recoveryEpoch: epoch,
                    operation: operation
                )
                _ = await stopRecoveryRuntime(operationID: diagnosticOperation)
                try OperationDeadline.checkCurrent()
                UserSystemLogger.shared.log(.success, module: .recovery, key: UserLogKey.recoverySucceeded)
                #if DEBUG
                DeveloperDiagnostics.shared.record(.init(
                    operationID: diagnosticOperation, module: .recovery, level: .success,
                    stage: "route-evaluation", outcome: "recovery-success", attempt: offset + 1,
                    route: "built-in-\(endpoint.protocolName)"
                ))
                #endif
                return result
            } catch let exhausted as APIRecoveryRoutesExhausted {
                lastError = exhausted.lastError
                let stopped = await stopRecoveryRuntime(operationID: diagnosticOperation)
                try OperationDeadline.checkCurrent()
                guard stopped else { break }
            } catch is CancellationError {
                _ = await stopRecoveryRuntime(operationID: diagnosticOperation)
                #if DEBUG
                DeveloperDiagnostics.shared.record(.init(
                    operationID: diagnosticOperation, module: .recovery, level: .warning,
                    stage: "route-evaluation", outcome: "cancelled", cancelled: true
                ))
                #endif
                throw CancellationError()
            } catch let error as NetworkClientError {
                _ = await stopRecoveryRuntime(operationID: diagnosticOperation)
                try OperationDeadline.checkCurrent()
                throw error
            } catch {
                let stopped = await stopRecoveryRuntime(operationID: diagnosticOperation)
                try checkCancellation(after: error)
                lastError = .transport("网络连接失败，请稍后重试")
                guard stopped else { break }
            }
        }

        try OperationDeadline.checkCurrent()
        UserSystemLogger.shared.log(.error, module: .recovery, key: UserLogKey.recoveryFailed)
        #if DEBUG
        DeveloperDiagnostics.shared.record(.init(
            operationID: diagnosticOperation, module: .recovery, level: .error,
            stage: "route-evaluation", outcome: "all-routes-failed",
            detail: "category=\(lastError.logCategory)"
        ))
        #endif
        throw lastError
    }

    func singleAttemptWrite<Result: Sendable>(
        plan: APIRecoveryPlan,
        probe: @escaping Operation<Void>,
        submit: @escaping Operation<Result>
    ) async throws -> Result {
        let submissionParent = OperationDeadline.current
        let deadline = OperationDeadline(after: OperationBudget.writeRouting, clock: clock)
        return try await OperationDeadline.$current.withValue(deadline) {
            try await self.writeWithinDeadline(plan: plan, submissionParent: submissionParent,
                probe: probe, submit: submit)
        }
    }

    private func writeWithinDeadline<Result: Sendable>(
        plan: APIRecoveryPlan,
        submissionParent: OperationDeadline?,
        probe: @escaping Operation<Void>,
        submit: @escaping Operation<Result>
    ) async throws -> Result {
        try OperationDeadline.checkCurrent()
        #if DEBUG
        let diagnosticOperation = DeveloperDiagnosticOperation.make("recovery-write")
        DeveloperDiagnostics.shared.record(.init(
            operationID: diagnosticOperation, module: .recovery,
            stage: "single-write-preflight", outcome: "started",
            detail: "targets=\(plan.targets.count) recoveryCandidates=\(plan.builtInProxy.count)"
        ))
        #else
        let diagnosticOperation: String? = nil
        #endif
        guard !plan.targets.isEmpty else {
            throw NetworkClientError.configInvalid("未配置 API 地址")
        }

        var lastError: NetworkClientError
        do {
            let selected = try await selectTarget(
                plan.targets,
                path: .normal,
                transport: nil,
                probe: probe
            )
            let transport = writeTransportFactory()
            defer { transport.finishTasksAndInvalidate() }
            let result = try await submitOnce(selected, transport: transport, submissionParent: submissionParent, submit: submit)
            #if DEBUG
            DeveloperDiagnostics.shared.record(.init(
                operationID: diagnosticOperation, module: .recovery, level: .success,
                stage: "single-write-submit", outcome: "completed-once", route: "direct"
            ))
            #endif
            return result
        } catch let exhausted as APIRecoveryRoutesExhausted {
            lastError = exhausted.lastError
        }

        try OperationDeadline.checkCurrent()
        let endpoints = BuiltInProxyParser.parseMany(plan.builtInProxy)
        guard !endpoints.isEmpty else {
            if !plan.builtInProxy.isEmpty {
                SafeLog.warning(
                    "[Recovery] skipped reason=no-compatible-endpoints "
                        + "configuredCount=\(plan.builtInProxy.count)"
                )
            }
            throw lastError
        }
        guard recoveryForeground, !systemVPNTakeover else { throw lastError }
        let epoch = recoveryEpoch
        UserSystemLogger.shared.log(.warning, module: .recovery, key: UserLogKey.recoveryStarting)

        try OperationDeadline.checkCurrent(minimum: OperationBudget.minimumRecoveryStart)
        try await acquireRecoveryRuntime()
        defer { releaseRecoveryRuntime() }
        try OperationDeadline.checkCurrent()
        try requireRecovery(epoch)
        let runtimeAvailable = await recoverBlockedRuntimeIfPossible(operationID: diagnosticOperation)
        try OperationDeadline.checkCurrent()
        guard runtimeAvailable else {
            throw lastError
        }

        for (offset, endpoint) in endpoints.enumerated() {
            try requireRecovery(epoch)
            try OperationDeadline.checkCurrent(minimum: OperationBudget.minimumRecoveryStart)
            let path = APIRecoveryPath.builtIn(
                index: offset + 1,
                protocolName: endpoint.protocolName
            )
            do {
                _ = try await recoveryRuntime.start(endpoint: endpoint)
                try requireRecovery(epoch)
            } catch is CancellationError {
                _ = await stopRecoveryRuntime(operationID: diagnosticOperation)
                throw CancellationError()
            } catch {
                let stopped = await stopRecoveryRuntime(operationID: diagnosticOperation)
                try checkCancellation(after: error)
                lastError = .transport("网络连接失败，请稍后重试")
                guard stopped else { break }
                continue
            }

            let selected: APIRecoveryRoute
            do {
                let probeTransport = try await recoveryRuntime.makeRecoveryTransport()
                try requireRecovery(epoch)
                selected = try await selectTarget(
                    plan.targets,
                    path: path,
                    transport: probeTransport,
                    recoveryEpoch: epoch,
                    probe: probe
                )
                try requireRecovery(epoch)
            } catch let exhausted as APIRecoveryRoutesExhausted {
                lastError = exhausted.lastError
                let stopped = await stopRecoveryRuntime(operationID: diagnosticOperation)
                try OperationDeadline.checkCurrent()
                guard stopped else { break }
                continue
            } catch is CancellationError {
                _ = await stopRecoveryRuntime(operationID: diagnosticOperation)
                throw CancellationError()
            } catch let error as NetworkClientError {
                _ = await stopRecoveryRuntime(operationID: diagnosticOperation)
                try OperationDeadline.checkCurrent()
                throw error
            } catch {
                let stopped = await stopRecoveryRuntime(operationID: diagnosticOperation)
                try checkCancellation(after: error)
                lastError = .transport("网络连接失败，请稍后重试")
                guard stopped else { break }
                continue
            }

            let writeTransport: any NetworkTransport
            do {
                writeTransport = try await recoveryRuntime.makeRecoveryTransport()
                try requireRecovery(epoch)
            } catch is CancellationError {
                _ = await stopRecoveryRuntime(operationID: diagnosticOperation)
                throw CancellationError()
            } catch {
                let stopped = await stopRecoveryRuntime(operationID: diagnosticOperation)
                try checkCancellation(after: error)
                lastError = .transport("网络连接失败，请稍后重试")
                guard stopped else { break }
                continue
            }

            do {
                try requireRecovery(epoch)
                let result = try await submitOnce(selected, transport: writeTransport, submissionParent: submissionParent, submit: submit)
                _ = await stopRecoveryRuntime(operationID: diagnosticOperation)
                try Task.checkCancellation()
                UserSystemLogger.shared.log(.success, module: .recovery, key: UserLogKey.recoverySucceeded)
                #if DEBUG
                DeveloperDiagnostics.shared.record(.init(
                    operationID: diagnosticOperation, module: .recovery, level: .success,
                    stage: "single-write-submit", outcome: "completed-once", attempt: offset + 1,
                    route: "built-in-\(endpoint.protocolName)"
                ))
                #endif
                return result
            } catch {
                _ = await stopRecoveryRuntime(operationID: diagnosticOperation)
                try Task.checkCancellation()
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                throw error
            }
        }

        try OperationDeadline.checkCurrent()
        UserSystemLogger.shared.log(.error, module: .recovery, key: UserLogKey.recoveryFailed)
        #if DEBUG
        DeveloperDiagnostics.shared.record(.init(
            operationID: diagnosticOperation, module: .recovery, level: .error,
            stage: "single-write-preflight", outcome: "all-routes-failed",
            detail: "submitCount=0 category=\(lastError.logCategory)"
        ))
        #endif
        throw lastError
    }

    private func attemptTargets<Result: Sendable>(
        _ targets: [String],
        path: APIRecoveryPath,
        transport: (any NetworkTransport)?,
        recoveryEpoch: UInt64? = nil,
        operation: @escaping Operation<Result>
    ) async throws -> Result {
        var lastError = NetworkClientError.transport("网络连接失败，请稍后重试")
        for (offset, target) in targets.enumerated() {
            try OperationDeadline.checkCurrent()
            if let recoveryEpoch { try requireRecovery(recoveryEpoch) }
            let route = APIRecoveryRoute(
                target: target,
                targetIndex: offset + 1,
                path: path,
                transport: transport
            )
            do {
                let deadline = OperationDeadline.current ?? operationDeadline(OperationBudget.read)
                let result = try await deadline.run { try await operation(route) }
                try OperationDeadline.checkCurrent()
                if let recoveryEpoch { try requireRecovery(recoveryEpoch) }
                return result
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as NetworkClientError {
                try OperationDeadline.checkCurrent()
                guard error.retryable else { throw error }
                lastError = error
            } catch {
                try checkCancellation(after: error)
                lastError = .transport("网络连接失败，请稍后重试")
            }
        }
        try OperationDeadline.checkCurrent()
        throw APIRecoveryRoutesExhausted(lastError: lastError)
    }

    private func selectTarget(
        _ targets: [String],
        path: APIRecoveryPath,
        transport: (any NetworkTransport)?,
        recoveryEpoch: UInt64? = nil,
        probe: @escaping Operation<Void>
    ) async throws -> APIRecoveryRoute {
        try await attemptTargets(
            targets,
            path: path,
            transport: transport,
            recoveryEpoch: recoveryEpoch
        ) { route in
            try await probe(route)
            return route
        }
    }

    private func submitOnce<Result: Sendable>(
        _ selected: APIRecoveryRoute,
        transport: any NetworkTransport,
        submissionParent: OperationDeadline?,
        submit: @escaping Operation<Result>
    ) async throws -> Result {
        // PRE-SUBMIT ends here. Never reuse its expired routing deadline for a
        // POST already sent; submission gets one bounded attempt, never replay.
        try OperationDeadline.checkCurrent()
        let deadline = OperationDeadline(after: OperationBudget.writeSubmit,
            clock: clock, parent: submissionParent)
        do {
            return try await deadline.run {
                try await submit(APIRecoveryRoute(target: selected.target,
                    targetIndex: selected.targetIndex, path: selected.path, transport: transport))
            }
        } catch {
            try Task.checkCancellation()
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if case NetworkClientError.timedOut = error { throw NetworkClientError.writeResultUnknown }
            if (error as? URLError)?.code == .timedOut { throw NetworkClientError.writeResultUnknown }
            throw error
        }
    }

    private func acquireRecoveryRuntime() async throws {
        try Task.checkCancellation()
        if !recoveryInUse {
            recoveryInUse = true
            return
        }
        let id = UUID()
        try OperationDeadline.checkCurrent()
        let queueClock = OperationDeadline.current?.clock ?? clock
        let remaining = OperationDeadline.current?.remaining ?? recoveryWaitTimeout
        let timeout = min(recoveryWaitTimeout, remaining)
        let deadlineLimited = remaining <= recoveryWaitTimeout
        let until = queueClock.now() + timeout
        try await withTaskCancellationHandler(operation: {
            try await enqueueRecoveryWaiter(id: id, clock: queueClock, until: until, deadlineLimited: deadlineLimited)
        }, onCancel: {
            Task { await self.cancelRecoveryWaiter(id) }
        })
        // Once the continuation is resumed normally, this task owns the slot.
        // Let the caller install its release defer before observing a concurrent
        // cancellation; otherwise the granted slot can be orphaned forever.
    }

    private func enqueueRecoveryWaiter(id: UUID, clock: OperationClock, until: Duration, deadlineLimited: Bool) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            if Task.isCancelled {
                continuation.resume(throwing: CancellationError())
                return
            }
            let timer = Task { [weak self] in
                do { try await clock.sleepUntil(until) } catch { return }
                await self?.timeoutRecoveryWaiter(id, deadlineLimited: deadlineLimited)
            }
            recoveryWaiters.append(RecoveryWaiter(id: id, continuation: continuation, timer: timer))
        }
    }

    private func releaseRecoveryRuntime() {
        guard !recoveryWaiters.isEmpty else {
            recoveryInUse = false
            let drained = recoveryDrainWaiters
            recoveryDrainWaiters.removeAll()
            drained.forEach { $0.resume() }
            return
        }
        let waiter = recoveryWaiters.removeFirst()
        waiter.timer.cancel()
        waiter.continuation.resume()
    }

    private func cancelRecoveryWaiter(_ id: UUID) {
        guard let index = recoveryWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = recoveryWaiters.remove(at: index)
        waiter.timer.cancel()
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func timeoutRecoveryWaiter(_ id: UUID, deadlineLimited: Bool) {
        guard let index = recoveryWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = recoveryWaiters.remove(at: index)
        waiter.timer.cancel()
        waiter.continuation.resume(
            throwing: deadlineLimited ? NetworkClientError.timedOut : NetworkClientError.serviceUnavailable(
                "恢复通道暂时繁忙，请稍后重试", retryable: true
            )
        )
    }

    private func recoverBlockedRuntimeIfPossible(operationID: String?) async -> Bool {
        guard recoveryCleanupBlocked else { return true }
        return await stopRecoveryRuntime(operationID: operationID)
    }

    private func stopRecoveryRuntime(operationID: String?) async -> Bool {
        do {
            try await recoveryRuntime.stopRecovery()
            recoveryCleanupBlocked = false
            return true
        } catch {
            recoveryCleanupBlocked = true
            #if DEBUG
            DeveloperDiagnostics.shared.record(.init(
                operationID: operationID ?? DeveloperDiagnosticOperation.make("recovery-stop"),
                module: .recovery, level: .error,
                stage: "runtime-stop", outcome: "failed",
                detail: "category=core-close"
            ))
            #endif
            return false
        }
    }

    private func requireRecovery(_ epoch: UInt64) throws {
        try Task.checkCancellation()
        guard recoveryForeground, !systemVPNTakeover, recoveryEpoch == epoch else { throw CancellationError() }
        try OperationDeadline.checkCurrent()
    }

    private func checkCancellation(after error: Error) throws {
        try Task.checkCancellation()
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            throw CancellationError()
        }
        try OperationDeadline.checkCurrent()
    }

}

private struct APIRecoveryRoutesExhausted: Error, Sendable {
    let lastError: NetworkClientError
}
