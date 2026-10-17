from __future__ import annotations

import asyncio
import base64
import json
import logging
import os
import subprocess
import sys
import time
from io import BytesIO
from pathlib import Path

from mcp.client.session import ClientSession
from mcp.client.stdio import StdioServerParameters, stdio_client
from mcp.shared.memory import create_client_server_memory_streams
from PIL import Image

from orbit_phone import adb as adb_module
from orbit_phone.adb import AdbError
from orbit_phone.lock import DeviceLock
from orbit_phone.server import PhoneService, create_server


class FakeAdb:
    def __init__(self):
        buffer = BytesIO()
        Image.new("RGB", (24, 32), color="orange").save(buffer, format="JPEG")
        self.screenshot_data = base64.b64encode(buffer.getvalue()).decode("ascii")
        self.actions: list[tuple] = []

    def list_devices(self):
        return []

    def pick_serial(self):
        return "test-device"

    def status(self, serial):
        return {
            "serial": serial,
            "screen_on": True,
            "locked": False,
            "foreground": {"package": "com.example.app", "activity": "Main"},
            "adb_keyboard_installed": True,
            "screen": {"width": 24, "height": 32},
        }

    def screenshot(self, serial):
        return {"data": self.screenshot_data, "width": 24, "height": 32, "is_sensitive": False}

    def ui_tree(self, serial, max_nodes=120):
        return [{"text": "Search", "center": {"x": 500, "y": 200}}]

    def tap(self, serial, x, y):
        self.actions.append(("tap", serial, x, y))

    def double_tap(self, serial, x, y):
        self.actions.append(("double_tap", serial, x, y))

    def long_press(self, serial, x, y, ms):
        self.actions.append(("long_press", serial, x, y, ms))

    def swipe(self, serial, x1, y1, x2, y2, ms):
        self.actions.append(("swipe", serial, x1, y1, x2, y2, ms))

    def type_text(self, serial, text):
        self.actions.append(("type", serial, text))

    def clear_text(self, serial):
        self.actions.append(("clear_text", serial))

    def back(self, serial):
        self.actions.append(("back", serial))

    def home(self, serial):
        self.actions.append(("home", serial))

    def launch_app(self, serial, app):
        self.actions.append(("launch", serial, app))


def _text_payload(result) -> dict:
    for item in result.content:
        if item.type == "text":
            return json.loads(item.text)
    raise AssertionError("MCP result did not contain JSON TextContent")


def test_action_is_rejected_without_begin(tmp_path: Path) -> None:
    async def run() -> None:
        fake = FakeAdb()
        service = PhoneService(home=tmp_path, adb_api=fake, settle_seconds=0)
        result = await service.phone_tap(1, 2)
        assert _text_payload(result)["status"] == "not_started"
        observed = await service.phone_observe()
        assert _text_payload(observed)["status"] == "not_started"
        assert fake.actions == []

    asyncio.run(run())


def test_begin_observe_and_end_manage_lock_and_evidence(tmp_path: Path) -> None:
    async def run() -> None:
        fake = FakeAdb()
        service = PhoneService(home=tmp_path, adb_api=fake, settle_seconds=0)
        result = await service.phone_begin("offline check")
        assert _text_payload(result)["status"] == "started"
        assert service.lock.held is True
        observed = await service.phone_observe(include_tree=True)
        assert _text_payload(observed)["ui_tree"][0]["text"] == "Search"
        await service.phone_tap(500, 250)
        assert fake.actions == [("tap", "test-device", 500, 250)]
        ended = await service.phone_end("done")
        payload = _text_payload(ended)
        assert payload["status"] == "ended"
        assert Path(payload["screenshot"]).is_file()
        assert payload["evidence"] == payload["screenshot"]
        assert service.lock.held is False

    asyncio.run(run())


