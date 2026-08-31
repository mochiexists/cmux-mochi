import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileSupport
import Foundation
import Observation
import OSLog

public struct CMUXMobileRuntime: Sendable, MobileSyncRuntime {
    public static let defaultRPCRequestTimeoutNanoseconds: UInt64 = 30 * 1_000_000_000
    public static let defaultPairingRequestTimeoutNanoseconds: UInt64 = 8 * 1_000_000_000
    public static let defaultPairingAttemptTimeoutNanoseconds: UInt64 = 8 * 1_000_000_000

    public var supportedRouteKinds: [CmxAttachTransportKind]
    public var transportFactory: any CmxByteTransportFactory
    public var rpcRequestTimeoutNanoseconds: UInt64
    public var pairingRequestTimeoutNanoseconds: UInt64
    public var pairingAttemptTimeoutNanoseconds: UInt64
    public var now: @Sendable () -> Date
    /// When false, `MobileShellStore` skips background terminal refresh.
    /// Scripted transport tests set this off so background subscribe/poll
    /// requests don't consume responses intended for foreground methods.
    /// Production sets it on (the default), and falls back to the legacy
    /// 750ms poll only when a connected Mac does not support events.
    public var supportsServerPushEvents: Bool
    public var independentEventByteStreamProvider: CmxIndependentEventByteStreamProvider?
    public var terminalLaneProvider: MobileTerminalLaneProvider?
    public var artifactLaneProvider: MobileArtifactLaneProvider?

    public init(
        supportedRouteKinds: [CmxAttachTransportKind] = [.tailscale, .debugLoopback],
        transportFactory: any CmxByteTransportFactory,
        rpcRequestTimeoutNanoseconds: UInt64 = CMUXMobileRuntime.defaultRPCRequestTimeoutNanoseconds,
        pairingRequestTimeoutNanoseconds: UInt64 = CMUXMobileRuntime.defaultPairingRequestTimeoutNanoseconds,
        pairingAttemptTimeoutNanoseconds: UInt64 = CMUXMobileRuntime.defaultPairingAttemptTimeoutNanoseconds,
        now: @escaping @Sendable () -> Date = Date.init,
        supportsServerPushEvents: Bool = true,
        independentEventByteStreamProvider: CmxIndependentEventByteStreamProvider? = nil,
        terminalLaneProvider: MobileTerminalLaneProvider? = nil,
        artifactLaneProvider: MobileArtifactLaneProvider? = nil
    ) {
        self.supportedRouteKinds = supportedRouteKinds
        self.transportFactory = transportFactory
        self.rpcRequestTimeoutNanoseconds = rpcRequestTimeoutNanoseconds
        self.pairingRequestTimeoutNanoseconds = pairingRequestTimeoutNanoseconds
        self.pairingAttemptTimeoutNanoseconds = pairingAttemptTimeoutNanoseconds
        self.now = now
        self.supportsServerPushEvents = supportsServerPushEvents
        self.independentEventByteStreamProvider = independentEventByteStreamProvider
        self.terminalLaneProvider = terminalLaneProvider
        self.artifactLaneProvider = artifactLaneProvider
    }

    public init(
        transportFactory: any CmxRouteAwareByteTransportFactory,
        rpcRequestTimeoutNanoseconds: UInt64 = CMUXMobileRuntime.defaultRPCRequestTimeoutNanoseconds,
        pairingRequestTimeoutNanoseconds: UInt64 = CMUXMobileRuntime.defaultPairingRequestTimeoutNanoseconds,
        pairingAttemptTimeoutNanoseconds: UInt64 = CMUXMobileRuntime.defaultPairingAttemptTimeoutNanoseconds,
        now: @escaping @Sendable () -> Date = Date.init,
        supportsServerPushEvents: Bool = true,
        independentEventByteStreamProvider: CmxIndependentEventByteStreamProvider? = nil,
        terminalLaneProvider: MobileTerminalLaneProvider? = nil,
        artifactLaneProvider: MobileArtifactLaneProvider? = nil
    ) {
        self.supportedRouteKinds = transportFactory.supportedKinds
        self.transportFactory = transportFactory
        self.rpcRequestTimeoutNanoseconds = rpcRequestTimeoutNanoseconds
        self.pairingRequestTimeoutNanoseconds = pairingRequestTimeoutNanoseconds
        self.pairingAttemptTimeoutNanoseconds = pairingAttemptTimeoutNanoseconds
        self.supportsServerPushEvents = supportsServerPushEvents
        self.independentEventByteStreamProvider = independentEventByteStreamProvider
        self.terminalLaneProvider = terminalLaneProvider
        self.artifactLaneProvider = artifactLaneProvider
        self.now = now
    }
}
