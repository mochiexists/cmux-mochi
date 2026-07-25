import AppKit
import Bonsplit
import Foundation

extension Workspace {
    private static let revealInFinderTabContextMenuItemID = "revealInFinder"
    private static let copyFileTabContextMenuItemID = "copyFile"
    private static let copyPathTabContextMenuItemID = "copyPath"

    func tabPathContextMenuItems(for tabID: TabID) -> [TabContextMenuItem] {
        guard let target = tabPathActionTarget(tabID: tabID) else { return [] }
        var items = [
            TabContextMenuItem(
                id: Self.revealInFinderTabContextMenuItemID,
                title: String(localized: "contextMenu.revealInFinder", defaultValue: "Reveal in Finder")
            )
        ]
        if target.isFile {
            items.append(TabContextMenuItem(
                id: Self.copyFileTabContextMenuItemID,
                title: FileExternalOpenText.copyFileLabel(fileURL: URL(fileURLWithPath: target.path))
            ))
        }
        items.append(TabContextMenuItem(
            id: Self.copyPathTabContextMenuItemID,
            title: String(localized: "contextMenu.copyPath", defaultValue: "Copy Path")
        ))
        return items
    }

    func performTabPathContextMenuItem(_ identifier: String, for tabID: TabID) {
        guard let target = tabPathActionTarget(tabID: tabID) else { return }
        switch identifier {
        case Self.revealInFinderTabContextMenuItemID:
            FileExternalOpenAction.revealInFinder(path: target.path, isFile: target.isFile)
        case Self.copyPathTabContextMenuItemID:
            FileExternalOpenAction.copyPath(target.path)
        case Self.copyFileTabContextMenuItemID where target.isFile:
            FileExternalOpenAction.copyFile(fileURL: URL(fileURLWithPath: target.path))
        default:
            break
        }
    }

    nonisolated static func tabPathActionTarget(
        filePath: String?,
        browserURL: URL?,
        directory: String?
    ) -> (path: String, isFile: Bool)? {
        if let filePath = normalizedTabPath(filePath) {
            return (filePath, true)
        }
        if let browserURL, browserURL.isFileURL,
           let browserPath = normalizedTabPath(browserURL.path) {
            return (browserPath, true)
        }
        if let directory = normalizedTabPath(directory) {
            return (directory, false)
        }
        return nil
    }

    private func tabPathActionTarget(tabID: TabID) -> (path: String, isFile: Bool)? {
        let panel = panelIdFromSurfaceId(tabID).flatMap { panels[$0] }
        let directory = panelIdFromSurfaceId(tabID)
            .flatMap { panelDirectories[$0] }
        return Self.tabPathActionTarget(
            filePath: (panel as? FileBackedPanel)?.filePath,
            browserURL: (panel as? BrowserPanel)?.currentURL,
            directory: directory
        )
    }

    private nonisolated static func normalizedTabPath(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
