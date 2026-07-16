import Foundation

/// Decides whether `surface.send_text` must refuse because the target pane has a
/// live foreground job whose stdin would swallow the text (e.g. a `sudo`
/// password prompt or a running build), which is never what an automated sender
/// intends.
///
/// The guard fails open: it blocks only on positive evidence of a non-agent
/// foreground job. Agent panes (Claude/Codex composers) are legitimate send
/// targets, so any agent evidence — a detected resume binding, a registered
/// agent lifecycle, or a foreground command recognized as an agent CLI —
/// exempts the pane. `force` (the CLI `--force` flag) always wins.
public enum ControlSurfaceSendGuard {
    /// Foreground command names that are legitimate text-send targets even
    /// though the shell reports a running command. Agent CLIs own the pane's
    /// stdin by design (their composer is the intended recipient). `node` is
    /// included because JavaScript-based agent CLIs (Claude Code) report the
    /// runtime's name, not the script's; `ovm` because ovm-managed agent
    /// installs run the agent under the version-manager shim's process name
    /// (verified live: an ovm-managed `codex` launch reports `ovm`).
    public static let exemptForegroundCommands: Set<String> = [
        "claude", "codex", "node", "opencode", "omx", "omc", "cmux", "ovm",
    ]

    /// Returns `true` when the send must be refused with `live_foreground_job`.
    ///
    /// - Parameters:
    ///   - isCommandRunning: Whether shell integration reports a foreground
    ///     command on the pane (`PanelShellActivityState.commandRunning`).
    ///     Pass `false` for `promptIdle`/`unknown` — no report means no block.
    ///   - hasAgentEvidence: Whether the app has any evidence the pane hosts an
    ///     agent session (surface resume binding or agent lifecycle entry).
    ///   - foregroundCommandName: The pane's foreground process name, if
    ///     resolvable; matched case-insensitively against
    ///     ``exemptForegroundCommands``.
    ///   - force: The caller's explicit override (`--force`).
    public static func blocksTextSend(
        isCommandRunning: Bool,
        hasAgentEvidence: Bool,
        foregroundCommandName: String?,
        force: Bool
    ) -> Bool {
        if force || !isCommandRunning || hasAgentEvidence {
            return false
        }
        if let name = foregroundCommandName?.lowercased(),
           exemptForegroundCommands.contains(name) {
            return false
        }
        return true
    }
}
