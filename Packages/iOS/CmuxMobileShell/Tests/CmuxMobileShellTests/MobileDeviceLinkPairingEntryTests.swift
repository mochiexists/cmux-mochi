import Testing

@testable import CmuxMobileShell

@MainActor
@Suite("DeviceLink pairing entry")
struct MobileDeviceLinkPairingEntryTests {
    @Test("legacy attach grammar is rejected before connection setup")
    func legacyAttachGrammarIsRejected() async {
        let store = MobileShellComposite.preview()

        let result = await store.connectPairingURLResult(
            "cmux-ios://attach?v=2&r=100.71.210.41:58465"
        )

        #expect(result == .failed)
        #expect(store.connectionState == .disconnected)
        #expect(store.activeTicket == nil)
        #expect(store.activeRoute == nil)
        #expect(store.connectionError == MobilePairingFailureCategory.invalidCode.message)
    }
}
