import importlib.util
import json
import subprocess
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest import mock

_spec = importlib.util.spec_from_file_location(
    "termux_exporter", Path(__file__).with_name("termux-exporter.py")
)
exp = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(exp)

FULL = {
    "health": "GOOD",
    "percentage": 80,
    "plugged": "PLUGGED_AC",
    "status": "NOT_CHARGING",
    "temperature": 27.5,
    "current": -12345,
}


def completed(stdout="", returncode=0):
    return subprocess.CompletedProcess(["termux-battery-status"], returncode, stdout, "")


class Base(unittest.TestCase):
    def setUp(self):
        exp._cache.update(at=None, data=None)


class RenderTests(Base):
    def test_full(self):
        out = exp.render(FULL)
        for line in (
            "termux_battery_percent 80",
            "termux_battery_temperature_celsius 27.5",
            "termux_battery_current_microamps -12345",
            'termux_battery_plugged{source="PLUGGED_AC"} 1',
            'termux_battery_status{status="NOT_CHARGING"} 1',
            'termux_battery_health{health="GOOD"} 1',
            "termux_battery_scrape_success 1",
            "# TYPE termux_battery_percent gauge",
        ):
            self.assertIn(line + "\n", out)
        self.assertIn("# HELP termux_battery_health ", out)

    def test_missing_keys_omitted(self):
        out = exp.render({"percentage": 50})
        self.assertIn("termux_battery_percent 50\n", out)
        self.assertIn("termux_battery_scrape_success 1\n", out)
        for name in ("temperature", "current", "plugged", "status", "health"):
            self.assertNotIn(f"termux_battery_{name}", out)

    def test_escaping(self):
        out = exp.render({"health": 'a\\b"c\nd'})
        self.assertIn('termux_battery_health{health="a\\\\b\\"c\\nd"} 1\n', out)

    def test_failure_render(self):
        out = exp.render(None)
        samples = [l for l in out.splitlines() if not l.startswith("#")]
        self.assertEqual(samples, ["termux_battery_scrape_success 0"])


class FailureTests(Base):
    def check(self, **kw):
        with mock.patch.object(exp.subprocess, "run", **kw):
            out = exp.render(exp.get_battery())
        samples = [l for l in out.splitlines() if not l.startswith("#")]
        self.assertEqual(samples, ["termux_battery_scrape_success 0"])

    def test_nonzero_exit(self):
        self.check(return_value=completed("{}", 1))

    def test_timeout(self):
        self.check(side_effect=subprocess.TimeoutExpired("x", 10))

    def test_invalid_json(self):
        self.check(return_value=completed("not json"))

    def test_not_found(self):
        self.check(side_effect=FileNotFoundError())


class CacheTests(Base):
    def test_cache_within_ttl(self):
        with mock.patch.object(
            exp.subprocess, "run", return_value=completed(json.dumps(FULL))
        ) as run, mock.patch.object(exp.time, "monotonic", side_effect=[100.0, 110.0]):
            self.assertEqual(exp.get_battery(), FULL)
            self.assertEqual(exp.get_battery(), FULL)
        self.assertEqual(run.call_count, 1)

    def test_refresh_after_ttl(self):
        with mock.patch.object(
            exp.subprocess, "run", return_value=completed(json.dumps(FULL))
        ) as run, mock.patch.object(exp.time, "monotonic", side_effect=[100.0, 116.0]):
            exp.get_battery()
            exp.get_battery()
        self.assertEqual(run.call_count, 2)


class ServerTests(Base):
    def setUp(self):
        super().setUp()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), exp.Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def test_metrics(self):
        with mock.patch.object(
            exp.subprocess, "run", return_value=completed(json.dumps(FULL))
        ):
            with urllib.request.urlopen(self.base + "/metrics") as r:
                self.assertEqual(r.status, 200)
                self.assertEqual(
                    r.headers["Content-Type"], "text/plain; version=0.0.4; charset=utf-8"
                )
                self.assertIn(b"termux_battery_percent 80\n", r.read())

    def test_404(self):
        for path in ("/", "/foo"):
            with self.assertRaises(urllib.error.HTTPError) as cm:
                urllib.request.urlopen(self.base + path)
            self.assertEqual(cm.exception.code, 404)


if __name__ == "__main__":
    unittest.main()
