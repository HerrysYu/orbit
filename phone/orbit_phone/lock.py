"""Cross-process device ownership and atomic cancellation markers."""

from __future__ import annotations

import fcntl
import json
import os
import re
import threading
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator

DEFAULT_SERIAL = "e7fe2f2a"
_SERIAL_SAFE = re.compile(r"[^A-Za-z0-9_.:-]")


class PhoneNotStarted(RuntimeError):
    """Raised when a device operation is requested without an active lock."""


class PhoneCancelled(RuntimeError):
    """Raised when the current phone task has been cancelled."""


def safe_serial(serial: str) -> str:
    """Use the Host's filename rule for lock and cancel marker paths."""
    return _SERIAL_SAFE.sub("_", serial)


def opa_home() -> Path:
    configured = os.environ.get("OPA_HOME")
    return Path(configured).expanduser() if configured else Path.home() / ".opa"


class DeviceLock:
    """An advisory flock with a watcher for Host-written cancel files."""

    def __init__(self, serial: str = DEFAULT_SERIAL, home: Path | None = None, poll_seconds: float = 0.1):
        self.serial = serial
        self.safe_name = safe_serial(serial)
        self.home = (home or opa_home()).expanduser()
        self.directory = self.home / "phone"
        self.lock_path = self.directory / f"{self.safe_name}.lock"
        self.cancel_path = self.directory / f"{self.safe_name}.cancel"
        self.poll_seconds = poll_seconds
        self._fd: int | None = None
        self._mutex = threading.RLock()
        self._active_operations = 0
        self._cancelled = False
        self._release_pending = False
        self._watcher_stop = threading.Event()
        self._watcher: threading.Thread | None = None
        self._owner: dict[str, object] | None = None

    @property
    def held(self) -> bool:
        with self._mutex:
            return self._fd is not None

    @property
    def owner(self) -> dict[str, object] | None:
        with self._mutex:
            return dict(self._owner) if self._owner else None

    def acquire(self, task: str) -> tuple[bool, dict[str, object] | None]:
        """Acquire the device lock without blocking; return current owner when busy."""
        self.directory.mkdir(parents=True, exist_ok=True)
        with self._mutex:
            if self._fd is not None:
                return False, dict(self._owner or {"task": "already held by this process"})
            fd = os.open(self.lock_path, os.O_CREAT | os.O_RDWR, 0o600)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                os.close(fd)
                return False, self._read_owner()
            owner: dict[str, object] = {
                "pid": os.getpid(),
                "task": task,
                "started_at": datetime.now(timezone.utc).isoformat(),
            }
            payload = json.dumps(owner, ensure_ascii=False).encode("utf-8")
            os.ftruncate(fd, 0)
            os.lseek(fd, 0, os.SEEK_SET)
            os.write(fd, payload)
            os.fsync(fd)
            self._fd = fd
            self._owner = owner
            self._active_operations = 0
            self._cancelled = False
            self._release_pending = False
            # A marker left by an earlier task is stale once this process owns the
            # previously-free flock. Host cancellation during this task is observed
            # by the watcher and remains present until the next successful begin.
            self.cancel_path.unlink(missing_ok=True)
            self._watcher_stop = threading.Event()
            self._watcher = threading.Thread(target=self._watch_cancel, name=f"phone-cancel-{self.safe_name}", daemon=True)
            self._watcher.start()
            return True, owner

    def _read_owner(self) -> dict[str, object] | None:
        try:
            raw = self.lock_path.read_text(encoding="utf-8")
            data = json.loads(raw)
            return data if isinstance(data, dict) else {"task": raw[:500]}
        except (OSError, UnicodeError, json.JSONDecodeError):
            return {"task": "another process holds the device lock"}

    def is_locked_elsewhere(self) -> bool:
        """Check lock state without waiting; create the stable lock inode if needed."""
        if self.held:
            return True
        self.directory.mkdir(parents=True, exist_ok=True)
        fd = os.open(self.lock_path, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return True
            fcntl.flock(fd, fcntl.LOCK_UN)
            return False
        finally:
            os.close(fd)

    def write_cancel_marker(self, only_owned: bool = False) -> bool:
        """Atomically cancel a live owner, optionally restricting to our own flock."""
        with self._mutex:
            if only_owned and self._fd is None:
                return False
            if self._fd is None and not self.is_locked_elsewhere():
                return False
            self._write_cancel_marker_locked()
            if self._fd is not None:
                self._cancelled = True
                if self._active_operations == 0:
                    self._release_locked()
            return True

    def _write_cancel_marker_locked(self) -> None:
        self.directory.mkdir(parents=True, exist_ok=True)
        temp_path = self.directory / f".{self.safe_name}.{os.getpid()}.{threading.get_ident()}.cancel.tmp"
        try:
            fd = os.open(temp_path, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
            try:
                os.write(fd, b"cancel requested\n")
                os.fsync(fd)
            finally:
                os.close(fd)
            os.replace(temp_path, self.cancel_path)
        finally:
            temp_path.unlink(missing_ok=True)

    def _watch_cancel(self) -> None:
        while not self._watcher_stop.wait(self.poll_seconds):
            if self.cancel_path.exists():
                self._observe_cancel()
                return

    def _observe_cancel(self) -> None:
        with self._mutex:
            if self._fd is None:
                return
            self._cancelled = True
            if self._active_operations == 0:
                self._release_locked()

    def is_cancelled(self) -> bool:
        with self._mutex:
            if self.cancel_path.exists():
                self._cancelled = True
                if self._active_operations == 0:
                    self._release_locked()
            return self._cancelled

    @contextmanager
    def operation(self) -> Iterator[str]:
        """Keep ownership through an in-flight action and its automatic screenshot."""
        with self._mutex:
            if self.cancel_path.exists():
                self._cancelled = True
            if self._cancelled:
                if self._active_operations == 0:
                    self._release_locked()
                raise PhoneCancelled("Phone task was cancelled.")
            if self._fd is None:
                raise PhoneNotStarted("Call phone_begin(task) before observing or controlling the device.")
            self._active_operations += 1
            serial = self.serial
        try:
            yield serial
        finally:
            with self._mutex:
                self._active_operations = max(0, self._active_operations - 1)
                if self.cancel_path.exists():
                    self._cancelled = True
                if (self._cancelled or self._release_pending) and self._active_operations == 0:
                    self._release_locked()

    def release_after_operation(self) -> None:
        """Release now, or defer until all active ADB work has returned."""
        with self._mutex:
            self._release_pending = True
            if self._active_operations == 0:
                self._release_locked()

    def release(self) -> None:
        """Release device ownership, deferring while a subprocess action is active."""
        self.release_after_operation()
        watcher = self._watcher
        if watcher is not None and watcher is not threading.current_thread():
            watcher.join(timeout=max(0.2, self.poll_seconds * 3))

    def _release_locked(self) -> None:
        fd, self._fd = self._fd, None
        self._release_pending = False
        self._watcher_stop.set()
        if fd is not None:
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
            finally:
                os.close(fd)

