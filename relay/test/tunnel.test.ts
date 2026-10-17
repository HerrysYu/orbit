import { describe, expect, it } from "vitest";
import { hostSigMessage, idFromPub, tunnelPhoneSigMessage, verifyPhoneAuth } from "../src/auth";
import { matchRoute } from "../src/routes";
import {
  MAX_GRANTS,
  RATE_WINDOW_BYTES,
  isExpired,
  isValidToken,
  newByteWindow,
  parseBearerToken,
  parseGrants,
  parsePhoneText,
  sha256hex,
  takeBytes,
} from "../src/tunnel-protocol";
import { b64u, newIdentity } from "./helpers";

const NOW = 1_760_000_000_000;

async function phoneParams(ts = String(NOW), message = tunnelPhoneSigMessage) {
  const id = await newIdentity();
  const phoneId = await idFromPub(id.pub);
  const sig = await id.sign(message(phoneId, ts));
  return { phoneId, params: new URLSearchParams({ pub: b64u(id.pub), ts, sig: b64u(sig) }) };
}

describe("verifyPhoneAuth", () => {
  it("accepts a correctly signed phone, over the exact string from the spec", async () => {
    expect(tunnelPhoneSigMessage("p", "1")).toBe("opa-tunnel-phone-v1|p|1");
    const { phoneId, params } = await phoneParams();
    expect(await verifyPhoneAuth(phoneId, params, NOW, null)).toMatchObject({ ok: true, value: { phoneId } });
  });

  it("answers 401 for a wrong message prefix, an id mismatch and a stale ts", async () => {
    const a = await phoneParams(String(NOW), hostSigMessage);
    expect(await verifyPhoneAuth(a.phoneId, a.params, NOW, null)).toMatchObject({
      ok: false,
      status: 401,
      reason: "bad signature",
    });
    const b = await phoneParams();
    const other = await phoneParams();
    expect(await verifyPhoneAuth(other.phoneId, b.params, NOW, null)).toMatchObject({
      ok: false,
      status: 401,
      reason: "id mismatch",
    });
    const stale = await phoneParams(String(NOW - 6 * 60_000));
    expect(await verifyPhoneAuth(stale.phoneId, stale.params, NOW, null)).toMatchObject({
      ok: false,
      status: 401,
      reason: "stale ts",
    });
  });

  it("answers 403 outside ALLOWED_PHONE_IDS and 400 for malformed requests", async () => {
    const { phoneId, params } = await phoneParams();
    expect(await verifyPhoneAuth(phoneId, params, NOW, new Set(["0".repeat(32)]))).toMatchObject({
      ok: false,
      status: 403,
    });
    expect((await verifyPhoneAuth(phoneId, params, NOW, new Set([phoneId]))).ok).toBe(true);
    expect(await verifyPhoneAuth(phoneId, new URLSearchParams(), NOW, null)).toMatchObject({ status: 400 });
    expect(await verifyPhoneAuth("XYZ", params, NOW, null)).toMatchObject({ status: 400, reason: "bad phoneId" });
  });
});

describe("grants", () => {
  const hash = "ab".repeat(32);
  const grant = (i: number, over: Record<string, unknown> = {}) => ({ id: `g${i}`, name: `bot ${i}`, hash, exp: 0, ...over });

  it("accepts a valid table, drops extra fields, counts name length in code points", () => {
    const r = parseGrants([grant(1), grant(2, { exp: NOW, extra: true }), grant(3, { name: "😀".repeat(64) })]);
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.grants[1]).toEqual({ id: "g2", name: "bot 2", hash, exp: NOW });
    expect(parseGrants([]).ok).toBe(true);
    expect(parseGrants(Array.from({ length: MAX_GRANTS }, (_, i) => grant(i))).ok).toBe(true);
  });

  it("rejects the whole table on any bad entry", () => {
    const bad = (v: unknown) => expect(parseGrants(v).ok).toBe(false);
    bad(Array.from({ length: MAX_GRANTS + 1 }, (_, i) => grant(i)));
    bad([grant(1, { hash: "AB".repeat(32) })]); // uppercase
    bad([grant(1, { hash: "ab".repeat(31) })]); // short
    bad([grant(1), grant(1, { hash: "cd".repeat(32) })]); // duplicate id
    bad([grant(1, { exp: -1 })]);
    bad([grant(1, { exp: 1.5 })]);
    bad([grant(1, { exp: "0" })]);
    bad([grant(1, { id: "has space" })]);
    bad([grant(1, { id: "x".repeat(65) })]);
    bad([grant(1, { name: "" })]);
    bad([grant(1, { name: "x".repeat(65) })]);
    bad({ grants: [] });
    bad(["g1"]);
  });

  it("parses phone text frames: grants, bad grants, and everything ignorable", () => {
    expect(parsePhoneText(JSON.stringify({ t: "grants", grants: [grant(1)] }))).toEqual({
      kind: "grants",
      grants: [grant(1)],
    });
    expect(parsePhoneText('{"t":"grants","grants":"x"}')).toEqual({ kind: "bad_grants" });
    expect(parsePhoneText('{"t":"grants"}')).toEqual({ kind: "bad_grants" });
    const huge = JSON.stringify({ t: "grants", grants: [], pad: "x".repeat(70_000) });
    expect(parsePhoneText(huge)).toEqual({ kind: "bad_grants" });
    for (const t of ["not json", "[1]", "null", '{"t":"hello"}', '{"grants":[]}']) {
      expect(parsePhoneText(t)).toEqual({ kind: "ignore" });
    }
  });

  it("expires at exp, never when exp is 0", () => {
    expect(isExpired({ exp: 0 }, NOW)).toBe(false);
    expect(isExpired({ exp: NOW + 1 }, NOW)).toBe(false);
    expect(isExpired({ exp: NOW }, NOW)).toBe(true);
  });
});

