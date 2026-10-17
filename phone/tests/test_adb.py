from __future__ import annotations

import base64
import json
import subprocess
from io import BytesIO

import pytest
from PIL import Image

from orbit_phone import adb


def test_coordinate_grid_and_pixel_boundaries() -> None:
    assert adb.to_device_point(0, 0, 1440, 3200) == (0, 0)
    assert adb.to_device_point(999, 999, 1440, 3200) == (1438, 3196)
    assert adb.to_device_point(1000, 1200, 1440, 3200) == (1000, 1200)
    assert adb.to_device_point(2000, -5, 1440, 3200) == (1439, 0)
    assert adb.to_device_point(-20, -1, 1440, 3200) == (0, 0)
    with pytest.raises(ValueError):
        adb.to_device_point(1, 2, 0, 3200)
    with pytest.raises(ValueError):
        adb.to_device_point(float("nan"), 2, 1440, 3200)


def test_android_17_foreground_parser_prefers_top_resumed_activity() -> None:
    dump = """
    topResumedActivity=ActivityRecord{111 u0 com.sankuai.meituan/com.meituan.android.pt.homepage.activity.MainActivity t19}
    ACTIVITY com.bfr.app/com.box.app.MainLauncherDefault t2 pid=1
    mResumedActivity: ActivityRecord{222 u0 com.bfr.app/com.box.app.MainLauncherDefault t2}
    """
    assert adb.parse_foreground_activity(dump) == (
        "com.sankuai.meituan",
        "com.meituan.android.pt.homepage.activity.MainActivity",
    )
    assert adb.parse_foreground_activity(
        "topResumedActivity=ActivityRecord{157 u0 com.google.android.apps.nexuslauncher/.NexusLauncherActivity t2}"
    ) == ("com.google.android.apps.nexuslauncher", ".NexusLauncherActivity")
    assert adb.parse_foreground_activity(
        "mResumedActivity: ActivityRecord{222 u0 com.xingin.xhs/com.xingin.xhs.index.v2.IndexActivityV2 t3}"
    ) == ("com.xingin.xhs", "com.xingin.xhs.index.v2.IndexActivityV2")
    assert adb.parse_foreground_activity("no activity records") is None


def test_list_devices_uses_argv_and_parses_details(monkeypatch: pytest.MonkeyPatch) -> None:
    seen: list[list[str]] = []

    def fake_run(args, **kwargs):
        seen.append(args)
        return subprocess.CompletedProcess(args, 0, "List of devices attached\ne7fe2f2a device product:device model:23116PN5BC\n", "")

    monkeypatch.setattr(adb.subprocess, "run", fake_run)
    devices = adb.list_devices()
    assert seen == [["adb", "devices", "-l"]]
    assert devices == [adb.Device("e7fe2f2a", "device", {"model": "23116PN5BC", "connection_type": "usb"})]


