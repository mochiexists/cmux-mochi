import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class AgentSessionAutoResumeSettingsTests: XCTestCase {
    func testScrollbackAutosaveDefaultAndStoredValue() throws {
        let suiteName = "cmux-scrollback-autosave-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(TerminalScrollbackAutosaveSettings.enabledKey, "terminal.autosaveScrollback")
        XCTAssertTrue(TerminalScrollbackAutosaveSettings.isEnabled(defaults: defaults))

        defaults.set(false, forKey: TerminalScrollbackAutosaveSettings.enabledKey)
        XCTAssertFalse(TerminalScrollbackAutosaveSettings.isEnabled(defaults: defaults))
    }

    func testModeKeyDefaultAndNotificationOnChange() throws {
        let suiteName = "cmux-agent-session-resume-mode-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(AgentSessionAutoResumeSettings.modeKey, "terminal.agentResumeMode")
        XCTAssertEqual(AgentSessionAutoResumeSettings.mode(defaults: defaults), .medium)

        let notificationCenter = NotificationCenter()
        var notificationCount = 0
        let observer = notificationCenter.addObserver(
            forName: AgentSessionAutoResumeSettings.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer { notificationCenter.removeObserver(observer) }

        AgentSessionAutoResumeSettings.setMode(.medium, defaults: defaults, notificationCenter: notificationCenter)
        XCTAssertEqual(AgentSessionAutoResumeSettings.mode(defaults: defaults), .medium)
        XCTAssertEqual(notificationCount, 0)

        // Setting the same mode does not notify.
        AgentSessionAutoResumeSettings.setMode(.medium, defaults: defaults, notificationCenter: notificationCenter)
        XCTAssertEqual(notificationCount, 0)

        AgentSessionAutoResumeSettings.setMode(.off, defaults: defaults, notificationCenter: notificationCenter)
        XCTAssertEqual(AgentSessionAutoResumeSettings.mode(defaults: defaults), .off)
        XCTAssertEqual(notificationCount, 1)

        AgentSessionAutoResumeSettings.reset(defaults: defaults, notificationCenter: notificationCenter)
        XCTAssertEqual(AgentSessionAutoResumeSettings.mode(defaults: defaults), .medium)
        XCTAssertEqual(notificationCount, 2)
    }

    func testLegacyBooleanMigratesToMode() throws {
        let suiteName = "cmux-agent-session-resume-legacy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Legacy auto-resume ON migrates to .full, OFF migrates to .medium.
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.legacyAutoResumeAgentSessionsKey)
        XCTAssertEqual(AgentSessionAutoResumeSettings.mode(defaults: defaults), .full)

        defaults.set(false, forKey: AgentSessionAutoResumeSettings.legacyAutoResumeAgentSessionsKey)
        XCTAssertEqual(AgentSessionAutoResumeSettings.mode(defaults: defaults), .medium)

        // An explicit mode value takes precedence over the legacy boolean.
        defaults.set(AgentSessionResumeMode.off.rawValue, forKey: AgentSessionAutoResumeSettings.modeKey)
        XCTAssertEqual(AgentSessionAutoResumeSettings.mode(defaults: defaults), .off)
    }

    func testModeFlagsMatchMatrix() {
        XCTAssertEqual(AgentSessionResumeMode.off.replaysScrollback, false)
        XCTAssertEqual(AgentSessionResumeMode.off.prefillsResumeCommand, false)
        XCTAssertEqual(AgentSessionResumeMode.off.submitsResumeCommand, false)

        XCTAssertEqual(AgentSessionResumeMode.medium.replaysScrollback, true)
        XCTAssertEqual(AgentSessionResumeMode.medium.prefillsResumeCommand, true)
        XCTAssertEqual(AgentSessionResumeMode.medium.submitsResumeCommand, false)

        XCTAssertEqual(AgentSessionResumeMode.full.replaysScrollback, false)
        XCTAssertEqual(AgentSessionResumeMode.full.prefillsResumeCommand, true)
        XCTAssertEqual(AgentSessionResumeMode.full.submitsResumeCommand, true)
    }

    @MainActor
    func testResumeModeControlsResumeCommandPrefillAndSubmitOnRestore() throws {
        let defaults = UserDefaults.standard
        let key = AgentSessionAutoResumeSettings.modeKey
        let legacyKey = AgentSessionAutoResumeSettings.legacyAutoResumeAgentSessionsKey
        let previous = defaults.object(forKey: key)
        let previousLegacy = defaults.object(forKey: legacyKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            if let previousLegacy {
                defaults.set(previousLegacy, forKey: legacyKey)
            } else {
                defaults.removeObject(forKey: legacyKey)
            }
        }

        let source = Workspace()
        let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
        let sourceIndex = try makeRestorableAgentIndex(
            workspaceId: source.id,
            panelId: sourcePanelId,
            sessionId: "codex-auto-resume-disabled-session"
        )
        let snapshot = source.sessionSnapshot(includeScrollback: false, restorableAgentIndex: sourceIndex)

        // FULL: resume command is prefilled AND submitted (trailing newline).
        defaults.set(AgentSessionResumeMode.full.rawValue, forKey: key)
        let restoredFull = Workspace()
        restoredFull.restoreSessionSnapshot(snapshot)
        let fullPanelId = try XCTUnwrap(restoredFull.focusedPanelId)
        let fullPanel = try XCTUnwrap(restoredFull.terminalPanel(for: fullPanelId))
        let fullInput = fullPanel.surface.debugInitialInputMetadata()
        XCTAssertTrue(fullInput.hasInitialInput)
        XCTAssertEqual(fullInput.byteCount, preparedResumeInput.utf8.count + 1)

        // MEDIUM: resume command is prefilled WITHOUT submitting (no newline).
        defaults.set(AgentSessionResumeMode.medium.rawValue, forKey: key)
        let restoredMedium = Workspace()
        restoredMedium.restoreSessionSnapshot(snapshot)
        let mediumPanelId = try XCTUnwrap(restoredMedium.focusedPanelId)
        let mediumPanel = try XCTUnwrap(restoredMedium.terminalPanel(for: mediumPanelId))
        let mediumInput = mediumPanel.surface.debugInitialInputMetadata()
        XCTAssertTrue(mediumInput.hasInitialInput)
        XCTAssertEqual(mediumInput.byteCount, preparedResumeInput.utf8.count)
        XCTAssertEqual(
            restoredMedium.sessionSnapshot(includeScrollback: false)
                .panels.first?.terminal?.agent?.sessionId,
            "codex-auto-resume-disabled-session"
        )

        // OFF: no resume command prefilled at all.
        defaults.set(AgentSessionResumeMode.off.rawValue, forKey: key)
        let restoredOff = Workspace()
        restoredOff.restoreSessionSnapshot(snapshot)
        let offPanelId = try XCTUnwrap(restoredOff.focusedPanelId)
        let offPanel = try XCTUnwrap(restoredOff.terminalPanel(for: offPanelId))
        XCTAssertFalse(offPanel.surface.debugInitialInputMetadata().hasInitialInput)

        restoredMedium.updatePanelShellActivityState(panelId: mediumPanelId, state: .promptIdle)
        XCTAssertEqual(
            restoredMedium.sessionSnapshot(includeScrollback: false)
                .panels.first?.terminal?.agent?.sessionId,
            "codex-auto-resume-disabled-session"
        )

        restoredMedium.updatePanelShellActivityState(panelId: mediumPanelId, state: .commandRunning)
        XCTAssertNil(restoredMedium.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.agent)
    }

    /// When autoResumeAgentSessions is enabled but the agent was already exited at snapshot time
    /// (wasAgentRunning == false), cmux must NOT inject the resume command on restore.
    /// The session ID must still be preserved for manual resume.
    @MainActor
    func testAgentExitedBeforeSnapshotDoesNotAutoResumeEvenWhenSettingEnabled() throws {
        try withRestoredDefaults(key: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) // autoResumeAgentSessions = true (default)

            let source = Workspace()
            let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
            let sourceIndex = try makeRestorableAgentIndex(
                workspaceId: source.id,
                panelId: sourcePanelId,
                sessionId: "codex-exited-before-snapshot-session"
            )
            // Simulate: agent was already exited (shell at promptIdle) before snapshot
            source.updatePanelShellActivityState(panelId: sourcePanelId, state: .promptIdle)
            let snapshot = source.sessionSnapshot(includeScrollback: false, restorableAgentIndex: sourceIndex)

            XCTAssertEqual(snapshot.panels.first?.terminal?.wasAgentRunning, false,
                           "snapshot should record wasAgentRunning=false when shell was idle at save time")
            XCTAssertNotNil(snapshot.panels.first?.terminal?.agent,
                            "session ID must be preserved for manual resume")

            let restored = Workspace()
            restored.restoreSessionSnapshot(snapshot)
            let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
            let restoredPanel = try XCTUnwrap(restored.terminalPanel(for: restoredPanelId))
            let restoredInput = restoredPanel.surface.debugInitialInputMetadata()

            XCTAssertFalse(restoredInput.hasInitialInput,
                           "must not auto-resume when agent was already exited at snapshot time")
            XCTAssertNil(restoredPanel.surface.debugInitialCommand())
            XCTAssertEqual(
                restored.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.agent?.sessionId,
                "codex-exited-before-snapshot-session",
                "session ID must still be available for manual resume"
            )
        }
    }

    /// When autoResumeAgentSessions is enabled and the agent WAS running at snapshot time
    /// (wasAgentRunning == true), cmux MUST auto-resume as before.
    @MainActor
    func testAgentRunningAtSnapshotAutoResumesWhenSettingEnabled() throws {
        try withRestoredDefaults(key: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) // autoResumeAgentSessions = true (default)

            let source = Workspace()
            let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
            let sourceIndex = try makeRestorableAgentIndex(
                workspaceId: source.id,
                panelId: sourcePanelId,
                sessionId: "codex-running-at-snapshot-session"
            )
            // Simulate: agent was still running when cmux quit
            source.updatePanelShellActivityState(panelId: sourcePanelId, state: .commandRunning)
            let snapshot = source.sessionSnapshot(includeScrollback: false, restorableAgentIndex: sourceIndex)

            XCTAssertEqual(snapshot.panels.first?.terminal?.wasAgentRunning, true,
                           "snapshot should record wasAgentRunning=true when agent was running at save time")

            let restored = Workspace()
            restored.restoreSessionSnapshot(snapshot)
            let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
            let restoredPanel = try XCTUnwrap(restored.terminalPanel(for: restoredPanelId))
            let restoredInput = restoredPanel.surface.debugInitialInputMetadata()

            XCTAssertFalse(restoredInput.hasInitialInput)
            XCTAssertEqual(restoredInput.byteCount, 0)
            try assertAgentAutoResumeUsesStartupCommand(
                restoredPanel,
                scriptContains: ["'resume'", "codex-running-at-snapshot-session"]
            )
            XCTAssertEqual(
                restored.restoredAgentResumeStatesByPanelId[restoredPanelId],
                .autoResumeCommandRunning
            )

            restored.updatePanelShellActivityState(panelId: restoredPanelId, state: .promptIdle)
            XCTAssertNil(restored.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.agent)
        }
    }

    @MainActor
    func testRemoteWorkspaceAutoResumeKeepsRemoteStartupCommand() throws {
        try withRestoredDefaults(key: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) // autoResumeAgentSessions = true (default)

            let source = Workspace()
            let remoteCommand = "ssh cmux-macmini"
            let expectedRestoredRemoteCommand = "ssh -tt cmux-macmini"
            source.configureRemoteConnection(
                WorkspaceRemoteConfiguration(
                    destination: "cmux-macmini",
                    port: nil,
                    identityFile: nil,
                    sshOptions: [],
                    localProxyPort: nil,
                    relayPort: 64000,
                    relayID: "relay-auto-resume-remote",
                    relayToken: String(repeating: "a", count: 64),
                    localSocketPath: "/tmp/cmux-auto-resume-remote.sock",
                    terminalStartupCommand: remoteCommand
                ),
                autoConnect: false
            )
            let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
            let sourceIndex = try makeRestorableAgentIndex(
                workspaceId: source.id,
                panelId: sourcePanelId,
                sessionId: "codex-remote-running-session"
            )
            source.updatePanelShellActivityState(panelId: sourcePanelId, state: .commandRunning)
            let snapshot = source.sessionSnapshot(includeScrollback: false, restorableAgentIndex: sourceIndex)

            let restored = Workspace()
            restored.restoreSessionSnapshot(snapshot)
            let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
            let restoredPanel = try XCTUnwrap(restored.terminalPanel(for: restoredPanelId))
            let restoredInput = restoredPanel.surface.debugInitialInputMetadata()
            let restoredRemoteCommand = try XCTUnwrap(restored.remoteConfiguration?.terminalStartupCommand)

            XCTAssertEqual(restoredRemoteCommand, expectedRestoredRemoteCommand)
            XCTAssertEqual(restoredPanel.surface.debugInitialCommand(), expectedRestoredRemoteCommand)
            XCTAssertTrue(restoredInput.hasInitialInput)
            XCTAssertGreaterThan(restoredInput.byteCount, 0)
            let input = try XCTUnwrap(restoredPanel.surface.initialInput)
            XCTAssertTrue(input.contains("'resume'"), input)
            XCTAssertTrue(input.contains("codex-remote-running-session"), input)
            XCTAssertFalse(input.contains("cmux-agent-resume"), input)
            XCTAssertNil(restoredPanel.requestedWorkingDirectory)
            XCTAssertEqual(
                restored.restoredAgentResumeStatesByPanelId[restoredPanelId],
                .awaitingAutoResumeCommand
            )
        }
    }

    @MainActor
    func testRemoteWorkspaceAutoResumeKeepsLongResumeInputInline() throws {
        try withRestoredDefaults(key: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) // autoResumeAgentSessions = true (default)

            let source = Workspace()
            let remoteCommand = "ssh cmux-macmini"
            source.configureRemoteConnection(
                WorkspaceRemoteConfiguration(
                    destination: "cmux-macmini",
                    port: nil,
                    identityFile: nil,
                    sshOptions: [],
                    localProxyPort: nil,
                    relayPort: 64000,
                    relayID: "relay-auto-resume-long-remote",
                    relayToken: String(repeating: "b", count: 64),
                    localSocketPath: "/tmp/cmux-auto-resume-long-remote.sock",
                    terminalStartupCommand: remoteCommand
                ),
                autoConnect: false
            )
            let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
            let longPath = "/Users/cmux/" + String(repeating: "nested-project-", count: 120)
            let sourceIndex = try makeRestorableAgentIndex(
                workspaceId: source.id,
                panelId: sourcePanelId,
                sessionId: "codex-remote-long-running-session",
                extraArguments: ["--add-dir", longPath]
            )
            source.updatePanelShellActivityState(panelId: sourcePanelId, state: .commandRunning)
            let snapshot = source.sessionSnapshot(includeScrollback: false, restorableAgentIndex: sourceIndex)

            let restored = Workspace()
            restored.restoreSessionSnapshot(snapshot)
            let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
            let restoredPanel = try XCTUnwrap(restored.terminalPanel(for: restoredPanelId))
            let restoredInput = try XCTUnwrap(restoredPanel.surface.initialInput)

            XCTAssertEqual(restoredPanel.surface.debugInitialCommand(), restored.remoteConfiguration?.terminalStartupCommand)
            XCTAssertGreaterThan(restoredInput.utf8.count, SessionRestorableAgentSnapshot.maxInlineStartupInputBytes)
            XCTAssertTrue(restoredInput.contains("'resume'"), restoredInput)
            XCTAssertTrue(restoredInput.contains("codex-remote-long-running-session"), restoredInput)
            XCTAssertTrue(restoredInput.contains(longPath), restoredInput)
            XCTAssertFalse(restoredInput.contains("cmux-agent-resume"), restoredInput)
            XCTAssertEqual(
                restored.restoredAgentResumeStatesByPanelId[restoredPanelId],
                .awaitingAutoResumeCommand
            )
        }
    }

    @MainActor
    func testUnknownAgentShellStatePreservesLegacyAutoResumeBehavior() throws {
        try withRestoredDefaults(key: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) // autoResumeAgentSessions = true (default)

            let source = Workspace()
            let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
            let sourceIndex = try makeRestorableAgentIndex(
                workspaceId: source.id,
                panelId: sourcePanelId,
                sessionId: "codex-unknown-shell-state-session"
            )
            source.updatePanelShellActivityState(panelId: sourcePanelId, state: .unknown)
            let snapshot = source.sessionSnapshot(includeScrollback: false, restorableAgentIndex: sourceIndex)

            XCTAssertNil(snapshot.panels.first?.terminal?.wasAgentRunning,
                         "unknown shell state should be persisted as nil for legacy auto-resume behavior")

            let restored = Workspace()
            restored.restoreSessionSnapshot(snapshot)
            let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
            let restoredPanel = try XCTUnwrap(restored.terminalPanel(for: restoredPanelId))
            let restoredInput = restoredPanel.surface.debugInitialInputMetadata()

            XCTAssertFalse(restoredInput.hasInitialInput)
            XCTAssertEqual(restoredInput.byteCount, 0)
            try assertAgentAutoResumeUsesStartupCommand(
                restoredPanel,
                scriptContains: ["'resume'", "codex-unknown-shell-state-session"]
            )
        }
    }

    @MainActor
    func testAgentHookBindingExitedBeforeSnapshotDoesNotAutoResumeEvenWhenTrusted() throws {
        try withRestoredDefaults(key: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey) // autoResumeAgentSessions = true (default)

            let source = Workspace()
            let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
            let sourceIndex = try makeRestorableAgentIndex(
                workspaceId: source.id,
                panelId: sourcePanelId,
                sessionId: "codex-exited-binding-session"
            )
            let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
                SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                    name: "Codex",
                    kind: "codex",
                    command: "codex resume codex-exited-binding-session",
                    cwd: "/tmp/repo",
                    checkpointId: "codex-exited-binding-session",
                    source: "agent-hook",
                    autoResume: true,
                    updatedAt: 1_777_777_777
                ),
            ])
            source.updatePanelShellActivityState(panelId: sourcePanelId, state: .promptIdle)
            let snapshot = source.sessionSnapshot(
                includeScrollback: false,
                restorableAgentIndex: sourceIndex,
                surfaceResumeBindingIndex: bindingIndex
            )

            XCTAssertEqual(snapshot.panels.first?.terminal?.wasAgentRunning, false)

            let restored = Workspace()
            restored.restoreSessionSnapshot(snapshot)
            let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
            let restoredPanel = try XCTUnwrap(restored.terminalPanel(for: restoredPanelId))
            let input = restoredPanel.surface.debugInitialInputMetadata()

            XCTAssertFalse(input.hasInitialInput)
            XCTAssertEqual(input.byteCount, 0)
            XCTAssertNil(restoredPanel.surface.debugInitialCommand())
            XCTAssertEqual(
                restored.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.agent?.sessionId,
                "codex-exited-binding-session"
            )
            XCTAssertEqual(
                restored.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.resumeBinding?.source,
                "agent-hook"
            )
        }
    }

    @MainActor
    func testDisabledAutoResumeDoesNotRunAgentHookResumeBinding() throws {
        let defaults = UserDefaults.standard
        let key = AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let source = Workspace()
        let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
        let sourceIndex = try makeRestorableAgentIndex(
            workspaceId: source.id,
            panelId: sourcePanelId,
            sessionId: "codex-binding-auto-resume-disabled-session"
        )
        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                name: "Codex",
                kind: "codex",
                command: "codex resume codex-binding-auto-resume-disabled-session",
                cwd: "/tmp/repo",
                checkpointId: "codex-binding-auto-resume-disabled-session",
                source: "agent-hook",
                updatedAt: 1_777_777_777
            ),
        ])
        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: sourceIndex,
            surfaceResumeBindingIndex: bindingIndex
        )

        defaults.set(false, forKey: key)
        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        let restoredPanel = try XCTUnwrap(restored.terminalPanel(for: restoredPanelId))
        let input = restoredPanel.surface.debugInitialInputMetadata()

        XCTAssertFalse(input.hasInitialInput)
        XCTAssertEqual(input.byteCount, 0)
        XCTAssertNil(restoredPanel.surface.debugInitialCommand())
        XCTAssertEqual(
            restored.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.resumeBinding?.source,
            "agent-hook"
        )
        XCTAssertEqual(
            restored.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.agent?.sessionId,
            "codex-binding-auto-resume-disabled-session"
        )

        restored.updatePanelShellActivityState(panelId: restoredPanelId, state: .commandRunning)
        let userCommandSnapshot = restored.sessionSnapshot(includeScrollback: false)
        XCTAssertNil(userCommandSnapshot.panels.first?.terminal?.agent)
        XCTAssertNil(userCommandSnapshot.panels.first?.terminal?.resumeBinding)
    }

    @MainActor
    func testDisabledAutoResumeKeepsScrollbackForSuppressedAgentHookBinding() throws {
        let defaults = UserDefaults.standard
        let key = AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let source = Workspace()
        let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                name: "OpenCode",
                kind: "opencode",
                command: "opencode --session suppressed-binding-session",
                cwd: "/tmp/repo",
                checkpointId: "suppressed-binding-session",
                source: "agent-hook",
                updatedAt: 1_777_777_777
            ),
        ])
        var snapshot = source.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: bindingIndex
        )
        let panelIndex = try XCTUnwrap(snapshot.panels.indices.first)
        let savedScrollback = "previous output\n"
        snapshot.panels[panelIndex].terminal?.scrollback = savedScrollback

        defaults.set(false, forKey: key)
        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        let restoredPanel = try XCTUnwrap(restored.terminalPanel(for: restoredPanelId))
        let input = restoredPanel.surface.debugInitialInputMetadata()

        XCTAssertFalse(input.hasInitialInput)
        XCTAssertEqual(input.byteCount, 0)
        XCTAssertNil(restoredPanel.surface.debugInitialCommand())
        XCTAssertEqual(
            restored.sessionSnapshot(includeScrollback: true).panels.first?.terminal?.scrollback,
            savedScrollback
        )
    }

    @MainActor
    func testAgentHookResumeBindingClearsAfterStartupCommandCompletes() throws {
        let defaults = UserDefaults.standard
        let key = AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.set(true, forKey: key)

        let source = Workspace()
        let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
        let sourceIndex = try makeRestorableAgentIndex(
            workspaceId: source.id,
            panelId: sourcePanelId,
            sessionId: "codex-binding-auto-resume-session"
        )
        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                name: "Codex",
                kind: "codex",
                command: "codex resume codex-binding-auto-resume-session",
                cwd: "/tmp/repo",
                checkpointId: "codex-binding-auto-resume-session",
                source: "agent-hook",
                autoResume: true,
                updatedAt: 1_777_777_777
            ),
        ])
        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: sourceIndex,
            surfaceResumeBindingIndex: bindingIndex
        )

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        let restoredPanel = try XCTUnwrap(restored.terminalPanel(for: restoredPanelId))
        let input = restoredPanel.surface.debugInitialInputMetadata()
        XCTAssertFalse(input.hasInitialInput)
        XCTAssertEqual(input.byteCount, 0)
        try assertAgentAutoResumeUsesStartupCommand(
            restoredPanel,
            scriptContains: ["codex resume codex-binding-auto-resume-session"]
        )
        XCTAssertEqual(
            restored.restoredAgentResumeStatesByPanelId[restoredPanelId],
            .autoResumeCommandRunning
        )

        restored.updatePanelShellActivityState(panelId: restoredPanelId, state: .promptIdle)
        let completedSnapshot = restored.sessionSnapshot(includeScrollback: false)
        XCTAssertNil(completedSnapshot.panels.first?.terminal?.agent)
        XCTAssertNil(completedSnapshot.panels.first?.terminal?.resumeBinding)
    }

    @MainActor
    func testNonAgentResumeBindingDoesNotMarkRestoredAgentAwaitingAutoResume() throws {
        let defaults = UserDefaults.standard
        let key = AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.set(true, forKey: key)

        let source = Workspace()
        let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
        let sourceIndex = try makeRestorableAgentIndex(
            workspaceId: source.id,
            panelId: sourcePanelId,
            sessionId: "codex-agent-inside-tmux-session"
        )
        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                name: "tmux work",
                kind: "tmux",
                command: "tmux attach -t work",
                cwd: "/tmp/repo",
                checkpointId: "work",
                source: "process-detected",
                autoResume: true,
                updatedAt: 1_777_777_777
            ),
        ])
        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: sourceIndex,
            surfaceResumeBindingIndex: bindingIndex
        )

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        let restoredPanel = try XCTUnwrap(restored.terminalPanel(for: restoredPanelId))
        XCTAssertTrue(restoredPanel.surface.debugInitialInputMetadata().hasInitialInput)
        XCTAssertNil(restoredPanel.surface.debugInitialCommand())

        restored.updatePanelShellActivityState(panelId: restoredPanelId, state: .commandRunning)
        let runningSnapshot = restored.sessionSnapshot(includeScrollback: false)
        XCTAssertNil(runningSnapshot.panels.first?.terminal?.agent)
        XCTAssertEqual(runningSnapshot.panels.first?.terminal?.resumeBinding?.kind, "tmux")
    }

    // After a session is restored on reload, the UI fork action must still find it. The action
    // resolves the conversation via Workspace.forkableAgentSnapshot(forPanelId:), which reads the
    // snapshot captured at restore (restoredAgentSnapshotsByPanelId). A restored codex/claude/opencode
    // session must therefore still expose a valid fork command + launchable fork input.
    @MainActor
    func testRestoredSessionRemainsForkable() throws {
        let source = Workspace()
        let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
        let sessionId = "codex-fork-after-restore-session"
        let sourceIndex = try makeRestorableAgentIndex(
            workspaceId: source.id,
            panelId: sourcePanelId,
            sessionId: sessionId
        )
        let snapshot = source.sessionSnapshot(includeScrollback: false, restorableAgentIndex: sourceIndex)

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)

        let forkable = try XCTUnwrap(
            restored.forkableAgentSnapshot(forPanelId: restoredPanelId),
            "a restored session must remain forkable via the UI"
        )
        XCTAssertEqual(forkable.sessionId, sessionId)
        let forkCommand = try XCTUnwrap(forkable.forkCommand, "restored session must expose a fork command")
        XCTAssertTrue(forkCommand.contains("'fork'"), "codex fork verb expected; got: \(forkCommand)")
        XCTAssertTrue(forkCommand.contains(sessionId), "fork must reference the restored session id; got: \(forkCommand)")
        XCTAssertNotNil(
            forkable.forkStartupInput(
                fileManager: .default,
                temporaryDirectory: FileManager.default.temporaryDirectory
            ),
            "restored session must produce launchable fork startup input"
        )
    }

    // After a resumed agent is killed, the surface must return to the session's launch directory,
    // not the surface default. The resume command's own `cd` runs inside the `-lic` child shell, so
    // the outer login shell needs an explicit `cd` to the working directory before `exec -l`.
    func testResumeLauncherReturnsToLaunchCwdAfterAgentExits() {
        let dir = "/tmp/repo-resume"
        let lines = TerminalStartupReturnShellScript.commandThenReturnLines(
            command: "{ cd -- '\(dir)' 2>/dev/null || [ ! -d '\(dir)' ]; } && 'claude' '--resume' 'abc'",
            workingDirectory: dir
        )
        let script = lines.joined(separator: "\n")

        let outerCd = "{ cd -- '\(dir)' 2>/dev/null || true; }"
        let exec = "exec -l \"$_cmux_resume_shell\""
        let outerCdRange = script.range(of: outerCd)
        let execRange = script.range(of: exec)
        XCTAssertNotNil(outerCdRange, "launcher must cd the outer shell back to the launch dir; script:\n\(script)")
        XCTAssertNotNil(execRange, script)
        if let outerCdRange, let execRange {
            XCTAssertTrue(
                outerCdRange.lowerBound < execRange.lowerBound,
                "the return-to-launch-dir cd must run before exec -l; script:\n\(script)"
            )
        }

        // Back-compat: with no working directory, no extra outer cd is emitted.
        let bare = TerminalStartupReturnShellScript
            .commandThenReturnLines(command: "echo hi")
            .joined(separator: "\n")
        XCTAssertFalse(bare.contains("|| true; }"), bare)
        XCTAssertTrue(bare.contains(exec), bare)
    }

    private func withRestoredDefaults<T>(
        key: String,
        defaults: UserDefaults = .standard,
        body: () throws -> T
    ) rethrows -> T {
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        return try body()
    }

    @MainActor
    private func assertAgentAutoResumeUsesStartupCommand(
        _ panel: TerminalPanel,
        scriptContains needles: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let command = try XCTUnwrap(panel.surface.debugInitialCommand(), file: file, line: line)
        XCTAssertTrue(command.hasPrefix("/bin/zsh '"), command, file: file, line: line)
        let scriptPath = String(command.dropFirst("/bin/zsh '".count).dropLast())
        defer { try? FileManager.default.removeItem(atPath: scriptPath) }
        let script = try String(contentsOfFile: scriptPath, encoding: .utf8)
        for needle in needles {
            XCTAssertTrue(script.contains(needle), script, file: file, line: line)
        }
        XCTAssertTrue(script.contains("CMUX_SHELL_INTEGRATION_DIR"), script, file: file, line: line)
        XCTAssertTrue(script.contains("CMUX_ZSH_ZDOTDIR"), script, file: file, line: line)
        XCTAssertTrue(script.contains("\"$_cmux_resume_shell\" -lic"), script, file: file, line: line)
        XCTAssertTrue(script.contains("csh|tcsh) \"$_cmux_resume_shell\" -c"), script, file: file, line: line)
        XCTAssertTrue(script.contains("exec -l \"$_cmux_resume_shell\""), script, file: file, line: line)
    }

    private func makeRestorableAgentIndex(
        workspaceId: UUID,
        panelId: UUID,
        sessionId: String,
        extraArguments: [String] = []
    ) throws -> RestorableAgentSessionIndex {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-auto-resume-\(UUID().uuidString)", isDirectory: true)
        let previousHookStateDir = getenv("CMUX_AGENT_HOOK_STATE_DIR").map { String(cString: $0) }
        setenv("CMUX_AGENT_HOOK_STATE_DIR", home.appendingPathComponent("hook-state", isDirectory: true).path, 1)
        defer {
            if let previousHookStateDir {
                setenv("CMUX_AGENT_HOOK_STATE_DIR", previousHookStateDir, 1)
            } else {
                unsetenv("CMUX_AGENT_HOOK_STATE_DIR")
            }
        }
        let storeURL = RestorableAgentKind.codex.hookStoreFileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let jsonObject: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId.uuidString,
                    "surfaceId": panelId.uuidString,
                    "cwd": "/tmp/repo",
                    "updatedAt": Date().timeIntervalSince1970,
                    "launchCommand": [
                        "launcher": "codex",
                        "executablePath": "/usr/local/bin/codex",
                        "arguments": ["/usr/local/bin/codex", "--model", "gpt-5.4"] + extraArguments,
                        "workingDirectory": "/tmp/repo",
                        "environment": ["CODEX_HOME": "/tmp/codex"],
                        "capturedAt": Date().timeIntervalSince1970,
                        "source": "process",
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted])
        try data.write(to: storeURL, options: .atomic)
        return RestorableAgentSessionIndex.load(homeDirectory: home.path)
    }
}

