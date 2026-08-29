public import Foundation

/// Service that owns workspace session restore policy decisions.
///
/// The app target injects concrete approval storage, prompt handling, automated
/// test detection, scrollback truncation, and Hermes Codex defaults. That keeps
/// this package independent of app DTO storage and UI while preserving the
/// exact restore behavior.
public struct WorkspaceSessionRestorePolicyService<Binding: WorkspaceSurfaceResumeBinding>: Sendable {
    private let applyStoredApproval: @Sendable (Binding, URL, Data?) -> Binding?
    private let shouldRunPromptedSurfaceResume: @Sendable (Binding) -> Bool
    private let isRunningUnderAutomatedTests: @Sendable () -> Bool
    private let truncateScrollback: @Sendable (String?) -> String?
    private let hermesCodexEnvironment: WorkspaceHermesCodexEnvironment

    /// Creates a restore policy service.
    public init(
        applyStoredApproval: @escaping @Sendable (Binding, URL, Data?) -> Binding?,
        shouldRunPromptedSurfaceResume: @escaping @Sendable (Binding) -> Bool,
        isRunningUnderAutomatedTests: @escaping @Sendable () -> Bool,
        truncateScrollback: @escaping @Sendable (String?) -> String?,
        hermesCodexEnvironment: WorkspaceHermesCodexEnvironment
    ) {
        self.applyStoredApproval = applyStoredApproval
        self.shouldRunPromptedSurfaceResume = shouldRunPromptedSurfaceResume
        self.isRunningUnderAutomatedTests = isRunningUnderAutomatedTests
        self.truncateScrollback = truncateScrollback
        self.hermesCodexEnvironment = hermesCodexEnvironment
    }

    /// Resolves the scrollback text persisted for a terminal snapshot.
    public func resolvedSnapshotTerminalScrollback(
        capturedScrollback: String?,
        fallbackScrollback: String?,
        replayBaselineScrollback: String? = nil,
        replayBoundaryMarker: String? = nil,
        allowFallbackScrollback: Bool = true
    ) -> String? {
        if let capturedScrollback {
            var resolved = if allowFallbackScrollback,
                              let replayBaselineScrollback,
                              let replayBoundaryMarker,
                              let continuation = scrollbackAfterReplayBoundary(
                                  captured: capturedScrollback,
                                  marker: replayBoundaryMarker
                              ) {
                joiningScrollback(replayBaselineScrollback, continuation)
            } else {
                capturedScrollback
            }
            if let replayBoundaryMarker {
                resolved = removingReplayBoundaryLines(
                    from: resolved,
                    marker: replayBoundaryMarker
                )
            }
            return nonEmptyTruncatedScrollback(resolved)
        }
        guard allowFallbackScrollback else { return nil }
        return nonEmptyTruncatedScrollback(fallbackScrollback)
    }

    private func nonEmptyTruncatedScrollback(_ text: String?) -> String? {
        guard let truncated = truncateScrollback(text), !truncated.isEmpty else {
            return nil
        }
        return truncated
    }

    /// Session replay appends a concealed, per-restore boundary line after the
    /// durable snapshot. While that boundary remains in Ghostty, everything
    /// after it is live output and can be joined to the immutable replay
    /// baseline without guessing from repeated terminal text. If history is
    /// cleared or the boundary is evicted, it disappears and the live capture
    /// remains authoritative.
    private func scrollbackAfterReplayBoundary(captured: String, marker: String) -> String? {
        guard let markerRange = replayBoundaryRange(in: captured, marker: marker) else {
            return nil
        }
        guard let lineEnd = captured[markerRange.upperBound...].firstIndex(of: "\n") else {
            return ""
        }
        return String(captured[captured.index(after: lineEnd)...])
    }

