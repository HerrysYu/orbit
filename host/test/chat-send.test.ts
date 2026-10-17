// `chat.send` is idempotent by clientId (protocol.md §4.2): a retry must not reach the bot a second time.
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { Host } from '../src/app.ts';
import { CodexBridge } from '../src/codex/bridge.ts';
import { CodexRpc } from '../src/codex/rpc.ts';
import { Db } from '../src/store/db.ts';
import type { Ev } from '../src/store/events.ts';

describe('chat.send idempotency', () => {
  const cleanups: (() => void)[] = [];
  afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

  /** A Host over `db` whose bot never wakes up (push is stubbed) — only the handler and the msg.user event matter here. */
  function makeHost(db = new Db(':memory:')) {
    const bridge = new CodexBridge(new CodexRpc(process.execPath, []));
    const host = new Host({ db, bridge });
    const push = vi.spyOn(host.butler, 'push').mockImplementation(() => {});
    const userMessage = vi.spyOn(host.butler, 'userMessage');
    const userEvents: Ev[] = [];
    host.ev.on('ev', (e: Ev) => { if (e.k === 'msg.user') userEvents.push(e); });
    cleanups.push(() => { host.butler.scheduler.stop(); bridge.rpc.stop(); });
    const send = (d: object) => host.handle('dev1', 'chat.send', d) as Promise<{ msgId: string; duplicate?: boolean }>;
    return { host, db, push, userMessage, userEvents, send };
  }

  it('first send goes to the bot and replies { msgId } only', async () => {
    const { send, push, userEvents, userMessage } = makeHost();
    const res = await send({ clientId: 'c1', text: '帮我订周六的日料' });
    expect(res).toEqual({ msgId: expect.stringMatching(/^u_/) });
    expect('duplicate' in res).toBe(false);
    expect(userMessage).toHaveBeenCalledTimes(1);
    expect(push).toHaveBeenCalledTimes(1);
    expect(userEvents).toHaveLength(1);
    expect(userEvents[0].d).toMatchObject({ id: res.msgId, clientId: 'c1', text: '帮我订周六的日料' });
  });

  it('a repeated clientId returns the existing msgId and never reaches the bot again', async () => {
    const { send, push, userEvents, userMessage, db } = makeHost();
    const first = await send({ clientId: 'c1', text: 'hello' });
    // The retry may even carry different text (e.g. an edited draft) — the clientId alone decides.
    const again = await send({ clientId: 'c1', text: 'hello (retry)' });
    const third = await send({ clientId: 'c1', text: 'hello', attachments: [{ kind: 'link', url: 'https://example.com' }] });

    expect(again).toEqual({ msgId: first.msgId, duplicate: true });
    expect(third).toEqual({ msgId: first.msgId, duplicate: true });
    expect(userMessage).toHaveBeenCalledTimes(1);
    expect(push).toHaveBeenCalledTimes(1);
    expect(userEvents).toHaveLength(1);
    expect(db.sql.prepare('SELECT client_id, msg_id FROM client_msgs').all()).toEqual([{ client_id: 'c1', msg_id: first.msgId }]);
  });

  it('different clientIds are different messages', async () => {
    const { send, userMessage, userEvents } = makeHost();
    const a = await send({ clientId: 'c1', text: 'one' });
    const b = await send({ clientId: 'c2', text: 'one' });
    expect(b.msgId).not.toBe(a.msgId);
    expect(b.duplicate).toBeUndefined();
    expect(userMessage).toHaveBeenCalledTimes(2);
    expect(userEvents.map((e) => (e.d as { clientId: string }).clientId)).toEqual(['c1', 'c2']);
  });

  it('a missing or empty clientId cannot be de-duplicated and is never recorded', async () => {
    const { send, userMessage, db } = makeHost();
    const a = await send({ text: 'no id' });
    const b = await send({ text: 'no id' });
    const c = await send({ clientId: '', text: 'empty id' });
    const d = await send({ clientId: '', text: 'empty id' });
    expect(new Set([a.msgId, b.msgId, c.msgId, d.msgId]).size).toBe(4);
    expect([a, b, c, d].some((r) => r.duplicate)).toBe(false);
    expect(userMessage).toHaveBeenCalledTimes(4);
    expect(db.sql.prepare('SELECT COUNT(*) AS n FROM client_msgs').get()).toEqual({ n: 0 });
  });

  it('remembers clientIds across a host restart', async () => {
    const first = makeHost();
    const sent = await first.send({ clientId: 'c-persist', text: 'hi' });

    // Same database, brand new Host: what the app sees after `opa start` again.
    const second = makeHost(first.db);
    const retry = await second.send({ clientId: 'c-persist', text: 'hi' });
    expect(retry).toEqual({ msgId: sent.msgId, duplicate: true });
    expect(second.userMessage).not.toHaveBeenCalled();
    expect(second.userEvents).toHaveLength(0);
  });

  it('works for the local control socket too (deviceId is irrelevant)', async () => {
    const { host, userMessage } = makeHost();
    const a = await host.handle('local-cli', 'chat.send', { clientId: '1760000000000', text: 'hi' }) as { msgId: string };
    const b = await host.handle('dev1', 'chat.send', { clientId: '1760000000000', text: 'hi' });
    expect(b).toEqual({ msgId: a.msgId, duplicate: true });
    expect(userMessage).toHaveBeenCalledTimes(1);
  });
});

describe('client_msgs table', () => {
  it('is added to a database created before it existed, and opening twice is harmless', () => {
    const dir = mkdtempSync(join(tmpdir(), 'opa-wp0-db-'));
    const path = join(dir, 'old.sqlite');
    try {
      const legacy = new DatabaseSync(path);
      legacy.exec('CREATE TABLE kv (key TEXT PRIMARY KEY, value TEXT NOT NULL); INSERT INTO kv VALUES (\'k\', \'"v"\');');
      legacy.close();

      for (let i = 0; i < 2; i++) {
        const db = new Db(path);
        expect(db.get('k')).toBe('v'); // old data untouched
        expect(db.sql.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'client_msgs'").get()).toEqual({ name: 'client_msgs' });
        const cols = db.sql.prepare('PRAGMA table_info(client_msgs)').all() as { name: string; type: string; notnull: number; pk: number }[];
        expect(cols.map((c) => `${c.name}:${c.type}`)).toEqual(['client_id:TEXT', 'msg_id:TEXT', 'ts:INTEGER']);
        expect(cols.find((c) => c.name === 'client_id')!.pk).toBe(1);
        db.sql.close();
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
