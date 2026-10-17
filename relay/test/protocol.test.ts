import { describe, expect, it } from "vitest";
import { idFromPub } from "../src/auth";
import { bytesToBase64 } from "../src/encoding";
import {
  HOST_OFFLINE,
  HOST_ONLINE,
  deviceConnectedFrame,
  deviceDisconnectedFrame,
  isDeviceAllowed,
  newBucket,
  normalizeAllowList,
  parseHostFrame,
  pushResultFrame,
  takeToken,
  wrapDeviceFrame,
} from "../src/protocol";
import { matchRoute } from "../src/routes";

const NOW = 1_760_000_000_000;

describe("matchRoute", () => {
  it("matches the three routes", () => {
    expect(matchRoute("GET", "/healthz")).toEqual({ kind: "healthz" });
    expect(matchRoute("GET", "/v1/host/abc")).toEqual({ kind: "host", hostId: "abc" });
    expect(matchRoute("GET", "/v1/device/abc")).toEqual({ kind: "device", hostId: "abc" });
  });
  it("rejects anything else", () => {
    expect(matchRoute("POST", "/v1/host/abc").kind).toBe("not_found");
    expect(matchRoute("GET", "/v1/host/abc/x").kind).toBe("not_found");
    expect(matchRoute("GET", "/v1/other/abc").kind).toBe("not_found");
    expect(matchRoute("GET", "/").kind).toBe("not_found");
  });
});

describe("frames", () => {
  it("wraps device data verbatim", () => {
    const data = '{"t":"x","n":0,"c":"AAAA"}';
    const f = JSON.parse(wrapDeviceFrame("d1", data));
    expect(f).toEqual({ from: "d1", data });
  });
  it("builds control frames", () => {
    expect(JSON.parse(HOST_ONLINE)).toEqual({ relay: "host_online" });
    expect(JSON.parse(HOST_OFFLINE)).toEqual({ relay: "host_offline" });
    expect(JSON.parse(deviceConnectedFrame("d"))).toEqual({ relay: "device_connected", deviceId: "d" });
    expect(JSON.parse(deviceDisconnectedFrame("d"))).toEqual({ relay: "device_disconnected", deviceId: "d" });
    expect(JSON.parse(pushResultFrame("p", 200))).toEqual({ relay: "push_result", id: "p", status: 200 });
    expect(JSON.parse(pushResultFrame("p", 410, "Unregistered"))).toEqual({
      relay: "push_result",
      id: "p",
      status: 410,
      reason: "Unregistered",
    });
  });
});

describe("parseHostFrame", () => {
  it("parses forward frames", () => {
    expect(parseHostFrame('{"to":"d","data":"x"}')).toEqual({ kind: "forward", to: "d", data: "x" });
  });
  it("parses allow and pairing", () => {
    expect(parseHostFrame('{"relay":"allow","devices":[]}')).toEqual({ kind: "allow", devices: [] });
    expect(parseHostFrame('{"relay":"pairing","until":5}')).toEqual({ kind: "pairing", until: 5 });
  });
  it("parses a full push frame", () => {
    const f = parseHostFrame(
      JSON.stringify({
        relay: "push",
        id: "p1",
        deviceToken: "ABCDEF0123456789",
        env: "sandbox",
        pushType: "liveactivity",
        topic: "com.example.app.push-type.liveactivity",
        priority: 10,
        collapseId: "c",
        expiration: 0,
        payload: { aps: {} },
      }),
    );
    expect(f).toEqual({
      kind: "push",
      push: {
        id: "p1",
        deviceToken: "abcdef0123456789",
        env: "sandbox",
        pushType: "liveactivity",
        topic: "com.example.app.push-type.liveactivity",
        priority: 10,
        collapseId: "c",
        expiration: 0,
        payload: { aps: {} },
      },
    });
  });
  it("reports invalid push with its id", () => {
    expect(parseHostFrame('{"relay":"push","id":"p","deviceToken":"zz"}')).toMatchObject({
      kind: "push_invalid",
      id: "p",
    });
    expect(
      parseHostFrame(
        '{"relay":"push","id":"p","deviceToken":"abcdef0123456789","env":"sandbox","pushType":"alert","topic":"a/b","payload":{}}',
      ),
    ).toMatchObject({ kind: "push_invalid", reason: "bad topic" });
  });
  it("rejects garbage", () => {
    expect(parseHostFrame("nope").kind).toBe("invalid");
    expect(parseHostFrame("[]").kind).toBe("invalid");
    expect(parseHostFrame('{"to":"d","data":1}').kind).toBe("invalid");
    expect(parseHostFrame('{"relay":"wat"}').kind).toBe("invalid");
    expect(parseHostFrame('{"relay":"pairing","until":"5"}').kind).toBe("invalid");
  });
});

describe("allowlist", () => {
  async function dev(seed: number) {
    const raw = new Uint8Array(32).fill(seed);
    return { id: await idFromPub(raw), pub: bytesToBase64(raw), raw };
  }

  it("normalizeAllowList keeps only entries whose id matches pub", async () => {
    const a = await dev(1);
    const b = await dev(2);
    const list = await normalizeAllowList([
      { id: a.id, pub: a.pub },
      { id: a.id, pub: b.pub }, // mismatch -> dropped
      { id: b.id, pub: b.pub.replace(/=+$/, "") }, // unpadded -> normalized
      { id: "x", pub: "!!" },
      "junk",
    ]);
    expect(list).toEqual([
      { id: a.id, pub: a.pub },
      { id: b.id, pub: b.pub },
    ]);
  });

  it("isDeviceAllowed: allowlist match requires id and pub", async () => {
    const a = await dev(1);
    const b = await dev(2);
    const state = { allow: [{ id: a.id, pub: a.pub }], pairingUntil: 0 };
    expect(isDeviceAllowed(state, { deviceId: a.id, pub: a.pub, pair: false }, NOW)).toBe(true);
    expect(isDeviceAllowed(state, { deviceId: a.id, pub: b.pub, pair: false }, NOW)).toBe(false);
    expect(isDeviceAllowed(state, { deviceId: b.id, pub: b.pub, pair: false }, NOW)).toBe(false);
  });

  it("isDeviceAllowed: pair=1 only while the window is open", async () => {
    const b = await dev(2);
    const open = { allow: [], pairingUntil: NOW + 1 };
    const closed = { allow: [], pairingUntil: NOW };
    expect(isDeviceAllowed(open, { deviceId: b.id, pub: b.pub, pair: true }, NOW)).toBe(true);
    expect(isDeviceAllowed(open, { deviceId: b.id, pub: b.pub, pair: false }, NOW)).toBe(false);
    expect(isDeviceAllowed(closed, { deviceId: b.id, pub: b.pub, pair: true }, NOW)).toBe(false);
  });
});

describe("token bucket", () => {
  it("allows a burst of 120 then refills at 120/s", () => {
    const b = newBucket(NOW);
    for (let i = 0; i < 120; i++) expect(takeToken(b, NOW)).toBe(true);
    expect(takeToken(b, NOW)).toBe(false);
    expect(takeToken(b, NOW + 5)).toBe(false); // 0.6 token
    expect(takeToken(b, NOW + 9)).toBe(true); // ~1.08 tokens
    expect(takeToken(b, NOW + 10_000)).toBe(true);
    expect(b.tokens).toBeLessThanOrEqual(120);
  });
});
