from __future__ import annotations

import multiprocessing
import threading
import time
from pathlib import Path

import pytest

from orbit_phone.lock import DeviceLock, PhoneCancelled


def _cancel_from_process(home: str, serial: str, result_queue) -> None:
    result_queue.put(DeviceLock(serial, Path(home)).write_cancel_marker())


def test_lock_is_mutually_exclusive_between_threads(tmp_path: Path) -> None:
    first = DeviceLock("e7fe2f2a", tmp_path)
    second = DeviceLock("e7fe2f2a", tmp_path)
    assert first.acquire("first task")[0] is True
    result: list[tuple[bool, dict | None]] = []
    thread = threading.Thread(target=lambda: result.append(second.acquire("second task")))
    thread.start()
    thread.join(timeout=2)
    assert not thread.is_alive()
    assert result[0][0] is False
    assert result[0][1]["task"] == "first task"
    first.release()
    assert second.acquire("second task")[0] is True
    second.release()


def test_cross_process_cancel_releases_idle_lock(tmp_path: Path) -> None:
    first = DeviceLock("e7fe2f2a", tmp_path, poll_seconds=0.02)
    assert first.acquire("idle task")[0] is True
    context = multiprocessing.get_context("spawn")
    queue = context.Queue()
    process = context.Process(target=_cancel_from_process, args=(str(tmp_path), "e7fe2f2a", queue))
    process.start()
    process.join(timeout=5)
    assert process.exitcode == 0
    assert queue.get(timeout=1) is True

    deadline = time.monotonic() + 2
    while first.held and time.monotonic() < deadline:
        time.sleep(0.02)
    assert first.held is False
    with pytest.raises(PhoneCancelled):
        with first.operation():
            pytest.fail("cancelled lock must not start another operation")


def test_cancel_keeps_lock_until_in_flight_action_finishes(tmp_path: Path) -> None:
    first = DeviceLock("e7fe2f2a", tmp_path, poll_seconds=0.02)
    assert first.acquire("active task")[0] is True
    context = multiprocessing.get_context("spawn")
    queue = context.Queue()
    process = context.Process(target=_cancel_from_process, args=(str(tmp_path), "e7fe2f2a", queue))

    with first.operation():
        process.start()
        process.join(timeout=5)
        assert process.exitcode == 0
        assert queue.get(timeout=1) is True
        deadline = time.monotonic() + 2
        while not first.is_cancelled() and time.monotonic() < deadline:
            time.sleep(0.02)
        assert first.is_cancelled() is True
        assert first.held is True

    assert first.held is False


def test_host_lock_and_cancel_paths_use_safe_serial_names(tmp_path: Path) -> None:
    lock = DeviceLock("usb/serial?", tmp_path)
    assert lock.lock_path == tmp_path / "phone" / "usb_serial_.lock"
    assert lock.cancel_path == tmp_path / "phone" / "usb_serial_.cancel"

