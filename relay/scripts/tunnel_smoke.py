#!/usr/bin/env python3
"""Smoke test for the ADB tunnel relay (docs/design/adb-relay-protocol.md), run against `wrangler dev`.

    cd relay && npx wrangler dev --port 8787 --ip 127.0.0.1        # terminal 1 (local mode)
    uv run --with websockets --with cryptography python relay/scripts/tunnel_smoke.py ws://127.0.0.1:8787

Prints one line per scenario and exits 1 at the first failure (the scenarios build on each other).
Scenarios 1-10 follow the contract end to end with one phone identity; 11-13 use fresh identities.
Add --hibernate to also idle past the Durable Object hibernation timeout (adds about 30 s).
Never prints tokens, signatures or frame payloads.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import contextlib
import hashlib
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.request
from types import SimpleNamespace
from urllib.parse import urlsplit

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed, InvalidStatus

MAX_FRAME = 65536
RATE_BYTES = 100 * 1024 * 1024


class Fail(Exception):
    pass


def check(cond: object, msg: str) -> None:
    if not cond:
        raise Fail(msg)


def b64u(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def now_ms() -> int:
    return int(time.time() * 1000)


def frame(t: int, channel: int, payload: bytes = b"") -> bytes:
    """Binary frame as the endpoints build it: type u8 | channel u32 BE | payload (the relay never parses it)."""
    return bytes([t]) + channel.to_bytes(4, "big") + payload


class Phone:
    """A phone identity: Ed25519 key, phoneId = hex(sha256(pub))[:32]."""

    def __init__(self) -> None:
        self.key = Ed25519PrivateKey.generate()
        self.pub = self.key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        self.id = hashlib.sha256(self.pub).hexdigest()[:32]

    def url(self, base: str, *, path_id: str | None = None, ts: str | None = None, sig: bytes | None = None) -> str:
        ts = ts or str(now_ms())
        if sig is None:
            sig = self.key.sign(f"opa-tunnel-phone-v1|{self.id}|{ts}".encode())
        return f"{base}/v1/tunnel/{path_id or self.id}/phone?pub={b64u(self.pub)}&ts={ts}&sig={b64u(sig)}"


class Bot:
    """A grant plus the token that unlocks it. The relay only ever learns `hash`."""

    def __init__(self, gid: str, name: str, exp: int = 0) -> None:
        self.gid, self.name, self.exp = gid, name, exp
        self.token = b64u(secrets.token_bytes(32))
        self.hash = hashlib.sha256(self.token.encode()).hexdigest()

    @property
    def grant(self) -> dict:
        return {"id": self.gid, "name": self.name, "hash": self.hash, "exp": self.exp}

    def opened(self) -> dict:
        return {"t": "client", "state": "open", "grant": self.gid, "name": self.name}

    def closed(self) -> dict:
        return {"t": "client", "state": "closed", "grant": self.gid}


def bearer(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


class Ctx:
    def __init__(self, base: str, stack: contextlib.AsyncExitStack) -> None:
        self.base = base.rstrip("/")
        self.http = self.base.replace("wss://", "https://", 1).replace("ws://", "http://", 1)
        self.stack = stack
        self.local = urlsplit(self.base).hostname in ("127.0.0.1", "localhost", "::1")

    def open(self, url: str, headers: dict | None = None):
        """Connect and register the socket for cleanup. Handshake failures raise InvalidStatus."""
        return self.stack.enter_async_context(
            connect(
                url,
                additional_headers=headers,
                compression=None,
                proxy=None if self.local else True,
                open_timeout=5,
                close_timeout=1,
                max_size=2**21,
            )
        )

    def phone(self, p: Phone):
        return self.open(p.url(self.base))

    def client_url(self, phone_id: str) -> str:
        return f"{self.base}/v1/tunnel/{phone_id}/client"

    def client(self, phone_id: str, token: str):
        return self.open(self.client_url(phone_id), bearer(token))


def http_status(url: str) -> int:
    try:
        with urllib.request.urlopen(url, timeout=5) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code


async def expect_status(ctx: Ctx, url: str, status: int, headers: dict | None = None) -> None:
    try:
        await ctx.open(url, headers)
    except InvalidStatus as e:
        got = e.response.status_code
        check(got == status, f"expected HTTP {status}, got {got} for {urlsplit(url).path}")
        return
    raise Fail(f"expected HTTP {status}, but the WebSocket connected: {urlsplit(url).path}")


def close_info(ws) -> tuple[int | None, str]:
    """(code, reason) once the peer's Close frame has arrived, else (None, "")."""
    rcvd = ws.protocol.close_rcvd
    if rcvd is not None:
        return rcvd.code, rcvd.reason
    if ws.close_code is not None:  # transport gone without a Close frame
        return ws.close_code, ws.close_reason or ""
    return None, ""


