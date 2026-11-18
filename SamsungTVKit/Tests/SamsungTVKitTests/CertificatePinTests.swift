import Foundation
import Security
import Testing
@testable import SamsungTVKit

@Suite struct CertificatePinTests {
    /// Expected pin of `Fixtures/TLS/cert-a.der`, computed once with:
    ///   openssl x509 -inform DER -in cert-a.der -noout -pubkey \
    ///     | openssl ec -pubin -outform DER | tail -c 65 | openssl dgst -sha256 -hex
    /// (the last 65 bytes of the SPKI DER are the uncompressed point 04||X||Y, which is what
    /// SecKeyCopyExternalRepresentation returns for an EC P-256 public key).
    static let certAPinHex = "3a43c778e8cbb8da3c3ee57dd83989c23feb3c3ec3451124644d0e8cd5e401b7"

    static func trust(for name: String) throws -> SecTrust {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "der", subdirectory: "Fixtures/TLS"))
        let der = try Data(contentsOf: url)
        let cert = try #require(SecCertificateCreateWithData(nil, der as CFData))
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(cert, SecPolicyCreateBasicX509(), &trust)
        #expect(status == errSecSuccess)
        return try #require(trust)
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    @Test func pinOfFixtureMatchesOpenSSL() throws {
        let pin = try #require(CertificatePin.of(Self.trust(for: "cert-a")))
        #expect(pin.sha256.count == 32)
        #expect(Self.hex(pin.sha256) == Self.certAPinHex)
    }

    @Test func pinIsStable() throws {
        let first = CertificatePin.of(try Self.trust(for: "cert-a"))
        let second = CertificatePin.of(try Self.trust(for: "cert-a"))
        #expect(first != nil)
        #expect(first == second)
    }

    @Test func differentCertsHaveDifferentPins() throws {
        let a = try #require(CertificatePin.of(Self.trust(for: "cert-a")))
        let b = try #require(CertificatePin.of(Self.trust(for: "cert-b")))
        #expect(a != b)
    }

    @Test func pinRoundTripsThroughCodable() throws {
        let pin = try #require(CertificatePin.of(Self.trust(for: "cert-a")))
        let decoded = try JSONDecoder().decode(CertificatePin.self, from: JSONEncoder().encode(pin))
        #expect(decoded == pin)
    }
}

@Suite struct PinningDecisionTests {
    let pinA = CertificatePin(sha256: Data(repeating: 0xA, count: 32))
    let pinB = CertificatePin(sha256: Data(repeating: 0xB, count: 32))

    @Test func recordFirstUseWithPinAccepts() {
        #expect(PinningDelegate.decide(policy: .recordFirstUse, presented: pinA) == .accept(pinA))
    }

    @Test func recordFirstUseWithoutPinRejects() {
        #expect(PinningDelegate.decide(policy: .recordFirstUse, presented: nil) == .reject(mismatch: false))
    }

    @Test func requireWithEqualPinAccepts() {
        #expect(PinningDelegate.decide(policy: .require(pinA), presented: pinA) == .accept(pinA))
    }

    @Test func requireWithDifferentPinRejectsAsMismatch() {
        #expect(PinningDelegate.decide(policy: .require(pinA), presented: pinB) == .reject(mismatch: true))
    }

    @Test func requireWithoutPinRejects() {
        #expect(PinningDelegate.decide(policy: .require(pinA), presented: nil) == .reject(mismatch: false))
    }
}
