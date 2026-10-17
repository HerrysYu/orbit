// Push plumbing between the Host and the relay: the APNs topic comes from the app's own bundle id (protocol.md §4.2
// `push.register`), and tokens the relay reports as dead are dropped by push id (`push_result` carries no token).
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { Host } from '../src/app.ts';
import { CodexBridge } from '../src/codex/bridge.ts';
import { CodexRpc } from '../src/codex/rpc.ts';
import { Db } from '../src/store/db.ts';
import { log } from '../src/util/log.ts';

const DEFAULT_BUNDLE = 'com.haoyuanyu.orbit';

describe('push: topics and dead tokens', () => {
  const cleanups: (() => void)[] = [];
  afterEach(() => { while (cleanups.length) cleanups.pop()!(); vi.restoreAllMocks(); });

  /** A Host whose relay link is a stub: frames it sends land in `sent`, `fromRelay` delivers frames like the real relay would. */
  function rig(db = new Db(':memory:')) {
    const bridge = new CodexBridge(new CodexRpc(process.execPath, []));
    const host = new Host({ db, bridge });
    cleanups.push(() => { host.butler.scheduler.stop(); bridge.rpc.stop(); });
    const sent: any[] = [];
    (host.gw as any).relay = { send: (s: string) => sent.push(JSON.parse(s)) };
    (host.gw as any).relayConnected = true;
    const fromRelay = (f: object) => (host.gw as any).onRelayFrame(JSON.stringify(f));
    const register = (d: object, deviceId = 'dev1') => host.handle(deviceId, 'push.register', d);
    const rows = () => db.sql.prepare('SELECT device_id, kind, token, bundle_id FROM push_tokens ORDER BY device_id, kind, token').all() as
      { device_id: string; kind: string; token: string; bundle_id: string | null }[];
    const tokensLeft = () => rows().map((r) => r.token);
    const alert = () => host.gw.push({ pushType: 'alert', payload: { aps: { alert: 'hi' } } });
    return { host, db, sent, fromRelay, register, rows, tokensLeft, alert };
  }

  describe('topic = the app\'s own bundle id', () => {
    it('an alert push goes to the bundle id the app registered with', async () => {
      const { register, alert, sent } = rig();
      await register({ kind: 'alert', token: 'aa11', env: 'production', bundleId: 'com.example.other-app' });

      expect(alert()).toBe(1);
      expect(sent).toHaveLength(1);
      expect(sent[0]).toMatchObject({ relay: 'push', deviceToken: 'aa11', env: 'production', pushType: 'alert', topic: 'com.example.other-app' });
    });

    it('Live Activity and push-to-start pushes use the same bundle id plus .push-type.liveactivity', async () => {
      const { host, register, sent } = rig();
      await register({ kind: 'liveactivity', token: 'bb22', env: 'sandbox', taskId: 't1', activityId: 'act1', bundleId: 'com.example.other-app' });
      await register({ kind: 'pushToStart', token: 'cc33', env: 'sandbox', bundleId: 'com.example.other-app' });

      expect(host.gw.push({ pushType: 'liveactivity', kind: 'liveactivity', taskId: 't1', payload: {} })).toBe(1);
      expect(host.gw.push({ pushType: 'liveactivity', kind: 'pushToStart', payload: {} })).toBe(1);
      expect(sent.map((f) => [f.deviceToken, f.topic])).toEqual([
        ['bb22', 'com.example.other-app.push-type.liveactivity'],
        ['cc33', 'com.example.other-app.push-type.liveactivity'],
      ]);
    });

    it(`without a bundleId the configured one is used, and the default is ${DEFAULT_BUNDLE}`, async () => {
      const { host, register, alert, sent } = rig();
      expect(host.cfg.bundleId).toBe(DEFAULT_BUNDLE);

      await register({ kind: 'alert', token: 'aa11', env: 'sandbox' });
      await register({ kind: 'liveactivity', token: 'bb22', env: 'sandbox', taskId: 't1' });
      alert();
      host.gw.push({ pushType: 'liveactivity', taskId: 't1', payload: {} });
      expect(sent.map((f) => f.topic)).toEqual([DEFAULT_BUNDLE, `${DEFAULT_BUNDLE}.push-type.liveactivity`]);
    });

    it('`opa config bundle-id` replaces the default, but a bundle id the app reported still wins', async () => {
      const db = new Db(':memory:');
      db.set('config.bundleId', 'com.custom.configured');
      const { register, sent, host } = rig(db);
      await register({ kind: 'alert', token: 'aa11', env: 'sandbox' }, 'dev1');
      await register({ kind: 'alert', token: 'dd44', env: 'sandbox', bundleId: 'com.example.reported' }, 'dev2');

      expect(host.gw.push({ pushType: 'alert', payload: {} })).toBe(2);
      expect(Object.fromEntries(sent.map((f) => [f.deviceToken, f.topic]))).toEqual({ aa11: 'com.custom.configured', dd44: 'com.example.reported' });
    });

    it('ignores a bundleId that is not a valid bundle id (token still registers, default topic is used)', async () => {
      const bad: unknown[] = ['', 'has space', 'com.exam/ple', 'com.exämple.app', 'a'.repeat(156), 42, true, {}, ['com.example'], null];
      for (const bundleId of bad) {
        const { register, rows, alert, sent } = rig();
        await register({ kind: 'alert', token: 'aa11', env: 'sandbox', bundleId });
        expect(rows(), JSON.stringify(bundleId)).toEqual([{ device_id: 'dev1', kind: 'alert', token: 'aa11', bundle_id: null }]);
        alert();
        expect(sent[0].topic, JSON.stringify(bundleId)).toBe(DEFAULT_BUNDLE);
      }
    });

    it('accepts the whole allowed alphabet and length range', async () => {
      const longest = `${'a'.repeat(154)}.`; // 155 chars
      for (const bundleId of ['a', 'Com.Example-App.v2', longest]) {
        const { register, rows } = rig();
        await register({ kind: 'alert', token: 'aa11', env: 'sandbox', bundleId });
        expect(rows()[0].bundle_id).toBe(bundleId);
      }
    });

    it('registering the same token again updates its bundle id', async () => {
      const { register, rows, alert, sent } = rig();
      await register({ kind: 'alert', token: 'aa11', env: 'sandbox' });
      expect(rows()[0].bundle_id).toBeNull();
      await register({ kind: 'alert', token: 'aa11', env: 'sandbox', bundleId: 'com.example.first' });
      await register({ kind: 'alert', token: 'aa11', env: 'sandbox', bundleId: 'com.example.second' });

      expect(rows()).toEqual([{ device_id: 'dev1', kind: 'alert', token: 'aa11', bundle_id: 'com.example.second' }]);
      alert();
      expect(sent[0].topic).toBe('com.example.second');
    });
  });

  describe('push_result', () => {
    const quiet = () => ({ warn: vi.spyOn(log, 'warn').mockImplementation(() => {}), info: vi.spyOn(log, 'info').mockImplementation(() => {}) });
    const result = (f: { id: string; status: number; reason?: string }) => ({ relay: 'push_result', ...f });

    it.each([
      { status: 410, reason: 'Unregistered' },
      { status: 410 },
      { status: 410, reason: 'ExpiredToken' },
      { status: 400, reason: 'BadDeviceToken' },
    ])('drops exactly the token that push went to on $status $reason', async ({ status, reason }) => {
      quiet();
      const { register, alert, sent, fromRelay, tokensLeft } = rig();
      await register({ kind: 'alert', token: 'aa11', env: 'sandbox' }, 'dev1');
      await register({ kind: 'alert', token: 'dd44', env: 'sandbox' }, 'dev2');
      expect(alert()).toBe(2);

      const dead = sent.find((f) => f.deviceToken === 'aa11');
      fromRelay(result({ id: dead.id, status, reason }));
      expect(tokensLeft()).toEqual(['dd44']);
    });

    it('also drops the token on a bare BadDeviceToken / Unregistered / ExpiredToken reason, whatever the status', async () => {
      quiet();
      for (const reason of ['BadDeviceToken', 'Unregistered', 'ExpiredToken']) {
        const { register, alert, sent, fromRelay, tokensLeft } = rig();
        await register({ kind: 'alert', token: 'aa11', env: 'sandbox' });
        alert();
        fromRelay(result({ id: sent[0].id, status: 400, reason }));
        expect(tokensLeft(), reason).toEqual([]);
      }
    });

    it('keeps the token on success and on failures that say nothing about the token', async () => {
      quiet();
      for (const r of [{ status: 200 }, { status: 403, reason: 'InvalidProviderToken' }, { status: 429, reason: 'TooManyRequests' }, { status: 500, reason: 'InternalServerError' }, { status: 502, reason: 'fetch failed' }]) {
        const { register, alert, sent, fromRelay, tokensLeft } = rig();
        await register({ kind: 'alert', token: 'aa11', env: 'sandbox' });
        alert();
        fromRelay(result({ id: sent[0].id, ...r }));
        expect(tokensLeft(), JSON.stringify(r)).toEqual(['aa11']);
      }
    });

    it('DeviceTokenNotForTopic keeps the token and warns once, naming the topic and how to fix it', async () => {
      const { warn } = quiet();
      const { register, alert, sent, fromRelay, tokensLeft } = rig();
      await register({ kind: 'alert', token: 'aa11', env: 'sandbox', bundleId: 'com.example.wrong' });

      for (let i = 0; i < 3; i++) {
        alert();
        fromRelay(result({ id: sent.at(-1).id, status: 400, reason: 'DeviceTokenNotForTopic' }));
      }
      expect(tokensLeft()).toEqual(['aa11']);
      expect(warn).toHaveBeenCalledTimes(1);
      const [scope, message] = warn.mock.calls[0] as [string, string];
      expect(scope).toBe('push');
      expect(message).toContain('DeviceTokenNotForTopic');
      expect(message).toContain('com.example.wrong');
      expect(message).toContain('bundle-id');
    });

    it('ApnsNotConfigured keeps the token and warns once, pointing at relay/README.md', async () => {
      const { warn } = quiet();
      const { register, alert, sent, fromRelay, tokensLeft } = rig();
      await register({ kind: 'alert', token: 'aa11', env: 'sandbox' });

      for (let i = 0; i < 3; i++) {
        alert();
        fromRelay(result({ id: sent.at(-1).id, status: 500, reason: 'ApnsNotConfigured' }));
      }
      expect(tokensLeft()).toEqual(['aa11']);
      expect(warn).toHaveBeenCalledTimes(1);
      const message = String((warn.mock.calls[0] as unknown[])[1]);
      expect(message).toContain('Relay 还没配置 APNs 密钥（APNS_KEY_P8 / APNS_KEY_ID / APNS_TEAM_ID），见 relay/README.md');
    });

    it('other failures are still logged on every occurrence, as `APNs <status> <reason>`', async () => {
      const { warn } = quiet();
      const { register, alert, sent, fromRelay } = rig();
      await register({ kind: 'alert', token: 'aa11', env: 'sandbox' });
      for (let i = 0; i < 2; i++) {
        alert();
        fromRelay(result({ id: sent.at(-1).id, status: 403, reason: 'InvalidProviderToken' }));
      }
      expect(warn.mock.calls.map((c) => c.slice(1).join(' '))).toEqual(['APNs 403 InvalidProviderToken', 'APNs 403 InvalidProviderToken']);
    });

    it('a result for an id the host does not know (e.g. sent before a restart) or without an id changes nothing', async () => {
      quiet();
      const { register, fromRelay, tokensLeft } = rig();
      await register({ kind: 'alert', token: 'aa11', env: 'sandbox' });

      expect(() => {
        fromRelay({ relay: 'push_result', id: 'p999', status: 410, reason: 'Unregistered' });
        fromRelay({ relay: 'push_result', id: null, status: 400, reason: 'BadDeviceToken' });
        fromRelay({ relay: 'push_result', status: 410 });
      }).not.toThrow();
      expect(tokensLeft()).toEqual(['aa11']);
    });

    it('an answer is used up: replaying it later does not delete a token that registered again', async () => {
      quiet();
      const { register, alert, sent, fromRelay, tokensLeft } = rig();
      await register({ kind: 'alert', token: 'aa11', env: 'sandbox' });
      alert();
      const dead = result({ id: sent[0].id, status: 410, reason: 'Unregistered' });

      fromRelay(dead);
      expect(tokensLeft()).toEqual([]);
      await register({ kind: 'alert', token: 'aa11', env: 'sandbox' }); // the app comes back with the same token
      fromRelay(dead);
      expect(tokensLeft()).toEqual(['aa11']);
    });

    it('remembers at most 1000 outstanding pushes, forgetting the oldest first', async () => {
      quiet();
      const { db, host, sent, fromRelay, tokensLeft } = rig();
      const insert = db.sql.prepare('INSERT INTO push_tokens(device_id, kind, token, env, updated_at) VALUES (?, ?, ?, ?, ?)');
      for (let i = 0; i < 1001; i++) insert.run(`dev${i}`, 'alert', `tok${i}`, 'sandbox', 1);
      expect(host.gw.push({ pushType: 'alert', payload: {} })).toBe(1001);

      const [oldest, second] = sent; // 1001 pushes are in flight; the first one has been forgotten
      fromRelay(result({ id: oldest.id, status: 410, reason: 'Unregistered' }));
      expect(tokensLeft()).toHaveLength(1001);
      fromRelay(result({ id: second.id, status: 410, reason: 'Unregistered' }));
      expect(tokensLeft()).toHaveLength(1000);
      expect(tokensLeft()).not.toContain(second.deviceToken);
      expect(tokensLeft()).toContain(oldest.deviceToken);
    });
  });
});

