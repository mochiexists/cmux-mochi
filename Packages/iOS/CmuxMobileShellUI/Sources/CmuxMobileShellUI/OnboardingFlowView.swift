#if os(iOS)
import CMUXMobileCore
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// A short product tour that ends at the account-free QR pairing flow.
struct OnboardingFlowView: View {
    let context: OnboardingContext
    let isAuthenticated: Bool
    let connectionPhase: OnboardingConnectionPhase
    let connectionMethod: MobileConnectionMethod
    let onSelectConnectionMethod: (MobileConnectionMethod) -> Void
    let onReachedConnection: () -> Void
    let onSkip: () -> Void
    let onRetryConnection: () -> Void
    let onStartFallbackPairing: () -> Void
    let onComplete: () -> Void

    @State private var stage: OnboardingStage
    @State private var didReachConnection = false
    @Environment(\.analytics) private var analytics

    init(
        initialStage: OnboardingStage,
        context: OnboardingContext,
        isAuthenticated: Bool,
        connectionPhase: OnboardingConnectionPhase,
        connectionMethod: MobileConnectionMethod = .automatic,
        onSelectConnectionMethod: @escaping (MobileConnectionMethod) -> Void = { _ in },
        onReachedConnection: @escaping () -> Void,
        onSkip: @escaping () -> Void,
        onRetryConnection: @escaping () -> Void,
        onStartFallbackPairing: @escaping () -> Void,
        onComplete: @escaping () -> Void
    ) {
        self.context = context
        self.isAuthenticated = isAuthenticated
        self.connectionPhase = connectionPhase
        self.connectionMethod = connectionMethod
        self.onSelectConnectionMethod = onSelectConnectionMethod
        self.onReachedConnection = onReachedConnection
        self.onSkip = onSkip
        self.onRetryConnection = onRetryConnection
        self.onStartFallbackPairing = onStartFallbackPairing
        self.onComplete = onComplete
        _stage = State(initialValue: initialStage)
    }

    var body: some View {
        OnboardingSceneContainer(
            stage: stage,
            chrome: chrome,
            onBack: handleBack,
            onSkip: skip,
            onPrimary: handlePrimary,
            onSecondary: handleSecondary,
            pageContent: OnboardingPageViewport(
                stage: stage,
                onNavigate: { navigate(to: $0) }
            ) { pageStage in
                page(for: pageStage)
            }
        )
        .interactiveDismissDisabled()
        .onAppear {
            captureSceneViewed()
            reachConnectionIfNeeded()
        }
        .onChange(of: stage) { _, _ in
            captureSceneViewed()
            reachConnectionIfNeeded()
        }
        .onChange(of: isAuthenticated) { _, isNowAuthenticated in
            guard stage == .connect else { return }
            captureSceneViewed()
            if isNowAuthenticated {
                onReachedConnection()
            }
        }
    }

    private var chrome: OnboardingSceneChrome {
        OnboardingSceneChrome(
            stage: stage,
            isAuthenticated: isAuthenticated,
            connectionPhase: connectionPhase,
            connectionMethod: connectionMethod
        )
    }

    @ViewBuilder
    private func page(for pageStage: OnboardingStage) -> some View {
        switch pageStage {
        case .agents:
            OnboardingAgentsView()
        case .notifications:
            OnboardingNotificationsView()
        case .connect:
            OnboardingConnectionView(
                phase: connectionPhase,
                connectionMethod: .tailscale,
                showsAutomaticMethod: false,
                onSelectConnectionMethod: selectConnectionMethod
            )
        }
    }

    private func handleBack() {
        switch stage {
        case .agents:
            break
        case .notifications:
            showAgents()
        case .connect:
            showNotifications()
        }
    }

    private func handlePrimary() {
        switch stage {
        case .agents:
            showNotifications()
        case .notifications:
            showConnection()
        case .connect:
            finishOrStartPairing()
        }
    }

    private func showAgents() {
        navigate(to: .agents)
    }

    private func showNotifications() {
        navigate(to: .notifications)
    }

    private func showConnection() {
        navigate(to: .connect)
    }

    private func reachConnectionIfNeeded() {
        guard stage == .connect, !didReachConnection else { return }
        didReachConnection = true
        onReachedConnection()
    }

    private func navigate(to destination: OnboardingStage) {
        guard destination != stage else { return }
        stage = destination
    }

    private func skip() {
        analytics.capture("ios_onboarding_skipped", eventProperties)
        onSkip()
    }

    private func finishOrStartPairing() {
        switch connectionPhase {
        case .idle, .fallback:
            startTailscalePairing()
        case .searching:
            break
        case .ready:
            analytics.capture("ios_onboarding_completed", eventProperties)
            onComplete()
        }
    }

    private func handleSecondary() {
        startTailscalePairing()
    }

    private func selectConnectionMethod(_ method: MobileConnectionMethod) {
        guard method != connectionMethod else { return }
        var properties = eventProperties
        properties["connection_method"] = .string(method.rawValue)
        analytics.capture("ios_onboarding_connection_method_selected", properties)
        onSelectConnectionMethod(method)
    }

    private func startTailscalePairing() {
        var properties = eventProperties
        properties["source"] = .string("tailscale_choice")
        analytics.capture("ios_onboarding_pairing_started", properties)
        onStartFallbackPairing()
    }

    private func captureSceneViewed() {
        var properties = eventProperties
        properties["surface"] = .string(stage.analyticsValue)
        analytics.capture("ios_onboarding_scene_viewed", properties)
    }

    private var eventProperties: [String: AnalyticsValue] {
        [
            "context": .string(context.rawValue),
            "stage": .string(stage.analyticsValue)
        ]
    }
}
#endif
