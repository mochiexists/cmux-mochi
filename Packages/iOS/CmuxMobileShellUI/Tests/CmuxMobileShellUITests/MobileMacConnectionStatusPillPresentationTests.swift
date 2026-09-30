import CMUXMobileCore
import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

@Suite struct MobileMacConnectionStatusPillPresentationTests {
    @Test(arguments: [
        (CmxAttachTransportKind.localNetwork, MobileMacConnectionStatusPillPresentation.route(.localNetwork)),
        (CmxAttachTransportKind.tailscale, MobileMacConnectionStatusPillPresentation.route(.tailscale)),
    ])
    func connectedRouteIsVisible(
        routeKind: CmxAttachTransportKind,
        expected: MobileMacConnectionStatusPillPresentation
    ) {
        #expect(
            MobileMacConnectionStatusPillPresentation.resolve(
                status: .connected,
                routeKind: routeKind
            ) == expected
        )
    }

    @Test(arguments: [
        CmxAttachTransportKind.localNetwork,
        CmxAttachTransportKind.tailscale,
        CmxAttachTransportKind.iroh,
        CmxAttachTransportKind.websocket,
        CmxAttachTransportKind.debugLoopback,
        nil,
    ])
    func reconnectingOverridesRoute(routeKind: CmxAttachTransportKind?) {
        #expect(
            MobileMacConnectionStatusPillPresentation.resolve(
                status: .reconnecting,
                routeKind: routeKind
            ) == .reconnecting
        )
    }

    @Test func disconnectedIsVisibleAndActionable() {
        #expect(
            MobileMacConnectionStatusPillPresentation.resolve(
                status: .unavailable,
                routeKind: .tailscale
            ) == .unavailable
        )
    }

    @Test(arguments: [
        CmxAttachTransportKind.iroh,
        CmxAttachTransportKind.websocket,
        CmxAttachTransportKind.debugLoopback,
        nil,
    ])
    func connectedUnsupportedRouteDoesNotClaimLANOrTailscale(
        routeKind: CmxAttachTransportKind?
    ) {
        #expect(
            MobileMacConnectionStatusPillPresentation.resolve(
                status: .connected,
                routeKind: routeKind
            ) == nil
        )
    }
}
