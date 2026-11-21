import Foundation
import SamsungTVKit

extension AppModel {
    // MARK: - Watching a TV that isn't connected

    /// The app is in front on Wi-Fi and the selected TV's session is connected (to notice the TV turning
    /// off), has failed as unreachable (off, or still booting after Power) or is retrying after a drop.
    /// Pairing, denials and approval timeouts are excluded: reconnecting would prompt on the TV again.
    private var shouldWatchSelected: Bool {
        guard appeared, !inBackground, onWiFi, selectedID != nil else { return false }
        switch sessionState {
        case .connected, .connecting, .failed(.unreachable): return true
        case .idle, .awaitingApproval, .failed(.approvalTimedOut), .failed(.denied), .failed(.identityChanged):
            return false
        }
    }

    func updateWatch() {
        if shouldWatchSelected {
            if watchTask == nil { startWatch() }
        } else {
            watchTask?.cancel()
            watchTask = nil
            watchFoundNoAnswer = false
        }
    }

    /// Every `watchInterval`, asks the selected TV for its info (one small local HTTP request) and
    /// `watchChecked`s the answer. Ends once there is nothing to watch.
    private func startWatch() {
        let clock = env.clock
        let fetcher = env.fetcher
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: Self.watchInterval)
                } catch {
                    return // cancelled
                }
                guard let self, self.shouldWatchSelected, let id = self.selectedID,
                      let host = self.registry.tvs[id]?.lastHost else {
                    self?.watchTask = nil
                    return
                }
                if self.powerBusy { continue } // the power toggle is already checking
                if self.sessionState == .connecting { self.connectingTicks += 1 }
                let info = try? await fetcher.fetchInfo(host: host)
                guard !Task.isCancelled, self.selectedID == id, self.shouldWatchSelected else { continue }
                self.watchChecked(info, for: id)
            }
        }
    }

    /// Acts on one watch check of the selected TV. An answer updates its status (as a scan would); when it
    /// is on, a failed session reconnects and a stalled attempt restarts; standby while connected marks it
    /// off. No answer while retrying is shown instead of an endless "Connecting…", and a connected TV that
    /// stops answering gets a fresh connection, which fails fast if it is really gone.
    private func watchChecked(_ info: TVDeviceInfo?, for id: TVID) {
        guard let info, info.id == id else {
            missedChecks += 1
            rescanIfSelectedTVMissing()
            switch sessionState {
            case .connecting:
                watchFoundNoAnswer = true
            case .connected:
                missedWhileConnected += 1
                if missedWhileConnected >= Self.missedChecksBeforeReconnect {
                    missedWhileConnected = 0
                    openSession(id)
                }
            default:
                break
            }
            return
        }
        watchFoundNoAnswer = false
        missedWhileConnected = 0
        resetMissingTVRescan()
        handle(.found(info)) // reconnects a failed session when the TV is on; clears "off" when on
        if info.powerState != .on, sessionState == .connected, !selectedTurnedOff {
            // Turned off with its own remote into network standby: the connection may stay open.
            turnedOffTVs.insert(id)
            rebuildTVs()
        }
        if info.powerState == .on, sessionState == .connecting, connectingTicks >= Self.stalledConnectTicks {
            connectingTicks = 0
            openSession(id)
        }
    }

    /// The selected TV has missed `missedChecksBeforeRescan` checks in a row: it may have moved to another
    /// address, so scan with the subnet sweep, once until the TV answers, another TV is selected or the app
    /// returns from the background or to Wi-Fi (a TV that is simply off would otherwise sweep over and
    /// over). Skipped while the TV is one this app just turned off: it is expected not to answer. Shows no
    /// Scan Again feedback.
    private func rescanIfSelectedTVMissing() {
        guard missedChecks >= Self.missedChecksBeforeRescan, !missingTVRescanDone, !scanning,
              !selectedTurnedOff else { return }
        missingTVRescanDone = true
        startScan(sweepAnyway: true)
    }

    func resetMissingTVRescan() {
        missedChecks = 0
        missingTVRescanDone = false
    }
}
