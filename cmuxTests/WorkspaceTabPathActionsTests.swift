import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Workspace tab path actions")
struct WorkspaceTabPathActionsTests {
    @Test func fileBackedPanelPathWinsAndSupportsFileActions() throws {
        let target = try #require(Workspace.tabPathActionTarget(
            filePath: " /tmp/artifact.tsx ",
            browserURL: URL(fileURLWithPath: "/tmp/browser.html"),
            directory: "/tmp/project"
        ))

        #expect(target.path == "/tmp/artifact.tsx")
        #expect(target.isFile)
    }

    @Test func fileBrowserURLSupportsFileActions() throws {
        let target = try #require(Workspace.tabPathActionTarget(
            filePath: nil,
            browserURL: URL(fileURLWithPath: "/tmp/report.pdf"),
            directory: "/tmp/project"
        ))

        #expect(target.path == "/tmp/report.pdf")
        #expect(target.isFile)
    }

    @Test func ordinaryBrowserFallsBackToPanelDirectory() throws {
        let target = try #require(Workspace.tabPathActionTarget(
            filePath: nil,
            browserURL: URL(string: "https://example.com"),
            directory: " /tmp/project "
        ))

        #expect(target.path == "/tmp/project")
        #expect(!target.isFile)
    }

    @Test func blankInputsExposeNoPathActions() {
        #expect(Workspace.tabPathActionTarget(
            filePath: "  ",
            browserURL: nil,
            directory: "\n"
        ) == nil)
    }
}
