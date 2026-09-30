import CmuxMobileShellModel
import Observation

/// Owns workspace-list selection tasks whose identity must survive SwiftUI view copies.
@MainActor
@Observable
final class WorkspaceListSelectionCoordinator {
    var macTitlePickerSwitchTask: Task<Void, Never>?
    var macTitlePickerSwitchIsCancellation = false
    var macTitlePickerSwitchGeneration: UInt64 = 0
    var macTitlePickerPendingSelection: WorkspaceMacSelection?
    var deferredWorkspaceSelectionGeneration: UInt64 = 0
}