def test_every_action_tool_can_return_ui_tree_and_defaults_to_none(tmp_path: Path) -> None:
    async def run() -> None:
        fake = FakeAdb()
        service = PhoneService(home=tmp_path, adb_api=fake, settle_seconds=0)
        assert _text_payload(await service.phone_begin("tree on actions"))["status"] == "started"

        calls = {
            "tap": lambda **kw: service.phone_tap(500, 250, **kw),
            "double_tap": lambda **kw: service.phone_double_tap(500, 250, **kw),
            "long_press": lambda **kw: service.phone_long_press(500, 250, 600, **kw),
            "swipe": lambda **kw: service.phone_swipe(500, 800, 500, 200, 300, **kw),
            "type": lambda **kw: service.phone_type("hello", **kw),
            "clear_text": lambda **kw: service.phone_clear_text(**kw),
            "back": lambda **kw: service.phone_back(**kw),
            "home": lambda **kw: service.phone_home(**kw),
            "launch": lambda **kw: service.phone_launch("com.example.app", **kw),
            "wait": lambda **kw: service.phone_wait(0, **kw),
        }
        for name, call in calls.items():
            default = _text_payload(await call())
            assert default["status"] == "ok", name
            assert "ui_tree" not in default, name
            explicit_off = _text_payload(await call(include_tree=False))
            assert "ui_tree" not in explicit_off, name
            with_tree = await call(include_tree=True)
            payload = _text_payload(with_tree)
            assert payload["status"] == "ok", name
            assert payload["action"] == name
            assert payload["ui_tree"][0]["text"] == "Search", name
            # The screenshot is still the first content item, exactly as without the tree.
            assert with_tree.content[0].type == "image", name
        await service.phone_end("done")

    asyncio.run(run())


def test_action_tools_expose_include_tree_in_mcp_schema_and_forward_it(tmp_path: Path) -> None:
    async def run() -> None:
        fake = FakeAdb()
        service = PhoneService(home=tmp_path, adb_api=fake, settle_seconds=0)
        server = create_server(service)
        async with create_client_server_memory_streams() as (client_streams, server_streams):
            server_task = asyncio.create_task(
                server._lowlevel_server.run(
                    server_streams[0],
                    server_streams[1],
                    server._lowlevel_server.create_initialization_options(),
                )
            )
            try:
                async with ClientSession(*client_streams) as client:
                    await client.initialize()
                    tools = {tool.name: tool for tool in (await client.list_tools()).tools}
                    for name in (
                        "phone_tap", "phone_double_tap", "phone_long_press", "phone_swipe", "phone_type",
                        "phone_clear_text", "phone_back", "phone_home", "phone_launch", "phone_wait",
                    ):
                        schema = tools[name].input_schema
                        assert "include_tree" in schema["properties"], name
                        assert "include_tree" not in schema.get("required", []), name
                        assert schema["properties"]["include_tree"].get("default") is False, name
                    await client.call_tool("phone_begin", {"task": "schema check"})
                    plain = await client.call_tool("phone_tap", {"x": 10, "y": 20})
                    assert "ui_tree" not in _text_payload(plain)
                    tree = await client.call_tool("phone_tap", {"x": 10, "y": 20, "include_tree": True})
                    assert _text_payload(tree)["ui_tree"][0]["text"] == "Search"
                    await client.call_tool("phone_end", {"summary": "schema check done"})
            finally:
                if not server_task.done():
                    server_task.cancel()
                try:
                    await server_task
                except asyncio.CancelledError:
                    pass

    asyncio.run(run())


def test_begin_status_or_screenshot_failure_releases_lock(tmp_path: Path) -> None:
    class FailingAdb(FakeAdb):
        fail_at = "status"

        def status(self, serial):
            if self.fail_at == "status":
                raise AdbError("status unavailable")
            return super().status(serial)

        def screenshot(self, serial):
            if self.fail_at == "screenshot":
                raise AdbError("screenshot unavailable")
            return super().screenshot(serial)

    async def run() -> None:
        for failure in ("status", "screenshot"):
            fake = FailingAdb()
            fake.fail_at = failure
            service = PhoneService(home=tmp_path / failure, adb_api=fake, settle_seconds=0)
            result = await service.phone_begin("failure cleanup")
            assert _text_payload(result)["status"] == "error"
            assert service.lock.held is False
            service.close()

    asyncio.run(run())


