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
    try:
        return subprocess.run([KEYS, *args], capture_output=True, text=True, timeout=20).stdout
    except subprocess.TimeoutExpired:
        print("timed out: keys", *args, flush=True)
        return ""


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


def activate(bundle):
    """Bring an app forward and wait until macOS says it's in front."""
    keys("activate", bundle)
    for _ in range(20):
        if windows().get("frontApp") == bundle:
            time.sleep(0.2)
            return True
        time.sleep(0.2)
    print("could not bring forward:", bundle, flush=True)
    return False


def frame_of(window_id):
    for win in windows()["windows"]:
        if win["id"] == window_id:
            return [round(v) for v in win["frame"]]
    return None


def shot(name):
    try:
        subprocess.run(["screencapture", "-x", f"{OUT}/{name}.png"], timeout=20)
    except subprocess.TimeoutExpired:
        print("timed out: screenshot", name, flush=True)


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
    """Points two windows share. A sliver of 8 points or less doesn't count: some apps
    (Terminal, Chrome) round their size to whole characters or even numbers."""
    w = min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0])
    h = min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1])
    if w <= 8 or h <= 8:
        return 0
    return w * h


def inside(r, vis, tol=1):
    return (r[0] >= vis[0] - tol and r[1] >= vis[1] - tol and
            r[0] + r[2] <= vis[0] + vis[2] + tol and r[1] + r[3] <= vis[1] + vis[3] + tol)


def fits_or_minimum(got, want, vis, tol=1):
    """Right spot, or as close as the app allows: bigger than asked (its minimum size),
    still on screen, and lined up with the same screen edge."""
    if got is None:
        return False
    for start, size in ((0, 2), (1, 3)):
        g0, g1 = got[start], got[start] + got[size]
        w0, w1 = want[start], want[start] + want[size]
        if abs(g0 - w0) <= tol and abs(g1 - w1) <= tol:
            continue
        if got[size] > want[size] and (abs(g0 - w0) <= tol or abs(g1 - w1) <= tol) and inside(got, vis, tol):
            continue
        return False
    return True


VISIBLE = [0, 0, 0, 0]


def snap_check(label, mods, code, expect, tol=1, warn=False, allow_minimum=False):
    press(mods, code)
    got, win = front()
    ok = close(got, expect, tol) or (allow_minimum and fits_or_minimum(got, expect, VISIBLE, tol))
    note = "" if close(got, expect, tol) else " (app minimum size)"
    detail = f"got {got}, want {expect}{note if ok else ''}"
    if not ok:
        # Find out why: what was in front, what Tessera thought was in front, and a second try.
        shot("fail-" + "".join(c if c.isalnum() else "-" for c in label))
        d = dump()
        detail += f"; front app {windows().get('frontApp')}, front window {win and win['id']}, Tessera's focused window {d.get('focused')}"
        press(mods, code)
        again, _ = front()
        detail += f"; a second press gave {again}"
    record(label, ok, detail, warn=warn)
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
    crowded = bool(d["autoTile"].get("crowded"))
    record(f"{label}: no overlaps", not pairs, "; ".join(pairs) + (" — apps' minimum sizes can't all fit" if crowded else ""),
           warn=(not strict) or crowded)
    # Hidden check: how much of each tiled window is not covered by windows above it.
    order = [w["id"] for w in windows()["windows"]]
    for w in tiled:
        r = frames[w["id"]]
        above = [frames[o] for o in order[:order.index(w["id"])] if o in frames] if w["id"] in order else []
        covered = sum(overlap(r, a) for a in above)
        share = 1 - min(1, covered / max(1, r[2] * r[3]))
        if share < 0.3:
            record(f"{label}: {w['app']} {w['id']} is visible", False, f"only {share:.0%} visible", warn=crowded)
    shot("tile-" + label.lower().replace(" ", "-").replace("+", "plus").replace(",", ""))
    return d, frames



# ---------- layout shape checks ----------

STYLES = ["auto", "columns", "rows", "grid", "mainAndSide"]
STYLE_NAMES = {"auto": "Auto", "columns": "Columns", "rows": "Rows", "grid": "Grid", "mainAndSide": "Main + Side"}
DIGIT = {"auto": "0x12", "columns": "0x13", "rows": "0x14", "grid": "0x15", "mainAndSide": "0x17"}


