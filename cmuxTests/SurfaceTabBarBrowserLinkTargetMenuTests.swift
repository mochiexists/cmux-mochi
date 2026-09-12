import AppKit
import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Surface tab bar browser link target menu")
struct SurfaceTabBarBrowserLinkTargetMenuTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "surface-tab-bar-browser-link-target-menu-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func toggleItem(in menu: NSMenu) throws -> NSMenuItem {
        try #require(menu.items.first { $0.identifier == SurfaceTabBarBrowserLinkTargetMenu.toggleItemIdentifier })
    }

    @Test func defaultsToCmuxBrowserWithNoHighlight() throws {
        let defaults = makeDefaults()
        let menu = SurfaceTabBarBrowserLinkTargetMenu(defaults: defaults)

        #expect(!menu.opensLinksInDefaultBrowser)
        #expect(menu.highlightedSplitActions.isEmpty)
        let item = try toggleItem(in: menu.makeMenu(onToggle: {}))
        #expect(item.state == .off)
        #expect(item.isEnabled)
    }

    @Test func togglingFlipsTheSharedSettingAndHighlightsTheGlobe() throws {
        let defaults = makeDefaults()
        let menu = SurfaceTabBarBrowserLinkTargetMenu(defaults: defaults)

        menu.toggleLinkTarget()

        #expect(!BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowser(defaults: defaults))
        #expect(menu.opensLinksInDefaultBrowser)
        #expect(menu.highlightedSplitActions == [.newBrowser])
        #expect(try toggleItem(in: menu.makeMenu(onToggle: {})).state == .on)

        menu.toggleLinkTarget()

        #expect(BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowser(defaults: defaults))
        #expect(menu.highlightedSplitActions.isEmpty)
    }

    @Test func menuItemActionTogglesAndNotifies() throws {
        let defaults = makeDefaults()
        let menu = SurfaceTabBarBrowserLinkTargetMenu(defaults: defaults)
        var toggleCount = 0
        let nsMenu = menu.makeMenu { toggleCount += 1 }
        let item = try toggleItem(in: nsMenu)

        let action = try #require(item.action)
        let target = try #require(item.target)
        #expect(NSApplication.shared.sendAction(action, to: target, from: item))

        #expect(toggleCount == 1)
        #expect(menu.opensLinksInDefaultBrowser)
    }

    @Test func disabledBrowserShowsExternalTargetLockedOn() throws {
        let defaults = makeDefaults()
        defaults.set(true, forKey: BrowserAvailabilitySettings.disabledKey)
        let menu = SurfaceTabBarBrowserLinkTargetMenu(defaults: defaults)

        #expect(menu.opensLinksInDefaultBrowser)
        #expect(menu.highlightedSplitActions == [.newBrowser])
        let item = try toggleItem(in: menu.makeMenu(onToggle: {}))
        #expect(item.state == .on)
        #expect(!item.isEnabled)

        menu.toggleLinkTarget()
        #expect(defaults.object(forKey: BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowserKey) == nil)
    }
}
