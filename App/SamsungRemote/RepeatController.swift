import SamsungTVKit

/// Hold-to-repeat for one key at a time (volume, channel, arrows).
///
/// `.clickEvery(interval, initialDelay:)` sends a click at once, a second after `initialDelay` if the key is
/// still held (so a tap never doubles), then one every `interval` until `end()`;
/// `.pressRelease` sends a press on `begin` and the matching release on `end()`. `end()` is
/// idempotent; `begin` while a key is held ends that hold first.
@MainActor
final class RepeatController {
    private let clock: any Clock<Duration>
    private let strategy: RepeatStrategy
    private let send: (RemoteKey, KeyAction) async -> Void
    /// Called for every click after the first of a hold (the model counts them for haptics).
    var onRepeat: () -> Void = {}

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
        case .clickEvery(let interval, let initialDelay):
            let clock = clock // a local: opening the stored existential directly fails to type-check
            repeating = Task {
                await send(key, .click)
                var wait = initialDelay
                while !Task.isCancelled {
                    do {
                        try await clock.sleep(for: wait)
                    } catch {
                        return // cancelled by end()
                    }
                    guard !Task.isCancelled else { return }
                    onRepeat()
                    await send(key, .click)
                    wait = interval
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
