/// The answer ``TerminalWorkingDirectoryAccessGate`` gives for one directory.
public enum TerminalWorkingDirectoryAccessOutcome: Sendable, Equatable {
    /// The directory opened and is a directory.
    case accessible

    /// The open finished in time but failed (missing, not a directory, or
    /// denied). Ghostty handles these itself without blocking, so callers
    /// pass the directory through unchanged.
    case unavailable

    /// The open did not finish before the deadline, or an earlier open is
    /// still stuck. macOS file access is stalled (typically an unanswered
    /// privacy prompt), so the caller must not hand the path to Ghostty.
    case timedOut
}
