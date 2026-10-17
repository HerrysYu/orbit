import assert from 'node:assert/strict';
import { CodexBridge } from '../src/codex/bridge.ts';
import { phoneMcpConfig } from '../src/phone/config.ts';

const RPC_TIMEOUT_MS = 45_000;
const bridge = new CodexBridge();
const activeThreadIds: string[] = [];
const rawRpcRequest = bridge.rpc.request.bind(bridge.rpc);
bridge.rpc.request = ((method: string, params?: unknown, timeoutMs = RPC_TIMEOUT_MS) =>
  rawRpcRequest(method, params, Math.min(timeoutMs, RPC_TIMEOUT_MS))) as typeof bridge.rpc.request;

async function request<T>(method: string, params: unknown): Promise<T> {
  return bridge.rpc.request<T>(method, params, RPC_TIMEOUT_MS);
}

function withTimeout<T>(promise: Promise<T>, label: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`${label} timed out`)), RPC_TIMEOUT_MS);
    promise.then((value) => { clearTimeout(timer); resolve(value); }, (error) => { clearTimeout(timer); reject(error); });
  });
}

async function statusFor(threadId: string): Promise<any[]> {
  const response = await request<any>('mcpServerStatus/list', { threadId });
  return response.data ?? [];
}

function parseDevices(result: any): { status: string; devices: unknown[]; message?: string } {
  if (result?.isError) throw new Error('phone_devices returned an MCP error');
  const structured = result?.structuredContent;
  if (structured && typeof structured.status === 'string' && Array.isArray(structured.devices)) return structured;
  for (const item of result?.content ?? []) {
    if (typeof item?.text !== 'string') continue;
    try {
      const parsed = JSON.parse(item.text);
      if (typeof parsed.status === 'string' && Array.isArray(parsed.devices)) return parsed;
    } catch { /* try another content item */ }
  }
  throw new Error('phone_devices returned no parseable device status');
}

try {
  const config = phoneMcpConfig();
  assert.ok(config, 'phone config is unavailable; run opa phone setup first');
  await withTimeout(bridge.start(), 'app-server initialize');

  const common = {
    cwd: process.cwd(),
    ephemeral: true,
    approvalPolicy: 'never',
    sandbox: 'read-only',
    serviceName: 'opa-phone-smoke',
  };
  const phone = await request<any>('thread/start', {
    ...common,
    config: {
      mcp_servers: { orbit_phone: config },
      features: { computer_use: false },
    },
  });
  const phoneThreadId = phone.thread.id as string;
  activeThreadIds.push(phoneThreadId);

  let phoneServers: any[] = [];
  let orbitPhone: any;
  const deadline = Date.now() + RPC_TIMEOUT_MS;
  while (Date.now() < deadline) {
    phoneServers = await statusFor(phoneThreadId);
    orbitPhone = phoneServers.find((server) => server.name === 'orbit_phone');
    if (orbitPhone?.tools && Object.keys(orbitPhone.tools).length > 0) break;
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  assert.ok(orbitPhone, 'phone thread did not expose orbit_phone');
  const tools = Object.keys(orbitPhone.tools ?? {}).sort();
  assert.ok(tools.includes('phone_devices'), `phone_devices missing from tools: ${tools.join(', ')}`);
  assert.ok(tools.includes('phone_observe'), `phone_observe missing from tools: ${tools.join(', ')}`);

  // phone_devices is an explicit read-only enumeration. Do not call begin, observe,
  // or any action tool from this smoke script.
  const deviceResult = await request<any>('mcpServer/tool/call', {
    threadId: phoneThreadId, server: 'orbit_phone', tool: 'phone_devices', arguments: {},
  });
  const deviceStatus = parseDevices(deviceResult);
  assert.ok(['ok', 'unavailable'].includes(deviceStatus.status), `unexpected phone_devices status: ${deviceStatus.status}`);

  const plain = await request<any>('thread/start', common);
  const plainThreadId = plain.thread.id as string;
  activeThreadIds.push(plainThreadId);
  const plainServers = await statusFor(plainThreadId);
  assert.ok(!plainServers.some((server) => server.name === 'orbit_phone'), 'orbit_phone leaked into a thread without phone config');

  console.log(JSON.stringify({
    result: 'passed',
    phoneThreadId,
    phoneTools: tools,
    phoneThreadHasOrbitPhone: true,
    phoneDevices: {
      status: deviceStatus.status,
      connectedCount: deviceStatus.devices.length,
      message: deviceStatus.message,
    },
    plainThreadId,
    plainThreadHasOrbitPhone: false,
    modelTurnsStarted: 0,
  }, null, 2));
} finally {
  for (const threadId of activeThreadIds) {
    await request('thread/archive', { threadId }).catch(() => {});
  }
  // Avoid CodexBridge's general restart-on-exit listener during deliberate smoke cleanup.
  bridge.rpc.removeAllListeners('exit');
  bridge.rpc.stop();
}
