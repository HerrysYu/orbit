// Identity + signature verification (protocol.md §1, §3.2). Pure WebCrypto.
import { base64UrlToBytes, bytesToHex, utf8 } from "./encoding";

export const MAX_CLOCK_SKEW_MS = 5 * 60 * 1000;
export const ID_RE = /^[0-9a-f]{32}$/;

/** id(pub) = hex(sha256(pub))[0..32] */
export async function idFromPub(pub: Uint8Array): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", pub));
  return bytesToHex(digest).slice(0, 32);
}

export async function verifyEd25519(pub: Uint8Array, message: Uint8Array, sig: Uint8Array): Promise<boolean> {
  if (pub.length !== 32 || sig.length !== 64) return false;
  try {
    const key = await crypto.subtle.importKey("raw", pub, { name: "Ed25519" }, false, ["verify"]);
    return await crypto.subtle.verify({ name: "Ed25519" }, key, sig, message);
  } catch {
    return false;
  }
}

export function hostSigMessage(hostId: string, ts: string): string {
  return `opa-relay-host-v1|${hostId}|${ts}`;
}

export function deviceSigMessage(hostId: string, deviceId: string, ts: string): string {
  return `opa-relay-device-v1|${hostId}|${deviceId}|${ts}`;
}

/** ts must be a decimal integer string within ±5 min of now (strict). */
export function tsFresh(ts: string, now: number): boolean {
  if (!/^\d{1,16}$/.test(ts)) return false;
  return Math.abs(now - Number(ts)) < MAX_CLOCK_SKEW_MS;
}

export function parseAllowedHostIds(raw: string | undefined): Set<string> | null {
  if (!raw || raw.trim() === "") return null;
  return new Set(
    raw
      .split(",")
      .map((s) => s.trim().toLowerCase())
      .filter((s) => s.length > 0),
  );
}

export type AuthResult<T> = { ok: true; value: T } | { ok: false; status: number; reason: string };

export interface HostAuth {
  hostId: string;
  pub: Uint8Array;
}

export async function verifyHostAuth(
  hostId: string,
  params: URLSearchParams,
  now: number,
  allowedHostIds: Set<string> | null,
): Promise<AuthResult<HostAuth>> {
  if (!ID_RE.test(hostId)) return { ok: false, status: 400, reason: "bad hostId" };
  if (allowedHostIds && !allowedHostIds.has(hostId)) return { ok: false, status: 403, reason: "host not allowed" };
  const pubS = params.get("pub");
  const ts = params.get("ts");
  const sigS = params.get("sig");
  if (!pubS || !ts || !sigS) return { ok: false, status: 400, reason: "missing params" };
  const pub = base64UrlToBytes(pubS);
  const sig = base64UrlToBytes(sigS);
  if (!pub || pub.length !== 32 || !sig) return { ok: false, status: 400, reason: "bad encoding" };
  if (!tsFresh(ts, now)) return { ok: false, status: 401, reason: "stale ts" };
  if ((await idFromPub(pub)) !== hostId) return { ok: false, status: 401, reason: "id mismatch" };
  if (!(await verifyEd25519(pub, utf8(hostSigMessage(hostId, ts)), sig)))
    return { ok: false, status: 401, reason: "bad signature" };
  return { ok: true, value: { hostId, pub } };
}

export interface DeviceAuth {
  hostId: string;
  deviceId: string;
  pub: Uint8Array;
  pair: boolean;
}

export async function verifyDeviceAuth(
  hostId: string,
  params: URLSearchParams,
  now: number,
): Promise<AuthResult<DeviceAuth>> {
  if (!ID_RE.test(hostId)) return { ok: false, status: 400, reason: "bad hostId" };
  const deviceId = params.get("deviceId");
  const pubS = params.get("pub");
  const ts = params.get("ts");
  const sigS = params.get("sig");
  if (!deviceId || !pubS || !ts || !sigS) return { ok: false, status: 400, reason: "missing params" };
  if (!ID_RE.test(deviceId)) return { ok: false, status: 400, reason: "bad deviceId" };
  const pub = base64UrlToBytes(pubS);
  const sig = base64UrlToBytes(sigS);
  if (!pub || pub.length !== 32 || !sig) return { ok: false, status: 400, reason: "bad encoding" };
  if (!tsFresh(ts, now)) return { ok: false, status: 401, reason: "stale ts" };
  if ((await idFromPub(pub)) !== deviceId) return { ok: false, status: 401, reason: "id mismatch" };
  if (!(await verifyEd25519(pub, utf8(deviceSigMessage(hostId, deviceId, ts)), sig)))
    return { ok: false, status: 401, reason: "bad signature" };
  return { ok: true, value: { hostId, deviceId, pub, pair: params.get("pair") === "1" } };
}

// ---- ADB tunnel phone auth (docs/design/adb-relay-protocol.md §1, §3) ----

export function tunnelPhoneSigMessage(phoneId: string, ts: string): string {
  return `opa-tunnel-phone-v1|${phoneId}|${ts}`;
}

export interface PhoneAuth {
  phoneId: string;
  pub: Uint8Array;
}

/** Same checks and status codes as verifyHostAuth, with the phone's own signed string. */
export async function verifyPhoneAuth(
  phoneId: string,
  params: URLSearchParams,
  now: number,
  allowedPhoneIds: Set<string> | null,
): Promise<AuthResult<PhoneAuth>> {
  if (!ID_RE.test(phoneId)) return { ok: false, status: 400, reason: "bad phoneId" };
  if (allowedPhoneIds && !allowedPhoneIds.has(phoneId)) return { ok: false, status: 403, reason: "phone not allowed" };
  const pubS = params.get("pub");
  const ts = params.get("ts");
  const sigS = params.get("sig");
  if (!pubS || !ts || !sigS) return { ok: false, status: 400, reason: "missing params" };
  const pub = base64UrlToBytes(pubS);
  const sig = base64UrlToBytes(sigS);
  if (!pub || pub.length !== 32 || !sig) return { ok: false, status: 400, reason: "bad encoding" };
  if (!tsFresh(ts, now)) return { ok: false, status: 401, reason: "stale ts" };
  if ((await idFromPub(pub)) !== phoneId) return { ok: false, status: 401, reason: "id mismatch" };
  if (!(await verifyEd25519(pub, utf8(tunnelPhoneSigMessage(phoneId, ts)), sig)))
    return { ok: false, status: 401, reason: "bad signature" };
  return { ok: true, value: { phoneId, pub } };
}
