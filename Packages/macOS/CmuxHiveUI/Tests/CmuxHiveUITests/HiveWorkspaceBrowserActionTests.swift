import CmuxHive
import CmuxMobileShellModel
import Testing
@testable import CmuxHiveUI

@Suite("Hive workspace browser actions")
struct HiveWorkspaceBrowserActionTests {
    @Test("paired-offline state offers only the selected Mac connect action")
    func pairedOfflineOffersOneConnectAction() {
        let phase = HiveWorkspaceCoordinator.Phase.pairedOffline(
            message: "Offline",
            guidance: nil
        )

        #expect(HiveWorkspaceBrowserView.statusAction(for: phase) == nil)
        #expect(HiveWorkspaceBrowserView.pairedMacAction(for: .unavailable) == .connect)
    }

    @Test("failure state offers retry while connected Mac needs no action")
    func failureOffersRetry() {
        let phase = HiveWorkspaceCoordinator.Phase.failed(
            message: "Failed",
            guidance: nil
        )

        #expect(HiveWorkspaceBrowserView.statusAction(for: phase) == .retry)
        #expect(HiveWorkspaceBrowserView.pairedMacAction(for: .connected) == nil)
    }
}
