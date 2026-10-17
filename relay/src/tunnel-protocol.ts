// ADB tunnel helpers (docs/design/adb-relay-protocol.md §1, §3-§5).
// Everything here is pure (no Workers-only imports) so it can be unit tested under Node.
import { bytesToHex, utf8, utf8ByteLength } from "./encoding";

// ---- Limits ----

export const MAX_GRANTS = 32;
/** Largest text frame the relay will parse from the phone (a grants table is a few KiB at most). */
export const MAX_TEXT_FRAME_BYTES = 64 * 1024;
/** Largest binary frame, either direction. The relay never looks inside it. */
export const MAX_BINARY_FRAME_BYTES = 64 * 1024;
/** Fixed window for the per-phone byte budget; both directions count against it. */
export const RATE_WINDOW_MS = 60_000;
export const RATE_WINDOW_BYTES = 100 * 1024 * 1024;

// ---- Close codes (§3). 4000 and 4008 are the same numbers protocol.ts uses for the host relay. ----

export const CLOSE_FRAME_TOO_LARGE = 1009;
export const CLOSE_REPLACED = 4000;
export const CLOSE_REVOKED = 4001;
export const CLOSE_PHONE_RECONNECTED = 4003;
export const CLOSE_PHONE_OFFLINE = 4004;
export const CLOSE_RATE_LIMIT = 4008;

// ---- Token ----

export const TOKEN_RE = /^[A-Za-z0-9_-]{32,128}$/;

export function isValidToken(token: string): boolean {
  return TOKEN_RE.test(token);
}

export type BearerResult = { ok: true; token: string } | { ok: false; status: 400; reason: string };

/** `Authorization: Bearer <token>` → the token, or 400 "missing token" / "bad token". The scheme is case-insensitive. */
export function parseBearerToken(header: string | null): BearerResult {
  const m = header === null ? null : /^bearer +(.*)$/i.exec(header);
  if (!m || m[1] === "") return { ok: false, status: 400, reason: "missing token" };
  if (!isValidToken(m[1])) return { ok: false, status: 400, reason: "bad token" };
  return { ok: true, token: m[1] };
}

/** sha256 over the UTF-8 bytes of the token *string* (it is not base64-decoded first), as 64 lowercase hex chars. */
export async function sha256hex(s: string): Promise<string> {
  return bytesToHex(new Uint8Array(await crypto.subtle.digest("SHA-256", utf8(s))));
}

// ---- Grants (§1, §4) ----

export interface Grant {
  id: string;
  name: string;
  /** sha256hex(token). The relay never sees or stores the token itself. */
  hash: string;
  /** Epoch milliseconds; 0 means it never expires. */
  exp: number;
}

const GRANT_ID_RE = /^[A-Za-z0-9_-]{1,64}$/;
const GRANT_HASH_RE = /^[0-9a-f]{64}$/;
const MAX_NAME_CHARS = 64;

export type GrantsResult = { ok: true; grants: Grant[] } | { ok: false; reason: string };

function isObj(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function validName(name: string): boolean {
  // 64 characters means code points; 128 UTF-16 units is the cheap upper bound.
  return name.length >= 1 && name.length <= 2 * MAX_NAME_CHARS && Array.from(name).length <= MAX_NAME_CHARS;
}

/** Validate a whole grants table. All-or-nothing; extra fields on a grant are dropped. */
export function parseGrants(v: unknown): GrantsResult {
  if (!Array.isArray(v)) return { ok: false, reason: "grants must be an array" };
  if (v.length > MAX_GRANTS) return { ok: false, reason: "too many grants" };
  const seen = new Set<string>();
  const grants: Grant[] = [];
  for (const g of v) {
    if (!isObj(g)) return { ok: false, reason: "grant must be an object" };
    const { id, name, hash, exp } = g;
    if (typeof id !== "string" || !GRANT_ID_RE.test(id)) return { ok: false, reason: "bad id" };
    if (seen.has(id)) return { ok: false, reason: "duplicate id" };
    if (typeof name !== "string" || !validName(name)) return { ok: false, reason: "bad name" };
    if (typeof hash !== "string" || !GRANT_HASH_RE.test(hash)) return { ok: false, reason: "bad hash" };
    if (typeof exp !== "number" || !Number.isSafeInteger(exp) || exp < 0) return { ok: false, reason: "bad exp" };
    seen.add(id);
    grants.push({ id, name, hash, exp });
  }
  return { ok: true, grants };
}

export function isExpired(g: Pick<Grant, "exp">, now: number): boolean {
  return g.exp !== 0 && now >= g.exp;
}

// ---- Phone text frames (§4) ----

export type PhoneText =
  /** A valid, replace-everything grants table. */
  | { kind: "grants"; grants: Grant[] }
  /** A grants frame (or an oversized frame) that failed validation: reply `error`, keep the old table. */
  | { kind: "bad_grants" }
  /** Non-JSON, not an object, or an unknown `t`: ignored. */
  | { kind: "ignore" };

export function parsePhoneText(text: string): PhoneText {
  // Any UTF-16 unit takes at least one UTF-8 byte, so `length` alone can already prove it is too big.
  if (text.length > MAX_TEXT_FRAME_BYTES || utf8ByteLength(text) > MAX_TEXT_FRAME_BYTES) return { kind: "bad_grants" };
  let v: unknown;
  try {
    v = JSON.parse(text);
  } catch {
    return { kind: "ignore" };
  }
  if (!isObj(v) || v.t !== "grants") return { kind: "ignore" };
  const r = parseGrants(v.grants);
  return r.ok ? { kind: "grants", grants: r.grants } : { kind: "bad_grants" };
}

// ---- Frame builders (relay → phone) ----

export function clientOpenFrame(grant: string, name: string): string {
  return JSON.stringify({ t: "client", state: "open", grant, name });
}

export function clientClosedFrame(grant: string): string {
  return JSON.stringify({ t: "client", state: "closed", grant });
}

export function grantsOkFrame(count: number): string {
  return JSON.stringify({ t: "grants_ok", count });
}

export const BAD_GRANTS_FRAME = JSON.stringify({ t: "error", reason: "bad_grants" });

// ---- Byte budget ----

export interface ByteWindow {
  start: number;
  bytes: number;
}

export function newByteWindow(now: number): ByteWindow {
  return { start: now, bytes: 0 };
}

/**
 * Count `n` bytes against the current fixed window, starting a new one once `windowMs` has passed.
 * Returns false when the window total exceeds `limit`. Mutates `w`.
 */
export function takeBytes(
  w: ByteWindow,
  now: number,
  n: number,
  windowMs = RATE_WINDOW_MS,
  limit = RATE_WINDOW_BYTES,
): boolean {
  if (now < w.start || now - w.start >= windowMs) {
    w.start = now;
    w.bytes = 0;
  }
  w.bytes += n;
  return w.bytes <= limit;
}
