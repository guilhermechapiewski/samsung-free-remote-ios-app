import Foundation
import SamsungTVKit
import Synchronization

/// User-chosen display names for TVs, keyed by `TVID`.
protocol LabelStore: Sendable {
    func label(for id: TVID) -> String?
    func setLabel(_ s: String?, for id: TVID)
    /// Emits whenever labels may have changed on another device.
    var changes: AsyncStream<Void> { get }
}

/// The subset of `NSUbiquitousKeyValueStore` the label store uses, so tests can substitute an in-memory double.
protocol UbiquitousKeyValueStoring: AnyObject {
    func string(forKey key: String) -> String?
    func set(_ value: String, forKey key: String)
    func removeObject(forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: UbiquitousKeyValueStoring {
    func set(_ value: String, forKey key: String) {
        set(value as Any, forKey: key)
    }
}

/// Labels synced across the user's devices through iCloud key-value storage (key `label.<id>`).
/// Labels are trimmed and capped at 40 characters; an empty or whitespace-only label removes the entry.
final class ICloudLabelStore: LabelStore {
    static let maxLength = 40

    /// `NSUbiquitousKeyValueStore` is not `Sendable`; all access goes through this lock.
    private let store: Mutex<any UbiquitousKeyValueStoring>
    private let notificationCenter: NotificationCenter

    init(keyValueStore: sending any UbiquitousKeyValueStoring = NSUbiquitousKeyValueStore.default,
         notificationCenter: NotificationCenter = .default) {
        keyValueStore.synchronize()
        self.store = Mutex(keyValueStore)
        self.notificationCenter = notificationCenter
    }

    func label(for id: TVID) -> String? {
        store.withLock { $0.string(forKey: Self.key(for: id)) }
    }

    func setLabel(_ s: String?, for id: TVID) {
        let trimmed = String((s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxLength))
        let key = Self.key(for: id)
        store.withLock { kvs in
            if trimmed.isEmpty {
                kvs.removeObject(forKey: key)
            } else {
                kvs.set(trimmed, forKey: key)
            }
        }
    }

    var changes: AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observer = ChangeObserver(continuation: continuation)
        let center = notificationCenter
        center.addObserver(observer, selector: #selector(ChangeObserver.storeDidChange(_:)),
                           name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: nil)
        continuation.onTermination = { _ in center.removeObserver(observer) }
        return stream
    }

    private static func key(for id: TVID) -> String {
        "label.\(id.rawValue)"
    }
}

/// Forwards external-change notifications into a stream. Immutable and holding only a Sendable
/// continuation, so it is genuinely `Sendable` and can be removed from `onTermination`.
private final class ChangeObserver: NSObject, Sendable {
    private let continuation: AsyncStream<Void>.Continuation

    init(continuation: AsyncStream<Void>.Continuation) {
        self.continuation = continuation
    }

    @objc func storeDidChange(_ notification: Notification) {
        continuation.yield()
    }
}
