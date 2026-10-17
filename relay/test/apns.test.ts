import { describe, expect, it } from "vitest";
import { buildApnsRequest, importApnsKey, pemToDer, sendPush, signApnsJwt } from "../src/apns";
import { base64UrlToBytes, bytesToBase64, utf8 } from "../src/encoding";
import type { PushRequest } from "../src/protocol";

async function newP8(): Promise<{ pem: string; pub: CryptoKey }> {
  const kp = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
    "sign",
    "verify",
  ])) as CryptoKeyPair;
  const der = new Uint8Array((await crypto.subtle.exportKey("pkcs8", kp.privateKey)) as ArrayBuffer);
  const b64 = bytesToBase64(der).replace(/(.{64})/g, "$1\n");
  return { pem: `-----BEGIN PRIVATE KEY-----\n${b64}\n-----END PRIVATE KEY-----\n`, pub: kp.publicKey };
}

const push: PushRequest = {
  id: "p1",
  deviceToken: "abcdef0123456789",
  env: "production",
  pushType: "alert",
  topic: "com.example.app",
  priority: 5,
  collapseId: "c1",
  expiration: 0,
  payload: { aps: { alert: "hi" } },
};

describe("APNs JWT", () => {
  it("signs a verifiable ES256 JWT with raw r||s signature", async () => {
    const { pem, pub } = await newP8();
    const key = await importApnsKey(pem);
    const jwt = await signApnsJwt(key, "KEYID12345", "TEAMID1234", 1_760_000_000_123);
    const [h, c, s] = jwt.split(".");
    expect(JSON.parse(new TextDecoder().decode(base64UrlToBytes(h)!))).toEqual({ alg: "ES256", kid: "KEYID12345" });
    expect(JSON.parse(new TextDecoder().decode(base64UrlToBytes(c)!))).toEqual({ iss: "TEAMID1234", iat: 1_760_000_000 });
    const sig = base64UrlToBytes(s)!;
    expect(sig.length).toBe(64);
    expect(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, pub, sig, utf8(`${h}.${c}`))).toBe(true);
  });

  it("pemToDer tolerates escaped newlines", async () => {
    const { pem } = await newP8();
    expect(pemToDer(pem.replace(/\n/g, "\\n"))).toEqual(pemToDer(pem));
  });
});

describe("buildApnsRequest", () => {
  it("maps fields onto URL and headers", () => {
    const r = buildApnsRequest(push, "JWT");
    expect(r.url).toBe("https://api.push.apple.com/3/device/abcdef0123456789");
    expect(r.headers).toEqual({
      authorization: "bearer JWT",
      "apns-topic": "com.example.app",
      "apns-push-type": "alert",
      "apns-priority": "5",
      "apns-collapse-id": "c1",
      "apns-expiration": "0",
      "content-type": "application/json",
    });
    expect(JSON.parse(r.body)).toEqual(push.payload);
  });
  it("uses sandbox host and omits optional headers", () => {
    const r = buildApnsRequest(
      { ...push, env: "sandbox", priority: undefined, collapseId: undefined, expiration: undefined },
      "J",
    );
    expect(r.url.startsWith("https://api.sandbox.push.apple.com/3/device/")).toBe(true);
    expect(Object.keys(r.headers).sort()).toEqual(["apns-push-type", "apns-topic", "authorization", "content-type"]);
  });
});

describe("sendPush", () => {
  it("returns status and APNs reason, caches the token", async () => {
    const { pem } = await newP8();
    const auths: string[] = [];
    const fake = (async (_url: string, init: RequestInit) => {
      auths.push((init.headers as Record<string, string>).authorization);
      return new Response(JSON.stringify({ reason: "BadDeviceToken" }), { status: 400 });
    }) as unknown as typeof fetch;
    const creds = { keyP8: pem, keyId: "K", teamId: "T" };
    expect(await sendPush(push, creds, 1_000_000, fake)).toEqual({ status: 400, reason: "BadDeviceToken" });
    expect(await sendPush(push, creds, 1_000_000 + 60_000, fake)).toEqual({ status: 400, reason: "BadDeviceToken" });
    expect(auths[0]).toBe(auths[1]);
    await sendPush(push, creds, 1_000_000 + 51 * 60_000, fake);
    expect(auths[2]).not.toBe(auths[0]);
  });
});
