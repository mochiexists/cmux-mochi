import Foundation
import Network
import os

/// Fork (cmux Mochi): resolves the local network interface that owns this Mac's
/// Tailscale address, so the mobile pairing listener can bind to it exclusively.
///
/// WHY THIS EXISTS, rather than inspecting the peer's address:
///
/// The pairing host previously admitted a connection when the PEER's address fell
/// inside `100.64.0.0/10`. That range is RFC 6598 shared address space, which
/// carriers, hotels and some ISPs also hand out, so it is not evidence of the
/// tailnet — and worse, any check of the peer's address is forgeable by a machine
/// on the same LAN, including an "authoritative" lookup against Tailscale's own
/// peer map (an attacker can simply put a real peer's tailnet IP in the source
/// field of a packet that never touched the tunnel).
///
/// The only unforgeable question is about OUR end: which interface did this
/// connection arrive on? A peer cannot influence that — it is a property of our
/// socket, not of their packet. Binding the listener to the Tailscale `utun`
/// makes off-tailnet connections impossible to accept at all, which removes the
/// admission check rather than trying to make it smarter.
///
/// The interface is identified by the address it owns (via `getifaddrs`), not by
/// name pattern: Tailscale's utun index varies between boots and other VPNs also
/// create utun devices.
final class MobileHostTailnetInterface: Sendable {
    static let shared = MobileHostTailnetInterface()

    private struct State {
        var interfaces: [NWInterface] = []
        var didReceivePath = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dev.cmux.mobile.tailnet-interface")

    private init() {
        monitor.pathUpdateHandler = { [state] path in
            state.withLock { current in
                current.interfaces = path.availableInterfaces
                current.didReceivePath = true
            }
        }
        monitor.start(queue: queue)
    }

    /// The name of the interface holding a Tailscale address, or `nil` when
    /// Tailscale is not up on this Mac.
    ///
    /// Reads the kernel's interface list directly, so it needs neither the
    /// Tailscale daemon nor DNS and cannot be influenced by a remote peer.
    static func tailnetInterfaceName() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let start = head else { return nil }
        defer { freeifaddrs(head) }

        for pointer in sequence(first: start, next: { $0.pointee.ifa_next }) {
            guard let address = pointer.pointee.ifa_addr else { continue }
            let name = String(cString: pointer.pointee.ifa_name)
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                let v4 = UnsafeRawPointer(address)
                    .assumingMemoryBound(to: sockaddr_in.self)
                    .pointee.sin_addr.s_addr
                let octets = withUnsafeBytes(of: v4) { Array($0) }
                // 100.64.0.0/10
                if octets.count == 4, octets[0] == 100, (64...127).contains(octets[1]) {
                    return name
                }
            case AF_INET6:
                let v6 = UnsafeRawPointer(address)
                    .assumingMemoryBound(to: sockaddr_in6.self)
                    .pointee.sin6_addr
                let bytes = withUnsafeBytes(of: v6) { Array($0) }
                // fd7a:115c:a1e0::/48
                if bytes.count == 16,
                   bytes[0] == 0xfd, bytes[1] == 0x7a, bytes[2] == 0x11,
                   bytes[3] == 0x5c, bytes[4] == 0xa1, bytes[5] == 0xe0 {
                    return name
                }
            default:
                continue
            }
        }
        return nil
    }

    /// The `NWInterface` to pin a listener to, or `nil` when Tailscale is down or
    /// the path monitor has not yet reported (in which case the caller must fail
    /// closed rather than bind to every interface).
    func requiredInterface() -> NWInterface? {
        guard let name = Self.tailnetInterfaceName() else { return nil }
        return state.withLock { $0.interfaces }.first { $0.name == name }
    }
}
