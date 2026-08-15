import Foundation

@MainActor
extension MobileShellComposite {
    /// Capture the current signed-in account/team scope for async list loads and
    /// route writes.
    func currentScopeSnapshot(userID explicitUserID: String? = nil) async -> MobileShellScopeSnapshot? {
        guard isSignedIn else { return nil }
        // Fork (cmux Mochi): an account-free session is authorized by an attach
        // ticket, so there is no Stack user to scope by — and `nil` must never be
        // used as a scope, because it reads every stored Mac across all accounts.
        // Fall back to this install's own scope id instead, which keeps
        // account-free Macs in a space of their own that no account can read.
        // Without this, aggregation bailed out and each newly paired Mac silently
        // replaced the previous one.
        let resolvedUserID = explicitUserID
            ?? identityProvider?.currentUserID
            ?? MobileLocalPairingScope.identifier()
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
        guard isSignedIn,
              secondaryAggregationScopeGeneration == scope.generation else {
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
