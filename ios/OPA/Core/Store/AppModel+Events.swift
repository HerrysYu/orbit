import Foundation
import SwiftUI

// Inbound frames → state.

extension AppModel {
    func handle(_ m: InboundMessage) {
        switch m {
        case .ev(let seq, let ts, let k, let d):
            touchOnline()
            if seq > 0 {
                guard seq > lastSeq else { return }   // already have it
                lastSeq = seq
                localOrderCounter = 0                  // local sort keys are relative to the newest seq
                if !isDemo {
                    defaults.set(Int(seq), forKey: DefaultsKey.lastSeq)
                    persistence.append(seq: seq, ts: ts, k: k, d: d)
                }
            }
            apply(k: k, d: d, ts: ts, seq: seq, animated: true)
        case .live(let k, let d):
            touchOnline()
            applyLive(k: k, d: d)
        case .pairResult:
            break
        case .res, .unknown:
            break
        }
    }

    /// Applies one durable event. `seq` (0 when the event is not numbered) decides where a new timeline item goes;
    /// `animated` is true for live events and false when replaying the stored log.
    func apply(k: String, d: JSONValue, ts: Int64, seq: Int64 = 0, animated: Bool) {
        let work = { [self] in applyEvent(k: k, d: d, ts: ts, seq: seq, live: animated) }
        if animated { withAnimation(spring, work) } else { work() }
    }

    private func applyEvent(k: String, d: JSONValue, ts: Int64, seq: Int64, live: Bool) {
        switch k {
        case "msg.user":
            applyUserEcho(d, ts: ts, seq: seq)
        case "msg.assistant":
            applyAssistantFinal(d, ts: ts, seq: seq)
        case "ui.render":
            if let c = try? d["card"]?.decode(Card.self) {
                // Re-rendering a card keeps its place in the chat; only its content changes.
                timelineStore.upsert(.card(c), order: orderKey(seq: seq))
            }
        case "ui.patch":
            if let id = d["id"]?.string, let props = d["props"] {
                timelineStore.update("c:" + id) { item in
                    guard case .card(var c) = item else { return }
                    c.props = c.props.merging(props)
                    item = .card(c)
                }
            }
        case "task.upsert":
            if let t = try? d.decode(OPATask.self), !removedTaskIds.contains(t.id) {
                tasks[t.id] = t
                if !t.status.isActive, cancellingTaskIds.contains(t.id) { cancellingTaskIds.remove(t.id) }
                if live { liveActivities.update(task: t, butlerName: settings.butler.name) }
            }
        case "task.remove":
            applyTaskRemoval(ids: d["ids"]?.items.compactMap(\.string) ?? [])
        case "session.upsert":
            if let s = try? d.decode(OPASession.self) {
                if let taskId = s.taskId, removedTaskIds.contains(taskId) { break }
                sessions[s.id] = s
            }
        case "approval.request":
            if let a = try? d.decode(Approval.self) {
                approvals[a.id] = a
                if !isReplaying { rescheduleExpiry() }
            }
        case "approval.resolved":
            if let r = try? d.decode(ApprovalResolution.self) {
                resolvedApprovals[r.id] = r
                if !isReplaying { rescheduleExpiry() }
            }
        case "memory.changed":
            memoryRevision += 1
            if live { scheduleMemoryReload() }
        case "settings.changed":
            if let s = try? d.decode(Settings.self) { acceptServerSettings(s) }
        default:
            break
        }
    }

    /// Sort key for a new timeline item: its host `seq` when it has one, otherwise just after everything seen so far.
    func orderKey(seq: Int64) -> Double {
        seq > 0 ? Double(seq) : nextLocalOrder()
    }

    func nextLocalOrder() -> Double {
        localOrderCounter += 1
        return Double(lastSeq) + 0.5 + Double(localOrderCounter) * 1e-6
    }

    // MARK: Live events

    func applyLive(k: String, d: JSONValue) {
        switch k {
        case "msg.start":
            guard let id = d["id"]?.string, !timelineStore.contains("a:" + id) else { return }
            withAnimation(spring) { beginStreaming(id: id, proactive: d["proactive"]?.bool ?? false) }
        case "msg.delta":
            guard let id = d["id"]?.string, let text = d["text"]?.string else { return }
            appendStreamDelta(id: id, text: text)
        case "butler.status":
            withAnimation(spring) {
                let state = d["state"].flatMap { ButlerState(rawValue: $0.string ?? "") } ?? .idle
                butlerState = state
                let (detail, tool) = Self.friendlyStatus(detail: d["detail"]?.string, tool: d["tool"]?.string)
                butlerDetail = detail
                butlerTool = tool
            }
            if butlerState == .idle { scheduleStreamIdleCheck() }
        case "session.progress":
            if let sid = d["sessionId"]?.string, let t = d["text"]?.string {
                withAnimation(.easeInOut(duration: 0.2)) { sessionProgress[sid] = t }
            }
        default:
            break
        }
    }

    // MARK: butler.status wording

    /// `detail` is a phrase for people ("派出任务") and is shown as is. Early hosts put the raw tool name there
    /// (`codex_session_create`, `notify`): that must never reach the screen, so it becomes "处理中" and moves to `tool`.
    nonisolated static func friendlyStatus(detail: String?, tool: String?) -> (detail: String?, tool: String?) {
        guard let raw = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return (nil, tool) }
        if looksLikeToolName(raw) { return ("处理中", tool ?? raw) }
        return (raw, tool)
    }

    /// Only ASCII letters, digits and `_ - .`, no spaces: a tool name, not a sentence.
    nonisolated static func looksLikeToolName(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_-.".unicodeScalars.contains($0)) }
    }
}
