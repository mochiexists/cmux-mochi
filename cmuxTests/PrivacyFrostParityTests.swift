import AppKit
import CmuxControlSocket
import CmuxSidebar
import Combine
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Privacy Frost parity", .serialized)
struct PrivacyFrostParityTests {
    @Test func workspaceAndGroupPrivacyRoundTripWithEffectiveInheritance() throws {
        let source = TabManager()
        let groupedChild = try #require(source.tabs.first)
        groupedChild.setCustomTitle("Grouped Secret")
        let directPrivate = source.addWorkspace(select: false)
        directPrivate.setCustomTitle("Direct Secret")
        let groupId = try #require(
            source.createWorkspaceGroup(
                name: "Secret Group",
                childWorkspaceIds: [groupedChild.id],
                selectAnchor: false
            )
        )

        source.setWorkspacePrivacyBlurred([directPrivate.id], isBlurred: true)
        source.setWorkspaceGroupPrivacyBlurred(groupId: groupId, isBlurred: true)

        #expect(directPrivate.isPrivacyBlurred)
        #expect(source.isWorkspaceEffectivelyPrivacyBlurred(groupedChild))
        #expect(!groupedChild.isPrivacyBlurred, "The group owns inherited privacy; members need not duplicate it.")

        let snapshot = source.sessionSnapshot(includeScrollback: false)
        #expect(snapshot.workspaceGroups?.first(where: { $0.id == groupId })?.isPrivacyBlurred == true)
        #expect(snapshot.workspaces.first(where: { $0.workspaceId == directPrivate.id })?.isPrivacyBlurred == true)

        let restored = TabManager()
        _ = restored.restoreSessionSnapshot(snapshot)
        let restoredDirect = try #require(restored.tabs.first(where: { $0.customTitle == "Direct Secret" }))
        let restoredGrouped = try #require(restored.tabs.first(where: { $0.customTitle == "Grouped Secret" }))

