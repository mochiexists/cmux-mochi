import XCTest
import AppKit
import Bonsplit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TabContextMenuPathTests: XCTestCase {
    func testTabContextMenuItemsProviderIsSetOnWorkspaceInit() {
        let workspace = Workspace()

        XCTAssertNotNil(
            workspace.bonsplitController.tabContextMenuItemsProvider,
            "Workspace should provide Bonsplit with app-owned path actions"
        )
    }

    func testTabContextMenuItemsProviderTracksPanelDirectory() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let tabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(panelId))

        XCTAssertEqual(workspace.bonsplitController.tabContextMenuItemsProvider?(tabId, PaneID()).map(\.id) ?? [], [])

        workspace.panelDirectories[panelId] = "   "
        XCTAssertEqual(workspace.bonsplitController.tabContextMenuItemsProvider?(tabId, PaneID()).map(\.id) ?? [], [])

        workspace.panelDirectories[panelId] = "/Users/test/Documents/project"
        let items = workspace.bonsplitController.tabContextMenuItemsProvider?(tabId, PaneID()) ?? []
        XCTAssertEqual(items.map(\.id), ["revealInFinder", "copyPath"])
        XCTAssertEqual(items.map(\.title), ["Reveal in Finder", "Copy Path"])
        XCTAssertTrue(items.allSatisfy(\.isEnabled))
    }

    func testCopyPathTabContextMenuItemWritesTrimmedAbsolutePathToPasteboard() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let paneId = try XCTUnwrap(workspace.paneId(forPanelId: panelId))
        let tabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(panelId))
        let tab = try XCTUnwrap(workspace.bonsplitController.tab(tabId))
        let directory = "/Users/test/Documents/project"
        let pasteboard = NSPasteboard.general

        workspace.panelDirectories[panelId] = "  \(directory)  "
        pasteboard.clearContents()

        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestTabContextMenuItem: "copyPath",
            for: tab,
            inPane: paneId
        )

        XCTAssertEqual(pasteboard.string(forType: .string), directory)
    }

    func testBonsplitPathActionsUseGenericCustomMenuItems() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let tabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(panelId))

        workspace.panelDirectories[panelId] = "/Users/test/Documents/project"

        let items = workspace.bonsplitController.tabContextMenuItemsProvider?(tabId, PaneID()) ?? []
        XCTAssertEqual(
            items,
            [
                TabContextMenuItem(id: "revealInFinder", title: "Reveal in Finder"),
                TabContextMenuItem(id: "copyPath", title: "Copy Path"),
            ]
        )
        XCTAssertFalse(TabContextAction.allCases.map(\.rawValue).contains("revealInFinder"))
        XCTAssertFalse(TabContextAction.allCases.map(\.rawValue).contains("copyPath"))
    }
}
