import Foundation
import SamsungTVKit

extension AppModel {
    // MARK: - Power

    func togglePower() {
        guard !powerBusy else { return }
        guard let id = selectedID, let tv = registry.tvs[id] else {
            statusEvent = .chooseTVFirst
            return
        }
        if current == nil {
            // No session, e.g. Wi-Fi was lost: check again, reconnecting if Wi-Fi is back.
            refresh()
        }
        guard let handle = current else {
            statusEvent = onWiFi ? .unreachable : .notOnWiFi
            return
        }
        powerBusyTVs.insert(id)
        statusEvent = nil
        // Show the likely direction at once (the plan, after checking the TV, may correct it), so the line
        // never shows a stale message in between.
        powerDirections[id] = isConnected && !selectedTurnedOff ? .turningOff : .turningOn
        let power = powerController(for: id), sender = powerSender(for: handle)
        let onPlan: @Sendable (PowerAction) async -> Void = { [weak self] action in
            await self?.powerPlanned(action, for: id)
        }
        Task { [weak self] in
            let outcome = await power.togglePower(tv: tv, sender: sender, onPlan: onPlan)
            guard let self else { return }
            self.powerBusyTVs.remove(id)
            self.powerDirections[id] = nil
            // Only report on the TV still selected.
            guard let outcome, id == self.selectedID, let current = self.current else { return }
            self.powerFinished(outcome, tv: id, on: current)
        }
    }

    private func powerPlanned(_ action: PowerAction, for id: TVID) {
        guard powerBusyTVs.contains(id) else { return }
        powerDirections[id] = action == .turnOff ? .turningOff : .turningOn
    }

    /// Sends the power controller's key through `handle`'s queue (after its earlier work and every
    /// earlier teardown), and refuses with `.unreachable` once `handle` is closed or replaced, so a
    /// late toggle never revives a session the app already closed.
    private func powerSender(for handle: SessionHandle) -> HandlePowerSender {
        HandlePowerSender { [weak self, weak handle] (key: RemoteKey, timeout: Duration) throws(SessionError) in
            guard let self, let handle else { throw .unreachable }
            try await self.sendPowerKey(key, timeout: timeout, on: handle)
        }
    }

    private func sendPowerKey(_ key: RemoteKey, timeout: Duration, on handle: SessionHandle) async throws(SessionError) {
        guard handle === current else { throw .unreachable }
        let result = await handle.enqueue { [weak self] session -> Result<Void, SessionError> in
            // Checked again once the queue reaches this work: the session may have closed meanwhile.
            guard let self, handle === self.current else { return .failure(.unreachable) }
            do throws(SessionError) {
                try await session.sendEnsuringConnection(key, timeout: timeout)
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
        try result.get()
    }

    private func powerController(for id: TVID) -> any PowerToggling {
        if let existing = powerControllers[id] { return existing }
        let controller = env.makePowerController()
        powerControllers[id] = controller
        return controller
    }

    private func powerFinished(_ outcome: PowerOutcome, tv id: TVID, on handle: SessionHandle) {
        switch outcome {
        case .turnedOff:
            turnedOffTVs.insert(id)
            rebuildTVs()
            refresh()
        case .turnedOn:
            turnedOffTVs.remove(id)
            if sessionState != .connected { openSession(id) }
            refresh()
        case .failedToWake:
            statusEvent = .notTurnedOn
        case .noMACKnown:
            statusEvent = .wakeAddressUnknown
        case .notOnWiFi:
            statusEvent = .notOnWiFi
        case .failed(.identityChanged):
            sessionStateChanged(.failed(.identityChanged), on: handle)
        case .failed(.denied):
            sessionStateChanged(.failed(.denied), on: handle)
        case .failed(.unreachable), .failed(.approvalTimedOut):
            statusEvent = .unreachable
        }
    }
}
