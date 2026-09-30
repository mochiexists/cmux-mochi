import AppKit
import CmuxHive
import CmuxHiveUI
import CmuxMobileShell
import SwiftUI

/// App-composition owner for account-free remote Mac workspaces.
@MainActor
final class HiveWorkspaceService {
    private let composition: HiveComposition?
    private let coordinatorOverride: HiveWorkspaceCoordinator?
    private let uiFixtureName: String?
    private let startupError: String?
    private let mirrorController = HiveWorkspaceMirrorController()
    private var browserWindowController: HiveWorkspaceBrowserWindowController?
    private var didStartUIFixture = false
    var coordinator: HiveWorkspaceCoordinator? {
        coordinatorOverride ?? composition?.coordinator
    }

    init() {
        #if DEBUG
        if let fixture = HiveWorkspaceUIFixtureShell() {
            composition = nil
            coordinatorOverride = HiveWorkspaceCoordinator(shell: fixture)
            uiFixtureName = fixture.fixtureName
            startupError = nil
            return
        }
        #endif
        do {
            composition = try Self.makeComposition()
            coordinatorOverride = nil
            uiFixtureName = nil
            startupError = nil
        } catch {
            composition = nil
            coordinatorOverride = nil
            uiFixtureName = nil
            startupError = String(describing: error)
        }
    }

    init(composition: HiveComposition) {
        self.composition = composition
        coordinatorOverride = nil
        uiFixtureName = nil
        startupError = nil
    }

    /// Starts the app-lifetime Hive connection owner without opening its window.
    func start() {
        guard let coordinator else { return }
        #if DEBUG
        if let uiFixtureName {
            guard !didStartUIFixture else { return }
            didStartUIFixture = true
            coordinator.refreshWorkspaceSnapshot(forcePhaseReconciliation: true)
            if uiFixtureName == "pairing" {
                Task {
                    _ = await coordinator.pair(
                        link: HiveWorkspaceUIFixtureShell.pairingLink
                    )
                }
            }
            Task { [weak self] in
                guard let self else { return }
                if let manager = AppDelegate.shared?.activeTabManagerForCommands() {
                    self.presentUIFixture(
                        named: uiFixtureName,
                        coordinator: coordinator,
                        in: manager
                    )
                    return
                }
                let keyWindowChanges = NotificationCenter.default.notifications(
                    named: NSWindow.didBecomeKeyNotification
                )
                for await _ in keyWindowChanges {
                    if let manager = AppDelegate.shared?.activeTabManagerForCommands() {
                        self.presentUIFixture(
                            named: uiFixtureName,
                            coordinator: coordinator,
                            in: manager
                        )
                        return
                    }
                }
            }
            return
        }
        #endif
        Task {
            await coordinator.startConnectionLifecycle()
        }
    }

    #if DEBUG
    private func presentUIFixture(
        named fixtureName: String,
        coordinator: HiveWorkspaceCoordinator,
        in manager: TabManager
    ) {
        if fixtureName.hasPrefix("pane-"),
           let workspace = coordinator.workspaces.first,
           let terminal = workspace.terminals.first {
            _ = mirrorController.open(
                workspace: workspace,
                selectedTerminal: terminal,
                coordinator: coordinator,
                in: manager,
                focus: true
            )
        } else if fixtureName == "workspace-connected-mounted",
                  let workspace = coordinator.workspaces.first,
                  let terminal = workspace.terminals.first {
            _ = mirrorController.open(
                workspace: workspace,
                selectedTerminal: terminal,
                coordinator: coordinator,
                in: manager,
                focus: false
            )
            show(in: manager)
        } else {
            show(in: manager)
        }
    }
    #endif

    func show(in tabManager: TabManager) {
        start()
        guard let coordinator else {
            let alert = NSAlert()
            alert.messageText = String(
                localized: "hive.error.store.title",
                defaultValue: "Remote Macs Unavailable"
            )
            alert.informativeText = startupError ?? String(
                localized: "hive.error.store.description",
                defaultValue: "The local pairing store could not be opened."
            )
            alert.runModal()
            return
        }
        let controller: HiveWorkspaceBrowserWindowController
        if let browserWindowController {
            controller = browserWindowController
        } else {
            controller = HiveWorkspaceBrowserWindowController(
                coordinator: coordinator,
                mirrorController: mirrorController
            )
            browserWindowController = controller
        }
        controller.show(in: tabManager)
    }

