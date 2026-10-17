// Makes card images displayable on the phone. The bot may put a Mac-local path (a phone-task screenshot, a workspace file) or a plain
// http:// URL into a card's image field; the iPhone cannot reach the former and the App's ATS refuses the latter, so before a card is
// stored and pushed the Host inlines such images as small JPEG data URLs. Best effort: any failure leaves the original value alone and
// nothing here ever throws.
import { execFile } from 'node:child_process';
import { mkdtemp, readFile, realpath, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { OPA_HOME } from '../store/db.ts';
import { log } from '../util/log.ts';

const execFileP = promisify(execFile);

const MAX_EDGE = 960; // px, longest side of an embedded image
const JPEG_QUALITY = 70;
const SIPS_TIMEOUT_MS = 10_000;
const FETCH_TIMEOUT_MS = 8_000;
const MAX_DOWNLOAD_BYTES = 8 * 1024 * 1024;
const MAX_LOCAL_BYTES = 32 * 1024 * 1024;
/** A data: URL with more base64 than this is decoded and shrunk like any other image. */
const MAX_INLINE_BASE64 = 600 * 1024;
/** Per card: at most this many images are fetched and shrunk... */
export const MAX_EMBEDDED_IMAGES = 6;
/** ...and the base64 of all images inlined in the card stays within this (one encrypted relay frame has to carry the whole card). */
export const MAX_TOTAL_BASE64 = 900 * 1024;

type Props = Record<string, unknown>;

export interface EmbedOpts {
  /** Turns encoded image bytes (any format) into a small JPEG. Default: macOS `sips`. Reject to leave the image alone. */
  resize?: (input: Buffer) => Promise<Uint8Array>;
  /** Used to download http:// images. Default: the global fetch. */
  fetch?: typeof fetch;
  /** Local files are only embedded from below this directory. Default: OPA_HOME. */
  home?: string;
}

type Slot = { holder: Props; key: string };
type Kind = 'local' | 'http' | 'shrink' | 'inline' | 'keep';
type Job = { slot: Slot; kind: 'local' | 'http' | 'shrink'; source: string; oldLen: number };

/** The image fields of the GenUI catalog (genui.ts) that hold a URL. */
function imageSlots(component: string, props: Props): Slot[] {
  const slots: Slot[] = [];
  const add = (holder: unknown, key: string) => {
    if (holder && typeof holder === 'object' && typeof (holder as Props)[key] === 'string') slots.push({ holder: holder as Props, key });
  };
  const each = (list: unknown, fn: (item: unknown) => void) => { if (Array.isArray(list)) list.forEach(fn); };
  switch (component) {
    case 'image_gallery': each(props.images, (img) => add(img, 'url')); break;
    case 'comparison': each(props.items, (item) => add(item, 'imageUrl')); break;
    case 'link_preview':
    case 'order_card': add(props, 'imageUrl'); break;
    case 'video': add(props, 'posterUrl'); break;
  }
  return slots;
}

const isDataImage = (v: string) => /^data:image\//i.test(v);
/** Length of the payload after the comma of a data: URL (0 for anything else). */
const inlineLen = (v: string) => (isDataImage(v) ? Math.max(0, v.length - v.indexOf(',') - 1) : 0);

function kindOf(v: string): Kind {
  if (isDataImage(v)) {
    const comma = v.indexOf(',');
    return comma > 0 && /;base64$/i.test(v.slice(0, comma)) && inlineLen(v) > MAX_INLINE_BASE64 ? 'shrink' : 'inline';
  }
  if (/^http:\/\//i.test(v)) return 'http';
  if (/^file:\/\//i.test(v) || (v.startsWith('/') && !v.startsWith('//'))) return 'local';
  return 'keep'; // https://, relative paths, anything else
}

const reason = (e: unknown) => {
  const err = e as { message?: string; stderr?: string } | undefined;
  return (err?.stderr?.trim() || err?.message || String(e)).split('\n')[0].slice(0, 200);
};
const brief = (v: string) => (isDataImage(v) ? `data URL (${Math.round(v.length / 1024)} KB)` : v.replace(/\?.*$/, '').slice(0, 160));

/** Resolves a local image reference to its real path, if (and only if) it lives under `home`. Warns and returns null otherwise. */
async function allowedLocalPath(value: string, home: string, warned: Set<string>): Promise<string | null> {
  try {
    const real = await realpath(value.startsWith('/') ? value : fileURLToPath(value)); // follows symlinks and "..": no escaping via either
    const root = await realpath(home); // /tmp, /var/... are symlinks on macOS, so both sides must be resolved
    if (real.startsWith(root.endsWith(sep) ? root : root + sep)) return real;
    if (!warned.has(value)) {
      warned.add(value);
      log.warn('media', `image path is outside OPA_HOME, left as is: ${brief(value)}`);
    }
  } catch (e) {
    log.warn('media', `local image not readable, left as is: ${brief(value)} (${reason(e)})`);
  }
  return null;
}

async function readLocal(path: string): Promise<Buffer> {
  const st = await stat(path);
  if (!st.isFile()) throw new Error('not a regular file');
  if (st.size > MAX_LOCAL_BYTES) throw new Error(`file too large (${st.size} bytes)`);
  return await readFile(path);
}

async function readCapped(res: Response, max: number): Promise<Buffer> {
  if (!res.body) {
    const all = Buffer.from(await res.arrayBuffer());
    if (all.length > max) throw new Error(`image too large (${all.length} bytes)`);
    return all;
  }
  const reader = res.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > max) throw new Error(`image too large (over ${max} bytes)`);
      chunks.push(value);
    }
  } finally {
    reader.cancel().catch(() => {});
  }
  return Buffer.concat(chunks);
}

