"""Safe, offline-testable ADB primitives for the Orbit phone server."""

from __future__ import annotations

import base64
import math
import os
import re
import subprocess
from dataclasses import dataclass
from io import BytesIO
from typing import Any
from xml.etree import ElementTree

from PIL import Image
from phone_agent import adb as phone_adb
from phone_agent.config.apps import APP_PACKAGES

DEFAULT_SERIAL = "e7fe2f2a"
ADB_KEYBOARD_PACKAGE = "com.android.adbkeyboard"
_COMPONENT_RE = r"(?P<package>[A-Za-z_][\w.]*)/(?P<activity>\.?[A-Za-z_][\w.$]*)"
_TOP_RESUMED_RE = re.compile(rf"topResumedActivity=ActivityRecord\{{[^\n]*?\s{_COMPONENT_RE}")
_RESUMED_RE = re.compile(rf"mResumedActivity:\s*ActivityRecord\{{[^\n]*?\s{_COMPONENT_RE}")
_BOUNDS_RE = re.compile(r"\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]")
_SENSITIVE_WORDS = re.compile(r"(?i)(password|passcode|验证码|支付密码|银行卡密码)")
_EDITABLE_CLASSES = ("EditText", "AutoCompleteTextView")
_SIZE_RE = re.compile(r"(?:Physical|Override) size:\s*(\d+)x(\d+)")


class AdbError(RuntimeError):
    """An actionable ADB or device error without sensitive input text."""


@dataclass(frozen=True)
class Device:
    serial: str
    state: str
    details: dict[str, str]


def _serial_from_env() -> str:
    return os.environ.get("OPA_PHONE_SERIAL", DEFAULT_SERIAL).strip() or DEFAULT_SERIAL


def _adb_prefix(serial: str | None = None) -> list[str]:
    return ["adb", "-s", serial] if serial else ["adb"]


