import { bytesToBase64Url, utf8 } from "../src/encoding";

export interface Identity {
  pub: Uint8Array;
  sign(msg: string): Promise<Uint8Array>;
}

export async function newIdentity(): Promise<Identity> {
  const kp = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const pub = new Uint8Array(await crypto.subtle.exportKey("raw", kp.publicKey));
  return {
    pub,
    sign: async (msg) => new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, kp.privateKey, utf8(msg))),
  };
}

export const b64u = bytesToBase64Url;
