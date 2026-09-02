import Foundation
@preconcurrency import Network
import SystemConfiguration

/// Watches the system network path for the mobile pairing host and reports
/// deduplicated path changes on the main actor.
///
/// When the Mac moves networks or Tailscale flips, the advertised route set
/// changes and the wildcard pairing listener may retain a defunct socket even
/// while Network.framework still reports it as ready. ``MobileHostService``
/// owns the listener rebind and route republish; this type owns the observation:
/// one `NWPathMonitor`, a path signature for duplicate suppression, and nothing
/// else.
///
/// Every observation that differs from the previous one fires `onPathChange`,
/// *including the first*: the initial callback can arrive after the
/// listener-ready route publish and describe a different path than those
/// routes were computed on (e.g. Tailscale came up in between), so treating
/// it as a silent baseline would swallow that first real change. Republishing
/// is cheap because downstream consumers dedup unchanged routes; only an
/// observation identical to the previous one is skipped (`NWPathMonitor` can
/// deliver duplicate callbacks).
///
/// The signature includes the local IPv4 addresses (from `getifaddrs`) on top
/// of `NWPath`'s status/interfaces/gateways: two networks can present the same
/// interface name and gateway address (two home LANs both using `en0` and
/// `192.168.1.1`) while assigning a different local address, and the advertised
/// routes are built from the local addresses. IPv6 is deliberately excluded:
/// RFC 4941 temporary addresses rotate while the path is otherwise unchanged,
/// which would turn rotation churn into spurious republishes, and an IPv6
/// renumbering that matters for routes accompanies an interface/gateway/IPv4
/// change in practice.
@MainActor
final class MobileHostNetworkPathMonitor {
    private let monitor = NWPathMonitor()
    /// Signature of the last observed path, for duplicate suppression.
    private var lastSignature: String?
    private let onPathChange: @MainActor (_ isInitialObservation: Bool) -> Void
    /// Returns the machine's local IPv4 addresses; injectable for tests.
    /// Called on the monitor queue, off-main.
    private let localIPv4Addresses: @Sendable () -> [String]

    init(
        onPathChange: @escaping @MainActor (_ isInitialObservation: Bool) -> Void,
        localIPv4Addresses: @escaping @Sendable () -> [String] = {
            MobileHostNetworkPathMonitor.systemLocalIPv4Addresses()
        }
    ) {
        self.onPathChange = onPathChange
        self.localIPv4Addresses = localIPv4Addresses
    }

