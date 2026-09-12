import AppKit
import Bonsplit

/// Right-click menu for the pane tab bar's new-browser (globe) button.
///
/// Offers one checkable item, "Open Links in Default Browser", that flips whether
/// terminal links open in the cmux browser or leave for the user's default browser.
/// It writes the same `BrowserLinkOpenSettings` key that Settings and the command
/// palette use, so every entry point stays in agreement, and it reports which split
/// action to highlight so the globe turns accent-colored while links open externally.
@MainActor
struct SurfaceTabBarBrowserLinkTargetMenu {
    static let toggleItemIdentifier = NSUserInterfaceItemIdentifier(
        "cmux.surfaceTabBar.newBrowser.openLinksInDefaultBrowser"
    )

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// False while the cmux browser is switched off entirely; links always open
    /// externally then, so the toggle is shown checked but disabled.
    var isBrowserEnabled: Bool {
        BrowserAvailabilitySettings.isEnabled(defaults: defaults)
    }

    /// True when clicking a terminal link leaves cmux for the default browser.
    var opensLinksInDefaultBrowser: Bool {
        !BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowser(defaults: defaults)
    }

    /// Split actions the tab bar should render in the accent color for this state.
    var highlightedSplitActions: Set<BonsplitConfiguration.SplitActionButton.Action> {
        opensLinksInDefaultBrowser ? [.newBrowser] : []
    }

    /// Flips the link target. A no-op while the cmux browser is disabled.
    func toggleLinkTarget() {
        guard isBrowserEnabled else { return }
        let openInCmuxBrowser = opensLinksInDefaultBrowser
        defaults.set(openInCmuxBrowser, forKey: BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowserKey)
    }

    /// Builds the context menu. `onToggle` runs after the setting flips so the caller
    /// can refresh anything that mirrors it.
    func makeMenu(onToggle: @escaping @MainActor () -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let item = NSMenuItem(
            title: String(
                localized: "surfaceTabBar.newBrowser.openLinksInDefaultBrowser",
                defaultValue: "Open Links in Default Browser"
            ),
            action: #selector(SurfaceTabBarBrowserLinkTargetMenuAction.toggleLinkTarget(_:)),
            keyEquivalent: ""
        )
        item.identifier = Self.toggleItemIdentifier
        item.state = opensLinksInDefaultBrowser ? .on : .off
        item.isEnabled = isBrowserEnabled

        let target = SurfaceTabBarBrowserLinkTargetMenuAction { [self] in
            toggleLinkTarget()
            onToggle()
        }
        item.target = target
        // NSMenuItem holds its target weakly; keep the box alive for the menu's lifetime.
        item.representedObject = target
        menu.addItem(item)
        return menu
    }
}

/// Objective-C-visible target that forwards the menu item's action to a closure.
@MainActor
private final class SurfaceTabBarBrowserLinkTargetMenuAction: NSObject {
    private let handler: @MainActor () -> Void

    init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    @objc func toggleLinkTarget(_ sender: Any?) {
        handler()
    }
}
