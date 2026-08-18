import AppKit
import Foundation

/// Single action path behind "Copy Workspace Path", shared by the AppKit sidebar
/// row menu and the SwiftUI workspace context menu so both surfaces copy the
/// same thing. The path is the workspace's Finder directory — the same value
/// "Show in Finder" reveals.
enum WorkspacePathClipboard {
    static let menuTitle = String(
        localized: "contextMenu.copyWorkspacePath",
        defaultValue: "Copy Workspace Path"
    )

    static func copy(_ path: String?) {
        guard let path, !path.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }
}
