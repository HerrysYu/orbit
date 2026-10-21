// Wires everything together and implements the app `req` methods — protocol.md §4.2.
import { Db } from './store/db.ts';
import { EventLog } from './store/events.ts';
import { CodexBridge } from './codex/bridge.ts';
import { Gateway } from './gateway/gateway.ts';
import { Identity } from './gateway/identity.ts';
import { Butler } from './butler/butler.ts';
import { isFinishedTask } from './butler/state.ts';
import { EFFORT_SETTING_KEYS, parseEffortSetting } from './butler/effort.ts';
import { PhoneStatusProbe } from './phone/status.ts';
import type { DeviceContext, ImportItem, Settings } from './types.ts';
import { log } from './util/log.ts';

export interface HostConfig { port: number; relayUrl?: string; bundleId: string }

/** What `push.register` accepts as the app's own bundle id (it becomes the APNs topic). */
const BUNDLE_ID_RE = /^[A-Za-z0-9.-]{1,155}$/;

export function loadConfig(db: Db): HostConfig {
  return {
    port: Number(process.env.OPA_PORT ?? db.get<number>('config.port') ?? 7420),
    relayUrl: process.env.OPA_RELAY_URL ?? db.get<string>('config.relayUrl') ?? undefined,
    bundleId: db.get<string>('config.bundleId') ?? 'com.haoyuanyu.orbit',
  };
}

export class Host {
  readonly db: Db;
  readonly ev: EventLog;
  readonly id: Identity;
  readonly cfg: HostConfig;
  readonly bridge: CodexBridge;
  readonly gw: Gateway;
  readonly butler: Butler;
  readonly phoneProbe = new PhoneStatusProbe();

  /** `parts` is a test seam (in-memory Db, fake bridge); the CLI always calls `new Host()`. */
  constructor(parts: { db?: Db; bridge?: CodexBridge } = {}) {
    this.db = parts.db ?? new Db();
    this.ev = new EventLog(this.db);
    this.id = new Identity(this.db);
    this.cfg = loadConfig(this.db);
    this.bridge = parts.bridge ?? new CodexBridge();
    this.gw = new Gateway(this.id, this.db, this.ev, this.cfg);
    this.butler = new Butler(this.db, this.ev, this.bridge, this.gw);
  }

  async start() {
    this.gw.handler = (deviceId, m, d) => this.handle(deviceId, m, d);
    this.gw.start();
    await this.bridge.start().catch((e) => log.error('codex', 'failed to start codex app-server:', e?.message ?? e));
    this.butler.start();
    log.info('host', `hostId ${this.id.hostId} · ${this.id.devices().length} paired device(s)`);
  }

