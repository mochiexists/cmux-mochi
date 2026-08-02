// Phase 0b spike: mutual TLS 1.3 over NWListener/NWConnection with SPKI pinning
// in BOTH directions, ALPN, resumption disabled. Proves the v7 transport bet.
//
// Cases exercised:
//   1. happy path       — server pin matches, client fingerprint authorized  => connected, ALPN verified
//   2. wrong server pin — client rejects the server                          => handshake fails, no data
//   3. unknown client   — server rejects an unauthorized client fingerprint  => handshake fails
//   4. plaintext client — no TLS at all against the TLS listener             => no session
//
// Identities are created in-memory (SecIdentity assembled without keychain
// persistence via PKCS#12 import into a transient keychain-less context is not
// available, so we use SecPKCS12Import on in-memory data — the app will read
// its identity from the entitled keychain instead; identity *provenance* is
// spike 0a's job, this spike is about the TLS behavior).

import Crypto
import Foundation
import Network
import Security
import SwiftASN1
import X509

// MARK: - helpers

func fail(_ msg: String) -> Never {
    print("SPIKE FAIL: \(msg)")
    exit(1)
}

func spkiFingerprint(_ certificate: Certificate) -> String {
    var s = DER.Serializer()
    try! s.serialize(certificate.publicKey)
    return SHA256.hash(data: Data(s.serializedBytes)).map { String(format: "%02x", $0) }.joined()
}

func spkiFingerprint(secCertificate: SecCertificate) -> String? {
    let der = SecCertificateCopyData(secCertificate) as Data
    guard let parsed = try? Certificate(derEncoded: Array(der)) else { return nil }
    return spkiFingerprint(parsed)
}

/// Builds a self-signed P-256 identity and returns (SecIdentity, fingerprint).
func makeIdentity(commonName: String) -> (identity: SecIdentity, fingerprint: String) {
    let key = P256.Signing.PrivateKey()
    let name = try! DistinguishedName { CommonName(commonName) }
    let notBefore = Date().addingTimeInterval(-60)
    let certificate = try! Certificate(
        version: .v3,
        serialNumber: .init(),
        publicKey: .init(key.publicKey),
        notValidBefore: notBefore,
        notValidAfter: notBefore.addingTimeInterval(100 * 365 * 24 * 3600),
        issuer: name,
        subject: name,
        signatureAlgorithm: .ecdsaWithSHA256,
        extensions: try! .init { Critical(BasicConstraints.notCertificateAuthority) },
        issuerPrivateKey: .init(key)
    )
    var certSer = DER.Serializer()
    try! certSer.serialize(certificate)
    let certDER = Data(certSer.serializedBytes)

    // Assemble a PKCS#12 via openssl (spike-only convenience) and import it.
    let dir = NSTemporaryDirectory() + "spike0b-\(UUID().uuidString)"
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let keyPath = dir + "/k.pem", certPath = dir + "/c.pem", p12Path = dir + "/i.p12"
    try! key.pemRepresentation.write(toFile: keyPath, atomically: true, encoding: .utf8)
    let certPEM = "-----BEGIN CERTIFICATE-----\n"
        + certDER.base64EncodedString(options: [.lineLength64Characters])
        + "\n-----END CERTIFICATE-----\n"
    try! certPEM.write(toFile: certPath, atomically: true, encoding: .utf8)

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    proc.arguments = [
        "pkcs12", "-export",
        "-certpbe", "PBE-SHA1-3DES", "-keypbe", "PBE-SHA1-3DES", "-macalg", "sha1",
        "-inkey", keyPath, "-in", certPath, "-out", p12Path,
        "-passout", "pass:spike", "-name", commonName,
    ]
    proc.standardError = FileHandle.nullDevice
    try! proc.run()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0, let p12 = try? Data(contentsOf: URL(fileURLWithPath: p12Path)) else {
        fail("openssl pkcs12 export failed for \(commonName)")
    }

    var items: CFArray?
    let importStatus = SecPKCS12Import(
        p12 as CFData,
        [kSecImportExportPassphrase as String: "spike"] as CFDictionary,
        &items
    )
    guard importStatus == errSecSuccess,
          let array = items as? [[String: Any]],
          let identity = array.first?[kSecImportItemIdentity as String]
    else {
        fail("SecPKCS12Import(\(commonName)): \(importStatus)")
    }
    return (identity as! SecIdentity, spkiFingerprint(certificate))
}

// MARK: - TLS option builders

let alpn = "cmux-devicelink/1"

