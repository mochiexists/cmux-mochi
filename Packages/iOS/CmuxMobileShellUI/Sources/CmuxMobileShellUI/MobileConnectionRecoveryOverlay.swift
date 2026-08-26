import CmuxMobileShell
import SwiftUI

private struct MobileConnectionRecoveryOverlay: ViewModifier {
    @Bindable var store: CMUXMobileShellStore

    func body(content: Content) -> some View {
        // Reauth is a blocking condition, not a status: the Mac rejected the
        // connection, so a durable banner explaining fresh QR pairing is the
        // surface. Transient reconnects and failed attempts keep the terminal
        // visible and ride the status pill / picker status line instead.
        content.overlay(alignment: .top) {
            if store.connectionRequiresReauth {
                MobileConnectionRecoveryBanner(
                    connectionRequiresReauth: store.connectionRequiresReauth
                )
            }
        }
    }
}

extension View {
    func mobileConnectionRecoveryOverlay(
        store: CMUXMobileShellStore
    ) -> some View {
        modifier(MobileConnectionRecoveryOverlay(store: store))
    }
}
