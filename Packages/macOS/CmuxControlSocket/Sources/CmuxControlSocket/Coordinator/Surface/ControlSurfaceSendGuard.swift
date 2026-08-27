import Foundation

/// Decides whether `surface.send_text` must refuse because the target pane has a
/// live foreground job whose stdin would swallow the text (e.g. a `sudo`
/// password prompt or a running build), which is never what an automated sender
/// intends.
///
/// The guard fails open: it blocks only on positive evidence of a non-agent
/// foreground job, either a shell-integration running report or a resolvable
/// foreground process that is not the idle shell. Agent panes (Claude/Codex
/// composers) are legitimate send targets, so any agent evidence — a detected
/// resume binding, a registered agent lifecycle, or a foreground command
/// recognized as an agent CLI — exempts the pane. `force` (the CLI `--force`
/// flag) always wins.
// lint:allow namespace-type — pure send-policy decision with no dependency or
// lifetime; every observation required for a verdict is an explicit argument.
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

    /// Foreground process names that represent an idle interactive shell, not
    /// a job consuming terminal input. This is used only when shell integration
    /// has not reported `commandRunning`; an explicit running report still
    /// blocks even if foreground-process discovery is momentarily stale.
    public static let idleShellForegroundCommands: Set<String> = [
        "bash", "dash", "fish", "ksh", "login", "nu", "pwsh", "sh", "tcsh", "xonsh", "zsh",
    ]

    /// Returns `true` when the send must be refused with `live_foreground_job`.
    ///
    /// - Parameters:
    ///   - isCommandRunning: Whether shell integration reports a foreground
    ///     command on the pane (`PanelShellActivityState.commandRunning`).
    ///     When false, a resolvable non-shell foreground process remains
    ///     positive evidence of a live job.
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
        if force || hasAgentEvidence {
            return false
        }
        let name = foregroundCommandName?.lowercased()
        if let name, exemptForegroundCommands.contains(name) {
            return false
        }
        if isCommandRunning {
            return true
        }
        guard let name else { return false }
        return !idleShellForegroundCommands.contains(name)
    }
}
