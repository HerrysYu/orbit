# OPA 加密测试向量（协议 v1）

[English](VECTORS.md) | **简体中文**

由 `OPATests/CryptoTests.testVectorsAndPrint`（CryptoKit）生成，并与 Node `crypto`（X25519、HKDF-SHA256、ChaCha20-Poly1305、Ed25519）交叉核对：所有派生值均逐字节一致。

输入（原始 32 字节私钥）：
- device 的 Ed25519 签名密钥 = `01` × 32
- host 的 Ed25519 签名密钥   = `02` × 32
- device 的临时 X25519 密钥 = `03` × 32
- host 的临时 X25519 密钥   = `04` × 32

| 项目 | 结果 |
|---|---|
| devicePub (b64) | `iojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1w=` |
| hostPub (b64) | `gTl3Dqh9F19Wo1Rmw0x+zMuNipG07jeiXfYPW4/Js5Q=` |
| deviceId | `34750f98bd59fcfc946da45aaabe933b` |
| hostId | `6a3803d5f059902a1c6dafbc9ba47292` |
| ephPubD (b64) | `Xf7dO2vUf2+ijuFdlp1bsOpTd01Ii9r53xxuASSz7yI=` |
| ephPubH (b64) | `rAGyIJ6GNU+4UyN7XeD0+rE8f8v0M6YcAZNpYX/s8Qs=` |
| X25519 共享值 (hex) | `40e47a3f525bdcac491d418978d7db5af623ac7afe7623c6d78a5d4fce9d0f63` |
| kD2H (hex) | `29b39576079cf30bb3373d56eac8357129609c43b2610a8d094a73c4d46d7524` |
| kH2D (hex) | `38a420dd3edb9d5c0575dace1f62dc640dec9d0befb25fdaea550306864208e6` |
| kD2H 前 8 字节 | `29b39576079cf30b` |
| kH2D 前 8 字节 | `38a420dd3edb9d5c` |
| SAS | `992060` |
| 消息为 `{"t":"req","id":"1","m":"ping","d":{}}`、密钥为 `kD2H` 且 `n=0` 时的 `c` | `ke7I6qDOionHPT2dUGYIoRLcPetw47x2/WLaqd5lwuuC9YM4YTcfQRZHNqdXY2PxzWuije+9` |

签名：CryptoKit 的 Ed25519 `signature(for:)` 使用随机化（hedged），因此每次运行的输出都会不同。应通过验证签名来比较，而不是比较字节。使用设备密钥对 hello 消息 `opa-hello-v1|6a3803d5f059902a1c6dafbc9ba47292|Xf7dO2vUf2+ijuFdlp1bsOpTd01Ii9r53xxuASSz7yI=|1760000000000` 生成的确定性 RFC 8032 签名（Node `crypto.sign`、libsodium）为：

`B3yvm9/O3V8uL7sfGHg/8cglfscV1eqOXIoSaNHxO45HGwqW/qF4SUMqfLa/b1rcjtijqEH6y5Qp5ARVXtJZBg==`

`testVerifiesHostLibrarySignature` 检查 CryptoKit 能接受该签名，且 Node 能接受 CryptoKit 生成的签名。
