import CmuxMobileShellModel
import Testing
@testable import CmuxHiveUI

@Suite("Hive computer workspace groups")
struct HiveComputerWorkspaceGroupTests {
    @Test("keeps sibling Mac workspaces in distinct picker sections")
    func groupsByAuthenticatedMac() {
        var nightlyWorkspace = MobileWorkspacePreview(
            id: "nightly",
            macDeviceID: "mac-a",
            macDisplayName: "Studio",
            name: "Nightly",
            terminals: []
        )
        nightlyWorkspace.macInstanceTag = "nightly"
        var stableWorkspace = MobileWorkspacePreview(
            id: "stable",
            macDeviceID: "mac-a",
            macDisplayName: "Studio",
            name: "Stable",
            terminals: []
        )
        stableWorkspace.macInstanceTag = "stable"
        let workspaces = [
            MobileWorkspacePreview(
                id: "one",
                macDeviceID: "mac-b",
                macDisplayName: "Laptop",
                name: "One",
                terminals: []
            ),
            nightlyWorkspace,
            stableWorkspace,
        ]

        let groups = HiveComputerWorkspaceGroup.grouped(workspaces)

        #expect(groups.count == 3)
        #expect(groups.filter { $0.deviceID == "mac-a" }.map(\.instanceTag) == ["nightly", "stable"])
        #expect(Set(groups.map(\.id)).count == 3)
    }
}
