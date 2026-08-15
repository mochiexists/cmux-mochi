import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

/// Fork (cmux Mochi): a ticket-authorized session must survive the failure of a
/// feature that legitimately needs a Stack account.
///
/// The bug this pins: a background notification reconcile always needs Stack auth,
/// so with no account it threw `.authorizationFailed`. That was classified as a
/// fatal authorization problem, which tore down a healthy paired session and told
/// the operator "This computer is signed in to a different cmux account. Sign out
/// and sign back in with that account." — wrong, and impossible to act on when the
/// whole point is to have no account.
@Suite struct MobileShellTicketAuthFailurePolicyTests {
    private func ticket(authToken: String?) throws -> CmxAttachTicket {
        try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "mac-1",
            macDisplayName: "Studio",
            routes: [
                try CmxAttachRoute(
                    id: "tailscale",
                    kind: .tailscale,
                    endpoint: .hostPort(host: "100.64.0.5", port: 58465)
                ),
            ],
            expiresAt: Date().addingTimeInterval(600),
            authToken: authToken
        )
    }

    @Test func ticketWithTokenIsTreatedAsTicketAuthorized() throws {
        #expect(MobileShellComposite.isTicketAuthorizedConnection(try ticket(authToken: "secret")))
    }

    /// A blank token is not testable here — `CmxAttachTicket.validate()` rejects it
    /// outright with `.emptyAuthToken`, so the whitespace case cannot reach this
    /// policy in the first place.
    @Test func ticketWithoutTokenFallsBackToAccountRules() throws {
        #expect(!MobileShellComposite.isTicketAuthorizedConnection(try ticket(authToken: nil)))
        #expect(!MobileShellComposite.isTicketAuthorizedConnection(nil))
    }

    /// Ticket expiry is the one authorization failure that must stay fatal: it
    /// genuinely ends the session's authorization, so the user has to re-pair.
    @Test func ticketExpiryRemainsFatal() {
        #expect(MobileShellComposite.isTicketExpiryFailure(MobileShellConnectionError.attachTicketExpired))
    }

    /// Everything else a Stack-needing request can raise must NOT be fatal on a
    /// ticket-authorized connection — these are the errors that were evicting the
    /// session and demanding an account switch.
    @Test func stackAuthFailuresAreNotTicketExpiry() {
        let nonFatal: [MobileShellConnectionError] = [
            .authorizationFailed("Sign in on your computer with the same account, then try again."),
            .accountMismatch("This Mac is signed in to a different cmux account."),
            .insecureManualRoute,
        ]
        for error in nonFatal {
            #expect(!MobileShellComposite.isTicketExpiryFailure(error))
        }
    }
}
