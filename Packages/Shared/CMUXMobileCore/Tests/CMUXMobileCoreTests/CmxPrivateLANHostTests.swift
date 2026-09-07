import Testing

@testable import CMUXMobileCore

@Suite("Private LAN host classification")
struct CmxPrivateLANHostTests {
    private let classifier = CmxPrivateLANHost()

    @Test("RFC 1918 IPv4 literals are local network hosts", arguments: [
        "10.0.0.1",
        "172.16.0.1",
        "172.31.255.254",
        "192.168.1.20",
    ])
    func acceptsPrivateIPv4(_ host: String) {
        #expect(classifier.matches(host))
    }

    @Test("public, special, and malformed hosts are not local network hosts", arguments: [
        "100.71.210.41",
        "127.0.0.1",
        "169.254.1.2",
        "172.32.0.1",
        "203.0.113.10",
        "work-mac.local",
        "192.168.bad.1.20",
        "",
    ])
    func rejectsOtherHosts(_ host: String) {
        #expect(!classifier.matches(host))
    }
}
