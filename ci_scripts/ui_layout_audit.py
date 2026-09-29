#!/usr/bin/env python3
"""Check navigation and layout on a disposable simulator without screenshots."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time

from ui_accessibility import read_state


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT, timeout=30)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("udid")
    parser.add_argument("--output", type=Path, default=Path("/tmp/overland-ui-layout.json"))
    parser.add_argument("--start-at", choices=("tabs", "forms", "server"), default="tabs",
                        help="Resume after earlier checks have passed")
    args = parser.parse_args()
    devices = json.loads(run("xcrun", "simctl", "list", "devices", "-j"))["devices"]
    device = next(d for group in devices.values() for d in group if d["udid"] == args.udid)
    if device["name"] not in ("Overland Fake Route", "Overland UI Audit"):
        parser.error("Use a disposable Overland Fake Route or Overland UI Audit simulator")
    base = ["idb"]
    if os.environ.get("IDB_COMPANION"):
        base += ["--companion", os.environ["IDB_COMPANION"]]
    checks = []

    def ui(*parts):
        return run(*base, "ui", *parts, "--udid", args.udid)

    def state():
        return read_state(ui)

    def find(label, kind=None):
        return next((e for e in state() if (e.get("AXLabel") == label
                     or (kind == "TextField" and not e.get("AXLabel") and e.get("AXValue") == label))
                     and (kind is None or e.get("type") == kind)), None)

    def frame(label, kind=None):
        element = find(label, kind)
        assert element, f"Missing {kind or 'element'}: {label}"
        return element["frame"]

    def center(label, kind=None):
        f = frame(label, kind)
        return round(f["x"] + f["width"] / 2), round(f["y"] + f["height"] / 2)

    def tap(label, kind="Button"):
        x, y = center(label, kind)
        ui("tap", str(x), str(y))
        time.sleep(0.7)

    def swipe(start, end):
        ui("swipe", *map(str, (*start, *end)), "--duration", "0.65")
        time.sleep(0.8)

    def selected(label):
        tabs = [e for e in state() if e.get("AXLabel") in ("Tracker", "Trip", "Settings")
                and e.get("type") == "Button"]
        assert len(tabs) == 3, f"Expected three tabs: {len(tabs)}"
        elements = state()
        has_map = any(e.get("subrole") == "AXMapArea" for e in elements)
        has_trip_controls = any(e.get("AXLabel") == "Trip Settings" and e.get("type") == "Button"
                                for e in elements)
        if label == "Settings":
            assert not has_map and not find("Controls panel"), "Settings did not replace the map page"
        else:
            assert has_map, f"{label} map is missing"
            assert has_trip_controls == (label == "Trip"), f"Wrong controls for {label}"

    def scroll_to(label, kind=None, direction="up"):
        for _ in range(14):
            element = find(label, kind)
            tab_y = frame("Tracker", "Button")["y"]
            if element:
                f = element["frame"]
                if 70 < f["y"] and f["y"] + f["height"] < tab_y - 8:
                    return element
            x = round(frame("Tracker")["x"] + 20)
            if direction == "down" or (element and element["frame"]["y"] <= 70):
                swipe((x, 180), (x, 440))
            else:
                swipe((x, round(tab_y - 80)), (x, round(tab_y - 340)))
        raise AssertionError(f"Could not scroll {label} clear of tab bar")

    def record(message):
        checks.append(message)
        print(message, flush=True)

    original_size = run("xcrun", "simctl", "ui", args.udid, "content_size").strip()
    original_appearance = run("xcrun", "simctl", "ui", args.udid, "appearance").strip()
    try:
        for _ in range(20):
            if find("Settings", "Button"):
                break
            time.sleep(0.5)
        if args.start_at == "tabs":
            tap("Tracker")
            selected("Tracker")
            baseline = {label: frame(label) for label in ("Tracker", "Trip", "Settings")}
            expanded_top = frame("Controls panel")["y"]
            tap("Controls panel")
            compact = frame("Controls panel")
            assert compact["height"] >= 20, "Grabber hit area is too small"
            assert compact["width"] <= 272, "Folded panel is too wide"
            tab_span = frame("Settings")["x"] + frame("Settings")["width"] - frame("Tracker")["x"]
            assert 0 <= compact["width"] - tab_span <= 8, "Folded panel does not closely fit the tabs"
            overlap = compact["y"] + compact["height"] - frame("Trip")["y"]
            assert -2 <= overlap <= 8, "Grabber does not meet the native tab bar"
            assert frame("Trip")["y"] - compact["y"] <= 24, "Grabber sits too far above the native bar"
            for label, before in baseline.items():
                after = frame(label)
                assert all(abs(before[axis] - after[axis]) < 1 for axis in ("x", "y", "width", "height")), f"{label} moved on collapse"
            time.sleep(2)
            assert find("Controls panel")["AXValue"] == "Collapsed", "Status refresh reopened the panel"
            start = center("Controls panel")
            swipe(start, (start[0], start[1] - 45))
            assert abs(frame("Controls panel")["y"] - compact["y"]) < 1, "Short upward drag did not settle closed"
            start = center("Controls panel")
            travel = compact["y"] - expanded_top
            swipe(start, (start[0], round(start[1] - travel * 0.7)))
            selected("Tracker")
            assert find("Send Now", "Button"), "Vertical drag did not reopen panel"
            expanded = frame("Controls panel")
            start = center("Controls panel")
            swipe(start, (start[0], start[1] + 45))
            assert abs(frame("Controls panel")["y"] - expanded["y"]) < 1, "Short downward drag did not settle open"
            record("Panel expansion keeps all tab frames fixed and leaves selection unchanged")

            for destination in ("Settings", "Tracker", "Trip", "Settings", "Trip", "Tracker"):
                tap(destination)
                selected(destination)
            record("Direct tab taps work between every pair of pages")

            swipe(center("Tracker"), center("Settings"))
            selected("Settings")
            swipe(center("Settings"), center("Tracker"))
            selected("Tracker")
            # Begin on an unselected tab to catch coordinate calculations anchored to selection.
            swipe(center("Trip"), center("Settings"))
            selected("Settings")
            record("Horizontal scrub works in both directions and from an unselected tab")

            assert not find("Controls panel"), "Settings exposes the map panel"
            assert not any(e.get("subrole") == "AXMapArea" for e in state()), "Settings exposes a map"
            scroll_to("Privacy Policy")
            record("Last Settings row scrolls above the shared bar")

        if args.start_at != "server":
            tap("Settings")
            scroll_to("WiFi Zones", "Button")
            tap("WiFi Zones")
            assert find("WiFi Zones", "Heading") or find("WiFi Zones", "StaticText"), "WiFi navigation title is missing"
            tap("Add Zone")
            assert find("Add Zone", "Heading") or find("Add Zone", "StaticText"), "WiFi zone form did not open"
            assert find("Latitude", "TextField") and find("Longitude", "TextField")
            tap("Cancel")
            tap("Settings")
            scroll_to("About Usage Presets", "Button", direction="down")
            tap("About Usage Presets")
            assert find("Done", "Button"), "Preset help did not open"
            tap("Done")
            record("WiFi navigation, zone form, and preset help open and dismiss")

        if args.start_at == "server":
            tap("Settings")
        scroll_to("Server", "Button")
        tap("Server")
        scroll_to("Clear Server URL", "Button")
        record("Last Server action scrolls clear of the shared bar")

        tap("Tracker")
        for appearance in ("dark", "light"):
            run("xcrun", "simctl", "ui", args.udid, "appearance", appearance)
            time.sleep(0.5)
            selected("Tracker")
            assert frame("Send Now")["y"] < frame("Tracker")["y"]
        record("Both appearance modes retain visible controls and tabs")

        run("xcrun", "simctl", "ui", args.udid, "content_size", "accessibility-extra-extra-extra-large")
        time.sleep(1)
        selected("Tracker")
        tab = frame("Tracker")
        assert tab["height"] >= 44 and tab["y"] > 0, "Large-text tabs are not usable"
        handle = frame("Controls panel")
        assert handle["y"] >= 60, "Large-text panel exceeds the top safe area"
        scroll_to("Send Now", "Button")
        tap("Trip")
        selected("Trip")
        scroll_to("Start Trip", "Button")
        record("Largest accessibility text keeps panel actions reachable")
    except Exception:
        args.output.with_suffix(".accessibility.json").write_text(json.dumps(state(), indent=2))
        raise
    finally:
        run("xcrun", "simctl", "ui", args.udid, "content_size", original_size)
        run("xcrun", "simctl", "ui", args.udid, "appearance", original_appearance)
        args.output.write_text(json.dumps({"checks": checks}, indent=2))


if __name__ == "__main__":
    main()
