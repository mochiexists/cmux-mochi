public import Foundation
internal import Darwin
internal import os

/// Checks, with a deadline, that a terminal's working directory can be opened
/// before the directory reaches `ghostty_surface_new`.
///
/// Ghostty opens and stats the requested working directory synchronously
/// inside `ghostty_surface_new`, which cmux calls on the main thread. When
/// macOS privacy checks stall (an unanswered TCC prompt holds `sandboxd`),
/// every open of a protected folder such as `~/Documents` waits, and a new
/// tab hangs the whole app. On 2026-11-08 that hang lasted until cmux was
/// force-quit and every agent in its terminals died.
///
/// The gate runs the same open on a background queue and waits at most
/// ``deadline``. While a probe that missed its deadline is still stuck, later
/// checks answer ``TerminalWorkingDirectoryAccessOutcome/timedOut`` at once
/// without starting another probe, so one stall costs the main thread one
/// deadline and parks at most one probe thread. The stall clears as soon as
/// the stuck open returns.
///
/// Construct one gate at the composition root and share it across surfaces;
/// the stall memory is what keeps later tabs instant.
///
/// ```swift
/// let gate = TerminalWorkingDirectoryAccessGate(
///     deadline: .milliseconds(50),
///     probe: { _ in true }
/// )
/// gate.check("/tmp") // .accessible
/// ```
public final class TerminalWorkingDirectoryAccessGate: Sendable {
    /// How long ``check(_:)`` waits for the background open.
    public let deadline: Duration

    /// The directory a surface starts in when its own directory stalls.
    /// Home itself is not privacy-protected.
    public let homeDirectory: String

    private let probe: @Sendable (String) -> Bool
    private let probeQueue = DispatchQueue(
        label: "com.cmuxterm.working-directory-access-probe",
        qos: .userInitiated,
        attributes: .concurrent
    )
    // Lock carve-out: `check(_:)` is called synchronously from main-actor
    // surface creation and the probe completes on a GCD thread; both do a
    // tiny compare-and-set that an actor would turn into await hops.
    private let state = OSAllocatedUnfairLock(initialState: ProbeLedger())

    /// Creates a gate.
    ///
    /// - Parameters:
    ///   - deadline: The longest ``check(_:)`` blocks its caller. 750 ms keeps
    ///     a normal tab instant (an open takes microseconds) while bounding a
    ///     stalled one well under the app's 8 s hang watchdog.
    ///   - homeDirectory: The fallback start directory.
    ///   - probe: Returns whether the path opens as a directory. Runs on a
    ///     background queue and may block indefinitely.
    public init(
        deadline: Duration = .milliseconds(750),
        homeDirectory: String = NSHomeDirectory(),
        probe: @escaping @Sendable (String) -> Bool = TerminalWorkingDirectoryAccessGate.opensDirectory
    ) {
        self.deadline = deadline
        self.homeDirectory = homeDirectory
        self.probe = probe
    }

    /// Whether a probe that missed its deadline is still waiting on the OS.
    public var isStalled: Bool {
        state.withLock { !$0.stalledProbes.isEmpty }
    }

    /// Opens `path` on a background queue and waits up to ``deadline``.
    ///
    /// - Parameter path: The directory a surface is about to start in.
    /// - Returns: The outcome; never blocks longer than ``deadline``.
    public func check(_ path: String) -> TerminalWorkingDirectoryAccessOutcome {
        let probeID: UInt64? = state.withLock { ledger in
            guard ledger.stalledProbes.isEmpty else { return nil }
            return ledger.startProbe()
        }
        guard let probeID else { return .timedOut }

        let finished = DispatchSemaphore(value: 0)
        let probe = probe
        let state = state
        probeQueue.async {
            let opened = probe(path)
            state.withLock { $0.finishProbe(probeID, opened: opened) }
            finished.signal()
        }
        // A bounded wait, not a lock: the deadline is the point of this type.
        _ = finished.wait(timeout: .now() + deadline.timeInterval)
        let opened: Bool? = state.withLock { $0.collectOrAbandon(probeID) }
        guard let opened else { return .timedOut }
        return opened ? .accessible : .unavailable
    }

    /// Opens `path` read-only as a directory, the same check Ghostty makes in
    /// `ghostty_surface_new`.
    ///
    /// - Parameter path: An absolute directory path.
    /// - Returns: `true` when the path opens and is a directory.
    @Sendable
    public static func opensDirectory(_ path: String) -> Bool {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }
}
