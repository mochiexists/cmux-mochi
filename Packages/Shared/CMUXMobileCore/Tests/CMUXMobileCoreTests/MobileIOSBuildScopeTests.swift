import Testing
@testable import CMUXMobileCore

/// A tagged build must resolve its own scope regardless of vendor prefix.
///
/// Anchoring the lookup to one vendor's bundle identifier resolved `nil` for
/// every tagged build of a fork or renamed app. The build-compatibility policy
/// then treated each saved-Mac write as belonging to another build and dropped
/// it, so a pairing that fully succeeded never persisted — and the next launch
/// had no Mac to dial.
@Test func buildScopeResolvesForAnyVendorBundleIdentifier() {
    #expect(
        MobileIOSBuildScope.current(
            infoDictionary: [:], bundleIdentifier: "dev.cmux.ios.clean-trunk"
        )?.value == "clean-trunk"
    )
    #expect(
        MobileIOSBuildScope.current(
            infoDictionary: [:], bundleIdentifier: "com.cmux-mochi.ios.clean-trunk"
        )?.value == "clean-trunk"
    )
    #expect(
        MobileIOSBuildScope.current(
            infoDictionary: [:], bundleIdentifier: "org.example.fork.ios.feat"
        )?.value == "feat"
    )
}

/// An untagged build owns the stable partition and must resolve no scope.
@Test func buildScopeIsAbsentForUntaggedBundleIdentifiers() {
    #expect(
        MobileIOSBuildScope.current(
            infoDictionary: [:], bundleIdentifier: "dev.cmux.ios"
        ) == nil
    )
    #expect(
        MobileIOSBuildScope.current(
            infoDictionary: [:], bundleIdentifier: "com.cmux-mochi.ios"
        ) == nil
    )
}

/// The bundle identifier wins over `CMUXDevTag` when both name a tag, matching
/// the precedence the store partitioning has always relied on.
@Test func buildScopePrefersBundleIdentifierOverInfoDictionary() {
    #expect(
        MobileIOSBuildScope.current(
            infoDictionary: ["CMUXDevTag": "feat"],
            bundleIdentifier: "dev.cmux.ios.other"
        )?.value == "other"
    )
    // With no tag in the identifier, the build's own stamp is the fallback.
    #expect(
        MobileIOSBuildScope.current(
            infoDictionary: ["CMUXDevTag": "feat"],
            bundleIdentifier: "dev.cmux.ios"
        )?.value == "feat"
    )
}
