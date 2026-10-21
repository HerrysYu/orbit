import { randomUUID } from 'node:crypto';
import { closeSync, fsyncSync, lstatSync, mkdirSync, openSync, readFileSync, renameSync, unlinkSync, writeFileSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { OPA_HOME } from '../store/db.ts';

export interface McpServerConfig {
  command?: string; args?: string[]; cwd?: string; env?: Record<string, string>;
  url?: string; http_headers?: Record<string, string>; startup_timeout_sec?: number;
  tool_timeout_sec?: number; enabled_tools?: string[]; disabled_tools?: string[];
}
export interface McpRegistryOptions { home?: string; env?: NodeJS.ProcessEnv }
export interface McpCatalogItem {
  id: string; name: string; region: 'china' | 'global'; description: string; sourceUrl: string; setup: string;
  enabled: boolean; configured: boolean; missingEnv: string[]; reason?: string; builtin: boolean;
}
type RawServerConfig = McpServerConfig & { type?: string; enabled?: boolean };
type RegistryState = { presets: Record<string, { enabled: boolean }>; mcpServers: Record<string, RawServerConfig> };
type Builtin = Omit<McpCatalogItem, 'enabled' | 'configured' | 'missingEnv' | 'reason' | 'builtin'> & {
  requiredEnv: string[]; config: McpServerConfig;
};
type NormalizedServer = { config: McpServerConfig; enabled: boolean; missingEnv: string[] };

const TIMEOUTS = { startup_timeout_sec: 90, tool_timeout_sec: 120 } as const;
const ENV_NAME = /^[A-Za-z_][A-Za-z0-9_]*$/;
const ID_PATTERN = /^[A-Za-z0-9_-]{1,64}$/;
const HEADER_NAME = /^[!#$%&'*+.^_\x60|~0-9A-Za-z-]+$/;
const BUILTINS: Builtin[] = [
  { id: 'amap', name: '高德地图', region: 'china', description: '查询 POI、路线与天气；不支持下单。',
    sourceUrl: 'https://modelscope.cn/mcp/servers/%40amap/amap-maps', setup: '在 mcp.env 设置 AMAP_MAPS_API_KEY。',
    requiredEnv: ['AMAP_MAPS_API_KEY'], config: {
      command: 'npx', args: ['-y', '@amap/amap-maps-mcp-server@0.0.8'],
      env: { AMAP_MAPS_API_KEY: '${AMAP_MAPS_API_KEY}' }, ...TIMEOUTS,
    } },
  { id: 'rail_12306', name: '12306 车次查询', region: 'china',
    description: '社区维护的铁路查询服务，可查车次与余票，不购票，也非 12306 官方 MCP。',
    sourceUrl: 'https://github.com/Joooook/12306-mcp', setup: '无需 API Key。', requiredEnv: [],
    config: { command: 'npx', args: ['-y', '12306-mcp@0.3.10'], ...TIMEOUTS } },
  { id: 'feishu', name: '飞书', region: 'china',
    description: '飞书官方 MCP；需要开放平台应用、相应权限和文档共享。',
    sourceUrl: 'https://github.com/larksuite/lark-openapi-mcp',
    setup: '在 mcp.env 设置 FEISHU_APP_ID 和 FEISHU_APP_SECRET。',
    requiredEnv: ['FEISHU_APP_ID', 'FEISHU_APP_SECRET'], config: {
      command: 'npx', args: ['-y', '@larksuiteoapi/lark-mcp@0.5.1', 'mcp', '-l', 'zh'],
      env: { APP_ID: '${FEISHU_APP_ID}', APP_SECRET: '${FEISHU_APP_SECRET}', LARK_DOMAIN: 'https://open.feishu.cn' },
      ...TIMEOUTS,
    } },
  { id: 'playwright', name: 'Playwright 浏览器', region: 'global',
    description: '使用隔离的无头浏览器；不加载个人 Chrome 档案，需要安装 Chrome。',
    sourceUrl: 'https://github.com/microsoft/playwright-mcp', setup: '无需 API Key；需安装 Chrome。',
    requiredEnv: [], config: {
      command: 'npx', args: ['-y', '@playwright/mcp@0.0.83', '--headless', '--isolated', '--browser', 'chrome'],
      ...TIMEOUTS,
    } },
  { id: 'fetch', name: '公开网页读取', region: 'global', description: '读取公开网页内容；不越权读取私人网页。',
    sourceUrl: 'https://github.com/modelcontextprotocol/servers/tree/main/src/fetch', setup: '无需 API Key。',
    requiredEnv: [], config: {
      command: 'uvx', args: ['--from', 'mcp-server-fetch==2026.10.19', 'mcp-server-fetch'], ...TIMEOUTS,
    } },
  { id: 'tavily', name: 'Tavily 搜索', region: 'global', description: '网页检索服务，需要 API Key，使用可能产生费用。',
    sourceUrl: 'https://github.com/tavily-ai/tavily-mcp', setup: '在 mcp.env 设置 TAVILY_API_KEY。',
    requiredEnv: ['TAVILY_API_KEY'], config: {
      command: 'npx', args: ['-y', 'tavily-mcp@0.2.22'],
      env: { TAVILY_API_KEY: '${TAVILY_API_KEY}' }, ...TIMEOUTS,
    } },
  { id: 'github', name: 'GitHub', region: 'global', description: 'GitHub 官方只读 MCP；令牌应采用最小权限。',
    sourceUrl: 'https://github.com/github/github-mcp-server',
    setup: '在 mcp.env 设置只读所需的 GITHUB_PERSONAL_ACCESS_TOKEN。',
    requiredEnv: ['GITHUB_PERSONAL_ACCESS_TOKEN'], config: {
      url: 'https://api.githubcopilot.com/mcp/',
      http_headers: { Authorization: 'Bearer ${GITHUB_PERSONAL_ACCESS_TOKEN}', 'X-MCP-Readonly': 'true' },
      ...TIMEOUTS,
    } },
  { id: 'notion', name: 'Notion', region: 'global', description: 'Notion 官方 MCP；需要 Integration 和页面授权。',
    sourceUrl: 'https://github.com/makenotion/notion-mcp-server',
    setup: '在 mcp.env 设置 NOTION_TOKEN，并授权 Integration 访问页面。',
    requiredEnv: ['NOTION_TOKEN'], config: {
      command: 'npx', args: ['-y', '@notionhq/notion-mcp-server@2.5.2'],
      env: { NOTION_TOKEN: '${NOTION_TOKEN}' }, ...TIMEOUTS,
    } },
];
const BUILTIN_BY_ID = new Map(BUILTINS.map((item) => [item.id, item]));
const RESERVED_IDS = new Set([
  'orbit_phone', '__proto__', 'prototype', 'constructor', 'toString', 'toLocaleString', 'valueOf',
  'hasOwnProperty', 'isPrototypeOf', 'propertyIsEnumerable', '__defineGetter__', '__defineSetter__',
  '__lookupGetter__', '__lookupSetter__',
]);
const CONFIG_KEYS = new Set(['type', 'enabled', 'command', 'args', 'cwd', 'env', 'url', 'headers', 'http_headers',
  'startup_timeout_sec', 'tool_timeout_sec', 'enabled_tools', 'disabled_tools']);

function isRecord(value: unknown): value is Record<string, any> { return typeof value === 'object' && value !== null && !Array.isArray(value); }
function fail(message: string): never { throw new Error(message); }
function validateId(id: string): void {
  if (!ID_PATTERN.test(id) || RESERVED_IDS.has(id) || id.startsWith('orbit_mcp_')) fail('MCP 服务 ID 无效或属于保留名称。');
}
function paths(options: McpRegistryOptions = {}) {
  const effectiveEnv = { ...process.env, ...options.env };
  const home = options.home ?? effectiveEnv.OPA_HOME ?? OPA_HOME ?? join(homedir(), '.opa');
  return { home, configPath: join(home, 'mcp.json'), envPath: join(home, 'mcp.env') };
}
function effectiveProcessEnv(options: McpRegistryOptions): NodeJS.ProcessEnv { return { ...process.env, ...options.env }; }
function readEnvFile(envPath: string): Record<string, string> {
  try {
    const result: Record<string, string> = {};
    for (const [key, value] of Object.entries(parseEnv(readFileSync(envPath, 'utf8')))) {
      if (value !== undefined) result[key] = value;
    }
    return result;
  } catch (error) {
    if (isRecord(error) && error.code === 'ENOENT') return {};
    fail('MCP 环境文件无法读取或格式无效；请检查 mcp.env。');
  }
}
function readState(configPath: string): RegistryState {
  let parsed: unknown;
  try { parsed = JSON.parse(readFileSync(configPath, 'utf8')); } catch (error) {
    if (isRecord(error) && error.code === 'ENOENT') return { presets: {}, mcpServers: {} };
    fail('MCP 配置文件无法读取或 JSON 格式无效；请检查 mcp.json。');
  }
  if (!isRecord(parsed)) fail('MCP 配置无效：根节点必须是对象。');
  if (Object.keys(parsed).some((key) => key !== 'presets' && key !== 'mcpServers')) fail('MCP 配置含有不支持的顶层字段。');
  const presets: RegistryState['presets'] = {};
  const sourcePresets = parsed.presets === undefined ? {} : parsed.presets;
  if (!isRecord(sourcePresets)) fail('MCP 配置无效：presets 必须是对象。');
  for (const [id, preset] of Object.entries(sourcePresets)) {
    validateId(id);
    if (!BUILTIN_BY_ID.has(id)) fail('MCP 配置包含未知的内置服务开关。');
    if (!isRecord(preset) || Object.keys(preset).some((key) => key !== 'enabled') || typeof preset.enabled !== 'boolean') {
      fail('MCP 配置无效：内置服务开关必须包含布尔值 enabled。');
    }
    presets[id] = { enabled: preset.enabled };
  }
  const mcpServers: RegistryState['mcpServers'] = {};
  const sourceServers = parsed.mcpServers === undefined ? {} : parsed.mcpServers;
  if (!isRecord(sourceServers)) fail('MCP 配置无效：mcpServers 必须是对象。');
  for (const [id, config] of Object.entries(sourceServers)) {
    validateId(id);
    if (BUILTIN_BY_ID.has(id)) fail('MCP 自定义服务 ID 与内置服务冲突。');
    mcpServers[id] = config as RawServerConfig;
  }
  return { presets, mcpServers };
}
function parseEnvTemplate(value: string): void {
  for (const match of value.matchAll(/\$\{([^}]*)\}/g)) if (!ENV_NAME.test(match[1])) fail('MCP 配置包含无效的环境变量模板。');
  if (value.replace(/\$\{[^}]*\}/g, '').includes('${')) fail('MCP 配置包含无效的环境变量模板。');
}
type NormalizeOptions = { expand: boolean; processEnv?: NodeJS.ProcessEnv; fileEnv?: Record<string, string> };
function normalizeServerConfig(raw: unknown, options: NormalizeOptions): NormalizedServer {
  if (!isRecord(raw)) fail('MCP 服务配置必须是对象。');
  if (Object.keys(raw).some((key) => !CONFIG_KEYS.has(key))) fail('MCP 服务配置包含不支持的字段。');
  if (raw.enabled !== undefined && typeof raw.enabled !== 'boolean') fail('MCP 服务 enabled 必须是布尔值。');
  const enabled = raw.enabled === undefined ? true : raw.enabled;
  if (raw.type !== undefined && typeof raw.type !== 'string') fail('MCP 服务 type 无效。');
  if (raw.type === 'sse') fail('该服务使用旧版 SSE；请改用 Streamable HTTP 地址后重新导入。');
  if (raw.type !== undefined && raw.type !== 'stdio' && raw.type !== 'http' && raw.type !== 'streamable-http') {
    fail('MCP 服务 type 只支持 stdio 或 Streamable HTTP。');
  }
  const hasCommand = raw.command !== undefined, hasUrl = raw.url !== undefined;
  const kind = raw.type === 'stdio' ? 'stdio' : raw.type === 'http' || raw.type === 'streamable-http' ? 'http' : hasCommand ? 'stdio' : 'http';
  if (hasCommand === hasUrl || (kind === 'stdio' && !hasCommand) || (kind === 'http' && !hasUrl)) {
    fail('MCP 服务必须且只能配置 command（stdio）或 url（Streamable HTTP）。');
  }
  const missing = new Set<string>(), processEnv = options.processEnv ?? {}, fileEnv = options.fileEnv ?? {};
  const expand = (value: string): string => {
    parseEnvTemplate(value);
    if (!options.expand) return value;
    const result = value.replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g, (_all, name: string) => {
      const p = processEnv[name], f = fileEnv[name], resolved = p !== undefined ? p : f;
      if (resolved === undefined || resolved === '') { missing.add(name); return '${' + name + '}'; }
      return resolved;
    });
    return result;
  };
  const output: McpServerConfig = { ...TIMEOUTS };
  const parseTimeout = (key: 'startup_timeout_sec' | 'tool_timeout_sec') => {
    const value = raw[key];
    if (value === undefined) return;
    if (typeof value !== 'number' || value !== TIMEOUTS[key]) {
      fail('MCP 超时固定为 startup_timeout_sec=90 和 tool_timeout_sec=120。');
    }
    output[key] = value;
  };
  parseTimeout('startup_timeout_sec'); parseTimeout('tool_timeout_sec');
  const parseToolList = (key: 'enabled_tools' | 'disabled_tools') => {
    const value = raw[key];
    if (value === undefined) return;
    if (!Array.isArray(value) || value.some((x) => typeof x !== 'string' || x.length === 0)) fail('MCP 工具过滤字段必须是非空字符串数组。');
    output[key] = [...value] as string[];
  };
  parseToolList('enabled_tools'); parseToolList('disabled_tools');
  if (kind === 'stdio') {
    if (raw.url !== undefined || raw.http_headers !== undefined || raw.headers !== undefined) fail('stdio 服务不能包含 HTTP 字段。');
    if (typeof raw.command !== 'string' || raw.command.trim() === '' || raw.command.includes('${')) {
      fail('stdio 服务 command 无效；环境变量模板只支持 args、env、url 和 http_headers。');
    }
    output.command = raw.command;
    if (raw.args !== undefined) {
      if (!Array.isArray(raw.args) || raw.args.some((x) => typeof x !== 'string')) fail('stdio 服务 args 必须是字符串数组。');
      output.args = raw.args.map(expand);
    } else output.args = [];
    if (raw.cwd !== undefined) {
      if (typeof raw.cwd !== 'string' || raw.cwd.length === 0 || raw.cwd.includes('${')) fail('stdio 服务 cwd 无效；环境变量模板只支持 args、env、url 和 http_headers。');
      output.cwd = raw.cwd;
    }
    if (raw.env !== undefined) {
      if (!isRecord(raw.env)) fail('stdio 服务 env 必须是字符串映射。');
      const env: Record<string, string> = {};
      for (const [key, value] of Object.entries(raw.env)) {
        if (!ENV_NAME.test(key) || typeof value !== 'string') fail('stdio 服务 env 必须是有效的字符串映射。');
        env[key] = expand(value);
      }
      output.env = env;
    }
  } else {
    if (raw.command !== undefined || raw.args !== undefined || raw.cwd !== undefined || raw.env !== undefined) fail('Streamable HTTP 服务不能包含 stdio 字段。');
    if (typeof raw.url !== 'string') fail('Streamable HTTP 服务 url 无效。');
    output.url = expand(raw.url);
    const urlTemplateNames = [...raw.url.matchAll(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g)].map((match) => match[1]);
    const unresolvedUrlTemplate = urlTemplateNames.some((name) => {
      if (!options.expand) return true;
      const processValue = processEnv[name], fileValue = fileEnv[name];
      const resolved = processValue !== undefined ? processValue : fileValue;
      return resolved === undefined || resolved === '';
    });
    if (!unresolvedUrlTemplate) {
      let parsedUrl: URL;
      try { parsedUrl = new URL(output.url); } catch { fail('Streamable HTTP 服务 url 必须是有效的 HTTP 或 HTTPS 地址。'); }
      if (!['http:', 'https:'].includes(parsedUrl.protocol) || !parsedUrl.hostname || parsedUrl.username || parsedUrl.password) {
        fail('Streamable HTTP 服务 url 必须是无凭据的 HTTP 或 HTTPS 地址。');
      }
    }
    if (raw.http_headers !== undefined && raw.headers !== undefined) fail('HTTP headers 与 http_headers 不能同时配置。');
    const rawHeaders = raw.http_headers ?? raw.headers;
    if (rawHeaders !== undefined) {
      if (!isRecord(rawHeaders)) fail('Streamable HTTP 服务 headers 必须是字符串映射。');
      const headers: Record<string, string> = {};
      for (const [key, value] of Object.entries(rawHeaders)) {
        if (!HEADER_NAME.test(key) || typeof value !== 'string') fail('Streamable HTTP 服务 http_headers 无效。');
        const expanded = expand(value);
        if (/[\r\n]/.test(expanded)) fail('Streamable HTTP 服务 header 值不能包含换行。');
        headers[key] = expanded;
      }
      output.http_headers = headers;
    }
  }
  return { config: output, enabled, missingEnv: [...missing].sort() };
}
function readInputs(options: McpRegistryOptions = {}) {
  const { configPath, envPath } = paths(options);
  return { state: readState(configPath), processEnv: effectiveProcessEnv(options), fileEnv: readEnvFile(envPath) };
}
function builtinEnabled(state: RegistryState, id: string): boolean { return state.presets[id]?.enabled ?? true; }
function catalogForBuiltin(item: Builtin, state: RegistryState, processEnv: NodeJS.ProcessEnv, fileEnv: Record<string, string>): McpCatalogItem {
  const base = {
    id: item.id, name: item.name, region: item.region, description: item.description, sourceUrl: item.sourceUrl,
    setup: item.setup, builtin: true, enabled: builtinEnabled(state, item.id),
  };
  try {
    const normalized = normalizeServerConfig(item.config, { expand: true, processEnv, fileEnv });
    const missingEnv = [...new Set([
      ...item.requiredEnv.filter((key) => {
        const p = processEnv[key], f = fileEnv[key];
        return p !== undefined ? p === '' : f === undefined || f === '';
      }),
      ...normalized.missingEnv,
    ])].sort();
    return { ...base, configured: missingEnv.length === 0, missingEnv, ...(missingEnv.length ? { reason: '缺少所需环境变量。' } : {}) };
  } catch { return { ...base, configured: false, missingEnv: [...item.requiredEnv], reason: '内置 MCP 配置无效。' }; }
}
function catalogForCustom(id: string, raw: RawServerConfig, processEnv: NodeJS.ProcessEnv, fileEnv: Record<string, string>): McpCatalogItem {
  const base = {
    id, name: id, region: 'global' as const, description: '用户自定义 MCP 服务。',
    sourceUrl: 'https://modelscope.cn/mcp/servers', setup: '从本地 MCP 配置导入。', builtin: false,
  };
  try {
    const n = normalizeServerConfig(raw, { expand: true, processEnv, fileEnv });
    return { ...base, enabled: n.enabled, configured: n.missingEnv.length === 0, missingEnv: n.missingEnv,
      ...(n.missingEnv.length ? { reason: '缺少所需环境变量。' } : {}) };
  } catch {
    return {
      ...base, enabled: isRecord(raw) && typeof raw.enabled === 'boolean' ? raw.enabled : true,
      configured: false, missingEnv: [], reason: '本地 MCP 配置无效。',
    };
  }
}

