import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class AgentSessionAutoResumeSettingsTests: XCTestCase {
    func testModeKeyDefaultAndNotificationOnChange() throws {
        let suiteName = "cmux-agent-session-resume-mode-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(AgentSessionAutoResumeSettings.modeKey, "terminal.agentResumeMode")
        XCTAssertEqual(AgentSessionAutoResumeSettings.mode(defaults: defaults), .full)

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
        XCTAssertEqual(notificationCount, 1)

        // Setting the same mode does not notify.
        AgentSessionAutoResumeSettings.setMode(.medium, defaults: defaults, notificationCenter: notificationCenter)
        XCTAssertEqual(notificationCount, 1)

        AgentSessionAutoResumeSettings.setMode(.off, defaults: defaults, notificationCenter: notificationCenter)
        XCTAssertEqual(AgentSessionAutoResumeSettings.mode(defaults: defaults), .off)
        XCTAssertEqual(notificationCount, 2)

        AgentSessionAutoResumeSettings.reset(defaults: defaults, notificationCenter: notificationCenter)
        XCTAssertEqual(AgentSessionAutoResumeSettings.mode(defaults: defaults), .full)
        XCTAssertEqual(notificationCount, 3)
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
        let preparedResumeInput = try XCTUnwrap(
            snapshot.panels.first?.terminal?.agent?.resumePreparedStartupInput()
        )

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

    private func makeRestorableAgentIndex(
        workspaceId: UUID,
        panelId: UUID,
        sessionId: String
    ) throws -> RestorableAgentSessionIndex {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-auto-resume-\(UUID().uuidString)", isDirectory: true)
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
                        "arguments": ["/usr/local/bin/codex", "--model", "gpt-5.4"],
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