async def recv_any(ws, timeout: float = 5.0):
    try:
        return await asyncio.wait_for(ws.recv(), timeout)
    except TimeoutError:
        code, reason = close_info(ws)
        if code is not None:
            raise Fail(f"socket was closed by the relay (code {code}, reason {reason!r}) while waiting for a frame") from None
        raise Fail(f"no frame within {timeout}s") from None
    except ConnectionClosed:
        raise Fail(f"socket closed while waiting for a frame (code {ws.close_code}, reason {ws.close_reason!r})") from None


async def recv_json(ws, timeout: float = 5.0) -> dict:
    m = await recv_any(ws, timeout)
    check(isinstance(m, str), "expected a text frame, got binary")
    return json.loads(m)


async def recv_bin(ws, timeout: float = 5.0) -> bytes:
    m = await recv_any(ws, timeout)
    check(isinstance(m, bytes), f"expected a binary frame, got text {m!r}")
    return m


async def expect_silent(ws, secs: float = 0.4) -> None:
    try:
        m = await asyncio.wait_for(ws.recv(), secs)
    except TimeoutError:
        code, _ = close_info(ws)
        check(code is None, f"socket was closed (code {code}) but was expected to stay open and quiet")
        return
    except ConnectionClosed:
        raise Fail(f"socket closed (code {ws.close_code}) but was expected to stay open and quiet") from None
    raise Fail(f"expected silence, got a {'binary' if isinstance(m, bytes) else 'text'} frame")


async def expect_closed(ws, code: int, reason: str | None = None, timeout: float = 5.0) -> None:
    """Wait for the relay's Close frame and check its code (and reason).

    The Close frame is the signal, not TCP teardown: workerd keeps the TCP connection of a socket it closed
    itself open until the Durable Object goes idle if that socket never sent a message (HostRelay does the
    same), so wait_closed() can lag by ~10 s.
    """
    deadline = time.monotonic() + timeout
    while close_info(ws)[0] is None:
        if time.monotonic() > deadline:
            raise Fail(f"no Close frame within {timeout}s (expected {code})")
        await asyncio.sleep(0.005)
    got_code, got_reason = close_info(ws)
    check(got_code == code, f"expected close code {code}, got {got_code} ({got_reason!r})")
    if reason is not None:
        check(got_reason == reason, f"expected close reason {reason!r}, got {got_reason!r}")


async def send_json(ws, obj: dict) -> None:
    await ws.send(json.dumps(obj, separators=(",", ":")))


async def set_grants(ws, bots: list[Bot]) -> None:
    await send_json(ws, {"t": "grants", "grants": [b.grant for b in bots]})
    check(await recv_json(ws) == {"t": "grants_ok", "count": len(bots)}, "grants were not acknowledged")


# --------------------------------------------------------------------------------------------
# Scenarios 1-10: one phone identity, in order
# --------------------------------------------------------------------------------------------


