import AppKit
import Bonsplit

extension Workspace {
    /// Hooks the pane tab bar's new-browser button: a right-click shows the link-target
    /// menu, and the globe stays accent-colored while terminal links open externally.
    func installSurfaceTabBarBrowserLinkTargetMenu() {
        refreshSurfaceTabBarBrowserLinkTargetHighlight()

        bonsplitController.splitActionSecondaryClickHandler = { [weak self] button, _, anchorView, event in
            guard button.action == .newBrowser, let self else { return false }
            let menu = SurfaceTabBarBrowserLinkTargetMenu().makeMenu { [weak self] in
                self?.refreshSurfaceTabBarBrowserLinkTargetHighlight()
            }
            NSMenu.popUpContextMenu(menu, with: event, for: anchorView)
            return true
        }

        // Settings and the command palette write the same key; mirror their changes.
        surfaceTabBarBrowserLinkTargetTask = Task { [weak self] in
            let changes = NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification)
            for await _ in changes {
                guard let self else { return }
                refreshSurfaceTabBarBrowserLinkTargetHighlight()
            }
        }
    }

    func refreshSurfaceTabBarBrowserLinkTargetHighlight() {
        let highlighted = SurfaceTabBarBrowserLinkTargetMenu().highlightedSplitActions
        guard bonsplitController.highlightedSplitActions != highlighted else { return }
        bonsplitController.highlightedSplitActions = highlighted
    }
}
