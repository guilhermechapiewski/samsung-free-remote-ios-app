import SamsungTVKit

/// Hold-to-repeat for one key at a time (volume, channel, arrows).
///
/// `.clickEvery(interval)` sends a click at once and then every `interval` until `end()`;
/// `.pressRelease` sends a press on `begin` and the matching release on `end()`. `end()` is
/// idempotent; `begin` while a key is held ends that hold first.
@MainActor
final class RepeatController {
    private let clock: any Clock<Duration>
    private let strategy: RepeatStrategy
    private let send: (RemoteKey, KeyAction) async -> Void

    /// The running `.clickEvery` loop.
    private var repeating: Task<Void, Never>?
    /// The key pressed under `.pressRelease`, awaiting its release.
    private var pressedKey: RemoteKey?
    /// Press/release sends run one after another, so a release never overtakes its press.
    private var tail: Task<Void, Never>?

    init(clock: any Clock<Duration>, strategy: RepeatStrategy, send: @escaping (RemoteKey, KeyAction) async -> Void) {
        self.clock = clock
        self.strategy = strategy
        self.send = send
    }

    func begin(_ key: RemoteKey) {
        end()
        switch strategy {
        case .pressRelease:
            pressedKey = key
            enqueue(key, .press)
        case .clickEvery(let interval):
            let clock = clock // a local: opening the stored existential directly fails to type-check
            repeating = Task {
                while !Task.isCancelled {
                    await send(key, .click)
                    do {
                        try await clock.sleep(for: interval)
                    } catch {
                        return // cancelled by end()
                    }
                }
            }
        }
    }

    func end() {
        repeating?.cancel()
        repeating = nil
        if let key = pressedKey {
            pressedKey = nil
            enqueue(key, .release)
        }
    }

    private func enqueue(_ key: RemoteKey, _ action: KeyAction) {
        let previous = tail
        tail = Task {
            await previous?.value
            await send(key, action)
        }
    }
}