    /// Removes the entire terminal line that contains an internal replay marker,
    /// including its conceal/reset escape sequences. Boundary lookup happens on
    /// the raw capture before character truncation, so a truncated marker can
    /// never be persisted and replayed as visible text.
    private func removingReplayBoundaryLines(from text: String, marker: String) -> String {
        var sanitized = text
        while let markerRange = replayBoundaryRange(in: sanitized, marker: marker) {
            let lineStart = sanitized[..<markerRange.lowerBound].lastIndex(of: "\n")
                .map { sanitized.index(after: $0) } ?? sanitized.startIndex
            let lineEnd = sanitized[markerRange.upperBound...].firstIndex(of: "\n")
                .map { sanitized.index(after: $0) } ?? sanitized.endIndex
            sanitized.removeSubrange(lineStart..<lineEnd)
        }
        return sanitized
    }

    /// Plain row capture can insert line breaks where a narrow terminal wrapped
    /// the concealed marker. Match the marker while ignoring only CR/LF inside
    /// the candidate so wrapped boundaries remain unambiguous and removable.
    private func replayBoundaryRange(in text: String, marker: String) -> Range<String.Index>? {
        guard !marker.isEmpty else { return nil }
        var textIndex = text.startIndex
        var markerIndex = marker.startIndex
        var matchStart: String.Index?

        while textIndex < text.endIndex {
            let textCharacter = text[textIndex]
            if textCharacter == marker[markerIndex] {
                if matchStart == nil {
                    matchStart = textIndex
                }
                marker.formIndex(after: &markerIndex)
                let matchEnd = text.index(after: textIndex)
                if markerIndex == marker.endIndex, let matchStart {
                    return matchStart..<matchEnd
                }
                text.formIndex(after: &textIndex)
                continue
            }

            if matchStart != nil, (textCharacter == "\n" || textCharacter == "\r") {
                text.formIndex(after: &textIndex)
                continue
            }

            matchStart = nil
            markerIndex = marker.startIndex
            if textCharacter == marker[markerIndex] {
                matchStart = textIndex
                marker.formIndex(after: &markerIndex)
                let matchEnd = text.index(after: textIndex)
                if markerIndex == marker.endIndex, let matchStart {
                    return matchStart..<matchEnd
                }
            }
            text.formIndex(after: &textIndex)
        }
        return nil
    }

    private func joiningScrollback(_ baseline: String, _ continuation: String) -> String {
        guard !baseline.isEmpty else { return continuation }
        guard !continuation.isEmpty else { return baseline }
        if baseline.hasSuffix("\n") || continuation.hasPrefix("\n") {
            return baseline + continuation
        }
        return baseline + "\n" + continuation
    }

    /// Returns whether restored scrollback should be replayed for a terminal.
    ///
    /// A restorable agent record is only metadata. It does not guarantee that
    /// restore will launch the agent: liveness checks can deliberately suppress
    /// that launch. Keep the saved terminal contents unless startup work will
    /// actually replace them.
    public func shouldReplaySessionScrollback(
        hasRestorableAgent _: Bool,
        tmuxStartCommand: String? = nil,
        hasResumeStartupWork: Bool = false
    ) -> Bool {
        restorableTmuxStartCommand(tmuxStartCommand) == nil && !hasResumeStartupWork
    }

    /// Returns whether a restored remote workspace should auto-connect.
    public func shouldAutoConnectRestoredRemote<Snapshot: WorkspaceSessionRemoteRestoreSnapshot>(
        foregroundAuthToken: String?,
        snapshot: Snapshot,
        isRunningUnderAutomatedTests overrideIsRunningUnderAutomatedTests: Bool? = nil
    ) -> Bool {
        let runningUnderTests = overrideIsRunningUnderAutomatedTests ?? isRunningUnderAutomatedTests()
        guard !runningUnderTests else { return false }
        let normalizedForegroundAuthToken = foregroundAuthToken?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedForegroundAuthToken?.isEmpty == false else { return true }
        let hasTerminalThatWillAuthenticateReconnect = snapshot.panels.contains {
            guard let terminal = $0.terminal else { return false }
            if terminal.isRemoteTerminal != false {
                return true
            }
            let remotePTYSessionID = terminal.remotePTYSessionID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return remotePTYSessionID?.isEmpty == false
        }
        return !hasTerminalThatWillAuthenticateReconnect
    }

