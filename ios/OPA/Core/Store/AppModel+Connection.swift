import Foundation
import SwiftUI

// Presence line, connection info, connection state handling, the Mac's clock.

extension AppModel {
    // MARK: Presence

    /// The one-line "what Orbit is doing" + mascot pose. Priority: Mac offline → approvals waiting → streaming a reply
    /// → executing → thinking → idle. See `Presence.resolve`. The wording is fixed per state; nothing the model or an
    /// execution session reports (tool names, progress lines) reaches it.
    var presence: Presence {
        Presence.resolve(.init(connection: connection,
                               isDemo: isDemo,
                               lastSeenOnlineAt: connection.isConnected ? nil : lastSeenOnlineAt,   // not read while connected: no re-render per pong
                               pendingApprovalCount: pendingApprovals.count,
                               isStreaming: hasStreamingMessage,
                               butlerState: butlerState,
                               hasRunningWork: hasRunningExecution,
                               now: Date()))
    }

    /// An execution session is running for a task that is still going (or for no task at all). A session whose task
    /// has finished is not really running, whatever its last status says.
    var hasRunningExecution: Bool {
        sessions.values.contains { s in
            guard s.status == .running else { return false }
            guard let taskId = s.taskId, let task = tasks[taskId] else { return true }
            return task.status == .running || task.status == .planning
        }
    }

    // MARK: Connection info

    /// Host name, transport path, and when the Mac was last connected / seen — for the connection sheet.
    var connectionInfo: ConnectionInfo {
        ConnectionInfo(hostName: hostName, path: connection.path, lastConnectedAt: lastConnectedAt,
                       lastSeenOnlineAt: lastSeenOnlineAt, state: connection)
    }

    func connectionStateChanged(_ s: ConnectionState) {
        let wasConnected = connection.isConnected
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            connection = s
            if case .awaitingPairConfirm(let sas, _) = s { pairingSAS = sas }
            if case .failed(let m) = s, pairedHost == nil { pairingError = m }
            hostName = connectionManager.hostName ?? hostName
        }
        if s.isConnected {
            let now = Date()
            lastConnectedAt = now
            lastSeenOnlineAt = now
            persistConnectionTimes()
        } else if wasConnected {
            persistConnectionTimes()
            connectionLost()
        }
    }

    /// The connection dropped: whatever the bot was doing is no longer visible to us, and a reply that was streaming
    /// will not finish. (The final text, if the Mac completed it, comes with the next sync.)
    func connectionLost() {
        finishAllStreaming()
        butlerState = .idle
        butlerDetail = nil
        butlerTool = nil
    }

    /// Something just arrived from the Mac.
    func touchOnline() {
        guard connection.isConnected else { return }
        let now = Date()
        if let last = lastSeenOnlineAt, now.timeIntervalSince(last) < 1 { return }
        lastSeenOnlineAt = now
    }

    func persistConnectionTimes() {
        guard !isDemo else { return }
        if let lastConnectedAt { defaults.set(lastConnectedAt.timeIntervalSince1970, forKey: DefaultsKey.lastConnectedAt) }
        if let lastSeenOnlineAt { defaults.set(lastSeenOnlineAt.timeIntervalSince1970, forKey: DefaultsKey.lastSeenOnlineAt) }
    }

    // MARK: Mac clock

    /// A heartbeat answer: proof of life, and a sample of the Mac's clock.
    func recordPong(_ sample: PongSample) {
        touchOnline()
        recordClockSample(hostTs: sample.hostTs, sentAt: sample.sentAt, receivedAt: sample.receivedAt)
    }

    /// One `ping` right after the handshake, so approval expiry is judged on the Mac's clock from the start.
    func calibrateHostClock() async {
        let sent = Clock.nowMs
        guard let res = try? await request("ping", [:], timeout: .seconds(5)) else { return }
        recordClockSample(hostTs: res["ts"]?.int64, sentAt: sent, receivedAt: Clock.nowMs)
    }

    func recordClockSample(hostTs: Int64?, sentAt: Int64, receivedAt: Int64) {
        guard let hostTs, receivedAt >= sentAt, receivedAt - sentAt < 3_000 else { return }
        let offset = hostTs - (sentAt + receivedAt) / 2
        if abs(offset - hostClockOffsetMs) >= 1_000 {   // ignore jitter; only real clock differences matter
            hostClockOffsetMs = offset
            expiryTick += 1
            rescheduleExpiry()
        }
    }
}
