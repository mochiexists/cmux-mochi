import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
import os

private let pairedMacPersistenceLog = Logger(
    subsystem: "com.cmuxterm.app",
    category: "MobilePairedMacPersistence"
)

enum PairedMacInstanceTagUpdate {
    case preserve
    /// A no-tag fresh attach may persist while the row is still unclaimed, but
    /// cannot mutate routes owned by an authenticated tagged instance.
    case preserveOnlyIfUnclaimed
    case replace(String?)
}

@MainActor
extension MobileShellComposite {
    /// Persist a connection only with authority proven by authenticated status.
    /// Returns false when persistence fails or a no-tag fresh attach finds an
    /// existing tagged owner.
    @discardableResult
    func persistPairedMacFromTicket(
        _ ticket: CmxAttachTicket,
        instanceTagUpdate: PairedMacInstanceTagUpdate = .preserve,
        displayNameOverride: String? = nil,
        userAuthorizedTailscaleRoutes: [CmxAttachRoute] = [],
        ifStillCurrent: (() -> Bool)? = nil
    ) async -> Bool {
        guard let pairedMacStore,
              !ticket.macDeviceID.isEmpty,
              ticket.macDeviceID != "manual-ticket-request",
              !ticket.macDeviceID.hasPrefix("manual-") else { return true }
        // Fork (cmux Mochi): store account-free pairings under this install's local
        // scope rather than nil. A nil scope is unreadable by aggregation (which
        // refuses nil to avoid reading every account's Macs), so Macs saved that way
        // could never be listed together — each new pairing displaced the last.
        let scope = await currentScopeSnapshot(userID: identityProvider?.currentUserID)
        let stackUserID = scope?.userID ?? identityProvider?.currentUserID
        let ticketDisplayName = displayNameOverride ?? ticket.macDisplayName
        // Starts false and is earned by an actual write. It was initialised to
        // `true`, so every early return below — and a write closure that never
        // ran at all — reported success while persisting nothing. A pairing then
        // logged "persisted=true" with an empty store, and the phone had no Mac
        // to dial on the next cold launch: the exact failure this function
        // exists to prevent, reported as a success.
        var accepted = false
        await performSerializedPairedMacWrite(ifStillCurrent: ifStillCurrent) { [weak self] in
            guard let self else { return }
            if let scope, await !self.isScopeCurrent(scope) {
                pairedMacPersistenceLog.error(
                    "paired mac not persisted: scope changed during write"
                )
                return
            }
            let scopedMacs = (try? await pairedMacStore.loadAll(
                stackUserID: stackUserID, teamID: scope?.teamID
            )) ?? []
            let expectedStoredTag: String?
            switch instanceTagUpdate {
            case .preserve:
                expectedStoredTag = self.activeMacInstanceTag
            case .preserveOnlyIfUnclaimed:
                expectedStoredTag = nil
            case .replace(let reportedTag):
                expectedStoredTag = reportedTag
            }
            let exactExisting = scopedMacs.first {
                $0.macDeviceID == ticket.macDeviceID
                    && $0.instanceTag == expectedStoredTag
            }
            let physicalMatches = scopedMacs.filter {
                $0.macDeviceID == ticket.macDeviceID
            }
            let existing: MobilePairedMac?
            if let exactExisting {
                existing = exactExisting
            } else if case .preserve = instanceTagUpdate,
                      expectedStoredTag == nil {
                // Before the foreground status probe reports its tag, the
                // selected row is the only safe authority fallback. Never pick
                // an arbitrary sibling merely because it was seen more recently.
                existing = physicalMatches.first(where: \.isActive)
                    ?? (physicalMatches.count == 1 ? physicalMatches[0] : nil)
            } else {
                existing = nil
            }
            let storedTag = existing?.instanceTag
            var displayName = ticketDisplayName ?? existing?.displayName
            if displayName == nil {
                let knownMacs = (try? await pairedMacStore.loadAll(
                    stackUserID: nil, teamID: scope?.teamID
                )) ?? []
                displayName = knownMacs.first {
                    $0.macDeviceID == ticket.macDeviceID
                }?.displayName
            }
            let instanceTag: String?
            let authorityIsUnchanged: Bool
            switch instanceTagUpdate {
            case .preserve:
                instanceTag = storedTag
                authorityIsUnchanged = true
            case .preserveOnlyIfUnclaimed:
                instanceTag = nil
                authorityIsUnchanged = true
            case .replace(let reportedTag):
                instanceTag = reportedTag
                authorityIsUnchanged = reportedTag == storedTag
            }
            let storedRoutes = existing?.routes ?? []
            let routes = authorityIsUnchanged
                && ticket.routes.count == 1 && !storedRoutes.isEmpty
                ? Self.mergedReconnectRoutes(
                    ticketRoutes: ticket.routes, storedRoutes: storedRoutes
                )
                : ticket.routes
            do {
                if case .preserveOnlyIfUnclaimed = instanceTagUpdate {
                    accepted = try await pairedMacStore.upsertRoutesIfAuthorized(
                        macDeviceID: ticket.macDeviceID,
                        displayName: displayName,
                        routes: routes,
                        condition: .unclaimed,
                        markActive: true,
                        stackUserID: stackUserID,
                        teamID: scope?.teamID,
                        now: Date()
                    )
                    guard accepted else { return }
                } else {
                    try await pairedMacStore.upsert(
                        macDeviceID: ticket.macDeviceID,
                        displayName: displayName,
                        routes: routes,
                        instanceTag: instanceTag,
                        markActive: true,
                        stackUserID: stackUserID,
                        teamID: scope?.teamID,
                        now: Date()
                    )
                    // `upsert` returns Void, and the build-compatibility wrapper
                    // DROPS a write for a Mac whose instance tag does not match
                    // this build's scope — silently, without throwing. Assuming
                    // success here is what produced a "pairing persisted=true"
                    // log against an empty store. Read the row back: the only
                    // trustworthy evidence that the write survived every wrapper
                    // between here and the database.
                    let stored = (try? await pairedMacStore.loadAll(
                        stackUserID: stackUserID, teamID: scope?.teamID
                    )) ?? []
                    accepted = stored.contains { $0.macDeviceID == ticket.macDeviceID }
                    if !accepted {
                        pairedMacPersistenceLog.error(
                            """
                            paired mac write was dropped for \
                            \(ticket.macDeviceID, privacy: .public) tag=\
                            \(instanceTag ?? "nil", privacy: .public) — most likely \
                            build-compatibility: this iOS build's scope does not match \
                            the Mac's instance tag
                            """
                        )
                        return
                    }
                }
                if !userAuthorizedTailscaleRoutes.isEmpty {
                    // The user just proved control of this Mac by entering its
                    // pairing code; record the device-local grant so later
                    // preference-ordered dials use the evidence path.
                    do {
                        try await pairedMacStore.authorizeUserTailscaleRoutes(
                            macDeviceID: ticket.macDeviceID,
                            instanceTag: instanceTag,
                            stackUserID: stackUserID,
                            teamID: scope?.teamID,
                            routes: userAuthorizedTailscaleRoutes
                        )
                    } catch {
                        pairedMacPersistenceLog.error(
                            "user tailscale grant persist failed: \(String(describing: error), privacy: .public)"
                        )
                    }
                }
                await self.clearHiddenMacDeviceID(
                    ticket.macDeviceID,
                    instanceTag: instanceTag,
                    scope: scope
                )
                self.hasKnownPairedMac = true
            } catch {
                accepted = false
                pairedMacPersistenceLog.error(
                    "paired mac upsert failed: \(String(describing: error), privacy: .public)"
                )
            }
        }
        return accepted
    }
}
