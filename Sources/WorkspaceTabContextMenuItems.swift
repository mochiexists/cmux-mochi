import Foundation
import Bonsplit

enum WorkspaceTabContextMenuItems {
    static func pathActions(
        target: (path: String, isFile: Bool),
        revealInFinderId: String,
        copyFileId: String,
        copyPathId: String
    ) -> [TabContextMenuItem] {
        var items = [
            TabContextMenuItem(
                id: revealInFinderId,
                title: String(localized: "contextMenu.revealInFinder", defaultValue: "Reveal in Finder")
            )
        ]
        if target.isFile {
            items.append(TabContextMenuItem(
                id: copyFileId,
                title: FileExternalOpenText.copyFileLabel(fileURL: URL(fileURLWithPath: target.path))
            ))
        }
        items.append(TabContextMenuItem(
            id: copyPathId,
            title: String(localized: "contextMenu.copyPath", defaultValue: "Copy Path")
        ))
        return items
    }
}
