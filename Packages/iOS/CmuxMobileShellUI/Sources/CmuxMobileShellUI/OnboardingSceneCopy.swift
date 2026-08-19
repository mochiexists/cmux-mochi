#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct OnboardingSceneCopy: View {
    let title: String
    let message: String
    let alignment: TextAlignment
    /// Fork (cmux Mochi): the first onboarding screen carries the fork's own
    /// mark, so a new install knows whose app this is before any upstream-styled
    /// flow copy. Without it the Mochi identity first appeared on the Add
    /// Computer sheet — a screen too late.
    var showsBrandMark: Bool = false

    var body: some View {
        VStack(alignment: alignment == .leading ? .leading : .center, spacing: 12) {
            if showsBrandMark {
                brandMark
            }

            OnboardingBalancedText(
                title,
                role: .title,
                alignment: alignment
            )

            OnboardingBalancedText(
                message,
                role: .body,
                alignment: alignment,
                maximumNumberOfLines: 2
            )
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .center)
    }

    private var brandMark: some View {
        HStack(spacing: 8) {
            Image("MochiLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            Text(L10n.string("mobile.onboarding.brand", defaultValue: "cmux Mochi"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("MobileOnboardingBrandMark")
    }
}
#endif
