// `phone.status` through the REAL execFile: a fake `adb` executable is all that is mocked. The sibling file
// phone-status.test.ts mocks execFile itself; this one proves the production wiring (argv, encoding, callback,
// error shapes) behaves the way those mocks assume.
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { PhoneStatusProbe } from '../src/phone/status.ts';

const CONFIG_OK = { command: process.execPath };

// Shell builtins only: PATH is narrowed to the fake's own directory for these tests.
const FAKE_ADB = `#!/bin/sh
printf '%s|' "$@" >> "$ADB_LOG"; echo >> "$ADB_LOG"
if [ -n "$FAKE_FAIL" ]; then echo "error: cannot connect to daemon at tcp:5037" >&2; exit 1; fi
if [ "$1" = "devices" ]; then
  printf 'List of devices attached\\n%s               %s usb:1-1 product:marble model:23116PN5BC device:marble transport_id:1\\n\\n' "$FAKE_SERIAL" "$FAKE_STATE"
  exit 0
fi
if [ "$1" = "-s" ] && [ "$3" = "shell" ]; then
  [ "$FAKE_KEYBOARD" = "yes" ] && printf 'package:com.android.adbkeyboard\\n'
  exit 0
fi
echo "unexpected adb call" >&2
exit 1
`;

const savedEnv = new Map<string, string | undefined>();
const setEnv = (key: string, value: string | undefined) => {
  if (!savedEnv.has(key)) savedEnv.set(key, process.env[key]);
  if (value === undefined) delete process.env[key]; else process.env[key] = value;
};

let dir: string;
let logPath: string;
/** What the fake adb was called with, one entry per call, arguments joined by "|". */
const calls = () => { try { return readFileSync(logPath, 'utf8').trim().split('\n').filter(Boolean); } catch { return []; } };

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'opa-phone-status-'));
  logPath = join(dir, 'calls.log');
  const bin = join(dir, 'bin');
  mkdirSync(bin);
  writeFileSync(join(bin, 'adb'), FAKE_ADB, { mode: 0o755 });
  setEnv('PATH', bin);
  setEnv('ADB_LOG', logPath);
  setEnv('OPA_PHONE_SERIAL', undefined);
  setEnv('FAKE_SERIAL', 'e7fe2f2a');
  setEnv('FAKE_STATE', 'device');
  setEnv('FAKE_KEYBOARD', 'yes');
  setEnv('FAKE_FAIL', undefined);
});
afterEach(() => {
  for (const [key, value] of savedEnv) { if (value === undefined) delete process.env[key]; else process.env[key] = value; }
  savedEnv.clear();
  rmSync(dir, { recursive: true, force: true });
});

describe('phone.status with a fake adb executable', () => {
  it('a ready phone with ADB Keyboard', async () => {
    const status = await new PhoneStatusProbe().status(CONFIG_OK);
    expect(status).toStrictEqual({ available: true, serial: 'e7fe2f2a', device: { serial: 'e7fe2f2a', state: 'device', model: '23116PN5BC' }, adbKeyboard: true });
    expect(calls()).toEqual(['devices|-l|', '-s|e7fe2f2a|shell|pm|list|packages|com.android.adbkeyboard|']);
  });

  it('a ready phone without ADB Keyboard (empty output, exit 0)', async () => {
    setEnv('FAKE_KEYBOARD', 'no');
    const status = await new PhoneStatusProbe().status(CONFIG_OK);
    expect(status).toMatchObject({ available: true, adbKeyboard: false });
  });

  it('an unauthorized phone is reported and not asked anything else', async () => {
    setEnv('FAKE_STATE', 'unauthorized');
    const status = await new PhoneStatusProbe().status(CONFIG_OK);
    expect(status).toMatchObject({ available: false, device: { serial: 'e7fe2f2a', state: 'unauthorized' }, reason: expect.stringContaining('授权') });
    expect(calls()).toEqual(['devices|-l|']);
  });

  it('adb missing from PATH gives available:false, not an exception', async () => {
    setEnv('PATH', join(dir, 'nothing-here'));
    const status = await new PhoneStatusProbe().status(CONFIG_OK);
    expect(status).toStrictEqual({ available: false, serial: 'e7fe2f2a', reason: expect.stringContaining('找不到 adb') });
    expect(calls()).toEqual([]);
  });

  it('adb exiting non-zero gives the first line of its error output', async () => {
    setEnv('FAKE_FAIL', '1');
    const status = await new PhoneStatusProbe().status(CONFIG_OK);
    expect(status).toStrictEqual({ available: false, serial: 'e7fe2f2a', reason: 'adb 执行失败：error: cannot connect to daemon at tcp:5037' });
  });

  it('a serial full of shell metacharacters reaches adb as one plain argument', async () => {
    const nasty = 'dev;echo$IFS$$`id`&&x|y';
    setEnv('OPA_PHONE_SERIAL', nasty);
    setEnv('FAKE_SERIAL', nasty);
    const status = await new PhoneStatusProbe().status(CONFIG_OK);
    expect(status).toMatchObject({ available: true, serial: nasty, adbKeyboard: true });
    expect(calls()).toEqual(['devices|-l|', `-s|${nasty}|shell|pm|list|packages|com.android.adbkeyboard|`]);
  });
});
