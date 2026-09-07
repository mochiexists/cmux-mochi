public import CMUXMobileCore
public import CmuxMobileRPC
import CmuxMobileTransport
public import Foundation
public import Network

/// Transport configuration for macOS Hive connections.
///
/// Network routes are admitted only when the caller can resolve DeviceLink TLS
/// options for the immutable device-id and instance-tag carried by each request.
public struct HiveMobileRuntime: MobileSyncRuntime, Sendable {
    public static let defaultRPCRequestTimeoutNanoseconds: UInt64 = 30_000_000_000
    public static let defaultPairingRequestTimeoutNanoseconds: UInt64 = 8_000_000_000

    public var supportedRouteKinds: [CmxAttachTransportKind]
    public var transportFactory: any CmxByteTransportFactory
    public var rpcRequestTimeoutNanoseconds: UInt64
    public var pairingRequestTimeoutNanoseconds: UInt64
    public var pairingAttemptTimeoutNanoseconds: UInt64
    public var now: @Sendable () -> Date
    public var supportsServerPushEvents: Bool

    public init(
        supportedRouteKinds: [CmxAttachTransportKind],
        transportFactory: any CmxByteTransportFactory,
        rpcRequestTimeoutNanoseconds: UInt64 = Self.defaultRPCRequestTimeoutNanoseconds,
        pairingRequestTimeoutNanoseconds: UInt64 = Self.defaultPairingRequestTimeoutNanoseconds,
        pairingAttemptTimeoutNanoseconds: UInt64 = Self.defaultPairingRequestTimeoutNanoseconds,
        now: @escaping @Sendable () -> Date = Date.init,
        supportsServerPushEvents: Bool = true
    ) {
        self.supportedRouteKinds = supportedRouteKinds
        self.transportFactory = transportFactory
        self.rpcRequestTimeoutNanoseconds = rpcRequestTimeoutNanoseconds
        self.pairingRequestTimeoutNanoseconds = pairingRequestTimeoutNanoseconds
        self.pairingAttemptTimeoutNanoseconds = pairingAttemptTimeoutNanoseconds
        self.now = now
        self.supportsServerPushEvents = supportsServerPushEvents
    }

    /// Build the production LAN/Tailscale factory with exact DeviceLink lookup.
    public static func network(
        allowsLoopbackRoutes: Bool = false,
        deviceLinkTLSOptions: @escaping @Sendable (
            CmxByteTransportRequest
        ) -> NWProtocolTLS.Options?
    ) -> HiveMobileRuntime {
        var supportedKinds: [CmxAttachTransportKind] = [
            .localNetwork,
            .tailscale,
        ]
        if allowsLoopbackRoutes {
            supportedKinds.insert(.debugLoopback, at: 0)
        }
        let factory = CmxNetworkByteTransportFactory(
            supportedKinds: supportedKinds,
            deviceLinkTLSOptions: deviceLinkTLSOptions
        )
        return HiveMobileRuntime(
            supportedRouteKinds: supportedKinds,
            transportFactory: factory
        )
    }
}
