import Dispatch
import os

/// A directory probe that blocks like an open stuck on a pending privacy
/// prompt until the test releases it, and counts how often it was started.
final class BlockingDirectoryProbe: Sendable {
    private let release = DispatchSemaphore(value: 0)
    // Test-only counter bumped from the gate's probe queue.
    private let starts = OSAllocatedUnfairLock(initialState: 0)

    var startCount: Int { starts.withLock { $0 } }

    func open(_ path: String) -> Bool {
        starts.withLock { $0 += 1 }
        release.wait()
        return true
    }

    /// Lets one blocked probe return.
    func answer() {
        release.signal()
    }
}
