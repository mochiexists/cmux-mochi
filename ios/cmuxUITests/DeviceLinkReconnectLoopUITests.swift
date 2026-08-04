import XCTest

/// Reproduces the reconnect loop on a paired physical device.
///
/// The loop only runs while the app is being used: launched and left alone it
/// connects once and stays quiet, which is why every headless launch looked
/// healthy while the phone in hand was unusable. This drives the app the way a
/// person does, then idles long enough for the cycle to repeat, so the device
/// log names the recovery trigger without anyone tapping anything.
///
/// It asserts nothing about the loop itself — its job is to *produce* the
/// window, and the assertions live in the log the run leaves behind. Reading
/// that log is the point:
///
///     xcrun devicectl device copy from --device <udid> --source / \
///       --destination /tmp/p --domain-type appDataContainer \
///       --domain-identifier com.cmux-mochi.ios.endpoint-stability
///     grep "connection recovery" "/tmp/p/Library/Application Support/cmux-debug.log"
final class DeviceLinkReconnectLoopUITests: XCTestCase {
    override func setUpWithError() throws {
        // The loop is the subject; a failed tap must not end the run before the
        // idle window that captures it.
        continueAfterFailure = true
    }

    @MainActor
    func testDrivePairedAppSoTheReconnectLoopIsLogged() throws {
        let app = XCUIApplication()
        // No launch arguments: this must run against the REAL stored pairing.
        // Clearing auth or injecting mock data would remove the very state that
        // makes the loop happen.
        app.launch()

        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 30),
            "app never reached the foreground"
        )

        // Give the launch reconnect time to land before touching anything, so
        // the log separates "connected once on launch" from what the loop does.
        Thread.sleep(forTimeInterval: 12)

        // Record the screen. The loop did not reproduce on a plain launch-and-
        // idle run, so what is actually on screen decides which control matters.
        let tree = app.debugDescription
        let treeAttachment = XCTAttachment(string: tree)
        treeAttachment.name = "accessibility-tree"
        treeAttachment.lifetime = .keepAlways
        add(treeAttachment)
        print("CMUX_UITEST_TREE_BEGIN\n\(tree)\nCMUX_UITEST_TREE_END")

        // The runner's stdout does not reach the xcodebuild log and attachments
        // did not survive the result bundle, so report what is on screen through
        // a failure message, which does. `continueAfterFailure` keeps the run
        // going so the idle window still happens.
        let buttonLabels = (0..<min(app.buttons.count, 25))
            .map { app.buttons.element(boundBy: $0).label }
            .filter { !$0.isEmpty }
        let cellLabels = (0..<min(app.cells.count, 15))
            .map { app.cells.element(boundBy: $0).label }
            .filter { !$0.isEmpty }
        let screen = "CMUX_SCREEN buttons=\(buttonLabels.joined(separator: " | ")) "
            + "cells=\(cellLabels.joined(separator: " | ")) "
            + "collectionViews=\(app.collectionViews.count) tables=\(app.tables.count) "
            + "scrollViews=\(app.scrollViews.count)"

        // The real assertion. This device holds a pairing and the device log
        // shows `dial finished: connected` within a second of launch — so the
        // app must be past onboarding. Seeing "Trouble connecting?" / Skip /
        // Next means the transport connected and the UI never noticed, which is
        // the bug: the user sees a connecting screen forever on a phone that is
        // demonstrably connected.
        let onboardingLabels: Set<String> = ["Skip", "Next", "Trouble connecting?"]
        let strandedOnOnboarding = !onboardingLabels.isDisjoint(with: Set(buttonLabels))
        XCTAssertFalse(
            strandedOnOnboarding,
            "paired device connected but the UI is still on the connecting screen. \(screen)"
        )

        // Press Reconnect / Retry. This is the control the user pressed when the
        // loop appeared, and it is the only trigger that is unambiguously
        // `.manual` — pressing it separates a user-driven redial from the
        // automatic ones in the log.
        let wanted = ["Reconnect", "Retry", "Try Again", "Connect"]
        var pressed = false
        for label in wanted {
            let button = app.buttons[label]
            if button.exists, button.isHittable {
                button.tap()
                print("CMUX_UITEST tapped button: \(label)")
                pressed = true
                break
            }
        }
        if !pressed {
            // Fall back to the first hittable row so the app still does work.
            for collection in [app.cells, app.buttons] where collection.count > 0 {
                let element = collection.element(boundBy: 0)
                if element.exists, element.isHittable {
                    element.tap()
                    print("CMUX_UITEST tapped fallback: \(element.label)")
                    break
                }
            }
        }

        // Pull-to-refresh. This calls `reconnectOrRefresh()` directly — the same
        // entry point as the offline row's Reconnect button — so it exercises
        // the teardown-and-redial path without depending on a button label.
        // Repeated, because one healthy refresh proves nothing; the loop is what
        // happens when the list stays offline.
        for attempt in 1...3 {
            let surface = app.collectionViews.firstMatch.exists
                ? app.collectionViews.firstMatch
                : (app.tables.firstMatch.exists ? app.tables.firstMatch : app.scrollViews.firstMatch)
            if surface.exists {
                let top = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
                let down = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
                top.press(forDuration: 0.05, thenDragTo: down)
                print("CMUX_UITEST pull-to-refresh \(attempt)")
            }
            Thread.sleep(forTimeInterval: 15)
        }

        // Idle inside the app while the cycle repeats. The observed loop runs
        // about once a second, so this window holds many iterations.
        Thread.sleep(forTimeInterval: 75)

        // Background and foreground once: `.foreground` is one of the recovery
        // triggers, and this separates it from the others in the log.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 5)
        app.activate()
        Thread.sleep(forTimeInterval: 45)

        XCTAssertEqual(app.state, .runningForeground, "app left the foreground")
    }
}
