"""Send .pkg files to a PS4 running Remote Package Installer (RPI).

Serves the selected files over HTTP from this computer and asks RPI to
install them. Progress is measured here, from the bytes the PS4 downloads,
instead of polling RPI: RPI leaks a thread per request and stops answering
after a few hundred, so this script sends exactly one request per package.

Usage:
    python send_to_ps4.py FILE.pkg [FILE2.pkg ...]
    python send_to_ps4.py --list LISTFILE      (one path per line; Double Commander %L)
Options:
    --ps4 IP          console address      (default from actions.json, else 192.168.1.113)
    --rpi-port PORT   RPI port: 12800 = flatz RPI, 12801 = patched RPI (default from actions.json)
Keep this window open until the PS4 finishes downloading.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
CHUNK = 1024 * 1024


def load_settings() -> dict:
    cfg = HERE / "actions.json"
    data = {"ps4_ip": "192.168.1.113", "rpi_port": 12800}
    if cfg.exists():
        data.update(json.loads(cfg.read_text(encoding="utf-8")).get("ps4", {}))
    return data


def local_ip_towards(host: str) -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((host, 9))
        return s.getsockname()[0]
    finally:
        s.close()


class Served:
    """Files offered to the PS4 and how many bytes it has pulled."""

    def __init__(self, files: list[Path]):
        self.files = {str(i): f for i, f in enumerate(files)}
        self.sent = {k: 0 for k in self.files}
        self.last_activity = {k: 0.0 for k in self.files}
        self.lock = threading.Lock()

    def add_sent(self, key: str, n: int):
        with self.lock:
            self.sent[key] += n
            self.last_activity[key] = time.time()


def make_handler(served: Served):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):  # keep the console clean
            pass

        def _resolve(self):
            parts = self.path.split("/")
            if len(parts) < 3 or parts[1] not in served.files:
                self.send_error(404)
                return None, None
            return parts[1], served.files[parts[1]]

        def do_HEAD(self):
            self._serve(head=True)

        def do_GET(self):
            self._serve(head=False)

        def _serve(self, head: bool):
            key, path = self._resolve()
            if path is None:
                return
            size = path.stat().st_size
            start, end = 0, size - 1
            rng = self.headers.get("Range")
            if rng and rng.startswith("bytes="):
                a, _, b = rng[6:].split(",")[0].partition("-")
                if a:
                    start = int(a)
                    end = int(b) if b else size - 1
                else:  # suffix range: last N bytes
                    start = max(0, size - int(b))
                end = min(end, size - 1)
                if start > end:
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{size}")
                    self.end_headers()
                    return
                self.send_response(206)
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            else:
                self.send_response(200)
            length = end - start + 1
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(length))
            self.end_headers()
            if head:
                return
            with open(path, "rb") as fh:
                fh.seek(start)
                left = length
                try:
                    while left > 0:
                        buf = fh.read(min(CHUNK, left))
                        if not buf:
                            break
                        self.wfile.write(buf)
                        left -= len(buf)
                        served.add_sent(key, len(buf))
                except (ConnectionResetError, BrokenPipeError, ConnectionAbortedError):
                    pass

    return Handler


def rpi(ps4: str, port: int, endpoint: str, payload: dict, timeout: float = 10) -> dict:
    req = urllib.request.Request(
        f"http://{ps4}:{port}/api/{endpoint}",
        data=json.dumps(payload).encode(),
        method="POST",
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        text = r.read().decode("utf-8", "replace")
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return {"status": "unknown", "raw": text}


def human(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{int(n)} B"
        n /= 1024
    return f"{n:.1f} GB"


def pause_if_console():
    if sys.stdin and sys.stdin.isatty():
        try:
            input("\nPress Enter to close...")
        except EOFError:
            pass


def main() -> int:
    settings = load_settings()
    ap = argparse.ArgumentParser(description="Send .pkg files to a PS4 (Remote Package Installer).")
    ap.add_argument("files", nargs="*")
    ap.add_argument("--list", help="file with one path per line (Double Commander %%L)")
    ap.add_argument("--ps4", default=settings["ps4_ip"])
    ap.add_argument("--rpi-port", type=int, default=int(settings["rpi_port"]))
    args = ap.parse_args()

    names = list(args.files)
    if args.list:
        names += [l.strip() for l in Path(args.list).read_text(encoding="utf-8-sig").splitlines() if l.strip()]
    files = [Path(n) for n in names if n.lower().endswith(".pkg") and Path(n).is_file()]
    skipped = [n for n in names if Path(n) not in files]
    for n in skipped:
        print(f"Skipping (not a .pkg file): {n}")
    if not files:
        print("No .pkg files to send.")
        return 1

    print(f"PS4: {args.ps4}  RPI port: {args.rpi_port}")
    try:
        rpi(args.ps4, args.rpi_port, "is_exists", {"title_id": "CUSA00000"}, timeout=4)
    except Exception as e:
        print(f"Cannot reach Remote Package Installer at {args.ps4}:{args.rpi_port} ({e}).")
        print("Start RPI on the PS4 (and check the IP / port), then try again.")
        return 2

    served = Served(files)
    server = ThreadingHTTPServer(("0.0.0.0", 0), make_handler(served))
    my_ip = local_ip_towards(args.ps4)
    base = f"http://{my_ip}:{server.server_address[1]}"
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(f"Serving from {base}\n")

    started: dict[str, str] = {}
    for key, path in served.files.items():
        url = f"{base}/{key}/{urllib.parse.quote(path.name)}"
        try:
            res = rpi(args.ps4, args.rpi_port, "install", {"type": "direct", "packages": [url]}, timeout=30)
        except Exception as e:
            print(f"  FAILED  {path.name}: {e}")
            continue
        if res.get("status") == "success":
            started[key] = path.name
            print(f"  queued  {path.name}  (task {res.get('task_id')}, {human(path.stat().st_size)})")
        else:
            print(f"  FAILED  {path.name}: {res}")
        time.sleep(3)  # RPI is fragile with back-to-back requests

    if not started:
        print("\nNothing was queued.")
        server.shutdown()
        return 3

    print("\nThe PS4 is downloading. Keep this window open until all show 100%.\n")
    sizes = {k: served.files[k].stat().st_size for k in started}
    done: set[str] = set()
    try:
        while len(done) < len(started):
            time.sleep(2)
            parts = []
            now = time.time()
            for k, name in started.items():
                pct = min(100, served.sent[k] * 100 // max(1, sizes[k]))
                idle = now - served.last_activity[k] if served.last_activity[k] else 0
                if pct >= 100 and idle > 20:
                    done.add(k)
                parts.append(f"{name[:28]}: {pct}%")
            print("\r" + " | ".join(parts)[:150].ljust(150), end="", flush=True)
    except KeyboardInterrupt:
        print("\nStopped. Downloads that were still running on the PS4 will fail.")
        server.shutdown()
        return 4
    print("\n\nAll packages transferred. The PS4 finishes installing on its own.")
    server.shutdown()
    return 0


if __name__ == "__main__":
    code = main()
    pause_if_console()
    sys.exit(code)
