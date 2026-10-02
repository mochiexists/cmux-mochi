public import CmuxTerminalCore
public import GhosttyKit

/// The injected collaborators a ``TerminalSurface`` needs to run.
///
/// Constructed once at the composition root (today the transitional
/// `GhosttyApp` statics; later the app's composition root proper) and passed
/// to every `TerminalSurface` initializer. The bundle replaces the god-file
/// reach-ups into `GhosttyApp.shared`, `TerminalController.shared`,
/// `MobileTerminalByteTee.shared`, `RendererRealizationController.shared`,
/// and `AgentHibernationController.shared`.
public struct TerminalSurfaceRuntimeDependencies {
    /// The process-wide surface registry.
    public let registry: any TerminalSurfaceRegistering

    /// The embedded Ghostty engine owner.
    public let engine: any TerminalEngineHosting

    /// The factory for the surface's native view pair.
    public let viewProvider: any TerminalSurfaceViewProviding

    /// Live settings reads folded into spawn environments.
    public let spawnPolicy: any TerminalSurfaceSpawnPolicyProviding

    /// The shared PTY output-tee installer.
    public let byteTee: any TerminalByteTeeBinding

    /// The renderer-reclamation pass scheduler.
    public let rendererRealization: any TerminalRendererRealizationScheduling

    /// The agent-hibernation input recorder.
    public let hibernationRecorder: any AgentHibernationRecording

    /// The serialized native-surface free queue.
    public let runtimeTeardown: TerminalSurfaceRuntimeTeardownCoordinator

    /// Releases one native Ghostty surface on the teardown coordinator.
    public let runtimeSurfaceDeallocator: @Sendable (ghostty_surface_t) -> Void

    /// The paced native-surface creation queue for restored terminal sessions.
    public let restoreSpawnScheduler: any TerminalSurfaceRuntimeSpawnScheduling

    /// Filesystem probes and writers used by runtime creation.
    public let runtimeFilesystem: TerminalSurfaceRuntimeFilesystem

    /// The first port of the per-session `CMUX_PORT` allocation
    /// (snapshotted once per app session by the composition root).
    public let sessionPortBase: Int

    /// The per-workspace port range size (snapshotted once per app session
    /// by the composition root).
    public let sessionPortRangeSize: Int

    /// The environment key carrying one-shot session scrollback replay; the
    /// surface strips it after the first runtime spawn.
    public let scrollbackReplayEnvironmentKey: String

    /// Provides the app's current global font magnification percent.
    public let globalFontMagnificationPercent: @Sendable () -> Int

    /// Creates the dependency bundle.
    ///
    /// - Parameter runtimeSurfaceDeallocator: Releases one native surface.
    ///   The teardown coordinator retains this closure until it executes the
    ///   corresponding asynchronous teardown request.
    public init(
        registry: any TerminalSurfaceRegistering,
        engine: any TerminalEngineHosting,
        viewProvider: any TerminalSurfaceViewProviding,
        spawnPolicy: any TerminalSurfaceSpawnPolicyProviding,
        byteTee: any TerminalByteTeeBinding,
        rendererRealization: any TerminalRendererRealizationScheduling,
        hibernationRecorder: any AgentHibernationRecording,
        runtimeTeardown: TerminalSurfaceRuntimeTeardownCoordinator,
        runtimeSurfaceDeallocator: @escaping @Sendable (ghostty_surface_t) -> Void = {
            ghostty_surface_free($0)
        },
        restoreSpawnScheduler: any TerminalSurfaceRuntimeSpawnScheduling,
        runtimeFilesystem: TerminalSurfaceRuntimeFilesystem,
        sessionPortBase: Int,
        sessionPortRangeSize: Int,
        scrollbackReplayEnvironmentKey: String,
        globalFontMagnificationPercent: @escaping @Sendable () -> Int = { 100 }
    ) {
        self.registry = registry
        self.engine = engine
        self.viewProvider = viewProvider
        self.spawnPolicy = spawnPolicy
        self.byteTee = byteTee
        self.rendererRealization = rendererRealization
        self.hibernationRecorder = hibernationRecorder
        self.runtimeTeardown = runtimeTeardown
        self.runtimeSurfaceDeallocator = runtimeSurfaceDeallocator
        self.restoreSpawnScheduler = restoreSpawnScheduler
        self.runtimeFilesystem = runtimeFilesystem
        self.sessionPortBase = sessionPortBase
        self.sessionPortRangeSize = sessionPortRangeSize
        self.scrollbackReplayEnvironmentKey = scrollbackReplayEnvironmentKey
        self.globalFontMagnificationPercent = globalFontMagnificationPercent
    }
}
