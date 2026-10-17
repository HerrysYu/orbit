import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { OPA_HOME } from '../store/db.ts';

export const PHONE_DIR = join(import.meta.dirname, '../../../phone');
export const DEFAULT_PHONE_SERIAL = 'e7fe2f2a';

export interface PhoneMcpConfig {
  command: string;
  args: string[];
  cwd: string;
  env: Record<string, string>;
  startup_timeout_sec: number;
  tool_timeout_sec: number;
}

export interface PhoneConfigStatus {
  available: boolean;
  reason?: string;
  config?: PhoneMcpConfig;
}

/** Optional inputs keep configuration checks testable while normal callers use the environment. */
export interface PhoneConfigOverrides {
  phoneDir?: string;
  command?: string;
  serial?: string;
  opaHome?: string;
}

export function phoneConfigStatus(overrides: PhoneConfigOverrides = {}): PhoneConfigStatus {
  const phoneDir = overrides.phoneDir ?? PHONE_DIR;
  const command = overrides.command ?? process.env.OPA_PHONE_CMD;
  const python = join(phoneDir, '.venv', 'bin', 'python');
  if (!command && !existsSync(python)) {
    return {
      available: false,
      reason: `找不到手机 Python 环境 ${python}；请运行 opa phone setup 安装依赖。`,
    };
  }

  return {
    available: true,
    config: {
      command: command || python,
      args: ['-m', 'orbit_phone.server'],
      cwd: phoneDir,
      env: {
        OPA_PHONE_SERIAL: overrides.serial ?? process.env.OPA_PHONE_SERIAL ?? DEFAULT_PHONE_SERIAL,
        OPA_HOME: overrides.opaHome ?? process.env.OPA_HOME ?? OPA_HOME,
      },
      startup_timeout_sec: 30,
      tool_timeout_sec: 120,
    },
  };
}

export function phoneMcpConfig(): PhoneMcpConfig | undefined {
  return phoneConfigStatus().config;
}
