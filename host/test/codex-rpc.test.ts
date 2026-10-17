// CodexRpc must survive a missing / broken codex binary: no unhandled 'error', pending requests rejected, one 'exit' per child.
import type { ChildProcess } from 'node:child_process';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { CodexRpc } from '../src/codex/rpc.ts';
import { log } from '../src/util/log.ts';

const settle = (ms = 100) => new Promise<void>((r) => setTimeout(r, ms));
/** Not `events.once`: that one also rejects on 'error', which these tests emit on purpose. */
const exitOf = (proc: ChildProcess) => new Promise<void>((r) => proc.once('exit', () => r()));

describe('CodexRpc when the child cannot run', () => {
  const cleanups: (() => void)[] = [];
  afterEach(() => { while (cleanups.length) cleanups.pop()!(); vi.restoreAllMocks(); });

  /** An rpc over `bin` that records every 'exit' it emits. */
  function make(bin: string, args: string[] = []) {
    const rpc = new CodexRpc(bin, args);
    const exits: unknown[] = [];
    rpc.on('exit', (code) => exits.push(code));
    cleanups.push(() => rpc.stop());
    return { rpc, exits };
  }

  it('a missing binary (ENOENT) rejects pending requests, does not crash, and emits exit once', async () => {
    const errors = vi.spyOn(log, 'error').mockImplementation(() => {});
    const { rpc, exits } = make('/nonexistent/codex');

    rpc.start();
    // Same order as CodexBridge.start(): spawn, then send `initialize` straight away.
    await expect(rpc.request('initialize', {})).rejects.toThrow(/ENOENT/);
    await settle(); // let the stdin / process 'close' events drain; an unhandled 'error' would fail the run here

    expect(exits).toEqual([null]);
    const lines = errors.mock.calls.map((c) => c.slice(1).join(' '));
    expect(lines.some((l) => l.includes('ENOENT'))).toBe(true);
    expect(lines.some((l) => l.includes('找不到 codex 命令') && l.includes('OPA_CODEX_BIN'))).toBe(true);

    // Nothing is running any more: further requests fail right away instead of waiting for the timeout.
    await expect(rpc.request('thread/list', {}, 60_000)).rejects.toThrow(/not running/);
    expect(exits).toHaveLength(1);
  });

  it('can be started again after a failed start (the bridge restarts it 3 s later), and exits once per attempt', async () => {
    vi.spyOn(log, 'error').mockImplementation(() => {});
    const { rpc, exits } = make('/nonexistent/codex');

    for (let attempt = 1; attempt <= 2; attempt++) {
      rpc.start();
      await expect(rpc.request('initialize', {})).rejects.toThrow(/ENOENT/);
      await settle();
      expect(exits).toHaveLength(attempt);
    }
  });

  it("'error' followed by the real 'exit' of the same child emits exit only once", async () => {
    vi.spyOn(log, 'error').mockImplementation(() => {});
    const { rpc, exits } = make(process.execPath, ['-e', 'setInterval(() => {}, 1000)']);

    rpc.start();
    const proc = (rpc as unknown as { proc: ChildProcess }).proc;
    const hanging = rpc.request('never/answered', {}, 30_000);
    const exited = exitOf(proc);

    proc.emit('error', Object.assign(new Error('boom'), { code: 'EBOOM' }));
    await expect(hanging).rejects.toThrow(/EBOOM/);
    await exited; // the child that errored is killed so it cannot linger beside its replacement
    await settle(50);

    expect(exits).toEqual([null]);
  });

  it('a normal exit still rejects pending requests with the exit code and emits it once', async () => {
    const { rpc, exits } = make(process.execPath, ['-e', 'setTimeout(() => process.exit(3), 100)']);

    rpc.start();
    await expect(rpc.request('initialize', {}, 10_000)).rejects.toThrow('codex exited (3)');
    await settle(50);

    expect(exits).toEqual([3]);
  });

  it('writing to a child that already exited does not crash (EPIPE is only logged)', async () => {
    const debug = vi.spyOn(log, 'debug').mockImplementation(() => {});
    const { rpc } = make(process.execPath, ['-e', '']);

    rpc.start();
    const proc = (rpc as unknown as { proc: ChildProcess }).proc;
    await exitOf(proc);
    // Some Node versions keep stdin writable until 'close'; either way the write must not throw an unhandled 'error'.
    proc.stdin!.emit('error', Object.assign(new Error('write EPIPE'), { code: 'EPIPE' }));
    await settle(50);

    expect(debug.mock.calls.some((c) => c.join(' ').includes('EPIPE'))).toBe(true);
  });
});
