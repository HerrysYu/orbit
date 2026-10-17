"""MCPServer stdio endpoint for safe, model-free Android primitives."""

from __future__ import annotations

import atexit
import asyncio
import base64
import json
import os
import signal
import sys
from datetime import datetime
from pathlib import Path
from typing import Any, Callable

import anyio
from mcp.server.mcpserver import MCPServer
from mcp.server.stdio import stdio_server
from mcp.types import CallToolResult, ImageContent, TextContent, ToolAnnotations

from . import adb
from .lock import DeviceLock, PhoneCancelled, PhoneNotStarted, opa_home


def _json_text(data: dict[str, Any]) -> TextContent:
    return TextContent(type="text", text=json.dumps(data, ensure_ascii=False, separators=(",", ":")))


def _error_result(status: str, message: str, *, is_error: bool = False) -> CallToolResult:
    return CallToolResult(content=[_json_text({"status": status, "message": message})], is_error=is_error)


def _exception_message(exc: BaseException) -> str:
    if isinstance(exc, adb.AdbError):
        return str(exc)
    return f"Device operation failed ({type(exc).__name__})."


class PhoneService:
    """Stateful tool implementation. A background watcher frees an idle lock on cancel."""

    def __init__(self, *, home: Path | None = None, adb_api: Any = adb, settle_seconds: float = 0.6):
        self.home = home or opa_home()
        self.adb = adb_api
        self.settle_seconds = settle_seconds
        configured_serial = os.environ.get("OPA_PHONE_SERIAL", "").strip() or adb.DEFAULT_SERIAL
        self.lock = DeviceLock(serial=configured_serial, home=self.home)
        self._operation_gate = asyncio.Lock()

    def _new_lock(self, serial: str) -> DeviceLock:
        return DeviceLock(serial=serial, home=self.home)

    def _observe(
        self,
        serial: str,
        include_tree: bool,
        info: dict[str, Any] | None = None,
    ) -> tuple[dict[str, Any], dict[str, Any]]:
        info = info or self.adb.status(serial)
        screenshot = self.adb.screenshot(serial)
        data: dict[str, Any] = {
            "status": "ok",
            "serial": serial,
            "foreground": info.get("foreground"),
            "screen": info.get("screen"),
            "screen_on": info.get("screen_on"),
            "locked": info.get("locked"),
            "adb_keyboard_installed": info.get("adb_keyboard_installed"),
            "is_sensitive": bool(screenshot.get("is_sensitive", False)),
        }
        if include_tree:
            data["ui_tree"] = self.adb.ui_tree(serial, max_nodes=120)
        return screenshot, data

    def _observe_result(self, screenshot: dict[str, Any], data: dict[str, Any], extra: dict[str, Any] | None = None) -> CallToolResult:
        payload = {**data, **(extra or {})}
        return CallToolResult(
            content=[
                ImageContent(type="image", data=screenshot["data"], mimeType="image/jpeg"),
                _json_text(payload),
            ]
        )

    async def phone_begin(self, task: str) -> CallToolResult:
        """Acquire the shared device lock and include its initial status and screenshot."""
        async with self._operation_gate:
            if self.lock.held:
                try:
                    with self.lock.operation() as serial:
                        shot, data = self._observe(serial, True)
                        if self.lock.is_cancelled():
                            raise PhoneCancelled("Phone task was cancelled.")
                    return self._observe_result(shot, data, {"status": "already_started", "task": self.lock.owner.get("task") if self.lock.owner else None})
                except PhoneCancelled:
                    return _error_result("cancelled", "This phone task was cancelled.", is_error=True)
                except Exception as exc:
                    self.lock.release_after_operation()
                    return _error_result("error", _exception_message(exc), is_error=True)

            try:
                serial = self.adb.pick_serial()
            except Exception as exc:
                return _error_result("unavailable", _exception_message(exc), is_error=True)

            self.lock = self._new_lock(serial)
            acquired, owner = self.lock.acquire(task)
            if not acquired:
                return CallToolResult(content=[_json_text({"status": "busy", "serial": serial, "owner": owner})])
            try:
                with self.lock.operation() as active_serial:
                    info = self.adb.status(active_serial)
                    screenshot, data = self._observe(active_serial, True, info)
                    data = {**data, "device_status": info}
                    if self.lock.is_cancelled():
                        raise PhoneCancelled("Phone task was cancelled.")
                return self._observe_result(screenshot, data, {"status": "started", "task": task})
            except PhoneCancelled:
                self.lock.release()
                return _error_result("cancelled", "Phone task was cancelled while it was starting.", is_error=True)
            except Exception as exc:
                self.lock.release_after_operation()
                return _error_result("error", _exception_message(exc), is_error=True)

    async def phone_observe(self, include_tree: bool = True) -> CallToolResult:
        """Return a real MCP image plus JSON status; requires an active phone_begin lock."""
        return await self._observe_tool(include_tree, action_name="observe")

    async def _observe_tool(self, include_tree: bool, *, action_name: str) -> CallToolResult:
        async with self._operation_gate:
            try:
                with self.lock.operation() as serial:
                    shot, data = self._observe(serial, include_tree)
                    if self.lock.is_cancelled():
                        raise PhoneCancelled("Phone task was cancelled.")
                return self._observe_result(shot, data, {"action": action_name})
            except PhoneCancelled:
                return _error_result("cancelled", "This phone task was cancelled.", is_error=True)
            except PhoneNotStarted as exc:
                return _error_result("not_started", str(exc), is_error=True)
            except Exception as exc:
                self.lock.release_after_operation()
                return _error_result("error", _exception_message(exc), is_error=True)

    async def _action(self, action: str, fn: Callable[[str], None], include_tree: bool = False) -> CallToolResult:
        async with self._operation_gate:
            try:
                with self.lock.operation() as serial:
                    fn(serial)
                    await self._wait_or_cancel(self.settle_seconds)
                    screenshot, data = self._observe(serial, include_tree)
                    if self.lock.is_cancelled():
                        raise PhoneCancelled("Phone task was cancelled.")
                return self._observe_result(screenshot, data, {"action": action, "status": "ok"})
            except PhoneCancelled:
                return _error_result("cancelled", "This phone task was cancelled; no next action was started.", is_error=True)
            except PhoneNotStarted as exc:
                return _error_result("not_started", str(exc), is_error=True)
            except Exception as exc:
                self.lock.release_after_operation()
                return _error_result("error", _exception_message(exc), is_error=True)

    async def _wait_or_cancel(self, seconds: float) -> None:
        until = asyncio.get_running_loop().time() + seconds
        while True:
            if self.lock.is_cancelled():
                raise PhoneCancelled("Phone task was cancelled.")
            remaining = until - asyncio.get_running_loop().time()
            if remaining <= 0:
                return
            await asyncio.sleep(min(0.05, remaining))

    async def phone_tap(self, x: float, y: float, include_tree: bool = False) -> CallToolResult:
        """Tap a 0–999 grid point (upper-left is 0,0); values above 999 are pixels."""
        return await self._action("tap", lambda serial: self.adb.tap(serial, x, y), include_tree)

    async def phone_double_tap(self, x: float, y: float, include_tree: bool = False) -> CallToolResult:
        """Double-tap a 0–999 grid point (upper-left is 0,0); values above 999 are pixels."""
        return await self._action("double_tap", lambda serial: self.adb.double_tap(serial, x, y), include_tree)

    async def phone_long_press(self, x: float, y: float, ms: int = 800, include_tree: bool = False) -> CallToolResult:
        """Long-press a 0–999 grid point (upper-left is 0,0), for ms milliseconds."""
        if ms <= 0 or ms > 30_000:
            return _error_result("invalid_argument", "ms must be between 1 and 30000.", is_error=True)
        return await self._action("long_press", lambda serial: self.adb.long_press(serial, x, y, ms), include_tree)

    async def phone_swipe(
        self, x1: float, y1: float, x2: float, y2: float, ms: int = 300, include_tree: bool = False
    ) -> CallToolResult:
        """Swipe between 0–999 grid points (upper-left is 0,0); values above 999 are pixels."""
        if ms <= 0 or ms > 30_000:
            return _error_result("invalid_argument", "ms must be between 1 and 30000.", is_error=True)
        return await self._action("swipe", lambda serial: self.adb.swipe(serial, x1, y1, x2, y2, ms), include_tree)

    async def phone_type(self, text: str, include_tree: bool = False) -> CallToolResult:
        """Enter text into the focused field using ADB Keyboard, then restore the prior keyboard."""
        return await self._action("type", lambda serial: self.adb.type_text(serial, text), include_tree)

    async def phone_clear_text(self, include_tree: bool = False) -> CallToolResult:
        """Clear text in the currently focused field; requires an active lock."""
        return await self._action("clear_text", self.adb.clear_text, include_tree)

    async def phone_back(self, include_tree: bool = False) -> CallToolResult:
        """Press Android Back; requires an active lock."""
        return await self._action("back", self.adb.back, include_tree)

    async def phone_home(self, include_tree: bool = False) -> CallToolResult:
        """Press Android Home; requires an active lock."""
        return await self._action("home", self.adb.home, include_tree)

    async def phone_launch(self, app: str, include_tree: bool = False) -> CallToolResult:
        """Launch an app by Chinese APP_PACKAGES name or Android package name."""
        return await self._action("launch", lambda serial: self.adb.launch_app(serial, app), include_tree)

    async def phone_wait(self, seconds: float, include_tree: bool = False) -> CallToolResult:
        """Wait up to 10 seconds for the screen to settle, then return a fresh screenshot."""
        if not 0 <= seconds <= 10:
            return _error_result("invalid_argument", "seconds must be between 0 and 10.", is_error=True)
        async with self._operation_gate:
            try:
                with self.lock.operation() as serial:
                    await self._wait_or_cancel(seconds)
                    await self._wait_or_cancel(self.settle_seconds)
                    screenshot, data = self._observe(serial, include_tree)
                    if self.lock.is_cancelled():
                        raise PhoneCancelled("Phone task was cancelled.")
                return self._observe_result(screenshot, data, {"action": "wait", "status": "ok"})
            except PhoneCancelled:
                return _error_result("cancelled", "This phone task was cancelled.", is_error=True)
            except PhoneNotStarted as exc:
                return _error_result("not_started", str(exc), is_error=True)
            except Exception as exc:
                self.lock.release_after_operation()
                return _error_result("error", _exception_message(exc), is_error=True)

    async def phone_end(self, summary: str) -> CallToolResult:
        """Save a final screenshot beneath ~/.opa/phone/evidence and release device ownership."""
        async with self._operation_gate:
            try:
                with self.lock.operation() as serial:
                    screenshot = self.adb.screenshot(serial)
                    if self.lock.is_cancelled():
                        raise PhoneCancelled("Phone task was cancelled.")
                    evidence_dir = self.home / "phone" / "evidence"
                    evidence_dir.mkdir(parents=True, exist_ok=True)
                    stamp = datetime.now().astimezone().strftime("%Y%m%dT%H%M%S.%f%z")
                    path = evidence_dir / f"{stamp}.jpg"
                    path.write_bytes(base64.b64decode(screenshot["data"]))
                    payload = {
                        "status": "ended",
                        "summary": summary,
                        "screenshot": str(path),
                        "evidence": str(path),
                    }
                self.lock.release()
                return CallToolResult(content=[_json_text(payload)])
            except PhoneCancelled:
                self.lock.release()
                return _error_result("cancelled", "This phone task was cancelled; device ownership was released.", is_error=True)
            except PhoneNotStarted as exc:
                return _error_result("not_started", str(exc), is_error=True)
            except Exception as exc:
                self.lock.release_after_operation()
                self.lock.release()
                return _error_result("error", _exception_message(exc), is_error=True)

    async def phone_devices(self) -> CallToolResult:
        """List ADB devices without acquiring or touching a phone."""
        try:
            devices = self.adb.list_devices()
            payload = {
                "status": "ok",
                "devices": [
                    {"serial": device.serial, "state": device.state, "details": device.details}
                    for device in devices
                ],
            }
            if not devices:
                payload["message"] = "No Android device is connected. Connect one and authorize USB debugging."
        except Exception as exc:
            payload = {"status": "unavailable", "devices": [], "message": _exception_message(exc)}
        return CallToolResult(content=[_json_text(payload)])

    async def phone_cancel(self, only_owned: bool = False) -> CallToolResult:
        """Write the shared cancellation marker; the active process releases when no ADB call is running."""
        if self.lock.write_cancel_marker(only_owned=only_owned):
            return CallToolResult(content=[_json_text({"status": "cancel_requested", "serial": self.lock.serial})])
        return CallToolResult(content=[_json_text({"status": "idle", "message": "No active phone lock was found."})])

    def close(self) -> None:
        self.lock.release()


