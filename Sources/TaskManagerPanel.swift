import Foundation
import SwiftUI

/// Runtime backing for a Task Manager surface hosted as a tab.
///
/// Owns the `CmuxTaskManagerModel` that drives the activity table. The model's
/// sampling timer is started/stopped by `CmuxTaskManagerView`'s onAppear /
/// onDisappear, so this panel is a thin holder. Task Manager surfaces are
/// ephemeral and are deliberately not persisted across launches.
@MainActor
final class TaskManagerPanel: NSObject, Panel, ObservableObject {
    let id = UUID()
    let panelType: PanelType = .taskManager

    /// Per-surface model so multiple Task Manager tabs sample independently.
    let model: CmuxTaskManagerModel

    var displayTitle: String {
        String(localized: "taskManager.title", defaultValue: "Task Manager")
    }

    var displayIcon: String? { "gauge.with.dots.needle.33percent" }

    override init() {
        let model = CmuxTaskManagerModel()
        // A full tab shows the process table, unlike the aggregate-only footer.
        model.includesProcesses = true
        self.model = model
        super.init()
    }

    func close() {
        model.stop()
    }

    func focus() {}
    func unfocus() {}

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
    }
}
