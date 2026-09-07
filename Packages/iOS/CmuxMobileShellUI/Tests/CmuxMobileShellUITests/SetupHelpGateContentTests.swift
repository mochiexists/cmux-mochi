import Foundation
import CmuxMobileWorkspace
import Testing
@testable import CmuxMobileShellUI

@Suite struct SetupHelpGateContentTests {
    @Test func setupGatesDoNotExposeExternalPurchaseLinks() {
        let gates: [MobileSetupGuidanceState] = [
            .notSignedIn,
            .signedInNeverPaired,
            .macUnreachable,
            .accountMismatch,
        ]

        for gate in gates {
            let url = SetupHelpGateContent.content(for: gate).link?.url.absoluteString
            #expect(url?.contains("founders-edition") != true)
            #expect(url?.contains("github.com/manaflow-ai/cmux") != true)
        }
    }

    @Test func signedInNeverPairedGateUsesInAppInstructionsOnly() {
        let content = SetupHelpGateContent.content(for: .signedInNeverPaired)

        #expect(content.link == nil)
    }

    @Test func setupGuidanceUsesAccountFreeQRLanguage() {
        for gate in MobileSetupGuidanceState.allCases {
            let content = SetupHelpGateContent.content(for: gate)
            let copy = "\(content.title) \(content.body)".lowercased()
            #expect(!copy.contains("sign in"))
            #expect(!copy.contains("same account"))
        }

        let firstRun = SetupHelpGateContent.content(for: .notSignedIn)
        #expect(firstRun.body.localizedCaseInsensitiveContains("without a cmux account"))
        #expect(firstRun.body.localizedCaseInsensitiveContains("QR code"))

        let rejected = SetupHelpGateContent.content(for: .accountMismatch)
        #expect(rejected.title.localizedCaseInsensitiveContains("pair again"))
        #expect(rejected.body.localizedCaseInsensitiveContains("fresh QR code"))
    }

    @Test func connectionRejectionUsesFreshPairingInsteadOfAccountRecovery() {
        let copy = String(localized: MobileConnectionRecoveryBanner.defaultPairingRejectionDescription)
        #expect(copy.localizedCaseInsensitiveContains("Pair a Device"))
        #expect(copy.localizedCaseInsensitiveContains("fresh QR code"))
        #expect(!copy.localizedCaseInsensitiveContains("account"))
        #expect(!copy.localizedCaseInsensitiveContains("sign out"))
    }
}
