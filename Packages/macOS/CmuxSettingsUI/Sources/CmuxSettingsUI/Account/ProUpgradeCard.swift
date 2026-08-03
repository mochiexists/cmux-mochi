import CmuxFoundation
import SwiftUI

/// Upgrade row rendered below the identity card in the Account section.
///
/// Shows the cmux Pro pitch (one title line + one price/value subtitle)
/// with a trailing button that asks the host to open the pricing page in
/// the default browser via ``AccountFlow/openProUpgrade()`` or the billing
/// portal via ``AccountFlow/openBillingPortal()`` for Stripe-managed subscribers.
@MainActor
struct ProUpgradeCard: View {
    let flow: AccountFlow?

    init(flow: AccountFlow?) {
        self.flow = flow
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "settings.account.pro.title", defaultValue: "cmux Pro"))
                    .cmuxFont(size: 13, weight: .medium)
                Text(subtitleText)
                    .cmuxFont(size: 11)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            // Fork (cmux Mochi): this build has no Pro plan to sell, so the
            // action is withheld rather than offering something that cannot be
            // bought here. The row still renders, explaining what this build is.
            if !Self.isMochiFork, shouldShowAction {
                Button {
                    if flow?.canManageBilling == true {
                        flow?.openBillingPortal()
                    } else {
                        flow?.openProUpgrade()
                    }
                } label: {
                    Text(buttonTitle)
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .onHover { hovering in
            // Warm the pricing destination while the pointer is over the row
            // so clicking "Upgrade…" opens an already-loaded page. Managed
            // subscribers get the Stripe portal instead, which the host does
            // not prewarm.
            if hovering, flow?.canManageBilling != true {
                flow?.prefetchProUpgrade()
            }
        }
        .task(id: flow?.currentIdentity?.id ?? "") {
            await flow?.refreshBillingPlan()
        }
    }

    /// Whether this is the personal, non-commercial cmux Mochi fork.
    ///
    /// Kept as one flag rather than deleting the Pro screens, so upstream
    /// merges stay clean and this work remains easy to offer back.
    static let isMochiFork = (Bundle.main.bundleIdentifier ?? "").hasPrefix("com.cmux-mochi")

    private var subtitleText: String {
        if Self.isMochiFork {
            return String(
                localized: "settings.account.pro.mochiFork",
                defaultValue: "This is cmux Mochi, a personal fork built for account-free phone access, for the love of the game. There is no Pro plan here \u{2014} support cmux upstream instead."
            )
        }
        if flow?.isProActive == true {
            if flow?.canManageBilling == true {
                return String(
                    localized: "settings.account.pro.activeSubtitle",
                    defaultValue: "Your Pro subscription is active. Manage billing or cancel in Stripe."
                )
            }
            return String(
                localized: "settings.account.pro.externalSubtitle",
                defaultValue: "Your subscription is managed by our previous billing system. Contact support to make changes."
            )
        }
        return String(
            localized: "settings.account.pro.subtitle",
            defaultValue: "Cloud dev boxes, the iOS app, and cmux AI. $30/month, or $240/year."
        )
    }

    private var buttonTitle: String {
        if flow?.canManageBilling == true {
            return String(localized: "settings.account.pro.manageBilling", defaultValue: "Manage billing")
        }
        return String(localized: "settings.account.pro.upgrade", defaultValue: "Upgrade…")
    }

    private var shouldShowAction: Bool {
        flow?.isProActive != true || flow?.canManageBilling == true
    }
}
