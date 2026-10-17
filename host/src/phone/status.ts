// Read-only status of the dedicated Android phone, for the app's settings screen (docs/protocol.md §4.2 `phone.status`).
// It only asks adb what is connected — it never operates the phone — and it never throws: every way adb can go wrong
// comes back as `available:false` with a Chinese `reason` the app can show as-is.
import { execFile } from 'node:child_process';
import { DEFAULT_PHONE_SERIAL, phoneConfigStatus, type PhoneConfigOverrides, type PhoneConfigStatus } from './config.ts';

export interface PhoneDevice { serial: string; state: string; model?: string }

export interface PhoneStatus {
  available: boolean;
  /** Present exactly when `available` is false: what to fix, in words for the owner. */
  reason?: string;
  /** The phone Orbit is pinned to: `OPA_PHONE_SERIAL`, default e7fe2f2a. */
  serial: string;
  /** What adb says about `serial`, whatever its state. Absent when adb could not be asked or does not list it. */
  device?: PhoneDevice;
  /** Is ADB Keyboard installed? Only known when the device is ready and the check finished; absent means unknown. */
  adbKeyboard?: boolean;
}

/** Each adb call is cut off after this long, so a whole check takes a few seconds at most. */
export const ADB_TIMEOUT_MS = 3_000;
/** How long past the timeout we wait for `execFile` to call back before giving up on it (see `runAdb`). */
const ADB_GRACE_MS = 1_000;
/** adb's answer is reused for this long, so reopening the settings screen doesn't spawn adb every time. */
export const PHONE_STATUS_TTL_MS = 20_000;
const ADB_KEYBOARD_PACKAGE = 'com.android.adbkeyboard';

/** The phone Orbit is pinned to. A blank `OPA_PHONE_SERIAL` counts as unset, as it does for the Python worker. */
export function configuredPhoneSerial(env: NodeJS.ProcessEnv = process.env): string {
  return env.OPA_PHONE_SERIAL?.trim() || DEFAULT_PHONE_SERIAL;
}

/**
 * Parses `adb devices -l`. Only lines after the "List of devices attached" header count: older adb prints its
 * "* daemon not running" start-up chatter on stdout, ahead of the header. `model` is adb's own spelling (spaces
 * become underscores) and is left out when adb doesn't report one, e.g. for an unauthorized phone.
 */
export function parseAdbDevices(stdout: string): PhoneDevice[] {
  const devices: PhoneDevice[] = [];
  let listing = false;
  for (const raw of stdout.split(/\r?\n/)) {
    const line = raw.trim();
    if (!listing) { listing = line.startsWith('List of devices attached'); continue; }
    if (!line || line.startsWith('*')) continue;
    const m = /^(\S+)\s+(\S+)(?:\s+(.*))?$/.exec(line);
    if (!m) continue;
    const model = /(?:^|\s)model:(\S+)/.exec(m[3] ?? '')?.[1];
    devices.push({ serial: m[1], state: m[2], ...(model ? { model } : {}) });
  }
  return devices;
}

// ───────────── running adb ─────────────

type AdbFailure = { kind: 'missing' } | { kind: 'timeout' } | { kind: 'failed'; detail: string };
type AdbRun = { ok: true; stdout: string } | { ok: false; failure: AdbFailure };

function classifyFailure(error: { code?: string | number | null; killed?: boolean; signal?: string | null }, stderr: string): AdbFailure {
  if (error.code === 'ENOENT') return { kind: 'missing' };
  if (error.killed || error.code === 'ETIMEDOUT') return { kind: 'timeout' };
  const firstLine = stderr.split(/\r?\n/).map((l) => l.trim()).find(Boolean);
  const detail = firstLine ?? (typeof error.code === 'number' ? `退出码 ${error.code}` : String(error.code ?? error.signal ?? '未知错误'));
  return { kind: 'failed', detail: detail.slice(0, 160) };
}

/**
 * Runs `adb <args>` — argv only, never a shell. Node's own `timeout` kills just the direct child and then waits for its
 * stdio pipes to close, so a grandchild that inherited a pipe (an adb server being started) could leave the callback
 * pending forever. Everyone asking for the phone's status shares one in-flight probe, so a hang would wedge the screen
 * for good: a hard deadline just past the timeout settles the call regardless and kills the child.
 */
function runAdb(args: string[]): Promise<AdbRun> {
  return new Promise((resolve) => {
    let child: ReturnType<typeof execFile> | undefined;
    const guard = setTimeout(() => {
      resolve({ ok: false, failure: { kind: 'timeout' } });
      child?.kill('SIGKILL');
    }, ADB_TIMEOUT_MS + ADB_GRACE_MS);
    try {
      child = execFile('adb', args, { timeout: ADB_TIMEOUT_MS, encoding: 'utf8' }, (error, stdout, stderr) => {
        clearTimeout(guard);
        resolve(error ? { ok: false, failure: classifyFailure(error, String(stderr ?? '')) } : { ok: true, stdout: String(stdout ?? '') });
      });
    } catch (e) {
      clearTimeout(guard); // no child, so nothing will ever call back
      throw e;             // → the promise rejects, and `probeAdb` turns that into a reason
    }
  });
}

// ───────────── what adb said ─────────────

/** The part of the status that comes from spawning adb — and so the part that is cached. */
type AdbProbe =
  | { kind: 'unusable'; reason: string }                          // adb missing, timed out or failed
  | { kind: 'absent'; others: PhoneDevice[] }                     // adb works but doesn't list the configured serial
  | { kind: 'listed'; device: PhoneDevice; adbKeyboard?: boolean }; // adb lists it, in whatever state

