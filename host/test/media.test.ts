// embedCardImages: Mac-local / plain-http card images become data URLs the phone can show. The resizer and fetch are injected, so
// nothing here needs sips or the network (the default sips resizer is exercised through a stub executable at the end).
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, truncateSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { embedCardImages } from '../src/butler/media.ts';
import { TOOL_MAP } from '../src/butler/tools.ts';
import { OPA_HOME } from '../src/store/db.ts';
import { log } from '../src/util/log.ts';

let home: string; // plays OPA_HOME
let outside: string; // a directory next to it
let warn: ReturnType<typeof spyWarn>;
const spyWarn = () => vi.spyOn(log, 'warn').mockImplementation(() => {});

beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), 'media-test-home-'));
  outside = mkdtempSync(join(tmpdir(), 'media-test-outside-'));
  warn = spyWarn();
});
afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
  rmSync(home, { recursive: true, force: true });
  rmSync(outside, { recursive: true, force: true });
});

const file = (dir: string, name: string, content: string | Buffer) => {
  const path = join(dir, name);
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, content);
  return path;
};
const jpegUrl = (content: string | Buffer) => `data:image/jpeg;base64,${Buffer.from(content).toString('base64')}`;
const gallery = (...urls: string[]) => ({ title: 'shots', images: urls.map((url, i) => ({ url, caption: `c${i}` })) });
const urls = (props: Record<string, any>): string[] => props.images.map((i: any) => i.url);
const payloadLen = (url: string) => url.length - url.indexOf(',') - 1;
/** A fake "shrinker": tags the first bytes it was given, so a test can tell which source ended up where. */
const resizer = () => vi.fn(async (input: Buffer) => Buffer.from(`jpeg:${input.subarray(0, 8).toString('latin1')}`));
const imageResponse = (body: string | Buffer, type = 'image/png', headers: Record<string, string> = {}) =>
  new Response(body as BodyInit, { headers: { 'content-type': type, ...headers } });
const asFetch = (fn: unknown) => fn as typeof fetch;

