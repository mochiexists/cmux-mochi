#if canImport(UIKit)
import CMUXMobileCore
import GhosttyKit
import Testing
import UIKit

@testable import CmuxMobileTerminal

// Serialized: every test here shares the process-wide Ghostty runtime, the
// static surface-pointer registry and the key window, so running them
// concurrently lets one test's surface satisfy another's frame assertion.
@Suite("Ghostty runtime actions", .serialized)
struct GhosttyRuntimeActionTests {
    @MainActor
    @Test("renderer continuation actions request another frame")
    func rendererContinuationActionRequestsAnotherFrame() async throws {
        let runtime = try GhosttyRuntime.shared()
        let delegate = RendererContinuationTestDelegate()
        let view = GhosttySurfaceView(runtime: runtime, delegate: delegate)
        let controller = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        controller.view.addSubview(view)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            view.prepareForDismantle()
            window.isHidden = true
        }

        let surface = try #require(view.surface)
        view.needsDraw = false
        #expect(
            GhosttyRuntime.simulateSurfaceActionForTesting(
                surface: surface,
                tag: GHOSTTY_ACTION_RENDER
            )
        )
        for _ in 0..<10 where !view.needsDraw {
            await Task.yield()
        }
        #expect(view.needsDraw)
    }

    // DISABLED (fork): this proof cannot observe what it claims, and its
    // teardown is unsafe. Measured on 2026-09-09:
    //   * `replacementView.needsDraw` goes true with NO stale continuation at
    //     all — mounting the replacement makes it request its own frame — so a
    //     pass here never distinguished "not retargeted" from "not yet drawn".
    //   * The invariant itself holds structurally: the GHOSTTY_ACTION_RENDER
    //     handler captures the bridge and reads `bridge.surfaceView` when the
    //     continuation runs, and `detach()` nils it (observed nil here), so the
    //     registry re-registration this models is not on that path at all.
    //   * Letting the drain run to completion instead of short-circuiting on
    //     the contaminated flag crashes teardown: the test points a live
    //     surface address at a second view, and dismantling both cannot unwind
    //     that safely.
    // Proving "no draw was delivered" needs a delivery counter on the wakeup
    // path, not a shared latch. Re-enable with that, not with more timing.
    @MainActor
    @Test(
        "stale renderer continuations do not follow reused surface addresses",
        .disabled("Contaminated signal and unsafe teardown; needs a wakeup-delivery counter.")
    )
    func staleRendererContinuationDoesNotTargetReplacementView() async throws {
        let runtime = try GhosttyRuntime.shared()
        let delegate = RendererContinuationTestDelegate()
        let sourceView = GhosttySurfaceView(runtime: runtime, delegate: delegate)
        let replacementView = GhosttySurfaceView(runtime: runtime, delegate: delegate)
        let controller = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        controller.view.addSubview(sourceView)
        controller.view.addSubview(replacementView)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            sourceView.prepareForDismantle()
            replacementView.prepareForDismantle()
            window.isHidden = true
        }

        let sourceSurface = try #require(sourceView.surface)
        let bridge = try #require(
            GhosttySurfaceBridge.fromOpaque(ghostty_surface_userdata(sourceSurface))
        )
        replacementView.stopDisplayLink()
        replacementView.needsDraw = false

        #expect(
            GhosttyRuntime.simulateSurfaceActionForTesting(
                surface: sourceSurface,
                tag: GHOSTTY_ACTION_RENDER
            )
        )

        // Model the source surface being detached and its raw address being
        // reused before the queued MainActor continuation gets a turn.
        bridge.detach()
        GhosttySurfaceView.register(surface: sourceSurface, for: replacementView)

        for _ in 0..<10 where !replacementView.needsDraw {
            await Task.yield()
        }
        #expect(!replacementView.needsDraw)
    }
}

@MainActor
private final class RendererContinuationTestDelegate: GhosttySurfaceViewDelegate {
    func ghosttySurfaceView(
        _ surfaceView: GhosttySurfaceView,
        didProduceInput data: Data
    ) {}

    func ghosttySurfaceView(
        _ surfaceView: GhosttySurfaceView,
        didResize size: TerminalGridSize,
        reportID: UInt64
    ) {}
}
#endif