func serverTLSOptions(identity: SecIdentity, authorized: Set<String>) -> NWProtocolTLS.Options {
    let options = NWProtocolTLS.Options()
    let sec = options.securityProtocolOptions
    sec_protocol_options_set_local_identity(sec, sec_identity_create(identity)!)
    sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv13)
    sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv13)
    sec_protocol_options_add_tls_application_protocol(sec, alpn)
    // v7: client certificate REQUIRED (servers default to false).
    sec_protocol_options_set_peer_authentication_required(sec, true)
    // v7: resumption unconditionally disabled so revocation is never bypassed.
    sec_protocol_options_set_tls_resumption_enabled(sec, false)
    sec_protocol_options_set_tls_tickets_enabled(sec, false)
    sec_protocol_options_set_verify_block(sec, { _, trust, complete in
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
        guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
              let leaf = chain.first,
              let fingerprint = spkiFingerprint(secCertificate: leaf) else {
            complete(false); return
        }
        complete(authorized.contains(fingerprint))
    }, DispatchQueue.global())
    return options
}

func clientTLSOptions(identity: SecIdentity, expectedServerPin: String) -> NWProtocolTLS.Options {
    let options = NWProtocolTLS.Options()
    let sec = options.securityProtocolOptions
    sec_protocol_options_set_local_identity(sec, sec_identity_create(identity)!)
    sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv13)
    sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv13)
    sec_protocol_options_add_tls_application_protocol(sec, alpn)
    sec_protocol_options_set_tls_resumption_enabled(sec, false)
    sec_protocol_options_set_tls_tickets_enabled(sec, false)
    sec_protocol_options_set_verify_block(sec, { _, trust, complete in
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
        guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
              let leaf = chain.first,
              let fingerprint = spkiFingerprint(secCertificate: leaf) else {
            complete(false); return
        }
        complete(fingerprint == expectedServerPin)
    }, DispatchQueue.global())
    return options
}

// MARK: - harness

final class Harness: @unchecked Sendable {
    let listener: NWListener
    private(set) var port: NWEndpoint.Port = NWEndpoint.Port(rawValue: 1)!
    private var accepted: [NWConnection] = []
    private let lock = NSLock()
    var acceptedALPN: String?
    /// Server-side truth: a connection that actually reached `.ready` on the
    /// LISTENER side, i.e. the server accepted the client's certificate.
    private var serverReadyCount = 0
    var serverAdmitted: Bool {
        lock.lock(); defer { lock.unlock() }
        return serverReadyCount > 0
    }

    init(identity: SecIdentity, authorized: Set<String>) {
        let params = NWParameters(tls: serverTLSOptions(identity: identity, authorized: authorized))
        params.allowLocalEndpointReuse = true
        listener = try! NWListener(using: params, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.lock(); self.accepted.append(connection); self.lock.unlock()
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    self.lock.lock(); self.serverReadyCount += 1; self.lock.unlock()
                    let meta = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
                    if let meta {
                        let negotiated = sec_protocol_metadata_get_negotiated_protocol(meta.securityProtocolMetadata)
                        self.acceptedALPN = negotiated.map { String(cString: $0) }
                    }
                    // Echo server: proves the channel actually carries data.
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { data, _, _, _ in
                        if let data, !data.isEmpty {
                            connection.send(content: data, completion: .contentProcessed { _ in })
                        }
                    }
                }
            }
            connection.start(queue: .global())
        }
        listener.start(queue: .global())
        guard ready.wait(timeout: .now() + 5) == .success, let p = listener.port else {
            fail("listener never became ready")
        }
        port = p
    }

    func stop() {
        lock.lock(); accepted.forEach { $0.cancel() }; lock.unlock()
        listener.cancel()
    }
}

enum DialOutcome: String { case echoed, connectedButUnusable, failed, timedOut }