describe('push_tokens.bundle_id migration', () => {
  const dirs: string[] = [];
  afterEach(() => { for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true }); });

  const columns = (db: Db) => (db.sql.prepare('PRAGMA table_info(push_tokens)').all() as { name: string }[]).map((c) => c.name);

  it('adds the column to a database created before it existed, keeps its rows, and is a no-op the next time', () => {
    const dir = mkdtempSync(join(tmpdir(), 'opa-db-'));
    dirs.push(dir);
    const path = join(dir, 'opa.sqlite');
    const old = new DatabaseSync(path);
    old.exec(`CREATE TABLE push_tokens (device_id TEXT NOT NULL, kind TEXT NOT NULL, token TEXT NOT NULL, env TEXT NOT NULL,
      activity_id TEXT, task_id TEXT, updated_at INTEGER NOT NULL, PRIMARY KEY (device_id, kind, token));
      INSERT INTO push_tokens VALUES ('dev1', 'alert', 'aa11', 'sandbox', NULL, NULL, 1);`);
    old.close();

    const upgraded = new Db(path);
    expect(columns(upgraded)).toContain('bundle_id');
    expect(upgraded.sql.prepare('SELECT device_id, token, bundle_id FROM push_tokens').all()).toEqual([{ device_id: 'dev1', token: 'aa11', bundle_id: null }]);
    upgraded.sql.close();

    const again = new Db(path); // column already there: must not throw
    expect(columns(again).filter((c) => c === 'bundle_id')).toHaveLength(1);
    again.sql.close();
  });

  it('a brand-new database has the column too', () => {
    expect(columns(new Db(':memory:'))).toContain('bundle_id');
  });
});
