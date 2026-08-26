#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport

struct OnboardingSceneChrome: Equatable {
    let showsBack: Bool
    let showsSkip: Bool
    let primaryTitle: String?
    let secondaryTitle: String?

    init(
        stage: OnboardingStage,
        isAuthenticated: Bool,
        connectionPhase: OnboardingConnectionPhase,
        connectionMethod: MobileConnectionMethod = .automatic
    ) {
        showsBack = stage != .agents
        showsSkip = stage != .connect

        switch stage {
        case .agents:
            primaryTitle = L10n.string(
                "mobile.onboarding.agents.primary",
                defaultValue: "Continue"
            )
            secondaryTitle = nil
        case .notifications:
            primaryTitle = L10n.string(
                "mobile.onboarding.continue",
                defaultValue: "Continue"
            )
            secondaryTitle = nil
        case .connect:
            switch connectionPhase {
            case .idle:
                primaryTitle = Self.scanPairingCodeTitle
                secondaryTitle = nil
            case .searching:
                primaryTitle = nil
                secondaryTitle = nil
            case .fallback:
                primaryTitle = Self.scanPairingCodeTitle
                secondaryTitle = nil
            case .ready:
                primaryTitle = L10n.string(
                    "mobile.onboarding.ready.primary",
                    defaultValue: "Open Workspaces"
                )
                secondaryTitle = nil
            }
        }
    }

    private static var scanPairingCodeTitle: String {
        L10n.string(
            "mobile.onboarding.connect.scanTailscaleCode",
            defaultValue: "Scan Pairing Code"
        )
    }
}
#endif