async def s1_phone_auth(ctx: Ctx, S: SimpleNamespace) -> str:
    S.phone = Phone()
    p = S.phone
    now = now_ms()
    await expect_status(ctx, p.url(ctx.base, ts=str(now - 10 * 60_000)), 401)  # stale ts
    await expect_status(ctx, p.url(ctx.base, sig=secrets.token_bytes(64)), 401)  # bad signature
    wrong_prefix = p.key.sign(f"opa-relay-host-v1|{p.id}|{now}".encode())
    await expect_status(ctx, p.url(ctx.base, ts=str(now), sig=wrong_prefix), 401)  # wrong message prefix
    await expect_status(ctx, p.url(ctx.base, path_id=Phone().id), 401)  # id != hash(pub)
    await expect_status(ctx, f"{ctx.base}/v1/tunnel/NOT-AN-ID/phone", 400)  # bad phoneId
    await expect_status(ctx, f"{ctx.base}/v1/tunnel/{p.id}/phone", 400)  # missing params
    check(http_status(f"{ctx.http}/v1/tunnel/{p.id}/phone") == 426, "plain GET on /phone should be 426")
    check(http_status(f"{ctx.http}/v1/tunnel/{p.id}/client") == 426, "plain GET on /client should be 426")
    check(http_status(f"{ctx.http}/v1/tunnel/{p.id}/other") == 404, "unknown tunnel path should be 404")
    check(http_status(f"{ctx.http}/v1/tunnel/{p.id}") == 404, "bare tunnel path should be 404")
    return "phone auth: stale ts / bad sig / wrong prefix / id mismatch 401; bad id / no params 400; plain GET 426; other paths 404"


async def s2_grants(ctx: Ctx, S: SimpleNamespace) -> str:
    S.A, S.B = Bot("gA", "bot-A"), Bot("gB", "bot-B")
    S.ph = await ctx.phone(S.phone)
    await S.ph.send("not json")  # ignored
    await S.ph.send('{"t":"mystery"}')  # unknown t: ignored
    await set_grants(S.ph, [S.A, S.B])  # the first reply is grants_ok, so the junk above got none
    bad = dict(S.A.grant, hash="XYZ")
    await send_json(S.ph, {"t": "grants", "grants": [bad]})
    check(await recv_json(S.ph) == {"t": "error", "reason": "bad_grants"}, "invalid table should be refused")
    await S.ph.send(json.dumps({"t": "grants", "grants": [], "pad": "x" * 70_000}))
    check(await recv_json(S.ph) == {"t": "error", "reason": "bad_grants"}, "oversized text frame should be refused")
    return "phone connects, junk ignored, grants [A,B] -> grants_ok 2; invalid and oversized tables -> bad_grants"


async def s3_client_auth(ctx: Ctx, S: SimpleNamespace) -> str:
    url = ctx.client_url(S.phone.id)
    await expect_status(ctx, url, 401, bearer(b64u(secrets.token_bytes(32))))  # well-formed, unknown
    await expect_status(ctx, ctx.client_url(Phone().id), 401, bearer(S.A.token))  # unknown phone: auth fails before 404
    await expect_status(ctx, url, 400, bearer("short"))  # malformed token
    await expect_status(ctx, url, 400, bearer("!" * 43))
    await expect_status(ctx, url, 400, {"Authorization": f"Basic {S.A.token}"})
    await expect_status(ctx, url, 400)  # no Authorization header
    await expect_status(ctx, ctx.client_url("NOT-AN-ID"), 400, bearer(S.A.token))
    return "client auth: unknown token 401; malformed / missing token 400; bad phoneId 400"


async def s4_client_open(ctx: Ctx, S: SimpleNamespace) -> str:
    S.ca = await ctx.client(S.phone.id, S.A.token)
    check(await recv_json(S.ph) == S.A.opened(), "phone should see client open for A")
    return "client A connects -> phone gets client open (A)"


