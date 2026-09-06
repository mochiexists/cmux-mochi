import Testing

@testable import CmuxMobileShellModel

@Suite("Pairing URL result semantics")
struct MobilePairingURLConnectionResultTests {
    @Test func durableOfflinePairingIsNotReportedAsConnected() {
        let result = MobilePairingURLConnectionResult.pairedOffline

        #expect(result.didPair)
        #expect(!result.didConnect)
    }

    @Test func failedValidationIsNeitherPairedNorConnected() {
        let result = MobilePairingURLConnectionResult.failed

        #expect(!result.didPair)
        #expect(!result.didConnect)
    }
}
