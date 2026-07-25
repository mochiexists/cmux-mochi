import AppKit
import Bonsplit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized) struct TabContextMenuPathTests {
    @Test func providerTracksDirectoryAndFileBackedPanels() throws {
        let workspace = Workspace()
        let defaultPanelID = try #require(workspace.focusedPanelId)
        let defaultTabID = try #require(workspace.surfaceIdFromPanelId(defaultPanelID))

        #expect(workspace.bonsplitController.tabContextMenuItemsProvider?(defaultTabID, PaneID()) == [])

        workspace.panelDirectories[defaultPanelID] = "/Users/test/Documents/project"
        let directoryItems = workspace.bonsplitController.tabContextMenuItemsProvider?(defaultTabID, PaneID()) ?? []
        #expect(directoryItems.map(\.id) == ["revealInFinder", "copyPath"])

        let paneID = try #require(workspace.bonsplitController.allPaneIds.first)
        let markdown = try #require(
            workspace.newMarkdownSurface(
                inPane: paneID,
                filePath: "/Users/test/Documents/notes/readme.md"
            )
        )
        let markdownTabID = try #require(workspace.surfaceIdFromPanelId(markdown.id))
        let fileItems = workspace.bonsplitController.tabContextMenuItemsProvider?(markdownTabID, PaneID()) ?? []

        #expect(fileItems.map(\.id) == ["revealInFinder", "copyFile", "copyPath"])
        #expect(fileItems.map(\.title) == ["Reveal in Finder", "Copy .md File", "Copy Path"])
    }

    @Test func resolverPrefersFilesAndIgnoresRemoteBrowserURLs() {
        let markdown = Workspace.tabPathActionTarget(
            filePath: "  /Users/test/readme.md  ",
            browserURL: nil,
            directory: "/Users/test"
        )
        #expect(markdown?.path == "/Users/test/readme.md")
        #expect(markdown?.isFile == true)

        let localBrowser = Workspace.tabPathActionTarget(
            filePath: nil,
            browserURL: URL(fileURLWithPath: "/Users/test/index.html"),
            directory: nil
        )
        #expect(localBrowser?.path == "/Users/test/index.html")
        #expect(localBrowser?.isFile == true)

        let remoteBrowser = Workspace.tabPathActionTarget(
            filePath: nil,
            browserURL: URL(string: "https://example.com"),
            directory: "/Users/test/project"
        )
        #expect(remoteBrowser?.path == "/Users/test/project")
        #expect(remoteBrowser?.isFile == false)
    }

    @Test func copyFileWritesPasteableFileObjectAndPathFallback() throws {
        let workspace = Workspace()
        let paneID = try #require(workspace.bonsplitController.allPaneIds.first)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-copy-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("readme.md")
        try "# hello\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let panel = try #require(workspace.newMarkdownSurface(inPane: paneID, filePath: fileURL.path))
        let tabID = try #require(workspace.surfaceIdFromPanelId(panel.id))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        workspace.performTabPathContextMenuItem("copyFile", for: tabID)

        #expect(fileURLs(on: pasteboard).map(\.path) == [fileURL.path])
        #expect(pasteboard.string(forType: .string) == fileURL.path)
    }

    @Test func copyFileIgnoresDirectoryTargets() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let tabID = try #require(workspace.surfaceIdFromPanelId(panelID))
        let pasteboard = NSPasteboard.general
        workspace.panelDirectories[panelID] = "/Users/test/Documents/project"
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)

        workspace.performTabPathContextMenuItem("copyFile", for: tabID)

        #expect(pasteboard.string(forType: .string) == "before")
        #expect(fileURLs(on: pasteboard).isEmpty)
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
