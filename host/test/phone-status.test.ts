// `phone.status` (protocol.md §4.2) with `execFile` mocked: what adb says → what the app is told.
// The error objects below have the exact shape Node's real execFile produces (checked against real children).
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { Host } from '../src/app.ts';
import { CodexBridge } from '../src/codex/bridge.ts';
import { CodexRpc } from '../src/codex/rpc.ts';
import { DEFAULT_PHONE_SERIAL } from '../src/phone/config.ts';
import { ADB_TIMEOUT_MS, configuredPhoneSerial, parseAdbDevices, PHONE_STATUS_TTL_MS, PhoneStatusProbe } from '../src/phone/status.ts';
import { Db } from '../src/store/db.ts';

const execFileMock = vi.hoisted(() => vi.fn());
vi.mock('node:child_process', async (importOriginal) => ({
  ...(await importOriginal<typeof import('node:child_process')>()),
  execFile: execFileMock,
}));

const SERIAL = 'e7fe2f2a';
const READY = `${SERIAL}               device usb:1-1 product:marble model:23116PN5BC device:marble transport_id:1`;
const listing = (...lines: string[]) => ['List of devices attached', ...lines, ''].join('\n');
const KEYBOARD = 'package:com.android.adbkeyboard\n';
const KEYBOARD_CMD = `adb -s ${SERIAL} shell pm list packages com.android.adbkeyboard`;

const ENOENT = { error: { code: 'ENOENT', syscall: 'spawn adb', path: 'adb' } };
const TIMED_OUT = { error: { code: null, killed: true, signal: 'SIGTERM' } };
const exits = (code: number, stderr = '') => ({ error: { code, killed: false, signal: null }, stderr });

/** The Python environment is there / is not: `phoneConfigStatus`'s own test seam, so no venv is needed on the machine. */
const CONFIG_OK = { command: process.execPath };
const CONFIG_MISSING = { phoneDir: '/tmp/opa-no-phone-venv', command: '' };

interface Reply { stdout?: string; stderr?: string; error?: object; gate?: Promise<void> }

/** Makes the mocked execFile answer like adb; `gate` holds an answer back until the promise settles. */
function fakeAdb(script: { devices?: Reply; keyboard?: Reply }) {
  execFileMock.mockImplementation((_file: string, args: string[], _options: object, callback: (...a: unknown[]) => void) => {
    const reply: Reply = (args[0] === 'devices' ? script.devices : args.includes('shell') ? script.keyboard : undefined)
      ?? { error: { code: 99, killed: false, signal: null }, stderr: `unexpected adb call: ${args.join(' ')}` };
    void (reply.gate ?? Promise.resolve()).then(() => {
      if (reply.error) callback(Object.assign(new Error(`Command failed: adb ${args.join(' ')}`), reply.error), reply.stdout ?? '', reply.stderr ?? '');
      else callback(null, reply.stdout ?? '', reply.stderr ?? '');
    });
    return undefined;
  });
}
const adbCalls = () => execFileMock.mock.calls.map(([file, args]) => `${file} ${(args as string[]).join(' ')}`);

let clock = 1_000_000;
const probe = () => new PhoneStatusProbe(() => clock);

const savedEnv = new Map<string, string | undefined>();
const setEnv = (key: string, value: string | undefined) => {
  if (!savedEnv.has(key)) savedEnv.set(key, process.env[key]);
  if (value === undefined) delete process.env[key]; else process.env[key] = value;
};

beforeEach(() => {
  execFileMock.mockReset();
  clock = 1_000_000;
  setEnv('OPA_PHONE_SERIAL', undefined);
});
afterEach(() => {
  vi.useRealTimers();
  for (const [key, value] of savedEnv) { if (value === undefined) delete process.env[key]; else process.env[key] = value; }
  savedEnv.clear();
});

