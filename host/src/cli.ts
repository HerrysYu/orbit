// opa — OpenPersonalAgent host CLI.
//   opa start                 run the host (gateway + butler + codex bridge)
//   opa pair                  show a pairing QR code and confirm the SAS code
//   opa chat                  talk to the butler from the terminal (for testing without the phone)
//   opa status | devices | unpair <deviceId>
//   opa phone setup | status
//   opa config relay <wss://…> | port <n> | bundle-id <id> | phone-notify on|off
//   opa install-skills        link skills/china-services and phone-automation into ~/.codex/skills
import { createInterface } from 'node:readline/promises';
import { existsSync, mkdirSync, symlinkSync, writeFileSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { stdin, stdout } from 'node:process';
import { spawnSync } from 'node:child_process';
import qrcode from 'qrcode-terminal';
import { DEFAULT_PHONE_SERIAL, PHONE_DIR, phoneConfigStatus } from './phone/config.ts';
import { controlClient } from './control.ts';
import { Db } from './store/db.ts';
import { SKILLS_DIR } from './codex/bridge.ts';

const [cmd, ...args] = process.argv.slice(2);

async function main() {
  switch (cmd) {
    case 'start': {
      const { Host } = await import('./app.ts');
      const { startControl } = await import('./control.ts');
      const host = new Host();
      await host.start();
      startControl(host);
      const stop = () => { host.gw.stop(); host.bridge.rpc.stop(); process.exit(0); };
      process.on('SIGINT', stop);
      process.on('SIGTERM', stop);
      return;
    }
    case 'pair': return pair();
    case 'chat': return chat();
    case 'status': case 'devices': {
      const c = await connect();
      const r = await c.send(cmd === 'status' ? { cmd: 'status' } : { cmd: 'req', m: 'devices.list' });
      console.log(JSON.stringify(r.d, null, 2));
      return c.close();
    }
    case 'unpair': {
      const c = await connect();
      console.log((await c.send({ cmd: 'unpair', deviceId: args[0] })).ok ? '已解除配对' : '失败');
      return c.close();
    }
    case 'config': return config();
    case 'phone': return phone();
    case 'install-skills': {
      const dest = join(homedir(), '.codex/skills');
      mkdirSync(dest, { recursive: true });
      for (const name of ['china-services', 'phone-automation']) {
        const target = join(dest, name);
        if (existsSync(target)) { console.log(`${target} 已存在，跳过`); continue; }
        symlinkSync(resolve(SKILLS_DIR, name), target);
        console.log(`已链接 ${target} → ${resolve(SKILLS_DIR, name)}`);
      }
      return;
    }
    case 'launchd': return launchd();
    default:
      console.log(readFileSync(new URL(import.meta.url), 'utf8').split('\n').filter((l) => l.startsWith('//')).map((l) => l.slice(3)).join('\n'));
  }
}

async function phone() {
  const [subcommand] = args;
  if (subcommand === 'setup') return phoneSetup();
  if (subcommand === 'status') return phoneStatus();
  console.error('用法：opa phone setup | status');
  process.exitCode = 2;
}

function phoneSetup() {
  const r = spawnSync('uv', ['sync'], { cwd: PHONE_DIR, stdio: 'inherit', timeout: 10 * 60_000 });
  if (r.error) {
    console.error(`uv sync 启动失败：${r.error.message}`);
    process.exitCode = 1;
  } else if (r.status !== 0) {
    console.error(`uv sync 失败${r.status === null ? `（${r.signal ?? '未知原因'}）` : `（退出码 ${r.status}）`}`);
    process.exitCode = 1;
  }
}

function phoneStatus() {
  const config = phoneConfigStatus();
  const serial = process.env.OPA_PHONE_SERIAL || DEFAULT_PHONE_SERIAL;
  console.log(`手机自动化配置：${JSON.stringify(config, null, 2)}`);
  if (!config.available) process.exitCode = 1;
  const devices = runPhoneCommand('adb', ['devices', '-l'], 5_000);
  if (!devices.ok) {
    console.error(`无法执行 adb devices -l：${devices.error}`);
    process.exitCode = 1;
    return;
  }
  console.log(devices.stdout.trimEnd());
  const entries = devices.stdout.split(/\r?\n/).slice(1).map((line) => /^\s*(\S+)\s+(\S+)/.exec(line)).filter(Boolean) as RegExpExecArray[];
  const selected = entries.find((entry) => entry[1] === serial);
  if (!selected) {
    console.error(`未发现选定设备 ${serial}。连接小米手机并在手机上授权 USB 调试后重试。`);
    process.exitCode = 1;
    return;
  }
  if (selected[2] !== 'device') {
    console.error(`设备 ${serial} 当前状态为 ${selected[2]}；请在手机上处理授权或连接状态。`);
    process.exitCode = 1;
    return;
  }

  const packages = runPhoneCommand('adb', ['-s', serial, 'shell', 'pm', 'list', 'packages', 'com.android.adbkeyboard'], 5_000);
  const imes = runPhoneCommand('adb', ['-s', serial, 'shell', 'ime', 'list', '-s'], 5_000);
  if (!packages.ok || !imes.ok) {
    console.error(`检查 ADB Keyboard 失败：${packages.error ?? imes.error}`);
    process.exitCode = 1;
    return;
  }
  const installed = packages.stdout.split(/\r?\n/).some((line) => line.trim() === 'package:com.android.adbkeyboard');
  const enabled = imes.stdout.split(/\r?\n/).some((line) => line.includes('com.android.adbkeyboard'));
  console.log(`ADB Keyboard：${installed ? '已安装' : '未安装'}，输入法${enabled ? '已启用' : '未启用'}`);
  if (!installed || !enabled) process.exitCode = 1;

  const safeDebug = runPhoneCommand('adb', ['-s', serial, 'shell', 'input', 'keyevent', '0'], 5_000);
  const debugOutput = `${safeDebug.stdout}\n${safeDebug.stderr}`;
  const permissionDenied = /securityexception|inject_events|permission denial|permission denied|not allowed to inject/i.test(debugOutput);
  if (safeDebug.ok && !permissionDenied) console.log('USB 调试（安全设置）：检查通过');
  else {
    const detail = permissionDenied ? debugOutput.trim().slice(0, 300) : safeDebug.error;
    console.error(`USB 调试（安全设置）检查失败；请在开发者选项中开启该设置。${detail ? `详情：${detail}` : ''}`);
    process.exitCode = 1;
  }
}

function runPhoneCommand(command: string, argv: string[], timeout: number) {
  const result = spawnSync(command, argv, { encoding: 'utf8', timeout, maxBuffer: 1024 * 1024 });
  const spawnError = result.error as NodeJS.ErrnoException | undefined;
  const error = spawnError?.code === 'ETIMEDOUT' ? `命令超时（${timeout} ms）` : spawnError?.message;
  const stderr = result.stderr?.trim();
  return { ok: !error && result.status === 0, stdout: result.stdout ?? '', stderr: result.stderr ?? '', error: error ?? (result.status === 0 ? undefined : `退出码 ${result.status ?? result.signal ?? '未知'}${stderr ? `：${stderr.slice(0, 300)}` : ''}`) };
}

async function connect() {
  try {
    return await controlClient(() => {});
  } catch {
    console.error('连接不到 host。先在另一个终端运行：opa start');
    process.exit(1);
  }
}

async function pair() {
  const rl = createInterface({ input: stdin, output: stdout });
  let c!: Awaited<ReturnType<typeof controlClient>>;
  try {
    c = await controlClient(async (f) => {
      if (f.t !== 'pairing') return;
      console.log(`\n📱 设备「${f.deviceName}」请求配对。`);
      console.log(`   请核对手机上显示的代码：\x1b[1m${f.sas}\x1b[0m`);
      const ans = (await rl.question('   一致吗？(y/N) ')).trim().toLowerCase();
      await c.send({ cmd: 'confirm', sas: f.sas, ok: ans === 'y' || ans === 'yes' });
      console.log(ans.startsWith('y') ? '✅ 已配对' : '❌ 已拒绝');
      rl.close(); c.close(); process.exit(0);
    });
  } catch {
    console.error('连接不到 host。先运行：opa start'); process.exit(1);
  }
  const r = await c.send({ cmd: 'pair' });
  qrcode.generate(r.link, { small: true });
  console.log(`\n用 OPA App 扫描上面的二维码（或在 App 里粘贴下面的链接），5 分钟内有效：\n${r.link}\n`);
  console.log(`局域网地址：${r.payload.lan.map((l: any) => `${l.host}:${l.port}`).join(', ') || '无'}  Relay：${r.payload.relay ?? '未配置'}`);
  console.log('等待手机连接…');
}

async function chat() {
  const rl = createInterface({ input: stdin, output: stdout });
  let streaming = false;
  const c = await controlClient((f) => {
    if (f.t === 'live' && f.k === 'msg.start') { streaming = true; stdout.write('\n\x1b[36mOrbit>\x1b[0m '); }
    else if (f.t === 'live' && f.k === 'msg.delta') stdout.write(f.d.text);
    else if (f.t === 'ev' && f.k === 'msg.assistant') { if (!streaming) stdout.write(`\n\x1b[36mOrbit>\x1b[0m ${f.d.text}`); streaming = false; stdout.write('\n'); }
    else if (f.t === 'ev' && f.k === 'ui.render') stdout.write(`\n\x1b[33m[卡片 ${f.d.card.component} ${f.d.card.id}]\x1b[0m ${JSON.stringify(f.d.card.props).slice(0, 400)}${f.d.card.actions ? ` 按钮:${f.d.card.actions.map((a: any) => a.id).join('/')}` : ''}\n`);
    else if (f.t === 'ev' && f.k === 'ui.patch') stdout.write(`\x1b[33m[卡片更新 ${f.d.id}]\x1b[0m ${JSON.stringify(f.d.props).slice(0, 200)}\n`);
    else if (f.t === 'ev' && f.k === 'task.upsert') stdout.write(`\x1b[35m[任务 ${f.d.status}]\x1b[0m ${f.d.title} ${f.d.steps.map((s: any) => `${s.title}:${s.status}`).join(' → ')}\n`);
    else if (f.t === 'ev' && f.k === 'approval.request') stdout.write(`\x1b[31m[审批 ${f.d.id}]\x1b[0m ${f.d.title}：${f.d.detail.slice(0, 200)}  （输入 /approve ${f.d.id} 或 /deny ${f.d.id}）\n`);
    else if (f.t === 'live' && f.k === 'butler.status' && f.d.state === 'acting' && f.d.detail) stdout.write(`\x1b[2m  · ${f.d.detail}${f.d.tool ? `（${f.d.tool}）` : ''}\x1b[0m\n`);
    else if (f.t === 'live' && f.k === 'session.progress') stdout.write(`\x1b[2m  ⚙ ${f.d.sessionId.slice(0, 8)} ${f.d.text}\x1b[0m\n`);
  }).catch(() => { console.error('连接不到 host。先运行：opa start'); process.exit(1); });
  await c.send({ cmd: 'events' });
  console.log('和 Orbit 对话。/stop 打断，/approve <id>，/deny <id>，/click <cardId> <actionId> [json]，/quit 退出。');
  for (;;) {
    const line = (await rl.question('\n你> ')).trim();
    if (!line) continue;
    if (line === '/quit') break;
    if (line === '/stop') { await c.send({ cmd: 'req', m: 'chat.interrupt' }); continue; }
    const [k, a1, a2, ...rest] = line.split(' ');
    if (k === '/approve' || k === '/deny') { await c.send({ cmd: 'req', m: 'approval.respond', d: { approvalId: a1, decision: k === '/approve' ? 'approve' : 'deny' } }); continue; }
    if (k === '/click') { await c.send({ cmd: 'req', m: 'ui.action', d: { cardId: a1, actionId: a2, value: rest.length ? JSON.parse(rest.join(' ')) : undefined } }); continue; }
    await c.send({ cmd: 'req', m: 'chat.send', d: { clientId: String(Date.now()), text: line } });
  }
  rl.close(); c.close();
}

async function config() {
  const db = new Db();
  const [k, v] = args;
  if (k === 'relay') { db.set('config.relayUrl', v); console.log('relay =', v); }
  else if (k === 'port') { db.set('config.port', Number(v)); console.log('port =', v); }
  else if (k === 'bundle-id') { db.set('config.bundleId', v); console.log('bundleId =', v); }
  else if (k === 'phone-notify') {
    // The running host re-reads this on every poll, so no restart is needed. OPA_PHONE_NOTIFY=0 also switches it off.
    if (v === 'on' || v === 'off') { db.set('config.phoneNotify', v === 'on'); console.log('phone-notify =', v); }
    else if (v === undefined) console.log('phone-notify =', db.get<boolean>('config.phoneNotify') === false ? 'off' : 'on');
    else { console.error('用法：opa config phone-notify on|off'); process.exitCode = 2; }
  }
  else console.log('用法：opa config relay <wss://…> | port <n> | bundle-id <id> | phone-notify on|off');
}

/** Write a LaunchAgent so the host starts at login and restarts on crash. */
async function launchd() {
  const plist = join(homedir(), 'Library/LaunchAgents/com.openpersonalagent.host.plist');
  const bin = resolve(import.meta.dirname, '../bin/opa.mjs');
  writeFileSync(plist, `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.openpersonalagent.host</string>
  <key>ProgramArguments</key><array><string>${process.execPath}</string><string>${bin}</string><string>start</string></array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>${process.env.PATH}</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${join(homedir(), '.opa/host.log')}</string>
  <key>StandardErrorPath</key><string>${join(homedir(), '.opa/host.log')}</string>
</dict></plist>
`);
  console.log(`已写入 ${plist}\n启用：launchctl load -w ${plist}`);
}

await main();
