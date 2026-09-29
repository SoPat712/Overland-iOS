#!/usr/bin/env python3
"""Verify layout, navigation and numeric slider editing without changing tracking."""
import json
import os
from pathlib import Path
import subprocess
import time

from ui_accessibility import read_state

root = Path(__file__).resolve().parent.parent
sim = os.environ.get("SIM", "iPhone 17 Pro")
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
requested_udid = os.environ.get("SIM_UDID")
matches = [d for group in devices["devices"].values() for d in group
           if d["state"] == "Booted"
           and (d["udid"] == requested_udid if requested_udid else d["name"] == sim)]
if len(matches) != 1:
    raise SystemExit("Select one booted simulator with SIM_UDID or SIM")
udid = matches[0]["udid"]
base = ["idb", "--companion", os.environ.get("IDB_COMPANION", "localhost:10882")]
shots = root / "Screenshots"
capture_screenshots = os.environ.get("CAPTURE_SCREENSHOTS") == "1"
if capture_screenshots:
    shots.mkdir(exist_ok=True)


def run(*args):
    return subprocess.check_output(base + list(args) + ["--udid", udid], text=True, timeout=20)


def state():
    return read_state(lambda *parts: run("ui", *parts))


def element(label, kind=None):
    matches = [e for e in state() if e.get("AXLabel") == label and (not kind or e.get("type") == kind)]
    if len(matches) != 1:
        raise AssertionError(f"Expected one {kind or 'element'} named {label}: {len(matches)}")
    return matches[0]


def tap(label, kind="Button"):
    time.sleep(0.5)
    f = element(label, kind)["frame"]
    if not (60 <= f["y"] and f["y"] + f["height"] <= 860):
        raise AssertionError(f"{label} is outside the visible screen: {f}")
    run("ui", "tap", str(round(f["x"] + f["width"] / 2)), str(round(f["y"] + f["height"] / 2)))
    time.sleep(0.7)


def shot(name):
    if capture_screenshots:
        run("screenshot", str(shots / name))


subprocess.run(["xcrun", "simctl", "terminate", udid, "com.aaronpk.overland"], capture_output=True)
subprocess.check_call(["xcrun", "simctl", "launch", udid, "com.aaronpk.overland"])
time.sleep(3)
run("focus")
controls = element("Send Now", "Button")["frame"]
tab = element("Tracker", "Button")["frame"]
assert controls["y"] + controls["height"] < tab["y"], "Send Now overlaps the tabs"
shot("verified_tracker.png")
tap("Controls panel")
tap("Trip")
element("Start Trip", "Button")
tap("Trip Settings")
element("Trip Settings", "Heading")
shot("verified_trip_settings.png")
tap("Settings")
assert not any(e.get("subrole") == "AXMapArea" for e in state()), "Settings exposes a map"
for _ in range(5):
    if any(e.get("AXLabel") == "Server" and e.get("type") == "Button" and 100 < e["frame"]["y"] < 650 for e in state()):
        break
    run("ui", "swipe", "70", "650", "70", "400", "--duration", "0.5")
    time.sleep(1)
tap("Server")
element("Add Header", "Button")
shot("verified_server.png")
# Reset navigation without touching preferences or recording state.
subprocess.check_call(["xcrun", "simctl", "terminate", udid, "com.aaronpk.overland"])
subprocess.check_call(["xcrun", "simctl", "launch", udid, "com.aaronpk.overland"])
time.sleep(2)
tap("Settings")
# Desired Accuracy is conditional on the preset, so use the always-present distance row.
for _ in range(5):
    if any(e.get("AXLabel") == "Edit Min Distance Between Points" and 120 < e["frame"]["y"] < 650 for e in state()):
        break
    run("ui", "swipe", "70", "680", "70", "430", "--duration", "0.7")
    time.sleep(1.5)
value_label = "Edit Min Distance Between Points"
original = element(value_label, "Button")["AXValue"]
original_number = "0" if original == "Off" else original.split()[0]
changed = False
try:
    tap(value_label)
    field = next(e for e in state() if e.get("type") == "TextField")["frame"]
    run("ui", "tap", str(round(field["x"] + 20)), str(round(field["y"] + field["height"] / 2)))
    run("ui", "key", "4", "--command")
    run("ui", "text", "25")
    tap("Save")
    changed = True
    assert element(value_label, "Button")["AXValue"] == "25 m"
    shot("verified_settings.png")
finally:
    if changed:
        tap(value_label)
        field = next(e for e in state() if e.get("type") == "TextField")["frame"]
        run("ui", "tap", str(round(field["x"] + 20)), str(round(field["y"] + field["height"] / 2)))
        run("ui", "key", "4", "--command")
        run("ui", "text", original_number)
        tap("Save")
assert element(value_label, "Button")["AXValue"] == original
tap("Tracker")
print("PASS: controls clear tab bar; Trip Settings and Server navigation; exact slider entry and restoration")