def test_type_result_does_not_echo_input_text(tmp_path: Path) -> None:
    async def run() -> None:
        fake = FakeAdb()
        service = PhoneService(home=tmp_path, adb_api=fake, settle_seconds=0)
        await service.phone_begin("type test")
        result = await service.phone_type("OPA-SENSITIVE-INPUT")
        serialized = json.dumps([item.model_dump(by_alias=True) for item in result.content])
        assert "OPA-SENSITIVE-INPUT" not in serialized
        await service.phone_end("finished")

    asyncio.run(run())


def test_type_text_restores_ime_and_redacts_upstream_failure(tmp_path: Path, monkeypatch) -> None:
    fake = FakeAdb()
    monkeypatch.setattr(adb_module, "pick_serial", lambda: "test-device")
    monkeypatch.setattr(adb_module, "status", fake.status)
    monkeypatch.setattr(adb_module, "screenshot", fake.screenshot)
    monkeypatch.setattr(adb_module, "ui_tree", fake.ui_tree)

    original_ime = "com.android.inputmethod.latin/.LatinIME"
    secret = "private-input-should-not-be-logged"
    calls: list[tuple] = []
    should_fail = False

    def detect_and_set_adb_keyboard(device_id=None):
        calls.append(("detect", device_id))
        return original_ime

    def upstream_type_text(text, device_id=None):
        calls.append(("type", text, device_id))
        if should_fail:
            raise RuntimeError(f"failed to enter {text}")

    def restore_keyboard(ime, device_id=None):
        calls.append(("restore", ime, device_id))

    monkeypatch.setattr(adb_module.phone_adb, "detect_and_set_adb_keyboard", detect_and_set_adb_keyboard)
    monkeypatch.setattr(adb_module.phone_adb, "type_text", upstream_type_text)
    monkeypatch.setattr(adb_module.phone_adb, "restore_keyboard", restore_keyboard)

    async def run() -> None:
        nonlocal should_fail
        for should_fail in (False, True):
            calls.clear()
            service = PhoneService(home=tmp_path / str(should_fail), adb_api=adb_module, settle_seconds=0)
            assert _text_payload(await service.phone_begin("IME restore test"))["status"] == "started"
            result = await service.phone_type(secret)
            payload = _text_payload(result)
            serialized = json.dumps([item.model_dump(by_alias=True) for item in result.content])
            assert (payload["status"] == "error") is should_fail
            assert secret not in serialized
            assert calls == [
                ("detect", "test-device"),
                ("type", secret, "test-device"),
                ("restore", original_ime, "test-device"),
            ]
            if should_fail:
                assert service.lock.held is False
            else:
                await service.phone_end("input complete")

    asyncio.run(run())


def test_cancel_without_local_begin_uses_configured_serial(tmp_path: Path, monkeypatch) -> None:
    async def run() -> None:
        serial = "192.0.2.4:5555"
        monkeypatch.setenv("OPA_PHONE_SERIAL", serial)
        external_owner = DeviceLock(serial, tmp_path, poll_seconds=0.02)
        assert external_owner.acquire("remote worker")[0]
        service = PhoneService(home=tmp_path, adb_api=FakeAdb(), settle_seconds=0)
        result = await service.phone_cancel()
        assert _text_payload(result)["serial"] == serial
        assert service.lock.cancel_path.is_file()
        deadline = time.monotonic() + 2
        while external_owner.held and time.monotonic() < deadline:
            await asyncio.sleep(0.02)
        assert external_owner.held is False

    asyncio.run(run())


