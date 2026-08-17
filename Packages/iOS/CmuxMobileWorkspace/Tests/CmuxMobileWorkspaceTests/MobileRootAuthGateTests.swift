import Foundation
import Testing

@testable import CmuxMobileWorkspace

@Suite struct MobileRootAuthGateTests {
    @Test func allowsAttachTicketAuthenticationWithoutStackAuth() throws {
        #expect(MobileRootAuthGate.isAuthenticated(
            stackAuthenticated: false,
            attachTicketAuthenticated: true
        ))
        #expect(!MobileRootAuthGate.isAuthenticated(
            stackAuthenticated: false,
            attachTicketAuthenticated: false
        ))

        let attachURL = try #require(URL(string: "cmux-ios://attach?v=1&payload=test"))
        // The dev channel's scheme is also a valid attach deep link, so a dev
        // build recognizes the deep link the system camera hands it.
        let devAttachURL = try #require(URL(string: "cmux-ios-dev://attach?v=2&r=100.64.0.5:58465"))
        let authURL = try #require(URL(string: "stack-auth-mobile-oauth-url://callback?code=test"))
        let otherURL = try #require(URL(string: "cmux-ios://oauth?v=1"))

        #expect(MobileRootAuthGate.isAttachURL(attachURL))
        #expect(MobileRootAuthGate.isAttachURL(devAttachURL))
        #expect(!MobileRootAuthGate.isAttachURL(authURL))
        #expect(!MobileRootAuthGate.isAttachURL(otherURL))
    }

    @Test func showsRestoringSessionOnlyBeforeAuthentication() {
        #expect(MobileRootAuthGate.shouldShowRestoringSession(
            stackAuthenticated: false,
            attachTicketAuthenticated: false,
            isRestoringSession: true
        ))
        #expect(!MobileRootAuthGate.shouldShowRestoringSession(
            stackAuthenticated: true,
            attachTicketAuthenticated: false,
            isRestoringSession: true
        ))
        #expect(!MobileRootAuthGate.shouldShowRestoringSession(
            stackAuthenticated: false,
            attachTicketAuthenticated: true,
            isRestoringSession: true
        ))
        #expect(!MobileRootAuthGate.shouldShowRestoringSession(
            stackAuthenticated: false,
            attachTicketAuthenticated: false,
            isRestoringSession: false
        ))
    }

    @Test func clearsOnlyStaleTemporaryAttachAuthentication() {
        #expect(MobileRootAuthGate.shouldClearAttachTicketAuthentication(
            pairingResult: .failed,
            connectionState: .disconnected,
            hasActiveUnexpiredTicket: false
        ))
        #expect(MobileRootAuthGate.shouldClearAttachTicketAuthentication(
            pairingResult: .superseded,
            connectionState: .disconnected,
            hasActiveUnexpiredTicket: false
        ))
        #expect(!MobileRootAuthGate.shouldClearAttachTicketAuthentication(
            pairingResult: .needsUserApproval,
            connectionState: .disconnected,
            hasActiveUnexpiredTicket: false
        ))
        #expect(!MobileRootAuthGate.shouldClearAttachTicketAuthentication(
            pairingResult: .superseded,
            connectionState: .connected,
            hasActiveUnexpiredTicket: true
        ))
        #expect(!MobileRootAuthGate.shouldClearAttachTicketAuthentication(
            pairingResult: .connected,
            connectionState: .connected,
            hasActiveUnexpiredTicket: true
        ))
        #expect(MobileRootAuthGate.shouldClearAttachTicketAuthentication(
            pairingResult: .connected,
            connectionState: .connected,
            hasActiveUnexpiredTicket: false
        ))
        #expect(MobileRootAuthGate.shouldReconnectStoredMac(
            stackAuthenticated: true,
            attachTicketAuthenticated: false,
            isRestoringSession: false,
            connectionState: .disconnected
        ))
        #expect(!MobileRootAuthGate.shouldReconnectStoredMac(
            stackAuthenticated: true,
            attachTicketAuthenticated: true,
            isRestoringSession: false,
            connectionState: .disconnected
        ))
        #expect(!MobileRootAuthGate.shouldReconnectStoredMac(
            stackAuthenticated: false,
            attachTicketAuthenticated: true,
            isRestoringSession: false,
            connectionState: .disconnected
        ))
        #expect(!MobileRootAuthGate.shouldReconnectStoredMac(
            stackAuthenticated: true,
            attachTicketAuthenticated: false,
            isRestoringSession: true,
            connectionState: .disconnected
        ))
    }

    @Test func showsRestoringStoredMacWhileReconnectingAKnownPairedMac() {
        // Actively reconnecting a found stored Mac.
        #expect(MobileRootAuthGate.shouldShowRestoringStoredMac(
            authenticated: true,
            connectionState: .disconnected,
            isReconnectingStoredMac: true,
            hasKnownPairedMac: false,
            pairedMacHintUndetermined: false,
            didFinishStoredMacReconnectAttempt: false
        ))
        // First frame for a returning user: persisted hint, attempt not yet resolved.
        #expect(MobileRootAuthGate.shouldShowRestoringStoredMac(
            authenticated: true,
            connectionState: .disconnected,
            isReconnectingStoredMac: false,
            hasKnownPairedMac: true,
            pairedMacHintUndetermined: false,
            didFinishStoredMacReconnectAttempt: false
        ))
        // Existing install that predates the hint (key absent): treat undetermined
        // as "may have a paired Mac" so it does not flash add-device on first launch.
        #expect(MobileRootAuthGate.shouldShowRestoringStoredMac(
            authenticated: true,
            connectionState: .disconnected,
            isReconnectingStoredMac: false,
            hasKnownPairedMac: false,
            pairedMacHintUndetermined: true,
            didFinishStoredMacReconnectAttempt: false
        ))
        // Undetermined, but the first attempt resolved with no Mac: fall through.
        #expect(!MobileRootAuthGate.shouldShowRestoringStoredMac(
            authenticated: true,
            connectionState: .disconnected,
            isReconnectingStoredMac: false,
            hasKnownPairedMac: false,
            pairedMacHintUndetermined: true,
            didFinishStoredMacReconnectAttempt: true
        ))
        // Failed/offline attempt resolved: fall through to the add-device view.
        #expect(!MobileRootAuthGate.shouldShowRestoringStoredMac(
            authenticated: true,
            connectionState: .disconnected,
            isReconnectingStoredMac: false,
            hasKnownPairedMac: true,
            pairedMacHintUndetermined: false,
            didFinishStoredMacReconnectAttempt: true
        ))
        // A later runtime redial must keep the established workspace shell
        // mounted. Re-entering the launch-only restoring branch destroys the
        // shell's compact navigation path and returns the user to the list.
        #expect(!MobileRootAuthGate.shouldShowRestoringStoredMac(
            authenticated: true,
            connectionState: .disconnected,
            isReconnectingStoredMac: true,
            hasKnownPairedMac: true,
            pairedMacHintUndetermined: false,
            didFinishStoredMacReconnectAttempt: true
        ))
        // Never paired (hint determined-false): add-device immediately, no flash.
        #expect(!MobileRootAuthGate.shouldShowRestoringStoredMac(
            authenticated: true,
            connectionState: .disconnected,
            isReconnectingStoredMac: false,
            hasKnownPairedMac: false,
            pairedMacHintUndetermined: false,
            didFinishStoredMacReconnectAttempt: false
        ))
        // Already connected: never show the restoring UI, regardless of flags.
        #expect(!MobileRootAuthGate.shouldShowRestoringStoredMac(
            authenticated: true,
            connectionState: .connected,
            isReconnectingStoredMac: true,
            hasKnownPairedMac: true,
            pairedMacHintUndetermined: true,
            didFinishStoredMacReconnectAttempt: false
        ))
        // Not authenticated: the sign-in/restoring-session gates run instead.
        #expect(!MobileRootAuthGate.shouldShowRestoringStoredMac(
            authenticated: false,
            connectionState: .disconnected,
            isReconnectingStoredMac: true,
            hasKnownPairedMac: true,
            pairedMacHintUndetermined: true,
            didFinishStoredMacReconnectAttempt: false
        ))
    }

    // MARK: - DeviceLink pairing (fork: cmux Mochi)

    @Test func accountFreePairedDeviceReconnectsWithoutAnAccount() {
        // The bug this feature exists to fix: a phone paired without an account
        // holds a private key and the Mac's pin, yet the old gate refused to
        // reconnect because no Stack session existed, so every cold launch
        // demanded a fresh QR scan.
        #expect(MobileRootAuthGate.shouldReconnectStoredMac(
            stackAuthenticated: false,
            hasPairedDeviceIdentity: true,
            attachTicketAuthenticated: false,
            isRestoringSession: false,
            connectionState: .disconnected
        ))
    }

    @Test func noCredentialMeansNoReconnectAttempt() {
        // Nothing to present: fall through to pairing rather than spinning.
        #expect(!MobileRootAuthGate.shouldReconnectStoredMac(
            stackAuthenticated: false,
            hasPairedDeviceIdentity: false,
            attachTicketAuthenticated: false,
            isRestoringSession: false,
            connectionState: .disconnected
        ))
    }

    @Test func deviceLinkGateStillRespectsTheOtherConditions() {
        // A live attach ticket already owns the connection.
        #expect(!MobileRootAuthGate.shouldReconnectStoredMac(
            stackAuthenticated: false,
            hasPairedDeviceIdentity: true,
            attachTicketAuthenticated: true,
            isRestoringSession: false,
            connectionState: .disconnected
        ))
        // Restore in flight: let it finish before dialing.
        #expect(!MobileRootAuthGate.shouldReconnectStoredMac(
            stackAuthenticated: false,
            hasPairedDeviceIdentity: true,
            attachTicketAuthenticated: false,
            isRestoringSession: true,
            connectionState: .disconnected
        ))
        // Already connected: nothing to do.
        #expect(!MobileRootAuthGate.shouldReconnectStoredMac(
            stackAuthenticated: false,
            hasPairedDeviceIdentity: true,
            attachTicketAuthenticated: false,
            isRestoringSession: false,
            connectionState: .connected
        ))
    }

    @Test func accountAndDeviceCredentialsAreBothSufficient() {
        // Either credential alone is enough; neither disables the other.
        for (stack, device) in [(true, false), (false, true), (true, true)] {
            #expect(MobileRootAuthGate.shouldReconnectStoredMac(
                stackAuthenticated: stack,
                hasPairedDeviceIdentity: device,
                attachTicketAuthenticated: false,
                isRestoringSession: false,
                connectionState: .disconnected
            ))
        }
    }
}

/// A DeviceLink pairing authenticates the root view on its own.
///
/// Without this a device that paired successfully still rendered the sign-in
/// screen: the credential it had just earned was not one the gate recognised,
/// so an account-free pairing could never reach its workspace.
@Test func pairedDeviceIdentityAuthenticatesWithoutAnAccount() {
    #expect(
        MobileRootAuthGate.isAuthenticated(
            stackAuthenticated: false,
            attachTicketAuthenticated: false,
            pairedDeviceAuthenticated: true
        )
    )
    // No credential of any kind is still unauthenticated.
    #expect(
        !MobileRootAuthGate.isAuthenticated(
            stackAuthenticated: false,
            attachTicketAuthenticated: false,
            pairedDeviceAuthenticated: false
        )
    )
    // The existing credentials keep working, and the default keeps callers that
    // predate device pairing unchanged.
    #expect(MobileRootAuthGate.isAuthenticated(stackAuthenticated: true))
    #expect(
        MobileRootAuthGate.isAuthenticated(
            stackAuthenticated: false, attachTicketAuthenticated: true
        )
    )
    #expect(!MobileRootAuthGate.isAuthenticated(stackAuthenticated: false))
}
