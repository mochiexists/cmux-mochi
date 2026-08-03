import Foundation

/// A point-in-time view of the Mac-side iOS pairing host, shown in the Mobile
/// settings section.
///
/// The configured port is only a *preference*: if it is already in use the
/// listener binds an OS-assigned ephemeral port instead, and the iOS app is
/// handed the actual ``boundPort``. The settings UI uses this snapshot to show
/// the real bound port and warn when it differs from ``configuredPort`` so a
/// configured port can never silently fail to take effect.
///
/// The host supplies the snapshot through
/// ``SettingsHostActions/mobilePairingStatus()`` and pushes updates through
/// ``SettingsHostActions/mobilePairingStatusUpdates()``. The settings package
/// stays Foundation-only; the host maps its own runtime types into this value.
public struct MobilePairingStatusSnapshot: Sendable, Equatable {
    /// Whether the pairing listener is currently bound and accepting iOS
    /// connections.
    public let isRunning: Bool

    /// The preferred port from settings the listener tried to bind.
    public let configuredPort: Int

    /// The port the listener actually bound, or `nil` when it is not running.
    public let boundPort: Int?

    /// Why the listener is not running, when it is not.
    ///
    /// Replaces an `usesEphemeralFallback` flag: the listener no longer moves to
    /// another port when the configured one is taken, so "which port did we land
    /// on instead" is not a question that can arise. What the user needs instead
    /// is the reason it refused to start.
    public let lastErrorDescription: String?

    /// Number of iOS devices currently connected.
    public let activeConnectionCount: Int

    /// The addresses the iOS app can use to reach this Mac.
    public let routes: [MobilePairingRoute]

    /// Creates a pairing-status snapshot.
    ///
    /// - Parameters:
    ///   - isRunning: Whether the listener is bound.
    ///   - configuredPort: The preferred port from settings.
    ///   - boundPort: The port actually bound, or `nil` when not running.
    ///   - lastErrorDescription: Why the listener is not running, if it is not.
    ///   - activeConnectionCount: Number of connected iOS devices.
    ///   - routes: Addresses the iOS app can use to reach this Mac.
    public init(
        isRunning: Bool,
        configuredPort: Int,
        boundPort: Int?,
        lastErrorDescription: String?,
        activeConnectionCount: Int,
        routes: [MobilePairingRoute]
    ) {
        self.isRunning = isRunning
        self.configuredPort = configuredPort
        self.boundPort = boundPort
        self.lastErrorDescription = lastErrorDescription
        self.activeConnectionCount = activeConnectionCount
        self.routes = routes
    }
}