async function download(url: string, doFetch: typeof fetch): Promise<Buffer> {
  const ctl = new AbortController();
  let timer: NodeJS.Timeout | undefined;
  // Raced rather than relying on the abort alone, so a fetch that ignores its signal still cannot hold the card up.
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => { ctl.abort(); reject(new Error(`download timed out after ${FETCH_TIMEOUT_MS / 1000}s`)); }, FETCH_TIMEOUT_MS);
  });
  const work = (async () => {
    const res = await doFetch(url, { signal: ctl.signal, headers: { accept: 'image/*' } });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const type = (res.headers.get('content-type') ?? '').split(';')[0].trim().toLowerCase();
    if (!type.startsWith('image/')) throw new Error(`not an image (content-type: ${type || 'none'})`);
    if (Number(res.headers.get('content-length')) > MAX_DOWNLOAD_BYTES) throw new Error('image too large');
    return await readCapped(res, MAX_DOWNLOAD_BYTES);
  })();
  try {
    return await Promise.race([work, timeout]);
  } finally {
    clearTimeout(timer);
  }
}

/** Default resizer: macOS `sips`, on private temp files that are always removed afterwards. */
async function sipsResize(input: Buffer): Promise<Buffer> {
  const dir = await mkdtemp(join(tmpdir(), 'opa-media-'));
  try {
    const src = join(dir, 'src');
    const dst = join(dir, 'out.jpg');
    await writeFile(src, input);
    // `sips -Z` enlarges small pictures as well, so only ask for it when the picture really is bigger than MAX_EDGE.
    const { stdout } = await execFileP('sips', ['-g', 'pixelWidth', '-g', 'pixelHeight', src], { timeout: SIPS_TIMEOUT_MS });
    const w = Number(/pixelWidth:\s*(\d+)/.exec(stdout)?.[1]);
    const h = Number(/pixelHeight:\s*(\d+)/.exec(stdout)?.[1]);
    const scale = Math.max(w, h) <= MAX_EDGE ? [] : ['-Z', String(MAX_EDGE)];
    await execFileP('sips', [...scale, '-s', 'format', 'jpeg', '-s', 'formatOptions', String(JPEG_QUALITY), src, '--out', dst], { timeout: SIPS_TIMEOUT_MS });
    return await readFile(dst);
  } finally {
    await rm(dir, { recursive: true, force: true }).catch(() => {});
  }
}

