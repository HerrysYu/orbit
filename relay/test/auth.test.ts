import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";
import {
  deviceSigMessage,
  hostSigMessage,
  idFromPub,
  parseAllowedHostIds,
  tsFresh,
  verifyDeviceAuth,
  verifyEd25519,
  verifyHostAuth,
} from "../src/auth";
import { base64ToBytes, base64UrlToBytes, bytesToBase64, bytesToBase64Url, utf8 } from "../src/encoding";
import { b64u, newIdentity } from "./helpers";

const NOW = 1_760_000_000_000;

describe("idFromPub", () => {
  it("is the first 32 lowercase hex chars of sha256(pub)", async () => {
    const pub = new Uint8Array(32).map((_, i) => i);
    const expected = createHash("sha256").update(pub).digest("hex").slice(0, 32);
    expect(await idFromPub(pub)).toBe(expected);
    expect(expected).toMatch(/^[0-9a-f]{32}$/);
  });
});

describe("base64 helpers", () => {
  it("round-trips base64url without padding", () => {
    for (let n = 0; n < 40; n++) {
      const b = new Uint8Array(n).map((_, i) => (i * 37 + 250) & 0xff);
      const s = bytesToBase64Url(b);
      expect(s).not.toMatch(/[=+/]/);
      expect(base64UrlToBytes(s)).toEqual(b);
    }
  });
  it("decodes standard base64 with padding", () => {
    const b = new Uint8Array([0xfb, 0xff, 0xfe]);
    expect(base64ToBytes(bytesToBase64(b))).toEqual(b);
    expect(base64ToBytes("+/8=")).toEqual(new Uint8Array([0xfb, 0xff]));
  });
  it("rejects malformed input", () => {
    expect(base64UrlToBytes("a+b")).toBeNull();
    expect(base64ToBytes("a-b_")).toBeNull();
    expect(base64ToBytes("abcde")).toBeNull();
  });
});

describe("verifyEd25519", () => {
  it("accepts a valid signature and rejects tampering", async () => {
    const id = await newIdentity();
    const sig = await id.sign("hello");
    expect(await verifyEd25519(id.pub, utf8("hello"), sig)).toBe(true);
    expect(await verifyEd25519(id.pub, utf8("hellO"), sig)).toBe(false);
    const bad = sig.slice();
    bad[0] ^= 1;
    expect(await verifyEd25519(id.pub, utf8("hello"), bad)).toBe(false);
    expect(await verifyEd25519(id.pub.slice(0, 31), utf8("hello"), sig)).toBe(false);
  });
});

describe("tsFresh", () => {
  it("accepts within 5 minutes, rejects outside or malformed", () => {
    expect(tsFresh(String(NOW), NOW)).toBe(true);
    expect(tsFresh(String(NOW - 299_999), NOW)).toBe(true);
    expect(tsFresh(String(NOW + 299_999), NOW)).toBe(true);
    expect(tsFresh(String(NOW - 300_000), NOW)).toBe(false);
    expect(tsFresh(String(NOW + 300_001), NOW)).toBe(false);
    expect(tsFresh("1.5e12", NOW)).toBe(false);
    expect(tsFresh("-1", NOW)).toBe(false);
  });
});

describe("parseAllowedHostIds", () => {
  it("returns null when unset and a trimmed set otherwise", () => {
    expect(parseAllowedHostIds(undefined)).toBeNull();
    expect(parseAllowedHostIds("  ")).toBeNull();
    expect([...parseAllowedHostIds(" AA , bb,,")!]).toEqual(["aa", "bb"]);
  });
});

async function hostParams(ts = String(NOW)) {
  const id = await newIdentity();
  const hostId = await idFromPub(id.pub);
  const sig = await id.sign(hostSigMessage(hostId, ts));
  return { id, hostId, params: new URLSearchParams({ pub: b64u(id.pub), ts, sig: b64u(sig) }) };
}

describe("verifyHostAuth", () => {
  it("accepts a correctly signed host", async () => {
    const { hostId, params, id } = await hostParams();
    const r = await verifyHostAuth(hostId, params, NOW, null);
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.value.pub).toEqual(id.pub);
  });
  it("uses the exact signed string from the spec", () => {
    expect(hostSigMessage("h", "1")).toBe("opa-relay-host-v1|h|1");
    expect(deviceSigMessage("h", "d", "1")).toBe("opa-relay-device-v1|h|d|1");
  });
  it("rejects when hostId != id(pub)", async () => {
    const a = await hostParams();
    const b = await hostParams();
    const r = await verifyHostAuth(b.hostId, a.params, NOW, null);
    expect(r).toMatchObject({ ok: false, status: 401, reason: "id mismatch" });
  });
  it("rejects stale ts", async () => {
    const { hostId, params } = await hostParams(String(NOW - 6 * 60_000));
    expect(await verifyHostAuth(hostId, params, NOW, null)).toMatchObject({ ok: false, reason: "stale ts" });
  });
  it("rejects bad signature (signed different ts)", async () => {
    const { hostId, params } = await hostParams();
    params.set("ts", String(NOW + 1));
    expect(await verifyHostAuth(hostId, params, NOW, null)).toMatchObject({ ok: false, reason: "bad signature" });
  });
  it("enforces ALLOWED_HOST_IDS", async () => {
    const { hostId, params } = await hostParams();
    expect(await verifyHostAuth(hostId, params, NOW, new Set(["0".repeat(32)]))).toMatchObject({
      ok: false,
      status: 403,
    });
    expect((await verifyHostAuth(hostId, params, NOW, new Set([hostId]))).ok).toBe(true);
  });
  it("rejects missing params and malformed hostId", async () => {
    const { hostId } = await hostParams();
    expect(await verifyHostAuth(hostId, new URLSearchParams(), NOW, null)).toMatchObject({ status: 400 });
    expect(await verifyHostAuth("XYZ", new URLSearchParams(), NOW, null)).toMatchObject({ status: 400 });
  });
});

describe("verifyDeviceAuth", () => {
  async function deviceParams(hostId: string, pair = false) {
    const id = await newIdentity();
    const deviceId = await idFromPub(id.pub);
    const ts = String(NOW);
    const sig = await id.sign(deviceSigMessage(hostId, deviceId, ts));
    const p = new URLSearchParams({ deviceId, pub: b64u(id.pub), ts, sig: b64u(sig) });
    if (pair) p.set("pair", "1");
    return { id, deviceId, params: p };
  }
  const hostId = "a".repeat(32);

  it("accepts a correctly signed device and reports pair flag", async () => {
    const d = await deviceParams(hostId, true);
    const r = await verifyDeviceAuth(hostId, d.params, NOW);
    expect(r).toMatchObject({ ok: true, value: { deviceId: d.deviceId, pair: true } });
  });
  it("binds the signature to the hostId", async () => {
    const d = await deviceParams(hostId);
    expect(await verifyDeviceAuth("b".repeat(32), d.params, NOW)).toMatchObject({ ok: false, reason: "bad signature" });
  });
  it("rejects deviceId != id(pub)", async () => {
    const d = await deviceParams(hostId);
    const other = await deviceParams(hostId);
    d.params.set("deviceId", other.deviceId);
    expect(await verifyDeviceAuth(hostId, d.params, NOW)).toMatchObject({ ok: false, reason: "id mismatch" });
  });
  it("pair flag only when pair=1", async () => {
    const d = await deviceParams(hostId);
    d.params.set("pair", "true");
    expect(await verifyDeviceAuth(hostId, d.params, NOW)).toMatchObject({ ok: true, value: { pair: false } });
  });
});
