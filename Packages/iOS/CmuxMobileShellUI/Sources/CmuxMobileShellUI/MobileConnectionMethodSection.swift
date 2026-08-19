#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// The Auto-Connect vs Tailscale connection-method choice, shared by Settings
/// and (through the same store) onboarding. Choosing Tailscale surfaces the
/// pairing-code scanner entry, because a user-entered code is what authorizes
/// each Mac's Tailscale destination.
struct MobileConnectionMethodSection: View {
    @Bindable var store: MobileConnectionMethodStore
    /// Fork (cmux Mochi): the automatic method dials upstream's account-backed
    /// relays, so it is only offered to a signed-in session; account-free
    /// installs get the pairing path that actually works here, with nothing to
    /// mis-select. Defaults to offering it so previews keep the upstream shape.
    var showsAutomaticMethod: Bool = true
    let startPairingScanner: (() -> Void)?

    var body: some View {
        Section {
            Picker(
                L10n.string(
                    "mobile.settings.connectionMethod",
                    defaultValue: "Connection Method"
                ),
                selection: $store.method
            ) {
                if showsAutomaticMethod {
                    Text(L10n.string(
                        "mobile.settings.connectionMethod.automatic",
                        defaultValue: "Auto-Connect"
                    ))
                    .tag(MobileConnectionMethod.automatic)
                }
                Text(L10n.string(
                    "mobile.settings.connectionMethod.tailscale",
                    defaultValue: "Tailscale"
                ))
                .tag(MobileConnectionMethod.tailscale)
            }
            .accessibilityIdentifier("MobileSettingsConnectionMethod")
            if store.method == .tailscale, startPairingScanner != nil {
                Button {
                    startPairingScanner?()
                } label: {
                    Label(
                        L10n.string(
                            "mobile.settings.connectionMethod.scanCode",
                            defaultValue: "Scan Pairing Code"
                        ),
                        systemImage: "qrcode.viewfinder"
                    )
                }
                .accessibilityIdentifier("MobileSettingsTailscaleScanButton")
            }
        } footer: {
            Text(footerText)
        }
    }

    private var footerText: String {
        switch store.method {
        case .automatic:
            L10n.string(
                "mobile.settings.connectionMethod.automaticFooter",
                defaultValue: "Connects to your Mac automatically over an end-to-end encrypted connection, directly or through cmux relays. No setup needed."
            )
        case .tailscale:
            L10n.string(
                "mobile.settings.connectionMethod.tailscaleFooter",
                defaultValue: "Connects over your Tailscale network first. Scan the Tailscale pairing code shown on your Mac once (cmux Settings → Pair iPhone) to enable it for that Mac."
            )
        }
    }
}
#endif