        #expect(restoredDirect.isPrivacyBlurred)
        #expect(restored.workspaceGroups.first(where: { $0.id == groupId })?.isPrivacyBlurred == true)
        #expect(restored.isWorkspaceEffectivelyPrivacyBlurred(restoredGrouped))
        #expect(!restored.canSelectWorkspace(restoredDirect))
        #expect(!restored.canSelectWorkspace(restoredGrouped))
    }

    @Test func rowMenuExposesLivePrivacyTargetAndAction() throws {
        let manager = TabManager()
        let workspace = try #require(manager.tabs.first)
        let commands = Self.makeCommands(workspace: workspace, manager: manager)

        let blurMenu = commands.makeContextMenu(onOpen: {}, onClose: {})
        let blurItem = try #require(blurMenu.items.first(where: { $0.title == "Blur Workspace" }))
        #expect(blurItem.target != nil)
        #expect(blurItem.action != nil)
        #expect(NSApp.sendAction(try #require(blurItem.action), to: blurItem.target, from: blurItem))
        #expect(workspace.isPrivacyBlurred)

        let unblurMenu = commands.makeContextMenu(onOpen: {}, onClose: {})
        let unblurItem = try #require(unblurMenu.items.first(where: { $0.title == "Unblur Workspace" }))
        #expect(NSApp.sendAction(try #require(unblurItem.action), to: unblurItem.target, from: unblurItem))
        #expect(!workspace.isPrivacyBlurred)
    }

    @Test func appKitRowRedactsSensitiveContentAcrossTheFullRow() throws {
        let workspace = Workspace()
        let snapshot = Self.makeSnapshot(
            title: "Project Nightingale",
            customDescription: "Customer acquisition plan",
            metadataEntries: [SidebarStatusEntry(key: "secret", value: "prod-token-123")],
            isPrivacyBlurred: true
        )
        let model = Self.makeModel(workspaceId: workspace.id, snapshot: snapshot, isPrivacyBlurred: true)
        let cell = SidebarWorkspaceRowTableCellView()
        cell.frame = NSRect(x: 0, y: 0, width: 320, height: 120)
        cell.configure(
            model: model,
            actions: Self.makeActions(model: model, workspace: workspace),
            isPointerHovering: false,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )
        cell.layoutSubtreeIfNeeded()

#if DEBUG
        #expect(cell.privacyRedactionProbe.isFrostVisible)
        #expect(cell.privacyRedactionProbe.frostCoversRow)
        #expect(cell.privacyRedactionProbe.displayedTitle == "Private Workspace")
#endif
        let visibleText = Self.visibleTextContent(in: cell).joined(separator: "\n")
        #expect(visibleText.contains("Private Workspace"))
        #expect(!visibleText.contains("Project Nightingale"))
        #expect(!visibleText.contains("Customer acquisition plan"))
        #expect(!visibleText.contains("prod-token-123"))
    }

    @Test func privacyMutationSynchronouslyRefreshesSidebarObservationAndSnapshotPolicy() throws {
        let workspace = Workspace()
        var immediatePublishCount = 0
        let cancellable = workspace.sidebarImmediateObservationPublisher.sink {
            immediatePublishCount += 1
        }
        defer { cancellable.cancel() }
        immediatePublishCount = 0

        workspace.isPrivacyBlurred = true
        #expect(immediatePublishCount == 1)

        let current = Self.makeSnapshot(title: "Secret", isPrivacyBlurred: false)
        let next = Self.makeSnapshot(title: "Secret", isPrivacyBlurred: true)
        let decision = SidebarWorkspaceSnapshotRefreshPolicy().decision(
            current: current,
            next: next,
            force: false,
            contextMenuVisible: true
        )
        #expect(decision.workspaceSnapshotStorage?.isPrivacyBlurred == true)
        #expect(decision.pendingWorkspaceSnapshot == nil)
        #expect(!decision.hasDeferredWorkspaceObservationInvalidation)
    }

    @Test func controlFocusRoutesRejectPrivateWorkspacePaneAndSurface() throws {
        let manager = TabManager()
        let visibleWorkspace = try #require(manager.tabs.first)
        let privateWorkspace = manager.addWorkspace(select: false)
        let privatePaneId = try #require(privateWorkspace.bonsplitController.allPaneIds.first?.id)
        let privateSurfaceId = try #require(privateWorkspace.panels.keys.first)
        let socketPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("privacy-frost-\(UUID().uuidString.prefix(8)).sock")
            .path

        TerminalController.shared.stop()
        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .cmuxOnly
        )
        defer { TerminalController.shared.stop() }
        manager.setWorkspacePrivacyBlurred([privateWorkspace.id], isBlurred: true)

        #expect(
            TerminalController.shared.controlSelectWorkspace(
                routing: Self.routing(workspaceID: privateWorkspace.id),
                workspaceID: privateWorkspace.id
            ) == .notFound
        )
        #expect(manager.selectedTabId == visibleWorkspace.id)
        #expect(
            TerminalController.shared.controlPaneFocus(
                routing: Self.routing(workspaceID: privateWorkspace.id),
                paneID: privatePaneId
            ) == .workspaceNotFound
        )
        #expect(
            TerminalController.shared.controlSurfaceFocus(
                routing: Self.routing(workspaceID: privateWorkspace.id),
                surfaceID: privateSurfaceId
            ) == .workspaceNotFound
        )
        #expect(manager.selectedTabId == visibleWorkspace.id)
    }

    private static func routing(
        workspaceID: UUID? = nil,
        surfaceID: UUID? = nil,
        paneID: UUID? = nil
    ) -> ControlRoutingSelectors {
        ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            paneID: paneID
        )
    }

    private static func makeCommands(
        workspace: Workspace,
        manager: TabManager
    ) -> SidebarWorkspaceRowCommands {
        SidebarWorkspaceRowCommands(
            tab: workspace,
            tabManager: manager,
            notificationStore: nil,
            index: manager.tabs.firstIndex(where: { $0.id == workspace.id }) ?? 0,
            contextMenuWorkspaceIds: [workspace.id],
            remoteContextMenuWorkspaceIds: [],
            allRemoteContextMenuTargetsConnecting: false,
            allRemoteContextMenuTargetsDisconnected: false,
            contextMenuPinState: nil,
            workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot(items: []),
            refreshSnapshot: {},
            readSelectedTabIds: { [] },
            writeSelectedTabIds: { _ in },
            readLastSelectionIndex: { nil },
            writeLastSelectionIndex: { _ in },
            setSelectionToTabs: {},
            snapshotProvider: { nil }
        )
    }

    private static func makeSnapshot(
        title: String,
        customDescription: String? = nil,
        metadataEntries: [SidebarStatusEntry] = [],
        isPrivacyBlurred: Bool
    ) -> SidebarWorkspaceSnapshotBuilder.Snapshot {
        let defaults = UserDefaults(suiteName: "PrivacyFrostParityTests.\(UUID().uuidString)")!
        return SidebarWorkspaceSnapshotBuilder.Snapshot(
            presentationKey: SidebarWorkspaceSnapshotFactory.presentationKey(
                settings: SidebarTabItemSettingsSnapshot(defaults: defaults),
                showsAgentActivity: false
            ),
            title: title,
            customDescription: customDescription,
            isPinned: false,
            isPrivacyBlurred: isPrivacyBlurred,
            customColorHex: nil,
            remoteWorkspaceSidebarText: nil,
            remoteConnectionStatusText: "",
            remoteStateHelpText: "",
            showsRemoteReconnectAffordance: false,
            copyableSidebarSSHError: nil,
            latestConversationMessage: nil,
            metadataEntries: metadataEntries,
            metadataBlocks: [],
            latestLog: nil,
            progress: nil,
            activeCodingAgentCount: 0,
            compactGitBranchSummaryText: nil,
            compactDirectoryCandidates: [],
            compactBranchDirectoryCandidates: [],
            branchDirectoryLines: [],
            branchLinesContainBranch: false,
            pullRequestRows: [],
            listeningPorts: [],
            finderDirectoryPath: nil,
            mediaActivity: BrowserMediaActivity(),
            taskStatus: nil,
            todoStatusMenuModel: nil,
            hasManualTaskStatus: false,
            checklistItems: [],
            checklistCompletedCount: 0,
            checklistTotalCount: 0,
            checklistFirstUncheckedText: nil
        )
    }

    private static func makeModel(
        workspaceId: UUID,
        snapshot: SidebarWorkspaceSnapshotBuilder.Snapshot,
        isPrivacyBlurred: Bool
    ) -> SidebarWorkspaceRowModel {
        let defaults = UserDefaults(suiteName: "PrivacyFrostParityTests.\(UUID().uuidString)")!
        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)
        return SidebarWorkspaceRowModel(
            workspaceId: workspaceId,
            index: 0,
            snapshot: snapshot,
            settings: settings,
            isPrivacyBlurred: isPrivacyBlurred,
            isActive: false,
            isMultiSelected: false,
            canCloseWorkspace: true,
            accessibilityWorkspaceCount: 1,
            unreadCount: 1,
            latestNotificationText: "Customer acquisition plan",
            showsAgentActivity: false,
            rowSpacing: 8,
            isBeingDragged: false,
            topDropIndicatorVisible: false,
            bottomDropIndicatorVisible: false,
            isGrouped: false,
            isFirstRow: true,
            shortcutHintText: nil,
            showsShortcutHints: false,
            colorSchemeIsDark: true,
            globalFontMagnificationPercent: 100,
            isChecklistExpanded: false,
            checklistAddFieldActivationToken: 0,
            isChecklistPopoverPresented: false,
            editingChecklistItemId: nil,
            todoControlsEnabled: false,
            isMetadataExpanded: true,
            isMarkdownExpanded: true
        )
    }

    private static func makeActions(
        model: SidebarWorkspaceRowModel,
        workspace: Workspace
    ) -> SidebarAppKitRowActions {
        SidebarAppKitRowActions(
            commands: makeCommands(workspace: workspace, manager: TabManager()),
            onOpenStatusURL: { _ in },
            onOpenPullRequest: { _ in },
            onOpenPort: { _ in },
            onToggleChecklistExpansion: {},
            onToggleMetadataExpansion: {},
            onToggleMarkdownExpansion: {},
            onConsumeChecklistAddFieldActivation: {},
            checklistSetItemState: { _, _ in },
            checklistRemoveItem: { _ in },
            checklistAddItem: { _ in },
            checklistEditItem: { _, _ in },
            checklistMoveItem: { _, _ in },
            checklistOpenPane: {},
            checklistAddAttachments: { _ in },
            checklistRemoveAttachment: { _, _ in },
            checklistOpenAttachments: { _, _ in },
            onChecklistPopoverPresentedChange: { _ in },
            onBeginChecklistItemEdit: { _ in },
            onEndChecklistItemEdit: { _ in },
            applyTodoStatus: { _ in },
            hideTodoStatus: {},
            commitRename: { _ in }
        )
    }

    private static func visibleTextContent(in root: NSView) -> [String] {
        func collect(_ view: NSView, ancestorsVisible: Bool) -> [String] {
            let isVisible = ancestorsVisible && !view.isHidden
            guard isVisible else { return [] }
            var values: [String] = []
            if let textField = view as? NSTextField, !textField.stringValue.isEmpty {
                values.append(textField.stringValue)
            } else if let textView = view as? NSTextView, !textView.string.isEmpty {
                values.append(textView.string)
            } else if let button = view as? NSButton, !button.title.isEmpty {
                values.append(button.title)
            }
            return values + view.subviews.flatMap { collect($0, ancestorsVisible: isVisible) }
        }
        return collect(root, ancestorsVisible: true)
    }
}