def create_server(service: PhoneService | None = None) -> MCPServer:
    """Register the stable Orbit tool names and descriptions on the mcp 2.3 MCPServer."""
    phone = service or PhoneService()
    server = MCPServer(name="orbit_phone", title="Orbit Phone", version="0.1.0")
    server.add_tool(
        phone.phone_begin,
        description="Acquire the shared Android device lock and return status plus the first screenshot. Call before any observe or action; task is a short human-readable task description.",
    )
    server.add_tool(
        phone.phone_observe,
        description="Observe the active Android device and return an MCP image plus JSON foreground/screen status. Requires phone_begin. include_tree optionally adds a bounded, redacted UI hierarchy.",
        annotations=ToolAnnotations(read_only_hint=True),
    )
    server.add_tool(
        phone.phone_tap,
        description="Tap one Android screen point. Coordinates use a 0–999 grid with the upper-left at 0,0; values above 999 are treated as physical pixels. Requires phone_begin and returns a fresh screenshot. Optional include_tree=true also returns the bounded, redacted ui_tree.",
    )
    server.add_tool(
        phone.phone_double_tap,
        description="Double-tap one Android screen point. Coordinates use a 0–999 grid with the upper-left at 0,0; values above 999 are physical pixels. Requires phone_begin and returns a fresh screenshot. Optional include_tree=true also returns the bounded, redacted ui_tree.",
    )
    server.add_tool(
        phone.phone_long_press,
        description="Long-press one Android screen point for ms milliseconds. Coordinates use a 0–999 grid with the upper-left at 0,0; values above 999 are physical pixels. Requires phone_begin and returns a fresh screenshot. Optional include_tree=true also returns the bounded, redacted ui_tree.",
    )
    server.add_tool(
        phone.phone_swipe,
        description="Swipe between two Android screen points for ms milliseconds. Coordinates use a 0–999 grid with the upper-left at 0,0; values above 999 are physical pixels. Requires phone_begin and returns a fresh screenshot. Optional include_tree=true also returns the bounded, redacted ui_tree.",
    )
    server.add_tool(
        phone.phone_type,
        description="Type text into the focused Android field with ADB Keyboard, restoring the previous keyboard afterward. Requires phone_begin; input text is not logged or echoed. Returns a fresh screenshot. Optional include_tree=true also returns the bounded, redacted ui_tree.",
    )
    server.add_tool(
        phone.phone_clear_text,
        description="Clear the currently focused Android text field. Requires phone_begin and returns a fresh screenshot. Optional include_tree=true also returns the bounded, redacted ui_tree.",
    )
    server.add_tool(
        phone.phone_back,
        description="Press Android Back. Requires phone_begin and returns a fresh screenshot. Optional include_tree=true also returns the bounded, redacted ui_tree.",
    )
    server.add_tool(
        phone.phone_home,
        description="Press Android Home. Requires phone_begin and returns a fresh screenshot. Optional include_tree=true also returns the bounded, redacted ui_tree.",
    )
    server.add_tool(
        phone.phone_launch,
        description="Launch an Android app using a Chinese name from phone_agent.config.apps.APP_PACKAGES or a package name. Requires phone_begin and returns a fresh screenshot. Optional include_tree=true also returns the bounded, redacted ui_tree.",
    )
    server.add_tool(
        phone.phone_wait,
        description="Wait up to 10 seconds for an Android screen transition, then return a fresh screenshot. Requires phone_begin; seconds must be between 0 and 10. Optional include_tree=true also returns the bounded, redacted ui_tree.",
        annotations=ToolAnnotations(read_only_hint=True),
    )
    server.add_tool(phone.phone_end, description="Save a final screenshot under ~/.opa/phone/evidence, then release the device lock. Requires phone_begin; summary is the task outcome.")
    server.add_tool(
        phone.phone_devices,
        description="List connected ADB devices without acquiring or touching one.",
        annotations=ToolAnnotations(read_only_hint=True),
    )
    server.add_tool(
        phone.phone_cancel,
        description="Request cancellation of the active phone task using the shared atomic cancel marker. only_owned=true cancels only a task this process currently owns; the in-flight ADB action completes before device ownership is released.",
        annotations=ToolAnnotations(read_only_hint=True),
    )
    return server


