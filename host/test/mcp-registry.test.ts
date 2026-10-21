import { mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { importMcpServices, initializeMcpConfig, listMcpServices, resolveMcpServices, setMcpServiceEnabled } from '../src/mcp/registry.ts';

let home = '';
let incoming = '';
let env: NodeJS.ProcessEnv;
const names = ['AMAP_MAPS_API_KEY', 'FEISHU_APP_ID', 'FEISHU_APP_SECRET', 'TAVILY_API_KEY',
  'GITHUB_PERSONAL_ACCESS_TOKEN', 'NOTION_TOKEN', 'TOKEN', 'ARG', 'MCP_URL', 'UNSET_TOKEN'];
const opts = () => ({ home, env });
const state = (value: unknown) => writeFileSync(join(home, 'mcp.json'), JSON.stringify(value, null, 2) + '\n', { mode: 0o600 });
const envFile = (value: string) => writeFileSync(join(home, 'mcp.env'), value, { mode: 0o600 });
const importJson = (value: unknown) => writeFileSync(incoming, JSON.stringify(value, null, 2));
function errorOf(fn: () => unknown): string {
  try { fn(); } catch (error) { return (error as Error).message; }
  throw new Error('Expected operation to fail');
}
beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), 'opa-mcp-registry-'));
  incoming = join(home, 'import.json');
  env = Object.fromEntries(names.map((name) => [name, undefined]));
});
afterEach(() => rmSync(home, { recursive: true, force: true }));

