import Testing

@testable import CmuxMobileShellModel

@Suite struct MobilePairingScannerPresentationTests {
    @Test func scannerOwnsPairingProgressAndFailureUntilTheUserRetries() {
        #expect(MobilePairingScannerPresentation.resolve(
            didScanCode: false,
            isPairing: false,
            error: nil,
            guidance: nil
        ) == .scanning)
        #expect(MobilePairingScannerPresentation.resolve(
            didScanCode: true,
            isPairing: true,
            error: nil,
            guidance: nil
        ) == .connecting)
        #expect(MobilePairingScannerPresentation.resolve(
            didScanCode: true,
            isPairing: false,
            error: "Could not reach your Mac.",
            guidance: "Keep cmux open and scan a fresh QR code."
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
            guidance: nil
        ) == .connecting)
    }
}
