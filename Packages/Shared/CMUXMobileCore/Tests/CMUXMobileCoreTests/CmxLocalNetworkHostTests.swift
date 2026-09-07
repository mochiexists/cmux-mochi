import Testing

@testable import CMUXMobileCore

@Suite("Local network host classification")
struct CmxLocalNetworkHostTests {
    private let classifier = CmxLocalNetworkHost()

    @Test("Private IPv4 and mDNS names are local", arguments: [
        "192.168.1.20",
        "studio-mac.local",
        "Studio-Mac.local",
        "build.host.local",
    ])
    func acceptsLocalHosts(_ host: String) {
        #expect(classifier.matches(host))
    }

    @Test("Public and malformed names are not local", arguments: [
        "100.71.210.41",
        "example.com",
        ".local",
        "bad-.local",
        "-bad.local",
        "bad_name.local",
        "",
    ])
    func rejectsOtherHosts(_ host: String) {
        #expect(!classifier.matches(host))
    }
}
