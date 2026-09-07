import AppKit
import CmuxHive
import CmuxHiveUI
import SwiftUI

/// App-composition owner for account-free remote Mac workspaces.
@MainActor
final class HiveWorkspaceService {
    private let composition: HiveComposition?
    private let startupError: String?
    private let mirrorController = HiveWorkspaceMirrorController()
    private var browserWindowController: HiveWorkspaceBrowserWindowController?

    init() {
        do {
            composition = try HiveComposition(
                allowsLoopbackRoutes: Self.allowsLoopbackRoutes
            )
            startupError = nil
        } catch {
            composition = nil
            startupError = String(describing: error)
        }
    }

    func show(in tabManager: TabManager) {
        guard let composition else {
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
                coordinator: composition.coordinator,
                mirrorController: mirrorController
            )
            browserWindowController = controller
        }
        controller.show(in: tabManager)
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
