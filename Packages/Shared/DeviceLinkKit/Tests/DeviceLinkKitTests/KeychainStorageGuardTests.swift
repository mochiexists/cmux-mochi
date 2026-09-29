import Foundation
import Testing

@testable import DeviceLinkKit

@Suite("Keychain test-process guard")
struct KeychainStorageGuardTests {
    @Test("production stores reject access from a test process")
    func rejectsTestProcessAccess() {
        let store = KeychainServerPinStore(
            scope: KeychainScope(bundleIdentifier: "com.cmux.keychain-guard-tests")
        )

        #expect(throws: KeychainStorageError.testProcessAccess) {
            _ = try store.pins()
        }
    }
}
