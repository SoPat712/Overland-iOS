"""Read visible content and native navigation omitted by IDB's default reader."""
import json


TAB_LABELS = ("Tracker", "Trip", "Settings")


def read_state(ui):
    elements = json.loads(ui("describe-all"))
    bridge = json.loads(ui("describe-all", "--api", "axbridge"))
    app_pid = elements[0].get("pid") if elements else None
    bars = [e["frame"] for e in bridge
            if e.get("type") == "NavigationBar" and e.get("pid") == app_pid
            and e["frame"]["height"] > 0][-1:]
    has_tabs = any(e.get("AXLabel") == "Tab Bar" for e in elements)
    present = {(e.get("type"), e.get("AXLabel")) for e in elements}

    # The alternate reader includes clipped content; merge only native navigation.
    for element in bridge:
        label = element.get("AXLabel")
        kind = element.get("type")
        if not label or element.get("pid") != app_pid or (kind, label) in present:
            continue
        f = element["frame"]
        in_bar = kind in ("Button", "StaticText", "Heading") and any(
            f["x"] >= bar["x"] and f["y"] >= bar["y"]
            and f["x"] + f["width"] <= bar["x"] + bar["width"]
            and f["y"] + f["height"] <= bar["y"] + bar["height"]
            for bar in bars)
        if in_bar or (has_tabs and kind == "Button" and label in TAB_LABELS):
            elements.append(element)
            present.add((kind, label))
    return elements
