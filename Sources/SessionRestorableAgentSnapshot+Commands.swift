import Foundation

extension SessionRestorableAgentSnapshot {
    private enum SnapshotCodingKeys: String, CodingKey {
        case kind
        case sessionId
        case workingDirectory
        case launchCommand
        case registration
        case permissionMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: SnapshotCodingKeys.self)
        let persistedKind = try container.decode(String.self, forKey: .kind)
        let registration = try container.decodeIfPresent(
            CmuxVaultAgentRegistration.self,
            forKey: .registration
        )?.migratedPersistedBuiltInRegistration
        guard let kind = RestorableAgentKind(
            persistedRawValue: persistedKind,
            registration: registration
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Invalid restorable agent kind '\(persistedKind)'"
            )
        }
        self.init(
            kind: kind,
            sessionId: try container.decode(String.self, forKey: .sessionId),
            workingDirectory: try container.decodeIfPresent(String.self, forKey: .workingDirectory),
            launchCommand: try container.decodeIfPresent(
                AgentLaunchCommandSnapshot.self,
                forKey: .launchCommand
            ),
            registration: registration,
            // Optional so snapshots persisted before the field decode unchanged.
            permissionMode: try container.decodeIfPresent(String.self, forKey: .permissionMode)
        )
    }

    var resumeCommand: String? {
        resumeCommand(
            includeWorkingDirectoryPrefix: true,
            style: AgentResumeCommandStyleSettings.style()
        )
    }

    func resumeCommand(
        includeWorkingDirectoryPrefix: Bool,
        restoringWorkingDirectory: String? = nil,
        style: AgentResumeCommandStyle = AgentResumeCommandStyleSettings.style()
    ) -> String? {
        let effectiveWorkingDirectory = restoringWorkingDirectory ?? workingDirectory
        if kind.restoreMode == .relaunchCommand {
            return AgentRelaunchCommandBuilder().shellCommand(
                kind: kind,
                launchCommand: launchCommand,
                workingDirectory: effectiveWorkingDirectory,
                includeWorkingDirectoryPrefix: includeWorkingDirectoryPrefix
            )
        }
        // Fork (cmux Mochi): prefer the shell-integration alias (cx/cxy/cc/ccy)
        // when it resumes the session identically. It resolves the agent through
        // the integration's PATH shim, so cmux hooks stay wired, and keeps the
        // resumed line short instead of carrying the captured binary path.
        // `equivalentAliasResumeShellCommand` returns nil the moment anything
        // would be lost, so this can only ever substitute, never approximate.
        if style == .alias,
           let aliasCommand = AgentResumeCommandBuilder.equivalentAliasResumeShellCommand(
            kind: kind,
            sessionId: sessionId,
            launchCommand: launchCommand,
            workingDirectory: effectiveWorkingDirectory,
            registrationOverride: registration,
            includeWorkingDirectoryPrefix: includeWorkingDirectoryPrefix,
            observedPermissionMode: permissionMode
        ) {
            return aliasCommand
        }
        return AgentResumeCommandBuilder.resumeShellCommand(
            kind: kind,
            sessionId: sessionId,
            launchCommand: launchCommand,
            workingDirectory: effectiveWorkingDirectory,
            registrationOverride: registration,
            includeWorkingDirectoryPrefix: includeWorkingDirectoryPrefix,
            observedPermissionMode: permissionMode
        )
    }

    var forkCommand: String? {
        guard kind.restoreMode == .resumeSession else { return nil }
        return AgentResumeCommandBuilder.forkShellCommand(
            kind: kind,
            sessionId: sessionId,
            launchCommand: launchCommand,
            workingDirectory: workingDirectory,
            registrationOverride: registration,
            observedPermissionMode: permissionMode
        )
    }

    var agentDisplayName: String {
        if let name = registration?.name.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return kind.displayName
    }
}
