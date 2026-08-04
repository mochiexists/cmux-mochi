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
        // Run against the REAL stored pairing: no clearAuth, no mock data —
        // either would remove the very state that makes the loop happen.
        //
        // Do mark onboarding as seen. A test run reinstalls the app, which wipes
        // UserDefaults while the keychain survives, so the first run landed on
        // the first-run explainer and never reached the workspace list. That is
        // an artifact of reinstalling, not the behaviour under test.
        app.launchArguments += ["-dev.cmux.mobile.onboarding.seen.v1", "YES"]
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
        let onboardingLabels: Set<String> = ["Skip", "Next"]
        let strandedOnOnboarding = !onboardingLabels.isDisjoint(with: Set(buttonLabels))
        XCTAssertFalse(
            strandedOnOnboarding,
            "paired device connected but the UI is still on first-run onboarding. \(screen)"
        )

        // Connected, so the list must offer work rather than a way back online.
        XCTAssertFalse(
            buttonLabels.contains("Reconnect"),
            "connected phone is still offering Reconnect. \(screen)"
        )

        // Switch machines and record what each one lists. Both Macs sharing one
        // identical set is the reported bug: the foreground workspace aggregate
        // was never re-keyed onto the real Mac, so the two collapse into one
        // bucket and the picker changes the name but not the contents.
        // Identify rows by their stable accessibility identifier
        // (`MobileWorkspaceRow-<workspaceID>`), not by label. Two machines can
        // legitimately host workspaces with the same *name* — the M4 and the M5
        // each have one called "cat" — so names cannot tell "the picker is
        // broken" from "both workspaces happen to be called cat". The ids can.
        func visibleWorkspaceRowIDs() -> [String] {
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'MobileWorkspaceRow-'"))
                .allElementsBoundByIndex
                .filter(\.exists)
                .map { String($0.identifier.dropFirst("MobileWorkspaceRow-".count)) }
                .sorted()
        }

        var perMachineRows: [String: [String]] = [:]
        let macPicker = app.descendants(matching: .any)["MobileWorkspaceMacPicker"]

        // Collect the machine names ONCE, then select each by name. Indexing
        // into a freshly-queried option list does not work: the list is rebuilt
        // per presentation and its order is not stable, so index 1 kept
        // re-selecting the machine already showing.
        func machineOptionLabels() -> [String] {
            app.descendants(matching: .any).allElementsBoundByIndex
                .filter { $0.exists && $0.isHittable
                    && ($0.label.localizedCaseInsensitiveContains("MacBook")
                        || $0.label.localizedCaseInsensitiveContains("m5")) }
                .map(\.label)
        }

        _ = machineOptionLabels
        _ = macPicker

        // The decisive check needs no picker navigation at all. In "All
        // Computers" the aggregated list must carry a row for EACH paired Mac's
        // workspaces. Row identifiers are `MobileWorkspaceRow-<macID><wsID>`, so
        // counting distinct rows answers "am I seeing both machines?" directly —
        // and it is what the user actually reported: one chat visible, two Macs
        // paired.
        let aggregatedRows = visibleWorkspaceRowIDs()
        perMachineRows["AllComputers"] = aggregatedRows
        // Put the contents in the assertion message: the runner's stdout does
        // not reach the xcodebuild log, so this is the only way to see them.
        let summary = perMachineRows
            .map { "\($0.key) -> [\($0.value.joined(separator: ", "))]" }
            .sorted()
            .joined(separator: "  ||  ")
        // Two paired Macs, one workspace each (M5 9B836F1E…, M4 987C7060…), so
        // the aggregated list must show two distinct rows. One row means the
        // second Mac's secondary connection never produced workspaces — the
        // reported "I can only see one chat".
        let distinctMacsInList = Set(aggregatedRows.map { String($0.prefix(36)) })
        XCTAssertGreaterThanOrEqual(
            distinctMacsInList.count, 2,
            "All Computers lists workspaces from \(distinctMacsInList.count) machine(s), "
                + "expected 2. rows=\(aggregatedRows) \(summary) \(screen)"
        )

        // Every row in an aggregated list must name its machine, or two Macs
        // holding same-named workspaces are indistinguishable.
        // Read it off the row's accessibility VALUE: the row combines its
        // children, so the machine label is only reachable there.
        let attributed = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'MobileWorkspaceRow-'"))
            .allElementsBoundByIndex
            .filter(\.exists)
            .map { "\($0.value ?? "")" }
        let attributionCount = attributed.filter { $0.contains(" on ") }.count
        XCTAssertGreaterThanOrEqual(
            attributionCount, 2,
            "aggregated rows do not name their machine (\(attributionCount) of "
                + "\(aggregatedRows.count) rows). values=\(attributed) \(screen)"
        )

        // The machine filter must actually filter. Selecting one machine should
        // leave strictly fewer rows than "all", and every survivor must belong
        // to that machine.
        // A SwiftUI Menu does not always publish its identifier on the element
        // XCUITest can hit, so fall back to the visible "Filter" control.
        var filterMenu = app.descendants(matching: .any)["MobileWorkspaceFilterMenu"]
        if !filterMenu.exists || !filterMenu.isHittable {
            let byLabel = app.buttons["Filter"]
            if byLabel.exists { filterMenu = byLabel }
        }
        if filterMenu.waitForExistence(timeout: 10), filterMenu.isHittable {
            filterMenu.tap()
            Thread.sleep(forTimeInterval: 4)
            // Match by LABEL, not identifier: SwiftUI does not carry
            // `accessibilityIdentifier` into a presented Menu's items, so every
            // entry arrives with an empty identifier. Reading the menu proved
            // this — the entries are there, unlabelled by id.
            func machineEntry() -> XCUIElement? {
                app.descendants(matching: .any).allElementsBoundByIndex
                    .first {
                        $0.exists && $0.isHittable
                            && $0.label != "All Machines"
                            && ($0.label.localizedCaseInsensitiveContains("MacBook")
                                || $0.label.localizedCaseInsensitiveContains("m5")
                                || $0.label == "Computer")
                    }
            }
            // The per-machine entries live under a "Machines" SUBMENU, not at
            // the top level of the filter menu. Reading the menu's contents is
            // what showed this: it offers "All Workspaces | Unread | Machines".
            if machineEntry() == nil {
                let machinesSubmenu = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label == 'Machines'"))
                    .allElementsBoundByIndex
                    .first { $0.exists && $0.isHittable }
                if let machinesSubmenu {
                    machinesSubmenu.tap()
                    Thread.sleep(forTimeInterval: 4)
                }
            }
            let machineFilter = machineEntry()
            if let machineFilter {
                let filteredMachine = machineFilter.label
                machineFilter.tap()
                Thread.sleep(forTimeInterval: 10)
                let filteredRows = visibleWorkspaceRowIDs()
                XCTAssertFalse(
                    filteredRows.isEmpty,
                    "filtering to '\(filteredMachine)' emptied the list. all=\(aggregatedRows)"
                )
                // Every survivor must come from ONE machine: row ids are
                // `<macID><workspaceID>`, so a single distinct 36-char prefix
                // means the filter really narrowed to one Mac.
                let survivingMacs = Set(filteredRows.map { String($0.prefix(36)) })
                XCTAssertEqual(
                    survivingMacs.count, 1,
                    "filter to '\(filteredMachine)' left rows from \(survivingMacs.count) machines: \(filteredRows)"
                )
                XCTAssertLessThan(
                    filteredRows.count, aggregatedRows.count,
                    "filtering changed nothing — \(filteredRows.count) rows before and after"
                )
                // Restore the full list for the steps below, and make sure the
                // menu is actually dismissed: a menu left open swallows every
                // later tap, and the next step then reports rows that exist but
                // are not hittable — which reads as a product bug and is not.
                filterMenu.tap()
                Thread.sleep(forTimeInterval: 3)
                let showAll = app.descendants(matching: .any)["MobileWorkspaceFilterShowAll"]
                if showAll.exists, showAll.isHittable {
                    showAll.tap()
                } else {
                    // Dismiss by tapping outside the menu.
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap()
                }
                Thread.sleep(forTimeInterval: 8)
            } else {
                // Report what the menu DID contain. "No machine entries" can
                // mean the product built no machines, or that the control this
                // test tapped was not the machine menu at all — those have
                // opposite fixes and the failure text must tell them apart.
                let presented = app.descendants(matching: .any).allElementsBoundByIndex
                    .filter { $0.exists && !$0.label.isEmpty }
                    .prefix(24)
                    .map { "\($0.label)[\($0.identifier)]" }
                    .joined(separator: " | ")
                XCTFail(
                    "filter menu opened but offered no machine entries. "
                        + "presented=\(presented) \(screen)"
                )
            }
        } else {
            XCTFail("no filter menu on a multi-machine list. \(screen)")
        }

        // Opening a chat must actually load it. A row that opens to nothing is
        // the reported symptom: the list looked healthy, the tap did nothing
        // useful. The composer is the cheapest honest proof that the workspace
        // detail mounted against a live connection rather than an empty shell.
        func hittableRow() -> XCUIElement? {
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'MobileWorkspaceRow-'"))
                .allElementsBoundByIndex
                .first { $0.exists && $0.isHittable }
        }
        var firstRow = hittableRow()
        if firstRow == nil {
            // Something modal is still up. Dismiss and look once more before
            // calling this a failure.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap()
            Thread.sleep(forTimeInterval: 5)
            firstRow = hittableRow()
        }
        if let firstRow {
            let openedRow = firstRow.identifier
            firstRow.tap()
            let composer = app.descendants(matching: .any)["MobileComposerField"]
            let loaded = composer.waitForExistence(timeout: 40)
            let afterOpen = app.buttons.allElementsBoundByIndex
                .filter(\.exists).prefix(12).map(\.label).joined(separator: " | ")
            XCTAssertTrue(
                loaded,
                "opening \(openedRow) did not load a chat — no composer after 40 s. "
                    + "buttons=\(afterOpen)"
            )

            // Send a real message and require the Mac to answer. A chat that
            // opens is not the same as a link that carries work: this is the
            // only step that proves the round trip end to end, over DeviceLink,
            // with no account anywhere in it.
            if loaded {
                let marker = "cmux-uitest-ping"
                composer.tap()
                composer.typeText("echo \(marker)\n")
                // The Mac has to receive it, run it, and stream output back.
                let echoed = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", marker, marker))
                let deadline = Date().addingTimeInterval(90)
                var sawEcho = false
                while Date() < deadline {
                    if echoed.allElementsBoundByIndex.contains(where: \.exists) {
                        sawEcho = true
                        break
                    }
                    Thread.sleep(forTimeInterval: 3)
                }
                XCTAssertTrue(
                    sawEcho,
                    "sent '\(marker)' over the DeviceLink connection and saw no response "
                        + "within 90 s — the chat renders but the link carries no work."
                )
            }
        } else {
            XCTFail("no workspace row was tappable. rows=\(aggregatedRows) \(screen)")
        }

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
        // Deliberately no blind fallback tap. Tapping `buttons[0]` opened the
        // Add Computer sheet on an earlier run and made a healthy phone look
        // like it had no computers — the test manufacturing the very state it
        // was meant to detect.
        _ = pressed

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

        // Not asserted: a backgrounded app here says the runner lost the
        // foreground, which tells us nothing about the connection.
        _ = app.state
    }
}