describe('parseAdbDevices', () => {
  it('reads serial, state and model from `adb devices -l`', () => {
    const out = listing(
      READY,
      '192.168.1.5:5555       offline transport_id:4',
      'R5CT1234XYZ           unauthorized usb:1-2 transport_id:2',
      'emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:3',
      'adb-R5CT1234XYZ-AbCdEf._adb-tls-connect._tcp device product:b0q model:SM_S906B device:b0q transport_id:5',
    );
    expect(parseAdbDevices(out)).toStrictEqual([
      { serial: SERIAL, state: 'device', model: '23116PN5BC' },
      { serial: '192.168.1.5:5555', state: 'offline' },
      { serial: 'R5CT1234XYZ', state: 'unauthorized' },
      { serial: 'emulator-5554', state: 'device', model: 'sdk_gphone64_arm64' },
      { serial: 'adb-R5CT1234XYZ-AbCdEf._adb-tls-connect._tcp', state: 'device', model: 'SM_S906B' },
    ]);
  });

  it('ignores adb start-up chatter, blank lines and CRLF, and also reads the tab-separated plain format', () => {
    const noisy = '* daemon not running; starting now at tcp:5037\n* daemon started successfully\r\nList of devices attached\r\n\r\ne7fe2f2a\tdevice\r\n\r\n* trailing noise\r\n';
    expect(parseAdbDevices(noisy)).toStrictEqual([{ serial: SERIAL, state: 'device' }]);
  });

  it('reads nothing without the header, and does not mistake other keys for model', () => {
    expect(parseAdbDevices('')).toStrictEqual([]);
    expect(parseAdbDevices(`error: something went wrong\n${READY}\n`)).toStrictEqual([]);
    expect(parseAdbDevices(listing('X device usb:1 submodel:Nope'))).toStrictEqual([{ serial: 'X', state: 'device' }]);
  });
});

describe('configuredPhoneSerial', () => {
  it('is OPA_PHONE_SERIAL trimmed, and a blank value counts as unset', () => {
    expect(configuredPhoneSerial({})).toBe(DEFAULT_PHONE_SERIAL);
    expect(DEFAULT_PHONE_SERIAL).toBe('e7fe2f2a');
    expect(configuredPhoneSerial({ OPA_PHONE_SERIAL: '' })).toBe(DEFAULT_PHONE_SERIAL);
    expect(configuredPhoneSerial({ OPA_PHONE_SERIAL: '   ' })).toBe(DEFAULT_PHONE_SERIAL);
    expect(configuredPhoneSerial({ OPA_PHONE_SERIAL: ' 192.168.1.5:5555 ' })).toBe('192.168.1.5:5555');
  });
});