    func open(
        workspaceID: String,
        surfaceID: String?,
        in tabManager: TabManager
    ) -> HiveWorkspaceMirrorController.OpenResult? {
        guard let coordinator,
              let workspace = coordinator.workspaces.first(where: {
                  $0.id.rawValue == workspaceID
                      || $0.rpcWorkspaceID.rawValue == workspaceID
              }),
              let terminal = surfaceID.flatMap({ requestedID in
                  workspace.terminals.first { $0.id.rawValue == requestedID }
              }) ?? workspace.terminals.first else {
            return nil
        }
        return mirrorController.open(
            workspace: workspace,
            selectedTerminal: terminal,
            coordinator: coordinator,
            in: tabManager,
            focus: false
        )
    }

    func attachmentStatus() -> [HiveWorkspaceMirrorController.AttachmentStatus] {
        mirrorController.statusSnapshot()
    }

    private static func makeComposition() throws -> HiveComposition {
        #if DEBUG
        if let rawDirectory = ProcessInfo.processInfo.environment["CMUX_E2E_HIVE_STATE_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !rawDirectory.isEmpty {
            let directory = URL(fileURLWithPath: rawDirectory, isDirectory: true)
                .standardizedFileURL
            let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
            guard directory.path != "/", directory != home else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let credentialStore = HiveE2EDeviceLinkCredentialStore()
            let tag = ProcessInfo.processInfo.environment["CMUX_TAG"] ?? UUID().uuidString
            guard let defaults = UserDefaults(suiteName: "dev.cmux.hive-e2e.\(tag)") else {
                throw CocoaError(.fileWriteUnknown)
            }
            let client = MobileDeviceLinkClient(
                identityStore: credentialStore,
                pinStore: credentialStore,
                pairingIndexDefaults: defaults
            )
            return try HiveComposition(
                databaseURL: directory.appendingPathComponent("paired-computers.sqlite3"),
                defaults: defaults,
                deviceLinkClient: client,
                allowsLoopbackRoutes: true
            )
        }
        #endif
        return try HiveComposition(
            allowsLoopbackRoutes: Self.allowsLoopbackRoutes
        )
    }

    private static var allowsLoopbackRoutes: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}

@MainActor
private final class HiveWorkspaceBrowserWindowController: ReleasingWindowController {
    static let windowIdentifier = "cmux.hiveWorkspaceBrowser"

    private let coordinator: HiveWorkspaceCoordinator
    private let mirrorController: HiveWorkspaceMirrorController
    private weak var tabManager: TabManager?

    init(
        coordinator: HiveWorkspaceCoordinator,
        mirrorController: HiveWorkspaceMirrorController
    ) {
        self.coordinator = coordinator
        self.mirrorController = mirrorController
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(in tabManager: TabManager) {
        self.tabManager = tabManager
        showManagedWindow(activateApplication: true)
    }

    override func makeWindow() -> NSWindow {
        let root = HiveWorkspaceBrowserView(
            coordinator: coordinator
        ) { [weak self] workspace, terminal in
            guard let self, let tabManager = self.tabManager else { return }
            self.mirrorController.open(
                workspace: workspace,
                selectedTerminal: terminal,
                coordinator: self.coordinator,
                in: tabManager
            )
        } isTerminalMounted: { [weak mirrorController] workspace, terminal in
            mirrorController?.isMounted(workspace: workspace, terminal: terminal) == true
        }
        let window = NSWindow(
            contentViewController: NSHostingController(rootView: root)
        )
        window.title = String(localized: "hive.title", defaultValue: "Remote Macs")
        window.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 640, height: 560))
        window.contentMinSize = NSSize(width: 520, height: 420)
        window.center()
        return window
    }
}