describe('MCP registry', () => {
  it('lists the eight built-ins before credentials are configured without exposing secrets', () => {
    state({ presets: {}, mcpServers: {} });
    envFile('# no credentials yet\n');
    const catalog = listMcpServices(opts());
    expect(catalog).toHaveLength(8);
    expect(catalog.every((item) => item.enabled && item.builtin)).toBe(true);
    expect(catalog.find((item) => item.id === 'amap')).toMatchObject({ configured: false, missingEnv: ['AMAP_MAPS_API_KEY'] });
    expect(catalog.find((item) => item.id === 'rail_12306')).toMatchObject({ configured: true, missingEnv: [] });
    expect(JSON.stringify(catalog)).not.toContain('secret-value');
    expect(resolveMcpServices([], opts())).toEqual({});
  });

  it('keeps custom URLs, args, headers, and credentials out of the catalog', () => {
    state({ presets: {}, mcpServers: {
      private: { type: 'streamable-http', url: 'https://private.example/mcp?private-query=hide', headers: { Authorization: 'Bearer ${TOKEN}' } },
      argtest: { command: 'custom-launcher', args: ['private-argument'], env: { TOKEN: 'literal-secret' } },
    } });
    envFile('TOKEN=env-file-secret\n');
    const json = JSON.stringify(listMcpServices(opts()));
    for (const value of ['private.example', 'private-query', 'hide', 'private-argument', 'literal-secret', 'env-file-secret', 'Bearer']) {
      expect(json).not.toContain(value);
    }
    expect(json).toContain('https://modelscope.cn/mcp/servers');
    expect(json).toContain('TOKEN');
  });

  it('expands stdio and Streamable HTTP templates and maps standard headers', () => {
    state({ presets: {}, mcpServers: {} });
    envFile('FILE_TOKEN=file-token\nARG=file-arg\nMCP_URL=https://example.test/mcp\n');
    env.TOKEN = 'process-token';
    env.ARG = 'process-arg';
    importJson({ mcpServers: {
      stdio: { type: 'stdio', command: 'node', args: ['${ARG}', '--fixed'], env: { ACCESS_TOKEN: '${TOKEN}' } },
      remote: { type: 'streamable-http', url: '${MCP_URL}', headers: { Authorization: 'Bearer ${TOKEN}' } },
    } });
    expect(importMcpServices(incoming, opts()).sort()).toEqual(['remote', 'stdio']);
    expect(resolveMcpServices(['stdio', 'remote'], opts())).toEqual({
      orbit_mcp_stdio: { command: 'node', args: ['process-arg', '--fixed'], env: { ACCESS_TOKEN: 'process-token' },
        startup_timeout_sec: 90, tool_timeout_sec: 120 },
      orbit_mcp_remote: { url: 'https://example.test/mcp', http_headers: { Authorization: 'Bearer process-token' },
        startup_timeout_sec: 90, tool_timeout_sec: 120 },
    });
    const saved = readFileSync(join(home, 'mcp.json'), 'utf8');
    expect(JSON.parse(saved).mcpServers.remote.type).toBeUndefined();
    expect(JSON.parse(saved).mcpServers.remote.headers).toBeUndefined();
    expect(JSON.parse(saved).mcpServers.remote.http_headers.Authorization).toBe('Bearer ${TOKEN}');
    expect(saved).not.toContain('process-token');
  });

  it('treats a missing URL template as missing credentials and rejects conflicting headers', () => {
    state({ presets: {}, mcpServers: {
      missing: { type: 'http', url: '${MCP_URL}' },
      conflict: { type: 'http', url: 'https://example.test/mcp', headers: {}, http_headers: {} },
    } });
    envFile('');
    expect(errorOf(() => resolveMcpServices(['missing'], opts()))).toContain('MCP_URL');
    expect(errorOf(() => resolveMcpServices(['conflict'], opts()))).toContain('不能同时');
  });

  it('resolves a selected service despite unrelated invalid config', () => {
    state({ presets: {}, mcpServers: {
      selected: { command: 'node', args: ['--safe'] },
      unrelated: { command: 'launcher', args: [], surprise: 'invalid' },
      primitive: null,
    } });
    envFile('');
    expect(resolveMcpServices(['selected'], opts()).orbit_mcp_selected.command).toBe('node');
    expect(listMcpServices(opts()).find((item) => item.id === 'unrelated')).toMatchObject({
      configured: false, reason: '本地 MCP 配置无效。',
    });
    expect(listMcpServices(opts()).find((item) => item.id === 'primitive')).toMatchObject({
      configured: false, reason: '本地 MCP 配置无效。',
    });
  });

  it('rejects missing templates, disabled/unknown/reserved IDs, and malformed JSON safely', () => {
    state({ presets: {}, mcpServers: { needsKey: { command: 'node', args: ['${UNSET_TOKEN}'] } } });
    envFile('');
    expect(errorOf(() => resolveMcpServices(['needsKey'], opts()))).toContain('UNSET_TOKEN');
    expect(errorOf(() => resolveMcpServices(['unknown'], opts()))).toContain('未知');
    expect(errorOf(() => resolveMcpServices(['orbit_phone'], opts()))).toContain('保留');
    setMcpServiceEnabled('amap', false, opts());
    expect(errorOf(() => resolveMcpServices(['amap'], opts()))).toContain('停用');
    writeFileSync(join(home, 'mcp.json'), '{"mcpServers":{"bad":"private-json-secret', { mode: 0o600 });
    const error = errorOf(() => listMcpServices(opts()));
    expect(error).toContain('JSON');
    expect(error).not.toContain('private-json-secret');
  });

  it('initializes private files once and does not overwrite existing files', () => {
    const first = initializeMcpConfig(opts());
    expect(first.created).toEqual([first.configPath, first.envPath]);
    expect(statSync(first.configPath).mode & 0o777).toBe(0o600);
    expect(statSync(first.envPath).mode & 0o777).toBe(0o600);
    expect(readFileSync(first.envPath, 'utf8')).not.toMatch(/^[A-Za-z_][A-Za-z0-9_]*=.+$/m);
    const config = readFileSync(first.configPath, 'utf8'), environment = readFileSync(first.envPath, 'utf8');
    expect(initializeMcpConfig(opts()).created).toEqual([]);
    expect(readFileSync(first.configPath, 'utf8')).toBe(config);
    expect(readFileSync(first.envPath, 'utf8')).toBe(environment);
    writeFileSync(first.envPath, 'TOKEN=keep-me\n');
    expect(initializeMcpConfig(opts()).created).toEqual([]);
    expect(readFileSync(first.envPath, 'utf8')).toBe('TOKEN=keep-me\n');
  });

  it('merges valid imports and preserves the old config after failures', () => {
    state({ presets: { amap: { enabled: false } }, mcpServers: { keep: { command: 'keep-server', args: [], enabled: false } } });
    envFile('');
    importJson({ mcpServers: { add: { type: 'stdio', command: 'add-server' }, remote: { type: 'http', url: 'https://example.test/mcp' } } });
    expect(importMcpServices(incoming, opts()).sort()).toEqual(['add', 'remote']);
    const merged = JSON.parse(readFileSync(join(home, 'mcp.json'), 'utf8'));
    expect(merged.presets.amap).toEqual({ enabled: false });
    expect(merged.mcpServers.keep).toMatchObject({ command: 'keep-server', enabled: false });
    expect(merged.mcpServers.add.type).toBeUndefined();
    expect(merged.mcpServers.remote.url).toBe('https://example.test/mcp');
    for (const document of [
      { presets: {}, mcpServers: {} },
      { mcpServers: { bad: { command: 'x', unknownField: 'sensitive-invalid-value' } } },
      { mcpServers: { old: { type: 'sse', url: 'https://example.test/sse' } } },
      { mcpServers: { amap: { command: 'collision' } } },
      { mcpServers: { slow: { command: 'x', startup_timeout_sec: 3600 } } },
    ]) {
      importJson(document);
      const before = readFileSync(join(home, 'mcp.json'), 'utf8');
      const message = errorOf(() => importMcpServices(incoming, opts()));
      expect(readFileSync(join(home, 'mcp.json'), 'utf8')).toBe(before);
      expect(message).not.toContain('sensitive-invalid-value');
    }
  });

  it('changes only the requested enabled flag and returns redacted config errors', () => {
    state({ presets: { amap: { enabled: true } }, mcpServers: {
      custom: { command: 'run', args: ['--keep'], env: { TOKEN: 'private' } },
      bad: { url: 'not a URL containing private-value', http_headers: { Authorization: 'Bearer private-value' } },
    } });
    envFile('');
    setMcpServiceEnabled('amap', false, opts());
    setMcpServiceEnabled('custom', false, opts());
    const saved = JSON.parse(readFileSync(join(home, 'mcp.json'), 'utf8'));
    expect(saved.presets).toEqual({ amap: { enabled: false } });
    expect(saved.mcpServers.custom).toEqual({ command: 'run', args: ['--keep'], env: { TOKEN: 'private' }, enabled: false });
    const error = errorOf(() => resolveMcpServices(['bad'], opts()));
    expect(error).toContain('url');
    expect(error).not.toContain('private-value');
  });
});

