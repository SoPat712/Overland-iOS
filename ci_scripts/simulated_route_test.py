#!/usr/bin/env python3
"""Exercise real simulator location delivery against a disposable local server.

Creates and removes its own simulator. Never targets the owner's trial simulator.
No screenshots, production endpoints, or persisted credentials are used.
"""
import argparse
import json
import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import socket
import sqlite3
import subprocess
import tempfile
import threading
import time

from ui_accessibility import read_state

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


def check_history_migration(udid):
    container = Path(run("xcrun", "simctl", "get_app_container", udid, BUNDLE, "data").strip())
    path = container / "Library/Application Support/Recent Locations/history.sqlite"
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps({"_type": "location", "lat": 45.5152, "lon": -122.6784,
                          "tst": time.time(), "tid": "migration-test"}).encode()
    with sqlite3.connect(path) as db:
        db.execute("CREATE TABLE points (id INTEGER PRIMARY KEY, timestamp REAL NOT NULL, "
                   "latitude REAL NOT NULL, longitude REAL NOT NULL, format INTEGER NOT NULL, payload BLOB NOT NULL)")
        db.execute("INSERT INTO points VALUES (4000, ?, 45.5152, -122.6784, 1, ?)", (time.time(), payload))
        db.execute("INSERT INTO points VALUES (4001, 1, 45.5152, -122.6784, 1, ?)", (payload,))

    def migrated():
        with sqlite3.connect(path) as db:
            schema = db.execute("SELECT sql FROM sqlite_master WHERE name = 'points'").fetchone()[0]
            return "AUTOINCREMENT" in schema and db.execute("SELECT COUNT(*) FROM points").fetchone()[0] == 1

    run("xcrun", "simctl", "launch", udid, BUNDLE, "-GLTrackingStateDefaults", "NO")
    wait_for(migrated, "Replay migration or expiry failed")
    with sqlite3.connect(path) as db:
        assert db.execute("SELECT payload FROM points WHERE id = 4000").fetchone()[0] == payload, "Migration changed the stored record"
        db.execute("UPDATE points SET timestamp = 1")
    run("xcrun", "simctl", "terminate", udid, BUNDLE)
    run("xcrun", "simctl", "launch", udid, BUNDLE, "-GLTrackingStateDefaults", "NO")

    def expired():
        with sqlite3.connect(path) as db:
            return db.execute("SELECT COUNT(*) FROM points").fetchone()[0] == 0

    wait_for(expired, "Replay did not prune the expired final record")
    run("xcrun", "simctl", "terminate", udid, BUNDLE)
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--simulator-id", help="Reuse an Overland Fake Route simulator; its app data is reset and the simulator is deleted afterward")
    parser.add_argument("--keep-on-failure", action="store_true", help="Keep the stopped disposable simulator for diagnosis if a check fails")
    parser.add_argument("--output", type=Path, default=Path("/tmp/overland-fake-route-results.json"))
    args = parser.parse_args()
    if not args.app.is_dir():
        parser.error("Supply a built simulator .app directory")

    devices = json.loads(run("xcrun", "simctl", "list", "devices", "-j"))["devices"]
    existing = next((d for group in devices.values() for d in group if d["udid"] == args.simulator_id), None)
    if args.simulator_id and (not existing or existing["name"] != "Overland Fake Route"):
        parser.error("Only a disposable simulator named Overland Fake Route can be reused")
    booted = [d["name"] for group in devices.values() for d in group
              if d["state"] == "Booted" and d["udid"] != args.simulator_id]
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
    udid = args.simulator_id or run("xcrun", "simctl", "create", "Overland Fake Route", "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", runtime).strip()
    companion = None
    route = None
    runtime_log = None
    runtime_stream = None
    completed = False
    checks = []
    try:
        print(f"Isolated simulator {udid}", flush=True)
        if not existing or existing["state"] != "Booted":
            run("xcrun", "simctl", "boot", udid)
        run("xcrun", "simctl", "bootstatus", udid, "-b", timeout=180)
        runtime_log = args.output.with_suffix(".runtime.log").open("w")
        runtime_stream = subprocess.Popen(
            ["xcrun", "simctl", "spawn", udid, "log", "stream", "--style", "compact",
             "--level", "default", "--predicate", 'process == "Overland"'],
            stdout=runtime_log, stderr=subprocess.STDOUT)
        if existing:
            run("xcrun", "simctl", "uninstall", udid, BUNDLE)
        run("xcrun", "simctl", "install", udid, str(args.app.resolve()), timeout=120)
        history_path = check_history_migration(udid)
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
            return read_state(ui)

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

        def drag_panel(distance):
            frame = find("Controls panel")["frame"]
            x = round(frame["x"] + frame["width"] / 2)
            y = round(frame["y"] + frame["height"] / 2)
            ui("swipe", str(x), str(y), str(x), str(max(65, min(820, y + distance))), "--duration", "0.8")
            time.sleep(1)

        location_button = find("Show My Location", "Button")
        assert location_button and location_button["frame"]["x"] > 250, "Location control is not at top right"
        assert find("Map style", "PopUpButton"), "Map style control missing"
        wait_for(lambda: find("Current location"), "Map location missing")
        legal = find("Legal")["frame"]
        drag_panel(600)
        collapsed = find("Controls panel")
        assert collapsed["frame"]["y"] > 700, "Panel did not collapse"
        assert not find("Stop Tracking", "Button"), "Collapsed panel exposes hidden actions"
        assert find("Tracker", "Button") and find("Trip", "Button") and find("Settings", "Button")
        collapsed_legal = find("Legal")["frame"]
        assert collapsed_legal["y"] > legal["y"] + 100, "Map attribution did not follow the collapsed panel"
        assert collapsed_legal["y"] + collapsed_legal["height"] < collapsed["frame"]["y"], "Panel obscures MapKit attribution"
        drag_panel(-700)
        expanded = find("Controls panel")
        assert expanded["frame"]["width"] > collapsed["frame"]["width"], "Panel did not widen"
        assert 250 < expanded["frame"]["y"] < 650, "Panel does not fit its controls"
        action = find("Stop Tracking", "Button")["frame"]
        tabs = find("Tracker", "Button")["frame"]
        assert action["y"] + action["height"] < tabs["y"], "Tracking action overlaps tabs"
        assert tabs["y"] - action["y"] - action["height"] < 50, "Panel leaves empty space below its actions"
        drag_panel(700)
        tap("Tracker")
        assert find("Stop Tracking", "Button"), "Tab did not reopen controls"
        checks.append("Panel collapses to tabs and opens to fit its controls; map controls sit at top right")
        print(checks[-1], flush=True)

        tap("Stop Tracking")
        wait_for(lambda: find("Keep Tracking", "Button"), "Stop confirmation missing")
        tap("Keep Tracking")
        assert find("Stop Tracking", "Button"), "Cancel stopped tracking"
        checks.append("Main stop confirmation preserves tracking when canceled")
        print(checks[-1], flush=True)
        tap("Trip")
        tap("Trip Settings")
        assert find("Trip Settings", "Heading"), "Trip Settings did not open"
        assert not find("Controls panel"), "Settings retained the map panel"
        assert not any(e.get("subrole") == "AXMapArea" for e in state()), "Settings exposes the map"
        tap("Trip")
        tap("Show My Location")
        checks.append("Trip Settings opens as a separate page; returning to Trip restores map controls")
        tap("Start Trip")
        wait_for(lambda: find("Stop Trip", "Button"), "Trip did not start")
        route = subprocess.Popen(["xcrun", "simctl", "location", udid, "start", "--speed=12", "--interval=1",
                                  "45.5152,-122.6784", "45.5182,-122.6784", "45.5182,-122.6724"],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        wait_for(lambda: len([e for e in state() if e.get("type") == "Button"
                              and re.search(r"\d{1,2}:\d{2}:\d{2}", e.get("AXLabel") or "")]) >= 2,
                 "Trip timeline did not receive the first route points")
        drag_panel(600)
        assert not find("Stop Trip", "Button"), "Collapsed Trip panel exposes its controls"

        def coordinates():
            with lock:
                return {tuple(f["geometry"]["coordinates"]) for r in requests for f in r["body"].get("locations", [])
                        if (f.get("geometry") or {}).get("type") == "Point"}

        wait_for(lambda: len(coordinates()) >= 6, "Simulated route did not reach server", timeout=75)
        tap("Trip")
        checks.append("Trip continues recording while its controls are collapsed")
        with sqlite3.connect(history_path) as db:
            ids = [row[0] for row in db.execute("SELECT id FROM points")]
        assert ids and min(ids) > 4001, "History reused an expired ID and would miss new replay points"
        checks.append("Replay migrates legacy records unchanged and preserves increasing IDs after expiry")
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

        def single_map():
            maps = [e for e in state() if e.get("subrole") == "AXMapArea"]
            assert len(maps) == 1, f"Expected one map, found {len(maps)}"

        single_map()
        timeline = [e for e in state() if e.get("type") == "Button"
                    and re.search(r"\d{1,2}:\d{2}:\d{2}", e.get("AXLabel") or "")
                    and 0 <= e["frame"]["x"] < 300]
        assert timeline, "No recorded points in trip timeline"
        frame = timeline[0]["frame"]
        ui("tap", str(round(frame["x"] + frame["width"] / 2)), str(round(frame["y"] + frame["height"] / 2)))
        wait_for(lambda: find("Trip point"), "Historical trip marker missing")
        assert find("Live", "Button"), "Historical selection did not offer return to Live"
        tap("Tracker")
        single_map()
        assert find("Stop Tracking", "Button")
        assert not find("Trip point"), "Trip marker remained on Tracker"
        tap("Trip")
        single_map()
        assert find("Trip point"), "Tab switch lost the selected trip point"
        tap("Live")
        wait_for(lambda: find("Current location"), "Live did not restore user location")
        assert not find("Trip point"), "Live left historical marker visible"
        checks.append("One map switches panels and preserves trip timeline selection")

        # Keep longitude constant so the marker's horizontal position tests the camera.
        if route.poll() is None:
            route.terminate()
            route.wait(timeout=5)
        route = subprocess.Popen(["xcrun", "simctl", "location", udid, "start", "--speed=0.1", "--interval=1",
                                  "45.5182,-122.6724", "45.5183,-122.6724"],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        tap("Tracker")
        wait_for(lambda: find("45.5182, -122.6724"), "Tracker did not display the injected location")
        checks.append("Tracker displays the updated simulator coordinates")
        tap("Trip")
        tap("Show My Location")
        ui("swipe", "180", "260", "260", "260", "--duration", "0.6")
        time.sleep(1)
        marker = find("Current location")
        assert marker, "Current location missing after short pan"
        pan_x = marker["frame"]["x"]
        tap("Tracker")
        tap("Trip")
        single_map()
        marker = find("Current location")
        assert marker and abs(marker["frame"]["x"] - pan_x) < 8, "Tab switch reset the panned map"
        checks.append("Switching Tracker and Trip preserves the panned map position")

        tap("Stop Trip")
        wait_for(lambda: find("Start Trip", "Button"), "Trip did not end")
        tap("Tracker")
        assert find("Stop Tracking", "Button"), "Trip did not restore earlier tracking state"
        tap("Stop Tracking")
        tap("Stop Tracking", last=True)
        wait_for(lambda: find("Start Tracking", "Button"), "Confirmed stop did not stop tracking")
        checks.append("Ending trip restores tracking; explicit stop confirmation stops it")
        environment = dict(os.environ, SIM="Overland Fake Route", SIM_UDID=udid,
                           IDB_COMPANION=f"localhost:{port}", CAPTURE_SCREENSHOTS="0")
        subprocess.run(["python3", str(Path(__file__).with_name("idb_ui_test.py"))],
                       env=environment, check=True, timeout=240)
        checks.append("Settings navigation and exact numeric editing pass; the edited value is restored")
        subprocess.run(["python3", str(Path(__file__).with_name("ui_layout_audit.py")), udid,
                        "--output", str(args.output.with_suffix(".layout.json"))],
                       env=environment, check=True, timeout=600)
        checks.append("Panel, tab gestures, Settings clearance, and accessibility text checks pass")
        completed = True
        print("PASS: " + "; ".join(checks), flush=True)
    except Exception:
        if companion:
            try:
                args.output.with_suffix(".accessibility.json").write_text(json.dumps(state(), indent=2))
            except Exception:
                pass
        raise
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
        if runtime_stream:
            runtime_stream.terminate()
            try:
                runtime_stream.wait(timeout=5)
            except subprocess.TimeoutExpired:
                runtime_stream.kill()
                runtime_stream.wait(timeout=5)
        if runtime_log:
            runtime_log.close()
        server.shutdown()
        server.server_close()
        subprocess.run(["xcrun", "simctl", "shutdown", udid], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if completed or not args.keep_on_failure:
            subprocess.run(["xcrun", "simctl", "delete", udid], check=True)
            print(f"Removed isolated simulator; results: {args.output}", flush=True)
        else:
            print(f"Kept stopped diagnostic simulator {udid}; results: {args.output}", flush=True)


if __name__ == "__main__":
    main()
