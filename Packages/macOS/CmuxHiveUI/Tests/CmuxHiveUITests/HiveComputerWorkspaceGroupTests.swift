import CmuxMobileShellModel
import Testing
@testable import CmuxHiveUI

@Suite("Hive computer workspace groups")
struct HiveComputerWorkspaceGroupTests {
    @Test("keeps sibling Mac workspaces in distinct picker sections")
    func groupsByAuthenticatedMac() {
        let workspaces = [
            MobileWorkspacePreview(
                id: "one",
                macDeviceID: "mac-a",
                macDisplayName: "Studio",
                name: "One",
                terminals: []
            ),
            MobileWorkspacePreview(
                id: "two",
                macDeviceID: "mac-b",
                macDisplayName: "Laptop",
                name: "Two",
                terminals: []
            ),
        ]

        let groups = HiveComputerWorkspaceGroup.grouped(workspaces)

        #expect(groups.map(\.deviceID) == ["mac-b", "mac-a"])
        #expect(groups.map(\.displayName) == ["Laptop", "Studio"])
    }
}
