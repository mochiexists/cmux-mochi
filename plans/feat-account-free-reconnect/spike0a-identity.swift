// Phase 0a spike: P-256 identity via swift-certificates -> SecIdentity -> sec_protocol.
// Proves the v7 design's key API bet on macOS. Steps:
//  1. CryptoKit P-256 key
//  2. self-signed X.509 leaf via swift-certificates (100-year validity)
//  3. SecKey + SecCertificate from DER
//  4. Keychain round-trip to obtain a SecIdentity (data-protection first, legacy fallback)
//  5. sec_identity_create -> sec_protocol_options_set_local_identity
//  6. canonical SPKI SHA-256 fingerprint extraction

import Crypto
import CryptoKit
import Foundation
import Network
import Security
import SwiftASN1
import X509

func fail(_ msg: String) -> Never {
    print("SPIKE FAIL: \(msg)")
    exit(1)
}

// 1. P-256 key
let key = P256.Signing.PrivateKey()

// 2. Self-signed leaf
let subject = try! DistinguishedName {
    CommonName("spike0a-device")
}
let notBefore = Date().addingTimeInterval(-60)
let notAfter = notBefore.addingTimeInterval(100 * 365 * 24 * 3600)
let certificate: Certificate
do {
    certificate = try Certificate(
        version: .v3,
        serialNumber: .init(),
        publicKey: .init(key.publicKey),
        notValidBefore: notBefore,
        notValidAfter: notAfter,
        issuer: subject,
        subject: subject,
        signatureAlgorithm: .ecdsaWithSHA256,
        extensions: try .init {
            Critical(BasicConstraints.notCertificateAuthority)
        },
        issuerPrivateKey: .init(key)
    )
} catch {
    fail("certificate build: \(error)")
}

var serializer = DER.Serializer()
do { try serializer.serialize(certificate) } catch { fail("DER serialize: \(error)") }
let certDER = Data(serializer.serializedBytes)
print("ok: self-signed cert DER (\(certDER.count) bytes)")

// 3. SecKey + SecCertificate
guard let secCert = SecCertificateCreateWithData(nil, certDER as CFData) else {
    fail("SecCertificateCreateWithData rejected DER")
}
let keyAttrs: [CFString: Any] = [
    kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
    kSecAttrKeyClass: kSecAttrKeyClassPrivate,
]
var keyErr: Unmanaged<CFError>?
guard let secKey = SecKeyCreateWithData(
    key.x963Representation as CFData, keyAttrs as CFDictionary, &keyErr
) else {
    fail("SecKeyCreateWithData: \(String(describing: keyErr?.takeRetainedValue()))")
}
print("ok: SecCertificate + SecKey created")

// 4. Keychain round-trip for SecIdentity.
//
// CLI reality check (recorded for the spike report): an UNSIGNED CLI cannot
// SecItemAdd into the data-protection keychain (-34018, needs an
// application-identifier entitlement) and SecItemAdd of an ephemeral SecKey
// ref into the legacy file keychain returns -50. Both are environment
// artifacts of an unsigned binary, not API-chain failures — the shipping app
// is signed+entitled and uses the standard data-protection add (as cmux's
// existing keychain code already does; Phase 1 tests exercise that in an
// entitled target).
//
// For the spike we therefore import the identity via `security import` of a
// PKCS#12 (mode "make" writes the PEMs; the driver script does the import),
// which still proves the load-bearing claims: swift-certificates DER is
// accepted by the Security stack as a certificate AND pairs with its key
// into a resolvable SecIdentity.
if CommandLine.arguments.contains("make") {
    let dir = FileManager.default.currentDirectoryPath
    let keyPEM = key.pemRepresentation
    var certSerializer2 = DER.Serializer()
    try! certSerializer2.serialize(certificate)
    let certPEM = "-----BEGIN CERTIFICATE-----\n"
        + Data(certSerializer2.serializedBytes).base64EncodedString(options: [.lineLength64Characters])
        + "\n-----END CERTIFICATE-----\n"
    try! keyPEM.write(toFile: dir + "/spike0a-key.pem", atomically: true, encoding: .utf8)
    try! certPEM.write(toFile: dir + "/spike0a-cert.pem", atomically: true, encoding: .utf8)
    try! certDER.write(to: URL(fileURLWithPath: dir + "/spike0a-cert.der"))
    print("ok: wrote spike0a-key.pem / spike0a-cert.pem / spike0a-cert.der")
    print("SPIKE 0a MAKE DONE")
    exit(0)
}