def screen_plan(d):
    plans = (d or {}).get("autoTile", {}).get("plans", {})
    return next(iter(plans.values()), None) if plans else None


def near(a, b, tol=1):
    return abs(a - b) <= tol


def stacked(frames, axis, start, end):
    """Frames sit one after another along an axis (0 = x, 1 = y), from start to end, in order."""
    problems = []
    if not near(frames[0][axis], start):
        problems.append(f"first one starts at {frames[0][axis]}, not {start}")
    for a, b in zip(frames, frames[1:]):
        if not near(a[axis] + a[axis + 2], b[axis]):
            problems.append(f"gap or overlap between {a} and {b}")
    if not near(frames[-1][axis] + frames[-1][axis + 2], end):
        problems.append(f"last one ends at {frames[-1][axis] + frames[-1][axis + 2]}, not {end}")
    return problems


def shape_problems(style, frames, area):
    """What is wrong with a layout's shape (an empty list means it looks right)."""
    ax, ay, aw, ah = area
    if not frames:
        return ["no windows"]
    if len(frames) == 1:
        f = frames[0]
        if style == "auto" and aw / ah >= 2.1:
            return []
        return [] if close(f, [ax, ay, aw, ah]) else [f"one window should fill the screen: {f}"]
    problems = []
    if style == "columns":
        problems += [f"not full height: {f}" for f in frames if not (near(f[1], ay) and near(f[3], ah))]
        problems += stacked(frames, 0, ax, ax + aw)
    elif style == "rows":
        problems += [f"not full width: {f}" for f in frames if not (near(f[0], ax) and near(f[2], aw))]
        problems += stacked(frames, 1, ay, ay + ah)
    elif style == "mainAndSide":
        main, side = frames[0], frames[1:]
        if not (near(main[0], ax) and near(main[1], ay) and near(main[3], ah)):
            problems.append(f"main window isn't full height on the left: {main}")
        problems += [f"side window isn't beside the main one: {f}" for f in side
                     if not (near(f[0], main[0] + main[2]) and near(f[0] + f[2], ax + aw))]
        problems += stacked(side, 1, ay, ay + ah)
    elif style == "grid":
        rows = {}
        for f in frames:
            rows.setdefault(f[1], []).append(f)
        ys = sorted(rows)
        if len(frames) >= 4 and (len(rows) == 1 or len(rows) == len(frames)):
            problems.append(f"{len(rows)} rows for {len(frames)} windows is not a grid")
        firsts = [sorted(rows[y], key=lambda f: f[0])[0] for y in ys]
        problems += stacked(firsts, 1, ay, ay + ah)
        for y in ys:
            row = sorted(rows[y], key=lambda f: f[0])
            problems += stacked(row, 0, ax, ax + aw)
            if len({f[3] for f in row}) > 1:
                problems.append(f"row at y={y} has mixed heights")
        counts = [len(rows[y]) for y in ys]
        if len(set(counts[1:])) > 1 or (len(counts) > 1 and counts[0] > counts[-1]):
            problems.append(f"row sizes {counts} aren't even")
    elif style == "auto":
        total = sum(f[2] * f[3] for f in frames)
        if abs(total - aw * ah) > 2 * (aw + ah):
            problems.append(f"windows cover {total} of {aw * ah} points: holes or overlaps")
    return problems


def settled_dump():
    """Waits until Tessera has finished arranging (two looks in a row agree), then returns its state."""
    time.sleep(1.0)
    last, d = None, {}
    for _ in range(14):
        d = dump()
        plan = screen_plan(d)
        cg = {w["id"]: w["frame"] for w in windows()["windows"]}
        now = json.dumps([plan and plan["frames"], [cg.get(i) for i in (plan or {}).get("ids", [])]])
        if now == last:
            return d
        last = now
        time.sleep(0.5)
    print("did not settle", flush=True)
    return d


