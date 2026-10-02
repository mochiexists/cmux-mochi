import AppKit
import Dispatch

/// The shared left/right-sidebar actions resolved by keyboard shortcuts.
enum SidebarToggleShortcutCommand: CaseIterable, Equatable {
    case leftSidebar
    case rightSidebar

    var shortcutAction: KeyboardShortcutSettings.Action {
        switch self {
        case .leftSidebar:
            return .toggleSidebar
        case .rightSidebar:
            return .toggleRightSidebar
        }
    }

    static func matching(
        in candidates: [Self] = Self.allCases,
        using matches: (KeyboardShortcutSettings.Action) -> Bool
    ) -> Self? {
        candidates.first { matches($0.shortcutAction) }
    }

    func perform(
        toggleLeftSidebar: () -> Void,
        toggleRightSidebar: () -> Void
    ) {
        switch self {
        case .leftSidebar:
            toggleLeftSidebar()
        case .rightSidebar:
            toggleRightSidebar()
        }
    }
}

extension AppDelegate {
    func performSidebarToggleShortcutCommand(
        _ command: SidebarToggleShortcutCommand,
        preferredWindow: NSWindow?
    ) {
        command.perform(
            toggleLeftSidebar: {
                _ = self.toggleSidebarInActiveMainWindow(
                    preferredWindow: preferredWindow
                )
            },
            toggleRightSidebar: {
                DispatchQueue.main.async { [weak self, weak preferredWindow] in
                    _ = self?.toggleRightSidebarInActiveMainWindow(
                        preferredWindow: preferredWindow
                    )
                }
            }
        )
    }
}
