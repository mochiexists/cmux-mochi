import Darwin
import Foundation

/// Resolves a hostname to numeric addresses through the system resolver.
///
/// MagicDNS names resolve only while Tailscale is active, which is exactly the
/// condition under which a tailnet route is dialable — so a failure here is the
/// same answer as "that peer is not reachable", not a separate error to model.
enum CmxSystemHostResolver {
    /// Numeric addresses for `host`, IPv4 first.
    ///
    /// IPv4 leads because a tailnet peer always has a 100.64/10 address, while
    /// its IPv6 address depends on the tailnet's configuration; preferring the
    /// address that is always present keeps the common path one attempt long.
    static func addresses(for host: String) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            // getaddrinfo blocks, so it must not run on a cooperative thread.
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: resolveBlocking(host))
            }
        }
    }

    private static func resolveBlocking(_ host: String) -> [String] {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var head: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &head) == 0, let head else { return [] }
        defer { freeaddrinfo(head) }

        var ipv4: [String] = []
        var ipv6: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = head
        while let entry = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                entry.pointee.ai_addr,
                entry.pointee.ai_addrlen,
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if status == 0, let text = String(validatingUTF8: buffer), !text.isEmpty {
                if entry.pointee.ai_family == AF_INET {
                    ipv4.append(text)
                } else {
                    ipv6.append(text)
                }
            }
            cursor = entry.pointee.ai_next
        }
        return ipv4 + ipv6
    }
}
