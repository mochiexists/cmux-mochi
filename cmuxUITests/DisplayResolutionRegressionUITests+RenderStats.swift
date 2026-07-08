import Foundation

extension DisplayResolutionRegressionUITests {
    struct RenderStats: CustomStringConvertible {
        let panelId: String
        let drawCount: Int
        let metalDrawableCount: Int
        let metalLastDrawableTime: Double
        let presentCount: Int
        let lastPresentTime: Double
        let windowVisible: Bool
        let appIsActive: Bool
        let desiredFocus: Bool
        let isFirstResponder: Bool
        let diagnosticsUpdatedAt: Double

        init?(diagnostics: [String: String]) {
            guard diagnostics["renderStatsAvailable"] == "1",
                  let panelId = diagnostics["renderPanelId"], !panelId.isEmpty,
                  let drawCount = Int(diagnostics["renderDrawCount"] ?? ""),
                  let metalDrawableCount = Int(diagnostics["renderMetalDrawableCount"] ?? ""),
                  let metalLastDrawableTime = Double(diagnostics["renderMetalLastDrawableTime"] ?? ""),
                  let presentCount = Int(diagnostics["renderPresentCount"] ?? ""),
                  let lastPresentTime = Double(diagnostics["renderLastPresentTime"] ?? ""),
                  let diagnosticsUpdatedAt = Double(diagnostics["renderDiagnosticsUpdatedAt"] ?? "") else {
                return nil
            }

            self.panelId = panelId
            self.drawCount = drawCount
            self.metalDrawableCount = metalDrawableCount
            self.metalLastDrawableTime = metalLastDrawableTime
            self.presentCount = presentCount
            self.lastPresentTime = lastPresentTime
            self.windowVisible = diagnostics["renderWindowVisible"] == "1"
            self.appIsActive = diagnostics["renderAppIsActive"] == "1"
            self.desiredFocus = diagnostics["renderDesiredFocus"] == "1"
            self.isFirstResponder = diagnostics["renderIsFirstResponder"] == "1"
            self.diagnosticsUpdatedAt = diagnosticsUpdatedAt
        }

        var description: String {
            "panel=\(panelId) draw=\(drawCount) metal=\(metalDrawableCount) " +
                "lastMetal=\(String(format: "%.3f", metalLastDrawableTime)) " +
                "present=\(presentCount) lastPresent=\(String(format: "%.3f", lastPresentTime)) " +
                "visible=\(windowVisible) active=\(appIsActive) " +
                "desiredFocus=\(desiredFocus) firstResponder=\(isFirstResponder) " +
                "updatedAt=\(String(format: "%.3f", diagnosticsUpdatedAt))"
        }
    }
}