def check_layout(label, style, count=None):
    """After a layout change: right style, right shape, windows really there, no overlaps when they fit."""
    d = settled_dump()
    plan = screen_plan(d)
    # The layout of the desktop on screen now (each desktop has its own).
    chosen = list(d.get("autoTile", {}).get("currentLayouts", {}).values()) or list(d.get("layouts", {}).values()) or ["auto"]
    record(f"{label}: style is {STYLE_NAMES[style]}", chosen[0] == style and plan is not None and plan["style"] == style,
           f"setting {chosen}, arranged as {plan and plan['style']}")
    if not plan:
        return d, None
    frames = [[round(v) for v in f] for f in plan["frames"]]
    standard = [w for w in d["windows"] if w["standard"]]
    want = count if count is not None else len(standard)
    record(f"{label}: all {want} windows tiled", len(frames) == want, f"tiled {len(frames)}")
    problems = shape_problems(style, frames, [round(v) for v in plan["area"]])
    record(f"{label}: looks like {STYLE_NAMES[style]}", not problems, "; ".join(problems[:3]))
    cg = {w["id"]: [round(v) for v in w["frame"]] for w in windows()["windows"]}
    wrong, at_minimum = [], 0
    for wid, f in zip(plan["ids"], frames):
        actual = cg.get(wid)
        if actual is None:
            wrong.append(f"{wid} not on screen")
            continue
        sizes_ok, held = True, False
        for i in (2, 3):
            diff = actual[i] - f[i]
            if diff > 16:
                held = True          # the app won't go that small
            elif diff < -16:
                sizes_ok = False     # smaller than asked: wrong
        spot_ok = held or (near(actual[0], f[0], 2) and near(actual[1], f[1], 2))
        if held:
            at_minimum += 1
        if not (sizes_ok and spot_ok):
            wrong.append(f"{wid} at {actual}, planned {f}")
    note = f" ({at_minimum} held at their app's minimum size)" if at_minimum else ""
    record(f"{label}: windows are where planned", not wrong, "; ".join(wrong[:3]) + note)
    if plan["fits"]:
        actual = [cg[i] for i in plan["ids"] if i in cg]
        pairs = [(a, b) for i, a in enumerate(actual) for b in actual[i + 1:] if overlap(a, b) > 4]
        record(f"{label}: no overlaps", not pairs, f"{pairs[:2]}")
    else:
        record(f"{label}: everything fits", False, "some apps can't get small enough for this layout", warn=True)
    return d, frames


def choose(style, label, count=None, picture=None):
    """Press ⌃⌥1–5 for a style and check the result."""
    press(CO, DIGIT[style], 0.5)
    if picture:
        shot(picture)
    return check_layout(label, style, count)


def layout_suite(name, count):
    """Every style by its own key, then ⌃⌥L round twice, then ⌃⌥⇧L back."""
    seen = {}
    for style in STYLES[1:] + ["auto"]:
        _, frames = choose(style, f"{name}: ⌃⌥{STYLES.index(style) + 1} {STYLE_NAMES[style]}", count,
                           picture=f"layout-{name}-{style}".replace(" ", "-"))
        seen[style] = frames
    shapes = {s: tuple(map(tuple, f)) for s, f in seen.items() if f}
    distinct = len({shapes[s] for s in ("columns", "rows", "mainAndSide") if s in shapes})
    if count >= 3:
        record(f"{name}: Columns, Rows and Main + Side all look different", distinct == 3, f"{distinct} different")
    style = "auto"
    cycle = {}
    for step in range(10):
        style = STYLES[(STYLES.index(style) + 1) % len(STYLES)]
        press(CO, K["l"], 0.2)
        _, frames = check_layout(f"{name}: ⌃⌥L press {step + 1} → {STYLE_NAMES[style]}", style, count)
        if step >= 5 and frames and cycle.get(style):
            record(f"{name}: {STYLE_NAMES[style]} looks the same on the second round", close_all(frames, cycle[style]),
                   f"{frames} vs {cycle[style]}")
        if step < 5:
            cycle[style] = frames
    for step in range(5):
        style = STYLES[(STYLES.index(style) - 1) % len(STYLES)]
        press("ctrl,opt,shift", K["l"], 0.2)
        check_layout(f"{name}: ⌃⌥⇧L press {step + 1} → {STYLE_NAMES[style]}", style, count)


def close_all(a, b, tol=3):
    return a is not None and b is not None and len(a) == len(b) and all(close(x, y, tol) for x, y in zip(a, b))


def hide(bundle):
    activate(bundle)
    keys("press", "cmd", "0x04")
    time.sleep(0.8)


# ---------- the latest command wins ----------

def plan_ids(d):
    return (screen_plan(d) or {}).get("ids", [])


