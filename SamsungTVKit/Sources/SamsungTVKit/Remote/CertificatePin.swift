import CryptoKit
import Foundation
import Security

/// SHA-256 of the leaf certificate's public key bytes (as returned by
/// `SecKeyCopyExternalRepresentation`). Used for trust-on-first-use pinning of TV certificates.
public struct CertificatePin: Codable, Hashable, Sendable {
    public let sha256: Data

    init(sha256: Data) {
        self.sha256 = sha256
    }

    /// Pin of the leaf certificate presented in `trust`, or nil if it cannot be computed.
    /// Deliberately does not evaluate the trust: TV certificates are self-signed, so trust is
    /// decided solely by comparing pins.
    public static func of(_ trust: SecTrust) -> CertificatePin? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              let key = SecCertificateCopyKey(leaf),
              let keyData = SecKeyCopyExternalRepresentation(key, nil) as Data?
        else { return nil }
        return CertificatePin(sha256: Data(SHA256.hash(data: keyData)))
    }
}

public enum PinPolicy: Sendable {
    /// Accept whatever certificate is presented and record its pin (first pairing).
    case recordFirstUse
    /// Accept only a certificate whose pin equals this one.
    case require(CertificatePin)
}
