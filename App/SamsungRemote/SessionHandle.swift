import Foundation
import SamsungTVKit

/// One session to one TV address, with its observers and a serial queue of work, so a connect,
/// key presses and the final disconnect reach the session in the order they were issued.
@MainActor
final class SessionHandle {
    let host: String
    let session: any RemoteSessionProtocol
    var observers: [Task<Void, Never>] = []
    private var tail: Task<Void, Never>?

    /// `after` is work that must finish before this session's first operation (the previous
    /// session's disconnect).
    init(host: String, session: any RemoteSessionProtocol, after: Task<Void, Never>?) {
        self.host = host
        self.session = session
        tail = after
    }

    @discardableResult
    func enqueue<T: Sendable>(
        _ operation: @escaping @MainActor (any RemoteSessionProtocol) async -> T
    ) -> Task<T, Never> {
        let previous = tail, session = session
        let task = Task {
            await previous?.value
            return await operation(session)
        }
        tail = Task { _ = await task.value }
        return task
    }

    /// Stops observing and disconnects after any queued work. Returns the disconnect task.
    func close() -> Task<Void, Never> {
        for observer in observers { observer.cancel() }
        observers = []
        return enqueue { await $0.disconnect() }
    }
}

/// The `PowerKeySending` the power controller gets: routes its key through the app's session
/// handle instead of touching the session directly.
struct HandlePowerSender: PowerKeySending {
    let send: @MainActor @Sendable (RemoteKey, Duration) async throws(SessionError) -> Void

    func sendEnsuringConnection(_ key: RemoteKey, timeout: Duration) async throws(SessionError) {
        try await send(key, timeout)
    }
}