def latest_command_wins(F):
    """Maximise one window in a layout, then pick a layout: every window joins it."""
    choose("grid", "Grid before maximising", 7)
    activate("com.apple.TextEdit")
    d = dump()
    te = d["focused"]
    slot = plan_ids(d).index(te) if te in plan_ids(d) else -1
    press(CO, K["ret"], 1.5)
    d = dump()
    got = frame_of(te)
    record("Maximise while tiling: TextEdit fills the screen", got is not None and close(got, F(0, 0, 1, 1), 2), f"got {got}")
    record("Maximise while tiling: it stays there (pinned)", str(te) in d["autoTile"]["pinned"], f"pinned {list(d['autoTile']['pinned'])}")
    moves = d["autoTile"]["moves"]
    time.sleep(2.5)
    later = frame_of(te)
    record("Maximised window is left alone while you wait",
           dump()["autoTile"]["moves"] == moves and later is not None and got is not None and close(later, got, 2), f"{got} → {later}")
    d, _ = choose("rows", "⌃⌥3 after maximising: all 7 in Rows", 7, picture="latest-command-rows")
    record("⌃⌥3 after maximising: nothing is pinned", not d["autoTile"]["pinned"], f"pinned {list(d['autoTile']['pinned'])}")
    ids = plan_ids(d)
    record("The maximised window goes back to its old place", te in ids and ids.index(te) == slot,
           f"was {slot}, now {ids.index(te) if te in ids else None}")

    # Retile also puts a maximised window back.
    activate("com.apple.TextEdit")
    press(CO, K["ret"], 1.5)
    post("run:tile.retile", 0.5)
    d, _ = check_layout("Retile after maximising: all 7 in Rows", "rows", 7)
    record("Retile after maximising: nothing is pinned", not d["autoTile"]["pinned"])

    # macOS "Fill" (Window menu) counts as maximise: it wins until the next layout command.
    activate("com.apple.TextEdit")
    out = keys("app-menu", "com.apple.TextEdit", "Window", "Fill").strip()
    print(out, flush=True)
    if out.startswith("pressed"):
        time.sleep(2.0)
        d = dump()
        got = frame_of(te)
        record("macOS Fill while tiling: TextEdit keeps the whole screen", got is not None and close(got, F(0, 0, 1, 1), 24)
               and str(te) in d["autoTile"]["pinned"], f"got {got}, pinned {list(d['autoTile']['pinned'])}")
        d, _ = choose("columns", "⌃⌥2 after macOS Fill: all 7 in Columns", 7)
        record("⌃⌥2 after macOS Fill: nothing is pinned", not d["autoTile"]["pinned"])
    else:
        record("macOS Fill is in TextEdit's Window menu", False, out, warn=True)

    # macOS full screen (its own desktop): picking a layout brings the window back into it.
    activate("com.apple.TextEdit")
    out = keys("app-menu", "com.apple.TextEdit", "View", "Enter Full Screen").strip()
    if not out.startswith("pressed"):
        out = keys("app-menu", "com.apple.TextEdit", "Window", "Enter Full Screen|Full Screen").strip()
    print(out, flush=True)
    time.sleep(3.0)
    d = dump()
    full = [w["id"] for w in d["windows"] if w.get("fullScreen")]
    record("macOS full screen: TextEdit went full screen", te in full, f"{out}; full screen: {full}", warn=te not in full)
    if te in full:
        shot("full-screen")
        press(CO, DIGIT["grid"], 0.5)
        time.sleep(3.0)
        d, _ = check_layout("⌃⌥4 from macOS full screen: TextEdit is back, all 7 in Grid", "grid", 7)
        record("⌃⌥4 from macOS full screen: TextEdit left full screen",
               te not in [w["id"] for w in d["windows"] if w.get("fullScreen")] and te in plan_ids(d))


# ---------- desktops (Spaces) ----------

def desktops(d):
    """The desktops of the first screen: (current id, [ids of normal desktops])."""
    lists = d.get("autoTile", {}).get("desktops") or []
    if not lists:
        return None, []
    first = lists[0]
    return first.get("current"), [s["id"] for s in first.get("spaces", []) if s.get("type") == 0]


def go_to_desktop(number, label):
    """⌃→ / ⌃← like a person (falls back to Mission Control). Returns the desktop now on screen."""
    before, spaces = desktops(dump())
    if len(spaces) < number:
        return before
    want = spaces[number - 1]
    if before == want:
        return before
    if before in spaces:
        arrow = K["right"] if spaces.index(before) < number - 1 else K["left"]
        keys("press", "ctrl,fn,num", arrow)
    for _ in range(15):
        time.sleep(0.2)
        now, _ = desktops(dump())
        if now == want:
            return now
    print(f"{label}: ⌃→/⌃← did not switch, using Mission Control:", keys("space-go", str(number)).strip(), flush=True)
    time.sleep(1.0)
    now, _ = desktops(dump())
    return now


