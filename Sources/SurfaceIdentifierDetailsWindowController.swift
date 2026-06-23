import AppKit
import SwiftUI

@MainActor
final class SurfaceIdentifierDetailsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SurfaceIdentifierDetailsWindowController()

    private init() {
        let hostingController = NSHostingController(
            rootView: WorkspaceSurfaceIdentifierDetailsView(
                details: WorkspaceSurfaceIdentifierDetails(rows: []),
                onClose: {}
            )
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = String(localized: "identifierDetails.title", defaultValue: "Surface IDs")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.contentViewController = hostingController
        super.init(window: panel)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(details: WorkspaceSurfaceIdentifierDetails, relativeTo hostWindow: NSWindow? = nil) {
        guard let panel = window else { return }
        panel.contentViewController = NSHostingController(
            rootView: WorkspaceSurfaceIdentifierDetailsView(details: details) { [weak self] in
                self?.close()
            }
        )
        let hostWindow = hostWindow ?? NSApp.keyWindow
        if let hostWindow {
            panel.center(relativeTo: hostWindow)
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private extension NSWindow {
    func center(relativeTo hostWindow: NSWindow) {
        let hostFrame = hostWindow.frame
        setFrameOrigin(
            NSPoint(
                x: hostFrame.midX - frame.width / 2,
                y: hostFrame.midY - frame.height / 2
            )
        )
    }
}