    /// Returns startup input for an approved restored surface resume binding.
    public func surfaceResumeStartupInput(
        _ resumeBinding: Binding?,
        autoResumeAgentSessions: Bool,
        promptForApproval: Bool = true,
        approvalStoreURL: URL,
        approvalSigningSecret: Data? = nil
    ) -> String? {
        guard let effectiveBinding = approvedSurfaceResumeBinding(
            resumeBinding,
            autoResumeAgentSessions: autoResumeAgentSessions,
            promptForApproval: promptForApproval,
            approvalStoreURL: approvalStoreURL,
            approvalSigningSecret: approvalSigningSecret
        ) else {
            return nil
        }
        return effectiveBinding.restoreStartupInput()
    }

    /// Returns post-start input for a restored surface resume binding.
    public func surfaceResumeStartupLaunch(
        _ resumeBinding: Binding?,
        autoResumeAgentSessions: Bool,
        promptForApproval: Bool = true,
        approvalStoreURL: URL,
        approvalSigningSecret: Data? = nil
    ) -> WorkspaceSurfaceResumeStartupLaunch? {
        guard let effectiveBinding = approvedSurfaceResumeBinding(
            resumeBinding,
            autoResumeAgentSessions: autoResumeAgentSessions,
            promptForApproval: promptForApproval,
            approvalStoreURL: approvalStoreURL,
            approvalSigningSecret: approvalSigningSecret
        ) else {
            return nil
        }
        return surfaceResumeStartupLaunch(
            forApprovedBinding: effectiveBinding
        )
    }

    /// Returns post-start input for an already approved binding.
    public func surfaceResumeStartupLaunch(
        forApprovedBinding effectiveBinding: Binding
    ) -> WorkspaceSurfaceResumeStartupLaunch? {
        guard let input = effectiveBinding.restoreStartupInput() else {
            return nil
        }
        return .input(input)
    }

    /// Prepares a binding used only when a legacy shell command must be restored.
    ///
    /// - Parameter binding: The persisted binding whose structured fields remain authoritative.
    /// - Returns: A copy with compatibility-only provider setup applied to its shell command.
    public func bindingForCompatibilityShellRestore(_ binding: Binding) -> Binding {
        WorkspaceHermesAgentCommandBootstrapper(
            hermesCodexEnvironment: hermesCodexEnvironment
        ).bindingForStartup(binding)
    }

    /// Applies stored approval state and returns the binding allowed to run.
    public func approvedSurfaceResumeBinding(
        _ resumeBinding: Binding?,
        autoResumeAgentSessions: Bool,
        promptForApproval: Bool = true,
        approvalStoreURL: URL,
        approvalSigningSecret: Data? = nil
    ) -> Binding? {
        guard let resumeBinding else { return nil }
        guard var effectiveBinding = applyStoredApproval(
            resumeBinding,
            approvalStoreURL,
            approvalSigningSecret
        ) else {
            return nil
        }
        if !effectiveBinding.usesLocalRestoreVerb {
            effectiveBinding = bindingForCompatibilityShellRestore(effectiveBinding)
        }
        if effectiveBinding.source == "agent-hook", !autoResumeAgentSessions {
            return nil
        }
        if effectiveBinding.requiresPromptApproval {
            guard promptForApproval else { return nil }
            guard shouldRunPromptedSurfaceResume(effectiveBinding) else { return nil }
            return effectiveBinding
        }
        guard effectiveBinding.allowsAutomaticResume else { return nil }
        return effectiveBinding
    }

    /// Returns a restorable tmux start command when the command launches an OMX HUD.
    public func restorableTmuxStartCommand(_ rawCommand: String?) -> String? {
        WorkspaceHermesAgentCommandBootstrapper(
            hermesCodexEnvironment: hermesCodexEnvironment
        ).restorableTmuxStartCommand(rawCommand)
    }

    /// Returns whether terminal scrollback should be persisted when closing/restoring.
    public func shouldPersistSessionScrollback(closeConfirmationRequired: Bool) -> Bool {
        !closeConfirmationRequired
    }
}
