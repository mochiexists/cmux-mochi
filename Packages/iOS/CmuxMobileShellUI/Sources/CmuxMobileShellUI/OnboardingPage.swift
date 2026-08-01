#if os(iOS)
import CmuxMobileSupport
import Foundation

/// Value model for an onboarding page: an SF Symbol, a title, a body, an optional
/// checklist of short bullet items, and zero or more inline links. Pure data so
/// the page list is trivial to extend.
struct OnboardingPage: Sendable {
    let systemImage: String
    let title: String
    let body: String
    /// Short "do this" bullets, shown under the body. Empty when the page is pure
    /// prose. Used by the optional private-network page.
    let checklist: [String]
    /// Inline links shown under the checklist.
    let links: [OnboardingPageLink]

    init(
        systemImage: String,
        title: String,
        body: String,
        checklist: [String] = [],
        links: [OnboardingPageLink] = []
    ) {
        self.systemImage = systemImage
        self.title = title
        self.body = body
        self.checklist = checklist
        self.links = links
    }

    /// The ordered first-run pages: what cmux is, how Iroh connects, optional
    /// private-network paths, and how to pair.
    static var allPages: [OnboardingPage] {
        [whatItIs, howItConnects, privateNetworkOptions, pairNow]
    }

    private static var whatItIs: OnboardingPage {
        OnboardingPage(
            systemImage: "terminal",
            title: L10n.string(
                "mobile.onboarding.whatTitle",
                defaultValue: "Your Mac's terminals, on your phone"
            ),
            body: L10n.string(
                "mobile.onboarding.whatBody",
                defaultValue: "cmux runs your terminals and AI coding agents on your Mac. This app lets you watch them, type, and get notified when an agent needs you, right from your phone."
            )
        )
    }

    private static var howItConnects: OnboardingPage {
        OnboardingPage(
            systemImage: "lock.laptopcomputer",
            title: L10n.string(
                "mobile.onboarding.connectTitle",
                defaultValue: "Encrypted wherever you connect"
            ),
            // Fork (cmux Mochi): upstream's copy describes an Iroh-first journey
            // verified by a cmux account. This fork pairs over Tailscale using a
            // short-lived ticket from the Mac, so the account is not what secures
            // it and saying so would be false.
            //
            // Scoped deliberately to the SCANNED CODE rather than to every
            // connection: release builds pin the pairing LISTENER to the Tailscale
            // interface, but Iroh is admitted on its own endpoint and does not pass
            // through that listener. "The Mac refuses everything else" would
            // therefore be untrue for a signed-in user on Iroh.
            body: L10n.string(
                "mobile.onboarding.connectBody",
                defaultValue: "Your phone reaches the Mac over your own Tailscale network, so terminal traffic goes straight to your Mac. The Mac only accepts connections that arrive over that network, and only with a code it issued."
            )
        )
    }

    private static var privateNetworkOptions: OnboardingPage {
        OnboardingPage(
            systemImage: "point.3.connected.trianglepath.dotted",
            // Fork (cmux Mochi): Tailscale is REQUIRED here, not a later
            // optimisation. Release builds pin the Mac's pairing listener to the
            // Tailscale interface, so with Tailscale down the Mac does not listen
            // at all. Upstream's "optional" wording would leave a user staring at a
            // Mac that silently never appears.
            title: L10n.string(
                "mobile.onboarding.privateNetworkTitle",
                defaultValue: "Tailscale is required"
            ),
            body: L10n.string(
                "mobile.onboarding.privateNetworkBody",
                defaultValue: "This is how your phone finds your Mac. Install Tailscale on both devices and sign in to the same tailnet. Until then the Mac will not accept a scanned code."
            ),
            checklist: [
                L10n.string(
                    "mobile.onboarding.privateNetworkStep1",
                    defaultValue: "Install Tailscale on this phone and on the Mac, signed in to the same tailnet."
                ),
                L10n.string(
                    "mobile.onboarding.privateNetworkStep2",
                    defaultValue: "Leave cmux running on the Mac so it can accept the connection."
                ),
                L10n.string(
                    "mobile.onboarding.privateNetworkStep3",
                    defaultValue: "No cmux account needed — choose Continue without an account."
                ),
            ],
            links: [
                OnboardingPageLink(
                    title: L10n.string(
                        "mobile.onboarding.tailscaleAppStoreLink",
                        defaultValue: "Get Tailscale for iPhone"
                    ),
                    url: URL(string: "https://apps.apple.com/app/tailscale/id1470499037")!
                ),
                OnboardingPageLink(
                    title: L10n.string(
                        "mobile.onboarding.tailscaleLink",
                        defaultValue: "Get Tailscale for Mac"
                    ),
                    url: URL(string: "https://tailscale.com/download")!
                ),
            ]
        )
    }

    private static var pairNow: OnboardingPage {
        OnboardingPage(
            systemImage: "qrcode.viewfinder",
            title: L10n.string(
                "mobile.onboarding.pairTitle",
                defaultValue: "Pair your Mac"
            ),
            // Fork (cmux Mochi): the code is a short-lived attach ticket for the
            // tailnet, not an Iroh code, and it authorizes on its own — so this page
            // must not send the user looking for an account first.
            body: L10n.string(
                "mobile.onboarding.pairBody",
                defaultValue: "On your Mac open Settings → Mobile → Pair a Device, then scan the code here. The code authorizes this phone by itself and expires within the hour. cmux remembers the Mac and reconnects."
            )
        )
    }
}
#endif
