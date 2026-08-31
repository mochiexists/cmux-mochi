import Testing

@testable import CmuxMobileShellModel

@Suite struct MobilePairingScannerPresentationTests {
    @Test func scannerOwnsPairingProgressAndFailureUntilTheUserRetries() {
        #expect(MobilePairingScannerPresentation.resolve(
            didScanCode: false,
            isPairing: false,
            error: nil,
            guidance: nil,
            versionWarning: nil
        ) == .scanning)
        #expect(MobilePairingScannerPresentation.resolve(
            didScanCode: true,
            isPairing: true,
            error: nil,
            guidance: nil,
            versionWarning: nil
        ) == .connecting)
        #expect(MobilePairingScannerPresentation.resolve(
            didScanCode: true,
            isPairing: false,
            error: "Could not reach your Mac.",
            guidance: "Keep cmux open and scan a fresh QR code.",
            versionWarning: nil
        ) == .failed(
            message: "Could not reach your Mac.",
            guidance: "Keep cmux open and scan a fresh QR code."
        ))
    }

    @Test func activeRetryHidesThePreviousFailure() {
        #expect(MobilePairingScannerPresentation.resolve(
            didScanCode: true,
            isPairing: true,
            error: "The previous attempt failed.",
            guidance: nil,
            versionWarning: nil
        ) == .connecting)
    }

    @Test func compatibilityWarningBecomesAnExplicitDecision() {
        #expect(MobilePairingScannerPresentation.resolve(
            didScanCode: true,
            isPairing: false,
            error: nil,
            guidance: nil,
            versionWarning: "This Mac is newer than this iPhone app."
        ) == .versionWarning(message: "This Mac is newer than this iPhone app."))
    }
}