async def s5_binary(ctx: Ctx, S: SimpleNamespace) -> str:
    up = [  # bot -> phone
        frame(1, 1, b"adb"),  # OPEN
        frame(2, 1, os.urandom(32768)),  # DATA, 32773 bytes with the header
        frame(3, 1),  # CLOSE, header only
        frame(7, 0, (42).to_bytes(8, "big")),  # NOTIFY_ACK
        frame(6, 0, os.urandom(40)),  # type 6 is not special to the relay, in either direction
        frame(0xFF, 9, os.urandom(10)),  # unknown type
    ]
    down = [  # phone -> bot
        frame(4, 1),  # OPEN_OK
        frame(2, 1, os.urandom(32768)),
        frame(5, 1, b"connect_failed"),
        frame(6, 0, os.urandom(120)),  # NOTIFY
    ]
    check(len(up[1]) == 32773, "test frame should be 32773 bytes")
    await S.ca.send("hello from the bot")  # text from the bot is ignored, never forwarded
    for f in up:
        await S.ca.send(f)
        check(await recv_bin(S.ph) == f, "bot -> phone frame was altered")
    for f in down:
        await S.ph.send(f)
        check(await recv_bin(S.ca) == f, "phone -> bot frame was altered")
    return f"binary round trip verbatim, {len(up)} frames up / {len(down)} down (32773 bytes, type 6, unknown type)"


async def s6_replace_client(ctx: Ctx, S: SimpleNamespace) -> str:
    S.cb = await ctx.client(S.phone.id, S.B.token)
    await expect_closed(S.ca, 4000, "replaced")
    check(await recv_json(S.ph) == S.A.closed(), "phone should hear closed(A) first")
    check(await recv_json(S.ph) == S.B.opened(), "then open(B)")
    await S.cb.send(frame(2, 1, b"x"))  # the new bot is the one being relayed
    check(await recv_bin(S.ph) == frame(2, 1, b"x"), "B's frames should reach the phone")
    return "client B replaces A -> A closed 4000, phone gets closed(A) then open(B)"


async def s7_revoke(ctx: Ctx, S: SimpleNamespace) -> str:
    await send_json(S.ph, {"t": "grants", "grants": [S.A.grant]})
    got = [await recv_json(S.ph), await recv_json(S.ph)]
    check({"t": "grants_ok", "count": 1} in got, "grants_ok missing")
    check(S.B.closed() in got, "phone should hear closed(B)")
    await expect_closed(S.cb, 4001, "revoked")
    return "grants without B -> B closed 4001, phone gets closed(B)"


async def s8_frame_limit(ctx: Ctx, S: SimpleNamespace) -> str:
    ca = await ctx.client(S.phone.id, S.A.token)
    check(await recv_json(S.ph) == S.A.opened(), "phone should see open(A)")
    edge = frame(2, 1, os.urandom(MAX_FRAME - 5))  # exactly 65536 bytes is allowed
    await ca.send(edge)
    check(await recv_bin(S.ph) == edge, "a 65536-byte frame should pass")
    await ca.send(os.urandom(70_000))
    await expect_closed(ca, 1009, "frame too large")
    check(await recv_json(S.ph) == S.A.closed(), "phone gets closed(A) and never the big frame")
    return "65536-byte frame passes; 70000-byte frame from the bot -> closed 1009, phone gets closed(A)"


async def s9_phone_offline(ctx: Ctx, S: SimpleNamespace) -> str:
    ca = await ctx.client(S.phone.id, S.A.token)
    check(await recv_json(S.ph) == S.A.opened(), "phone should see open(A)")
    await S.ph.close()
    await expect_closed(ca, 4004, "phone offline")
    await expect_status(ctx, ctx.client_url(S.phone.id), 404, bearer(S.A.token))
    return "phone disconnects -> bot closed 4004; reconnect attempt -> 404"