final class TerminalCopyOnSelectSettingsTests: XCTestCase {
    func testDefaultsNotificationAndGhosttyConfigMapping() throws {
        let suiteName = "cmux-terminal-copy-on-select-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            TerminalCopyOnSelectSettings.copyOnSelectKey,
            "terminal.copyOnSelect"
        )
        XCTAssertFalse(TerminalCopyOnSelectSettings.isEnabled(defaults: defaults))
        XCTAssertNil(TerminalCopyOnSelectSettings.ghosttyConfigContents(defaults: defaults))
        XCTAssertNil(TerminalManagedGhosttySettings.ghosttyConfigContents(defaults: defaults))

        let notificationCenter = NotificationCenter()
        var notificationCount = 0
        let observer = notificationCenter.addObserver(
            forName: TerminalCopyOnSelectSettings.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer { notificationCenter.removeObserver(observer) }

        TerminalCopyOnSelectSettings.setEnabled(
            true,
            defaults: defaults,
            notificationCenter: notificationCenter
        )
        XCTAssertTrue(TerminalCopyOnSelectSettings.isEnabled(defaults: defaults))
        XCTAssertEqual(
            TerminalCopyOnSelectSettings.ghosttyConfigContents(defaults: defaults),
            "copy-on-select = clipboard"
        )
        XCTAssertEqual(
            TerminalManagedGhosttySettings.ghosttyConfigContents(defaults: defaults),
            "copy-on-select = clipboard"
        )
        XCTAssertEqual(notificationCount, 1)

        TerminalCopyOnSelectSettings.setEnabled(
            false,
            defaults: defaults,
            notificationCenter: notificationCenter
        )
        XCTAssertFalse(TerminalCopyOnSelectSettings.isEnabled(defaults: defaults))
        XCTAssertEqual(
            TerminalCopyOnSelectSettings.ghosttyConfigContents(defaults: defaults),
            "copy-on-select = false"
        )
        XCTAssertEqual(
            TerminalManagedGhosttySettings.ghosttyConfigContents(defaults: defaults),
            "copy-on-select = false"
        )
        XCTAssertEqual(notificationCount, 2)

        TerminalCopyOnSelectSettings.reset(
            defaults: defaults,
            notificationCenter: notificationCenter
        )
        XCTAssertFalse(TerminalCopyOnSelectSettings.isEnabled(defaults: defaults))
        XCTAssertNil(TerminalCopyOnSelectSettings.ghosttyConfigContents(defaults: defaults))
        XCTAssertNil(TerminalManagedGhosttySettings.ghosttyConfigContents(defaults: defaults))
        XCTAssertEqual(notificationCount, 2)
    }
}