def test_cancel_only_owned_ignores_external_lock_and_cancels_own_lock(tmp_path: Path, monkeypatch) -> None:
    async def wait_released(lock: DeviceLock) -> None:
        deadline = time.monotonic() + 2
        while lock.held and time.monotonic() < deadline:
            await asyncio.sleep(0.02)
        assert lock.held is False

    async def run() -> None:
        serial = "test-device"
        monkeypatch.setenv("OPA_PHONE_SERIAL", serial)
        external_owner = DeviceLock(serial, tmp_path, poll_seconds=0.02)
        assert external_owner.acquire("external task")[0]

        service = PhoneService(home=tmp_path, adb_api=FakeAdb(), settle_seconds=0)
        ignored = await service.phone_cancel(only_owned=True)
        assert _text_payload(ignored)["status"] == "idle"
        assert external_owner.held is True
        assert not service.lock.cancel_path.exists()

        assert _text_payload(await service.phone_cancel())["status"] == "cancel_requested"
        await wait_released(external_owner)

        own_service = PhoneService(home=tmp_path / "own", adb_api=FakeAdb(), settle_seconds=0)
        assert _text_payload(await own_service.phone_begin("owned task"))["status"] == "started"
        assert _text_payload(await own_service.phone_cancel(only_owned=True))["status"] == "cancel_requested"
        await wait_released(own_service.lock)

    asyncio.run(run())


def test_memory_client_receives_devices_observe_and_image_content(tmp_path: Path) -> None:
    async def run() -> None:
        fake = FakeAdb()
        service = PhoneService(home=tmp_path, adb_api=fake, settle_seconds=0)
        server = create_server(service)
        async with create_client_server_memory_streams() as (client_streams, server_streams):
            server_task = asyncio.create_task(
                server._lowlevel_server.run(
                    server_streams[0],
                    server_streams[1],
                    server._lowlevel_server.create_initialization_options(),
                )
            )
            try:
                async with ClientSession(*client_streams) as client:
                    await client.initialize()
                    devices = await client.call_tool("phone_devices")
                    assert _text_payload(devices)["devices"] == []
                    begun = await client.call_tool("phone_begin", {"task": "memory client"})
                    assert begun.content[0].type == "image"
                    assert begun.content[0].mime_type == "image/jpeg"
                    assert _text_payload(begun)["status"] == "started"
                    observed = await client.call_tool("phone_observe", {"include_tree": True})
                    image = next(item for item in observed.content if item.type == "image")
                    assert image.mime_type == "image/jpeg"
                    assert base64.b64decode(image.data).startswith(b"\xff\xd8")
                    assert _text_payload(observed)["foreground"]["package"] == "com.example.app"
                    await client.call_tool("phone_end", {"summary": "offline client done"})
            finally:
                if not server_task.done():
                    server_task.cancel()
                try:
                    await server_task
                except asyncio.CancelledError:
                    pass

    asyncio.run(run())


def test_stdio_stdout_stays_protocol_clean_when_upstream_prints(tmp_path: Path, caplog) -> None:
    caplog.set_level(logging.ERROR, logger="mcp.client.stdio")

    async def run() -> None:
        fake_path = tmp_path / "empty-bin"
        fake_path.mkdir()
        env = dict(os.environ)
        env.update({"PATH": str(fake_path), "OPA_HOME": str(tmp_path / "opa"), "OPA_PHONE_SERIAL": "e7fe2f2a"})
        params = StdioServerParameters(command=sys.executable, args=["-m", "orbit_phone.server"], env=env, cwd=Path(__file__).parents[1])
        async with stdio_client(params) as (read_stream, write_stream):
            async with ClientSession(read_stream, write_stream) as client:
                await client.initialize()
                result = await client.call_tool("phone_devices")
                assert _text_payload(result)["devices"] == []

    asyncio.run(run())
    assert not [record for record in caplog.records if "Failed to parse JSONRPC message from server" in record.getMessage()]

