#!/usr/bin/env python3
"""Drives Tessera on a real Mac with real apps and checks where every window ends up.

Used by CI (scripts/smoke-test.sh). Each check prints PASS, WARN or FAIL.
Expected frames are worked out here independently, from the screen's visible area.
"""
import json
import math
import os
import subprocess
import sys
import time

OUT = sys.argv[1] if len(sys.argv) > 1 else "ci-results"
KEYS = "/tmp/keys"
DUMP = "/tmp/tessera-dump.json"
results = []

# Key codes (US layout positions).
K = dict(left="0x7B", right="0x7C", down="0x7D", up="0x7E", ret="0x24", delete="0x33", esc="0x35",
         a="0x00", c="0x08", d="0x02", e="0x0E", f="0x03", g="0x05", i="0x22", j="0x26", k="0x28",
         l="0x25", m="0x2E", n="0x2D", t="0x11", u="0x20", w="0x0D", equal="0x18", minus="0x1B")
CO = "ctrl,opt"


# ---------- helpers ----------

def keys(*args):
    return subprocess.run([KEYS, *args], capture_output=True, text=True).stdout


def post(command, wait=0.8):
    keys("post", command)
    time.sleep(wait)


def press(mods, code, wait=0.7):
    if code in (K["left"], K["right"], K["up"], K["down"]):
        mods = (mods + ",fn,num").strip(",")
    keys("press", mods, code)
    time.sleep(wait)


def dump():
    try:
        os.remove(DUMP)
    except FileNotFoundError:
        pass
    keys("post", "dump")
    for _ in range(40):
        if os.path.exists(DUMP):
            time.sleep(0.2)
            with open(DUMP) as f:
                return json.load(f)
        time.sleep(0.2)
    return {}


def windows():
    try:
        return json.loads(keys("windows"))
    except json.JSONDecodeError:
        return {"windows": [], "frontPid": 0}


def front():
    data = windows()
    for win in data["windows"]:
        if win["pid"] == data["frontPid"]:
            return [round(v) for v in win["frame"]], win
    return None, None


def frame_of(window_id):
    for win in windows()["windows"]:
        if win["id"] == window_id:
            return [round(v) for v in win["frame"]]
    return None


def shot(name):
    subprocess.run(["screencapture", "-x", f"{OUT}/{name}.png"])


def record(name, ok, detail="", warn=False):
    status = "PASS" if ok else ("WARN" if warn else "FAIL")
    results.append((status, name, detail))
    print(f"{status} {name}" + (f"  ({detail})" if detail else ""), flush=True)


def close(a, b, tol=1):
    return a is not None and b is not None and all(abs(x - y) <= tol for x, y in zip(a, b))


def rnd(v):
    return math.floor(v + 0.5)   # Swift's .rounded() for positive numbers


def part(vis, x, y, w, h):
    vx, vy, vw, vh = vis
    left, right = rnd(vx + vw * x), rnd(vx + vw * (x + w))
    top, bottom = rnd(vy + vh * y), rnd(vy + vh * (y + h))
    return [left, top, right - left, bottom - top]


def gapped(rect, vis, gap):
    x, y, w, h = rect
    vx, vy, vw, vh = vis
    def inset(on_border):
        return gap if on_border else gap / 2
    left = rnd(x + inset(abs(x - vx) < 1))
    right = rnd(x + w - inset(abs(x + w - (vx + vw)) < 1))
    top = rnd(y + inset(abs(y - vy) < 1))
    bottom = rnd(y + h - inset(abs(y + h - (vy + vh)) < 1))
    return [left, top, right - left, bottom - top]


def overlap(a, b):
    w = min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0])
    h = min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1])
    return max(0, w) * max(0, h)


def inside(r, vis, tol=1):
    return (r[0] >= vis[0] - tol and r[1] >= vis[1] - tol and
            r[0] + r[2] <= vis[0] + vis[2] + tol and r[1] + r[3] <= vis[1] + vis[3] + tol)


def snap_check(label, mods, code, expect, tol=1, warn=False):
    press(mods, code)
    got, _ = front()
    record(label, close(got, expect, tol), f"got {got}, want {expect}", warn=warn)
    return got


def run_check(label, command, expect, tol=1, warn=False):
    post("run:" + command)
    got, _ = front()
    record(label, close(got, expect, tol), f"got {got}, want {expect}", warn=warn)


# ---------- auto-tile checks ----------

