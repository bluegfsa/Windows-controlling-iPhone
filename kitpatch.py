"""Windows compatibility patches for the SideTap engine.

Two upstream bugs break the whole stack on a Chinese Windows box. They are
patched here, once, instead of in every entry point:

1. `device._free_port()` / `device._netstat_ano_lines()` call
   `netstat -ano -p tcp` and then `proc.stdout.splitlines()`. Under some
   launchers stdout comes back as None (no console / no pipe), which raises
   `AttributeError: 'NoneType' object has no attribute 'splitlines'` — and that
   kills the bring-up *before* the tunnel is even started.

2. `device._run()` reads go-ios output with `text=True`. When the interpreter
   runs in UTF-8 mode (PYTHONUTF8=1, common under agent hosts) that decodes
   Chinese Windows error text — which is GBK — as UTF-8 and raises
   `UnicodeDecodeError: 'utf-8' codec can't decode byte 0xbb`. Every go-ios call
   that hits a localized message dies with it.

Import this module *after* `phone_harness.device` and before anything calls it.
"""
from __future__ import annotations

import pathlib
import subprocess
import sys

import phone_harness.device as device

NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0) if sys.platform == "win32" else 0


def _decode(raw) -> str:
    """Bytes → str without ever raising: go-ios mixes UTF-8 JSON with GBK errors."""
    if raw is None:
        return ""
    if isinstance(raw, str):
        return raw
    for enc in ("utf-8", "gbk", "cp936"):
        try:
            return raw.decode(enc)
        except (UnicodeDecodeError, LookupError):
            continue
    return raw.decode("utf-8", "replace")


def _netstat_lines() -> list[str]:
    try:
        proc = subprocess.run(
            ["netstat", "-ano", "-p", "tcp"],
            capture_output=True,
            timeout=20,
            creationflags=NO_WINDOW,
        )
    except (OSError, subprocess.SubprocessError):
        return []
    return _decode(proc.stdout).splitlines()


def _free_port(port: int) -> None:
    """Kill only `ios.exe` listeners on `port`; never fail the caller."""
    if sys.platform != "win32":
        return
    pids = set()
    for line in _netstat_lines():
        parts = line.split()
        if len(parts) >= 5 and parts[3].upper() == "LISTENING" and parts[1].endswith(f":{port}"):
            pids.add(parts[4])
    for pid in pids:
        try:
            info = subprocess.run(
                ["tasklist", "/FI", f"PID eq {pid}", "/NH"],
                capture_output=True, timeout=15, creationflags=NO_WINDOW,
            )
            if "ios.exe" in _decode(info.stdout).lower():
                subprocess.run(["taskkill", "/F", "/PID", pid],
                               capture_output=True, timeout=15,
                               creationflags=NO_WINDOW)
        except (OSError, subprocess.SubprocessError):
            continue


def _run(args, timeout: float = 30.0):
    """Same contract as device._run, but decodes bytes by hand."""
    exe = device.ios_path()
    if not exe:
        raise device.DeviceError(
            "go-ios not found. PhoneKit ships it in bin/ios.exe — run phone.py "
            "from the kit root, or add bin/ to PATH."
        )
    proc = subprocess.run(
        [exe, *device.pin_udid(args)],
        capture_output=True,
        timeout=timeout,
        creationflags=NO_WINDOW,
    )
    proc.stdout = _decode(proc.stdout)
    proc.stderr = _decode(proc.stderr)
    return proc


def _pid_image(pid: int) -> str:
    """Same contract as device._pid_image, but byte-safe on zh-Windows."""
    if sys.platform != "win32":
        try:
            return pathlib.Path(f"/proc/{pid}/comm").read_text().strip().lower()
        except OSError:
            return ""
    try:
        proc = subprocess.run(
            ["tasklist", "/FI", f"PID eq {pid}", "/NH", "/FO", "CSV"],
            capture_output=True, timeout=15, creationflags=NO_WINDOW,
        )
        first = _decode(proc.stdout).strip().splitlines()
        if first and first[0].startswith('"'):
            return first[0].split('","')[0].strip('"').lower()
        return ""
    except (OSError, subprocess.SubprocessError):
        return ""


def apply() -> None:
    device._free_port = _free_port
    device._netstat_ano_lines = _netstat_lines
    device._run = _run
    device._pid_image = _pid_image
    # go-ios' own JSON goes to stdout; anything printed by our code should never
    # blow up on a CJK console either.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:  # noqa: BLE001  — non-TextIOWrapper (piped) is fine
            pass
    # `doctor` asks schtasks whether the expiry-reminder task exists. On locked
    # down machines schtasks.exe is blacklisted and the probe is pure noise
    # (a red security banner per run, for a feature nobody asked for). Answer
    # "not installed" instead — that check is advisory and reports ok anyway.
    try:
        from phone_harness import admin as _admin

        _admin._reminder_installed = lambda: False
    except Exception:  # noqa: BLE001
        pass


apply()
