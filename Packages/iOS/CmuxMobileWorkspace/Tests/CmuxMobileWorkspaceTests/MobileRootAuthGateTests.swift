import Testing

@testable import CmuxMobileWorkspace

@Suite struct MobileRootAuthGateTests {
    @Test func accountAndDeviceIdentityUnlockTheRootIndependently() {
        #expect(MobileRootAuthGate.isAuthenticated(
            stackAuthenticated: true,
            pairedDeviceAuthenticated: false
        ))
        #expect(MobileRootAuthGate.isAuthenticated(
            stackAuthenticated: false,
            pairedDeviceAuthenticated: true
        ))
        #expect(!MobileRootAuthGate.isAuthenticated(
            stackAuthenticated: false,
            pairedDeviceAuthenticated: false
        ))
    }

    @Test func onlyDeviceLinkIdentityStartsAStoredMacDial() {
        #expect(MobileRootAuthGate.shouldReconnectStoredMac(
            hasPairedDeviceIdentity: true,
            isRestoringSession: false,
            connectionState: .disconnected
        ))
        #expect(!MobileRootAuthGate.shouldReconnectStoredMac(
            hasPairedDeviceIdentity: false,
            isRestoringSession: false,
            connectionState: .disconnected
        ))
    }

    @Test func deviceLinkReconnectWaitsForRestoreAndSkipsLiveConnections() {
        #expect(!MobileRootAuthGate.shouldReconnectStoredMac(
            hasPairedDeviceIdentity: true,
            isRestoringSession: true,
            connectionState: .disconnected
        ))
        #expect(!MobileRootAuthGate.shouldReconnectStoredMac(
            hasPairedDeviceIdentity: true,
            isRestoringSession: false,
            connectionState: .connected
        ))
    }

    @Test func showsRestoringStoredMacOnlyWhileAnUnresolvedKnownReconnectCanLand() {
        #expect(MobileRootAuthGate.shouldShowRestoringStoredMac(
            authenticated: true,
            connectionState: .disconnected,
            isReconnectingStoredMac: true,
            hasKnownPairedMac: false,
            pairedMacHintUndetermined: false,
            didFinishStoredMacReconnectAttempt: false
        ))
        #expect(MobileRootAuthGate.shouldShowRestoringStoredMac(
            authenticated: true,
            connectionState: .disconnected,
            isReconnectingStoredMac: false,
            hasKnownPairedMac: true,
            pairedMacHintUndetermined: false,
            didFinishStoredMacReconnectAttempt: false
        ))
        #expect(MobileRootAuthGate.shouldShowRestoringStoredMac(
            authenticated: true,
            connectionState: .disconnected,
            isReconnectingStoredMac: false,
            hasKnownPairedMac: false,
            pairedMacHintUndetermined: true,
            didFinishStoredMacReconnectAttempt: false
        ))
        #expect(!MobileRootAuthGate.shouldShowRestoringStoredMac(
            authenticated: true,
            connectionState: .disconnected,
            isReconnectingStoredMac: true,
            hasKnownPairedMac: true,
            pairedMacHintUndetermined: true,
            didFinishStoredMacReconnectAttempt: true
        ))
        #expect(!MobileRootAuthGate.shouldShowRestoringStoredMac(
            authenticated: false,
            connectionState: .disconnected,
            isReconnectingStoredMac: true,
            hasKnownPairedMac: true,
            pairedMacHintUndetermined: true,
            didFinishStoredMacReconnectAttempt: false
        ))
        #expect(!MobileRootAuthGate.shouldShowRestoringStoredMac(
            authenticated: true,
            connectionState: .connected,
            isReconnectingStoredMac: true,
            hasKnownPairedMac: true,
            pairedMacHintUndetermined: true,
            didFinishStoredMacReconnectAttempt: false
        ))
    }

    @Test func shellSurfaceKeepsOneWorkspaceShellAcrossRestoreAndOfflineStates() {
        #expect(MobileRootAuthGate.shellSurface(
            connectionState: .disconnected,
            showRestoringStoredMac: true,
            showDisconnectedNoPairedMacShell: true
        ) == .workspaceShell(isRestoringStoredMac: true))
        #expect(MobileRootAuthGate.shellSurface(
            connectionState: .disconnected,
            showRestoringStoredMac: false,
            showDisconnectedNoPairedMacShell: true
        ) == .disconnectedNoKnownPairedMac)
        #expect(MobileRootAuthGate.shellSurface(
            connectionState: .connected,
            showRestoringStoredMac: false,
            showDisconnectedNoPairedMacShell: false
        ) == .workspaceShell(isRestoringStoredMac: false))
    }
}
