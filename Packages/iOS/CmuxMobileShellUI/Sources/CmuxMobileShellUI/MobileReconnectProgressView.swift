import CMUXMobileCore
import CmuxMobileSupport
import SwiftUI

struct MobileReconnectProgressView: View {
    let macName: String
    let routeKind: CmxAttachTransportKind?
    let tailnetStatus: TailnetStatus?

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

                VStack(spacing: 7) {
                    technicalLine(
                        label: L10n.string(
                            "mobile.reconnect.stage.label",
                            defaultValue: "Stage"
                        ),
                        value: L10n.string(
                            "mobile.reconnect.stage.routes",
                            defaultValue: "Trying saved connection routes"
                        )
                    )
                    technicalLine(
                        label: L10n.string(
                            "mobile.reconnect.transport.label",
                            defaultValue: "Transport"
                        ),
                        value: routeLabel
                    )
                    if let tailnetStatus {
                        technicalLine(
                            label: tailscaleLabel,
                            value: tailnetStatusLabel(tailnetStatus)
                        )
                    }
                }
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .padding(.top, 4)
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

    private var routeLabel: String {
        switch routeKind {
        case .localNetwork:
            return L10n.string("mobile.reconnect.transport.localNetwork", defaultValue: "Local Network")
        case .tailscale:
            return tailscaleLabel
        case .iroh:
            return L10n.string("mobile.settings.iroh", defaultValue: "Iroh")
        case .websocket:
            return L10n.string("mobile.reconnect.transport.direct", defaultValue: "Direct")
        case .debugLoopback:
            return L10n.string("mobile.reconnect.transport.loopback", defaultValue: "Loopback")
        case nil:
            return L10n.string("mobile.reconnect.transport.selecting", defaultValue: "Selecting route")
        }
    }

    private var tailscaleLabel: String {
        L10n.string(
            "mobile.settings.connectionMethod.tailscale",
            defaultValue: "Tailscale"
        )
    }

    private func tailnetStatusLabel(_ status: TailnetStatus) -> String {
        switch status {
        case .active:
            return L10n.string("mobile.reconnect.tailscale.active", defaultValue: "Connected")
        case .inactiveOrNotInstalled:
            return L10n.string("mobile.reconnect.tailscale.inactive", defaultValue: "Not connected")
        case .unknown:
            return L10n.string("mobile.reconnect.tailscale.unknown", defaultValue: "Checking")
        }
    }

    private func technicalLine(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label + ":")
            Text(value)
                .foregroundStyle(.primary)
        }
    }
}