/// Dials and — critically — attempts a DATA ROUND TRIP.
///
/// TLS 1.3 finishes the client's handshake BEFORE the server has validated the
/// client certificate (client auth rides after the server's Finished), so a
/// client reaching `.ready` proves only that the *server* was acceptable. The
/// server's rejection of an unknown client surfaces on the first read/write.
/// Therefore `.echoed` — not `.ready` — is the honest signal of admission.
func dial(port: NWEndpoint.Port, tls: NWProtocolTLS.Options?, timeout: TimeInterval = 6) -> (DialOutcome, String?) {
    let params: NWParameters = tls.map { NWParameters(tls: $0) } ?? NWParameters(tls: nil)
    let connection = NWConnection(host: "127.0.0.1", port: port, using: params)
    let done = DispatchSemaphore(value: 0)
    var outcome: DialOutcome = .timedOut
    var negotiated: String?
    let finish: (DialOutcome) -> Void = { result in
        if outcome == .timedOut { outcome = result; done.signal() }
    }
    connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
            if let meta = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
               let p = sec_protocol_metadata_get_negotiated_protocol(meta.securityProtocolMetadata) {
                negotiated = String(cString: p)
            }
            let probe = Data("ping".utf8)
            connection.send(content: probe, completion: .contentProcessed { error in
                if error != nil { finish(.connectedButUnusable); return }
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { data, _, _, receiveError in
                    if receiveError != nil || data == nil || data!.isEmpty {
                        finish(.connectedButUnusable)
                    } else {
                        finish(.echoed)
                    }
                }
            })
        case .failed, .cancelled:
            finish(.failed)
        case .waiting:
            // A definitive TLS refusal surfaces as .waiting(secureChannelFailed)
            // before the connect deadline — v7 requires treating it as terminal.
            finish(.failed)
        default:
            break
        }
    }
    connection.start(queue: .global())
    _ = done.wait(timeout: .now() + timeout)
    connection.cancel()
    return (outcome, negotiated)
}

// MARK: - cases

let server = makeIdentity(commonName: "spike0b-mac")
let pairedClient = makeIdentity(commonName: "spike0b-phone-paired")
let strangerClient = makeIdentity(commonName: "spike0b-phone-stranger")
print("ok: three P-256 identities built")

// Case 1 — happy path
do {
    let harness = Harness(identity: server.identity, authorized: [pairedClient.fingerprint])
    defer { harness.stop() }
    let (outcome, negotiated) = dial(
        port: harness.port,
        tls: clientTLSOptions(identity: pairedClient.identity, expectedServerPin: server.fingerprint)
    )
    guard outcome == .echoed else { fail("case 1 (happy path) expected echoed, got \(outcome.rawValue)") }
    guard harness.serverAdmitted else { fail("case 1 server never admitted the connection") }
    guard negotiated == alpn else { fail("case 1 negotiated ALPN was \(negotiated ?? "nil"), expected \(alpn)") }
    print("ok: case 1 happy path — mTLS 1.3 data round-trip, ALPN '\(alpn)' verified, server admitted")
}

// Case 2 — wrong server pin
do {
    let harness = Harness(identity: server.identity, authorized: [pairedClient.fingerprint])
    defer { harness.stop() }
    let (outcome, _) = dial(
        port: harness.port,
        tls: clientTLSOptions(identity: pairedClient.identity, expectedServerPin: strangerClient.fingerprint)
    )
    guard outcome == .failed else { fail("case 2 (wrong server pin) expected failure, got \(outcome.rawValue)") }
    print("ok: case 2 wrong server pin — client refused the impostor before sending data")
}

// Case 3 — unknown client fingerprint (no enrollment window).
// KEY FINDING: the client may momentarily reach .ready (TLS 1.3 client auth is
// post-Finished), but the server must never admit it and no data may flow.
do {
    let harness = Harness(identity: server.identity, authorized: [pairedClient.fingerprint])
    defer { harness.stop() }
    let (outcome, _) = dial(
        port: harness.port,
        tls: clientTLSOptions(identity: strangerClient.identity, expectedServerPin: server.fingerprint)
    )
    guard outcome != .echoed else { fail("case 3 (unknown client) data flowed — server admitted a stranger") }
    guard !harness.serverAdmitted else { fail("case 3 server reached .ready for an unauthorized fingerprint") }
    print("ok: case 3 unknown client — server refused; no admission, no data (client saw: \(outcome.rawValue))")
}

// Case 4 — plaintext client against the TLS listener
do {
    let harness = Harness(identity: server.identity, authorized: [pairedClient.fingerprint])
    defer { harness.stop() }
    let (outcome, _) = dial(port: harness.port, tls: nil, timeout: 4)
    guard outcome != .echoed, !harness.serverAdmitted else {
        fail("case 4 (plaintext) unexpectedly established a usable session")
    }
    print("ok: case 4 plaintext — no session, no admission (client saw: \(outcome.rawValue))")
}

print("SPIKE 0b PASS (mTLS 1.3 + bidirectional SPKI pinning + ALPN + resumption off, on macOS)")
print("NOTE for design: client-side .ready does NOT prove server admission under")
print("TLS 1.3; the phone must treat a completed round trip as the connected signal.")