describe('phone status from adb', () => {
  it('a connected, authorized phone with ADB Keyboard is available', async () => {
    fakeAdb({ devices: { stdout: listing(READY) }, keyboard: { stdout: KEYBOARD } });
    const status = await probe().status(CONFIG_OK);
    // toStrictEqual: no `reason` key at all when available, and no undefined placeholders.
    expect(status).toStrictEqual({ available: true, serial: SERIAL, device: { serial: SERIAL, state: 'device', model: '23116PN5BC' }, adbKeyboard: true });
    expect(adbCalls()).toEqual(['adb devices -l', KEYBOARD_CMD]);
  });

  it('runs adb as argv with a 3 s timeout and never through a shell', async () => {
    fakeAdb({ devices: { stdout: listing(READY) }, keyboard: { stdout: KEYBOARD } });
    await probe().status(CONFIG_OK);
    expect(execFileMock).toHaveBeenCalledTimes(2);
    expect(ADB_TIMEOUT_MS).toBe(3000);
    for (const [file, args, options] of execFileMock.mock.calls) {
      expect(file).toBe('adb'); // a bare command name, resolved on PATH — nothing assembled into a command line
      expect(Array.isArray(args) && args.every((a: unknown) => typeof a === 'string')).toBe(true);
      expect(options.timeout).toBe(3000);
      expect(options.shell ?? false).toBe(false); // execFile only goes through a shell when asked to
    }
  });

  it.each([
    ['not installed', '', false],
    ['only a similarly named package', 'package:com.android.adbkeyboard.helper\n', false],
    ['installed, CRLF output', 'package:com.android.adbkeyboard\r\n', true],
  ])('ADB Keyboard %s → adbKeyboard %s while the phone stays available', async (_label, stdout, installed) => {
    fakeAdb({ devices: { stdout: listing(READY) }, keyboard: { stdout } });
    const status = await probe().status(CONFIG_OK);
    expect(status.available).toBe(true);
    expect(status.adbKeyboard).toBe(installed);
  });

  it.each([['times out', TIMED_OUT], ['fails', exits(1, 'error: device offline')]])(
    'when the ADB Keyboard check %s, adbKeyboard is left out — unknown is not "not installed"',
    async (_label, keyboard) => {
      fakeAdb({ devices: { stdout: listing(READY) }, keyboard });
      const status = await probe().status(CONFIG_OK);
      expect(status.available).toBe(true);
      expect('adbKeyboard' in status).toBe(false);
    },
  );

  it('an unauthorized phone is not available, says how to authorize, and nothing else is asked of it', async () => {
    fakeAdb({ devices: { stdout: listing(`${SERIAL}   unauthorized usb:1-1 transport_id:2`) } });
    const status = await probe().status(CONFIG_OK);
    expect(status).toStrictEqual({
      available: false, serial: SERIAL, device: { serial: SERIAL, state: 'unauthorized' },
      reason: expect.stringContaining('授权'),
    });
    expect(status.reason).toContain(SERIAL);
    expect(status.reason).toContain('USB 调试');
    expect(adbCalls()).toEqual(['adb devices -l']); // no shell command to a phone that has not allowed this Mac
  });

  it('an offline phone, and any other state, is not available either', async () => {
    fakeAdb({ devices: { stdout: listing(`${SERIAL}   offline transport_id:3`) } });
    const offline = await probe().status(CONFIG_OK);
    expect(offline).toMatchObject({ available: false, device: { state: 'offline' }, reason: expect.stringContaining('离线') });

    execFileMock.mockReset();
    fakeAdb({ devices: { stdout: listing(`${SERIAL}   authorizing transport_id:3`) } });
    const other = await probe().status(CONFIG_OK);
    expect(other).toMatchObject({ available: false, device: { state: 'authorizing' }, reason: expect.stringContaining('authorizing') });
    expect(adbCalls()).toEqual(['adb devices -l']);
  });

  it('a phone that is not connected is not available and has no device entry', async () => {
    fakeAdb({ devices: { stdout: listing() } });
    const status = await probe().status(CONFIG_OK);
    expect(status).toStrictEqual({ available: false, serial: SERIAL, reason: expect.stringContaining(`没有发现手机 ${SERIAL}`) });
    expect(status.reason).toContain('USB 调试');
    expect(adbCalls()).toEqual(['adb devices -l']);
  });

  it('another phone connected instead points at OPA_PHONE_SERIAL', async () => {
    fakeAdb({ devices: { stdout: listing('R5CT1234XYZ device usb:1-2 model:SM_S906B transport_id:2', '192.168.1.9:5555 offline transport_id:4') } });
    const status = await probe().status(CONFIG_OK);
    expect(status.available).toBe(false);
    expect(status.device).toBeUndefined();
    expect(status.reason).toContain(`没有发现手机 ${SERIAL}`);
    expect(status.reason).toContain('R5CT1234XYZ（device）');
    expect(status.reason).toContain('192.168.1.9:5555（offline）');
    expect(status.reason).toContain('OPA_PHONE_SERIAL');

    execFileMock.mockReset();
    fakeAdb({ devices: { stdout: listing(...['a', 'b', 'c', 'd', 'e'].map((s) => `${s} device transport_id:1`)) } });
    const crowded = await probe().status(CONFIG_OK);
    expect(crowded.reason).toContain('a（device）、b（device）、c（device） 等 5 台');
    expect(crowded.reason).not.toContain('d（device）');
  });

  it('adb not installed: available:false with a clear reason instead of throwing', async () => {
    fakeAdb({ devices: ENOENT });
    const status = await probe().status(CONFIG_OK);
    expect(status).toStrictEqual({ available: false, serial: SERIAL, reason: expect.stringContaining('找不到 adb') });
    expect(status.reason).toContain('PATH');
    expect(adbCalls()).toEqual(['adb devices -l']);
  });

  it('adb timing out: available:false with a clear reason instead of throwing, and no second adb call', async () => {
    fakeAdb({ devices: TIMED_OUT, keyboard: { stdout: KEYBOARD } });
    const status = await probe().status(CONFIG_OK);
    expect(status).toStrictEqual({ available: false, serial: SERIAL, reason: expect.stringContaining('3 秒') });
    expect(status.reason).toContain('adb');
    expect(adbCalls()).toEqual(['adb devices -l']);
  });

  it('adb failing says why, from the first line of its error output', async () => {
    fakeAdb({ devices: exits(1, "error: cannot connect to daemon at tcp:5037\nsecond line is not needed\n") });
    expect(await probe().status(CONFIG_OK)).toStrictEqual({
      available: false, serial: SERIAL, reason: 'adb 执行失败：error: cannot connect to daemon at tcp:5037',
    });

    fakeAdb({ devices: exits(255) });
    expect((await new PhoneStatusProbe(() => clock).status(CONFIG_OK)).reason).toBe('adb 执行失败：退出码 255');

    fakeAdb({ devices: { error: { code: 'EACCES', syscall: 'spawn adb', path: 'adb' } } });
    expect((await new PhoneStatusProbe(() => clock).status(CONFIG_OK)).reason).toBe('adb 执行失败：EACCES');

    fakeAdb({ devices: exits(1, 'x'.repeat(500)) });
    const long = (await new PhoneStatusProbe(() => clock).status(CONFIG_OK)).reason!;
    expect(long.length).toBeLessThan(200);
  });

  it('an execFile that throws is reported, not propagated, and leaves no timer behind', async () => {
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] });
    execFileMock.mockImplementation(() => { throw new Error('boom'); });
    const status = await probe().status(CONFIG_OK);
    expect(status).toStrictEqual({ available: false, serial: SERIAL, reason: '检查手机状态时出错：boom' });
    expect(vi.getTimerCount()).toBe(0);
  });

  it('follows OPA_PHONE_SERIAL, trimmed, for the lookup, the shell command and the answer', async () => {
    setEnv('OPA_PHONE_SERIAL', ' 192.168.1.5:5555 ');
    fakeAdb({
      devices: { stdout: listing(READY, '192.168.1.5:5555 device product:p model:Pixel_7 device:p transport_id:9') },
      keyboard: { stdout: KEYBOARD },
    });
    const status = await probe().status(CONFIG_OK);
    expect(status).toStrictEqual({ available: true, serial: '192.168.1.5:5555', device: { serial: '192.168.1.5:5555', state: 'device', model: 'Pixel_7' }, adbKeyboard: true });
    expect(adbCalls()).toEqual(['adb devices -l', 'adb -s 192.168.1.5:5555 shell pm list packages com.android.adbkeyboard']);
  });

  it('the Python environment missing makes the phone unavailable, with the setup hint, and still reports what adb found', async () => {
    fakeAdb({ devices: { stdout: listing(READY) }, keyboard: { stdout: KEYBOARD } });
    const status = await probe().status(CONFIG_MISSING);
    expect(status).toStrictEqual({
      available: false, serial: SERIAL, device: { serial: SERIAL, state: 'device', model: '23116PN5BC' }, adbKeyboard: true,
      reason: expect.stringContaining('opa phone setup'),
    });
  });

  it('hardware problems are reported before the Python environment', async () => {
    fakeAdb({ devices: { stdout: listing(`${SERIAL} unauthorized transport_id:2`) } });
    const status = await probe().status(CONFIG_MISSING);
    expect(status.reason).toContain('授权');
    expect(status.reason).not.toContain('opa phone setup');
  });
});

