#if os(iOS)
import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

@Suite
struct MobileAuthenticatedShellPresentationTests {
    @Test func allHiddenUsesWorkspaceShellEvenWithStaleFalseHint() {
        #expect(MobileAuthenticatedShellPresentation.resolve(
            connectionState: .disconnected,
            hasKnownPairedMac: false,
            hasHiddenComputers: true
        ) == .workspace)
    }

    @Test func trulyNoMacsUsesDisconnectedAddDeviceShell() {
        #expect(MobileAuthenticatedShellPresentation.resolve(
            connectionState: .disconnected,
            hasKnownPairedMac: false,
            hasHiddenComputers: false
        ) == .disconnected)
    }

    @Test(arguments: [MobileConnectionState.connected, .disconnected])
    func knownMacUsesWorkspaceShell(_ connectionState: MobileConnectionState) {
        #expect(MobileAuthenticatedShellPresentation.resolve(
            connectionState: connectionState,
            hasKnownPairedMac: true,
            hasHiddenComputers: false
        ) == .workspace)
    }

    @Test func connectedSessionUsesWorkspaceShellWithoutPersistedHints() {
        #expect(MobileAuthenticatedShellPresentation.resolve(
            connectionState: .connected,
            hasKnownPairedMac: false,
            hasHiddenComputers: false
        ) == .workspace)
    }

    @Test func firstReconnectBlocksWorkspaceNavigation() {
        #expect(MobileReconnectPresentation.shouldBlockWorkspaceNavigation(
            connectionState: .disconnected,
            isReconnectingStoredMac: true,
            isMacSwitchInFlight: false,
            didFinishStoredMacReconnectAttempt: false
        ))
    }

    @Test func automaticBackoffDoesNotFlashReconnectOverlayAfterFirstAttempt() {
        #expect(!MobileReconnectPresentation.shouldBlockWorkspaceNavigation(
            connectionState: .disconnected,
            isReconnectingStoredMac: true,
            isMacSwitchInFlight: false,
            didFinishStoredMacReconnectAttempt: true
        ))
    }

    @Test func explicitMacSwitchStillBlocksAfterEarlierReconnectCompleted() {
        #expect(MobileReconnectPresentation.shouldBlockWorkspaceNavigation(
            connectionState: .disconnected,
            isReconnectingStoredMac: true,
            isMacSwitchInFlight: true,
            didFinishStoredMacReconnectAttempt: true
        ))
    }
}
#endif