async def s10_phone_reconnect(ctx: Ctx, S: SimpleNamespace) -> str:
    ph2 = await ctx.phone(S.phone)  # no grants resent: they were persisted
    ca = await ctx.client(S.phone.id, S.A.token)
    check(await recv_json(ph2) == S.A.opened(), "persisted grant A should work on the reconnected phone")
    ph3 = await ctx.phone(S.phone)  # a second phone connection replaces the first
    await expect_closed(ph2, 4000, "replaced")
    await expect_closed(ca, 4003, "phone reconnected")
    await expect_silent(ph3)  # the new phone is not told about a bot it never saw
    cb = await ctx.client(S.phone.id, S.A.token)
    check(await recv_json(ph3) == S.A.opened(), "the bot can come back to the new phone")
    await cb.send(frame(1, 1, b"adb"))
    check(await recv_bin(ph3) == frame(1, 1, b"adb"), "and traffic flows")
    return "phone reconnects, persisted grants work; 2nd phone -> 1st closed 4000, bot closed 4003, new phone told nothing"


# --------------------------------------------------------------------------------------------
# Scenarios 11-13: fresh identities
# --------------------------------------------------------------------------------------------


async def fresh(ctx: Ctx, bot: Bot):
    """New phone with one grant and its bot already connected. Returns (phone, phone_ws, bot_ws)."""
    p = Phone()
    ph = await ctx.phone(p)
    await set_grants(ph, [bot])
    c = await ctx.client(p.id, bot.token)
    check(await recv_json(ph) == bot.opened(), "phone should see the bot open")
    return p, ph, c


async def expiry_case(ctx: Ctx, direction: str) -> None:
    bot = Bot("gE", "bot-exp", exp=now_ms() + 2500)
    p, ph, c = await fresh(ctx, bot)
    await asyncio.sleep(3.0)  # past exp
    await (c if direction == "bot" else ph).send(frame(2, 1, b"late"))
    await expect_closed(c, 4001, "revoked")
    check(await recv_json(ph) == bot.closed(), "phone should hear closed(E), not the late frame")
    await expect_status(ctx, ctx.client_url(p.id), 401, bearer(bot.token))  # and it cannot reconnect


async def s11_expiry(ctx: Ctx, S: SimpleNamespace) -> str:
    await asyncio.gather(expiry_case(ctx, "bot"), expiry_case(ctx, "phone"))
    return "expired grant: next frame from either side -> bot closed 4001, phone gets closed; reconnect -> 401"


async def s12_rate_limit(ctx: Ctx, S: SimpleNamespace) -> str:
    bot = Bot("gR", "bot-rate")
    p, ph, c = await fresh(ctx, bot)
    seen = {"phone": 0, "bot": 0}
    texts: list[dict] = []

    async def drain(ws, key: str) -> None:
        with contextlib.suppress(ConnectionClosed):
            async for m in ws:
                if isinstance(m, bytes):
                    seen[key] += len(m)
                else:
                    texts.append(json.loads(m))

    tasks = [asyncio.create_task(drain(ph, "phone")), asyncio.create_task(drain(c, "bot"))]
    chunk = os.urandom(MAX_FRAME)
    half = RATE_BYTES // MAX_FRAME // 2  # 800 frames each way = exactly 100 MiB together
    for _ in range(half):
        await c.send(chunk)
        await ph.send(chunk)
    for _ in range(100):
        if seen["phone"] == half * MAX_FRAME and seen["bot"] == half * MAX_FRAME:
            break
        await asyncio.sleep(0.05)
    check(seen["phone"] == half * MAX_FRAME, f"phone got {seen['phone']} bytes, expected {half * MAX_FRAME}")
    check(seen["bot"] == half * MAX_FRAME, f"bot got {seen['bot']} bytes, expected {half * MAX_FRAME}")
    with contextlib.suppress(ConnectionClosed):
        await ph.send(chunk)  # one byte over the budget, from the phone side
    await expect_closed(c, 4008, "rate limit")
    for _ in range(100):
        if bot.closed() in texts:
            break
        await asyncio.sleep(0.05)
    check(bot.closed() in texts, "phone should hear closed(R) after the rate limit")
    check(seen["bot"] == half * MAX_FRAME, "the frame over the budget must not be delivered")
    for t in tasks:
        t.cancel()
    return "100 MiB in one window (800 frames each way) passes; the next frame -> bot closed 4008, phone gets closed"


