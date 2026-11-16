import Foundation

/// Coalesces subscription refresh requests for one AppModel.
/// It has no tunnel state, node-switch queue or Core operation.
@MainActor
final class NodeSessionCoordinator {
    private var refreshTask: Task<Void, Never>?
    private var refreshTaskID: UUID?
    private var manualRefreshTask: Task<Void, Never>?
    private var manualRefreshTaskID: UUID?

    func waitForRefresh() async {
        await refreshTask?.value
    }

    func refresh(
        manual: Bool,
        operation: @escaping @MainActor (_ manual: Bool) async -> Void
    ) async {
        if manual {
            if let manualRefreshTask {
                await manualRefreshTask.value
                return
            }
            let id = UUID()
            let task = Task { [weak self] in
                guard let self else { return }
                await self.runRefresh(freshAfterInFlight: true, operation: operation)
            }
            manualRefreshTask = task
            manualRefreshTaskID = id
            await task.value
            if manualRefreshTaskID == id {
                manualRefreshTask = nil
                manualRefreshTaskID = nil
            }
        } else {
            await runRefresh(freshAfterInFlight: false, operation: operation)
        }
    }

    private func runRefresh(
        freshAfterInFlight: Bool,
        operation: @escaping @MainActor (_ manual: Bool) async -> Void
    ) async {
        while let refreshTask {
            let oldID = refreshTaskID
            if freshAfterInFlight { refreshTask.cancel() }
            await refreshTask.value
            if !freshAfterInFlight { return }
            if refreshTaskID == oldID {
                self.refreshTask = nil
                self.refreshTaskID = nil
            }
            guard !Task.isCancelled else { return }
        }
        guard !Task.isCancelled else { return }
        let id = UUID()
        let task = Task { await operation(freshAfterInFlight) }
        refreshTask = task
        refreshTaskID = id
        await task.value
        if refreshTaskID == id {
            refreshTask = nil
            refreshTaskID = nil
        }
    }

    func cancelAll() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshTaskID = nil
        manualRefreshTask?.cancel()
        manualRefreshTask = nil
        manualRefreshTaskID = nil
    }
}
