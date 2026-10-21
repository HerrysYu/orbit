import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';

let root: string;
let home: string;
const hostDir = join(import.meta.dirname, '..');
const cliPath = join(hostDir, 'src/cli.ts');

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'opa-mcp-cli-'));
  home = join(root, 'opa-home');
  mkdirSync(home, { recursive: true });
});

afterEach(() => rmSync(root, { recursive: true, force: true }));

function run(...args: string[]) {
  // Keep the child environment intentionally small; do not inherit user credentials or MCP secrets.
  return spawnSync(process.execPath, ['--import', 'tsx', cliPath, 'mcp', ...args], {
    cwd: hostDir,
    env: { PATH: '/usr/bin:/bin:/opt/homebrew/bin', HOME: root, TMPDIR: root, OPA_HOME: home },
    encoding: 'utf8',
    timeout: 10_000,
    maxBuffer: 1024 * 1024,
  });
}

describe('opa mcp CLI', () => {
  it('initializes without overwriting, lists/status offline, and toggles a built-in service', () => {
    const initialized = run('init');
    expect(initialized.status).toBe(0);
    const init = JSON.parse(initialized.stdout);
    expect(init.created).toHaveLength(2);
    const configPath = join(home, 'mcp.json');
    const envPath = join(home, 'mcp.env');
    writeFileSync(configPath, JSON.stringify({ presets: { amap: { enabled: false } }, mcpServers: {} }));
    writeFileSync(envPath, 'AMAP_MAPS_API_KEY=CLI_TEST_SECRET\n');
    const savedConfig = readFileSync(configPath, 'utf8');
    const savedEnv = readFileSync(envPath, 'utf8');

    const secondInit = run('init');
    expect(secondInit.status).toBe(0);
    expect(JSON.parse(secondInit.stdout).created).toEqual([]);
    expect(readFileSync(configPath, 'utf8')).toBe(savedConfig);
    expect(readFileSync(envPath, 'utf8')).toBe(savedEnv);

    const list = run('list');
    expect(list.status).toBe(0);
    const catalog = JSON.parse(list.stdout);
    expect(catalog.find((item: any) => item.id === 'amap')).toMatchObject({ enabled: false, configured: true });
    expect(list.stdout).not.toContain('CLI_TEST_SECRET');
    const status = run('status');
    expect(status.status).toBe(0);
    expect(JSON.parse(status.stdout)).toHaveLength(catalog.length);

    expect(run('enable', 'amap').status).toBe(0);
    expect(JSON.parse(run('status').stdout).find((item: any) => item.id === 'amap').enabled).toBe(true);
    expect(run('disable', 'amap').status).toBe(0);
    expect(JSON.parse(run('list').stdout).find((item: any) => item.id === 'amap').enabled).toBe(false);
  });

  it('imports standard mcpServers JSON without printing headers or secret values', () => {
    run('init');
    writeFileSync(join(home, 'mcp.env'), 'WEATHER_TOKEN=CLI_IMPORT_SECRET\n');
    const importPath = join(root, 'provider.json');
    writeFileSync(importPath, JSON.stringify({
      mcpServers: {
        'weather-demo': {
          type: 'http', url: 'https://example.invalid/mcp',
          http_headers: { Authorization: 'Bearer ' + '$' + '{WEATHER_TOKEN}' },
        },
      },
    }));

    const imported = run('import', importPath);
    expect(imported.status).toBe(0);
    expect(JSON.parse(imported.stdout)).toEqual({ imported: ['weather-demo'] });
    expect(imported.stdout).not.toContain('Bearer');
    expect(imported.stdout).not.toContain('CLI_IMPORT_SECRET');
    const listed = run('list');
    expect(listed.status).toBe(0);
    expect(JSON.parse(listed.stdout).find((item: any) => item.id === 'weather-demo')).toMatchObject({ configured: true, enabled: true });
    expect(listed.stdout).not.toContain('CLI_IMPORT_SECRET');
  });

  it('rejects unknown check IDs without starting Codex', () => {
    const invalid = run('check', 'not-a-real-service');
    expect(invalid.status).toBe(2);
    expect(invalid.stderr).toContain('用法：opa mcp check');
  });

  it('returns controlled errors without echoing a supplied path or raw JSON', () => {
    const path = join(root, 'bad-provider.json');
    writeFileSync(path, JSON.stringify({ mcpServers: { 'weather-demo': { url: 'https://user:pass@example.invalid' } } }));
    const result = run('import', path);
    expect(result.status).toBe(1);
    expect(result.stderr).toContain('MCP 操作失败');
    expect(result.stderr).not.toContain(path);
    expect(result.stderr).not.toContain('user:pass');
  });
});