describe('caching', () => {
  it('answers repeated calls from one adb run for 20 s, then asks adb again', async () => {
    fakeAdb({ devices: { stdout: listing(READY) }, keyboard: { stdout: KEYBOARD } });
    const p = probe();
    const first = await p.status(CONFIG_OK);
    expect(execFileMock).toHaveBeenCalledTimes(2);

    expect(PHONE_STATUS_TTL_MS).toBe(20_000);
    clock += 19_999;
    expect(await p.status(CONFIG_OK)).toStrictEqual(first);
    expect(execFileMock).toHaveBeenCalledTimes(2); // nothing spawned

    clock += 1; // 20 s after the answer arrived
    expect(await p.status(CONFIG_OK)).toStrictEqual(first);
    expect(execFileMock).toHaveBeenCalledTimes(4); // devices + keyboard again
  });

  it('shows a change as soon as the cache has expired', async () => {
    fakeAdb({ devices: { stdout: listing(`${SERIAL} unauthorized transport_id:2`) } });
    const p = probe();
    expect((await p.status(CONFIG_OK)).available).toBe(false);

    // The owner taps "allow" on the phone: still the old answer inside the window, the new one after it.
    fakeAdb({ devices: { stdout: listing(READY) }, keyboard: { stdout: KEYBOARD } });
    clock += 10_000;
    expect((await p.status(CONFIG_OK)).available).toBe(false);
    clock += 10_000;
    expect(await p.status(CONFIG_OK)).toMatchObject({ available: true, adbKeyboard: true });
  });

  it('failures are cached too, so a missing or hanging adb is not spawned again on every settings open', async () => {
    fakeAdb({ devices: ENOENT });
    const p = probe();
    const first = await p.status(CONFIG_OK);
    clock += 5_000;
    expect(await p.status(CONFIG_OK)).toStrictEqual(first);
    expect(execFileMock).toHaveBeenCalledTimes(1);
  });

  it('callers that arrive while adb is still being asked share that run', async () => {
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    fakeAdb({ devices: { stdout: listing(READY), gate }, keyboard: { stdout: KEYBOARD } });
    const p = probe();

    const a = p.status(CONFIG_OK);
    const b = p.status(CONFIG_OK);
    const c = p.status(CONFIG_OK);
    expect(execFileMock).toHaveBeenCalledTimes(1); // one `adb devices -l` in flight, not three

    release();
    const [ra, rb, rc] = await Promise.all([a, b, c]);
    expect(rb).toStrictEqual(ra);
    expect(rc).toStrictEqual(ra);
    expect(adbCalls()).toEqual(['adb devices -l', KEYBOARD_CMD]);
    await p.status(CONFIG_OK);
    expect(execFileMock).toHaveBeenCalledTimes(2); // and now it is cached
  });

  it('only adb is cached: finishing `opa phone setup` shows up on the very next call, with no new adb run', async () => {
    fakeAdb({ devices: { stdout: listing(READY) }, keyboard: { stdout: KEYBOARD } });
    const p = probe();
    expect((await p.status(CONFIG_MISSING)).available).toBe(false);
    clock += 1_000;
    expect((await p.status(CONFIG_OK)).available).toBe(true);
    expect(execFileMock).toHaveBeenCalledTimes(2);
  });

  it('what a caller does to an answer does not leak into the next one', async () => {
    fakeAdb({ devices: { stdout: listing(READY) }, keyboard: { stdout: KEYBOARD } });
    const p = probe();
    const first = await p.status(CONFIG_OK);
    first.device!.state = 'tampered';
    first.device!.model = 'tampered';
    expect(await p.status(CONFIG_OK)).toStrictEqual({ available: true, serial: SERIAL, device: { serial: SERIAL, state: 'device', model: '23116PN5BC' }, adbKeyboard: true });
  });

  it('a clock set backwards does not pin an old answer', async () => {
    fakeAdb({ devices: { stdout: listing(READY) }, keyboard: { stdout: KEYBOARD } });
    const p = probe();
    await p.status(CONFIG_OK);
    clock -= 3_600_000;
    await p.status(CONFIG_OK);
    expect(execFileMock).toHaveBeenCalledTimes(4);
  });

  it('a different OPA_PHONE_SERIAL is a different question', async () => {
    fakeAdb({ devices: { stdout: listing(READY, 'other-phone device transport_id:7') }, keyboard: { stdout: KEYBOARD } });
    const p = probe();
    expect((await p.status(CONFIG_OK)).serial).toBe(SERIAL);
    setEnv('OPA_PHONE_SERIAL', 'other-phone');
    const second = await p.status(CONFIG_OK);
    expect(second).toMatchObject({ serial: 'other-phone', available: true });
    expect(execFileMock).toHaveBeenCalledTimes(4);
  });
});

