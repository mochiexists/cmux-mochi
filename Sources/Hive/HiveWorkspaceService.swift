import AppKit
import CmuxHive
import CmuxHiveUI
import CmuxMobileShell
import CmuxMobileShellModel
import SwiftUI

/// App-composition owner for account-free remote Mac workspaces.
@MainActor
final class HiveWorkspaceService {
    private var composition: HiveComposition?
    private let coordinatorOverride: HiveWorkspaceCoordinator?
    private let uiFixtureName: String?
    private let hasKnownPairingAtLaunch: () -> Bool
    private let compositionFactory: (() throws -> HiveComposition)?
    private var startupError: String?
    private var didResolveComposition = false
    private let mirrorController = HiveWorkspaceMirrorController()
    private var browserWindowController: HiveWorkspaceBrowserWindowController?
    private var didStartUIFixture = false
    var coordinator: HiveWorkspaceCoordinator? {
        resolveCompositionIfNeeded()
        return coordinatorOverride ?? composition?.coordinator
    }

    init() {
        let environment = ProcessInfo.processInfo.environment
        #if DEBUG
        if let fixture = HiveWorkspaceUIFixtureShell(environment: environment) {
            composition = nil
            coordinatorOverride = HiveWorkspaceCoordinator(shell: fixture)
            uiFixtureName = fixture.fixtureName
            hasKnownPairingAtLaunch = { true }
            compositionFactory = nil
            startupError = nil
            didResolveComposition = true
            return
        }
        #endif
        composition = nil
        coordinatorOverride = nil
        uiFixtureName = nil
        hasKnownPairingAtLaunch = Self.makeLaunchPairingHint(environment: environment)
        compositionFactory = {
            try Self.makeComposition(environment: environment)
        }
        startupError = nil
    }

    init(composition: HiveComposition) {
        self.composition = composition
        coordinatorOverride = nil
        uiFixtureName = nil
        hasKnownPairingAtLaunch = { true }
        compositionFactory = { composition }
        startupError = nil
        didResolveComposition = true
    }

    init(coordinator: HiveWorkspaceCoordinator) {
        composition = nil
        coordinatorOverride = coordinator
        uiFixtureName = nil
        hasKnownPairingAtLaunch = { true }
        compositionFactory = nil
        startupError = nil
        didResolveComposition = true
    }

    /// Starts the app-lifetime Hive connection owner without opening its window.
    func start() {
        start(forceComposition: false)
    }

    private func start(forceComposition: Bool) {
        #if DEBUG
        if let uiFixtureName {
            guard let coordinator else { return }
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
        guard forceComposition || hasKnownPairingAtLaunch() else { return }
        guard let coordinator else { return }
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
        start(forceComposition: true)
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
              }) else {
            return nil
        }
        let terminal: MobileTerminalPreview
        if let surfaceID {
            guard let matched = workspace.terminals.first(where: {
                $0.id.rawValue == surfaceID
            }) else { return nil }
            terminal = matched
        } else {
            guard let first = workspace.terminals.first else { return nil }
            terminal = first
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

    private func resolveCompositionIfNeeded() {
        guard !didResolveComposition, coordinatorOverride == nil else { return }
        didResolveComposition = true
        guard let compositionFactory else { return }
        do {
            composition = try compositionFactory()
        } catch {
            startupError = String(describing: error)
        }
    }

    private static func makeLaunchPairingHint(
        environment: [String: String]
    ) -> () -> Bool {
        #if DEBUG
        if let rawDirectory = environment["CMUX_E2E_HIVE_STATE_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !rawDirectory.isEmpty {
            let tag = environment["CMUX_TAG"] ?? ""
            return {
                guard let defaults = UserDefaults(suiteName: "dev.cmux.hive-e2e.\(tag)") else {
                    return false
                }
                return MobileShellComposite.hasKnownPairedMac(in: defaults)
            }
        }
        #endif
        return {
            MobileShellComposite.hasKnownPairedMac()
        }
    }

    private static func makeComposition(
        environment: [String: String]
    ) throws -> HiveComposition {
        #if DEBUG
        if let rawDirectory = environment["CMUX_E2E_HIVE_STATE_DIR"]?
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
            let tag = environment["CMUX_TAG"] ?? UUID().uuidString
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