SERVICE = PhoneService()
SERVER = create_server(SERVICE)


async def _serve_stdio(wire_file: Any) -> None:
    """Run MCP on a duplicated wire fd while fd 1 is reserved for diagnostics."""
    wire_stdout = anyio.wrap_file(wire_file)
    try:
        async with stdio_server(stdout=wire_stdout) as (read_stream, write_stream):
            await SERVER._lowlevel_server.run(
                read_stream,
                write_stream,
                SERVER._lowlevel_server.create_initialization_options(),
            )
    finally:
        await wire_stdout.aclose()


def main() -> None:
    # mcp 2.3's stdio_server only diverts fd 1 when sys.stdout is backed by that fd.
    # Some MCP host launchers wrap stdout, so explicitly keep a duplicate for the
    # wire and route fd 1 to stderr before any tool can call upstream code that prints.
    atexit.register(SERVICE.close)

    def terminate(signum: int, _frame: Any) -> None:
        SERVICE.close()
        raise SystemExit(128 + signum)

    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, terminate)

    original_stdout = sys.stdout
    original_stdout.flush()
    restore_fd = os.dup(1)
    wire_fd = os.dup(1)
    wire_file = os.fdopen(wire_fd, "w", encoding="utf-8", buffering=1)
    try:
        # Some launchers replace sys.stdout with a wrapper that is not fd 1;
        # redirect that Python stream as well as raw writes to fd 1.
        sys.stdout = sys.stderr
        os.dup2(2, 1)
        anyio.run(_serve_stdio, wire_file)
    finally:
        wire_file.close()
        os.dup2(restore_fd, 1)
        os.close(restore_fd)
        sys.stdout = original_stdout


if __name__ == "__main__":
    main()

