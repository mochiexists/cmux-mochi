import AppKit
import Bonsplit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct TabContextMenuPathTests {
    @Test func tabContextMenuItemsProviderIsSetOnWorkspaceInit() {
        let workspace = Workspace()

        #expect(
            workspace.bonsplitController.tabContextMenuItemsProvider != nil,
            "Workspace should provide Bonsplit with app-owned path actions"
        )
    }

    @Test func tabContextMenuItemsProviderTracksPanelDirectory() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panelId))

        #expect(workspace.bonsplitController.tabContextMenuItemsProvider?(tabId, PaneID()).map(\.id) ?? [] == [])

        workspace.panelDirectories[panelId] = "   "
        #expect(workspace.bonsplitController.tabContextMenuItemsProvider?(tabId, PaneID()).map(\.id) ?? [] == [])

        workspace.panelDirectories[panelId] = "/Users/test/Documents/project"
        let items = workspace.bonsplitController.tabContextMenuItemsProvider?(tabId, PaneID()) ?? []
        #expect(items.map(\.id) == ["revealInFinder", "copyPath"])
        #expect(items.map(\.title) == ["Reveal in Finder", "Copy Path"])
        #expect(items.map(\.isEnabled) == [true, true])
    }

    @Test func copyPathTabContextMenuItemWritesTrimmedAbsolutePathToPasteboard() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: panelId))
        let tabId = try #require(workspace.surfaceIdFromPanelId(panelId))
        let tab = try #require(workspace.bonsplitController.tab(tabId))
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

        #expect(pasteboard.string(forType: .string) == directory)
    }

    @Test func copyIdentifiersTabContextActionWritesWorkspacePaneSurfacePayload() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: panelId))
        let tabId = try #require(workspace.surfaceIdFromPanelId(panelId))
        let tab = try #require(workspace.bonsplitController.tab(tabId))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestTabContextAction: .copyIdentifiers,
            for: tab,
            inPane: paneId
        )

        let payload = try #require(pasteboard.string(forType: .string))
        #expect(payload.contains("workspace_id=\(workspace.id.uuidString)"))
        #expect(payload.contains("pane_id=\(paneId.id.uuidString)"))
        #expect(payload.contains("surface_id=\(panelId.uuidString)"))
    }

    // MARK: - Markdown / browser-local-file targets (pure resolver)

    @Test func actionTargetPrefersMarkdownFileAsSelectedFile() {
        let target = Workspace.tabContextActionTarget(
            filePath: "  /Users/test/Documents/notes/readme.md  ",
            browserURL: nil,
            directory: "/Users/test/Documents/notes"
        )
        #expect(target?.path == "/Users/test/Documents/notes/readme.md")
        #expect(target?.isFile == true)
    }

    @Test func actionTargetUsesBrowserLocalFileURLAsSelectedFile() {
        let target = Workspace.tabContextActionTarget(
            filePath: nil,
            browserURL: URL(fileURLWithPath: "/Users/test/site/index.html"),
            directory: nil
        )
        #expect(target?.path == "/Users/test/site/index.html")
        #expect(target?.isFile == true)
    }

    @Test func actionTargetIgnoresRemoteBrowserURLAndFallsBackToDirectory() {
        let target = Workspace.tabContextActionTarget(
            filePath: nil,
            browserURL: URL(string: "https://example.com/page.html"),
            directory: "/Users/test/project"
        )
        #expect(target?.path == "/Users/test/project")
        #expect(target?.isFile == false)
    }

    @Test func actionTargetFallsBackToDirectoryAsFolder() {
        let target = Workspace.tabContextActionTarget(
            filePath: "   ",
            browserURL: nil,
            directory: "/Users/test/project"
        )
        #expect(target?.path == "/Users/test/project")
        #expect(target?.isFile == false)
    }

    @Test func actionTargetNilWhenNothingResolvable() {
        #expect(Workspace.tabContextActionTarget(filePath: nil, browserURL: nil, directory: nil) == nil)
        #expect(Workspace.tabContextActionTarget(filePath: "  ", browserURL: nil, directory: "   ") == nil)
    }

    @Test func markdownTabExposesPathActionsAndCopiesFilePath() throws {
        let workspace = Workspace()
        let paneId = try #require(workspace.bonsplitController.allPaneIds.first)
        let filePath = "/Users/test/Documents/notes/readme.md"
        let panel = try #require(
            workspace.newMarkdownSurface(inPane: paneId, filePath: filePath)
        )
        let tabId = try #require(workspace.surfaceIdFromPanelId(panel.id))

        // A markdown tab shows file actions even with no working directory.
        let items = workspace.bonsplitController.tabContextMenuItemsProvider?(tabId, PaneID()) ?? []
        #expect(items.map(\.id) == ["revealInFinder", "copyFile", "copyPath"])
        #expect(items.map(\.title) == ["Reveal in Finder", "Copy .md File", "Copy Path"])

        // Copy Path writes the markdown FILE path, not a directory.
        let tab = try #require(workspace.bonsplitController.tab(tabId))
        let actionPane = try #require(workspace.paneId(forPanelId: panel.id))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestTabContextMenuItem: "copyPath",
            for: tab,
            inPane: actionPane
        )
        #expect(pasteboard.string(forType: .string) == filePath)
    }

    @Test func filePreviewTabExposesPathActionsAndCopiesFilePath() throws {
        let workspace = Workspace()
        let paneId = try #require(workspace.bonsplitController.allPaneIds.first)
        let filePath = "/Users/test/Documents/project/.build/release/tool"
        let panel = try #require(
            workspace.newFilePreviewSurface(inPane: paneId, filePath: filePath)
        )
        let tabId = try #require(workspace.surfaceIdFromPanelId(panel.id))

        // A file-preview tab shows file actions even with no working directory.
        let items = workspace.bonsplitController.tabContextMenuItemsProvider?(tabId, PaneID()) ?? []
        #expect(items.map(\.id) == ["revealInFinder", "copyFile", "copyPath"])
        #expect(items.map(\.title) == ["Reveal in Finder", "Copy File", "Copy Path"])

        // Copy Path writes the previewed FILE path, not a directory.
        let tab = try #require(workspace.bonsplitController.tab(tabId))
        let actionPane = try #require(workspace.paneId(forPanelId: panel.id))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestTabContextMenuItem: "copyPath",
            for: tab,
            inPane: actionPane
        )
        #expect(pasteboard.string(forType: .string) == filePath)
    }

    @Test func artifactTabExposesPathActionsAndCopiesFilePath() throws {
        let workspace = Workspace()
        let paneId = try #require(workspace.bonsplitController.allPaneIds.first)
        let filePath = "/Users/test/.config/cmux/artifacts/2026/06/29/showcase.tsx"
        let panel = try #require(
            workspace.newArtifactSurface(inPane: paneId, filePath: filePath, kind: .react)
        )
        let tabId = try #require(workspace.surfaceIdFromPanelId(panel.id))

        let items = workspace.bonsplitController.tabContextMenuItemsProvider?(tabId, PaneID()) ?? []
        #expect(items.map(\.id) == ["revealInFinder", "copyFile", "copyPath"])
        #expect(items.map(\.title) == ["Reveal in Finder", "Copy .tsx File", "Copy Path"])

        let tab = try #require(workspace.bonsplitController.tab(tabId))
        let actionPane = try #require(workspace.paneId(forPanelId: panel.id))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestTabContextMenuItem: "copyPath",
            for: tab,
            inPane: actionPane
        )
        #expect(pasteboard.string(forType: .string) == filePath)
    }

    @Test func copyFileTabContextMenuItemWritesFileObjectToPasteboard() throws {
        let workspace = Workspace()
        let paneId = try #require(workspace.bonsplitController.allPaneIds.first)
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-copy-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let fileURL = tempDirectory.appendingPathComponent("readme.md")
        try "# hello\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let filePath = fileURL.path
        let panel = try #require(
            workspace.newMarkdownSurface(inPane: paneId, filePath: filePath)
        )
        let tabId = try #require(workspace.surfaceIdFromPanelId(panel.id))
        let tab = try #require(workspace.bonsplitController.tab(tabId))
        let actionPane = try #require(workspace.paneId(forPanelId: panel.id))
        let pasteboard = NSPasteboard.general

        pasteboard.clearContents()
        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestTabContextMenuItem: "copyFile",
            for: tab,
            inPane: actionPane
        )

        let copiedFilePaths = fileURLs(on: pasteboard).map(\.path)
        let copiedString = pasteboard.string(forType: .string)
        #expect(copiedFilePaths == [filePath])
        #expect(copiedString == filePath)
    }

    @Test func copyFileTabContextMenuItemIgnoresDirectoryTargets() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: panelId))
        let tabId = try #require(workspace.surfaceIdFromPanelId(panelId))
        let tab = try #require(workspace.bonsplitController.tab(tabId))
        let pasteboard = NSPasteboard.general

        workspace.panelDirectories[panelId] = "/Users/test/Documents/project"
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)
        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestTabContextMenuItem: "copyFile",
            for: tab,
            inPane: paneId
        )

        let directoryCopyString = pasteboard.string(forType: .string)
        let directoryCopyFileURLs = fileURLs(on: pasteboard)
        #expect(directoryCopyString == "before")
        #expect(directoryCopyFileURLs.isEmpty)
    }

    @Test func bonsplitPathActionsUseGenericCustomMenuItems() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panelId))

        workspace.panelDirectories[panelId] = "/Users/test/Documents/project"

        let items = workspace.bonsplitController.tabContextMenuItemsProvider?(tabId, PaneID()) ?? []
        #expect(items == [
            TabContextMenuItem(id: "revealInFinder", title: "Reveal in Finder"),
            TabContextMenuItem(id: "copyPath", title: "Copy Path"),
        ])
        #expect(!TabContextAction.allCases.map(\.rawValue).contains("revealInFinder"))
        #expect(!TabContextAction.allCases.map(\.rawValue).contains("copyFile"))
        #expect(!TabContextAction.allCases.map(\.rawValue).contains("copyPath"))
    }

    private func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) ?? []
        return objects.compactMap { object in
            if let url = object as? URL { return url }
            if let url = object as? NSURL { return url as URL }
            return nil
        }
    }
}
