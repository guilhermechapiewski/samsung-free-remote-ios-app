import Foundation
import Synchronization
import Testing
import SamsungTVKit
@testable import FreeRemote

// MARK: - Helpers

/// `CertificatePin`'s initializer is internal to the kit, so build one through its public Codable form.
private func pin(_ byte: UInt8) throws -> CertificatePin {
    let json = #"{"sha256":"\#(Data(repeating: byte, count: 32).base64EncodedString())"}"#
    return try JSONDecoder().decode(CertificatePin.self, from: Data(json.utf8))
}

private let tvA = TVID(rawValue: "uuid:test-tv-a")
private let tvB = TVID(rawValue: "uuid:test-tv-b")

/// Runs `body` against a keychain store with a unique service, deleting its items afterwards.
private func withKeychainStore(_ body: (KeychainCredentialStore) throws -> Void) rethrows {
    let store = KeychainCredentialStore(service: "FreeRemoteTests.\(UUID().uuidString)")
    defer {
        store.delete(tvA)
        store.delete(tvB)
    }
    try body(store)
}

// MARK: - KeychainCredentialStore

@Suite struct KeychainCredentialStoreTests {
    @Test func roundTrip() throws {
        try withKeychainStore { store in
            let creds = TVCredentials(token: "12345678", pin: try pin(1))
            #expect(store.load(tvA) == nil)
            try store.save(creds, for: tvA)
            #expect(store.load(tvA) == creds)
            #expect(store.load(tvB) == nil)
        }
    }

    @Test func overwriteReplacesExisting() throws {
        try withKeychainStore { store in
            try store.save(TVCredentials(token: "old", pin: try pin(1)), for: tvA)
            let updated = TVCredentials(token: nil, pin: try pin(2))
            try store.save(updated, for: tvA)
            #expect(store.load(tvA) == updated)
        }
    }

    @Test func deleteRemovesOnlyThatTV() throws {
        try withKeychainStore { store in
            let b = TVCredentials(token: "b", pin: try pin(3))
            try store.save(TVCredentials(token: "a", pin: try pin(1)), for: tvA)
            try store.save(b, for: tvB)
            store.delete(tvA)
            #expect(store.load(tvA) == nil)
            #expect(store.load(tvB) == b)
        }
    }

    @Test func servicesAreIsolated() throws {
        try withKeychainStore { first in
            try withKeychainStore { second in
                try first.save(TVCredentials(token: "a", pin: try pin(1)), for: tvA)
                #expect(second.load(tvA) == nil)
            }
        }
    }
}

// MARK: - ICloudLabelStore

/// In-memory stand-in for `NSUbiquitousKeyValueStore`. Sendable (state behind a `Mutex`) so tests can
/// inspect it after handing it to the store.
private final class InMemoryKeyValueStore: UbiquitousKeyValueStoring, Sendable {
    private let storage = Mutex<[String: String]>([:])

    var values: [String: String] { storage.withLock { $0 } }

    func string(forKey key: String) -> String? { storage.withLock { $0[key] } }
    func set(_ value: String, forKey key: String) { storage.withLock { $0[key] = value } }
    func removeObject(forKey key: String) { storage.withLock { $0[key] = nil } }
    func synchronize() -> Bool { true }
}

@Suite struct ICloudLabelStoreTests {
    private func makeStore(_ kvs: InMemoryKeyValueStore = InMemoryKeyValueStore(),
                           center: NotificationCenter = NotificationCenter()) -> ICloudLabelStore {
        ICloudLabelStore(keyValueStore: kvs, notificationCenter: center)
    }

    @Test func setStoresTrimmedLabelUnderPrefixedKey() {
        let kvs = InMemoryKeyValueStore()
        let store = makeStore(kvs)
        store.setLabel("  Living Room \n", for: tvA)
        #expect(store.label(for: tvA) == "Living Room")
        #expect(kvs.values == ["label.uuid:test-tv-a": "Living Room"])
        #expect(store.label(for: tvB) == nil)
    }

    @Test(arguments: [nil, "", "   ", "\n\t "])
    func emptyOrWhitespaceClears(_ value: String?) {
        let kvs = InMemoryKeyValueStore()
        let store = makeStore(kvs)
        store.setLabel("Bedroom", for: tvA)
        store.setLabel(value, for: tvA)
        #expect(store.label(for: tvA) == nil)
        #expect(kvs.values.isEmpty)
    }

    @Test func labelIsCappedAt40Characters() {
        let store = makeStore()
        store.setLabel(" " + String(repeating: "é", count: 45) + " ", for: tvA)
        #expect(store.label(for: tvA) == String(repeating: "é", count: 40))
    }

    @Test func changesEmitsOnExternalChange() async {
        let center = NotificationCenter()
        let store = makeStore(center: center)
        let changes = store.changes
        center.post(name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: nil)
        var iterator = changes.makeAsyncIterator()
        let next: Void? = await iterator.next()
        #expect(next != nil)
    }
}

// MARK: - FileKnownTVStore

@Suite struct FileKnownTVStoreTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "FreeRemoteTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "known-tvs.json")
    }

    private func sampleRegistry() -> KnownTVRegistry {
        var registry = KnownTVRegistry()
        registry.record(TVDeviceInfo(id: tvA, host: "192.168.0.10", name: "TV", modelName: "QE55", modelCode: "C",
                                     wifiMAC: MACAddress("AA:BB:CC:DD:EE:01"), networkType: "wireless",
                                     powerState: .on, tokenAuthSupported: true),
                        at: Date(timeIntervalSince1970: 1_000))
        return registry
    }

    @Test func missingFileYieldsEmptyRegistry() {
        #expect(FileKnownTVStore(url: tempURL()).load() == KnownTVRegistry())
    }

    @Test func roundTripCreatesDirectory() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileKnownTVStore(url: url)
        let registry = sampleRegistry()
        try store.save(registry)
        #expect(FileKnownTVStore(url: url).load() == registry)
    }

    @Test func corruptFileYieldsEmptyRegistry() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)
        #expect(FileKnownTVStore(url: url).load() == KnownTVRegistry())
    }

    @Test func defaultURLIsInApplicationSupport() {
        let url = FileKnownTVStore.defaultURL
        #expect(url.lastPathComponent == "known-tvs.json")
        #expect(url.deletingLastPathComponent() == URL.applicationSupportDirectory)
    }
}