async def s13_phone_oversize(ctx: Ctx, S: SimpleNamespace) -> str:
    bot = Bot("gP", "bot-big")
    p, ph, c = await fresh(ctx, bot)
    await ph.send(os.urandom(70_000))
    await expect_closed(ph, 1009, "frame too large")
    await expect_closed(c, 4004, "phone offline")
    return "70000-byte frame from the phone -> phone closed 1009, bot closed 4004"


async def s14_hibernation(ctx: Ctx, S: SimpleNamespace) -> str:
    a, b = Bot("hA", "bot-hA"), Bot("hB", "bot-hB")
    p = Phone()
    ph = await ctx.phone(p)
    await set_grants(ph, [a, b])
    ca = await ctx.client(p.id, a.token)
    check(await recv_json(ph) == a.opened(), "phone should see open(A)")
    await asyncio.sleep(15)  # idle: the Durable Object is evicted from memory here (hibernation)
    await ca.send(frame(2, 1, b"up"))
    check(await recv_bin(ph) == frame(2, 1, b"up"), "bot -> phone after idle")
    await ph.send(frame(2, 1, b"down"))
    check(await recv_bin(ca) == frame(2, 1, b"down"), "phone -> bot after idle")
    await asyncio.sleep(15)
    cb = await ctx.client(p.id, b.token)  # needs the grants table (from storage) and A's restored attachment
    await expect_closed(ca, 4000, "replaced")
    check(await recv_json(ph) == a.closed(), "closed(A) after idle")
    check(await recv_json(ph) == b.opened(), "open(B) after idle")
    await cb.send(frame(1, 1, b"adb"))
    check(await recv_bin(ph) == frame(1, 1, b"adb"), "traffic after idle")
    return "idle 2x15 s, then traffic, replacement and grants lookup still work (hibernation)"


SCENARIOS = [
    s1_phone_auth,
    s2_grants,
    s3_client_auth,
    s4_client_open,
    s5_binary,
    s6_replace_client,
    s7_revoke,
    s8_frame_limit,
    s9_phone_offline,
    s10_phone_reconnect,
    s11_expiry,
    s12_rate_limit,
    s13_phone_oversize,
]


async def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("base", nargs="?", default="ws://127.0.0.1:8787", help="relay base URL (ws:// or wss://)")
    ap.add_argument("--hibernate", action="store_true", help="also run the slow idle/hibernation scenario")
    args = ap.parse_args()

    scenarios = SCENARIOS + ([s14_hibernation] if args.hibernate else [])
    started = time.monotonic()
    async with contextlib.AsyncExitStack() as stack:
        ctx = Ctx(args.base, stack)
        try:
            check(http_status(f"{ctx.http}/healthz") == 200, "GET /healthz did not return 200")
        except (Fail, OSError, urllib.error.URLError) as e:
            print(f"relay not reachable at {ctx.base}: {e}", file=sys.stderr)
            return 2
        S = SimpleNamespace()
        for n, fn in enumerate(scenarios, 1):
            t0 = time.monotonic()
            try:
                title = await fn(ctx, S)
            except (Fail, TimeoutError, OSError, InvalidStatus, ConnectionClosed) as e:
                print(f"FAIL {n:>2}. {fn.__name__}: {type(e).__name__}: {e}")
                for m in range(n + 1, len(scenarios) + 1):
                    print(f"skip {m:>2}. {scenarios[m - 1].__name__}")
                return 1
            print(f"ok   {n:>2}. {title}  [{time.monotonic() - t0:.1f}s]")
    print(f"all {len(scenarios)} scenarios passed in {time.monotonic() - started:.1f}s")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
