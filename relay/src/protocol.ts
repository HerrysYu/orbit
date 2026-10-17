// Relay frame parsing, allowlist logic and rate limiting (protocol.md §3.2).
// Everything here is pure so it can be unit tested without the Workers runtime.
import { idFromPub } from "./auth";
import { base64ToBytes, bytesToBase64 } from "./encoding";

export const MAX_DEVICE_FRAME_BYTES = 1024 * 1024; // 1 MiB
export const DEVICE_FRAMES_PER_SEC = 120;

/** Close codes used by the relay. 4000 is fixed by the spec; the rest are relay-local. */
export const CLOSE_REPLACED = 4000;
export const CLOSE_NOT_ALLOWED = 4001;
export const CLOSE_RATE_LIMIT = 4008;

export interface AllowedDevice {
  id: string;
  /** Standard base64 (normalized, with padding) of the raw 32-byte Ed25519 key. */
  pub: string;
}

export interface RelayState {
  allow: AllowedDevice[];
  pairingUntil: number;
}

export type PushEnv = "sandbox" | "production";
export type PushType = "alert" | "liveactivity" | "background";

export interface PushRequest {
  id: string;
  deviceToken: string;
  env: PushEnv;
  pushType: PushType;
  topic: string;
  priority?: number;
  collapseId?: string;
  expiration?: number;
  payload: unknown;
}

export type HostFrame =
  | { kind: "forward"; to: string; data: string }
  | { kind: "allow"; devices: unknown[] }
  | { kind: "pairing"; until: number }
  | { kind: "push"; push: PushRequest }
  | { kind: "push_invalid"; id: string | null; reason: string }
  | { kind: "invalid"; reason: string };

function isObj(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

export function parseHostFrame(text: string): HostFrame {
  let v: unknown;
  try {
    v = JSON.parse(text);
  } catch {
    return { kind: "invalid", reason: "not json" };
  }
  if (!isObj(v)) return { kind: "invalid", reason: "not an object" };

  if (typeof v.relay === "string") {
    switch (v.relay) {
      case "allow":
        if (!Array.isArray(v.devices)) return { kind: "invalid", reason: "allow.devices must be an array" };
        return { kind: "allow", devices: v.devices };
      case "pairing":
        if (typeof v.until !== "number" || !Number.isFinite(v.until))
          return { kind: "invalid", reason: "pairing.until must be a number" };
        return { kind: "pairing", until: v.until };
      case "push":
        return parsePush(v);
      default:
        return { kind: "invalid", reason: `unknown relay control: ${v.relay}` };
    }
  }

  if (typeof v.to === "string" && typeof v.data === "string") return { kind: "forward", to: v.to, data: v.data };
  return { kind: "invalid", reason: "expected {to,data} or {relay}" };
}

function parsePush(v: Record<string, unknown>): HostFrame {
  const id = typeof v.id === "string" ? v.id : null;
  const bad = (reason: string): HostFrame => ({ kind: "push_invalid", id, reason });
  if (id === null) return bad("missing id");
  if (typeof v.deviceToken !== "string" || !/^[0-9a-fA-F]{16,400}$/.test(v.deviceToken))
    return bad("bad deviceToken");
  if (v.env !== "sandbox" && v.env !== "production") return bad("bad env");
  if (v.pushType !== "alert" && v.pushType !== "liveactivity" && v.pushType !== "background")
    return bad("bad pushType");
  if (typeof v.topic !== "string" || !/^[A-Za-z0-9.\-_]{1,255}$/.test(v.topic)) return bad("bad topic");
  if (v.priority !== undefined && v.priority !== null && !(v.priority === 5 || v.priority === 10 || v.priority === 1))
    return bad("bad priority");
  if (v.collapseId !== undefined && v.collapseId !== null && (typeof v.collapseId !== "string" || v.collapseId.length > 64))
    return bad("bad collapseId");
  if (
    v.expiration !== undefined &&
    v.expiration !== null &&
    (typeof v.expiration !== "number" || !Number.isInteger(v.expiration) || v.expiration < 0)
  )
    return bad("bad expiration");
  if (!isObj(v.payload)) return bad("payload must be an object");
  return {
    kind: "push",
    push: {
      id,
      deviceToken: v.deviceToken.toLowerCase(),
      env: v.env,
      pushType: v.pushType,
      topic: v.topic,
      priority: typeof v.priority === "number" ? v.priority : undefined,
      collapseId: typeof v.collapseId === "string" && v.collapseId !== "" ? v.collapseId : undefined,
      expiration: typeof v.expiration === "number" ? v.expiration : undefined,
      payload: v.payload,
    },
  };
}

/**
 * Validate the `devices` array of an allow frame. Entries with malformed pubs
 * or whose id != id(pub) are dropped. Pubs are normalized to padded standard base64.
 */
export async function normalizeAllowList(devices: unknown[]): Promise<AllowedDevice[]> {
  const out = new Map<string, AllowedDevice>();
  for (const d of devices) {
    if (!isObj(d) || typeof d.id !== "string" || typeof d.pub !== "string") continue;
    const raw = base64ToBytes(d.pub);
    if (!raw || raw.length !== 32) continue;
    if ((await idFromPub(raw)) !== d.id) continue;
    out.set(d.id, { id: d.id, pub: bytesToBase64(raw) });
  }
  return [...out.values()];
}

export interface DeviceIdentity {
  deviceId: string;
  /** Standard base64 of the raw pub. */
  pub: string;
  pair: boolean;
}

export function isDeviceAllowed(state: RelayState, dev: DeviceIdentity, now: number): boolean {
  if (state.allow.some((a) => a.id === dev.deviceId && a.pub === dev.pub)) return true;
  return dev.pair && now < state.pairingUntil;
}

// ---- Frame builders ----

export function wrapDeviceFrame(deviceId: string, data: string): string {
  return JSON.stringify({ from: deviceId, data });
}

export const HOST_ONLINE = JSON.stringify({ relay: "host_online" });
export const HOST_OFFLINE = JSON.stringify({ relay: "host_offline" });

export function deviceConnectedFrame(deviceId: string): string {
  return JSON.stringify({ relay: "device_connected", deviceId });
}

export function deviceDisconnectedFrame(deviceId: string): string {
  return JSON.stringify({ relay: "device_disconnected", deviceId });
}

export function pushResultFrame(id: string | null, status: number, reason?: string): string {
  const f: Record<string, unknown> = { relay: "push_result", id, status };
  if (reason !== undefined && reason !== "") f.reason = reason;
  return JSON.stringify(f);
}

// ---- Rate limiting ----

export interface TokenBucket {
  tokens: number;
  last: number;
}

export function newBucket(now: number, capacity = DEVICE_FRAMES_PER_SEC): TokenBucket {
  return { tokens: capacity, last: now };
}

/** Consume one token. Returns false if the bucket is empty (rate exceeded). Mutates `b`. */
export function takeToken(b: TokenBucket, now: number, rate = DEVICE_FRAMES_PER_SEC, capacity = rate): boolean {
  const elapsed = Math.max(0, now - b.last);
  b.tokens = Math.min(capacity, b.tokens + (elapsed * rate) / 1000);
  b.last = now;
  if (b.tokens < 1) return false;
  b.tokens -= 1;
  return true;
}
