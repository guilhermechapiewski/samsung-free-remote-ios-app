import Foundation

/// What is remembered about a paired TV: the pairing token (if the TV issued one) and the
/// pinned certificate.
public struct TVCredentials: Codable, Equatable, Sendable {
    public var token: String?
    public var pin: CertificatePin

    public init(token: String?, pin: CertificatePin) {
        self.token = token
        self.pin = pin
    }
}

public protocol CredentialStore: Sendable {
    func load(_ id: TVID) -> TVCredentials?
    func save(_ c: TVCredentials, for id: TVID) throws
    func delete(_ id: TVID)
}
