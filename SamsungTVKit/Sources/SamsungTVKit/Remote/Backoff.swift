/// Exponential reconnect delays: `base · 2^attempt`, capped at `max`.
public struct Backoff: Sendable {
    public let base: Duration
    public let max: Duration

    public init(base: Duration = .milliseconds(500), max: Duration = .seconds(30)) {
        self.base = base
        self.max = max
    }

    /// Delay before reconnect attempt `attempt` (0-based; negative values are treated as 0).
    public func delay(attempt: Int) -> Duration {
        var delay = base
        for _ in 0..<Swift.max(attempt, 0) {
            if delay >= max { break }
            delay *= 2
        }
        return Swift.min(delay, max)
    }
}
