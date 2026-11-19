import Foundation
import Synchronization
@testable import SamsungTVKit

/// Test double for `CredentialStore` (a copy of the unit-test target's; test targets cannot share sources).
final class InMemoryCredentialStore: CredentialStore {
    private let storage = Mutex<[TVID: TVCredentials]>([:])

    init(_ initial: [TVID: TVCredentials] = [:]) {
        storage.withLock { $0 = initial }
    }

    func load(_ id: TVID) -> TVCredentials? {
        storage.withLock { $0[id] }
    }

    func save(_ c: TVCredentials, for id: TVID) throws {
        storage.withLock { $0[id] = c }
    }

    func delete(_ id: TVID) {
        storage.withLock { _ = $0.removeValue(forKey: id) }
    }
}