function adbFailureReason(f: AdbFailure): string {
  switch (f.kind) {
    case 'missing': return '找不到 adb：Host 进程的 PATH 里没有它。请安装 Android Platform Tools，把 adb 加入 PATH，然后重启 Host。';
    case 'timeout': return `adb 没有在 ${ADB_TIMEOUT_MS / 1000} 秒内响应。请检查数据线，或在 Mac 终端运行 adb kill-server 后再试。`;
    case 'failed': return `adb 执行失败：${f.detail}`;
  }
}

async function probeAdb(serial: string): Promise<AdbProbe> {
  try {
    const listing = await runAdb(['devices', '-l']);
    if (!listing.ok) return { kind: 'unusable', reason: adbFailureReason(listing.failure) };
    const devices = parseAdbDevices(listing.stdout);
    const device = devices.find((d) => d.serial === serial);
    if (!device) return { kind: 'absent', others: devices };
    if (device.state !== 'device') return { kind: 'listed', device };
    // Only a ready phone can be asked. A failed check leaves the answer unknown rather than guessing "not installed".
    const keyboard = await runAdb(['-s', serial, 'shell', 'pm', 'list', 'packages', ADB_KEYBOARD_PACKAGE]);
    if (!keyboard.ok) return { kind: 'listed', device };
    return { kind: 'listed', device, adbKeyboard: keyboard.stdout.split(/\r?\n/).some((l) => l.trim() === `package:${ADB_KEYBOARD_PACKAGE}`) };
  } catch (e: any) {
    return { kind: 'unusable', reason: `检查手机状态时出错：${String(e?.message ?? e).slice(0, 160)}` };
  }
}

function describeDevices(devices: PhoneDevice[]): string {
  const shown = devices.slice(0, 3).map((d) => `${d.serial}（${d.state}）`).join('、');
  return devices.length > 3 ? `${shown} 等 ${devices.length} 台` : shown;
}

function absentReason(serial: string, others: PhoneDevice[]): string {
  return others.length
    ? `没有发现手机 ${serial}，adb 只看到 ${describeDevices(others)}。如果换了手机，请修改 OPA_PHONE_SERIAL 并重启 Host。`
    : `没有发现手机 ${serial}。请用数据线连接手机，并在手机上允许 USB 调试。`;
}

function notReadyReason(d: PhoneDevice): string {
  switch (d.state) {
    case 'unauthorized': return `手机 ${d.serial} 还没有授权这台 Mac。请解锁手机，在弹出的「允许 USB 调试」里点允许。`;
    case 'offline': return `手机 ${d.serial} 处于离线状态。请重新插拔数据线，或在手机上关闭再打开 USB 调试。`;
    default: return `手机 ${d.serial} 当前状态是 ${d.state}，暂时不能使用。`;
  }
}

/**
 * Hardware first, software second, in the order the README sets things up: adb → the phone → its state → the Python
 * environment. `available:false` always carries the first thing in that chain that is wrong.
 */
function composePhoneStatus(serial: string, probe: AdbProbe, config: PhoneConfigStatus): PhoneStatus {
  if (probe.kind === 'unusable') return { available: false, reason: probe.reason, serial };
  if (probe.kind === 'absent') return { available: false, reason: absentReason(serial, probe.others), serial };
  const device = { ...probe.device };
  const keyboard = probe.adbKeyboard === undefined ? {} : { adbKeyboard: probe.adbKeyboard };
  if (device.state !== 'device') return { available: false, reason: notReadyReason(device), serial, device, ...keyboard };
  if (!config.available) return { available: false, reason: config.reason ?? '手机自动化环境没有就绪。', serial, device, ...keyboard };
  return { available: true, serial, device, ...keyboard };
}

// ───────────── the probe the host keeps ─────────────

export class PhoneStatusProbe {
  private cached?: { serial: string; at: number; probe: AdbProbe };
  private inflight?: { serial: string; promise: Promise<AdbProbe> };

  /** `now` is a seam for tests. */
  constructor(private readonly now: () => number = Date.now) {}

  /**
   * Never rejects. Only what adb said is cached (20 s, failures included); the Python-environment check is a file
   * lookup and is redone every time, so finishing `opa phone setup` shows up at once. Callers arriving while adb is
   * still being asked share that one run. `configOverrides` is a test seam, like the one on `phoneConfigStatus`.
   */
  async status(configOverrides?: PhoneConfigOverrides): Promise<PhoneStatus> {
    const serial = configuredPhoneSerial();
    const probe = await this.adb(serial);
    return composePhoneStatus(serial, probe, phoneConfigStatus(configOverrides));
  }

  private adb(serial: string): Promise<AdbProbe> {
    const age = this.cached ? this.now() - this.cached.at : -1;
    // age < 0 also covers the clock being set backwards, which must not pin a stale answer.
    if (this.cached && this.cached.serial === serial && age >= 0 && age < PHONE_STATUS_TTL_MS) return Promise.resolve(this.cached.probe);
    if (this.inflight?.serial === serial) return this.inflight.promise;
    const promise: Promise<AdbProbe> = probeAdb(serial)
      .then((probe) => { this.cached = { serial, at: this.now(), probe }; return probe; })
      .finally(() => { if (this.inflight?.promise === promise) this.inflight = undefined; });
    this.inflight = { serial, promise };
    return promise;
  }
}