def check_tiling(label, strict=True, ignore=()):
    """Every visible normal window is tiled, inside the screen, not overlapping, and not hidden."""
    time.sleep(1.6)
    d = dump()
    vis = d["displays"][0]["visible"]
    standard = [w for w in d["windows"] if w["standard"] and w["id"] not in ignore]
    tiled = [w for w in standard if w["tiled"]]
    record(f"{label}: all {len(standard)} windows tiled", len(tiled) == len(standard),
           f"tiled {len(tiled)} of {len(standard)}: " + ", ".join(w["app"] for w in standard if not w["tiled"]))
    cg = {w["id"]: [round(v) for v in w["frame"]] for w in windows()["windows"]}
    frames = {w["id"]: cg.get(w["id"], w["frame"]) for w in tiled}
    outside = [w["app"] for w in tiled if not inside(frames[w["id"]], vis)]
    record(f"{label}: all inside the screen", not outside, ", ".join(outside))
    pairs = []
    ids = list(frames)
    for i, a in enumerate(ids):
        for b in ids[i + 1:]:
            area = overlap(frames[a], frames[b])
            if area > 4:
                pairs.append(f"{a}/{b} {area}px²")
    record(f"{label}: no overlaps", not pairs, "; ".join(pairs), warn=not strict)
    # Hidden check: how much of each tiled window is not covered by windows above it.
    order = [w["id"] for w in windows()["windows"]]
    for w in tiled:
        r = frames[w["id"]]
        above = [frames[o] for o in order[:order.index(w["id"])] if o in frames] if w["id"] in order else []
        covered = sum(overlap(r, a) for a in above)
        share = 1 - min(1, covered / max(1, r[2] * r[3]))
        if share < 0.3:
            record(f"{label}: {w['app']} {w['id']} is visible", False, f"only {share:.0%} visible")
    shot("tile-" + label.lower().replace(" ", "-").replace("+", "plus").replace(",", ""))
    return d, frames


# ---------- the tests ----------