  /** Dispatches one app `req` (protocol.md §4.2). Public so tests can drive it without a gateway. */
  async handle(deviceId: string, m: string, d: any): Promise<unknown> {
    const b = this.butler;
    switch (m) {
      case 'sync': return {}; // gateway handles the replay
      case 'ping': return { ts: Date.now() };
      case 'chat.send': return this.chatSend(d);
      case 'chat.clear': return b.clearChat();
      case 'chat.interrupt': b.interrupt(); return {};
      case 'ui.action': b.uiAction(String(d.cardId), String(d.actionId), d.value); return {};
      case 'approval.respond': b.approvalResponse(String(d.approvalId), d.decision === 'approve', d.note); return {};
      case 'task.cmd': return this.taskCmd(d);
      case 'tasks.clear': return this.tasksClear(d);
      case 'session.detail': {
        const session = b.state.session(d.sessionId);
        const items = b.phone.has(d.sessionId) ? b.phone.history(d.sessionId) : await this.bridge.recentItems(d.sessionId, 60).catch(() => []);
        return { session, items };
      }
      case 'context.update': {
        const ctx = { ...(d as DeviceContext), now: d.now ?? Date.now() };
        this.db.set('device.context', ctx);
        return {};
      }
      case 'import.add': {
        const items: ImportItem[] = (d.items ?? []).slice(0, 50);
        const ids = b.state.addImports(items);
        b.importsAdded(ids, items.map((i) => i.kind));
        return { ids };
      }
      case 'settings.get': return b.settings();
      case 'settings.set': {
        const cur = b.settings();
        // The effort names are checked before anything is stored, so a bad one changes nothing (the app rolls its picker back);
        // null counts as 自动 and is stored as ''.
        const sent = d.models && typeof d.models === 'object' ? d.models : {};
        const efforts = Object.fromEntries(EFFORT_SETTING_KEYS.filter((k) => k in sent).map((k) => [k, parseEffortSetting(sent[k])]));
        const next: Settings = {
          ...cur, ...d,
          butler: { ...cur.butler, ...d.butler }, models: { ...cur.models, ...d.models, ...efforts }, quietHours: { ...cur.quietHours, ...d.quietHours },
        };
        this.db.set('settings', next);
        if (d.heartbeatMinutes) b.armHeartbeat();
        this.ev.emitEv('settings.changed', next);
        return next;
      }
      case 'models.list': {
        // Bot and Codex sub-agents both run on Codex now, so both lists come from Codex's model/list.
        // `efforts` = the reasoning efforts a model supports (may be empty), `defaultEffort` = its own default (optional).
        const list = await b.models.list(true);
        return { butler: list, codex: list.map(({ id, displayName, isDefault, efforts, defaultEffort }) => ({ id, displayName, isDefault, efforts, defaultEffort })) };
      }
      case 'memory.list': return { items: b.memory.list() };
      case 'memory.add': { const mem = b.memory.write(String(d.text), d.kind ?? 'fact', 'explicit'); this.ev.emitEv('memory.changed', {}); return mem; }
      case 'memory.delete': b.memory.delete(String(d.id)); this.ev.emitEv('memory.changed', {}); return {};
      case 'push.register': {
        // `bundleId` (optional) is the app's own bundle id and decides the APNs topic; a value that isn't a plausible one is ignored.
        const bundleId = typeof d.bundleId === 'string' && BUNDLE_ID_RE.test(d.bundleId) ? d.bundleId : null;
        this.db.sql.prepare(`INSERT INTO push_tokens(device_id, kind, token, env, activity_id, task_id, bundle_id, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(device_id, kind, token) DO UPDATE SET env = excluded.env, activity_id = excluded.activity_id, task_id = excluded.task_id,
            bundle_id = excluded.bundle_id, updated_at = excluded.updated_at`)
          .run(deviceId, String(d.kind), String(d.token), d.env === 'production' ? 'production' : 'sandbox', d.activityId ?? null, d.taskId ?? null, bundleId, Date.now());
        if (d.kind !== 'liveactivity') {
          // Keep only the latest alert / pushToStart token per device.
          this.db.sql.prepare('DELETE FROM push_tokens WHERE device_id = ? AND kind = ? AND token != ?').run(deviceId, d.kind, d.token);
        }
        return {};
      }
      case 'devices.list': return { devices: this.id.devices().map(({ pub, ...rest }) => rest) };
      case 'phone.status': return this.phoneProbe.status();
      default: throw new Error(`unknown method ${m}`);
    }
  }

  /** `chat.send`, idempotent by `clientId`: the app resends after a reconnect, and Orbit must not see the same message twice. */
  private chatSend(d: any): { msgId: string; duplicate?: true } {
    const clientId = String(d.clientId ?? '');
    if (clientId) {
      const seen = this.db.sql.prepare('SELECT msg_id FROM client_msgs WHERE client_id = ?').get(clientId) as { msg_id: string } | undefined;
      if (seen) return { msgId: seen.msg_id, duplicate: true };
    }
    if (this.butler.isChatClearing()) throw new Error('chat.clear is in progress; retry chat.send');
    const msgId = this.butler.userMessage(String(d.text ?? ''), clientId, d.attachments ?? []);
    if (clientId) this.db.sql.prepare('INSERT OR IGNORE INTO client_msgs(client_id, msg_id, ts) VALUES (?, ?, ?)').run(clientId, msgId, Date.now());
    return { msgId };
  }

