public enum PowerAction: Equatable, Sendable {
    case turnOff, wakeFromStandby, wakeOnLAN
}

/// Decides what the power button does from a fresh info fetch.
public enum PowerPlanner {
    /// On → turn off; standby or unknown (the TV answers, so its network stack is up) → send the
    /// power key; unreachable → wake-on-LAN.
    public static func action(for result: Result<TVPowerState, TVInfoError>) -> PowerAction {
        switch result {
        case .success(.on): .turnOff
        case .success(.standby), .success(.unknown): .wakeFromStandby
        case .failure: .wakeOnLAN
        }
    }
}