    /// Begin observing. The handler computes the signature off-main (on
    /// `queue`) and hops to the main actor for dedup state and the callback.
    func start(queue: DispatchQueue) {
        monitor.pathUpdateHandler = { [weak self, localIPv4Addresses] path in
            let signature = Self.signature(
                status: String(describing: path.status),
                interfaceNames: path.availableInterfaces.map(\.name),
                gateways: path.gateways.map { String(describing: $0) },
                localAddresses: localIPv4Addresses()
            )
            Task { @MainActor [weak self] in
                self?.handleObservation(signature: signature)
            }
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }

    private func handleObservation(signature: String) {
        let isInitialObservation = lastSignature == nil
        let changed = Self.shouldReportPathChange(
            previousSignature: lastSignature,
            newSignature: signature
        )
        lastSignature = signature
        guard changed else { return }
        onPathChange(isInitialObservation)
    }

    /// Stable identity of a network path for change detection. Order-insensitive
    /// over interfaces, gateways, and local addresses so enumeration order can't
    /// fake a change. Pure for tests.
    nonisolated static func signature(
        status: String,
        interfaceNames: [String],
        gateways: [String],
        localAddresses: [String]
    ) -> String {
        let interfaces = interfaceNames.sorted().joined(separator: ",")
        let gatewayList = gateways.sorted().joined(separator: ",")
        let addresses = localAddresses.sorted().joined(separator: ",")
        return "\(status)|\(interfaces)|\(gatewayList)|\(addresses)"
    }

    /// Local IPv4 addresses of running physical network interfaces (see the
    /// type doc for why IPv6 is excluded). Restricting publication to `en*`
    /// interfaces keeps inactive adapters and VM/Internet-Sharing bridges from
    /// consuming every LAN-first dial attempt before the Tailscale fallback.
    /// Sorted by ``signature(status:interfaceNames:gateways:localAddresses:)``,
    /// so order here does not matter.
    nonisolated static func systemLocalIPv4Addresses() -> [String] {
        let tetheredInterfaceNames = systemTetheredInterfaceNames()
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }
        var addresses: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let nameCString = interface.ifa_name,
                  localNetworkInterfaceIsEligible(
                      name: String(cString: nameCString),
                      isUp: (interface.ifa_flags & UInt32(IFF_UP)) != 0,
                      isRunning: (interface.ifa_flags & UInt32(IFF_RUNNING)) != 0,
                      isLoopback: (interface.ifa_flags & UInt32(IFF_LOOPBACK)) != 0,
                      isTethered: tetheredInterfaceNames.contains(String(cString: nameCString))
                  ),
                  let address = interface.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }
            addresses.append(String(cString: host))
        }
        return addresses
    }

    /// The primary iPhone Personal Hotspot interface, when one owns the current
    /// IPv4 route. A phone providing the hotspot cannot dial back into its Mac
    /// client, so publishing that client address as a LAN route creates a
    /// guaranteed timeout before every real fallback.
    nonisolated static func systemTetheredInterfaceNames() -> Set<String> {
        guard let globalIPv4 = SCDynamicStoreCopyValue(
            nil,
            "State:/Network/Global/IPv4" as CFString
        ) as? [String: Any],
              let serviceID = globalIPv4["PrimaryService"] as? String,
              let interface = SCDynamicStoreCopyValue(
                  nil,
                  "Setup:/Network/Service/\(serviceID)/Interface" as CFString
              ) as? [String: Any],
              let deviceName = interface["DeviceName"] as? String
        else {
            return []
        }

        let serviceName = interface["UserDefinedName"] as? String ?? ""
        if personalHotspotServiceName(serviceName) {
            return [deviceName]
        }

        guard let ipv4 = SCDynamicStoreCopyValue(
            nil,
            "State:/Network/Service/\(serviceID)/IPv4" as CFString
        ) as? [String: Any],
              let addresses = ipv4["Addresses"] as? [String],
              personalHotspotIPv4Configuration(
                  addresses: addresses,
                  router: ipv4["Router"] as? String
              )
        else {
            return []
        }
        return [deviceName]
    }

    /// Pure recognition seam for the system-created iPhone USB network service.
    nonisolated static func personalHotspotServiceName(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("iphone") && normalized.contains("usb")
    }

    /// Recognizes the IPv4 network reserved by iPhone Personal Hotspot even
    /// when macOS exposes it through the generic Wi-Fi service name.
    nonisolated static func personalHotspotIPv4Configuration(
        addresses: [String],
        router: String?
    ) -> Bool {
        guard router == "172.20.10.1" else { return false }
        return addresses.contains { address in
            let octets = address.split(separator: ".").compactMap { Int($0) }
            guard octets.count == 4 else { return false }
            return octets[0] == 172
                && octets[1] == 20
                && octets[2] == 10
                && (2...14).contains(octets[3])
        }
    }

    /// Pure interface admission policy for LAN route publication.
    nonisolated static func localNetworkInterfaceIsEligible(
        name: String,
        isUp: Bool,
        isRunning: Bool,
        isLoopback: Bool,
        isTethered: Bool = false
    ) -> Bool {
        isUp && isRunning && !isLoopback && !isTethered && name.hasPrefix("en")
    }

    /// Whether a path observation should be reported: any observation that
    /// differs from the previous one, including the first (see the type doc
    /// for why the first observation is not a silent baseline). Pure for tests.
    nonisolated static func shouldReportPathChange(
        previousSignature: String?,
        newSignature: String
    ) -> Bool {
        previousSignature != newSignature
    }
}
