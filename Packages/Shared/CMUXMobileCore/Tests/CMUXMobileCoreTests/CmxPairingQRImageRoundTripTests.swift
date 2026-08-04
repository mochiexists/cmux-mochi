#if canImport(CoreImage)
import CoreImage
import Foundation
import Testing

@testable import CMUXMobileCore

/// The QR code the Mac draws must be optically readable back into the exact
/// pairing URL it encodes.
///
/// Everything else about pairing is tested at the string level: the grammar,
/// the route filtering, the hostile-input caps. Nothing tested the step the
/// camera actually performs — render to pixels, read pixels back. A payload
/// that is correct as a string but too dense, mis-encoded, or lossy once drawn
/// fails only in a person's hands, holding a phone up to a screen.
///
/// This is the closest a machine can get to that journey without optics: a real
/// DeviceLink pairing URL, rendered exactly as the Mac renders it, decoded by
/// the same Core Image detector class the scanner relies on, and then fed back
/// through ``CmxPairingQRCode`` to prove the round trip yields a usable pairing.
@Suite("Pairing QR image round trip")
struct CmxPairingQRImageRoundTripTests {
    /// A DeviceLink pairing URL shaped like the one `mobile.pairing.code.create`
    /// mints: v3 grammar, four routes, a 64-hex fingerprint and a token.
    private func pairingURL(routeCount: Int = 4) -> String {
        let hosts = [
            "100.112.69.84:58525",
            "fd7a:115c:a1e0::e53a:4555:58525",
            "timapple-m5.tailfc3a5b.ts.net:58525",
            "s-macbook-pro-2.tailfc3a5b.ts.net:58525",
        ]
        let routes = hosts.prefix(routeCount)
            .map { "r=\($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0)" }
            .joined(separator: "&")
        let fingerprint = String(repeating: "8dd06915fb28a21b", count: 4)
        return "cmux-ios-dev://attach?v=3&\(routes)"
            + "&f=\(fingerprint)"
            + "&t=uAbP6_tRWt5hCjS6zBqrYJJ_P7XeRawNEnhVGSnmPGc"
            + "&n=timapple%20m5%20(endpoint-stability)"
    }

    /// Renders a string to a QR image the way the Mac's pairing view does.
    private func renderQR(_ contents: String, scale: CGFloat = 10) throws -> CIImage {
        let filter = try #require(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data(contents.utf8), forKey: "inputMessage")
        // "M" is the default correction level; a lower level would shrink the
        // code at the cost of exactly the readability this test exists to check.
        filter.setValue("M", forKey: "inputCorrectionLevel")
        let output = try #require(filter.outputImage)
        return output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    private func decodeQR(_ image: CIImage) -> String? {
        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: CIContext(),
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        let features = detector?.features(in: image) as? [CIQRCodeFeature]
        return features?.compactMap(\.messageString).first
    }

    @Test("a minted pairing URL survives being drawn and read back")
    func pairingURLSurvivesRendering() throws {
        let original = pairingURL()
        let decoded = try #require(
            decodeQR(try renderQR(original)),
            "the rendered QR code could not be read back at all"
        )
        #expect(decoded == original)
    }

    @Test("the read-back payload still parses as a pairing")
    func readBackPayloadStillParses() throws {
        let original = pairingURL()
        let decoded = try #require(decodeQR(try renderQR(original)))
        // The scanner hands this exact string to the pairing sheet, so it must
        // survive the optical trip AND remain a payload the phone accepts.
        let url = try #require(URL(string: decoded))
        #expect(url.scheme == "cmux-ios-dev")
        #expect(url.host == "attach")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.filter { $0.name == "r" }.count == 4)
        #expect(items.first { $0.name == "f" }?.value?.count == 64)
        #expect(items.first { $0.name == "t" }?.value?.isEmpty == false)
    }

    /// Density is the failure mode a string test cannot see: every extra route
    /// makes the code finer, and a code too fine for a phone camera at arm's
    /// length is unusable while being perfectly valid.
    @Test("stays readable at the route counts a real Mac publishes", arguments: [1, 2, 3, 4])
    func staysReadableAcrossRouteCounts(routeCount: Int) throws {
        let original = pairingURL(routeCount: routeCount)
        let decoded = decodeQR(try renderQR(original))
        let detail = "a \(routeCount)-route pairing code did not survive rendering "
            + "(\(original.count) characters)"
        #expect(decoded == original, Comment(rawValue: detail))
    }

    /// Guards the scale the Mac actually draws at. A code that only reads back
    /// when rendered huge is not the code on screen.
    @Test("readable at a modest on-screen scale")
    func readableAtModestScale() throws {
        let original = pairingURL()
        let decoded = decodeQR(try renderQR(original, scale: 4))
        #expect(decoded == original, "unreadable at 4x; the Mac's QR may be too dense")
    }
}
#endif
