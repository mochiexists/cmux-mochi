#if os(iOS)
@testable import CmuxMobileShellUI
import Foundation
import SwiftUI
import Testing
import UIKit

@Suite struct OnboardingSceneChromeTests {
    @Test func productPagesKeepExpectedNavigationChrome() {
        let agents = OnboardingSceneChrome(
            stage: .agents,
            isAuthenticated: true,
            connectionPhase: .searching
        )
        let notifications = OnboardingSceneChrome(
            stage: .notifications,
            isAuthenticated: true,
            connectionPhase: .searching
        )

        #expect(!agents.showsBack)
        #expect(agents.showsSkip)
        #expect(agents.primaryTitle != nil)
        #expect(agents.secondaryTitle == nil)

        #expect(notifications.showsBack)
        #expect(notifications.showsSkip)
        #expect(notifications.primaryTitle != nil)
        #expect(notifications.secondaryTitle == nil)
    }

    @Test func connectionChromeIsQRFirstWithOrWithoutAccountAuthentication() {
        let signedOut = OnboardingSceneChrome(
            stage: .connect,
            isAuthenticated: false,
            connectionPhase: .idle,
            connectionMethod: .tailscale
        )
        let searching = OnboardingSceneChrome(
            stage: .connect,
            isAuthenticated: true,
            connectionPhase: .searching
        )
        let idle = OnboardingSceneChrome(
            stage: .connect,
            isAuthenticated: true,
            connectionPhase: .idle
        )
        let fallback = OnboardingSceneChrome(
            stage: .connect,
            isAuthenticated: true,
            connectionPhase: .fallback
        )
        let ready = OnboardingSceneChrome(
            stage: .connect,
            isAuthenticated: true,
            connectionPhase: .ready
        )

        #expect(signedOut.showsBack)
        #expect(!signedOut.showsSkip)
        #expect(signedOut.primaryTitle == "Scan Pairing Code")
        #expect(signedOut.secondaryTitle == nil)

        #expect(searching.primaryTitle == nil)
        #expect(searching.secondaryTitle == nil)
        #expect(idle.primaryTitle != nil)
        #expect(idle.secondaryTitle == nil)
        #expect(fallback.primaryTitle == "Scan Pairing Code")
        #expect(fallback.secondaryTitle == nil)
        #expect(ready.primaryTitle != nil)
        #expect(ready.secondaryTitle == nil)
    }

    @Test func screenshotLanguageMatchesTheSupportedLocale() {
        #expect(
            OnboardingScreenshotLanguage.resolve(
                locale: Locale(identifier: "en_US")
            ) == .english
        )
        #expect(
            OnboardingScreenshotLanguage.resolve(
                locale: Locale(identifier: "ja_JP")
            ) == .japanese
        )
        #expect(
            OnboardingScreenshotLanguage.resolve(
                locale: Locale(identifier: "fr_FR")
            ) == .english
        )
    }

    @Test @MainActor func everyLocalizedOnboardingScreenshotLoads() async {
        for content in OnboardingScreenshot.Content.allCases {
            for language in OnboardingScreenshotLanguage.allCases {
                for appearance in OnboardingScreenshotAppearance.allCases {
                    let image = await OnboardingScreenshot.image(
                        content: content,
                        language: language,
                        appearance: appearance
                    )
                    #expect(image.size.width > 0)
                    #expect(image.size.height > 0)
                }
            }
        }
    }

    @Test func screenshotAppearanceMatchesTheSystemColorScheme() {
        #expect(OnboardingScreenshotAppearance.resolve(colorScheme: .light) == .light)
        #expect(OnboardingScreenshotAppearance.resolve(colorScheme: .dark) == .dark)
    }

    @Test @MainActor func onboardingCopyUsesNativeLineBalancing() {
        let label = OnboardingBalancedText.makeLabel()
        label.font = .preferredFont(forTextStyle: .body)
        label.text = "Review every agent alert in one feed, even when push alerts are off."
        let maximumWidth: CGFloat = 360
        let maximumHeight = label.sizeThatFits(
            CGSize(width: maximumWidth, height: .greatestFiniteMagnitude)
        ).height
        let balancedSize = OnboardingBalancedText.balancedSize(
            for: label,
            maximumWidth: maximumWidth
        )

        #expect(label.numberOfLines == 0)
        #expect(label.lineBreakMode == .byWordWrapping)
        #expect(label.lineBreakStrategy == .pushOut)
        #expect(balancedSize.width < maximumWidth)
        #expect(balancedSize.height == ceil(maximumHeight))
    }

    @Test @MainActor func onboardingSubtitlesCanBeCappedAtTwoLines() {
        let label = OnboardingBalancedText.makeLabel()
        OnboardingBalancedText.configure(
            label,
            text: "Scan the pairing code shown on your Mac. cmux uses your local network when available and Tailscale when you're away.",
            role: .body,
            alignment: .center,
            maximumNumberOfLines: 2
        )
        let balancedSize = OnboardingBalancedText.balancedSize(
            for: label,
            maximumWidth: 360
        )

        #expect(label.numberOfLines == 2)
        #expect(balancedSize.width > 120)
    }
}
#endif
