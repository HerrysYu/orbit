// macOS Keychain via /usr/bin/security (argv, no shell). Falls back to undefined on other platforms.
import { execFileSync } from 'node:child_process';

const SERVICE = 'com.openpersonalagent.host';

export function keychainGet(account: string): string | undefined {
  if (process.platform !== 'darwin' || process.env.OPA_NO_KEYCHAIN) return undefined;
  try {
    return execFileSync('/usr/bin/security', ['find-generic-password', '-s', SERVICE, '-a', account, '-w'], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'],
    }).trim() || undefined;
  } catch {
    return undefined;
  }
}

export function keychainSet(account: string, secret: string): boolean {
  if (process.platform !== 'darwin' || process.env.OPA_NO_KEYCHAIN) return false;
  try {
    execFileSync('/usr/bin/security', ['add-generic-password', '-U', '-s', SERVICE, '-a', account, '-w', secret], { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}
