#if DEBUG
import AppKit
import Foundation

extension AppDelegate {
    private struct UITestRenderDiagnosticsSnapshot {
        let panelId: UUID
        let drawCount: Int
        let metalDrawableCount: Int
        let metalLastDrawableTime: Double
        let presentCount: Int
        let lastPresentTime: Double
        let windowVisible: Bool
        let appIsActive: Bool
        let desiredFocus: Bool
        let isFirstResponder: Bool
    }

    func appendUITestRenderDiagnosticsIfNeeded(
        _ payload: inout [String: String],
        environment env: [String: String]
    ) {
        guard env["CMUX_UI_TEST_DISPLAY_RENDER_STATS"] == "1" else { return }

        guard let renderState = currentUITestRenderDiagnostics() else {
            payload["renderStatsAvailable"] = "0"
            payload["renderPanelId"] = ""
            payload["renderDrawCount"] = ""
            payload["renderMetalDrawableCount"] = ""
            payload["renderMetalLastDrawableTime"] = ""
            payload["renderPresentCount"] = ""
            payload["renderLastPresentTime"] = ""
            payload["renderWindowVisible"] = ""
            payload["renderAppIsActive"] = ""
            payload["renderDesiredFocus"] = ""
            payload["renderIsFirstResponder"] = ""
            payload["renderDiagnosticsUpdatedAt"] = String(format: "%.6f", ProcessInfo.processInfo.systemUptime)
            return
        }

        payload["renderStatsAvailable"] = "1"
        payload["renderPanelId"] = renderState.panelId.uuidString
        payload["renderDrawCount"] = String(renderState.drawCount)
        payload["renderMetalDrawableCount"] = String(renderState.metalDrawableCount)
        payload["renderMetalLastDrawableTime"] = String(format: "%.6f", renderState.metalLastDrawableTime)
        payload["renderPresentCount"] = String(renderState.presentCount)
        payload["renderLastPresentTime"] = String(format: "%.6f", renderState.lastPresentTime)
        payload["renderWindowVisible"] = renderState.windowVisible ? "1" : "0"
        payload["renderAppIsActive"] = renderState.appIsActive ? "1" : "0"
        payload["renderDesiredFocus"] = renderState.desiredFocus ? "1" : "0"
        payload["renderIsFirstResponder"] = renderState.isFirstResponder ? "1" : "0"
        payload["renderDiagnosticsUpdatedAt"] = String(format: "%.6f", ProcessInfo.processInfo.systemUptime)
    }

    private func currentUITestRenderDiagnostics() -> UITestRenderDiagnosticsSnapshot? {
        guard let terminalPanel = focusedDisplayResolutionUITestTerminalPanel() else { return nil }
        let stats = terminalPanel.hostedView.debugRenderStats()
        return UITestRenderDiagnosticsSnapshot(
            panelId: terminalPanel.id,
            drawCount: stats.drawCount,
            metalDrawableCount: stats.metalDrawableCount,
            metalLastDrawableTime: stats.metalLastDrawableTime,
            presentCount: stats.presentCount,
            lastPresentTime: stats.lastPresentTime,
            windowVisible: stats.windowOcclusionVisible,
            appIsActive: stats.appIsActive,
            desiredFocus: stats.desiredFocus,
            isFirstResponder: stats.isFirstResponder
        )
    }

    func refreshDisplayResolutionUITestTerminal(reason: String) {
        focusedDisplayResolutionUITestTerminalPanel()?.surface.forceRefresh(reason: reason)
    }

    private func focusedDisplayResolutionUITestTerminalPanel() -> TerminalPanel? {
        guard let tabManager,
              let tabId = tabManager.selectedTabId,
              let workspace = tabManager.tabs.first(where: { $0.id == tabId }) else {
            return nil
        }

        if let focusedPanelId = workspace.focusedPanelId,
           let terminalPanel = workspace.terminalPanel(for: focusedPanelId) {
            return terminalPanel
        }
        if let focusedTerminalPanel = workspace.focusedTerminalPanel {
            return focusedTerminalPanel
        }
        return workspace.panels.values.compactMap { $0 as? TerminalPanel }.first
    }
}
#endif
