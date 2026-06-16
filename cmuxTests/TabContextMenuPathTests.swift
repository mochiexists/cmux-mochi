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

    // MARK: - Markdown / browser-local-file targets (pure resolver)

    func testActionTargetPrefersMarkdownFileAsSelectedFile() {
        let target = Workspace.tabContextActionTarget(
            filePath: "  /Users/test/Documents/notes/readme.md  ",
            browserURL: nil,
            directory: "/Users/test/Documents/notes"
        )
        XCTAssertEqual(target?.path, "/Users/test/Documents/notes/readme.md")
        XCTAssertEqual(target?.isFile, true)
    }

    func testActionTargetUsesBrowserLocalFileURLAsSelectedFile() {
        let target = Workspace.tabContextActionTarget(
            filePath: nil,
            browserURL: URL(fileURLWithPath: "/Users/test/site/index.html"),
            directory: nil
        )
        XCTAssertEqual(target?.path, "/Users/test/site/index.html")
        XCTAssertEqual(target?.isFile, true)
    }

    func testActionTargetIgnoresRemoteBrowserURLAndFallsBackToDirectory() {
        let target = Workspace.tabContextActionTarget(
            filePath: nil,
            browserURL: URL(string: "https://example.com/page.html"),
            directory: "/Users/test/project"
        )
        XCTAssertEqual(target?.path, "/Users/test/project")
        XCTAssertEqual(target?.isFile, false)
    }

    func testActionTargetFallsBackToDirectoryAsFolder() {
        let target = Workspace.tabContextActionTarget(
            filePath: "   ",
            browserURL: nil,
            directory: "/Users/test/project"
        )
        XCTAssertEqual(target?.path, "/Users/test/project")
        XCTAssertEqual(target?.isFile, false)
    }

    func testActionTargetNilWhenNothingResolvable() {
        XCTAssertNil(Workspace.tabContextActionTarget(filePath: nil, browserURL: nil, directory: nil))
        XCTAssertNil(Workspace.tabContextActionTarget(filePath: "  ", browserURL: nil, directory: "   "))
    }

    func testMarkdownTabExposesPathActionsAndCopiesFilePath() throws {
        let workspace = Workspace()
        let paneId = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let filePath = "/Users/test/Documents/notes/readme.md"
        let panel = try XCTUnwrap(
            workspace.newMarkdownSurface(inPane: paneId, filePath: filePath)
        )
        let tabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(panel.id))

        // A markdown tab shows the path actions even with no working directory.
        let items = workspace.bonsplitController.tabContextMenuItemsProvider?(tabId, PaneID()) ?? []
        XCTAssertEqual(items.map(\.id), ["revealInFinder", "copyPath"])

        // Copy Path writes the markdown FILE path, not a directory.
        let tab = try XCTUnwrap(workspace.bonsplitController.tab(tabId))
        let actionPane = try XCTUnwrap(workspace.paneId(forPanelId: panel.id))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestTabContextMenuItem: "copyPath",
            for: tab,
            inPane: actionPane
        )
        XCTAssertEqual(pasteboard.string(forType: .string), filePath)
    }

    func testFilePreviewTabExposesPathActionsAndCopiesFilePath() throws {
        let workspace = Workspace()
        let paneId = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let filePath = "/Users/test/Documents/project/.build/release/tool"
        let panel = try XCTUnwrap(
            workspace.newFilePreviewSurface(inPane: paneId, filePath: filePath)
        )
        let tabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(panel.id))

        // A file-preview tab shows the path actions even with no working directory.
        let items = workspace.bonsplitController.tabContextMenuItemsProvider?(tabId, PaneID()) ?? []
        XCTAssertEqual(items.map(\.id), ["revealInFinder", "copyPath"])

        // Copy Path writes the previewed FILE path, not a directory.
        let tab = try XCTUnwrap(workspace.bonsplitController.tab(tabId))
        let actionPane = try XCTUnwrap(workspace.paneId(forPanelId: panel.id))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestTabContextMenuItem: "copyPath",
            for: tab,
            inPane: actionPane
        )
        XCTAssertEqual(pasteboard.string(forType: .string), filePath)
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
