"""PhoneKit service — keeps tunnel + WDA + port forwards alive.

Why this file exists: `phone_harness.admin.up()` starts the tunnel and WDA as
*children of the calling process*. The moment that process exits (a script
finishes, a shell closes), Windows reaps them and the phone looks "down" again
one second later. This process calls up() once and then idles forever, so the
children has a long-lived parent.

It also answers a tiny control API, so a caller can bring the link back without
paying a Python start-up:

    GET  /health   -> {"ok": true, "up": bool, "wda": bool, "last_error": str}
    POST /up       -> (re)bring the link up
    POST /down     -> tear it down

Started automatically by phone.py when the link is cold; you can also run it
in a terminal:  python service.py
"""
from __future__ import annotations

import json
import os
import sys
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "src"))
os.environ["PATH"] = str(ROOT / "bin") + os.pathsep + os.environ.get("PATH", "")

# SideTap's Windows bugs (netstat returning None, GBK decoded as UTF-8) are
# patched in kitpatch.py, which must land before anything touches the device.
import kitpatch  # noqa: E402,F401

from phone_harness import admin, config  # noqa: E402

WDA_URL = f"http://127.0.0.1:{config.WDA_PORT}"
CONTROL_PORT = int(os.environ.get("PHONEKIT_CONTROL_PORT", "8899"))
LOG = ROOT / "artifacts" / "service.log"
_state = {"up": False, "last_error": None}
_lock = threading.Lock()


def wda_alive(timeout: float = 4.0) -> bool:
    import urllib.request

    try:
        with urllib.request.urlopen(WDA_URL + "/status", timeout=timeout) as r:
            return r.status == 200
    except Exception:  # noqa: BLE001
        return False


def bring_up() -> int:
    with _lock:
        try:
            rc = admin.up()
            _state["up"] = rc == 0
            _state["last_error"] = None
            print(f"[up] rc={rc} wda_alive={wda_alive()}", flush=True)
            return rc
        except Exception as exc:  # noqa: BLE001
            _state["up"] = False
            _state["last_error"] = str(exc)
            print(f"[up] FAILED: {exc}", flush=True)
            traceback.print_exc()
            return 1


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        return

    def do_GET(self):  # noqa: N802
        if self.path == "/health":
            self._send(200, {"ok": True, "up": _state["up"], "wda": wda_alive(),
                             "last_error": _state["last_error"],
                             "pid": os.getpid()})
        else:
            self._send(404, {"ok": False, "error": "unknown path"})

    def do_POST(self):  # noqa: N802
        if self.path == "/up":
            rc = bring_up()
            self._send(200 if rc == 0 else 500, {"ok": rc == 0, "wda": wda_alive()})
        elif self.path == "/down":
            try:
                admin.down()
            except Exception as exc:  # noqa: BLE001
                print(f"[down] error: {exc}", flush=True)
            _state["up"] = False
            self._send(200, {"ok": True})
        else:
            self._send(404, {"ok": False, "error": "unknown path"})


def main() -> int:
    LOG.parent.mkdir(exist_ok=True)
    # Bind the control port FIRST: bring_up() can take 20s+ on a cold tunnel,
    # and callers poll /health to decide whether the service exists at all.
    try:
        srv = ThreadingHTTPServer(("127.0.0.1", CONTROL_PORT), Handler)
    except OSError as exc:
        print(f"[service] cannot bind {CONTROL_PORT}: {exc}", flush=True)
        return 1
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    print(f"[service] control API on http://127.0.0.1:{CONTROL_PORT}", flush=True)

    def boot() -> None:
        # A dead WDA after a replug is the common case: retry a few times.
        for attempt in range(1, 4):
            rc = bring_up()
            if rc == 0 and wda_alive():
                return
            print(f"[boot] attempt {attempt} failed, retrying in 5s", flush=True)
            time.sleep(5)

    threading.Thread(target=boot, daemon=True).start()

    while True:
        time.sleep(30)
        if not wda_alive():
            print("[service] WDA unreachable, bringing link back up", flush=True)
            bring_up()


if __name__ == "__main__":
    raise SystemExit(main())
