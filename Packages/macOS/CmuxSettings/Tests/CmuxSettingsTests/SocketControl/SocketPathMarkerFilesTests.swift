import Testing
@testable import CmuxSettings

@Test func markerFilesAreVariantAware() {
    #expect(SocketPathMarkerFiles.variant(
        bundleIdentifier: "com.cmux-mochi",
        environment: [:]
    ) == .stable)
    #expect(SocketPathMarkerFiles.variant(
        bundleIdentifier: "com.cmux-mochi.nightly",
        environment: [:]
    ) == .nightly(slug: nil))
    #expect(SocketPathMarkerFiles.variant(
        bundleIdentifier: "com.cmux-mochi.debug.agent",
        environment: [:]
    ) == .dev(slug: "agent"))
    #expect(SocketPathMarkerFiles.variant(
        bundleIdentifier: "com.cmux-mochi.debug",
        environment: ["CMUX_TAG": "Issue 3542"]
    ) == .dev(slug: "issue-3542"))
    #expect(SocketPathMarkerFiles.variant(
        bundleIdentifier: "com.cmux-mochi.debug",
        environment: ["CMUX_TAG": "café"]
    ) == .dev(slug: "caf"))
}

@Test func defaultSocketPathsStayVariantScoped() {
    #expect(SocketPathMarkerFiles.defaultSocketPath(
        bundleIdentifier: "com.cmux-mochi",
        environment: [:],
        isDebugBuild: false,
        stableSocketPath: "/stable/cmux.sock"
    ) == "/stable/cmux.sock")
    #expect(SocketPathMarkerFiles.defaultSocketPath(
        bundleIdentifier: "com.cmux-mochi.nightly",
        environment: [:],
        isDebugBuild: false,
        stableSocketPath: "/stable/cmux.sock"
    ) == "/tmp/cmux-nightly.sock")
    #expect(SocketPathMarkerFiles.defaultSocketPath(
        bundleIdentifier: "com.cmux-mochi.staging.my-feature",
        environment: [:],
        isDebugBuild: false,
        stableSocketPath: "/stable/cmux.sock"
    ) == "/tmp/cmux-staging-my-feature.sock")
    #expect(SocketPathMarkerFiles.defaultSocketPath(
        bundleIdentifier: "com.cmux-mochi.debug",
        environment: ["CMUX_TAG": "Issue 3542"],
        isDebugBuild: false,
        stableSocketPath: "/stable/cmux.sock"
    ) == "/tmp/cmux-debug-issue-3542.sock")
}

/// A renamed or forked bundle id must still resolve to its own channel and tag.
///
/// The channel checks are anchored to one vendor's bundle id, so before the
/// structural fallback every non-upstream id fell through to `.stable`. Tagged
/// builds then all bound the single stable socket instead of
/// `/tmp/cmux-debug-<tag>.sock`, which silently broke tag isolation, the
/// tag-bound debug CLI, and iOS auto-pair.
@Test func variantResolvesForNonUpstreamBundleIdentifiers() {
    #expect(SocketPathMarkerFiles.variant(
        bundleIdentifier: "com.cmux-mochi",
        environment: [:]
    ) == .stable)
    #expect(SocketPathMarkerFiles.variant(
        bundleIdentifier: "com.cmux-mochi.debug",
        environment: [:]
    ) == .dev(slug: nil))
    #expect(SocketPathMarkerFiles.variant(
        bundleIdentifier: "com.cmux-mochi.debug.clean.trunk",
        environment: [:]
    ) == .dev(slug: "clean-trunk"))
    #expect(SocketPathMarkerFiles.variant(
        bundleIdentifier: "com.cmux-mochi.debug",
        environment: ["CMUX_TAG": "Issue 3542"]
    ) == .dev(slug: "issue-3542"))
    #expect(SocketPathMarkerFiles.variant(
        bundleIdentifier: "com.cmux-mochi.nightly",
        environment: [:]
    ) == .nightly(slug: nil))
    #expect(SocketPathMarkerFiles.variant(
        bundleIdentifier: "com.cmux-mochi.staging.my-feature",
        environment: [:]
    ) == .staging(slug: "my-feature"))
    // A tag named after another channel must not be mistaken for that channel.
    #expect(SocketPathMarkerFiles.variant(
        bundleIdentifier: "com.cmux-mochi.debug.nightly",
        environment: [:]
    ) == .dev(slug: "nightly"))
}
