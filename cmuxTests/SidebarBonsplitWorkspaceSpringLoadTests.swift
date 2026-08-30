import AppKit
import CmuxFoundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Spring-load is what makes a cross-workspace session drag legible: hovering a
/// workspace row switches the main UI to that workspace mid-drag, so the pane
/// layout you are about to drop into is the one on screen. It regressed once by
/// being dropped in a trunk port, so the behaviour is pinned here.
@Suite struct SidebarBonsplitWorkspaceSpringLoadTests {
    private final class MockDraggingInfo: NSObject, NSDraggingInfo {
        let draggingDestinationWindow: NSWindow?
        let draggingSourceOperationMask: NSDragOperation
        let draggingLocation: NSPoint
        let draggedImageLocation: NSPoint
        let draggedImage: NSImage?
        // NSPasteboard is AppKit-managed and read only by the main-actor drop view in these tests.
        nonisolated(unsafe) let draggingPasteboard: NSPasteboard
        // NSDraggingInfo exposes an untyped AppKit source object; tests never mutate it.
        nonisolated(unsafe) let draggingSource: Any?
        let draggingSequenceNumber: Int
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        let springLoadingHighlight: NSSpringLoadingHighlight = .none

        init(window: NSWindow, location: NSPoint, pasteboard: NSPasteboard) {
            self.draggingDestinationWindow = window
            self.draggingSourceOperationMask = .move
            self.draggingLocation = location
            self.draggedImageLocation = location
            self.draggedImage = nil
            self.draggingPasteboard = pasteboard
            self.draggingSource = nil
            self.draggingSequenceNumber = 1
        }

        func slideDraggedImage(to screenPoint: NSPoint) {}

        override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? {
            nil
        }

        func enumerateDraggingItems(
            options enumOpts: NSDraggingItemEnumerationOptions = [],
            for view: NSView?,
            classes classArray: [AnyClass],
            searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
            using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
        ) {}

        func resetSpringLoading() {}
    }

    /// A drop view hosted in a window, wired to spring-load into `targets`.
    @MainActor
    private struct Harness {
        let view: SidebarBonsplitTabWorkspaceDropView
        let window: NSWindow
        let pasteboard: NSPasteboard
        let sprung: Recorder
        let highlighted: Recorder

        final class Recorder {
            private(set) var workspaceIds: [UUID] = []
            func record(_ id: UUID) { workspaceIds.append(id) }
        }

        /// Sends a drag update over the vertical centre of `target`'s row.
        func hover(_ target: SidebarDropPlanner.WorkspaceDropTarget, entering: Bool = false) {
            let centre = CGPoint(x: target.frame.midX, y: target.frame.midY)
            let sender = MockDraggingInfo(
                window: window,
                location: view.convert(centre, to: nil),
                pasteboard: pasteboard
            )
            _ = entering ? view.draggingEntered(sender) : view.draggingUpdated(sender)
        }
    }

    /// Row height is comfortably above the planner's 25% edge bands, so a hover
    /// at the row centre resolves to `.existingWorkspace` rather than an insertion.
    private static let rowHeight: CGFloat = 40

    @MainActor
    private static func makeHarness(targets: [SidebarDropPlanner.WorkspaceDropTarget]) throws -> Harness {
        let frame = NSRect(x: 0, y: 0, width: 240, height: rowHeight * CGFloat(targets.count + 1))
        let view = SidebarBonsplitTabWorkspaceDropView(frame: frame)
        let window = NSWindow(contentRect: frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.test.springload.\(UUID().uuidString)"))
        pasteboard.clearContents()
        let payload: [String: Any] = [
            "tab": ["id": UUID().uuidString],
            "sourcePaneId": UUID().uuidString,
            "sourceProcessId": Int(ProcessInfo.processInfo.processIdentifier)
        ]
        pasteboard.setData(
            try JSONSerialization.data(withJSONObject: payload),
            forType: NSPasteboard.PasteboardType(BonsplitTabDragPayload.typeIdentifier)
        )

        let bridge = SidebarBonsplitTabWorkspaceDropOverlay.TargetBridge()
        bridge.updateTargets(targets)
        view.targetBridge = bridge
        view.canPerformAction = { _, _ in true }

        let sprung = Harness.Recorder()
        view.springLoadWorkspace = { sprung.record($0) }

        let highlighted = Harness.Recorder()
        view.setExistingWorkspaceDropTarget = { highlighted.record($0) }

        return Harness(
            view: view,
            window: window,
            pasteboard: pasteboard,
            sprung: sprung,
            highlighted: highlighted
        )
    }

    private static func target(index: Int) -> SidebarDropPlanner.WorkspaceDropTarget {
        SidebarDropPlanner.WorkspaceDropTarget(
            workspaceId: UUID(),
            isPinned: false,
            frame: CGRect(x: 0, y: rowHeight * CGFloat(index), width: 240, height: rowHeight)
        )
    }

    @Test @MainActor
    func hoveringAWorkspaceRowSpringLoadsThatWorkspace() throws {
        let first = Self.target(index: 0)
        let harness = try Self.makeHarness(targets: [first, Self.target(index: 1)])

        harness.hover(first, entering: true)

        #expect(harness.sprung.workspaceIds == [first.workspaceId])
        #expect(harness.highlighted.workspaceIds == [first.workspaceId])
    }

    @Test @MainActor
    func repeatedUpdatesOverTheSameRowSpringLoadOnlyOnce() throws {
        let first = Self.target(index: 0)
        let harness = try Self.makeHarness(targets: [first, Self.target(index: 1)])

        harness.hover(first, entering: true)
        harness.hover(first)
        harness.hover(first)

        #expect(
            harness.sprung.workspaceIds == [first.workspaceId],
            "Every drag tick over one row must not re-switch the workspace"
        )
    }

    @Test @MainActor
    func movingToAnotherRowSpringLoadsTheNewWorkspace() throws {
        let first = Self.target(index: 0)
        let second = Self.target(index: 1)
        let harness = try Self.makeHarness(targets: [first, second])

        harness.hover(first, entering: true)
        harness.hover(second)

        #expect(harness.sprung.workspaceIds == [first.workspaceId, second.workspaceId])
        #expect(harness.highlighted.workspaceIds == [first.workspaceId, second.workspaceId])
    }

    @Test @MainActor
    func leavingAndReenteringTheSameRowSpringLoadsAgain() throws {
        let first = Self.target(index: 0)
        let harness = try Self.makeHarness(targets: [first, Self.target(index: 1)])

        harness.hover(first, entering: true)
        harness.view.draggingExited(nil)
        harness.hover(first, entering: true)

        #expect(
            harness.sprung.workspaceIds == [first.workspaceId, first.workspaceId],
            "Stale spring state must not suppress the switch on a fresh drag"
        )
        #expect(harness.highlighted.workspaceIds == [first.workspaceId, first.workspaceId])
    }
}
