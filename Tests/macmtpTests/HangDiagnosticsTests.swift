import Foundation
import Testing
@testable import macmtp

private final class HangDiagnosticClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 100

    func now() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ interval: TimeInterval) {
        lock.lock()
        value += interval
        lock.unlock()
    }
}

private final class HangDiagnosticSnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: [String: Any]?
    private var capturedOnMainThread: Bool?

    func store(_ snapshot: [String: Any], onMainThread: Bool) {
        lock.lock()
        self.snapshot = snapshot
        capturedOnMainThread = onMainThread
        lock.unlock()
    }

    func read() -> (snapshot: [String: Any]?, onMainThread: Bool?) {
        lock.lock()
        defer { lock.unlock() }
        return (snapshot, capturedOnMainThread)
    }
}

@Test @MainActor
func hangSnapshotCanReadInFlightWorkOffMainWithoutWaitingForCompletion() {
    let clock = HangDiagnosticClock()
    let diagnostics = HangDiagnostics(uptime: { clock.now() })
    let snapshotReady = DispatchSemaphore(value: 0)
    let snapshotBox = HangDiagnosticSnapshotBox()
    let result = diagnostics.measureMainThread(.favorites) {
        clock.advance(6)
        // A watchdog read must succeed while the measured main-thread work is still running.
        DispatchQueue.global().async {
            snapshotBox.store(diagnostics.context(), onMainThread: Thread.isMainThread)
            snapshotReady.signal()
        }
        let completedBeforeMainWorkReturned = snapshotReady.wait(timeout: .now() + 2) == .success
        #expect(completedBeforeMainWorkReturned)
        let (snapshot, capturedOnMainThread) = snapshotBox.read()
        #expect(capturedOnMainThread == false)
        #expect(snapshot?["active_operation"] as? String == "favorites")
        #expect(snapshot?["active_elapsed_ms"] as? Double == 6_000)
        #expect(snapshot?["favorites_completion_count"] == nil)
        return 42
    }
    #expect(result == 42)
    #expect(diagnostics.context()["active_operation"] as? String == "none")
}

@Test @MainActor
func hangSnapshotRetainsEachCompletedPhaseAfterRecovery() {
    let clock = HangDiagnosticClock()
    let diagnostics = HangDiagnostics(uptime: { clock.now() })
    diagnostics.measureMainThread(.favorites) { clock.advance(6) }
    diagnostics.measureMainThread(.volumes) { clock.advance(0.25) }
    clock.advance(1)

    let snapshot = diagnostics.context()
    #expect(snapshot["favorites_last_duration_ms"] as? Double == 6_000)
    #expect(snapshot["favorites_completed_age_ms"] as? Double == 1_250)
    #expect(snapshot["volumes_last_duration_ms"] as? Double == 250)
    #expect(snapshot["volumes_completed_age_ms"] as? Double == 1_000)
    #expect(snapshot["favorites_completion_count"] as? Int == 1)
    #expect(snapshot["volumes_completion_count"] as? Int == 1)
}

@Test @MainActor
func hangMeasurementsRestoreOuterPhaseAndFinishWhenWorkThrows() {
    enum Failure: Error { case expected }
    let clock = HangDiagnosticClock()
    let diagnostics = HangDiagnostics(uptime: { clock.now() })
    do {
        try diagnostics.measureMainThread(.volumes) {
            diagnostics.measureMainThread(.favorites) { clock.advance(1) }
            #expect(diagnostics.context()["active_operation"] as? String == "volumes")
            throw Failure.expected
        }
        Issue.record("Expected the operation's error to propagate")
    } catch {
        #expect(error is Failure)
    }
    #expect(diagnostics.context()["active_operation"] as? String == "none")
    #expect(diagnostics.context()["volumes_last_duration_ms"] as? Double == 1_000)
}

@Test
func backgroundFilesystemWorkDoesNotMasqueradeAsMainThreadWork() async {
    let diagnostics = HangDiagnostics()
    let ignored = await Task.detached {
        diagnostics.measureMainThread(.favorites) { 42 } == 42
            && diagnostics.context()["favorites_completion_count"] == nil
    }.value
    #expect(ignored)
}

@Test
func hangSnapshotOmitsUnknownStateAndAcceptsOnlyFixedUIFields() {
    let diagnostics = HangDiagnostics()
    #expect(diagnostics.context()["last_known_connected"] == nil)
    #expect(diagnostics.context()["last_known_app_active"] == nil)
    diagnostics.setConnected(true)
    diagnostics.setWindowState(appActive: false, visible: true, unoccluded: false)
    let context = diagnostics.context()
    #expect(context["last_known_connected"] as? Bool == true)
    #expect(context["last_known_app_active"] as? Bool == false)
    #expect(context["last_known_main_window_visible"] as? Bool == true)
    #expect(context["last_known_main_window_unoccluded"] as? Bool == false)
    #expect(Set(context.keys) == [
        "snapshot_stage", "active_operation", "last_known_connected", "last_known_app_active",
        "last_known_main_window_visible", "last_known_main_window_unoccluded",
    ])
}