def main():
    os.makedirs(OUT, exist_ok=True)
    d = dump()
    if not d:
        record("Tessera answers test commands", False, "no dump")
        return
    with open(f"{OUT}/dump-start.json", "w") as f:
        json.dump(d, f, indent=1)
    record("Accessibility allowed", d.get("trusted") is True)
    record("All shortcuts registered", not d.get("failedShortcuts"), ", ".join(d.get("failedShortcuts", [])))
    V = d["displays"][0]["visible"]
    print("visible frame:", V, flush=True)
    F = lambda x, y, w, h: part(V, x, y, w, h)

    # --- Snapping with the keyboard, TextEdit ---
    keys("activate", "com.apple.TextEdit")
    start, _ = front()
    print("TextEdit starts at", start, flush=True)
    snap_check("TextEdit ⌃⌥← Left Half", CO, K["left"], F(0, 0, .5, 1))
    snap_check("TextEdit ⌃⌥← again: two thirds", CO, K["left"], F(0, 0, 2 / 3, 1))
    snap_check("TextEdit ⌃⌥← third time: one third", CO, K["left"], F(0, 0, 1 / 3, 1))
    snap_check("TextEdit ⌃⌥→ Right Half", CO, K["right"], F(.5, 0, .5, 1))
    snap_check("TextEdit ⌃⌥↑ Top Half", CO, K["up"], F(0, 0, 1, .5))
    snap_check("TextEdit ⌃⌥↓ Bottom Half", CO, K["down"], F(0, .5, 1, .5))
    snap_check("TextEdit ⌃⌥U Top Left", CO, K["u"], F(0, 0, .5, .5))
    snap_check("TextEdit ⌃⌥I Top Right", CO, K["i"], F(.5, 0, .5, .5))
    snap_check("TextEdit ⌃⌥J Bottom Left", CO, K["j"], F(0, .5, .5, .5))
    snap_check("TextEdit ⌃⌥K Bottom Right", CO, K["k"], F(.5, .5, .5, .5))
    snap_check("TextEdit ⌃⌥D First Third", CO, K["d"], F(0, 0, 1 / 3, 1))
    snap_check("TextEdit ⌃⌥F Centre Third", CO, K["f"], F(1 / 3, 0, 1 / 3, 1))
    snap_check("TextEdit ⌃⌥G Last Third", CO, K["g"], F(2 / 3, 0, 1 / 3, 1))
    snap_check("TextEdit ⌃⌥E First Two Thirds", CO, K["e"], F(0, 0, 2 / 3, 1))
    snap_check("TextEdit ⌃⌥T Last Two Thirds", CO, K["t"], F(1 / 3, 0, 2 / 3, 1))
    snap_check("TextEdit ⌃⌥↩ Maximise", CO, K["ret"], F(0, 0, 1, 1))
    snap_check("TextEdit ⌃⌥⌫ Restore", CO, K["delete"], start)

    cur, _ = front()
    w, h = cur[2], cur[3]
    centred = [rnd(V[0] + V[2] / 2 - w / 2), rnd(V[1] + V[3] / 2 - h / 2), w, h]
    snap_check("TextEdit ⌃⌥C Centre", CO, K["c"], centred)
    snap_check("TextEdit ⌃⌥= Make Larger", CO, K["equal"], [centred[0] - 30, centred[1] - 30, w + 60, h + 60])
    snap_check("TextEdit ⌃⌥- Make Smaller", CO, K["minus"], centred)
    snap_check("TextEdit ⌃⌥⇧↑ Maximise Height", "ctrl,opt,shift", K["up"], [centred[0], V[1], w, V[3]])
    run_check("TextEdit Almost Maximise", "snap.almostMaximise", F(.05, .05, .9, .9))
    run_check("TextEdit Centre Half", "snap.centreHalf", F(.25, 0, .5, 1))
    run_check("TextEdit Centre Two Thirds", "snap.centreTwoThirds", F(1 / 6, 0, 2 / 3, 1))
    run_check("TextEdit Top Left Sixth", "snap.topLeftSixth", F(0, 0, 1 / 3, .5))
    run_check("TextEdit Bottom Right Sixth", "snap.bottomRightSixth", F(2 / 3, .5, 1 / 3, .5))
    run_check("TextEdit First Three Quarters", "snap.firstThreeQuarters", F(0, 0, .75, 1))
    run_check("TextEdit Last Quarter", "snap.lastQuarter", F(.75, 0, .25, 1), warn=True)
    snap_check("TextEdit Restore after many snaps", CO, K["delete"], start)
    run_check("TextEdit Move Right (keeps size)", "snap.moveRight", [V[0] + V[2] - start[2], start[1], start[2], start[3]])
    run_check("TextEdit Move Up", "snap.moveUp", [V[0] + V[2] - start[2], V[1], start[2], start[3]])
    snap_check("TextEdit Restore after moving", CO, K["delete"], start)

    post("set:gap=10")
    snap_check("TextEdit Left Half with a 10 pt gap", CO, K["left"], gapped(F(0, 0, .5, 1), V, 10))
    snap_check("TextEdit Right Half with a 10 pt gap", CO, K["right"], gapped(F(.5, 0, .5, 1), V, 10))
    post("set:gap=0")
    snap_check("TextEdit Restore", CO, K["delete"], start)

    # --- Other apps ---
    for bundle, name in [("com.apple.finder", "Finder"), ("com.apple.Safari", "Safari"), ("com.google.Chrome", "Chrome")]:
        keys("activate", bundle)
        time.sleep(0.5)
        first, win = front()
        if not win:
            record(f"{name} has a window in front", False)
            continue
        snap_check(f"{name} Left Half", CO, K["left"], F(0, 0, .5, 1))
        snap_check(f"{name} Right Half", CO, K["right"], F(.5, 0, .5, 1))
        snap_check(f"{name} Top Left", CO, K["u"], F(0, 0, .5, .5), warn=True)
        snap_check(f"{name} Maximise", CO, K["ret"], F(0, 0, 1, 1))
        snap_check(f"{name} Restore", CO, K["delete"], first, tol=2)

    # --- Drag to a screen edge ---
    keys("activate", "com.apple.TextEdit")
    cur, _ = front()
    grab = (cur[0] + 100, cur[1] + 12)
    mid_y = V[1] + V[3] // 2
    keys("drag", str(grab[0]), str(grab[1]), "1", str(mid_y))
    time.sleep(0.8)
    got, _ = front()
    record("Drag TextEdit to the left edge: Left Half", close(got, F(0, 0, .5, 1)), f"got {got}")
    keys("drag", str(got[0] + 100), str(got[1] + 12), str(V[0] + V[2] // 2), str(V[1] + 150))
    time.sleep(0.8)
    got, _ = front()
    record("Drag it out again: old size back", got is not None and abs(got[2] - start[2]) <= 2 and abs(got[3] - start[3]) <= 2,
           f"got {got}, start {start}")
    keys("drag", str(got[0] + 100), str(got[1] + 12), str(V[0] + V[2] // 2), "1")
    time.sleep(0.8)
    got, _ = front()
    record("Drag TextEdit to the top edge: Maximise", close(got, F(0, 0, 1, 1)), f"got {got}")
    keys("drag", str(got[0] + 100), str(got[1] + 12), str(V[0] + V[2] - 2), str(mid_y))
    time.sleep(0.8)
    got, _ = front()
    record("Drag TextEdit to the right edge: Right Half", close(got, F(.5, 0, .5, 1)), f"got {got}")
    press(CO, K["delete"])

    # --- Menu and Settings ---
    post("menu", 1.5)
    shot("menu")
    press("", K["esc"], 0.5)
    post("settings", 2.0)
    shot("settings")
    post("close-settings", 0.5)

    # --- Auto-tile ---
    post("set:autoTile=1", 0.5)
    d, _ = check_tiling("Auto, 5 windows")
    for style in ["columns", "rows", "grid", "mainAndSide", "auto"]:
        post(f"set:layout={style}", 0.3)
        check_tiling(f"{style}", strict=style in ("auto", "grid", "columns", "mainAndSide"))

    keys("activate", "com.apple.TextEdit")
    keys("press", "cmd", K["n"])
    d, _ = check_tiling("Auto after a new window")
    keys("activate", "com.apple.TextEdit")
    keys("press", "cmd", K["w"])
    check_tiling("Auto after closing it")

    # Swap with main.
    keys("activate", "com.apple.Safari")
    press(CO, K["m"], 1.2)
    d = dump()
    order = list(d["autoTile"]["order"].values())[0] if d["autoTile"]["order"] else []
    record("⌃⌥M puts Safari in the main spot", bool(order) and order[0] == d["focused"], f"order {order}, focused {d['focused']}")

    # Snap by hand while tiling: Chrome takes the left half, the rest share the right half.
    keys("activate", "com.google.Chrome")
    chrome = snap_check("Auto-tile: Chrome ⌃⌥← keeps the left half", CO, K["left"], F(0, 0, .5, 1))
    _, cw = front()
    d, frames = check_tiling("Others fill the right half", ignore=(cw["id"],) if cw else ())
    right = [r for r in frames.values() if r[0] < V[0] + V[2] / 2 - 2]
    record("Tiles stay out of Chrome's half", not right, f"{right}")
    keys("activate", "com.google.Chrome")
    press(CO, K["delete"], 1.0)
    d, _ = check_tiling("⌃⌥⌫ puts Chrome back")

    # Float and tile again.
    keys("activate", "com.apple.TextEdit")
    press(CO, K["w"], 1.2)
    d = dump()
    record("⌃⌥W floats the window", d["focused"] in d["autoTile"]["floating"], f"floating {d['autoTile']['floating']}")
    check_tiling("Others retile around the floating window", ignore=(d["focused"],))
    press(CO, K["w"], 1.2)
    check_tiling("⌃⌥W tiles it again")

    # Drag one tile onto another to swap them. TextEdit's title bar is safe to grab
    # (Chrome's would pull out a tab).
    d = dump()
    tiled = {w["id"] for w in d["windows"] if w["tiled"]}
    textedit = [w["id"] for w in windows()["windows"] if w["owner"] == "TextEdit" and w["id"] in tiled]
    others = [i for i in tiled if i not in textedit]
    if textedit and others:
        a, b = textedit[0], others[0]
        fa, fb = frame_of(a), frame_of(b)
        keys("drag", str(fa[0] + 100), str(fa[1] + 12), str(fb[0] + fb[2] // 2), str(fb[1] + fb[3] // 2))
        time.sleep(1.5)
        record("Drag a tile onto another: they swap", close(frame_of(a), fb, 3) and close(frame_of(b), fa, 3),
               f"a {frame_of(a)} want {fb}; b {frame_of(b)} want {fa}")

    # Next layout and switching off.
    press(CO, K["l"], 1.2)
    d = dump()
    record("⌃⌥L switches to the next layout", "columns" in d["layouts"].values(), f"{d['layouts']}")
    check_tiling("columns via ⌃⌥L")
    press(CO, K["a"], 1.0)
    d = dump()
    record("⌃⌥A turns auto-tile off", d["autoTileSetting"] is False)
    with open(f"{OUT}/dump-end.json", "w") as f:
        json.dump(d, f, indent=1)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:  # Keep going so the results still get saved.
        import traceback
        traceback.print_exc()
        record("Test script finished", False, repr(error))
    fails = [r for r in results if r[0] == "FAIL"]
    warns = [r for r in results if r[0] == "WARN"]
    with open(f"{OUT}/results.txt", "w") as f:
        f.write(f"{len(results) - len(fails) - len(warns)} passed, {len(warns)} warnings, {len(fails)} failed\n\n")
        for status, name, detail in results:
            f.write(f"{status} {name}" + (f"  ({detail})" if detail else "") + "\n")
    print(open(f"{OUT}/results.txt").read().splitlines()[0])
    sys.exit(1 if fails else 0)