def _run_adb(
    serial: str | None,
    *args: str,
    timeout: float = 10,
    text: bool = True,
    allow_failure: bool = False,
) -> subprocess.CompletedProcess[Any]:
    """Run ADB only as an argv vector; never assemble shell command strings."""
    command = _adb_prefix(serial) + list(args)
    try:
        result = subprocess.run(command, capture_output=True, text=text, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise AdbError(f"ADB command failed ({args[0] if args else 'adb'}): {type(exc).__name__}") from None
    if result.returncode != 0 and not allow_failure:
        detail = result.stderr if text else result.stderr.decode("utf-8", "replace")
        detail = (detail or "").strip()
        raise AdbError(f"ADB command failed ({args[0] if args else 'adb'}): {detail or f'exit {result.returncode}'}")
    return result


def list_devices() -> list[Device]:
    """Parse ``adb devices -l`` through phone-agent's verified argv-based API."""
    return [
        Device(
            device.device_id,
            device.status,
            {
                **({"model": device.model} if device.model else {}),
                **({"android_version": device.android_version} if device.android_version else {}),
                "connection_type": device.connection_type.value,
            },
        )
        for device in phone_adb.list_devices()
    ]


def pick_serial() -> str:
    """Choose the configured device, or the sole connected device when unconfigured."""
    devices = list_devices()
    ready = [device.serial for device in devices if device.state == "device"]
    configured = os.environ.get("OPA_PHONE_SERIAL", "").strip()
    explicit = bool(configured)
    wanted = configured or DEFAULT_SERIAL
    if wanted in ready:
        return wanted
    if explicit:
        raise AdbError(f"Configured device {wanted!r} is not connected and ready; adb devices reports {ready or 'no ready devices'}.")
    if len(ready) == 1:
        return ready[0]
    if not ready:
        raise AdbError(f"No Android device is ready; expected {DEFAULT_SERIAL!r} or one connected device.")
    raise AdbError(f"Multiple Android devices are ready; set OPA_PHONE_SERIAL. Ready devices: {', '.join(ready)}")


def parse_foreground_activity(dump: str) -> tuple[str, str] | None:
    """Return Android's resumed package/activity, preferring topResumedActivity."""
    for pattern in (_TOP_RESUMED_RE, _RESUMED_RE):
        match = pattern.search(dump)
        if match:
            return match.group("package"), match.group("activity")
    return None


def _size_from_dump(dump: str) -> tuple[int, int] | None:
    matches = list(_SIZE_RE.finditer(dump))
    if not matches:
        return None
    match = matches[-1]
    return int(match.group(1)), int(match.group(2))


def status(serial: str) -> dict[str, Any]:
    """Inspect screen, lock state, foreground activity, keyboard, and resolution."""
    power = _run_adb(serial, "shell", "dumpsys", "power").stdout
    window = _run_adb(serial, "shell", "dumpsys", "window", "policy").stdout
    activity = _run_adb(serial, "shell", "dumpsys", "activity", "activities").stdout
    size_output = _run_adb(serial, "shell", "wm", "size").stdout
    keyboard_output = _run_adb(serial, "shell", "pm", "list", "packages", ADB_KEYBOARD_PACKAGE).stdout

    size = _size_from_dump(size_output)
    if size is None:
        raise AdbError("Could not determine Android screen dimensions from `wm size`.")
    resumed = parse_foreground_activity(activity)
    wake_match = re.search(r"mWakefulness=(\w+)", power)
    screen_match = re.search(r"Display Power: state=(ON|OFF)", power)
    screen_on: bool | None = None
    if wake_match:
        screen_on = wake_match.group(1).casefold() == "awake"
    elif screen_match:
        screen_on = screen_match.group(1) == "ON"
    lock_match = re.search(r"(?:mShowingLockscreen|mKeyguardShowing|showing)=(true|false)", window, re.IGNORECASE)
    locked = lock_match.group(1).casefold() == "true" if lock_match else None
    return {
        "serial": serial,
        "screen_on": screen_on,
        "locked": locked,
        "foreground": {"package": resumed[0], "activity": resumed[1]} if resumed else None,
        "adb_keyboard_installed": f"package:{ADB_KEYBOARD_PACKAGE}" in keyboard_output,
        "screen": {"width": size[0], "height": size[1]},
    }


def screenshot(serial: str) -> dict[str, Any]:
    """Capture a screen as bounded JPEG while retaining its physical dimensions."""
    result = _run_adb(serial, "exec-out", "screencap", "-p", timeout=15, text=False, allow_failure=True)
    raw = result.stdout
    diagnostics = raw + (result.stderr or b"")
    lowered = diagnostics.lower()
    is_sensitive = b"status: -1" in lowered or b"failed" in lowered
    if not raw and not is_sensitive:
        raise AdbError("ADB returned an empty screenshot.")
    try:
        if is_sensitive:
            dimensions = status(serial)["screen"]
            image = Image.new("RGB", (dimensions["width"], dimensions["height"]), color="black")
            original_size = image.size
        elif result.returncode != 0:
            detail = (result.stderr or b"").decode("utf-8", "replace").strip()
            raise AdbError(f"ADB screenshot command failed: {detail or f'exit {result.returncode}'}")
        else:
            with Image.open(BytesIO(raw)) as captured:
                image = captured.convert("RGB")
                original_size = captured.size
    except AdbError:
        raise
    except Exception as exc:
        raise AdbError(f"Could not decode device screenshot ({type(exc).__name__}).") from None

    image.thumbnail((1280, 1280))
    buffer = BytesIO()
    image.save(buffer, format="JPEG", quality=80, optimize=True)
    return {
        "data": base64.b64encode(buffer.getvalue()).decode("ascii"),
        "width": original_size[0],
        "height": original_size[1],
        "is_sensitive": is_sensitive,
    }


def _to_grid(value: float, size: int) -> int:
    if size <= 0:
        return 0
    return min(999, max(0, int(round(value / size * 1000))))


def to_device_point(x: float, y: float, width: int, height: int) -> tuple[int, int]:
    """Convert 0–999 model coordinates, or pixel coordinates above 999, to device pixels."""
    if width <= 0 or height <= 0:
        raise ValueError("screen dimensions must be positive")
    if not math.isfinite(float(x)) or not math.isfinite(float(y)):
        raise ValueError("coordinates must be finite numbers")
    if x > 999 or y > 999:
        px = min(max(int(round(x)), 0), width - 1)
        py = min(max(int(round(y)), 0), height - 1)
        return px, py
    grid_x = min(999, max(0, x))
    grid_y = min(999, max(0, y))
    return int(grid_x / 1000 * width), int(grid_y / 1000 * height)


def _redacted_node(element: ElementTree.Element, width: int, height: int) -> dict[str, Any] | None:
    attrs = element.attrib
    class_name = attrs.get("class", "")
    resource_id = attrs.get("resource-id", "")
    text = attrs.get("text", "")
    content_desc = attrs.get("content-desc", "")
    password = attrs.get("password", "false").casefold() == "true" or bool(
        _SENSITIVE_WORDS.search(" ".join((class_name, resource_id, text, content_desc)))
    )
    editable = (
        password
        or attrs.get("editable", "false").casefold() == "true"
        or class_name.endswith(_EDITABLE_CLASSES)
    )
    if editable:
        text = "[REDACTED]" if text else ""
        content_desc = "[REDACTED]" if content_desc else ""
    clickable = attrs.get("clickable", "false").casefold() == "true"
    if not clickable and not text and not content_desc:
        return None
    node: dict[str, Any] = {
        "text": text,
        "content_desc": content_desc,
        "resource_id": resource_id,
        "class": class_name,
        "clickable": clickable,
        "editable": editable,
        "password": password,
    }
    bounds = _BOUNDS_RE.fullmatch(attrs.get("bounds", ""))
    if bounds:
        x1, y1, x2, y2 = (int(value) for value in bounds.groups())
        center_x, center_y = (x1 + x2) / 2, (y1 + y2) / 2
        node["center"] = {"x": _to_grid(center_x, width), "y": _to_grid(center_y, height)}
    return node


def ui_tree(serial: str, max_nodes: int = 120) -> list[dict[str, Any]]:
    """Return a bounded list of visible/clickable nodes, redacting every editable value."""
    try:
        status_info = status(serial)
        width, height = status_info["screen"]["width"], status_info["screen"]["height"]
        _run_adb(serial, "shell", "uiautomator", "dump", "/sdcard/window.xml", timeout=15)
        xml = _run_adb(serial, "exec-out", "cat", "/sdcard/window.xml", timeout=10, text=False).stdout
        root = ElementTree.fromstring(xml)
    except (AdbError, ElementTree.ParseError, OSError, ValueError):
        return []
    if max_nodes <= 0:
        return []
    nodes: list[dict[str, Any]] = []
    for element in root.iter():
        node = _redacted_node(element, width, height)
        if node is not None:
            nodes.append(node)
            if len(nodes) >= max_nodes:
                break
    return nodes


def _device_point(serial: str, x: float, y: float) -> tuple[int, int]:
    dimensions = status(serial)["screen"]
    return to_device_point(x, y, dimensions["width"], dimensions["height"])


def tap(serial: str, x: float, y: float) -> None:
    px, py = _device_point(serial, x, y)
    phone_adb.tap(px, py, device_id=serial, delay=0)


def double_tap(serial: str, x: float, y: float) -> None:
    px, py = _device_point(serial, x, y)
    phone_adb.double_tap(px, py, device_id=serial, delay=0)


def long_press(serial: str, x: float, y: float, ms: int = 800) -> None:
    px, py = _device_point(serial, x, y)
    phone_adb.long_press(px, py, duration_ms=ms, device_id=serial, delay=0)


def swipe(serial: str, x1: float, y1: float, x2: float, y2: float, ms: int = 300) -> None:
    start_x, start_y = _device_point(serial, x1, y1)
    end_x, end_y = _device_point(serial, x2, y2)
    phone_adb.swipe(start_x, start_y, end_x, end_y, duration_ms=ms, device_id=serial, delay=0)


def type_text(serial: str, text: str) -> None:
    """Type through ADB Keyboard and restore the previously active IME."""
    original_ime = phone_adb.detect_and_set_adb_keyboard(device_id=serial)
    if not original_ime.strip():
        raise AdbError("Android did not report the current input method; text was not entered.")
    try:
        phone_adb.type_text(text, device_id=serial)
    finally:
        phone_adb.restore_keyboard(original_ime, device_id=serial)


def clear_text(serial: str) -> None:
    phone_adb.clear_text(device_id=serial)


def back(serial: str) -> None:
    phone_adb.back(device_id=serial, delay=0)


def home(serial: str) -> None:
    phone_adb.home(device_id=serial, delay=0)


def launch_app(serial: str, app: str) -> None:
    """Launch a known Chinese app name or a package name without shell-string parsing."""
    package = APP_PACKAGES.get(app)
    if package:
        launched = phone_adb.launch_app(app, device_id=serial, delay=0)
        if not launched:
            raise AdbError(f"Could not launch app {app!r}.")
        return
    package = app
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+", package):
        raise AdbError(f"Unknown app or package name: {app!r}")
    result = _run_adb(
        serial,
        "shell",
        "monkey",
        "-p",
        package,
        "-c",
        "android.intent.category.LAUNCHER",
        "1",
    )
    if result.stdout is None:
        raise AdbError(f"Could not launch package {package!r}.")