def watch_for_jumps(settled, seconds=2.0):
    """Looks at the windows ten times a second while a switch happens. Returns any that moved."""
    jumps = []
    end = time.time() + seconds
    while time.time() < end:
        for w in windows()["windows"]:
            want = settled.get(w["id"])
            got = [round(v) for v in w["frame"]]
            if want and not close(got, want, 2):
                jumps.append(f"{w['id']} at {got}, was {want}")
        time.sleep(0.1)
    return jumps


def desktops_never_jump():
    d = dump()
    record("Tessera can see desktops (Spaces)", d["autoTile"].get("spacesSupported") is True and desktops(d)[0] is not None,
           f"supported {d['autoTile'].get('spacesSupported')}, desktops {d['autoTile'].get('desktops')}")
    choose("columns", "Desktop 1: Columns", 7)
    home, spaces = desktops(dump())
    if len(spaces) < 2:
        print(keys("space-add").strip()[:3000], flush=True)
        time.sleep(1.5)
        home, spaces = desktops(dump())
    record("Test helper adds a second desktop", len(spaces) >= 2, f"desktops {spaces}")
    if len(spaces) < 2:
        return
    one = settled_dump()
    first_ids = plan_ids(one)
    settled = {i: frame_of(i) for i in first_ids}

    # Desktop 2: two new TextEdit windows, then Rows there.
    now = go_to_desktop(2, "to desktop 2")
    record("Switch to desktop 2", now == spaces[1], f"on {now}, desktop 2 is {spaces[1]}")
    if now != spaces[1]:
        return
    shot("desktop-2-empty")
    # New windows open on the desktop you're looking at. File › New works without bringing
    # TextEdit forward (which could switch back to desktop 1, where its other windows are).
    for _ in range(2):
        print(keys("app-menu", "com.apple.TextEdit", "File", "New").strip(), flush=True)
        time.sleep(1.0)
    still, _ = desktops(dump())
    record("New windows open on desktop 2", still == spaces[1], f"on {still}")
    d, _ = check_layout("Desktop 2: its two new windows tile, Columns like desktop 1", "columns", 2)
    second_ids = plan_ids(d)
    record("Desktop 2 tiles only its own windows", len(second_ids) == 2 and not set(second_ids) & set(first_ids),
           f"desktop 2 {second_ids}, desktop 1 {first_ids}")
    choose("rows", "Desktop 2: ⌃⌥3 Rows", 2, picture="desktop-2-rows")
    two = settled_dump()
    settled.update({i: frame_of(i) for i in plan_ids(two)})

    # Back on desktop 1: still Columns, nothing moved.
    moves = dump()["autoTile"]["moves"]
    go_to_desktop(1, "back to desktop 1")
    jumps = watch_for_jumps(settled)
    d, _ = check_layout("Desktop 1 keeps Columns after desktop 2 chose Rows", "columns", 7)
    record("Back to desktop 1: no window jumped", not jumps, "; ".join(jumps[:4]))

    # Swipe back and forth: Tessera never moves a window.
    for round_ in range(4):
        go_to_desktop(2, f"round {round_ + 1} to 2")
        jumps += watch_for_jumps(settled, 1.2)
        go_to_desktop(1, f"round {round_ + 1} to 1")
        jumps += watch_for_jumps(settled, 1.2)
    d = settled_dump()
    record("Switching desktops 8 more times: Tessera moved nothing", d["autoTile"]["moves"] == moves,
           f"{d['autoTile']['moves'] - moves} moves")
    record("Switching desktops 8 more times: no window jumped", not jumps, "; ".join(jumps[:4]))
    check_layout("Desktop 1 is still Columns", "columns", 7)

    # Mission Control open and shut: nothing moves either.
    moves = d["autoTile"]["moves"]
    keys("space-tree")
    time.sleep(1.5)
    d = settled_dump()
    record("Mission Control open and shut: Tessera moved nothing", d["autoTile"]["moves"] == moves,
           f"{d['autoTile']['moves'] - moves} moves")

    # Desktop 2 kept Rows. Close its windows there, then come home.
    go_to_desktop(2, "to desktop 2 again")
    check_layout("Desktop 2 still Rows", "rows", 2)
    print(keys("close-untitled", "com.apple.TextEdit").strip(), flush=True)
    time.sleep(1.0)
    go_to_desktop(1, "home")
    check_layout("Home again: Columns with 7 windows", "columns", 7)


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
    VISIBLE[:] = V
    print("visible frame:", V, flush=True)
    F = lambda x, y, w, h: part(V, x, y, w, h)

    # --- Snapping with the keyboard, TextEdit ---
    activate("com.apple.TextEdit")
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
    for bundle, name in [("com.apple.finder", "Finder"), ("com.apple.Safari", "Safari"), ("com.google.Chrome", "Chrome"),
                         ("com.apple.Terminal", "Terminal")]:
        activate(bundle)
        time.sleep(0.5)
        first, win = front()
        if not win:
            record(f"{name} has a window in front", False)
            continue
        tol = 16 if name == "Terminal" else 1     # Terminal sizes itself in whole characters
        snap_check(f"{name} Left Half", CO, K["left"], F(0, 0, .5, 1), tol=tol, allow_minimum=True)
        snap_check(f"{name} Right Half", CO, K["right"], F(.5, 0, .5, 1), tol=tol, allow_minimum=True)
        snap_check(f"{name} Top Left", CO, K["u"], F(0, 0, .5, .5), tol=tol, allow_minimum=True)
        snap_check(f"{name} Last Third", CO, K["g"], F(2 / 3, 0, 1 / 3, 1), tol=tol, allow_minimum=True)
        snap_check(f"{name} Maximise", CO, K["ret"], F(0, 0, 1, 1), tol=tol)
        snap_check(f"{name} Restore", CO, K["delete"], first, tol=max(tol, 2))

    # --- Drag to a screen edge ---
    record("macOS edge tiling was on at the start", d.get("macEdgeTiling") is True)
    post("fix-mac-tiling", 1.0)
    out = subprocess.run(["defaults", "read", "com.apple.WindowManager", "EnableTilingByEdgeDrag"], capture_output=True, text=True).stdout.strip()
    record("Tessera turns off macOS edge tiling", out == "0", f"EnableTilingByEdgeDrag = {out!r}")
    activate("com.apple.TextEdit")
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
    post("permission", 0.3)
    shot("permission")
    time.sleep(1.5)

    # --- Auto-tile: turn it on with the real key ---
    press(CO, K["a"], 0.5)
    d = dump()
    record("⌃⌥A turns auto-tile on", d.get("autoTileSetting") is True)
    check_layout("7 windows, Auto", "auto", 7)

    # --- Every layout with 7 windows from 5 apps ---
    layout_suite("7 windows", 7)

    # --- The menu, clicked through Accessibility like a person would ---
    trusted = keys("trusted").strip() == "yes"
    record("Test helper may read menus", trusted, "" if trusted else "no Accessibility for /tmp/keys", warn=not trusted)
    if trusted:
        post("menu", 1.5)
        shot("menu-layouts")
        try:
            items = json.loads(keys("menu-list") or "[]")
        except json.JSONDecodeError:
            items = []
        by_title = {i["title"]: i for i in items}
        for style in STYLES:
            item = by_title.get(STYLE_NAMES[style])
            digit = str(STYLES.index(style) + 1)
            record(f"Menu shows {STYLE_NAMES[style]} with ⌃⌥{digit}",
                   item is not None and item["key"] == digit and item["mods"] == 14, f"{item}")
        nxt, prv = by_title.get("Next Layout"), by_title.get("Previous Layout")
        record("Menu shows Next Layout ⌃⌥L", nxt is not None and nxt["key"].upper() == "L" and nxt["mods"] == 14, f"{nxt}")
        record("Menu shows Previous Layout ⌃⌥⇧L", prv is not None and prv["key"].upper() == "L" and prv["mods"] == 15, f"{prv}")
        checked = [i["title"] for i in items if i["checked"]]
        record("Menu ticks the current layout (Auto)", "Auto" in checked, f"ticked {checked}")
        for style in ["mainAndSide", "columns", "grid"]:
            if style != "mainAndSide":
                post("menu", 1.5)
            print(keys("menu-press", STYLE_NAMES[style]).strip(), flush=True)
            check_layout(f"Menu › {STYLE_NAMES[style]}", style, 7)
        post("menu", 1.5)
        items = json.loads(keys("menu-list") or "[]")
        record("Menu ticks the new layout (Grid)", "Grid" in [i["title"] for i in items if i["checked"]])
        press("", K["esc"], 0.5)

    # --- Windows coming and going keep the chosen layout ---
    choose("rows", "Rows before changes", 7)
    activate("com.apple.TextEdit")
    keys("press", "cmd", K["n"])
    check_layout("Rows after a new window", "rows", 8)
    activate("com.apple.TextEdit")
    keys("press", "cmd", K["w"])
    check_layout("Rows after closing it", "rows", 7)
    hide("com.apple.finder")
    check_layout("Rows after hiding Finder", "rows", 6)
    keys("unhide", "com.apple.finder")
    check_layout("Rows after showing Finder again", "rows", 7)
    activate("com.apple.TextEdit")
    keys("press", "cmd", K["m"])
    check_layout("Rows after minimising a window", "rows", 6)
    keys("unminimize", "com.apple.TextEdit")
    check_layout("Rows after bringing it back", "rows", 7)

    # --- Fewer windows: 3 (TextEdit only), then 1 ---
    # TextEdit in front first, then hide the rest from the background: hiding the front app
    # makes macOS bring another forward, which can un-hide one hidden a moment before.
    activate("com.apple.TextEdit")
    for bundle in ["com.apple.finder", "com.apple.Safari", "com.google.Chrome", "com.apple.Terminal"]:
        print(keys("hide", bundle).strip(), flush=True)
    check_layout("3 windows, Rows", "rows", 3)
    layout_suite("3 windows", 3)
    activate("com.apple.TextEdit")
    keys("press", "cmd", K["m"])
    time.sleep(0.8)
    activate("com.apple.TextEdit")
    keys("press", "cmd", K["m"])
    for style in STYLES:
        choose(style, f"1 window: {STYLE_NAMES[style]}", 1)
    keys("unminimize", "com.apple.TextEdit")
    for bundle in ["com.apple.finder", "com.apple.Safari", "com.google.Chrome", "com.apple.Terminal"]:
        keys("unhide", bundle)
    choose("auto", "Back to 7 windows, Auto", 7, picture="layout-7-back")

    # Swap with main.
    activate("com.apple.Safari")
    press(CO, K["m"], 1.2)
    d = settled_dump()
    order = (screen_plan(d) or {}).get("ids", [])
    record("⌃⌥M puts Safari in the main spot", bool(order) and order[0] == d["focused"], f"order {order}, focused {d['focused']}")

    # Snap by hand while tiling: Chrome takes the left half, the rest share the right half.
    activate("com.google.Chrome")
    chrome = snap_check("Auto-tile: Chrome ⌃⌥← keeps the left half", CO, K["left"], F(0, 0, .5, 1), allow_minimum=True)
    _, cw = front()
    d, frames = check_tiling("Others fill the right half", ignore=(cw["id"],) if cw else ())
    right = [r for r in frames.values() if r[0] < V[0] + V[2] / 2 - 2]
    record("Tiles stay out of Chrome's half", not right, f"{right}")
    activate("com.google.Chrome")
    press(CO, K["delete"], 1.0)
    d, _ = check_tiling("⌃⌥⌫ puts Chrome back")

    # Float and tile again.
    activate("com.apple.TextEdit")
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
        # Swapped means each window now sits where the other was. Sizes can shift by a few
        # points, because a row's height follows the minimum sizes of the windows in it.
        def centre_in(r, box):
            return r is not None and box[0] <= r[0] + r[2] / 2 <= box[0] + box[2] and box[1] <= r[1] + r[3] / 2 <= box[1] + box[3]
        na, nb = frame_of(a), frame_of(b)
        record("Drag a tile onto another: they swap", centre_in(na, fb) and centre_in(nb, fa),
               f"a {na} was {fa}; b {nb} was {fb}")

    latest_command_wins(F)
    desktops_never_jump()

    # Switching off, then back on: the layout is remembered.
    choose("mainAndSide", "Main + Side before switching off", 7)
    press(CO, K["a"], 1.0)
    d = dump()
    record("⌃⌥A turns auto-tile off", d["autoTileSetting"] is False)
    press(CO, K["a"], 0.5)
    check_layout("⌃⌥A on again remembers Main + Side", "mainAndSide", 7)
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
