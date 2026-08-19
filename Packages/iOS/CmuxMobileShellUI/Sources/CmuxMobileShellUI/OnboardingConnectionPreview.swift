#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct OnboardingConnectionPreview: View {
    let phase: OnboardingConnectionPhase
    /// Fork (cmux Mochi): the Mac↔phone link is drawn as a shared account only
    /// when an account actually authorizes it. QR/Tailscale pairings are
    /// authorized by the device's own key, and labeling them "Same account"
    /// told account-free operators they were on a path they deliberately
    /// avoided. Defaults to the account rendering so upstream call sites keep
    /// their look.
    var usesAccountLink: Bool = true

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 14) {
                deviceIcon(systemImage: "desktopcomputer", tint: .indigo)
                accountLink
                deviceIcon(systemImage: "iphone", tint: .blue)
            }

            connectionStatus

            Label(
                L10n.string(
                    "mobile.onboarding.connect.trust",
                    defaultValue: "Encrypted end to end"
                ),
                systemImage: "lock.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileOnboardingConnectionPreview")
    }

    private func deviceIcon(systemImage: String, tint: Color) -> some View {
        Circle()
            .fill(tint.gradient)
            .frame(width: 74, height: 74)
            .overlay {
                Image(systemName: systemImage)
                    .font(.title.weight(.medium))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }

    private var accountLink: some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(.thinMaterial)
                    .frame(width: 52, height: 52)

                Image(systemName: linkSystemImage)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(phase == .ready ? Color.green : Color.accentColor)
            }

            Text(linkLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .accessibilityHidden(true)
    }

    private var linkSystemImage: String {
        if usesAccountLink {
            return phase == .ready
                ? "person.crop.circle.badge.checkmark"
                : "person.crop.circle"
        }
        return phase == .ready ? "checkmark.seal.fill" : "qrcode"
    }

    private var linkLabel: String {
        if usesAccountLink {
            return L10n.string(
                "mobile.onboarding.connect.sameAccount",
                defaultValue: "Same account"
            )
        }
        return phase == .ready
            ? L10n.string(
                "mobile.onboarding.connect.pairedLink",
                defaultValue: "Paired"
            )
            : L10n.string(
                "mobile.onboarding.connect.scanToPair",
                defaultValue: "Scan to pair"
            )
    }

    @ViewBuilder
    private var connectionStatus: some View {
        switch phase {
        case .idle:
            Label(
                L10n.string(
                    "mobile.onboarding.connect.idleStatus",
                    defaultValue: "Ready to look for your Mac"
                ),
                systemImage: "magnifyingglass"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("MobileOnboardingConnectionIdle")
        case .searching:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.string(
                    "mobile.onboarding.connect.searching",
                    defaultValue: "Looking for your Mac…"
                ))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("MobileOnboardingConnectionSearching")
        case .fallback:
            Label(
                L10n.string(
                    "mobile.onboarding.connect.fallbackStatus",
                    defaultValue: "Couldn’t connect to your Mac yet"
                ),
                systemImage: "exclamationmark.circle"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("MobileOnboardingConnectionFallback")
        case .ready:
            Label(
                L10n.string(
                    "mobile.onboarding.connect.connectedStatus",
                    defaultValue: "Connected securely"
                ),
                systemImage: "checkmark.circle.fill"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.green)
            .accessibilityIdentifier("MobileOnboardingConnectionReady")
        }
    }
}
#endif
