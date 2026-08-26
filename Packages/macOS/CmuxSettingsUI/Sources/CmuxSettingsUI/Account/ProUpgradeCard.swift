import CmuxFoundation
import SwiftUI

enum ProUpgradePresentationPolicy {
    static func isMochiFork(bundleIdentifier: String?) -> Bool {
        bundleIdentifier?.hasPrefix("com.cmux-mochi") == true
    }

    static func showsAccountCard(
        bundleIdentifier: String?,
        upstreamUpgradeAvailable: Bool
    ) -> Bool {
        isMochiFork(bundleIdentifier: bundleIdentifier) || upstreamUpgradeAvailable
    }

    static func showsUpgradeAction(
        bundleIdentifier: String?,
        isProActive: Bool,
        canManageBilling: Bool
    ) -> Bool {
        guard !isMochiFork(bundleIdentifier: bundleIdentifier) else { return false }
        return !isProActive || canManageBilling
    }
}

/// Upgrade row rendered below the identity card in the Account section.
///
/// Shows the cmux Pro pitch (one title line + one price/value subtitle)
/// with a trailing button that asks the host to open the pricing page in
/// the default browser via ``AccountFlow/openProUpgrade()`` or the billing
/// portal via ``AccountFlow/openBillingPortal()`` for Stripe-managed subscribers.
@MainActor
struct ProUpgradeCard: View {
    let flow: AccountFlow?

    static var isMochiFork: Bool {
        ProUpgradePresentationPolicy.isMochiFork(
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
    }

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
            if shouldShowAction {
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
            if hovering, !Self.isMochiFork, flow?.canManageBilling != true {
                flow?.prefetchProUpgrade()
            }
        }
        .task(id: flow?.currentIdentity?.id ?? "") {
            guard !Self.isMochiFork else { return }
            await flow?.refreshBillingPlan()
        }
    }

    private var subtitleText: String {
        if Self.isMochiFork {
            return String(
                localized: "settings.account.pro.mochiFork",
                defaultValue: "This is cmux Mochi, a personal fork for account-free iPhone access. There is no Pro plan here — support cmux upstream instead."
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
            defaultValue: "Cloud dev boxes, the iOS app, and cmux AI. $30/month, or $288/year."
        )
    }

    private var buttonTitle: String {
        if flow?.canManageBilling == true {
            return String(localized: "settings.account.pro.manageBilling", defaultValue: "Manage billing")
        }
        return String(localized: "settings.account.pro.upgrade", defaultValue: "Upgrade…")
    }

    private var shouldShowAction: Bool {
        ProUpgradePresentationPolicy.showsUpgradeAction(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            isProActive: flow?.isProActive == true,
            canManageBilling: flow?.canManageBilling == true
        )
    }
}
