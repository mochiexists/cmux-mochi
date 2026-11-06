import Foundation

/// Process-wide retry window for Codex state databases that could not be read.
///
/// Session autosave rebuilds the restorable-agent index every few seconds and
/// verifies each Codex hook record against `~/.codex/state_*.sqlite`. Without a
/// window, an unreadable database is reopened for every record on every tick:
/// on 2026-11-06 that was ~16k failed SQLite lookups a minute, each written to
/// the persisted unified log. A failure skips the database for
/// `initialInterval`, doubling per consecutive failure up to `maximumInterval`;
/// any successful lookup clears it.
public final class CodexStateDatabaseBackoff: @unchecked Sendable {
    public static let shared = CodexStateDatabaseBackoff()
    public static let initialInterval: TimeInterval = 30
    public static let maximumInterval: TimeInterval = 15 * 60

    private struct Window {
        var consecutiveFailures: Int
        var retryAfter: Date
    }

    private let lock = NSLock()
    private let now: () -> Date
    private var windows: [String: Window] = [:]

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    public func shouldSkip(path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let window = windows[path] else { return false }
        return now() < window.retryAfter
    }

    public func recordFailure(path: String) {
        lock.lock()
        defer { lock.unlock() }
        let failures = (windows[path]?.consecutiveFailures ?? 0) + 1
        let exponent = Double(min(failures - 1, 16))
        let interval = min(Self.initialInterval * pow(2, exponent), Self.maximumInterval)
        windows[path] = Window(
            consecutiveFailures: failures,
            retryAfter: now().addingTimeInterval(interval)
        )
    }

    public func recordSuccess(path: String) {
        lock.lock()
        defer { lock.unlock() }
        windows[path] = nil
    }
}
