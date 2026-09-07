#if os(iOS)
@testable import CmuxMobileShellUI
import Testing

@Suite struct OnboardingConnectionPhaseTests {
    @Test func scannedPairingAttemptShowsBlockingProgressUntilItResolves() {
        #expect(PairingAttemptPresentation.resolve(isPairing: true) == .connecting)
        #expect(PairingAttemptPresentation.resolve(isPairing: false) == .idle)
    }

    @Test func inactiveTailnetProducesFallbackNoticeWithoutBlockingLANPairing() {
        #expect(PairingNetworkWarning.resolve(status: .inactiveOrNotInstalled) == .tailscaleDisconnected)
        #expect(PairingNetworkWarning.resolve(status: .active) == nil)
        #expect(PairingNetworkWarning.resolve(status: .unknown) == nil)
        #expect(PairingNetworkWarning.resolve(status: nil) == nil)
    }

    @Test func reconnectBlocksWorkspaceNavigationOnlyWhileAnAttemptIsActive() {
        #expect(MobileReconnectPresentation.shouldBlockWorkspaceNavigation(
            connectionState: .disconnected,
            isReconnectingStoredMac: true,
            isMacSwitchInFlight: false,
            didFinishStoredMacReconnectAttempt: false
        ))
        #expect(MobileReconnectPresentation.shouldBlockWorkspaceNavigation(
            connectionState: .disconnected,
            isReconnectingStoredMac: false,
            isMacSwitchInFlight: true,
            didFinishStoredMacReconnectAttempt: true
        ))
        #expect(!MobileReconnectPresentation.shouldBlockWorkspaceNavigation(
            connectionState: .connected,
            isReconnectingStoredMac: true,
            isMacSwitchInFlight: true,
            didFinishStoredMacReconnectAttempt: true
        ))
        #expect(!MobileReconnectPresentation.shouldBlockWorkspaceNavigation(
            connectionState: .disconnected,
            isReconnectingStoredMac: false,
            isMacSwitchInFlight: false,
            didFinishStoredMacReconnectAttempt: true
        ))
    }

    @Test func discoveryThatHasNotStartedShowsIdle() {
        #expect(OnboardingConnectionPhase(
            isMacReady: false,
            isSearching: false,
            didFinishSearch: false
        ) == .idle)
    }

    @Test func activeAutomaticDiscoveryShowsSearching() {
        #expect(OnboardingConnectionPhase(
            isMacReady: false,
            isSearching: true,
            didFinishSearch: true
        ) == .searching)
    }

    @Test func completedSearchWithoutMacRevealsFallback() {
        #expect(OnboardingConnectionPhase(
            isMacReady: false,
            isSearching: false,
            didFinishSearch: true
        ) == .fallback)
    }

    @Test func connectedMacAlwaysShowsReady() {
        #expect(OnboardingConnectionPhase(
            isMacReady: true,
            isSearching: true,
            didFinishSearch: false
        ) == .ready)
    }

    @Test func replayCanDeclareNoSearchPending() {
        #expect(OnboardingConnectionPhase(
            isMacReady: false,
            isSearching: false,
            didFinishSearch: false
        ) == .idle)
    }
}
#endif
