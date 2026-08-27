import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Workspace screenshot parity")
struct WorkspaceScreenshotParityTests {
    @Test func everyOutOfProcessRendererHasAnOverlayCaptureRole() {
        #expect(TerminalController.workspaceCaptureOverlayRole(for: .terminal) == .terminal)
        #expect(TerminalController.workspaceCaptureOverlayRole(for: .browser) == .browser)
        #expect(TerminalController.workspaceCaptureOverlayRole(for: .agentSession) == .agentSession)
        #expect(TerminalController.workspaceCaptureOverlayRole(for: .artifact) == .artifact)
    }

    @Test func SwiftUIRenderedPanelsStayInTheBaseWindowCapture() {
        for panelType in [
            PanelType.markdown,
            .filePreview,
            .rightSidebarTool,
            .customSidebar,
            .project,
            .workspaceTodo,
            .taskManager,
        ] {
            #expect(TerminalController.workspaceCaptureOverlayRole(for: panelType) == nil)
        }
    }
}
