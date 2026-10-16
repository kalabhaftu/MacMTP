import Foundation

/// Small, path-free state that the Sentry watchdog can read without waiting for the UI.
final class HangDiagnostics: @unchecked Sendable {
    enum Operation: String, CaseIterable {
        case favorites
        case volumes
    }

    private struct ActiveOperation {
        let operation: Operation
        let started: TimeInterval
    }

    private struct Completion {
        let duration: TimeInterval
        let finished: TimeInterval
        let count: Int
    }

    static let shared = HangDiagnostics()

    private let lock = NSLock()
    private let uptime: @Sendable () -> TimeInterval
    private var active: ActiveOperation?
    private var completions: [Operation: Completion] = [:]
    private var uiState: [String: Bool] = [:]

    init(uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.uptime = uptime
    }

    func setConnected(_ connected: Bool) {
        lock.lock()
        uiState["last_known_connected"] = connected
        lock.unlock()
    }

    func setWindowState(appActive: Bool, visible: Bool, unoccluded: Bool) {
        lock.lock()
        uiState["last_known_app_active"] = appActive
        uiState["last_known_main_window_visible"] = visible
        uiState["last_known_main_window_unoccluded"] = unoccluded
        lock.unlock()
    }

    func measureMainThread<T>(_ operation: Operation, perform: () throws -> T) rethrows -> T {
        guard Thread.isMainThread else { return try perform() }
        let started = uptime()
        lock.lock()
        let previous = active
        active = ActiveOperation(operation: operation, started: started)
        lock.unlock()

        defer {
            let finished = uptime()
            lock.lock()
            let count = completions[operation]?.count ?? 0
            completions[operation] = Completion(
                duration: max(0, finished - started),
                finished: finished,
                count: count < Int.max ? count + 1 : count
            )
            active = previous
            lock.unlock()
        }
        return try perform()
    }

    func context() -> [String: Any] {
        let now = uptime()
        lock.lock()
        let active = self.active
        let completions = self.completions
        let uiState = self.uiState
        lock.unlock()

        // These values describe beforeSend time. The stack may have been captured before recovery.
        var context: [String: Any] = ["snapshot_stage": "before_send"]
        uiState.forEach { context[$0.key] = $0.value }
        context["active_operation"] = active?.operation.rawValue ?? "none"
        if let active {
            context["active_elapsed_ms"] = max(0, now - active.started) * 1_000
        }
        for operation in Operation.allCases {
            guard let completion = completions[operation] else { continue }
            let prefix = operation.rawValue
            context["\(prefix)_last_duration_ms"] = completion.duration * 1_000
            context["\(prefix)_completed_age_ms"] = max(0, now - completion.finished) * 1_000
            context["\(prefix)_completion_count"] = completion.count
        }
        return context
    }
}
