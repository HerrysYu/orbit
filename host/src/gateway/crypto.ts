// OPA wire crypto — see docs/protocol.md §1–2. Must stay byte-compatible with the iOS CryptoKit impl.
import {
  createCipheriv, createDecipheriv, createHash, createPrivateKey, createPublicKey,
  diffieHellman, generateKeyPairSync, hkdfSync, sign, verify, type KeyObject,
} from 'node:crypto';

export const b64 = (b: Uint8Array) => Buffer.from(b).toString('base64');
export const unb64 = (s: string) => new Uint8Array(Buffer.from(s, 'base64'));
export const b64url = (b: Uint8Array) => Buffer.from(b).toString('base64url');
export const unb64url = (s: string) => new Uint8Array(Buffer.from(s, 'base64url'));

/** hostId / deviceId = first 32 hex chars of sha256(raw pub). */
export function idFromPub(pub: Uint8Array): string {
  return createHash('sha256').update(pub).digest('hex').slice(0, 32);
}

// PKCS#8 DER prefixes for raw 32-byte private keys (RFC 8410).
const ED_PKCS8 = Buffer.from('302e020100300506032b657004220420', 'hex');
const X_PKCS8 = Buffer.from('302e020100300506032b656e04220420', 'hex');

export interface SigningKey { priv: KeyObject; pub: Uint8Array; seed: Uint8Array }

export function signingKeyFromSeed(seed: Uint8Array): SigningKey {
  const priv = createPrivateKey({ key: Buffer.concat([ED_PKCS8, seed]), format: 'der', type: 'pkcs8' });
  return { priv, pub: rawPub(priv), seed };
}

export function generateSigningKey(): SigningKey {
  const { privateKey } = generateKeyPairSync('ed25519');
  const jwk = privateKey.export({ format: 'jwk' });
  return { priv: privateKey, pub: rawPub(privateKey), seed: unb64url(jwk.d!) };
}

function rawPub(priv: KeyObject): Uint8Array {
  return unb64url(createPublicKey(priv).export({ format: 'jwk' }).x!);
}

export function edSign(k: SigningKey, msg: string): Uint8Array {
  return new Uint8Array(sign(null, Buffer.from(msg, 'utf8'), k.priv));
}

export function edVerify(pub: Uint8Array, msg: string, sig: Uint8Array): boolean {
  try {
    const key = createPublicKey({ key: { kty: 'OKP', crv: 'Ed25519', x: b64url(pub) }, format: 'jwk' });
    return verify(null, Buffer.from(msg, 'utf8'), key, sig);
  } catch {
    return false;
  }
}

export interface EphKey { priv: KeyObject; pub: Uint8Array }

export function ephFromRaw(raw: Uint8Array): EphKey {
  const priv = createPrivateKey({ key: Buffer.concat([X_PKCS8, raw]), format: 'der', type: 'pkcs8' });
  return { priv, pub: unb64url(createPublicKey(priv).export({ format: 'jwk' }).x!) };
}

export function generateEph(): EphKey {
  const { privateKey } = generateKeyPairSync('x25519');
  return { priv: privateKey, pub: unb64url(createPublicKey(privateKey).export({ format: 'jwk' }).x!) };
}

export interface SessionKeys { d2h: Buffer; h2d: Buffer; sas: string }

export function deriveSessionKeys(myEph: EphKey, peerEphPub: Uint8Array, ephD: Uint8Array, ephH: Uint8Array): SessionKeys {
  const peer = createPublicKey({ key: { kty: 'OKP', crv: 'X25519', x: b64url(peerEphPub) }, format: 'jwk' });
  const shared = diffieHellman({ privateKey: myEph.priv, publicKey: peer });
  const salt = Buffer.concat([ephD, ephH]);
  const d2h = Buffer.from(hkdfSync('sha256', shared, salt, 'opa-v1-d2h', 32));
  const h2d = Buffer.from(hkdfSync('sha256', shared, salt, 'opa-v1-h2d', 32));
  const h = createHash('sha256').update('opa-sas').update(ephD).update(ephH).digest();
  const sas = String(h.readUInt32BE(0) % 1_000_000).padStart(6, '0');
  return { d2h, h2d, sas };
}

const AAD = Buffer.from('opa-v1', 'utf8');

function nonceFor(n: number): Buffer {
  const nonce = Buffer.alloc(12);
  nonce.writeBigUInt64BE(BigInt(n), 4);
  return nonce;
}

export function seal(key: Buffer, n: number, plaintext: string): string {
  const c = createCipheriv('chacha20-poly1305', key, nonceFor(n), { authTagLength: 16 });
  c.setAAD(AAD, { plaintextLength: Buffer.byteLength(plaintext) });
  const ct = Buffer.concat([c.update(plaintext, 'utf8'), c.final()]);
  return Buffer.concat([ct, c.getAuthTag()]).toString('base64');
}

export function open(key: Buffer, n: number, c64: string): string {
  const buf = Buffer.from(c64, 'base64');
  if (buf.length < 16) throw new Error('short frame');
  const d = createDecipheriv('chacha20-poly1305', key, nonceFor(n), { authTagLength: 16 });
  d.setAAD(AAD, { plaintextLength: buf.length - 16 });
  d.setAuthTag(buf.subarray(buf.length - 16));
  return Buffer.concat([d.update(buf.subarray(0, buf.length - 16)), d.final()]).toString('utf8');
}

export const helloMsg = (hostId: string, ephPub64: string, ts: number) => `opa-hello-v1|${hostId}|${ephPub64}|${ts}`;
export const welcomeMsg = (deviceId: string, ephD64: string, ephH64: string) => `opa-welcome-v1|${deviceId}|${ephD64}|${ephH64}`;
export const relayHostMsg = (hostId: string, ts: number) => `opa-relay-host-v1|${hostId}|${ts}`;