  /**
   * `tasks.clear {ids?}` — removes finished tasks (done / failed / cancelled) and archives the Codex sessions they spawned.
   * No `ids` = every finished task. With `ids`, only finished ones go; active or unknown ids come back in `skipped`
   * (an empty `ids` array therefore clears nothing).
   *
   * Everything the app can observe — rows deleted, `task.remove` sent, the sessions marked `archived` — happens
   * synchronously, and the reply goes out right away. Asking Codex to archive the threads (interrupt + archive, up to
   * 120 s per RPC when Codex is sluggish) is background work that nobody waits for: the app gives `tasks.clear` only ~20 s.
   */
  private tasksClear(d: any): { removed: string[]; skipped: string[] } {
    const b = this.butler;
    if (d?.ids != null && !Array.isArray(d.ids)) throw new Error('tasks.clear: ids must be an array of task ids');
    const targets: string[] = [];
    const skipped: string[] = [];
    if (d?.ids == null) targets.push(...b.state.finishedTasks().map((t) => t.id));
    else {
      for (const id of new Set<string>(d.ids.map(String))) {
        const t = b.state.task(id);
        (t && isFinishedTask(t) ? targets : skipped).push(id);
      }
    }
    // Check and delete happen in one synchronous stretch, so a task can't flip back to active in between.
    const removed = b.state.removeTasks(targets);
    const sessions = b.state.sessionsOfTasks(removed);
    for (const s of sessions) b.syncSession(s.id, { status: 'archived' });
    for (const s of sessions) this.archiveThread(s.id);
    return { removed, skipped };
  }

  /** Fire and forget: asks Codex to archive the thread behind a session that is already marked archived. Never rejects. */
  private archiveThread(sessionId: string): void {
    void (async () => {
      try {
        await this.bridge.archive(sessionId);
      } catch (e: any) {
        log.debug('host', `codex could not archive ${sessionId}; it stays archived here: ${e?.message ?? e}`);
      }
      try {
        // Interrupting the thread makes the bridge report status changes, which the butler mirrors into state, and the
        // archive itself can fail halfway. Either way the last word for a cleared task's session is "archived" (a no-op,
        // with no event, when nothing moved).
        this.butler.syncSession(sessionId, { status: 'archived' });
      } catch (e: any) {
        log.debug('host', `could not re-mark ${sessionId} archived: ${e?.message ?? e}`);
      }
    })();
  }

  /** Phone runs (phone_ ids) are stopped by their runner; every other session is a Codex thread. */
  private async stopSession(id: string): Promise<boolean> {
    if (this.butler.phone.has(id)) return this.butler.phone.cancel(id);
    return this.bridge.interrupt(id);
  }

  private async taskCmd(d: any): Promise<unknown> {
    const b = this.butler;
    const sid: string | undefined = d.sessionId;
    switch (d.cmd) {
      case 'interrupt':
        if (sid) await this.stopSession(sid);
        else if (d.taskId) for (const s of b.state.sessions().filter((x) => x.taskId === d.taskId)) await this.stopSession(s.id).catch(() => {});
        b.push({ type: 'user_task_cmd', fromUser: true, body: `主人在任务页手动中止了 ${sid ? `session ${sid}` : `task ${d.taskId} 的所有 session`}。` });
        return {};
      case 'steer':
        if (!sid || !d.text) throw new Error('steer needs sessionId and text');
        await this.bridge.send(sid, String(d.text));
        b.push({ type: 'user_task_cmd', fromUser: true, body: `主人直接给 session ${sid} 发了指令：${d.text}` });
        return {};
      case 'archive':
        if (sid) { await this.stopSession(sid).catch(() => {}); await this.bridge.archive(sid).catch(() => {}); b.syncSession(sid, { status: 'archived' }); }
        return {};
      case 'cancel':
        if (d.taskId) {
          for (const s of b.state.sessions().filter((x) => x.taskId === d.taskId)) await this.stopSession(s.id).catch(() => {});
          b.state.updateTask(d.taskId, { status: 'cancelled' });
          b.push({ type: 'user_task_cmd', fromUser: true, body: `主人取消了 task ${d.taskId}。停止相关工作和闹钟。` });
        }
        return {};
      default: throw new Error(`unknown task cmd ${d.cmd}`);
    }
  }
}
