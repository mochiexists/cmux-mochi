import AppKit
import Foundation

/// Keeps a sidebar drag's completion path alive while AppKit materialises its
/// native drag session.
///
/// `NSTableView` asks for a pasteboard writer BEFORE it creates the native
/// session, and it retains that writer until the session finishes. SwiftUI can
/// dismantle the representable inside that interval, and
/// ``SidebarWorkspaceTableController/dismantleContainerView(_:)`` clears the
/// table's delegate and drops its actions. AppKit then has nobody to deliver
/// `draggingSession(_:endedAt:operation:)` to, so the drag is never ended
/// app-side, the Dock still considers a drag active, and Mission Control,
/// Spaces and swipe gestures stay dead until `killall Dock`.
///
/// Retaining the source view, the controller and the actions FROM THE WRITER
/// closes that gap: whoever tears the table down, AppKit still holds this
/// object for the session's lifetime, so the completion path survives. The
/// controller keeps ownership of terminal cleanup via its `endedAt` callback;
/// this type only guarantees the callback still has something to reach.
///
/// Upstream fixed the same class of bug in manaflow-ai/cmux#11186. That fix
/// rides on a drag-ownership subsystem this fork does not carry, so this is
/// the same lesson applied to our own table controller rather than a backport.
@MainActor
final class SidebarWorkspaceDragPasteboardWriter: NSPasteboardItem {
    /// Identifies this writer's drag so a late callback from a superseded
    /// session can never finish a newer one on the same controller.
    let tokenID = UUID()
    let workspaceId: UUID

    // Intentionally strong. AppKit retains the writer while it builds and then
    // runs the native session, so the source table, its controller and the
    // actions cannot disappear between the writer request and `endedAt`.
    private var sourceView: NSView?
    private var controller: SidebarWorkspaceTableController?
    private var actions: SidebarWorkspaceTableActions?

    init(
        workspaceId: UUID,
        sourceView: NSView,
        controller: SidebarWorkspaceTableController,
        actions: SidebarWorkspaceTableActions
    ) {
        self.workspaceId = workspaceId
        self.sourceView = sourceView
        self.controller = controller
        self.actions = actions
        super.init()
        setString(
            "\(SidebarTabDragPayload.prefix)\(workspaceId.uuidString)",
            forType: NSPasteboard.PasteboardType(SidebarTabDragPayload.typeIdentifier)
        )
    }

    @available(*, unavailable)
    required init(pasteboardPropertyList _: Any, ofType _: NSPasteboard.PasteboardType) {
        fatalError("init(pasteboardPropertyList:ofType:) is not supported")
    }

    /// The actions that must still end the drag, even if the table that
    /// created them has since been dismantled.
    var retainedActions: SidebarWorkspaceTableActions? { actions }

    /// Whether this writer is still holding a completion path open.
    var isRetainingSource: Bool { controller != nil }

    /// Drops the retained graph once AppKit has finished with the session.
    /// Safe to call more than once.
    func releaseRetainedSource() {
        sourceView = nil
        controller = nil
        actions = nil
    }
}
