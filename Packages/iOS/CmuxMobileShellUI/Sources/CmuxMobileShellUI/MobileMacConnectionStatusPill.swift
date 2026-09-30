import CMUXMobileCore
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// A compact route/status pill overlaid on the terminal view.
struct MobileMacConnectionStatusPill: View {
    let host: String
    let status: MobileMacConnectionStatus
    let routeKind: CmxAttachTransportKind?
    var reconnect: (() -> Void)?

    @ViewBuilder
    var body: some View {
        if let presentation {
            if let reconnect, presentation == .unavailable {
                Button(action: reconnect) {
                    pill(presentation)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel(presentation))
                .accessibilityHint(
                    L10n.string("mobile.workspace.reconnect", defaultValue: "Reconnect")
                )
                .accessibilityIdentifier("MobileTerminalMacConnectionStatus")
            } else {
                pill(presentation)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(accessibilityLabel(presentation))
                    .accessibilityIdentifier("MobileTerminalMacConnectionStatus")
            }
        }
    }

    private var presentation: MobileMacConnectionStatusPillPresentation? {
        MobileMacConnectionStatusPillPresentation.resolve(
            status: status,
            routeKind: routeKind
        )
    }

    private func pill(_ presentation: MobileMacConnectionStatusPillPresentation) -> some View {
        HStack(spacing: 7) {
            if presentation == .reconnecting {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
            } else {
                Circle()
                    .fill(tintColor(for: presentation))
                    .frame(width: 8, height: 8)
            }

            Text(presentation.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.black.opacity(0.78), in: Capsule())
    }

    private func tintColor(
        for presentation: MobileMacConnectionStatusPillPresentation
    ) -> Color {
        switch presentation {
        case .route:
            return .green
        case .reconnecting:
            return .orange
        case .unavailable:
            return .red
        }
    }

    private func accessibilityLabel(
        _ presentation: MobileMacConnectionStatusPillPresentation
    ) -> String {
        host.isEmpty ? presentation.label : "\(host), \(presentation.label)"
    }
}
