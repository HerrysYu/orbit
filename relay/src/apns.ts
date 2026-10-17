// APNs provider-token (JWT ES256) signing and push delivery.
import { base64ToBytes, bytesToBase64Url, utf8 } from "./encoding";
import type { PushRequest } from "./protocol";

export interface ApnsCredentials {
  keyP8: string;
  keyId: string;
  teamId: string;
}

export const APNS_HOSTS = {
  sandbox: "https://api.sandbox.push.apple.com",
  production: "https://api.push.apple.com",
} as const;

/** Apple accepts tokens up to 60 min old and rejects refreshing more than once per 20 min; 50 min is the sweet spot. */
export const TOKEN_TTL_MS = 50 * 60 * 1000;

/** Parse a PKCS#8 PEM (the .p8 file contents) into DER bytes. Tolerates escaped "\n" from secret stores. */
export function pemToDer(pem: string): Uint8Array {
  const body = pem
    .replace(/\\n/g, "\n")
    .replace(/-----BEGIN [^-]+-----/g, "")
    .replace(/-----END [^-]+-----/g, "")
    .replace(/\s+/g, "");
  const der = base64ToBytes(body);
  if (!der || der.length === 0) throw new Error("APNS_KEY_P8 is not valid PEM");
  return der;
}

export async function importApnsKey(pem: string): Promise<CryptoKey> {
  return crypto.subtle.importKey("pkcs8", pemToDer(pem), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
}

/** Build an ES256 JWT. WebCrypto ECDSA output is already raw r||s (64 bytes), as JWS requires. */
export async function signApnsJwt(key: CryptoKey, keyId: string, teamId: string, nowMs: number): Promise<string> {
  const header = bytesToBase64Url(utf8(JSON.stringify({ alg: "ES256", kid: keyId })));
  const claims = bytesToBase64Url(utf8(JSON.stringify({ iss: teamId, iat: Math.floor(nowMs / 1000) })));
  const signingInput = `${header}.${claims}`;
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, utf8(signingInput)));
  return `${signingInput}.${bytesToBase64Url(sig)}`;
}

interface CachedToken {
  cacheKey: string;
  jwt: string;
  issuedAt: number;
}

/** Per-isolate cache; survives across DO instances in the same isolate. */
let cached: CachedToken | null = null;

export async function getProviderToken(creds: ApnsCredentials, nowMs: number): Promise<string> {
  const cacheKey = `${creds.teamId}:${creds.keyId}`;
  if (cached && cached.cacheKey === cacheKey && nowMs - cached.issuedAt < TOKEN_TTL_MS) return cached.jwt;
  const key = await importApnsKey(creds.keyP8);
  const jwt = await signApnsJwt(key, creds.keyId, creds.teamId, nowMs);
  cached = { cacheKey, jwt, issuedAt: nowMs };
  return jwt;
}

export function invalidateProviderToken(): void {
  cached = null;
}

export interface ApnsHttpRequest {
  url: string;
  headers: Record<string, string>;
  body: string;
}

/** Pure: map a relay push frame onto the APNs HTTP/2 request. */
export function buildApnsRequest(push: PushRequest, jwt: string): ApnsHttpRequest {
  const headers: Record<string, string> = {
    authorization: `bearer ${jwt}`,
    "apns-topic": push.topic,
    "apns-push-type": push.pushType,
    "content-type": "application/json",
  };
  if (push.priority !== undefined) headers["apns-priority"] = String(push.priority);
  if (push.collapseId !== undefined) headers["apns-collapse-id"] = push.collapseId;
  if (push.expiration !== undefined) headers["apns-expiration"] = String(push.expiration);
  return {
    url: `${APNS_HOSTS[push.env]}/3/device/${push.deviceToken}`,
    headers,
    body: JSON.stringify(push.payload),
  };
}

export interface PushOutcome {
  status: number;
  reason?: string;
}

export async function sendPush(
  push: PushRequest,
  creds: ApnsCredentials,
  nowMs: number,
  fetchImpl: typeof fetch = fetch,
): Promise<PushOutcome> {
  const jwt = await getProviderToken(creds, nowMs);
  const req = buildApnsRequest(push, jwt);
  const res = await fetchImpl(req.url, { method: "POST", headers: req.headers, body: req.body });
  if (res.status === 200) {
    await res.body?.cancel();
    return { status: 200 };
  }
  let reason: string | undefined;
  try {
    const j = (await res.json()) as { reason?: unknown };
    if (typeof j.reason === "string") reason = j.reason;
  } catch {
    // non-JSON body
  }
  if (res.status === 403 && (reason === "ExpiredProviderToken" || reason === "InvalidProviderToken")) {
    invalidateProviderToken();
  }
  return { status: res.status, reason };
}
