#!/data/data/com.termux/files/usr/bin/python
import json
import os
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CACHE_TTL = 15.0
CONTENT_TYPE = "text/plain; version=0.0.4; charset=utf-8"

_lock = threading.Lock()
_cache = {"at": None, "data": None}


def _run_battery():
    try:
        proc = subprocess.run(
            ["termux-battery-status"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if proc.returncode != 0:
            return None
        data = json.loads(proc.stdout)
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def get_battery():
    with _lock:
        now = time.monotonic()
        if _cache["at"] is None or now - _cache["at"] >= CACHE_TTL:
            _cache["data"] = _run_battery()
            _cache["at"] = now
        return _cache["data"]


def escape_label(value):
    return (
        str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    )


def _is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def render(data):
    lines = []

    def gauge(name, help_text, samples):
        lines.append(f"# HELP {name} {help_text}")
        lines.append(f"# TYPE {name} gauge")
        lines.extend(samples)

    if data is not None:
        numeric = (
            ("percentage", "termux_battery_percent", "Battery charge percentage."),
            (
                "temperature",
                "termux_battery_temperature_celsius",
                "Battery temperature in degrees Celsius.",
            ),
            (
                "current",
                "termux_battery_current_microamps",
                "Battery current in microamperes (negative when discharging).",
            ),
        )
        for key, name, help_text in numeric:
            if _is_number(data.get(key)):
                gauge(name, help_text, [f"{name} {data[key]}"])

        labelled = (
            ("plugged", "source", "termux_battery_plugged", "Plug source, value 1 for the current one."),
            ("status", "status", "termux_battery_status", "Charging status, value 1 for the current one."),
            ("health", "health", "termux_battery_health", "Battery health, value 1 for the current one."),
        )
        for key, label, name, help_text in labelled:
            if data.get(key) is not None:
                gauge(
                    name,
                    help_text,
                    [f'{name}{{{label}="{escape_label(data[key])}"}} 1'],
                )

    gauge(
        "termux_battery_scrape_success",
        "1 if termux-battery-status succeeded, else 0.",
        [f"termux_battery_scrape_success {0 if data is None else 1}"],
    )
    return "\n".join(lines) + "\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_error(404)
            return
        body = render(get_battery()).encode()
        self.send_response(200)
        self.send_header("Content-Type", CONTENT_TYPE)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


def main():
    port = int(os.environ.get("EXPORTER_PORT", "9100"))
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