describe('local files', () => {
  it('embeds a file under OPA_HOME as a data URL, without modifying the input', async () => {
    const path = file(home, 'phone/evidence/a.jpg', 'AAAA');
    const props = { title: 'shots', images: [{ url: path, caption: 'shot' }] };
    const before = structuredClone(props);
    const resize = resizer();
    const out = await embedCardImages('image_gallery', props, { home, resize });
    expect(out).not.toBe(props);
    expect(out).toEqual({ title: 'shots', images: [{ url: jpegUrl('jpeg:AAAA'), caption: 'shot' }] });
    expect(props).toEqual(before);
    expect(resize).toHaveBeenCalledTimes(1);
    expect(resize.mock.calls[0][0].toString()).toBe('AAAA');
    expect(warn).not.toHaveBeenCalled();
  });

  it('accepts file:// URLs, and OPA_HOME reached through a symlink', async () => {
    const path = file(home, 'x/b.jpg', 'BBBB');
    const link = join(outside, 'home-link'); // the tmp dir itself is behind a symlink on macOS (/var -> /private/var): both sides must be resolved
    symlinkSync(home, link);
    const resize = resizer();
    expect(urls(await embedCardImages('image_gallery', gallery(pathToFileURL(path).href), { home, resize }))).toEqual([jpegUrl('jpeg:BBBB')]);
    expect(urls(await embedCardImages('image_gallery', gallery(join(link, 'x/b.jpg')), { home: link, resize }))).toEqual([jpegUrl('jpeg:BBBB')]);
    expect(urls(await embedCardImages('image_gallery', gallery(path), { home: link, resize }))).toEqual([jpegUrl('jpeg:BBBB')]);
  });

  it('uses OPA_HOME when no home is given', async () => {
    mkdirSync(OPA_HOME, { recursive: true });
    const dir = mkdtempSync(join(OPA_HOME, 'media-test-'));
    try {
      const path = file(dir, 'a.jpg', 'AAAA');
      expect(urls(await embedCardImages('image_gallery', gallery(path), { resize: resizer() }))).toEqual([jpegUrl('jpeg:AAAA')]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it('leaves paths outside OPA_HOME as they are and warns once', async () => {
    const secret = file(outside, 'secret.jpg', 'SECRET');
    const escape = join(home, 'escape.jpg'); // inside, but a symlink to the outside
    symlinkSync(secret, escape);
    const resize = resizer();
    for (const url of [secret, `${home}/../${basename(outside)}/secret.jpg`, escape, pathToFileURL(secret).href]) {
      warn.mockClear();
      const out = await embedCardImages('image_gallery', gallery(url), { home, resize });
      expect(urls(out)).toEqual([url]);
      expect(warn).toHaveBeenCalledTimes(1);
    }
    warn.mockClear();
    expect(urls(await embedCardImages('image_gallery', gallery(secret, secret), { home, resize }))).toEqual([secret, secret]);
    expect(warn).toHaveBeenCalledTimes(1); // the same path twice in one card is still one warning
    expect(resize).not.toHaveBeenCalled();
  });

  it('leaves missing files, directories, oversized files and non-local strings alone', async () => {
    const dir = join(home, 'adir');
    mkdirSync(dir);
    const missing = join(home, 'nope.jpg');
    const huge = file(home, 'huge.jpg', 'x');
    truncateSync(huge, 33 * 1024 * 1024); // sparse; over the 32 MB read limit
    const others = ['relative/pic.jpg', '//cdn.example.com/pic.jpg', 'https://example.com/pic.jpg', ''];
    const resize = resizer();
    const out = await embedCardImages('image_gallery', gallery(missing, dir, huge, ...others), { home, resize });
    expect(urls(out)).toEqual([missing, dir, huge, ...others]);
    expect(resize).not.toHaveBeenCalled();
  });
});

describe('http images', () => {
  it('keeps https as is and downloads http', async () => {
    const fetchImpl = vi.fn(async (_url: string, _init?: RequestInit) => imageResponse('PNGDATA', 'image/png; charset=binary'));
    const resize = resizer();
    const out = await embedCardImages('image_gallery', gallery('https://example.com/a.png', 'http://example.com/b.png?x=1', 'HTTP://EXAMPLE.COM/c.png'), {
      home, resize, fetch: asFetch(fetchImpl),
    });
    expect(urls(out)).toEqual(['https://example.com/a.png', jpegUrl('jpeg:PNGDATA'), jpegUrl('jpeg:PNGDATA')]);
    expect(fetchImpl.mock.calls.map((c) => c[0])).toEqual(['http://example.com/b.png?x=1', 'HTTP://EXAMPLE.COM/c.png']);
    expect(resize.mock.calls[0][0].toString()).toBe('PNGDATA');
  });

  it.each<[string, () => Promise<Response>]>([
    ['an error status', async () => new Response('nope', { status: 404, headers: { 'content-type': 'image/png' } })],
    ['a response that is not an image', async () => imageResponse('<html></html>', 'text/html')],
    ['no content-type at all', async () => new Response(new Uint8Array([1, 2, 3]))],
    ['a declared size over 8 MB', async () => imageResponse('x', 'image/png', { 'content-length': String(9 * 1024 * 1024) })],
    ['a body over 8 MB', async () => imageResponse(Buffer.alloc(8 * 1024 * 1024 + 1), 'image/jpeg')],
    ['a network error', async () => { throw new TypeError('fetch failed'); }],
  ])('keeps the original URL after %s', async (_name, respond) => {
    const resize = resizer();
    const out = await embedCardImages('image_gallery', gallery('http://example.com/b.png'), { home, resize, fetch: asFetch(respond) });
    expect(urls(out)).toEqual(['http://example.com/b.png']);
    expect(resize).not.toHaveBeenCalled();
    expect(warn).toHaveBeenCalledTimes(1);
  });

  it('accepts a body of exactly 8 MB', async () => {
    const out = await embedCardImages('image_gallery', gallery('http://example.com/b.png'), {
      home, resize: resizer(), fetch: asFetch(async () => imageResponse(Buffer.alloc(8 * 1024 * 1024, 65), 'image/jpeg')),
    });
    expect(urls(out)).toEqual([jpegUrl('jpeg:AAAAAAAA')]);
  });

  it('abandons a download that hangs after 8 seconds', async () => {
    vi.useFakeTimers();
    let signal: AbortSignal | undefined;
    const hang = vi.fn((_url: string, init?: RequestInit) => {
      signal = init?.signal ?? undefined;
      return new Promise<Response>(() => {});
    });
    const pending = embedCardImages('image_gallery', gallery('http://example.com/slow.png'), { home, resize: resizer(), fetch: asFetch(hang) });
    await vi.advanceTimersByTimeAsync(7_999);
    expect(signal?.aborted).toBe(false);
    await vi.advanceTimersByTimeAsync(1);
    expect(urls(await pending)).toEqual(['http://example.com/slow.png']);
    expect(signal?.aborted).toBe(true);
  });
});

describe('data URLs', () => {
  it('shrinks one with more than 600 KB of base64 and keeps the rest', async () => {
    const dataUrl = (bytes: number) => `data:image/png;base64,${Buffer.alloc(bytes, 1).toString('base64')}`;
    const big = dataUrl(500_000); // 666,668 chars
    const atLimit = dataUrl(460_800); // exactly 614,400 chars = 600 KB: kept
    const justOver = dataUrl(460_803); // 614,404 chars: shrunk
    const small = dataUrl(30_000);
    const svg = 'data:image/svg+xml,%3Csvg%3E%3C/svg%3E';
    const notImage = `data:text/plain;base64,${Buffer.alloc(900_000).toString('base64')}`;
    const resize = resizer();
    const out = await embedCardImages('image_gallery', gallery(big, small, atLimit, svg, notImage, justOver), { home, resize });
    const shrunk = jpegUrl(`jpeg:${'\x01'.repeat(8)}`);
    expect(urls(out)).toEqual([shrunk, small, atLimit, svg, notImage, shrunk]);
    expect(resize.mock.calls.map((c) => c[0].length)).toEqual([500_000, 460_803]);
  });

  it('keeps an oversize data URL that cannot be shrunk', async () => {
    const big = `data:image/png;base64,${Buffer.alloc(500_000, 1).toString('base64')}`;
    const out = await embedCardImages('image_gallery', gallery(big), { home, resize: async () => { throw new Error('not an image'); } });
    expect(urls(out)).toEqual([big]);
  });
});

describe('per-card limits', () => {
  it('embeds at most 6 images', async () => {
    const paths = Array.from({ length: 8 }, (_, i) => file(home, `p/${i}.jpg`, `IMG${i}`));
    const resize = resizer();
    const out = await embedCardImages('image_gallery', gallery(...paths), { home, resize });
    expect(urls(out)).toEqual([...paths.slice(0, 6).map((_, i) => jpegUrl(`jpeg:IMG${i}`)), paths[6], paths[7]]);
    expect(resize).toHaveBeenCalledTimes(6);
  });

  it('keeps the inline base64 of a card within 900 KB', async () => {
    const paths = [0, 1, 2, 3].map((i) => file(home, `${i}.jpg`, 'x'));
    const resize = vi.fn(async () => Buffer.alloc(300_000, 7)); // 400,000 chars of base64 each
    const out = await embedCardImages('image_gallery', gallery(...paths), { home, resize });
    expect(urls(out).slice(2)).toEqual(paths.slice(2)); // a third one would be 1.2 MB
    expect(urls(out).slice(0, 2).every((u) => u.startsWith('data:image/jpeg;base64,'))).toBe(true);
    expect(urls(out).filter((u) => u.startsWith('data:')).reduce((n, u) => n + payloadLen(u), 0)).toBeLessThanOrEqual(900 * 1024);
  });

  it('counts data URLs that are already in the card, and lets a shrunk one free its own space', async () => {
    const existing = `data:image/png;base64,${'A'.repeat(600_000)}`; // under the 600 KB limit, so it stays, but it takes up room
    const bigFile = file(home, 'big.jpg', 'BIG');
    const tinyFile = file(home, 'tiny.jpg', 'TINY');
    const resize = vi.fn(async (input: Buffer) => (input.toString() === 'BIG' ? Buffer.alloc(300_000, 7) : Buffer.from('tiny')));
    const out = await embedCardImages('image_gallery', gallery(existing, bigFile, tinyFile), { home, resize });
    expect(urls(out)).toEqual([existing, bigFile, jpegUrl('tiny')]); // 600,000 + 400,000 chars would not fit; the small one does

    const oversize = `data:image/png;base64,${Buffer.alloc(2_000_000, 1).toString('base64')}`;
    const out2 = await embedCardImages('image_gallery', gallery(oversize, bigFile), { home, resize: vi.fn(async () => Buffer.alloc(300_000, 7)) });
    expect(urls(out2).every((u) => u.startsWith('data:image/jpeg;base64,') && payloadLen(u) === 400_000)).toBe(true);
  });
});

describe('failures', () => {
  it('keeps the original value when the resizer fails, and goes on with the others', async () => {
    const a = file(home, 'a.jpg', 'AAAA');
    const b = file(home, 'b.jpg', 'BBBB');
    const flaky = vi.fn(async (input: Buffer) => {
      if (input.toString() === 'AAAA') throw new Error('sips exploded');
      return Buffer.from('ok');
    });
    const out = await embedCardImages('image_gallery', gallery(a, b), { home, resize: flaky });
    expect(urls(out)).toEqual([a, jpegUrl('ok')]);
    expect(warn).toHaveBeenCalledTimes(1);
  });

  it('never throws', async () => {
    const a = file(home, 'a.jpg', 'AAAA');
    const props = gallery(a, 'http://example.com/x.png');
    for (const resize of [async () => { throw new Error('boom'); }, async () => Buffer.alloc(0), async () => undefined as unknown as Buffer]) {
      const out = await embedCardImages('image_gallery', props, { home, resize, fetch: asFetch(async () => imageResponse('PNG')) });
      expect(out).toEqual(props);
    }
    for (const odd of [null, undefined, 'text', 7]) expect(await embedCardImages('image_gallery', odd as any, { home })).toBe(odd);
    expect(await embedCardImages('image_gallery', { images: 'nope' }, { home })).toEqual({ images: 'nope' });
    expect(await embedCardImages('image_gallery', { images: [null, 3, { url: 5 }, {}] }, { home })).toEqual({ images: [null, 3, { url: 5 }, {}] });
    expect(await embedCardImages('no_such_component', { imageUrl: a }, { home })).toEqual({ imageUrl: a });
  });
});

describe('which fields', () => {
  const path = () => file(home, 'f.jpg', 'FFFF');
  const want = jpegUrl('jpeg:FFFF');

  it('handles link_preview, comparison, order_card and video, and nothing else', async () => {
    const p = path();
    const resize = resizer();
    const run = (component: string, props: Record<string, unknown>) => embedCardImages(component, props, { home, resize });

    expect(await run('link_preview', { url: p, title: 't', imageUrl: p })).toEqual({ url: p, title: 't', imageUrl: want });
    expect(await run('comparison', { items: [{ id: 'a', title: 'A', imageUrl: p }, { id: 'b', title: 'B' }], recommendedId: 'a' }))
      .toEqual({ items: [{ id: 'a', title: 'A', imageUrl: want }, { id: 'b', title: 'B' }], recommendedId: 'a' });
    expect(await run('order_card', { merchant: 'm', items: [], total: 1, status: 'draft', imageUrl: p }))
      .toEqual({ merchant: 'm', items: [], total: 1, status: 'draft', imageUrl: want });
    expect(await run('video', { url: p, posterUrl: p })).toEqual({ url: p, posterUrl: want });

    const untouched: [string, Record<string, unknown>][] = [
      ['text_card', { markdown: `![x](${p})`, icon: p }],
      ['document', { title: 't', markdown: 'm', attachments: [{ name: 'a', url: p }] }],
      ['map_place', { name: 'n', lat: 1, lon: 2, url: p }],
      ['image_gallery', { images: [{ url: 'https://example.com/a.jpg', caption: p }] }],
    ];
    for (const [component, props] of untouched) expect(await run(component, props)).toEqual(props);
    expect(resize).toHaveBeenCalledTimes(4);
  });
});

// The default resizer, with a stub `sips` first on PATH (shell builtins only).
const FAKE_SIPS = `#!/bin/sh
printf '%s|' "$@" >> "$SIPS_LOG"; echo >> "$SIPS_LOG"
if [ -n "$FAKE_FAIL" ]; then echo "Error 13: not a valid image" >&2; exit 13; fi
if [ "$1" = "-g" ]; then
  printf '%s\\n  pixelWidth: %s\\n  pixelHeight: %s\\n' "$5" "$FAKE_W" "$FAKE_H"
  exit 0
fi
prev=; src=
for a in "$@"; do
  [ "$a" = "--out" ] && src=$prev
  prev=$a
done
IFS= read -r line < "$src"
printf 'jpeg-of-%s' "$line" > "$prev"
`;

describe('default resizer (stub sips)', () => {
  const savedEnv = new Map<string, string | undefined>();
  const setEnv = (key: string, value: string | undefined) => {
    if (!savedEnv.has(key)) savedEnv.set(key, process.env[key]);
    if (value === undefined) delete process.env[key]; else process.env[key] = value;
  };
  let sipsLog: string;
  /** What the stub was called with: one array of arguments per call. */
  const calls = () => readFileSync(sipsLog, 'utf8').trim().split('\n').map((l) => l.split('|').slice(0, -1));

  beforeEach(() => {
    const bin = join(outside, 'bin');
    mkdirSync(bin);
    writeFileSync(join(bin, 'sips'), FAKE_SIPS, { mode: 0o755 });
    sipsLog = join(outside, 'sips.log');
    setEnv('PATH', `${bin}:${process.env.PATH}`);
    setEnv('SIPS_LOG', sipsLog);
    setEnv('FAKE_W', '2000');
    setEnv('FAKE_H', '1000');
    setEnv('FAKE_FAIL', undefined);
  });
  afterEach(() => {
    for (const [key, value] of savedEnv) { if (value === undefined) delete process.env[key]; else process.env[key] = value; }
    savedEnv.clear();
  });

  it('shrinks big pictures to 960 px at JPEG quality 70 and removes its temp files', async () => {
    const path = file(home, 'a.png', 'AAAA');
    const out = await embedCardImages('image_gallery', gallery(path), { home });
    expect(urls(out)).toEqual([jpegUrl('jpeg-of-AAAA')]);
    const [probe, convert] = calls();
    expect(probe.slice(0, 4)).toEqual(['-g', 'pixelWidth', '-g', 'pixelHeight']);
    expect(convert.slice(0, 8)).toEqual(['-Z', '960', '-s', 'format', 'jpeg', '-s', 'formatOptions', '70']);
    expect(convert[9]).toBe('--out');
    expect(existsSync(dirname(convert[8]))).toBe(false); // the whole temp dir is gone
  });

  it('does not enlarge pictures that are already small', async () => {
    setEnv('FAKE_W', '200');
    setEnv('FAKE_H', '960');
    const out = await embedCardImages('image_gallery', gallery(file(home, 'a.png', 'AAAA')), { home });
    expect(urls(out)).toEqual([jpegUrl('jpeg-of-AAAA')]);
    expect(calls()[1].slice(0, 6)).toEqual(['-s', 'format', 'jpeg', '-s', 'formatOptions', '70']);
  });

  it('keeps the original when sips fails, and still cleans up', async () => {
    setEnv('FAKE_FAIL', '1');
    const path = file(home, 'a.png', 'AAAA');
    const out = await embedCardImages('image_gallery', gallery(path), { home });
    expect(urls(out)).toEqual([path]);
    expect(warn).toHaveBeenCalledTimes(1);
    expect(existsSync(dirname(calls()[0][4]))).toBe(false);
  });

  it('is what ui_render / ui_patch use; the bot only gets the card id back', async () => {
    mkdirSync(OPA_HOME, { recursive: true });
    const dir = mkdtempSync(join(OPA_HOME, 'media-test-'));
    const cards = new Map<string, any>();
    const state = {
      findCard: () => undefined,
      card: (id: string) => cards.get(id),
      renderCard: vi.fn((c: any) => { const card = { ...c, id: 'c_1', ts: 1 }; cards.set(card.id, card); return card; }),
      patchCard: vi.fn(),
    };
    const rt: any = { state, currentMsgId: () => 'm_1' };
    try {
      const shot = file(dir, 'phone/evidence/1.jpg', 'AAAA');
      const rendered = await TOOL_MAP.get('ui_render')!.run({ component: 'image_gallery', props: { images: [{ url: shot }, { url: 'https://example.com/x.jpg' }] } }, rt);
      expect(rendered).toEqual({ card_id: 'c_1' });
      expect(urls(state.renderCard.mock.calls[0][0].props)).toEqual([jpegUrl('jpeg-of-AAAA'), 'https://example.com/x.jpg']);

      const shot2 = file(dir, 'phone/evidence/2.jpg', 'BBBB');
      const patched = await TOOL_MAP.get('ui_patch')!.run({ card_id: 'c_1', props: { images: [{ url: shot2 }] } }, rt);
      expect(patched).toBe('ok');
      expect(state.patchCard).toHaveBeenCalledWith('c_1', { images: [{ url: jpegUrl('jpeg-of-BBBB') }] });
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
