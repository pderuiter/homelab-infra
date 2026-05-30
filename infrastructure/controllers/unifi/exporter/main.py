"""UniFi update-availability Prometheus exporter.

Polls the UniFi OS API (/api/system) and the Network controller API
(/proxy/network/api/s/<site>/stat/device) and exposes:

    unifi_os_update_available{current_version, latest_version}     0|1
    unifi_app_update_available{app, current_version, channel}      0|1
    unifi_device_update_available{device, model, mac, current_version, upgrade_to_firmware}  0|1
    unifi_device_online{device, model, mac}                        0|1
    unifi_scrape_success                                           0|1
    unifi_scrape_duration_seconds
    unifi_scrape_last_success_timestamp_seconds

Configuration via env vars (set by Kubernetes Deployment):
    UNIFI_HOST      e.g. 10.69.2.1
    UNIFI_USER      controller account username
    UNIFI_PASS      controller account password
    UNIFI_SITE      site name (default: "default")
    POLL_INTERVAL   seconds between scrapes (default: 300)
    LISTEN_PORT     metrics port (default: 9131)
"""

import logging
import os
import sys
import time
import urllib3

import requests
from prometheus_client import (
    CollectorRegistry,
    Gauge,
    generate_latest,
    CONTENT_TYPE_LATEST,
)
from http.server import BaseHTTPRequestHandler, HTTPServer
from threading import Thread


urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

HOST = os.environ["UNIFI_HOST"]
USER = os.environ["UNIFI_USER"]
PASS = os.environ["UNIFI_PASS"]
SITE = os.environ.get("UNIFI_SITE", "default")
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL", "300"))
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "9131"))

BASE_URL = f"https://{HOST}"

registry = CollectorRegistry()
os_update = Gauge(
    "unifi_os_update_available",
    "UniFi OS update available (0/1)",
    ["current_version", "latest_version"],
    registry=registry,
)
app_update = Gauge(
    "unifi_app_update_available",
    "UniFi app update available (0/1)",
    ["app", "current_version", "channel"],
    registry=registry,
)
device_update = Gauge(
    "unifi_device_update_available",
    "UniFi device firmware update available (0/1)",
    ["device", "model", "mac", "current_version", "upgrade_to_firmware"],
    registry=registry,
)
device_online = Gauge(
    "unifi_device_online",
    "UniFi device online (0/1)",
    ["device", "model", "mac"],
    registry=registry,
)
scrape_success = Gauge("unifi_scrape_success", "Last scrape success (0/1)", registry=registry)
scrape_duration = Gauge(
    "unifi_scrape_duration_seconds", "Duration of last scrape", registry=registry
)
scrape_last_success = Gauge(
    "unifi_scrape_last_success_timestamp_seconds",
    "Unix timestamp of last successful scrape",
    registry=registry,
)


logging.basicConfig(
    level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", stream=sys.stdout
)
log = logging.getLogger("unifi-update-exporter")


class UnifiClient:
    def __init__(self):
        self.session = requests.Session()
        self.session.verify = False
        self.csrf = None

    def login(self):
        r = self.session.post(
            f"{BASE_URL}/api/auth/login",
            json={"username": USER, "password": PASS, "rememberMe": False},
            timeout=10,
        )
        r.raise_for_status()
        self.csrf = r.headers.get("X-CSRF-Token") or r.headers.get("x-csrf-token")

    def get(self, path):
        headers = {"X-CSRF-Token": self.csrf} if self.csrf else {}
        r = self.session.get(f"{BASE_URL}{path}", headers=headers, timeout=15)
        if r.status_code == 401:
            self.login()
            headers["X-CSRF-Token"] = self.csrf
            r = self.session.get(f"{BASE_URL}{path}", headers=headers, timeout=15)
        r.raise_for_status()
        return r.json()


def scrape(client: UnifiClient):
    """One full scrape. Resets metrics before refilling so stale labels disappear."""
    os_update.clear()
    app_update.clear()
    device_update.clear()
    device_online.clear()

    system = client.get("/api/system")

    # --- UniFi OS itself ---
    current = system.get("hardware", {}).get("firmwareVersion", "unknown")
    latest = system.get("latestUpdate")
    if latest:
        latest_ver = (
            latest.get("version") if isinstance(latest, dict) else str(latest)
        )
        os_update.labels(current_version=current, latest_version=latest_ver).set(1)
    else:
        os_update.labels(current_version=current, latest_version=current).set(0)

    # --- Controller apps (network, protect, etc.) ---
    apps = system.get("apps", {})
    for app in apps.get("apps", []) + apps.get("controllers", []):
        name = app.get("name") or app.get("app") or "unknown"
        version = app.get("version") or "unknown"
        channel = app.get("releaseChannel") or "unknown"
        has_update = 1 if app.get("updateAvailable") else 0
        app_update.labels(app=name, current_version=version, channel=channel).set(
            has_update
        )

    # --- Per-device firmware ---
    devices_resp = client.get(f"/proxy/network/api/s/{SITE}/stat/device")
    for dev in devices_resp.get("data", []):
        name = dev.get("name") or dev.get("hostname") or "unnamed"
        model = dev.get("model") or "unknown"
        mac = dev.get("mac") or "unknown"
        version = dev.get("version") or "unknown"
        upgrade_to = dev.get("upgrade_to_firmware") or ""
        upgradable = 1 if dev.get("upgradable") else 0
        device_update.labels(
            device=name,
            model=model,
            mac=mac,
            current_version=version,
            upgrade_to_firmware=upgrade_to,
        ).set(upgradable)
        online = 1 if dev.get("state") == 1 else 0
        device_online.labels(device=name, model=model, mac=mac).set(online)


def poll_loop():
    client = UnifiClient()
    while True:
        start = time.time()
        try:
            if client.csrf is None:
                client.login()
            scrape(client)
            scrape_success.set(1)
            scrape_last_success.set(time.time())
            log.info("scrape ok in %.2fs", time.time() - start)
        except Exception:
            log.exception("scrape failed")
            scrape_success.set(0)
            # Force re-login on next iteration
            client.csrf = None
        finally:
            scrape_duration.set(time.time() - start)
        time.sleep(POLL_INTERVAL)


class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return
        body = generate_latest(registry)
        self.send_response(200)
        self.send_header("Content-Type", CONTENT_TYPE_LATEST)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        return  # silence default per-request logging


def main():
    Thread(target=poll_loop, daemon=True).start()
    log.info("listening on :%d/metrics", LISTEN_PORT)
    HTTPServer(("0.0.0.0", LISTEN_PORT), MetricsHandler).serve_forever()


if __name__ == "__main__":
    main()
