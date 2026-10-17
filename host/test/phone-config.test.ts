import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { DEFAULT_PHONE_SERIAL, PHONE_DIR, phoneConfigStatus, phoneMcpConfig } from '../src/phone/config.ts';

const oldEnv = new Map<string, string | undefined>();
function setEnv(key: string, value: string | undefined) {
  if (!oldEnv.has(key)) oldEnv.set(key, process.env[key]);
  if (value === undefined) delete process.env[key];
  else process.env[key] = value;
}

afterEach(() => {
  for (const [key, value] of oldEnv) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
  oldEnv.clear();
});

describe('phone MCP config', () => {
  it('uses the phone venv command, module args, working directory, and scoped environment', () => {
    setEnv('OPA_PHONE_CMD', 'python-from-env');
    setEnv('OPA_PHONE_SERIAL', 'device-from-env');
    setEnv('OPA_HOME', '/tmp/opa-phone-config-home');

    const config = phoneMcpConfig();
    expect(config).toMatchObject({
      command: 'python-from-env',
      args: ['-m', 'orbit_phone.server'],
      cwd: PHONE_DIR,
      env: { OPA_PHONE_SERIAL: 'device-from-env', OPA_HOME: '/tmp/opa-phone-config-home' },
      startup_timeout_sec: 30,
      tool_timeout_sec: 120,
    });
    expect(PHONE_DIR.endsWith('/phone')).toBe(true);
  });

  it('uses the default serial and explains how to set up a missing venv', () => {
    const temporary = mkdtempSync(join(tmpdir(), 'opa-phone-config-'));
    try {
      const python = join(temporary, '.venv', 'bin', 'python');
      mkdirSync(join(temporary, '.venv', 'bin'), { recursive: true });
      writeFileSync(python, '');
      setEnv('OPA_PHONE_CMD', undefined);
      setEnv('OPA_PHONE_SERIAL', undefined);
      const available = phoneConfigStatus({ phoneDir: temporary, command: '', opaHome: '/tmp/opa-phone-config-home' });
      expect(available).toMatchObject({
        available: true,
        config: {
          command: python,
          args: ['-m', 'orbit_phone.server'],
          cwd: temporary,
          env: { OPA_PHONE_SERIAL: DEFAULT_PHONE_SERIAL, OPA_HOME: '/tmp/opa-phone-config-home' },
          startup_timeout_sec: 30,
          tool_timeout_sec: 120,
        },
      });

      const missing = phoneConfigStatus({ phoneDir: join(temporary, 'missing'), command: '' });
      expect(missing.available).toBe(false);
      expect(missing.config).toBeUndefined();
      expect(missing.reason).toContain('opa phone setup');
    } finally {
      rmSync(temporary, { recursive: true, force: true });
    }
  });
});