/** Fetches the job's image and shrinks it. Returns the JPEG as base64, or null (already logged) when anything goes wrong. */
async function shrinkToBase64(job: Job, resize: NonNullable<EmbedOpts['resize']>, doFetch: typeof fetch): Promise<string | null> {
  try {
    const bytes = job.kind === 'local' ? await readLocal(job.source)
      : job.kind === 'http' ? await download(job.source, doFetch)
        : Buffer.from(job.source.slice(job.source.indexOf(',') + 1), 'base64');
    const jpeg = await resize(bytes);
    if (!jpeg?.byteLength) throw new Error('empty result');
    return Buffer.from(jpeg).toString('base64');
  } catch (e) {
    log.warn('media', `image left as is: ${brief(job.source)} (${reason(e)})`);
    return null;
  }
}

/**
 * Returns a copy of `props` whose image fields (image_gallery.images[].url, link_preview.imageUrl, comparison.items[].imageUrl,
 * order_card.imageUrl, video.posterUrl) are `data:image/jpeg;base64,...` where that was needed and possible:
 *  - local paths (/abs/path or file://) under OPA_HOME, and http:// images, are read / downloaded and shrunk;
 *  - data: images with more than 600 KB of base64 are shrunk; https:// and smaller data: images are kept.
 * Whatever cannot be converted keeps its original value. Per card: at most 6 images are processed, and all inline images together stay
 * within 900 KB of base64. The input is never modified.
 */
export async function embedCardImages(component: string, props: Props, opts: EmbedOpts = {}): Promise<Props> {
  if (!props || typeof props !== 'object') return props;
  let out: Props;
  try { out = structuredClone(props); } catch { return props; }
  const slots = imageSlots(component, out);
  if (!slots.length) return out;

  const resize = opts.resize ?? sipsResize;
  const doFetch = opts.fetch ?? globalThis.fetch;
  const home = opts.home ?? OPA_HOME;
  const warned = new Set<string>();

  // `used`: base64 chars of the images that are inline in the card, data: images already there included. Starts with the ones that stay
  // as they are; an image that gets embedded adds its share, one that cannot be shrunk keeps (and so counts) its original.
  let used = 0;
  const jobs: Job[] = [];
  for (const slot of slots) {
    const value = slot.holder[slot.key] as string;
    const kind = kindOf(value);
    if (kind === 'inline') used += inlineLen(value);
    else if (kind === 'http' || kind === 'shrink') jobs.push({ slot, kind, source: value, oldLen: inlineLen(value) });
    else if (kind === 'local') {
      const path = await allowedLocalPath(value, home, warned);
      if (path) jobs.push({ slot, kind, source: path, oldLen: 0 });
    }
  }
  if (jobs.length > MAX_EMBEDDED_IMAGES) log.warn('media', `card has ${jobs.length} images to embed, only the first ${MAX_EMBEDDED_IMAGES} are`);

  for (const job of jobs.slice(0, MAX_EMBEDDED_IMAGES)) {
    const base64 = await shrinkToBase64(job, resize, doFetch);
    if (base64 !== null && used + base64.length <= MAX_TOTAL_BASE64) {
      used += base64.length;
      job.slot.holder[job.slot.key] = `data:image/jpeg;base64,${base64}`;
    } else {
      if (base64 !== null) log.warn('media', `image left as is, the card would exceed ${MAX_TOTAL_BASE64 / 1024} KB of inline images: ${brief(job.source)}`);
      used += job.oldLen;
    }
  }
  return out;
}
