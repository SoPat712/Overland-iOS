#!/usr/bin/env python3
"""Exercise real simulator location delivery against a disposable local server.

Creates and removes its own simulator. Never targets the owner's trial simulator.
No screenshots, production endpoints, or persisted credentials are used.
"""
import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time

BUNDLE = "com.aaronpk.overland"


def run(*args, timeout=60):
    return subprocess.check_output(args, text=True, timeout=timeout, stderr=subprocess.STDOUT)


def wait_for(check, message, timeout=45):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(1)
    raise AssertionError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--output", type=Path, default=Path("/tmp/overland-fake-route-results.json"))
    args = parser.parse_args()
    if not args.app.is_dir():
        parser.error("Supply a built simulator .app directory")

    devices = json.loads(run("xcrun", "simctl", "list", "devices", "-j"))["devices"]
    booted = [d["name"] for group in devices.values() for d in group if d["state"] == "Booted"]
    if booted:
        parser.error("Shut down running simulators before this test: " + ", ".join(booted))

    requests = []
    lock = threading.Lock()

    class Receiver(BaseHTTPRequestHandler):
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            with lock:
                status = 503 if not requests else 200
                requests.append({"status": status, "body": body})
            response = json.dumps({"result": "ok" if status == 200 else "retry"}).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(response)))
            self.end_headers()
            self.wfile.write(response)

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Receiver)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    runtimes = json.loads(run("xcrun", "simctl", "list", "runtimes", "-j"))["runtimes"]
    runtime = next(r["identifier"] for r in runtimes if r["isAvailable"] and r["name"].startswith("iOS 27"))
    udid = run("xcrun", "simctl", "create", "Overland Fake Route", "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", runtime).strip()
    companion = None
    route = None
    checks = []
    try:
        print(f"Created isolated simulator {udid}", flush=True)
        run("xcrun", "simctl", "boot", udid)
        run("xcrun", "simctl", "bootstatus", udid, "-b", timeout=180)
        run("xcrun", "simctl", "install", udid, str(args.app.resolve()), timeout=120)
        for service in ("location-always", "motion"):
            run("xcrun", "simctl", "privacy", udid, "grant", service, BUNDLE)
        run("xcrun", "simctl", "location", udid, "set", "45.5152,-122.6784")
        endpoint = f"http://127.0.0.1:{server.server_port}/locations"
        run("xcrun", "simctl", "launch", udid, BUNDLE,
            "-GLAPIEndpointDefaults", endpoint, "-GLTrackingStateDefaults", "YES",
            "-GLSignificantLocationModeDefaults", "1", "-GLDesiredAccuracyDefaults", "-1",
            "-GLPausesAutomaticallyDefaults", "NO", "-GLSendIntervalDefaults", "1",
            "-GLNotificationsEnabledDefaults", "NO", "-GLLoggingModeDefaults", "0",
            "-GLTripPausesAutomaticallyDefaults", "NO", "-GLTripDesiredAccuracyDefaults", "-1")
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        log = tempfile.TemporaryFile()
        companion = subprocess.Popen(["idb_companion", "--udid", udid, "--grpc-port", str(port)], stdout=log, stderr=log, start_new_session=True)
        base = ["idb", "--companion", f"localhost:{port}", "ui"]

        def ui(*commands):
            return run(*base, *commands, "--udid", udid, timeout=15)

        def state():
            return json.loads(ui("describe-all"))

        def ready():
            try:
                return state()
            except (subprocess.SubprocessError, json.JSONDecodeError):
                return None

        def find(label, kind=None):
            return next((e for e in state() if e.get("AXLabel") == label and (kind is None or e.get("type") == kind)), None)

        def tap(label, kind="Button", last=False):
            matches = [e for e in state() if e.get("AXLabel") == label and e.get("type") == kind]
            if not matches:
                raise AssertionError(f"Missing {kind}: {label}")
            f = matches[-1 if last else 0]["frame"]
            ui("tap", str(round(f["x"] + f["width"] / 2)), str(round(f["y"] + f["height"] / 2)))
            time.sleep(0.8)

        wait_for(ready, "IDB did not become ready", timeout=60)
        wait_for(lambda: find("Stop Tracking", "Button"), "Tracker did not start")
        tap("Stop Tracking")
        wait_for(lambda: find("Keep Tracking", "Button"), "Stop confirmation missing")
        tap("Keep Tracking")
        assert find("Stop Tracking", "Button"), "Cancel stopped tracking"
        checks.append("Main stop confirmation preserves tracking when canceled")
        print(checks[-1], flush=True)
        tap("Trip")
        tap("Start Trip")
        wait_for(lambda: find("Stop Trip", "Button"), "Trip did not start")
        route = subprocess.Popen(["xcrun", "simctl", "location", udid, "start", "--speed=12", "--interval=1",
                                  "45.5152,-122.6784", "45.5182,-122.6784", "45.5182,-122.6724"],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        def coordinates():
            with lock:
                return {tuple(f["geometry"]["coordinates"]) for r in requests for f in r["body"].get("locations", [])
                        if (f.get("geometry") or {}).get("type") == "Point"}

        wait_for(lambda: len(coordinates()) >= 6, "Simulated route did not reach server", timeout=75)
        with lock:
            snapshots = list(requests)
        failed = snapshots[0]["body"]["locations"]
        assert snapshots[0]["status"] == 503
        def record_key(feature):
            properties = feature.get("properties", {})
            geometry = feature.get("geometry") or {}
            return (properties.get("timestamp"), properties.get("action"), tuple(geometry.get("coordinates", [])))
        failed_keys = {record_key(f) for f in failed}
        assert any(failed_keys <= {record_key(f) for f in r["body"].get("locations", [])}
                   for r in snapshots[1:] if r["status"] == 200), "Failed upload lost records"
        assert any(f.get("properties", {}).get("trip_id") for r in snapshots for f in r["body"].get("locations", [])), "Trip data missing from upload"
        wait_for(lambda: find("Current location"), "Current location annotation missing")
        assert find("Live"), "Trip timeline missing"
        checks.extend(["Simulated route reaches local server with at least six distinct coordinates",
                       "503 failure preserves records for successful retry", "Trip records carry trip metadata and timeline is live",
                       "Current location annotation is present"])
        tap("Stop Trip")
        wait_for(lambda: find("Start Trip", "Button"), "Trip did not end")
        tap("Tracker")
        assert find("Stop Tracking", "Button"), "Trip did not restore earlier tracking state"
        tap("Stop Tracking")
        tap("Stop Tracking", last=True)
        wait_for(lambda: find("Start Tracking", "Button"), "Confirmed stop did not stop tracking")
        checks.append("Ending trip restores tracking; explicit stop confirmation stops it")
        print("PASS: " + "; ".join(checks), flush=True)
    finally:
        args.output.write_text(json.dumps({"checks": checks, "requests": requests}, indent=2))
        if route and route.poll() is None:
            route.terminate()
            route.wait(timeout=5)
        if companion:
            companion.terminate()
            try:
                companion.wait(timeout=5)
            except subprocess.TimeoutExpired:
                companion.kill()
                companion.wait(timeout=5)
        server.shutdown()
        server.server_close()
        subprocess.run(["xcrun", "simctl", "shutdown", udid], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["xcrun", "simctl", "delete", udid], check=True)
        print(f"Removed isolated simulator; results: {args.output}", flush=True)


if __name__ == "__main__":
    main()
