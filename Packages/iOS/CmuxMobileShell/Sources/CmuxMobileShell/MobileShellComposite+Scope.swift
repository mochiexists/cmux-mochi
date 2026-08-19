import Foundation

@MainActor
extension MobileShellComposite {
    /// Capture the current signed-in account/team scope for async list loads and
    /// route writes.
    func currentScopeSnapshot(userID explicitUserID: String? = nil) async -> MobileShellScopeSnapshot? {
        // Fork (cmux Mochi): an account-free session is authorized by an attach
        // ticket, so there is no Stack user to scope by — and `nil` must never be
        // used as a scope, because it reads every stored Mac across all accounts.
        // Fall back to this install's own scope id instead, which keeps
        // account-free Macs in a space of their own that no account can read.
        // Without this, aggregation bailed out and each newly paired Mac silently
        // replaced the previous one.
        //
        // The shell store's `isSignedIn` only ever becomes true through the Stack
        // auth bridge, which an account-free (skipped sign-in / QR-paired) session
        // never crosses — so the local-scope fallback must not sit behind it, or
        // `refreshSecondaryMacWorkspaces` bails forever and every non-foreground
        // Mac shows "Not connected" while the foreground one works. Signed out,
        // the identity provider is deliberately ignored: a stale cached account id
        // must not resurrect an account scope the session no longer holds.
        let resolvedUserID: String
        if isSignedIn {
            resolvedUserID = explicitUserID
                ?? identityProvider?.currentUserID
                ?? MobileLocalPairingScope.identifier()
        } else {
            // Account-free needs evidence of a pairing before minting a scope:
            // pre-onboarding there is nothing to load, and a signed-out account
            // session must not silently continue under a fresh local scope.
            guard hasKnownPairedMac else { return nil }
            if let explicitUserID, !MobileLocalPairingScope.isLocal(explicitUserID) {
                return nil
            }
            resolvedUserID = explicitUserID ?? MobileLocalPairingScope.identifier()
        }
        guard !resolvedUserID.isEmpty else { return nil }
        let userID = resolvedUserID
        // A real account never adopts the local scope, and the local scope never
        // impersonates an account: only compare when both sides are accounts.
        if let currentUserID = identityProvider?.currentUserID,
           currentUserID != userID,
           !MobileLocalPairingScope.isLocal(userID) {
            return nil
        }
        return MobileShellScopeSnapshot(
            userID: userID,
            teamID: await teamIDProvider(),
            generation: secondaryAggregationScopeGeneration
        )
    }

    func pairedMacScopeKey(_ scope: MobileShellScopeSnapshot) -> String {
        makePairedMacScopeKey(userID: scope.userID, teamID: scope.teamID)
    }

    func makePairedMacScopeKey(userID: String, teamID: String?) -> String {
        "\(userID)\t\(teamID ?? "")"
    }

    func userWideScope(from scope: MobileShellScopeSnapshot) -> MobileShellScopeSnapshot {
        MobileShellScopeSnapshot(userID: scope.userID, teamID: nil, generation: scope.generation)
    }

    /// Whether a previously-captured list-load scope is still current.
    func isScopeCurrent(_ scope: MobileShellScopeSnapshot) async -> Bool {
        guard secondaryAggregationScopeGeneration == scope.generation else {
            return false
        }
        // Fork (cmux Mochi): account-free sessions never sign the shell in (see
        // `currentScopeSnapshot`), so a signed-in requirement here would invalidate
        // every local scope mid-flight. Signed out, only the local scope stays
        // valid; an account scope is genuinely stale the moment its session ends.
        if !isSignedIn, !MobileLocalPairingScope.isLocal(scope.userID) {
            return false
        }
        // Fork (cmux Mochi): a local (account-free) scope is never invalidated by
        // the absence of a Stack user — that absence is its whole premise. Only
        // compare account ids when the captured scope is itself an account scope.
        if !MobileLocalPairingScope.isLocal(scope.userID),
           let currentUserID = identityProvider?.currentUserID,
           currentUserID != scope.userID {
            return false
        }
        // Signing IN must invalidate a local scope: the session is now account-owned
        // and must not keep reading or writing the account-free space.
        if MobileLocalPairingScope.isLocal(scope.userID),
           identityProvider?.currentUserID?.isEmpty == false {
            return false
        }
        return await teamIDProvider() == scope.teamID
    }
}
