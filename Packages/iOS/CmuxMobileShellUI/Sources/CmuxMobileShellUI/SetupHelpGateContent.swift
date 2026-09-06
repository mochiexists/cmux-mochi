#if os(iOS)
import CmuxMobileSupport
import CmuxMobileWorkspace
import Foundation

/// The static guidance shown for one setup gate in ``SetupHelpView``.
struct SetupHelpGateContent {
    let systemImage: String
    let title: String
    let body: String
    let link: SetupHelpGateLink?
    let identifierSuffix: String
    let linkAccessibilityIdentifier: String

    /// Maps a setup gate to its title, icon, copy, and optional link. Pure and
    /// scoped to the content type so the gate guidance is data, separate from
    /// the view that lays it out.
    static func content(for gate: MobileSetupGuidanceState) -> SetupHelpGateContent {
        switch gate {
        case .notSignedIn:
            return SetupHelpGateContent(
                systemImage: "qrcode.viewfinder",
                title: L10n.string("mobile.setupHelp.signInTitle", defaultValue: "Scan the pairing code"),
                body: L10n.string(
                    "mobile.setupHelp.signInBody",
                    defaultValue: "Open Pair a Device in cmux on your computer and scan its QR code. Pairing works without a cmux account."
                ),
                link: nil,
                identifierSuffix: "notSignedIn",
                linkAccessibilityIdentifier: "MobileSetupHelpSignInLink"
            )
        case .signedInNeverPaired:
            return SetupHelpGateContent(
                systemImage: "desktopcomputer",
                title: L10n.string("mobile.setupHelp.macAppTitle", defaultValue: "Run cmux on your computer"),
                body: L10n.string(
                    "mobile.setupHelp.macAppBody",
                    defaultValue: "Keep cmux running on the computer. Open Pair a Device, then scan its QR code here while both devices share a local network or Tailscale."
                ),
                link: nil,
                identifierSuffix: "signedInNeverPaired",
                linkAccessibilityIdentifier: "MobileSetupHelpMacAppLink"
            )
        case .macUnreachable:
            return SetupHelpGateContent(
                systemImage: "wifi.exclamationmark",
                title: L10n.string("mobile.setupHelp.unreachableTitle", defaultValue: "Wake the computer"),
                body: L10n.string(
                    "mobile.setupHelp.unreachableBody",
                    defaultValue: "You paired this computer before, but it is not reachable now. Wake it and make sure cmux is running. Join the same local network, or connect both devices to Tailscale; this phone reconnects on its own."
                ),
                link: nil,
                identifierSuffix: "macUnreachable",
                linkAccessibilityIdentifier: "MobileSetupHelpUnreachableLink"
            )
        case .accountMismatch:
            return SetupHelpGateContent(
                systemImage: "qrcode.viewfinder",
                title: L10n.string("mobile.setupHelp.mismatchTitle", defaultValue: "Pair again"),
                body: L10n.string(
                    "mobile.setupHelp.mismatchBody",
                    defaultValue: "The computer rejected this phone's saved pairing. Open Pair a Device on the computer and scan a fresh QR code."
                ),
                link: nil,
                identifierSuffix: "accountMismatch",
                linkAccessibilityIdentifier: "MobileSetupHelpMismatchLink"
            )
        }
    }
}
#endif
