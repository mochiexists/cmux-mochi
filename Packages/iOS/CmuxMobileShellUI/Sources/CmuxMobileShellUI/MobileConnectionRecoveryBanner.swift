import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

/// Surfaces the one connection failure the user must act on: the Mac rejected
/// the saved DeviceLink pairing, so retrying with the same credential cannot
/// help and the phone must scan a fresh Pair iPhone QR code. Transient drops and
/// reconnect attempts deliberately do not render blocking chrome; they ride
/// the status line under the computers picker and the terminal status pill.
/// It can render as a floating pill above terminal content, or as an inline
/// row when the current surface is a list instead of a terminal.
struct MobileConnectionRecoveryBanner: View {
    static let defaultPairingRejectionDescription: String.LocalizationValue =
        "This computer rejected the saved pairing. Open Pair iPhone on the computer and scan a fresh QR code."

    var connectionRequiresReauth: Bool
    var rendersInline = false

    var body: some View {
        Group {
            if connectionRequiresReauth {
                repairPairingBanner(
                    text: L10n.string(
                        "mobile.recovery.accountMismatch",
                        defaultValue: Self.defaultPairingRejectionDescription
                    )
                )
            }
        }
        .animation(.default, value: connectionRequiresReauth)
    }

    /// A rejected DeviceLink credential requires a fresh QR pairing. The
    /// transport's raw error is intentionally not shown because upstream auth
    /// wording can mention accounts that this fork does not require.
    @ViewBuilder
    private func repairPairingBanner(text: String) -> some View {
        if rendersInline {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 24)
                Text(text)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 8)
            .accessibilityIdentifier("MobileConnectionReauthRow")
        } else {
            HStack(spacing: 8) {
                Image(systemName: "qrcode.viewfinder")
                    .foregroundStyle(.white)
                Text(text)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 420)
            .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.top, 8)
            .padding(.horizontal, 16)
            .accessibilityIdentifier("MobileConnectionReauthBanner")
        }
    }
}
