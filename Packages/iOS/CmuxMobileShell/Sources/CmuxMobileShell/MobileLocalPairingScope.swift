import Foundation

/// Fork (cmux Mochi): the account-free stand-in for a Stack user id.
///
/// Paired Macs are stored and loaded under a scope, normally the signed-in Stack
/// user. Account-free pairings had no scope at all, and `nil` cannot be used as
/// one: `loadAll(stackUserID: nil)` reads EVERY locally stored Mac across every
/// Stack account, which is exactly why aggregation refuses to run without a
/// concrete user (see `refreshSecondaryMacWorkspaces`). The consequence was that
/// pairing a second Mac silently replaced the first instead of joining it.
///
/// So give the no-account path a real scope of its own: one stable id per install,
/// namespaced so it can never be mistaken for — or collide with — a Stack user id.
/// Account-owned rows and account-free rows then live in disjoint scopes, and
/// neither can read the other.
///
/// The id identifies nothing but this install. It is a random UUID, never sent
/// anywhere, and is deliberately NOT derived from a device identifier so it cannot
/// become a tracking vector.
enum MobileLocalPairingScope {
    /// Namespace prefix. Stack user ids are opaque, but they are never issued with
    /// this prefix, so the two spaces cannot overlap.
    static let prefix = "mochi-local:"

    private static let defaultsKey = "mochi.pairing.localScopeID"

    /// Whether a scope id belongs to the account-free space rather than an account.
    static func isLocal(_ userID: String?) -> Bool {
        userID?.hasPrefix(prefix) == true
    }

    /// The stable account-free scope id for this install, minting one on first use.
    ///
    /// - Parameter defaults: injected so tests get an isolated suite.
    static func identifier(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: defaultsKey),
           existing.hasPrefix(prefix),
           existing.count > prefix.count {
            return existing
        }
        let minted = prefix + UUID().uuidString
        defaults.set(minted, forKey: defaultsKey)
        return minted
    }
}
