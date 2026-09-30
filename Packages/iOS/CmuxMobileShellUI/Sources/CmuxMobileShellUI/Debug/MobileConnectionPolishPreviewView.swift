#if DEBUG && os(iOS)
import CMUXMobileCore
import CmuxMobileShellModel
import SwiftUI

/// Deterministic screenshot fixtures for the release connection surfaces.
struct MobileConnectionPolishPreviewView: View {
    let mode: String

    @ViewBuilder
    var body: some View {
        switch mode {
        case "lan":
            terminal(status: .connected, routeKind: .localNetwork)
        case "tailscale":
            terminal(status: .connected, routeKind: .tailscale)
        case "reconnecting":
            terminal(status: .reconnecting, routeKind: nil)
        case "recovery":
            terminal(status: .connected, routeKind: .localNetwork)
                .overlay {
                    MobileReconnectProgressView(macName: "Studio Mac")
                }
        case "renew-pairing":
            terminal(status: .connected, routeKind: .localNetwork, showsPill: false)
                .overlay(alignment: .top) {
                    MobileConnectionRecoveryBanner(connectionRequiresReauth: true)
                }
        case "disconnected":
            DisconnectedWorkspaceShellView(
                hasKnownPairedMac: false,
                showAddDevice: {},
                showPairingScanner: {},
                signOut: {}
            )
        default:
            EmptyView()
        }
    }

    private func terminal(
        status: MobileMacConnectionStatus,
        routeKind: CmxAttachTransportKind?,
        showsPill: Bool = true
    ) -> some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                Color(red: 0.06, green: 0.07, blue: 0.09)
                    .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 8) {
                    Text("~")
                    Text("❯")
                }
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.white.opacity(0.72))
                .padding(.top, 62)
                .padding(.leading, 16)

                if showsPill {
                    MobileMacConnectionStatusPill(
                        host: "Studio Mac",
                        status: status,
                        routeKind: routeKind
                    )
                    .padding(12)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}
#endif