describe('an adb that never answers', () => {
  it('is cut off shortly after the timeout even if execFile never calls back, and the child is killed', async () => {
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] });
    const kill = vi.fn();
    let late: ((...a: unknown[]) => void) | undefined;
    execFileMock.mockImplementation((_file: string, _args: string[], _options: object, callback: (...a: unknown[]) => void) => { late = callback; return { kill }; });
    const p = probe();

    const pending = p.status(CONFIG_OK);
    await vi.advanceTimersByTimeAsync(ADB_TIMEOUT_MS + 999);
    expect(kill).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(1);
    const status = await pending;

    expect(status).toStrictEqual({ available: false, serial: SERIAL, reason: expect.stringContaining('3 秒') });
    expect(kill).toHaveBeenCalledWith('SIGKILL');

    // A callback that finally arrives is ignored, and the next caller is not stuck behind the hung run.
    late!(null, listing(READY), '');
    expect(await p.status(CONFIG_OK)).toStrictEqual(status);
    expect(execFileMock).toHaveBeenCalledTimes(1);
  });

  it('leaves no timer behind when adb answers in time', async () => {
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] });
    fakeAdb({ devices: { stdout: listing(READY) }, keyboard: { stdout: KEYBOARD } });
    await probe().status(CONFIG_OK);
    expect(vi.getTimerCount()).toBe(0);
  });
});