describe("token", () => {
  const token = "A".repeat(43);

  it("checks the format and parses the Authorization header", () => {
    expect(isValidToken(token)).toBe(true);
    expect(isValidToken("A".repeat(32))).toBe(true);
    expect(isValidToken("A".repeat(128))).toBe(true);
    expect(isValidToken("A".repeat(31))).toBe(false);
    expect(isValidToken("A".repeat(129))).toBe(false);
    expect(isValidToken("A".repeat(42) + "=")).toBe(false);
    expect(isValidToken("A".repeat(42) + "+")).toBe(false);

    expect(parseBearerToken(`Bearer ${token}`)).toEqual({ ok: true, token });
    expect(parseBearerToken(`bearer ${token}`)).toEqual({ ok: true, token });
    for (const h of [null, "", "Bearer", "Bearer ", `Basic ${token}`, token]) {
      expect(parseBearerToken(h)).toMatchObject({ ok: false, status: 400, reason: "missing token" });
    }
    for (const h of ["Bearer short", `Bearer ${token} extra`, `Bearer ${token}=`]) {
      expect(parseBearerToken(h)).toMatchObject({ ok: false, status: 400, reason: "bad token" });
    }
  });

  it("hashes the token string's UTF-8 bytes (contract test vector, §9)", async () => {
    expect(await sha256hex(token)).toBe("0f007385b6f9d4b7eeb2748605afe1a984a0a3bfa3f014d09e2a784ce9e5cd1a");
  });
});

describe("byte window", () => {
  it("allows exactly 100 MiB per fixed 60 s window, then starts over", () => {
    const w = newByteWindow(NOW);
    expect(takeBytes(w, NOW, RATE_WINDOW_BYTES)).toBe(true);
    expect(takeBytes(w, NOW + 1, 1)).toBe(false);
    expect(takeBytes(w, NOW + 59_999, 1)).toBe(false);
    expect(takeBytes(w, NOW + 60_000, RATE_WINDOW_BYTES)).toBe(true);
    expect(takeBytes(w, NOW + 60_000, 1)).toBe(false);
  });
});

describe("matchRoute (tunnel)", () => {
  it("matches the two tunnel routes and 404s the rest of /v1/tunnel", () => {
    expect(matchRoute("GET", "/v1/tunnel/abc/phone")).toEqual({ kind: "tunnel_phone", phoneId: "abc" });
    expect(matchRoute("GET", "/v1/tunnel/abc/client")).toEqual({ kind: "tunnel_client", phoneId: "abc" });
    for (const p of ["/v1/tunnel", "/v1/tunnel/abc", "/v1/tunnel/abc/other", "/v1/tunnel/abc/phone/x", "/v1/tunnel//phone"]) {
      expect(matchRoute("GET", p).kind).toBe("not_found");
    }
    expect(matchRoute("POST", "/v1/tunnel/abc/phone").kind).toBe("not_found");
    // existing routes are unaffected
    expect(matchRoute("GET", "/v1/host/abc")).toEqual({ kind: "host", hostId: "abc" });
    expect(matchRoute("GET", "/v1/device/abc")).toEqual({ kind: "device", hostId: "abc" });
  });
});
