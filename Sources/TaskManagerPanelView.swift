import SwiftUI

struct TaskManagerPanelView: View {
    let panel: TaskManagerPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let onRequestPanelFocus: () -> Void

    var body: some View {
        CmuxTaskManagerView(model: panel.model, minimumSize: nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                onRequestPanelFocus()
            }
    }
}
