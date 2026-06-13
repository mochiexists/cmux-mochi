import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression tests for the Mochi fork feature set:
/// #1a captured-scrollback gating, #1b agent-resume prefill setting,
/// #2 DEV app-icon badge, #3 external-browser toggle, #4 Task Manager tab.
final class MochiFeatureTests: XCTestCase {

    // MARK: - #3 / #4 BrowserLaunchTargetSettings

    func testBrowserLaunchTargetDefaultsToInternal() throws {
        let suiteName = "cmux-browser-launch-target-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            BrowserLaunchTargetSettings.opensExternallyKey,
            "browser.openInExternalBrowser"
        )
        XCTAssertFalse(BrowserLaunchTargetSettings.opensExternally(defaults: defaults))
    }

    func testBrowserLaunchTargetSetAndToggle() throws {
        let suiteName = "cmux-browser-launch-target-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        BrowserLaunchTargetSettings.setOpensExternally(true, defaults: defaults)
        XCTAssertTrue(BrowserLaunchTargetSettings.opensExternally(defaults: defaults))

        // toggle() returns the new value and flips persisted state.
        let afterFirstToggle = BrowserLaunchTargetSettings.toggle(defaults: defaults)
        XCTAssertFalse(afterFirstToggle)
        XCTAssertFalse(BrowserLaunchTargetSettings.opensExternally(defaults: defaults))

        let afterSecondToggle = BrowserLaunchTargetSettings.toggle(defaults: defaults)
        XCTAssertTrue(afterSecondToggle)
        XCTAssertTrue(BrowserLaunchTargetSettings.opensExternally(defaults: defaults))
    }

    func testBrowserLaunchTargetPostsChangeNotification() throws {
        let suiteName = "cmux-browser-launch-target-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let expectation = expectation(
            forNotification: BrowserLaunchTargetSettings.didChangeNotification,
            object: nil,
            notificationCenter: .default
        )
        BrowserLaunchTargetSettings.setOpensExternally(true, defaults: defaults)
        wait(for: [expectation], timeout: 1)
    }

    // MARK: - #1b agent resume prefill (now the tri-state resume mode)

    func testAgentResumeMediumPrefillsWithoutSubmitting() throws {
        // Medium (the default) prefills the resume command but does not submit it —
        // the prefill-not-auto-submit behavior #1b introduced, now folded into the
        // tri-state resume mode.
        XCTAssertEqual(AgentSessionAutoResumeSettings.defaultMode, .medium)
        XCTAssertTrue(AgentSessionResumeMode.medium.prefillsResumeCommand)
        XCTAssertFalse(AgentSessionResumeMode.medium.submitsResumeCommand)
    }

    func testAgentResumeFullPrefillsAndSubmits() throws {
        // Full opts into auto-running the resume command (prefill + submit).
        XCTAssertTrue(AgentSessionResumeMode.full.prefillsResumeCommand)
        XCTAssertTrue(AgentSessionResumeMode.full.submitsResumeCommand)
        // Off neither prefills nor submits.
        XCTAssertFalse(AgentSessionResumeMode.off.prefillsResumeCommand)
        XCTAssertFalse(AgentSessionResumeMode.off.submitsResumeCommand)
    }

    // MARK: - #4 PanelType.taskManager

    func testTaskManagerPanelTypeRawValue() {
        XCTAssertEqual(PanelType.taskManager.rawValue, "taskManager")
    }

    func testTaskManagerPanelTypeCodableRoundTrip() throws {
        let encoded = try JSONEncoder().encode(PanelType.taskManager)
        let decoded = try JSONDecoder().decode(PanelType.self, from: encoded)
        XCTAssertEqual(decoded, .taskManager)
    }

    @MainActor
    func testTaskManagerPanelIdentity() {
        let panel = TaskManagerPanel()
        XCTAssertEqual(panel.panelType, .taskManager)
        XCTAssertEqual(panel.displayIcon, "gauge.with.dots.needle.33percent")
        XCTAssertFalse(panel.displayTitle.isEmpty)
        // A full Task Manager tab samples per-process detail.
        XCTAssertTrue(panel.model.includesProcesses)
        panel.close()
    }

    // MARK: - #2 AppIconDevBadge

    @MainActor
    func testAppIconDevBadgePreservesCanvasSize() {
        let base = NSImage(size: NSSize(width: 128, height: 128))
        base.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 128, height: 128).fill()
        base.unlockFocus()

        let badged = AppIconDevBadge.applied(to: base)
        XCTAssertEqual(badged.size, base.size)
        XCTAssertTrue(badged.isValid)
    }

    // MARK: - #1a captured-scrollback gating

    func testScrollbackReplayDefaultsOnForPlainTerminal() {
        // No agent, no tmux start command, no resume work: a plain terminal's
        // scrollback is safe to replay on restore.
        XCTAssertTrue(
            Workspace.shouldReplaySessionScrollback(
                restorableAgent: nil,
                tmuxStartCommand: nil,
                hasResumeStartupWork: false
            )
        )
    }

    func testScrollbackReplaySuppressedWhenResumeStartupWorkPending() {
        // Pending resume startup work must not race a stale TUI replay — this is
        // why #1a relies on captured agent scrollback rather than replay.
        XCTAssertFalse(
            Workspace.shouldReplaySessionScrollback(
                restorableAgent: nil,
                tmuxStartCommand: nil,
                hasResumeStartupWork: true
            )
        )
    }

    func testScrollbackPersistForRestoreKeepsLiveContent() {
        // The live-TUI fix: persistence is no longer gated on close-confirmation
        // or agent recognition. A live terminal with no restorable agent (e.g. an
        // open Claude TUI never detected as an agent) must still persist — the old
        // gate dropped exactly that content and left the reopened window blank.
        XCTAssertTrue(
            Workspace.shouldPersistSessionScrollbackForRestore(
                restorableAgent: nil,
                tmuxStartCommand: nil
            )
        )
        // The one intentional suppression: an OMX-HUD tmux restart with no
        // restorable agent, where a replayed scrollback would fight the restart.
        XCTAssertFalse(
            Workspace.shouldPersistSessionScrollbackForRestore(
                restorableAgent: nil,
                tmuxStartCommand: "omx hud --foo"
            )
        )
    }
}
