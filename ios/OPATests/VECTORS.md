# OPA crypto test vectors (protocol v1)

**English** | [简体中文](VECTORS.zh-CN.md)

Produced by `OPATests/CryptoTests.testVectorsAndPrint` (CryptoKit) and cross-checked against Node `crypto`
(X25519, HKDF-SHA256, ChaCha20-Poly1305, Ed25519): all derived values match byte for byte.

Inputs (raw 32-byte private keys):
- device Ed25519 signing = `01` × 32
- host Ed25519 signing   = `02` × 32
- device X25519 ephemeral = `03` × 32
- host X25519 ephemeral   = `04` × 32

| value | result |
|---|---|
| devicePub (b64) | `iojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1w=` |
| hostPub (b64) | `gTl3Dqh9F19Wo1Rmw0x+zMuNipG07jeiXfYPW4/Js5Q=` |
| deviceId | `34750f98bd59fcfc946da45aaabe933b` |
| hostId | `6a3803d5f059902a1c6dafbc9ba47292` |
| ephPubD (b64) | `Xf7dO2vUf2+ijuFdlp1bsOpTd01Ii9r53xxuASSz7yI=` |
| ephPubH (b64) | `rAGyIJ6GNU+4UyN7XeD0+rE8f8v0M6YcAZNpYX/s8Qs=` |
| X25519 shared (hex) | `40e47a3f525bdcac491d418978d7db5af623ac7afe7623c6d78a5d4fce9d0f63` |
| kD2H (hex) | `29b39576079cf30bb3373d56eac8357129609c43b2610a8d094a73c4d46d7524` |
| kH2D (hex) | `38a420dd3edb9d5c0575dace1f62dc640dec9d0befb25fdaea550306864208e6` |
| kD2H first 8 bytes | `29b39576079cf30b` |
| kH2D first 8 bytes | `38a420dd3edb9d5c` |
| SAS | `992060` |
| `c` for `{"t":"req","id":"1","m":"ping","d":{}}`, kD2H, n=0 | `ke7I6qDOionHPT2dUGYIoRLcPetw47x2/WLaqd5lwuuC9YM4YTcfQRZHNqdXY2PxzWuije+9` |

Signatures: CryptoKit's Ed25519 `signature(for:)` is randomized (hedged), so its output differs on every run.
Compare signatures by verification, not by bytes. The deterministic RFC 8032 signature (Node `crypto.sign`, libsodium)
of the hello message `opa-hello-v1|6a3803d5f059902a1c6dafbc9ba47292|Xf7dO2vUf2+ijuFdlp1bsOpTd01Ii9r53xxuASSz7yI=|1760000000000`
with the device key is:

`B3yvm9/O3V8uL7sfGHg/8cglfscV1eqOXIoSaNHxO45HGwqW/qF4SUMqfLa/b1rcjtijqEH6y5Qp5ARVXtJZBg==`

`testVerifiesHostLibrarySignature` checks that CryptoKit accepts it, and Node accepts CryptoKit's signatures.
