import CmuxMobileSupport
import SwiftUI

struct MobileReconnectProgressView: View {
    let macName: String

    var body: some View {
        ZStack {
            PlatformPalette.systemBackground
                .ignoresSafeArea()

            VStack(spacing: 18) {
                ProgressView()
                    .controlSize(.large)

                Text(title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text(L10n.string(
                    "mobile.reconnect.description",
                    defaultValue: "Trying your saved connections. Make sure cmux is open on your Mac."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            }
            .padding(32)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileReconnectProgress")
    }

    private var title: String {
        let trimmedName = macName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return L10n.string(
                "mobile.reconnect.title.generic",
                defaultValue: "Reconnecting to your Mac"
            )
        }
        let format = L10n.string(
            "mobile.reconnect.title.format",
            defaultValue: "Reconnecting to %@"
        )
        return String(format: format, trimmedName)
    }

}
