/// Root-presentation decisions for first-run onboarding.
public enum MobileOnboardingPresentationPolicy {
    /// An injected QR route owns the current launch, but does not itself prove
    /// pairing succeeded. Hide onboarding temporarily and leave the durable
    /// milestone untouched until the connection reaches ``connected``.
    public static func shouldShow(
        progress: MobileOnboardingProgress,
        hasInjectedAttachLaunchRoute: Bool
    ) -> Bool {
        progress != .complete && !hasInjectedAttachLaunchRoute
    }

    /// A real computer connection is the durable completion milestone promised
    /// by ``MobileOnboardingStore``. Persist it regardless of whether this launch
    /// arrived through the scanner, an injected dev QR, or stored-device reconnect.
    public static func shouldMarkComplete(
        progress: MobileOnboardingProgress,
        isConnected: Bool
    ) -> Bool {
        isConnected && progress != .complete
    }
}
