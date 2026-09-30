import Foundation
import Testing

@testable import DeviceLinkKit

@Suite("Keychain test-process guard")
struct KeychainStorageGuardTests {
    @Test("bare Swift Testing environment flag does not classify an app as a test host")
    func ignoresAmbientSwiftTestingEnvironmentFlag() {
        let evidence = KeychainTestProcessEvidence(
            environment: ["SWIFT_TESTING_ENABLED": "1"],
            executablePath: "/Applications/cmux.app/Contents/MacOS/cmux",
            processName: "cmux",
            loadedImagePaths: [
                "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation",
            ]
        )

        #expect(!evidence.isTestHost)
    }

    @Test(
        "real test-host evidence is classified as a test",
        arguments: [
            KeychainTestProcessEvidence(
                environment: [:],
                executablePath: "/tmp/DeviceLinkKitPackageTests.xctest/Contents/MacOS/DeviceLinkKitPackageTests",
                processName: "DeviceLinkKitPackageTests",
                loadedImagePaths: []
            ),
            KeychainTestProcessEvidence(
                environment: [:],
                executablePath: "/tmp/swiftpm-testing-helper",
                processName: "swiftpm-testing-helper",
                loadedImagePaths: []
            ),
            KeychainTestProcessEvidence(
                environment: [:],
                executablePath: "/Applications/cmux.app/Contents/MacOS/cmux",
                processName: "cmux",
                loadedImagePaths: [
                    "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks/Testing.framework/Versions/A/Testing",
                ]
            ),
        ]
    )
    func recognizesRealTestHostEvidence(_ evidence: KeychainTestProcessEvidence) {
        #expect(evidence.isTestHost)
    }

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
