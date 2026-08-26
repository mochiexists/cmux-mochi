import Testing
@testable import CmuxSettingsUI

@Suite("Pro upgrade presentation policy")
struct ProUpgradePresentationPolicyTests {
    @Test(arguments: [
        "com.cmux-mochi",
        "com.cmux-mochi.debug",
        "com.cmux-mochi.nightly",
    ])
    func mochiBuildKeepsExplanationButNeverOffersUpgrade(bundleIdentifier: String) {
        #expect(
            ProUpgradePresentationPolicy.showsAccountCard(
                bundleIdentifier: bundleIdentifier,
                upstreamUpgradeAvailable: false
            )
        )
        #expect(
            !ProUpgradePresentationPolicy.showsUpgradeAction(
                bundleIdentifier: bundleIdentifier,
                isProActive: false,
                canManageBilling: false
            )
        )
        #expect(
            !ProUpgradePresentationPolicy.showsUpgradeAction(
                bundleIdentifier: bundleIdentifier,
                isProActive: true,
                canManageBilling: true
            )
        )
    }

    @Test func upstreamBuildRetainsNormalUpgradeBehavior() {
        let bundleIdentifier = "com.cmuxterm.app"
        #expect(
            !ProUpgradePresentationPolicy.showsAccountCard(
                bundleIdentifier: bundleIdentifier,
                upstreamUpgradeAvailable: false
            )
        )
        #expect(
            ProUpgradePresentationPolicy.showsAccountCard(
                bundleIdentifier: bundleIdentifier,
                upstreamUpgradeAvailable: true
            )
        )
        #expect(
            ProUpgradePresentationPolicy.showsUpgradeAction(
                bundleIdentifier: bundleIdentifier,
                isProActive: false,
                canManageBilling: false
            )
        )
        #expect(
            !ProUpgradePresentationPolicy.showsUpgradeAction(
                bundleIdentifier: bundleIdentifier,
                isProActive: true,
                canManageBilling: false
            )
        )
        #expect(
            ProUpgradePresentationPolicy.showsUpgradeAction(
                bundleIdentifier: bundleIdentifier,
                isProActive: true,
                canManageBilling: true
            )
        )
    }
}
