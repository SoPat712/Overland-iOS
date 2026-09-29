#!/usr/bin/env python3
"""Replace only tagged replay-demo rows in one simulator's local history store."""

import argparse
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import sqlite3
import subprocess


BUNDLE = "com.aaronpk.overland"
DEMO_DEVICE = "Simulator demo · not sent"
ROUTE = Path(__file__).parent / "fixtures" / "portland_salem_route.json"


def simctl(*args):
    return subprocess.check_output(["xcrun", "simctl", *args], text=True).strip()


def is_demo(payload):
    try:
        return json.loads(payload).get("properties", {}).get("device_id") == DEMO_DEVICE
    except (TypeError, ValueError, AttributeError):
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("udid", help="UDID of the booted iOS simulator to seed")
    args = parser.parse_args()

    devices = json.loads(simctl("list", "devices", "-j"))["devices"]
    device = next((item for group in devices.values() for item in group
                   if item["udid"] == args.udid), None)
    if not device or device["state"] != "Booted" or not device["name"].startswith("iPhone"):
        parser.error("Supply the UDID of a booted iPhone simulator")

    route = json.loads(ROUTE.read_text())
    points = route["points"]
    if not points or max(point["speed_mps"] for point in points) * 2.23694 < 50:
        parser.error("The fixture needs a driving route with speeds reaching 50 mph")

    subprocess.run(["xcrun", "simctl", "terminate", args.udid, BUNDLE],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    container = Path(simctl("get_app_container", args.udid, BUNDLE, "data"))
    database = container / "Library" / "Application Support" / "Recent Locations" / "history.sqlite"
    if not database.is_file():
        parser.error("Launch Overland once to create its replay history database")

    end = datetime.now(timezone.utc) - timedelta(minutes=5)
    start = end - timedelta(seconds=route["duration_seconds"])
    with sqlite3.connect(database) as connection:
        rows = connection.execute("SELECT id, payload FROM points").fetchall()
        demo_ids = [(row_id,) for row_id, payload in rows if is_demo(payload)]
        connection.executemany("DELETE FROM points WHERE id = ?", demo_ids)
        for point in points:
            recorded = start + timedelta(seconds=point["elapsed_seconds"])
            payload = {
                "type": "Feature",
                "geometry": {"type": "Point", "coordinates": [point["longitude"], point["latitude"]]},
                "properties": {
                    "timestamp": recorded.strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "speed": point["speed_mps"],
                    "horizontal_accuracy": 5,
                    "device_id": DEMO_DEVICE,
                },
            }
            connection.execute(
                "INSERT INTO points (timestamp, latitude, longitude, format, payload) VALUES (?, ?, ?, 0, ?)",
                (recorded.timestamp(), point["latitude"], point["longitude"],
                 json.dumps(payload, separators=(",", ":")).encode()),
            )

    simctl("launch", args.udid, BUNDLE)
    print(f"Loaded {len(points)} local demo points; replaced {len(demo_ids)} previous demo points")
    print(f"{route['name']}: {route['distance_meters'] / 1609.344:.1f} miles; "
          f"maximum modeled speed {max(point['speed_mps'] for point in points) * 2.23694:.0f} mph")
    print("No location was added to the upload queue.")


if __name__ == "__main__":
    main()
