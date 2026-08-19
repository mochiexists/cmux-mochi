#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct OnboardingConnectionView: View {
    let phase: OnboardingConnectionPhase
    let connectionMethod: MobileConnectionMethod
    /// Fork (cmux Mochi): the automatic method dials upstream's account-backed
    /// relays, so it is only offered to a signed-in session. Account-free
    /// onboarding goes straight to the QR/Tailscale pairing this fork runs on —
    /// showing a dead "Recommended" option was the footgun that funneled new
    /// installs into "Couldn't connect to your Mac yet".
    let showsAutomaticMethod: Bool
    let onSelectConnectionMethod: (MobileConnectionMethod) -> Void

    var body: some View {
        ZStack {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityIdentifier("MobileOnboardingConnectScene")

            OnboardingSceneContent(
                title: title,
                message: message,
                visual: visual
            )
        }
    }

    /// The method choice stays visible while there is still a decision to act
    /// on; once connected it disappears (Settings keeps the control). With the
    /// automatic method unavailable there is no decision, so no picker.
    private var showsMethodPicker: Bool {
        (phase == .idle || phase == .fallback) && showsAutomaticMethod
    }

    private var visual: some View {
        VStack(spacing: 14) {
            OnboardingConnectionPreview(
                phase: phase,
                usesAccountLink: connectionMethod == .automatic
            )
            if showsMethodPicker {
                OnboardingConnectionMethodPicker(
                    method: connectionMethod,
                    onSelect: onSelectConnectionMethod
                )
            }
        }
    }

    private var title: String {
        if phase == .ready {
            return L10n.string(
                "mobile.onboarding.ready.title",
                defaultValue: "Your Mac is connected"
            )
        }
        if connectionMethod == .tailscale {
            return L10n.string(
                "mobile.onboarding.connect.tailscaleTitle",
                defaultValue: "Connect over Tailscale"
            )
        }
        return L10n.string(
            "mobile.onboarding.connect.title",
            defaultValue: "Your Mac connects automatically"
        )
    }

    private var message: String {
        if phase == .ready {
            return L10n.string(
                "mobile.onboarding.ready.body",
                defaultValue: "Open any workspace and respond when an agent needs you."
            )
        }
        if connectionMethod == .tailscale {
            return L10n.string(
                "mobile.onboarding.connect.tailscaleBody",
                defaultValue: "Connect over your Tailscale network. Scan the pairing code shown on your Mac."
            )
        }
        return L10n.string(
            "mobile.onboarding.connect.body",
            defaultValue: "Use the same cmux account on both devices. Your Mac connects automatically."
        )
    }
}
#endif