export function listMcpServices(options: McpRegistryOptions = {}): McpCatalogItem[] {
  const { state, processEnv, fileEnv } = readInputs(options);
  return [...BUILTINS.map((item) => catalogForBuiltin(item, state, processEnv, fileEnv)),
    ...Object.entries(state.mcpServers).sort(([a], [b]) => a.localeCompare(b)).map(([id, config]) => catalogForCustom(id, config, processEnv, fileEnv))];
}
export function resolveMcpServices(ids: readonly string[], options: McpRegistryOptions = {}): Record<string, McpServerConfig> {
  const { state, processEnv, fileEnv } = readInputs(options), resolved: Record<string, McpServerConfig> = {};
  for (const id of new Set(ids)) {
    validateId(id);
    const builtin = BUILTIN_BY_ID.get(id);
    if (builtin) {
      if (!builtinEnabled(state, id)) fail('MCP 服务已停用。');
      const n = normalizeServerConfig(builtin.config, { expand: true, processEnv, fileEnv });
      if (n.missingEnv.length) fail('MCP 服务缺少环境变量：' + n.missingEnv.join(', ') + '。');
      resolved['orbit_mcp_' + id] = n.config;
      continue;
    }
    if (!Object.hasOwn(state.mcpServers, id)) fail('未知 MCP 服务 ID。');
    const raw = state.mcpServers[id];
    const n = normalizeServerConfig(raw, { expand: true, processEnv, fileEnv });
    if (!n.enabled) fail('MCP 服务已停用。');
    if (n.missingEnv.length) fail('MCP 服务缺少环境变量：' + n.missingEnv.join(', ') + '。');
    resolved['orbit_mcp_' + id] = n.config;
  }
  return resolved;
}
function readJsonDocument(path: string, message: string): unknown {
  try { return JSON.parse(readFileSync(path, 'utf8')); } catch { fail(message); }
}
function writeExclusive(path: string, content: string): boolean {
  let fd: number;
  try { fd = openSync(path, 'wx', 0o600); } catch (error) {
    if (isRecord(error) && error.code === 'EEXIST') return false;
    throw error;
  }
  try { writeFileSync(fd, content, 'utf8'); fsyncSync(fd); } finally { closeSync(fd); }
  return true;
}
function atomicWrite(path: string, content: string): void {
  mkdirSync(dirname(path), { recursive: true });
  try { if (lstatSync(path).isSymbolicLink()) fail('拒绝写入符号链接形式的 MCP 配置。'); }
  catch (error) { if (!(isRecord(error) && error.code === 'ENOENT')) throw error; }
  const temporary = join(dirname(path), '.mcp-' + randomUUID() + '.tmp'), fd = openSync(temporary, 'wx', 0o600);
  try { writeFileSync(fd, content, 'utf8'); fsyncSync(fd); } catch (error) {
    closeSync(fd); try { unlinkSync(temporary); } catch {} throw error;
  }
  closeSync(fd);
  try { renameSync(temporary, path); } catch (error) { try { unlinkSync(temporary); } catch {} throw error; }
}
export function initializeMcpConfig(options: McpRegistryOptions = {}): { configPath: string; envPath: string; created: string[] } {
  const { home, configPath, envPath } = paths(options);
  mkdirSync(home, { recursive: true });
  const created: string[] = [];
  if (writeExclusive(configPath, JSON.stringify({ presets: {}, mcpServers: {} }, null, 2) + '\n')) created.push(configPath);
  const envTemplate = [
    '# Local MCP credentials. Keep this file private; do not commit it.',
    '# Process environment variables take precedence over values in this file.',
    '# AMAP_MAPS_API_KEY=', '# FEISHU_APP_ID=', '# FEISHU_APP_SECRET=', '# TAVILY_API_KEY=',
    '# GITHUB_PERSONAL_ACCESS_TOKEN=', '# NOTION_TOKEN=', '',
  ].join('\n');
  if (writeExclusive(envPath, envTemplate)) created.push(envPath);
  return { configPath, envPath, created };
}
export function setMcpServiceEnabled(id: string, enabled: boolean, options: McpRegistryOptions = {}): void {
  validateId(id);
  if (typeof enabled !== 'boolean') fail('MCP 服务 enabled 必须是布尔值。');
  const { configPath } = paths(options), state = readState(configPath);
  if (BUILTIN_BY_ID.has(id)) state.presets[id] = { enabled };
  else {
    const raw = state.mcpServers[id];
    if (!Object.hasOwn(state.mcpServers, id)) fail('未知 MCP 服务 ID。');
    if (!isRecord(raw)) fail('MCP 自定义服务配置无效。');
    state.mcpServers[id] = { ...raw, enabled };
  }
  atomicWrite(configPath, JSON.stringify(state, null, 2) + '\n');
}
function parseImportDocument(path: string): Record<string, unknown> {
  const parsed = readJsonDocument(path, 'MCP 导入文件无法读取或 JSON 格式无效。');
  if (!isRecord(parsed) || Object.keys(parsed).some((key) => key !== 'mcpServers') || !isRecord(parsed.mcpServers)) {
    fail('MCP 导入文件只接受 {"mcpServers": {...}} 格式。');
  }
  return parsed.mcpServers;
}
export function importMcpServices(path: string, options: McpRegistryOptions = {}): string[] {
  const { configPath } = paths(options), state = readState(configPath), imported = parseImportDocument(path);
  const normalizedIncoming: Record<string, RawServerConfig> = {};
  for (const [id, raw] of Object.entries(imported)) {
    validateId(id);
    if (BUILTIN_BY_ID.has(id)) fail('MCP 自定义服务 ID 与内置服务冲突。');
    const n = normalizeServerConfig(raw, { expand: false }), priorEnabled = state.mcpServers[id]?.enabled;
    const enabled = isRecord(raw) && typeof raw.enabled === 'boolean' ? raw.enabled : priorEnabled ?? n.enabled;
    normalizedIncoming[id] = { ...n.config, enabled };
  }
  const next: RegistryState = { presets: state.presets, mcpServers: { ...state.mcpServers, ...normalizedIncoming } };
  atomicWrite(configPath, JSON.stringify(next, null, 2) + '\n');
  return Object.keys(normalizedIncoming);
}