describe('phone.status request', () => {
  const cleanups: (() => void)[] = [];
  afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

  function makeHost() {
    const bridge = new CodexBridge(new CodexRpc(process.execPath, []));
    const db = new Db(':memory:');
    const host = new Host({ db, bridge });
    cleanups.push(() => { host.butler.scheduler.stop(); bridge.rpc.stop(); db.sql.close(); });
    return host;
  }

  it('is answered by the host, as plain JSON, from the cache on the second open', async () => {
    setEnv('OPA_PHONE_CMD', process.execPath); // the Python-environment check is not what this test is about
    fakeAdb({ devices: { stdout: listing(READY) }, keyboard: { stdout: KEYBOARD } });
    const host = makeHost();

    const res = await host.handle('dev1', 'phone.status', {});
    expect(res).toStrictEqual({ available: true, serial: SERIAL, device: { serial: SERIAL, state: 'device', model: '23116PN5BC' }, adbKeyboard: true });
    expect(JSON.parse(JSON.stringify(res))).toStrictEqual(res);

    expect(await host.handle('dev1', 'phone.status', {})).toStrictEqual(res);
    expect(await host.handle('local-cli', 'phone.status', undefined)).toStrictEqual(res);
    expect(execFileMock).toHaveBeenCalledTimes(2); // one devices + one keyboard, for three requests
  });

  it('answers with available:false instead of an error when adb is missing', async () => {
    setEnv('OPA_PHONE_CMD', process.execPath);
    fakeAdb({ devices: ENOENT });
    const host = makeHost();
    await expect(host.handle('dev1', 'phone.status', {})).resolves.toStrictEqual({
      available: false, serial: SERIAL, reason: expect.stringContaining('找不到 adb'),
    });
  });
});