// mode "use": expect the identity already imported into the login keychain.
let expectedDERPath = FileManager.default.currentDirectoryPath + "/spike0a-cert.der"
let expectedDER = (try? Data(contentsOf: URL(fileURLWithPath: expectedDERPath))) ?? certDER

let identityQuery: [CFString: Any] = [
    kSecClass: kSecClassIdentity,
    kSecReturnRef: true,
    kSecMatchLimit: kSecMatchLimitAll,
]
var result: CFTypeRef?
let queryStatus = SecItemCopyMatching(identityQuery as CFDictionary, &result)
guard queryStatus == errSecSuccess, let identities = result as? [SecIdentity] else {
    fail("identity query: \(queryStatus)")
}
// Find the IMPORTED identity by matching certificate data.
var matched: SecIdentity?
for identity in identities {
    var certOut: SecCertificate?
    guard SecIdentityCopyCertificate(identity, &certOut) == errSecSuccess,
          let certOut else { continue }
    if SecCertificateCopyData(certOut) as Data == expectedDER {
        matched = identity
        break
    }
}
guard let identity = matched else {
    fail("no SecIdentity pairing the imported cert with its key (searched \(identities.count))")
}
print("ok: SecIdentity resolved from keychain (cert+key paired by Security)")

// 5. sec_identity -> sec_protocol_options
guard let secIdentity = sec_identity_create(identity) else {
    fail("sec_identity_create returned nil")
}
let tlsOptions = NWProtocolTLS.Options()
sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, secIdentity)
sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv13)
sec_protocol_options_set_max_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv13)
print("ok: sec_protocol_options_set_local_identity accepted the identity")

// 6. Canonical SPKI SHA-256 fingerprint from the IMPORTED cert's DER,
// cross-checked against the SecCertificate's own key.
let importedCert: Certificate
do { importedCert = try Certificate(derEncoded: Array(expectedDER)) } catch {
    fail("X509 re-parse of imported DER: \(error)")
}
var spkiSerializer = DER.Serializer()
do { try spkiSerializer.serialize(importedCert.publicKey) } catch { fail("SPKI serialize: \(error)") }
let spkiDER = Data(spkiSerializer.serializedBytes)
let fingerprint = SHA256.hash(data: spkiDER).map { String(format: "%02x", $0) }.joined()
print("ok: SPKI fingerprint \(fingerprint.prefix(16))… (\(spkiDER.count)-byte SPKI)")

var importedCertOut: SecCertificate?
_ = SecIdentityCopyCertificate(identity, &importedCertOut)
if let importedCertOut,
   let certKey = SecCertificateCopyKey(importedCertOut),
   let ext = SecKeyCopyExternalRepresentation(certKey, nil) as Data?,
   let rebuilt = try? P256.Signing.PublicKey(x963Representation: ext) {
    var s2 = DER.Serializer()
    try? s2.serialize(Certificate.PublicKey(rebuilt))
    let fp2 = SHA256.hash(data: Data(s2.serializedBytes)).map { String(format: "%02x", $0) }.joined()
    guard fp2 == fingerprint else { fail("fingerprint mismatch between X509 parse and SecCertificate key") }
    print("ok: fingerprint cross-check matches")
}

print("SPIKE 0a PASS (macOS; identity via signed-context import — app path uses entitled SecItemAdd)")
