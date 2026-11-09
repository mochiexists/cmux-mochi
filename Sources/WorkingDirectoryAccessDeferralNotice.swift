import CmuxTerminal
import Foundation

/// Marks the pane of a terminal that started in the home folder because its
/// own working directory did not open in time (see
/// `TerminalWorkingDirectoryAccessGate`). The shell has `cd '<dir>'` queued
/// and lands there once macOS answers; the pane notification says why it is
/// waiting.
@MainActor
final class WorkingDirectoryAccessDeferralNotice {
    /// One notice per stall is enough; every new tab during it would repeat it.
    private static let cooldown: TimeInterval = 60

    private let notificationStore: TerminalNotificationStore
    private var observer: NSObjectProtocol?

    init(notificationStore: TerminalNotificationStore) {
        self.notificationStore = notificationStore
    }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceWorkingDirectoryAccessDeferred,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let workspaceId = notification.userInfo?["workspaceId"] as? UUID,
                  let surfaceId = notification.userInfo?["surfaceId"] as? UUID,
                  let workingDirectory = notification.userInfo?["workingDirectory"] as? String else {
                return
            }
            MainActor.assumeIsolated {
                self?.show(workspaceId: workspaceId, surfaceId: surfaceId, workingDirectory: workingDirectory)
            }
        }
    }

    private func show(workspaceId: UUID, surfaceId: UUID, workingDirectory: String) {
        let format = String(
            localized: "terminal.workingDirectoryAccessDeferred.body",
            defaultValue: "macOS has not answered for %@. This tab started in your home folder and will change to it once access is granted; a privacy prompt may be open."
        )
        notificationStore.addNotification(
            tabId: workspaceId,
            surfaceId: surfaceId,
            title: String(
                localized: "terminal.workingDirectoryAccessDeferred.title",
                defaultValue: "Waiting for file access"
            ),
            subtitle: "",
            body: String(format: format, workingDirectory),
            cooldownKey: "terminal.workingDirectoryAccessDeferred",
            cooldownInterval: Self.cooldown
        )
    }
}