def test_pick_serial_prefers_configured_then_unique_device(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(adb, "list_devices", lambda: [adb.Device("e7fe2f2a", "device", {})])
    monkeypatch.delenv("OPA_PHONE_SERIAL", raising=False)
    assert adb.pick_serial() == "e7fe2f2a"

    monkeypatch.setattr(adb, "list_devices", lambda: [adb.Device("usb-1", "device", {})])
    assert adb.pick_serial() == "usb-1"

    monkeypatch.setenv("OPA_PHONE_SERIAL", "missing")
    with pytest.raises(adb.AdbError, match="not connected"):
        adb.pick_serial()


def test_status_reads_android_17_and_screen_state_with_argv(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[list[str]] = []
    outputs = iter(
        [
            "mWakefulness=Awake\n",
            "mShowingLockscreen=false\n",
            "topResumedActivity=ActivityRecord{111 u0 com.sankuai.meituan/com.meituan.Main t19}\n",
            "Physical size: 1440x3200\n",
            "package:com.android.adbkeyboard\n",
        ]
    )

    def fake_run(args, **kwargs):
        calls.append(args)
        return subprocess.CompletedProcess(args, 0, next(outputs), "")

    monkeypatch.setattr(adb.subprocess, "run", fake_run)
    assert adb.status("e7fe2f2a") == {
        "serial": "e7fe2f2a",
        "screen_on": True,
        "locked": False,
        "foreground": {"package": "com.sankuai.meituan", "activity": "com.meituan.Main"},
        "adb_keyboard_installed": True,
        "screen": {"width": 1440, "height": 3200},
    }
    assert all(isinstance(args, list) and args[:2] == ["adb", "-s"] for args in calls)
    assert calls[2][-2:] == ["activity", "activities"]


def test_screenshot_is_jpeg_and_keeps_original_dimensions(monkeypatch: pytest.MonkeyPatch) -> None:
    image = Image.new("RGB", (1440, 3200), color=(12, 40, 80))
    buffer = BytesIO()
    image.save(buffer, format="PNG")
    payload = buffer.getvalue()
    seen: list[list[str]] = []

    def fake_run(args, **kwargs):
        seen.append(args)
        return subprocess.CompletedProcess(args, 0, payload, b"")

    monkeypatch.setattr(adb.subprocess, "run", fake_run)
    shot = adb.screenshot("e7fe2f2a")
    decoded = base64.b64decode(shot["data"])
    with Image.open(BytesIO(decoded)) as jpeg:
        assert jpeg.format == "JPEG"
        assert max(jpeg.size) <= 1280
    assert shot["width"] == 1440 and shot["height"] == 3200
    assert shot["is_sensitive"] is False
    assert seen == [["adb", "-s", "e7fe2f2a", "exec-out", "screencap", "-p"]]


def test_sensitive_screenshot_failure_is_reported_as_black_jpeg(monkeypatch: pytest.MonkeyPatch) -> None:
    def fake_run(args, **kwargs):
        return subprocess.CompletedProcess(args, 1, b"Status: -1", b"Failed to capture secure window")

    monkeypatch.setattr(adb.subprocess, "run", fake_run)
    monkeypatch.setattr(adb, "status", lambda _serial: {"screen": {"width": 80, "height": 120}})
    shot = adb.screenshot("e7fe2f2a")
    assert shot["is_sensitive"] is True
    assert (shot["width"], shot["height"]) == (80, 120)
    with Image.open(BytesIO(base64.b64decode(shot["data"]))) as jpeg:
        assert jpeg.format == "JPEG"
        assert jpeg.getpixel((0, 0)) == (0, 0, 0)


def test_launch_accepts_known_name_and_arbitrary_package_with_argv(monkeypatch: pytest.MonkeyPatch) -> None:
    upstream_calls: list[tuple] = []
    commands: list[list[str]] = []
    monkeypatch.setattr(adb.phone_adb, "launch_app", lambda *args, **kwargs: upstream_calls.append(args) or True)

    def fake_run(serial, *args, **kwargs):
        commands.append(["adb", "-s", serial, *args])
        return subprocess.CompletedProcess(args, 0, "", "")

    monkeypatch.setattr(adb, "_run_adb", fake_run)
    app_name = next(iter(adb.APP_PACKAGES))
    adb.launch_app("e7fe2f2a", app_name)
    adb.launch_app("e7fe2f2a", "com.example.onlyphone")
    assert upstream_calls == [(app_name,)]
    assert commands == [["adb", "-s", "e7fe2f2a", "shell", "monkey", "-p", "com.example.onlyphone", "-c", "android.intent.category.LAUNCHER", "1"]]
    with pytest.raises(adb.AdbError):
        adb.launch_app("e7fe2f2a", "not a package")


def test_ui_tree_redacts_input_and_password_content(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        adb,
        "status",
        lambda _serial: {"screen": {"width": 1000, "height": 2000}},
    )
    xml = b'''<hierarchy>
      <node text="alice@example.com" content-desc="Email" class="android.widget.EditText" editable="true" bounds="[0,0][100,100]" />
      <node text="984621" content-desc="payment password" class="android.widget.EditText" password="true" clickable="true" bounds="[100,100][300,200]" />
      <node text="Continue" class="android.widget.Button" clickable="true" bounds="[400,300][600,500]" />
      <node text="hidden label" clickable="false" />
    </hierarchy>'''
    outputs = iter([None, xml])

    def fake_run(_serial, *args, **kwargs):
        stdout = next(outputs)
        if args[:3] == ("shell", "uiautomator", "dump"):
            return subprocess.CompletedProcess(args, 0, "dumped", "")
        return subprocess.CompletedProcess(args, 0, stdout, b"")

    monkeypatch.setattr(adb, "_run_adb", fake_run)
    nodes = adb.ui_tree("e7fe2f2a")
    encoded = json.dumps(nodes)
    assert "alice@example.com" not in encoded
    assert "984621" not in encoded
    assert "[REDACTED]" in encoded
    assert len(nodes) == 4
    assert nodes[0]["center"] == {"x": 50, "y": 25}
    assert nodes[1]["password"] is True

