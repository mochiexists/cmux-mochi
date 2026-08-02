import DeviceLinkKit
import Foundation
import Network

// Drives a full DeviceLink enrollment against the live Mac, so a failure here
// is the host's, and a success proves the phone-side UI is what is stuck.
let raw = try String(contentsOfFile: "/tmp/probe-code.txt", encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
let payload = try PairingPayloadCoder.decode(URL(string: raw)!)
print("decoded code: routes=\(payload.routes.count) pin=\(payload.macFingerprint.shortForm)")

let phone = try DeviceIdentityMaterial.generate(commonName: "probe-phone")
let identity = try SecIdentityFactory.makeIdentity(from: phone)
print("probe phone identity: \(phone.fingerprint.shortForm)")

let options = DeviceLinkTLS.connectionOptions(
    identity: identity,
    expectedServerFingerprint: payload.macFingerprint
)

// Prefer the tailnet route, as a real phone would.
let route = payload.routes.first { $0.hasPrefix("127.") } ?? payload.routes[0]
let parts = route.split(separator: ":")
let host = parts.dropLast().joined(separator: ":")
let port = UInt16(parts.last!)!
print("dialing \(host):\(port)")

let connection = NWConnection(
    host: NWEndpoint.Host(host),
    port: NWEndpoint.Port(rawValue: port)!,
    using: NWParameters(tls: options)
)
let ready = DispatchSemaphore(value: 0)
final class Box: @unchecked Sendable { var value = "timeout" }
let box = Box()
connection.stateUpdateHandler = { s in
    switch s {
    case .ready: box.value = "ready"; ready.signal()
    case .failed(let e): box.value = "failed: \(e)"; ready.signal()
    case .waiting(let e): box.value = "waiting: \(e)"; ready.signal()
    default: break
    }
}
connection.start(queue: .global())
_ = ready.wait(timeout: .now() + 15)
print("TLS: \(box.value)")
guard box.value == "ready" else { exit(1) }

let request: [String: Any] = [
    "id": "probe-1",
    "method": "mobile.pairing.device.enroll",
    "params": ["ticket": payload.enrollmentTicket, "device_label": "probe device"],
]
let body = try JSONSerialization.data(withJSONObject: request)
var length = UInt32(body.count).bigEndian
var framed = Data(bytes: &length, count: 4)
framed.append(body)

let done = DispatchSemaphore(value: 0)
connection.send(content: framed, completion: .contentProcessed { error in
    if let error { print("send failed: \(error)") }
    done.signal()
})
_ = done.wait(timeout: .now() + 10)

let recv = DispatchSemaphore(value: 0)
connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, error in
    if let data, !data.isEmpty {
        let text = String(data: data.dropFirst(4), encoding: .utf8) ?? "<binary \(data.count)B>"
        print("RESPONSE: \(text.prefix(300))")
    } else {
        print("no response: \(String(describing: error))")
    }
    recv.signal()
}
_ = recv.wait(timeout: .now() + 15)
connection.cancel()
