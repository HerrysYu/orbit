import Foundation
import SwiftUI

// Approvals: what is pending, what each one's status is, answering them.

extension AppModel {
    /// The Mac's clock now (Unix ms). Approval expiry (`expiresAt`) is a Mac timestamp, so it is compared with this
    /// rather than the phone's clock (`hostClockOffsetMs` comes from `ping` round trips).
    func hostNowMs() -> Int64 { nowMs() + hostClockOffsetMs }

    /// Approvals still waiting for an answer, newest first. Answered and expired ones are excluded.
    var pendingApprovals: [Approval] {
        _ = expiryTick   // re-read when an approval's expiry time passes
        let now = hostNowMs()
        return approvals.values
            .filter { resolvedApprovals[$0.id] == nil && !$0.isExpired(now: now) }
            .sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id < $1.id }
    }

    /// What to show for an approval: pending → submitting → approved / denied, or expired, or failed (retryable).
    func approvalStatus(_ id: String) -> ApprovalStatus {
        _ = expiryTick
        if submittingApprovals.contains(id) { return .submitting }
        if let r = resolvedApprovals[id] {
            if r.by == "timeout" { return .expired }
            return r.decision == "approve" ? .approved : .denied
        }
        if let a = approvals[id], a.isExpired(now: hostNowMs()) { return .expired }
        if let failure = approvalFailures[id] { return .failed(failure) }
        return .pending
    }

    /// Answers an approval. Returns true when the host accepted the answer.
    ///
    /// Guards: a second tap while the first is in flight (including the Face ID prompt) is ignored; an approval that
    /// is already answered or has expired is not sent. A failure keeps the approval open with `.failed(message)`.
    @discardableResult
    func respond(approval: Approval, approve: Bool, note: String? = nil) async -> Bool {
        let id = approval.id
        guard !submittingApprovals.contains(id) else { return false }
        switch approvalStatus(id) {
        case .approved, .denied: return false
        case .expired:
            showToast("这条确认已过期，请回到任务查看最新请求")
            return false
        case .pending, .failed, .submitting: break
        }
        submittingApprovals.insert(id)
        approvalFailures[id] = nil
        defer { submittingApprovals.remove(id) }

        if approve, approval.requireBiometric {
            guard await Biometrics.authenticate(reason: "批准：\(approval.title)") else { return false }
            if approval.isExpired(now: hostNowMs()) {   // the prompt may have been up for a while
                showToast("这条确认已过期，请回到任务查看最新请求")
                return false
            }
        }
        var d: JSONValue = ["approvalId": .string(id), "decision": .string(approve ? "approve" : "deny")]
        if let note, !note.isEmpty, case .object(var o) = d { o["note"] = .string(note); d = .object(o) }
        do {
            try await request("approval.respond", d)
            withAnimation(spring) {
                resolvedApprovals[id] = ApprovalResolution(id: id, decision: approve ? "approve" : "deny", by: "user")
            }
            rescheduleExpiry()
            return true
        } catch {
            approvalFailures[id] = error.localizedDescription
            showToast(error.localizedDescription)
            return false
        }
    }

    // MARK: Expiry timer

    /// Wakes the UI when the next pending approval expires, so buttons disable themselves and the badge drops.
    func rescheduleExpiry() {
        expiryTask?.cancel()
        let now = hostNowMs()
        let next = approvals.values
            .filter { resolvedApprovals[$0.id] == nil }
            .compactMap(\.expiresAt)
            .filter { $0 > now }
            .min()
        guard let next else { return }
        let delay = Double(next - now) / 1000 + 0.05
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.expiryTick += 1
            self.rescheduleExpiry()
        }
    }
}
