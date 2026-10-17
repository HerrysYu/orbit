// Minimal JSON-RPC (newline-delimited, no "jsonrpc" header) client for `codex app-server`.
import { spawn, type ChildProcess } from 'node:child_process';
import { EventEmitter } from 'node:events';
import { log } from '../util/log.ts';

export interface RpcError { code: number; message: string; data?: unknown }

export class RpcRemoteError extends Error {
  constructor(public method: string, public rpc: RpcError) {
    super(`${method}: ${rpc.message}`);
  }
}

type Pending = { resolve: (v: any) => void; reject: (e: Error) => void; method: string; timer: NodeJS.Timeout };

/**
 * Events:
 *  - 'notification' (method, params)
 *  - 'request' (id, method, params) — server→client request, answer with respond()/respondError()
 *  - 'exit' (code)
 */
export class CodexRpc extends EventEmitter {
  private proc?: ChildProcess;
  private buf = '';
  private nextId = 1;
  private pending = new Map<number | string, Pending>();

  constructor(private bin = process.env.OPA_CODEX_BIN ?? 'codex', private args: string[] = ['app-server', '--listen', 'stdio://']) {
    super();
  }

  start(): void {
    const proc = spawn(this.bin, this.args, { stdio: ['pipe', 'pipe', 'pipe'], env: process.env });
    this.proc = proc;

    // One child can report both 'error' and 'exit'; whoever listens to this class must see 'exit' exactly once per child.
    let ended = false;
    const end = (code: number | null, reason: string) => {
      if (ended) return;
      ended = true;
      for (const p of this.pending.values()) { clearTimeout(p.timer); p.reject(new Error(reason)); }
      this.pending.clear();
      this.emit('exit', code);
    };

    proc.stdout!.setEncoding('utf8');
    proc.stdout!.on('data', (d: string) => this.onData(d));
    proc.stderr!.setEncoding('utf8');
    proc.stderr!.on('data', (d: string) => log.debug('codex', d.trim()));
    // Writing to a process that already died (or never started) surfaces here (EPIPE etc.); the 'exit' path owns the cleanup.
    proc.stdin!.on('error', (e) => log.debug('codex', 'stdin error:', e.message));
    // Without this listener a failed spawn (ENOENT, EACCES, …) is an unhandled 'error' event and takes the whole Host down.
    proc.on('error', (e: NodeJS.ErrnoException) => {
      log.error('codex', `cannot run "${this.bin}": ${e.code ?? e.message}`);
      if (e.code === 'ENOENT') log.error('codex', '找不到 codex 命令：请安装并登录 Codex CLI，或设置 OPA_CODEX_BIN');
      // A child that did start but errored anyway (e.g. kill failed) must not linger next to its replacement.
      if (proc.pid !== undefined) { try { proc.kill(); } catch { /* already gone */ } }
      end(null, `codex failed to start (${e.code ?? e.message})`);
    });
    proc.on('exit', (code) => end(code, `codex exited (${code})`));
  }

  stop(): void { this.proc?.kill(); }

  private onData(chunk: string) {
    this.buf += chunk;
    let i: number;
    while ((i = this.buf.indexOf('\n')) >= 0) {
      const line = this.buf.slice(0, i).trim();
      this.buf = this.buf.slice(i + 1);
      if (!line) continue;
      let msg: any;
      try { msg = JSON.parse(line); } catch { log.warn('codex', 'bad json line', line.slice(0, 200)); continue; }
      this.dispatch(msg);
    }
  }

  private dispatch(msg: any) {
    if (msg.method && msg.id !== undefined) {
      this.emit('request', msg.id, msg.method, msg.params);
    } else if (msg.method) {
      this.emit('notification', msg.method, msg.params);
    } else if (msg.id !== undefined) {
      const p = this.pending.get(msg.id);
      if (!p) return;
      this.pending.delete(msg.id);
      clearTimeout(p.timer);
      if (msg.error) p.reject(new RpcRemoteError(p.method, msg.error));
      else p.resolve(msg.result);
    }
  }

  private write(obj: unknown) {
    if (!this.proc?.stdin?.writable) throw new Error('codex app-server not running');
    this.proc.stdin.write(JSON.stringify(obj) + '\n');
  }

  request<T = any>(method: string, params?: unknown, timeoutMs = 120_000): Promise<T> {
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`${method} timed out`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, method, timer });
      try { this.write({ id, method, params }); } catch (e) { clearTimeout(timer); this.pending.delete(id); reject(e as Error); }
    });
  }

  notify(method: string, params?: unknown) { this.write(params === undefined ? { method } : { method, params }); }
  respond(id: number | string, result: unknown) { this.write({ id, result }); }
  respondError(id: number | string, code: number, message: string) { this.write({ id, error: { code, message } }); }
}
