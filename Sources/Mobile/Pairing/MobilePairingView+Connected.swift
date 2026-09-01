import SwiftUI

extension MobilePairingView {
    @ViewBuilder
    func connectedContent(_: MobilePairingModel.Ready) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .cmuxFont(size: 36)
                .foregroundStyle(.green)
            Text(String(localized: "mobile.pairing.connected.title", defaultValue: "iPhone connected"))
                .cmuxFont(.title3, weight: .semibold)
            Text(String(
                localized: "mobile.pairing.connected.subtitle",
                defaultValue: "Your terminal workspaces are now syncing to your iPhone. You can close this window."
            ))
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    var steps: some View {
        VStack(alignment: .leading, spacing: 10) {
            step(1, String(
                localized: "mobile.pairing.step.install",
                defaultValue: "Install cmux on your iPhone and open it."
            ))
            HStack(spacing: 4) {
                Spacer(minLength: 30)
                Text(String(localized: "mobile.pairing.getApp.prompt", defaultValue: "Don't have it yet?"))
                    .cmuxFont(.caption)
                    .foregroundStyle(.secondary)
                Link(
                    String(localized: "mobile.pairing.getApp.link", defaultValue: "Get cmux for iPhone"),
                    destination: Self.iphoneAppURL
                )
                .cmuxFont(.caption)
                Spacer(minLength: 0)
            }
            step(2, String(
                localized: "mobile.pairing.step.network",
                defaultValue: "Connect your iPhone to the same local network or Tailscale network as this Mac."
            ))
            step(3, String(
                localized: "mobile.pairing.step.scan",
                defaultValue: "Tap Add device, then Scan QR Code, and point the camera at the code above."
            ))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .cmuxFont(.caption, weight: .bold)
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor, in: Circle())
            Text(text).cmuxFont(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    func centered<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 10) { content() }
            .frame(maxWidth: .infinity, minHeight: 200)
    }
}
