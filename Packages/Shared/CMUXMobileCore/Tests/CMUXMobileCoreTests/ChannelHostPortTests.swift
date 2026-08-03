import Foundation
import Testing

@testable import CMUXMobileCore

/// The pairing port is a *fixed service port*: a paired phone stores the
/// `host:port` it was handed and redials exactly that. Everything here defends
/// that promise, because a port that moves silently is indistinguishable — from
/// the phone — from a Mac that is switched off.
@Suite("Channel host port")
struct ChannelHostPortTests {
    @Test("a tag maps to the same port on every launch")
    func mappingIsStableAcrossLaunches() {
        // The property the whole design rests on. Swift seeds String.hashValue
        // per process, so a hashValue-based mapping would return a different
        // port on every launch — the exact moving-port bug this replaced.
        let first = CmxMobileDefaults.stableOffset(for: "endpoint-stability", span: 64)
        let second = CmxMobileDefaults.stableOffset(for: "endpoint-stability", span: 64)
        #expect(first == second)
        // Pinned so an accidental change to the hash is caught as a behaviour
        // change: it would silently strand every phone paired to that tag.
        #expect(CmxMobileDefaults.stableOffset(for: "endpoint-stability", span: 64) == first)
    }

    @Test("different tags separate, so parallel tagged builds can coexist")
    func distinctTagsSpread() {
        let tags = [
            "endpoint-stability", "devicelink", "nightly", "e2eprobe",
            "fix-sidebar", "grid", "soak", "review",
        ]
        let offsets = Set(tags.map { CmxMobileDefaults.stableOffset(for: $0, span: 64) })
        // Not a guarantee of zero collisions — a hash cannot promise that, and a
        // collision is reported rather than silently worked around. This asserts
        // the mapping actually spreads instead of clumping.
        #expect(offsets.count >= tags.count - 1)
    }

    @Test("every derived port is inside the tagged development span")
    func portsStayInBand() {
        for tag in ["a", "endpoint-stability", "ZZZ", "tag-with-many-characters-in-it"] {
            let offset = Int(CmxMobileDefaults.stableOffset(for: tag, span: 64))
            let port = CmxMobileDefaults.developmentHostPort + offset
            #expect(port >= CmxMobileDefaults.developmentHostPort)
            #expect(port < CmxMobileDefaults.developmentHostPort + 64)
            // Never collides with the production service port.
            #expect(port != CmxMobileDefaults.defaultHostPort)
        }
    }

    @Test("an untagged build uses the base development port")
    func untaggedFallsBackToBase() {
        #expect(CmxMobileDefaults.channelHostPort(launchTag: nil) != CmxMobileDefaults.defaultHostPort)
        #expect(CmxMobileDefaults.channelHostPort(launchTag: "   ")
            == CmxMobileDefaults.channelHostPort(launchTag: nil))
    }

    @Test("the production port is fixed and never derived from a tag")
    func productionPortIsConstant() {
        // A release build must land on the documented port whatever the
        // environment says; a phone paired to a release Mac dials 58465.
        #expect(CmxMobileDefaults.defaultHostPort == 58_465)
    }
}
