#!/usr/bin/env python
"""PhoneKit — drive a real iPhone from the command line (WDA / WebDriverAgent).

One entry point. Every sub-command prints one JSON object to stdout, so an
agent (or a shell script) can parse it without screen-scraping.

    python phone.py status
    python phone.py open com.autonavi.amap
    python phone.py ocr
    python phone.py tap-text 开始导航
    python phone.py shot --path a.png
    python phone.py flow examples/amap_navigate.json

Design notes that matter for speed:
  * The link (tunnel + WDA + port forwards) is a DETACHED background service,
    started once. Commands never pay its ~15s bring-up again.
  * The WDA session is reused across processes (cached in .state/wda_session),
    so a command costs ~1-2s, not a new session each time.
  * `flow` runs many steps inside ONE process — that is the fast path.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "src"))
# Bundled go-ios lives in bin/ — put it first so `shutil.which("ios")` finds it
# without the human installing Node or touching PATH.
os.environ["PATH"] = str(ROOT / "bin") + os.pathsep + os.environ.get("PATH", "")

# SideTap's Windows bugs (netstat returning None, GBK decoded as UTF-8) are
# patched in kitpatch.py, which must land before anything touches the device.
import kitpatch  # noqa: E402,F401

from phone_harness import admin, config  # noqa: E402
from phone_harness import helpers as H  # noqa: E402

CONTROL = "http://127.0.0.1:8899"
ARTIFACTS = ROOT / "artifacts"
ARTIFACTS.mkdir(exist_ok=True)
_T0 = time.time()


# --------------------------------------------------------------------------- #
# plumbing
# --------------------------------------------------------------------------- #
class Fail(Exception):
    """A user-facing failure: printed as {"ok": false, "error": ...}."""

    def __init__(self, error: str, hint: str = "") -> None:
        super().__init__(error)
        self.error = error
        self.hint = hint


def out(payload: dict, code: int = 0) -> int:
    payload.setdefault("ok", code == 0)
    payload["ms"] = int((time.time() - _T0) * 1000)
    print(json.dumps(payload, ensure_ascii=False, indent=None))
    return code


def _http(path: str, method: str = "GET", timeout: float = 3.0) -> dict | None:
    import urllib.request

    req = urllib.request.Request(CONTROL + path, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode())
    except Exception:  # noqa: BLE001
        return None


def service_alive(timeout: float = 1.0) -> bool:
    return _http("/health", timeout=timeout) is not None


def wda_alive(timeout: float = 2.0) -> bool:
    import urllib.request

    try:
        with urllib.request.urlopen(config.WDA_URL + "/status", timeout=timeout) as r:
            return r.status == 200
    except Exception:  # noqa: BLE001
        return False


def _spawn_detached() -> bool:
    """Best-effort: start service.py so it outlives this process.

    A plain child dies with the console; DETACHED_PROCESS is the fix. Some
    sandboxes run their children inside a Windows job object with kill-on-close,
    where even a detached child is reaped — the health probe below is what
    tells the difference, so we never *assume* it worked.
    """
    log = ARTIFACTS / "service.log"
    flags = 0
    if sys.platform == "win32":
        flags = 0x00000008 | 0x00000200  # DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP
    try:
        with open(log, "ab") as fh:
            proc = subprocess.Popen(
                [sys.executable, str(ROOT / "service.py")],
                cwd=str(ROOT),
                stdin=subprocess.DEVNULL,
                stdout=fh,
                stderr=fh,
                creationflags=flags,
                close_fds=True,
            )
    except Exception:  # noqa: BLE001
        return False
    deadline = time.time() + 12
    while time.time() < deadline:
        if proc.poll() is not None:  # reaped by a job object — no point waiting
            return False
        if service_alive(0.4):
            return True
        time.sleep(0.3)
    return False


_SPAWN_TRIED = False
_USB_RECOVER_STATE = {"n": 0, "at": 0.0}


def _device_present() -> bool | None:
    """Is an iPhone enumerable over USB? None = could not tell.

    Checked BEFORE any bring-up so the common failure ("cable unplugged /
    phone locked") comes back in ~1s instead of after a 12s service probe.
    """
    exe = ROOT / "bin" / "ios.exe"
    try:
        p = subprocess.run([str(exe), "list"], capture_output=True, text=True,
                           timeout=12)
    except Exception:  # noqa: BLE001
        return None
    for line in p.stdout.splitlines():
        line = line.strip()
        if line.startswith('{"deviceList"'):
            try:
                return bool(json.loads(line)["deviceList"])
            except Exception:  # noqa: BLE001
                return None
    return None


def _clean_ghosts() -> int:
    """Remove leftover phantom 05AC nodes; they confuse Apple's filter driver.

    Each usbmuxd 'eject' leaves a new phantom behind (one evening produced
    11 of them). Only nodes that pnputil reports as disconnected are removed —
    the live interfaces carry the same instance shape and must survive.
    """
    run = lambda *cmd: subprocess.run(list(cmd), capture_output=True, timeout=60)
    n = 0
    try:
        p = subprocess.run(["pnputil", "/enum-devices"], capture_output=True,
                           timeout=60)
        txt = p.stdout.decode("utf-8", "replace")
        if "\ufffd" in txt:
            txt = p.stdout.decode("gbk", "replace")
        blocks, cur = [], []
        for line in txt.splitlines():
            s = line.strip()
            if s.startswith("USB\\") or (s and not line.startswith(" ")
                                        and not s.startswith(("类", "Class", "状态",
                                                              "Status", "实例", "Instance",
                                                              "设备", "Device", "发布", "Published",
                                                              "驱动", "Driver", "描述", "Description"))):
                if cur:
                    blocks.append(cur)
                cur = [s]
            elif cur:
                cur.append(s)
        if cur:
            blocks.append(cur)
        for b in blocks:
            inst = None
            connected = True
            for ln in b:
                m = re.match(r"(?:实例 ID|Instance ID)\s*:\s*(\S.*)$", ln)
                if m:
                    inst = m.group(1).strip()
                if re.search(r"(?:Disconnected|断开|未连接|phantom)", ln, re.I):
                    connected = False
            if inst and "VID_05AC" in inst.upper() and not connected \
                    and re.search(r"&\d+&", inst):
                run("pnputil", "/remove-device", inst)
                n += 1
    except Exception:  # noqa: BLE001
        pass
    return n


def recover_usb(quiet: bool = True) -> bool:
    """Rebuild the USB device stack when usbmuxd lost a phone that PnP still sees.

    Order matters and was found by trial: stop usbmuxd FIRST, or it keeps a
    handle on the old node and never notices the new one. Two full cycles:
    the first usually restores PnP, the second gets usbmuxd to notice it.
    """
    run = lambda *cmd: subprocess.run(list(cmd), capture_output=True, timeout=60)
    if not quiet:
        print(f"[kit] rebuilding USB stack, ghosts cleared: {_clean_ghosts()}",
              file=sys.stderr)
    for cycle in range(2):
        comp = _composite_instance()
        if not comp:
            # genuinely unplugged, or the node is a phantom — rescan may help
            run("pnputil", "/scan-devices")
            time.sleep(4)
            comp = _composite_instance()
            if not comp:
                return False  # nothing enumerable at all — cable issue
        svc = "Apple Mobile Device Service"
        if not quiet:
            print(f"[kit] cycle {cycle + 1}: rebuilding {comp}", file=sys.stderr)
        run("net", "stop", svc)
        run("pnputil", "/remove-device", comp)
        time.sleep(2)
        run("pnputil", "/scan-devices")
        time.sleep(6)
        run("net", "start", svc)
        time.sleep(6)
        # Apple's INF sets ResetPortEnabled=1: usbmuxd "ejects" the whole device
        # whenever it thinks it is wedged (event log id 225). With WDA-driving apps
        # that wedge often, this kills the link mid-flow — turn it off.
        _disable_port_reset()
        run("pnputil", "/disable-device", comp)
        time.sleep(2)
        run("pnputil", "/enable-device", comp)
        deadline = time.time() + 25
        while time.time() < deadline:
            if _device_present():
                return True
            time.sleep(1)
    return False


def _disable_port_reset() -> None:
    """Set ResetPortEnabled=0 on every usbmux interface we can find (best-effort)."""
    try:
        import winreg
    except ImportError:  # noqa: SIM105
        return
    base = (r"SYSTEM\CurrentControlSet\Enum\USB\VID_05AC&PID_12A8&MI_01")
    try:
        root = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, base)
    except OSError:
        return
    for i in range(winreg.QueryInfoKey(root)[0]):
        try:
            inst = winreg.EnumKey(root, i)
            with winreg.OpenKey(root, inst + r"\Device Parameters", 0,
                                winreg.KEY_SET_VALUE | winreg.KEY_QUERY_VALUE) as k:
                winreg.SetValueEx(k, "ResetPortEnabled", 0, winreg.REG_DWORD, 0)
        except OSError:
            continue


def _composite_instance() -> str | None:
    """Find the iPhone's composite device instance (the one without &MI_)."""
    try:
        p = subprocess.run(["pnputil", "/enum-devices", "/connected"],
                           capture_output=True, timeout=40)
    except Exception:  # noqa: BLE001
        return None
    # pnputil prints GBK on zh-Windows; decode leniently instead of crashing.
    txt = p.stdout.decode("utf-8", "replace")
    if "\ufffd" in txt:
        txt = p.stdout.decode("gbk", "replace")
    ids = []
    for line in txt.splitlines():
        line = line.strip()
        m = re.match(r"(?:实例 ID|Instance ID)\s*:\s*(\S.*)$", line)
        if m and "VID_05AC" in m.group(1).upper():
            inst = m.group(1).strip()
            if "&MI_" not in inst.upper():
                ids.append(inst)
    return ids[0] if ids else None


def ensure_link(quiet: bool = False, wait: float = 150.0) -> str:
    """Make sure the phone is drivable. Returns which path was taken.

    Cheap when warm (one HTTP GET, ~5ms). Self-healing when cold, in this order:
      service — an already-running service brings the link back
      spawn   — start the service detached (normal terminal / host)
      inline  — run the bring-up inside THIS process (sandboxed hosts kill
                detached children, so this is the one path that always works;
                the link then lives exactly as long as the command)
    """
    global _SPAWN_TRIED, _USB_RECOVERED
    if wda_alive():
        return "warm"

    present = _device_present()
    if present is False:
        # The Apple usbmux stack can lose the device while Windows still shows
        # it: PnP says OK, `ios list` says nothing. Happens repeatedly during
        # long flows, so recovery must be repeatable (cooldown-guarded), not
        # a once-per-process flag — that exact bug cost us a whole evening.
        cool = 45.0
        if (time.time() - _USB_RECOVER_STATE["at"] > cool
                and _USB_RECOVER_STATE["n"] < 8
                and os.environ.get("PHONEKIT_NO_USB_RECOVER") != "1"):
            _USB_RECOVER_STATE["n"] += 1
            _USB_RECOVER_STATE["at"] = time.time()
            if not quiet:
                print(f"[kit] usbmux lost the device (PnP still OK) — "
                      f"rebuilding the USB stack (try {_USB_RECOVER_STATE['n']})…",
                      file=sys.stderr)
            if recover_usb():
                present = _device_present()
        if present is False:
            raise Fail(
                "iPhone not visible over USB",
                "plug the cable, unlock the phone and tap 信任; also check "
                "`bin\\ios.exe list` by hand — if that is empty too, the USB "
                "filter driver is the next suspect (docs/04, 第 1 节)",
            )

    if service_alive():
        if not quiet:
            print("[kit] link down — asking the service to bring it up…",
                  file=sys.stderr)
        res = _http("/up", "POST", timeout=wait)
        if not res or not res.get("ok"):
            raise Fail(
                "the service could not bring the link up",
                "check the phone is on USB and unlocked; "
                f"log: {ARTIFACTS / 'service.log'}",
            )
        return _await_wda(wait, "service")

    if not _SPAWN_TRIED and os.environ.get("PHONEKIT_NO_SPAWN") != "1":
        _SPAWN_TRIED = True
        if not quiet:
            print("[kit] link down — starting the service…", file=sys.stderr)
        if _spawn_detached():
            return _await_wda(wait, "spawn")

    if not quiet:
        print("[kit] link down — bringing it up inside this process "
              "(detached services are not allowed here)", file=sys.stderr)
    rc = admin.up(wait_seconds=wait)
    if rc != 0:
        raise Fail(
            "cannot bring the link up (admin.up returned non-zero — see stderr)",
            "most common: the iPhone is not on USB / not trusted. Run "
            "`python phone.py doctor` for the exact check that failed.",
        )
    return _await_wda(wait, "inline")


def _await_wda(wait: float, how: str) -> str:
    deadline = time.time() + wait
    while time.time() < deadline:
        if wda_alive():
            return how
        time.sleep(0.5)
    raise Fail(
        "WDA never answered",
        f"via {how}; run `python phone.py doctor` — usually the phone is "
        "locked/asleep, or the signature needs re-signing (see docs/04)",
    )


def num(v) -> float:
    return float(v)


# --------------------------------------------------------------------------- #
# commands
# --------------------------------------------------------------------------- #
def cmd_status(_a) -> int:
    info = {"service": service_alive(), "wda": wda_alive()}
    if info["wda"]:
        try:
            info["app"] = H.current_app().get("bundleId")
            info["screen"] = H.screen_info()
        except Exception as exc:  # noqa: BLE001
            info["note"] = str(exc)
    return out(info)


def cmd_up(_a) -> int:
    ensure_link()
    return out({"wda": True, "url": config.WDA_URL})


def cmd_down(_a) -> int:
    admin.down()
    _http("/down", "POST", timeout=30)
    return out({"stopped": True})


def cmd_doctor(_a) -> int:
    rows = admin.doctor_results()
    bad = [r for r in rows if not r["ok"]]
    return out({"checks": rows, "failing": len(bad)}, 0 if not bad else 1)


_APP_INDEX: dict | None = None


def resolve_app(name: str) -> str:
    """中文名 → bundle id, from the shipped index.

    helpers.open_app() looks the name up by asking the phone for the whole app
    list (~1-2s) and fails outright on names it does not map. The static index
    makes the common case instant and the error message obvious.
    """
    global _APP_INDEX
    if "." in name:  # already a bundle id
        return name
    if _APP_INDEX is None:
        p = ROOT / "data" / "apps_index.json"
        try:
            _APP_INDEX = json.loads(p.read_text(encoding="utf-8"))["by_name"]
        except Exception:  # noqa: BLE001
            _APP_INDEX = {}
    bid = _APP_INDEX.get(name)
    if not bid:
        near = [k for k in _APP_INDEX if name in k or k in name]
        raise Fail(
            f"unknown app name {name!r}",
            f"try a bundle id, or one of: {', '.join(near[:8])}" if near
            else "run `phone.cmd apps` to list what is installed",
        )
    return bid


def cmd_open(a) -> int:
    ensure_link()
    bid = resolve_app(a.app)
    t = time.time()
    H.open_app(bid)
    if a.wait:
        H.wait_stable(a.wait)
    return out({"opened": a.app, "bundle": bid,
                "foreground": H.current_app().get("bundleId"),
                "act_ms": int((time.time() - t) * 1000)})


def cmd_apps(_a) -> int:
    ensure_link()
    apps = H.open_apps()
    return out({"count": len(apps), "apps": apps})


def cmd_app(_a) -> int:
    ensure_link()
    return out({"app": H.current_app()})


def cmd_home(_a) -> int:
    ensure_link()
    H.press_home()
    return out({"home": True})


def cmd_close(a) -> int:
    """Force-quit an app so the next `open` starts it from a cold state.

    Most Chinese apps restore their last screen, so a flow written against the
    home screen silently breaks the day after. Cold-starting removes that class
    of flakiness.
    """
    ensure_link()
    bid = resolve_app(a.app)
    t = time.time()
    killed = H.close_app(bid)
    return out({"closed": a.app, "bundle": bid, "was_running": bool(killed),
                "act_ms": int((time.time() - t) * 1000)})


def cmd_shot(a) -> int:
    ensure_link()
    t = time.time()
    path = Path(a.path) if a.path else ARTIFACTS / f"shot_{int(time.time()*1000)}.png"
    if not path.is_absolute():
        path = ARTIFACTS / path.name
    png = H.screenshot(str(path))
    res = {"path": str(path), "bytes": len(png),
           "act_ms": int((time.time() - t) * 1000)}
    if a.b64:
        res["png_b64"] = base64.b64encode(png).decode()
    return out(res)


def cmd_ocr(a) -> int:
    ensure_link()
    t = time.time()
    rows = H.ocr()
    if a.grep:
        needle = a.grep.lower()
        rows = [r for r in rows if needle in str(r.get("text", "")).lower()]
    rows = H.compact(rows, a.limit)
    return out({"count": len(rows), "rows": rows,
                "act_ms": int((time.time() - t) * 1000)})


def cmd_find(a) -> int:
    ensure_link()
    rows = H.find_text(a.text, exact=a.exact)
    return out({"query": a.text, "count": len(rows), "rows": H.compact(rows, 20)},
               0 if rows else 1)


def cmd_tap(a) -> int:
    ensure_link()
    t = time.time()
    H.tap(num(a.x), num(a.y))
    return out({"tap": [num(a.x), num(a.y)],
                "act_ms": int((time.time() - t) * 1000)})


def cmd_tap_if(a) -> int:
    """Tap the first OCR hit for `text`, or silently do nothing.

    For permission dialogs / pop-ups that MIGHT be on screen ("不允许",
    "以后再说"): a hard tap_text would fail the whole flow when the dialog
    never appears. OCR-first keeps it fast and works on alert overlays.
    """
    ensure_link()
    t = time.time()
    try:
        rows = H.ocr()
    except Exception:  # noqa: BLE001
        rows = []
    for r in rows:
        txt = str(r.get("text", ""))
        if (a.exact and txt == a.text) or (not a.exact and a.text in txt):
            H.tap(float(r["x"]), float(r["y"]))
            return out({"tapped": True, "text": txt,
                        "at": [r["x"], r["y"]],
                        "act_ms": int((time.time() - t) * 1000)})
    return out({"tapped": False, "act_ms": int((time.time() - t) * 1000)})


def cmd_tap_text(a) -> int:
    ensure_link()
    t = time.time()
    try:
        el = H.tap_text(a.text, index=a.index, exact=a.exact)
    except Exception:  # noqa: BLE001  — fall through to the OCR tap
        el = None
    if el is None:
        # The accessibility tree hides plenty of tappable labels behind
        # type=Other with no frame (amap's 偏好 was one). OCR sees everything
        # that is visibly rendered, so it is the reliable fallback.
        rows = H.ocr()
        hits = [r for r in rows
                if (a.text in str(r.get("text", "")) if not a.exact
                    else str(r.get("text", "")) == a.text)]
        if a.index >= len(hits):
            found = H.find_text(a.text, exact=a.exact)
            raise Fail(f"tap_text({a.text!r}) failed: not tappable via tree "
                       f"and not found by OCR",
                       f"{len(found)} candidate(s) on screen; run `ocr` to see them")
        r = hits[a.index]
        H.tap(float(r["x"]), float(r["y"]))
        el = {"via": "ocr", "text": r.get("text"),
              "x": r.get("x"), "y": r.get("y")}
    return out({"tapped": el, "act_ms": int((time.time() - t) * 1000)})


def cmd_type(a) -> int:
    ensure_link()
    t = time.time()
    H.type_text(a.text)
    return out({"typed": a.text, "act_ms": int((time.time() - t) * 1000)})


def cmd_field(a) -> int:
    ensure_link()
    t = time.time()
    rows = [r for r in H.ocr() if r.get("type") == "TextField"]
    if not rows:
        raise Fail("no TextField on screen", "tap the input box first")
    landed = H.set_field_text(rows[0], a.text)
    return out({"set": landed, "act_ms": int((time.time() - t) * 1000)})


def cmd_swipe(a) -> int:
    ensure_link()
    H.swipe(num(a.x1), num(a.y1), num(a.x2), num(a.y2), seconds=num(a.seconds))
    return out({"swipe": [num(a.x1), num(a.y1), num(a.x2), num(a.y2)]})


def cmd_scroll(a) -> int:
    ensure_link()
    H.scroll(a.direction, amount=num(a.amount))
    return out({"scrolled": a.direction})


def _find_text_ocr(text: str, exact: bool = False):
    """OCR fallback: heavy map pages (Amap route planner) hang WDA's
    accessibility tree, but screenshots + OCR stay instant."""
    try:
        rows = H.ocr()
    except Exception:  # noqa: BLE001
        return None
    for r in rows:
        txt = str(r.get("text", ""))
        if (exact and txt == text) or (not exact and text in txt):
            return {"text": txt, "x": r.get("x"), "y": r.get("y"),
                    "type": r.get("type", "Ocr")}
    return None


def cmd_wait_text(a) -> int:
    ensure_link()
    t = time.time()
    el = None
    hung = False
    try:
        el = H.wait_for_text(a.text, timeout=a.timeout)
    except TypeError:  # older signature without timeout kwarg
        el = None
        deadline = time.time() + a.timeout
        while time.time() < deadline:
            if H.find_text(a.text, exact=a.exact):
                el = H.find_text(a.text, exact=a.exact)[0]
                break
            time.sleep(0.2)
    except Exception:  # noqa: BLE001  — WDA hang/timeout: fall through to OCR
        hung = True
    if not el:
        # OCR path — also recovers the session when the tree call wedged WDA.
        deadline = time.time() + max(5.0, a.timeout / 2)
        while time.time() < deadline:
            el = _find_text_ocr(a.text, exact=a.exact)
            if el:
                break
            time.sleep(1.0)
    if not el:
        raise Fail(f"text {a.text!r} never appeared",
                   f"waited {a.timeout}s{' (accessibility tree hung, OCR fallback ran)' if hung else ''}")
    return out({"found": el, "act_ms": int((time.time() - t) * 1000)})


def cmd_wait_stable(a) -> int:
    ensure_link()
    t = time.time()
    ok = H.wait_stable(a.timeout)
    return out({"stable": ok, "act_ms": int((time.time() - t) * 1000)})


def cmd_tree(a) -> int:
    ensure_link()
    tree = H.ui_tree()
    if a.out:
        p = Path(a.out) if Path(a.out).is_absolute() else ARTIFACTS / a.out
        p.write_text(json.dumps(tree, ensure_ascii=False, indent=1), encoding="utf-8")
        return out({"path": str(p)})
    # a raw source dump is 40-400KB; the caller almost always wants the rows
    rows = H.compact(H.collect_texts(tree), a.limit)
    return out({"count": len(rows), "rows": rows})


def cmd_screen(_a) -> int:
    ensure_link()
    return out(H.screen_info())


# --------------------------------------------------------------------------- #
# flow — the fast path
# --------------------------------------------------------------------------- #
_SIMPLE = {
    "open": lambda s: cmd_open(_ns(app=s["app"], wait=s.get("wait", 0))),
    "close": lambda s: cmd_close(_ns(app=s["app"])),
    "tap": lambda s: cmd_tap(_ns(x=s["x"], y=s["y"])),
    "tap_if": lambda s: cmd_tap_if(_ns(text=s["text"],
                                       exact=s.get("exact", False))),
    "tap_text": lambda s: cmd_tap_text(
        _ns(text=s["text"], index=s.get("index", 0), exact=s.get("exact", False))),
    "type": lambda s: cmd_type(_ns(text=s["text"])),
    "field": lambda s: cmd_field(_ns(text=s["text"])),
    "swipe": lambda s: cmd_swipe(
        _ns(x1=s["x1"], y1=s["y1"], x2=s["x2"], y2=s["y2"],
            seconds=s.get("seconds", 0.3))),
    "scroll": lambda s: cmd_scroll(
        _ns(direction=s.get("direction", "down"), amount=s.get("amount", 0.4))),
    "shot": lambda s: cmd_shot(_ns(path=s.get("path"), b64=s.get("b64", False))),
    "ocr": lambda s: cmd_ocr(
        _ns(limit=s.get("limit", 40), grep=s.get("grep"))),
    "wait_text": lambda s: cmd_wait_text(
        _ns(text=s["text"], timeout=s.get("timeout", 8), exact=s.get("exact", False))),
    "wait_stable": lambda s: cmd_wait_stable(_ns(timeout=s.get("timeout", 8))),
    "home": lambda s: cmd_home(None),
    "app": lambda s: cmd_app(None),
}


class _ns:
    """Tiny namespace so flow steps reuse the same handlers as the CLI."""

    def __init__(self, **kw) -> None:
        self.__dict__.update(kw)


def _run_steps(sub: list, done: list, prefix: str = "") -> None:
    """Execute a nested step list (used by flow's retry block). Raises Fail."""
    for j, step in enumerate(sub, 1):
        if "sleep" in step:
            time.sleep(float(step["sleep"]))
            done.append({"i": prefix + str(j), "sleep": step["sleep"], "ok": True})
            continue
        cmd = step.get("cmd")
        if cmd not in _SIMPLE:
            raise Fail(f"retry step {prefix}{j}: unknown cmd {cmd!r}", "")
        t = time.time()
        rc = _SIMPLE[cmd](step.get("args", step.get("with", {})))
        if rc != 0:
            raise Fail(f"retry step {prefix}{j} ({cmd}) failed", "")
        done.append({"i": prefix + str(j), "cmd": cmd, "ok": True,
                     "ms": int((time.time() - t) * 1000)})


def cmd_flow(a) -> int:
    path = Path(a.file)
    if not path.is_absolute():
        path = ROOT / a.file
    spec = json.loads(path.read_text(encoding="utf-8"))
    steps = spec.get("steps", spec)
    # Simple templating so one example covers many targets: any top-level string
    # key becomes {{key}} inside the steps (e.g. {"dest": "广州塔"} -> "{{dest}}").
    if isinstance(spec, dict):
        for key, val in spec.items():
            if not isinstance(val, str) or key in ("name", "note"):
                continue
            try:
                steps = json.loads(
                    json.dumps(steps, ensure_ascii=False).replace("{{" + key + "}}", val)
                )
            except json.JSONDecodeError:
                pass  # value had a quote in it — leave the step unresolved
    t_all = time.time()
    done = []
    if a.dry_run:  # validate the file + templating without touching the phone
        return out({"flow": spec.get("name", path.stem), "steps": steps,
                    "dry_run": True, "count": len(steps)})
    ensure_link()
    for i, step in enumerate(steps, 1):
        if "sleep" in step:
            time.sleep(float(step["sleep"]))
            done.append({"i": i, "sleep": step["sleep"], "ok": True})
            continue
        # {"cmd": "retry", "args": {"times": 2, "steps": [...]}} — re-run the
        # block from its first step until every step in it succeeds. Covers
        # self-healing sequences like "app frozen on a splash ad → press Home
        # → relaunch → tap skip → wait for the home screen".
        if step.get("cmd") == "retry":
            sub = step.get("args", {}).get("steps", [])
            times = int(step.get("args", {}).get("times", 2))
            t = time.time()
            ok, err = False, ""
            for attempt in range(1, times + 1):
                try:
                    _run_steps(sub, done, prefix=f"{i}.{attempt}")
                    ok = True
                    break
                except Fail as exc:
                    err = exc.error
            if not ok:
                raise Fail(f"step {i} (retry) failed after {times} attempts: {err}",
                           "the wrapped block kept failing; inspect with `ocr`")
            done.append({"i": i, "cmd": "retry", "ok": True,
                         "ms": int((time.time() - t) * 1000)})
            continue
        cmd = step.get("cmd")
        if cmd not in _SIMPLE:
            raise Fail(f"step {i}: unknown cmd {cmd!r}",
                       f"known: {', '.join(sorted(_SIMPLE))}, sleep, retry")
        t = time.time()
        try:
            rc = _SIMPLE[cmd](step.get("args", step.get("with", {})))
        except Fail as exc:
            if a.keep_going:
                done.append({"i": i, "cmd": cmd, "ok": False, "error": exc.error})
                continue
            raise Fail(f"step {i} ({cmd}) failed: {exc.error}", exc.hint)
        done.append({"i": i, "cmd": cmd, "ok": rc == 0,
                     "ms": int((time.time() - t) * 1000)})
    return out({"flow": spec.get("name", path.stem), "steps": done,
                "total_ms": int((time.time() - t_all) * 1000)})


def cmd_serve(_a) -> int:
    os.execv(sys.executable, [sys.executable, str(ROOT / "service.py")])


# --------------------------------------------------------------------------- #
# arg parsing
# --------------------------------------------------------------------------- #
def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="phone", description="Drive a real iPhone over WDA. JSON out.")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("status", help="link + current app").set_defaults(fn=cmd_status)
    sub.add_parser("up", help="bring the link up (idempotent)").set_defaults(fn=cmd_up)
    sub.add_parser("down", help="tear the link down").set_defaults(fn=cmd_down)
    sub.add_parser("doctor", help="full health check").set_defaults(fn=cmd_doctor)
    sub.add_parser("serve", help="run the service in the foreground").set_defaults(fn=cmd_serve)

    s = sub.add_parser("open", help="launch an app by bundle id or name")
    s.add_argument("app")
    s.add_argument("--wait", type=float, default=0.0, help="seconds to wait for the UI to settle")
    s.set_defaults(fn=cmd_open)

    sub.add_parser("apps", help="list installed apps").set_defaults(fn=cmd_apps)
    sub.add_parser("app", help="current foreground app").set_defaults(fn=cmd_app)
    sub.add_parser("home", help="press Home").set_defaults(fn=cmd_home)

    s = sub.add_parser("close", help="force-quit an app (cold start next open)")
    s.add_argument("app", help="bundle id or name, e.g. com.autonavi.amap / 高德地图")
    s.set_defaults(fn=cmd_close)
    sub.add_parser("screen", help="screen geometry").set_defaults(fn=cmd_screen)

    s = sub.add_parser("shot", help="screenshot")
    s.add_argument("--path", default=None)
    s.add_argument("--b64", action="store_true", help="inline base64 PNG")
    s.set_defaults(fn=cmd_shot)

    s = sub.add_parser("ocr", help="visible text + coordinates")
    s.add_argument("--limit", type=int, default=60)
    s.add_argument("--grep", default=None)
    s.set_defaults(fn=cmd_ocr)

    s = sub.add_parser("find", help="locate text without tapping")
    s.add_argument("text")
    s.add_argument("--exact", action="store_true")
    s.set_defaults(fn=cmd_find)

    s = sub.add_parser("tap", help="tap absolute coordinates")
    s.add_argument("x")
    s.add_argument("y")
    s.set_defaults(fn=cmd_tap)

    s = sub.add_parser("tap-text", help="tap the element whose label contains TEXT")
    s.add_argument("text")
    s.add_argument("--index", type=int, default=0)
    s.add_argument("--exact", action="store_true")
    s.set_defaults(fn=cmd_tap_text)

    s = sub.add_parser("tap-if", help="tap TEXT if it is on screen, else skip (for pop-ups)")
    s.add_argument("text")
    s.add_argument("--exact", action="store_true")
    s.set_defaults(fn=cmd_tap_if)

    s = sub.add_parser("type", help="type into the focused field (CJK OK)")
    s.add_argument("text")
    s.set_defaults(fn=cmd_type)

    s = sub.add_parser("field", help="set the first TextField's value")
    s.add_argument("text")
    s.set_defaults(fn=cmd_field)

    s = sub.add_parser("swipe", help="swipe/drag")
    for k in ("x1", "y1", "x2", "y2"):
        s.add_argument(k)
    s.add_argument("--seconds", default=0.3)
    s.set_defaults(fn=cmd_swipe)

    s = sub.add_parser("scroll", help="scroll up or down")
    s.add_argument("direction", choices=["up", "down"])
    s.add_argument("--amount", default=0.4)
    s.set_defaults(fn=cmd_scroll)

    s = sub.add_parser("wait-text", help="block until text appears")
    s.add_argument("text")
    s.add_argument("--timeout", type=float, default=8.0)
    s.add_argument("--exact", action="store_true")
    s.set_defaults(fn=cmd_wait_text)

    s = sub.add_parser("wait-stable", help="block until the screen stops changing")
    s.add_argument("--timeout", type=float, default=8.0)
    s.set_defaults(fn=cmd_wait_stable)

    s = sub.add_parser("tree", help="accessibility tree")
    s.add_argument("--out", default=None)
    s.add_argument("--limit", type=int, default=80)
    s.set_defaults(fn=cmd_tree)

    s = sub.add_parser("flow", help="run a JSON step list in one process (fast)")
    s.add_argument("file")
    s.add_argument("--keep-going", action="store_true")
    s.add_argument("--dry-run", action="store_true",
                   help="print the resolved steps and exit (no phone needed)")
    s.set_defaults(fn=cmd_flow)
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.fn(args)
    except Fail as exc:
        return out({"error": exc.error, "hint": exc.hint}, 1)
    except KeyboardInterrupt:
        return out({"error": "interrupted"}, 130)
    except Exception as exc:  # noqa: BLE001
        return out({"error": f"{type(exc).__name__}: {exc}"}, 1)


if __name__ == "__main__":
    raise SystemExit(main())
