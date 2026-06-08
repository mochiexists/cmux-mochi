import Foundation
import Testing
@testable import CmuxBrowser

@Suite struct BrowserHistoryLocationTests {
    @Test func foldsDebugAndStagingNamespaces() {
        #expect(BrowserHistoryLocation.normalizedNamespace(bundleIdentifier: "com.cmux-mochi.debug.my-tag") == "com.cmux-mochi.debug")
        #expect(BrowserHistoryLocation.normalizedNamespace(bundleIdentifier: "com.cmux-mochi.staging.rc") == "com.cmux-mochi.staging")
        #expect(BrowserHistoryLocation.normalizedNamespace(bundleIdentifier: "com.cmux-mochi") == "com.cmux-mochi")
    }

    @Test func historyFileURLNestsUnderNamespace() {
        let root = URL(fileURLWithPath: "/tmp/appsupport", isDirectory: true)
        let location = BrowserHistoryLocation(applicationSupportDirectory: root, bundleIdentifier: "com.cmux-mochi.debug.tag")
        #expect(location.namespace == "com.cmux-mochi.debug")
        #expect(location.historyFileURL.path == "/tmp/appsupport/com.cmux-mochi.debug/browser_history.json")
    }

    @Test func legacyURLPresentOnlyWhenNamespaceDiffers() {
        let root = URL(fileURLWithPath: "/tmp/appsupport", isDirectory: true)
        let tagged = BrowserHistoryLocation(applicationSupportDirectory: root, bundleIdentifier: "com.cmux-mochi.debug.tag")
        #expect(tagged.legacyTaggedHistoryFileURL?.path == "/tmp/appsupport/com.cmux-mochi.debug.tag/browser_history.json")

        let prod = BrowserHistoryLocation(applicationSupportDirectory: root, bundleIdentifier: "com.cmux-mochi")
        #expect(prod.legacyTaggedHistoryFileURL == nil)
    }
}
