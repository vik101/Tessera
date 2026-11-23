#!/usr/bin/env python3
"""Several screens of different sizes, like a 49-inch monitor, a MacBook and a squarish Dell.

Runs after check.py (same windows, same Tessera). Adds pretend screens with scripts/ci/vdisplay.m,
moves windows between them, rearranges and unplugs screens, and checks after each step:
- each screen shows no more front windows than its own limit (Auto: by its size);
- front windows sit inside their own screen and don't overlap;
- waiting windows are off screen, and never show on another screen;
- no window is lost, and nothing moves once things settle.
Results are added to results.txt.
"""
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check as c  # noqa: E402  (shares the helpers and the results list)

OUT = c.OUT
VDISPLAY = "/tmp/vdisplay"
WIDE = (5120, 1440)   # 49-inch super ultrawide
DELL = (1600, 1200)   # 20-inch 4:3
screens_on = {}       # name -> pretend screen process


def plug(name, size, serial, x, y):
    log = open(f"{OUT}/vdisplay-{name}.txt", "w")
    screens_on[name] = subprocess.Popen([VDISPLAY, str(size[0]), str(size[1]), str(serial), str(x), str(y)],
                                        stdout=log, stderr=subprocess.STDOUT)
    time.sleep(6)


def unplug(name):
    process = screens_on.pop(name, None)
    if process:
        process.terminate()
        try:
            process.wait(5)
        except subprocess.TimeoutExpired:
            process.kill()
    time.sleep(6)


def screen_of_size(d, size):
    return next((s for s in d["displays"] if [round(v) for v in s["frame"][2:]] == list(size)), None)


def main_screen(d):
    return d["displays"][0]


def per_screen(d):
    """{screen id: (front ids, waiting ids, limit)}"""
    auto = d["autoTile"]
    out = {}
    for s in d["displays"]:
        plan = auto.get("plans", {}).get(s["id"], {})
        out[s["id"]] = (plan.get("ids", []), auto.get("waiting", {}).get(s["id"], []), auto.get("limits", {}).get(s["id"]))
    return out


def standard_windows():
    """Normal windows of the test apps, from the window server (minimised and hidden ones aren't listed)."""
    return [w for w in c.windows()["windows"] if w["owner"] in ("TextEdit", "Finder", "Safari", "Google Chrome", "Terminal")]


def sliver(a, b):
    """How much of rect a shows on rect b: (width, height), zero if none."""
    return c.showing(a, b)


def check_screens(label, expect_limits=None):
    """The promises, on every screen."""
    d = c.settled_dump()
    time.sleep(1.0)
    d = c.settled_dump()
    screens = {s["id"]: s for s in d["displays"]}
    state = per_screen(d)
    cg = {w["id"]: [round(v) for v in w["frame"]] for w in standard_windows()}
    problems, crowded = [], []
    for sid, (front, waiting, limit) in state.items():
        s = screens[sid]
        name = f"{round(s['frame'][2])}×{round(s['frame'][3])}"
        if expect_limits and sid in expect_limits and limit != expect_limits[sid]:
            problems.append(f"{name}: limit {limit}, want {expect_limits[sid]}")
        if limit and len(front) > limit:
            problems.append(f"{name}: {len(front)} in front, limit {limit}")
        mine = [w for w in d["windows"] if w.get("screen") == sid and w["standard"]]
        if limit and len(mine) >= limit and len(front) < limit:
            problems.append(f"{name}: only {len(front)} in front with {len(mine)} windows")
        for i in front:
            f = cg.get(i)
            if f and not c.inside(f, s["visible"], 2):
                crowded.append(f"{name}: {i} at {f} is not inside {s['visible']}")
        fronts = [cg[i] for i in front if i in cg]
        pairs = [(a, b) for n, a in enumerate(fronts) for b in fronts[n + 1:] if c.overlap(a, b) > 4]
        if pairs and sid not in d["autoTile"].get("crowded", []):
            problems.append(f"{name}: front windows overlap {pairs[:1]}")
        for i in waiting:
            f = cg.get(i)
            if not f:
                continue
            for other in d["displays"]:
                w, h = sliver(f, other["frame"])
                if w > 1 and h > 1 and (other["id"] != sid or (w > 4 and h > 4)):
                    problems.append(f"waiting {i} at {f} shows {w}×{h} on {round(other['frame'][2])}×{round(other['frame'][3])}")
    # No window lost: every test window is in front somewhere, waiting somewhere, or snapped/floating.
    placed = {i for front, waiting, _ in state.values() for i in front + waiting}
    lost = [w["id"] for w in d["windows"] if w["standard"] and w["id"] not in placed and w["tiled"]]
    c.record(f"{label}: every screen keeps its limit, nothing overlaps, waiting windows stay off every screen",
             not problems, "; ".join(problems[:4]))
    c.record(f"{label}: front windows sit inside their own screen", not crowded, "; ".join(crowded[:3]), warn=bool(crowded) and not problems)
    c.record(f"{label}: no window is lost", not lost, f"{lost}")
    moves = d["autoTile"]["moves"]
    time.sleep(2.5)
    later = c.dump()["autoTile"]["moves"]
    c.record(f"{label}: nothing moves once settled", later == moves, f"{later - moves} moves")
    c.shot(label.lower().replace(" ", "-").replace(",", "").replace("—", "-")[:60])
    return d


def most_recent_in_front(label, d, sid):
    front, waiting, limit = per_screen(d)[sid]
    used = {int(k): v for k, v in d["autoTile"].get("lastUsed", {}).items()}
    everyone = front + waiting
    best = sorted(everyone, key=lambda i: -used.get(i, -1))[:len(front)]
    c.record(f"{label}: the windows used most lately are in front", set(front) == set(best),
             f"front {front}, most lately used {best}")


def main():
    if not os.path.exists(VDISPLAY):
        c.record("Pretend screens can be made", False, "vdisplay not built", warn=True)
        return
    c.post("set:autoTile=1", 1.0)
    c.post("set:frontLimit=auto", 0.3)
    # More windows: 5 new TextEdit windows, 12 in all.
    for _ in range(5):
        c.keys("app-menu", "com.apple.TextEdit", "File", "New")
        time.sleep(0.6)

    # At home: the 49-inch above the main screen, centred; a squarish Dell to the left.
    d = c.dump()
    main = main_screen(d)
    mw, mh = round(main["frame"][2]), round(main["frame"][3])
    plug("wide", WIDE, 7, (mw - WIDE[0]) // 2, -WIDE[1])
    plug("dell", DELL, 8, -DELL[0], 0)
    d = c.dump()
    wide, dell = screen_of_size(d, WIDE), screen_of_size(d, DELL)
    c.record("Three screens: 49-inch, Dell and the main screen", wide is not None and dell is not None and len(d["displays"]) == 3,
             f"{[s['frame'] for s in d['displays']]}")
    if not (wide and dell):
        for name in list(screens_on):
            unplug(name)
        return
    c.post("set:layout=auto", 0.5)
    limits = {wide["id"]: 6, dell["id"]: 3, main["id"]: 3}

    # Send 8 windows to the 49-inch and 4 to the Dell; the rest stay on the main screen.
    ids = [w["id"] for w in d["windows"] if w["standard"]]
    for i in ids[:8]:
        c.post(f"send:{i}={wide['id']}", 0.4)
    for i in ids[8:12]:
        c.post(f"send:{i}={dell['id']}", 0.4)
    d = check_screens("Home: 49-inch above, Dell left", limits)
    state = per_screen(d)
    c.record("49-inch: 6 in front, 2 waiting", len(state[wide["id"]][0]) == 6 and len(state[wide["id"]][1]) == 2,
             f"{state[wide['id']][:2]}")
    c.record("Dell: 3 in front, 1 waiting", len(state[dell["id"]][0]) == 3 and len(state[dell["id"]][1]) == 1,
             f"{state[dell['id']][:2]}")

    # Each screen has its own layout: Columns on the 49-inch only.
    target = (c.single_window_apps(d, state[wide["id"]][0]) or state[wide["id"]][0])[0]
    c.activate(next((w["app"] for w in d["windows"] if w["id"] == target), "com.apple.TextEdit"))
    if c.dump().get("focused") not in state[wide["id"]][0]:
        c.record("Can work in a window on the 49-inch", False, f"focused {c.dump().get('focused')}", warn=True)
    else:
        c.press(c.CO, c.DIGIT["columns"], 1.0)
        d = check_screens("Columns on the 49-inch")
        plans = d["autoTile"]["plans"]
        c.record("Only the 49-inch changed to Columns",
                 plans.get(wide["id"], {}).get("style") == "columns" and plans.get(main["id"], {}).get("style") == "auto"
                 and plans.get(dell["id"], {}).get("style") == "auto", f"{ {k: v['style'] for k, v in plans.items()} }")
        frames = [c.frame_of(i) for i in plans.get(wide["id"], {}).get("ids", [])]
        c.record("6 columns on the 49-inch are each at least 800 points wide",
                 all(f and f[2] >= 800 for f in frames), f"{frames}")

    # A real drag: a TextEdit window from the main screen onto the Dell.
    d = c.dump()
    front_main = per_screen(d)[main["id"]][0]
    textedit = [w for w in c.windows()["windows"] if w["id"] in front_main and w["owner"] == "TextEdit"]
    if textedit:
        w = textedit[0]
        f = [round(v) for v in w["frame"]]
        dx, dy, dw, dh = [round(v) for v in dell["visible"]]
        c.keys("drag", str(f[0] + 100), str(f[1] + 12), str(dx + dw // 2), str(dy + dh // 2))
        time.sleep(2.0)
        d = c.settled_dump()
        c.record("Drag a window onto the Dell: it joins the Dell, in front",
                 w["id"] in per_screen(d)[dell["id"]][0], f"Dell front {per_screen(d)[dell['id']][0]}")
        check_screens("After dragging onto the Dell")

    # At the office: the 49-inch moves to the right of the main screen, bottoms lined up.
    print(c.keys("display-origin", str(wide["number"]), str(mw), str(mh - WIDE[1])).strip(), flush=True)
    time.sleep(6)
    check_screens("49-inch moved to the right")

    # Unplug the Dell: its windows go to the other screens, and the most recently used get the front.
    unplug("dell")
    d = check_screens("Dell unplugged")
    c.record("Two screens left", len(d["displays"]) == 2)
    for s in d["displays"]:
        most_recent_in_front(f"Dell unplugged, {round(s['frame'][2])}-wide screen", d, s["id"])

    # Plug it back in.
    plug("dell", DELL, 8, -DELL[0], 0)
    check_screens("Dell plugged back in")

    # Unplug everything: back to one screen, 3 in front.
    unplug("wide")
    unplug("dell")
    d = check_screens("Back to one screen", {main["id"]: 3})
    front, waiting, _ = per_screen(d)[main["id"]]
    c.record("One screen: 3 in front, the rest waiting", len(front) == 3 and len(waiting) >= 8, f"{len(front)} + {len(waiting)}")

    # Tidy up for anything after: the new windows close, every window back in front.
    print(c.keys("close-untitled", "com.apple.TextEdit").strip(), flush=True)
    c.post("set:frontLimit=none", 1.0)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        import traceback
        traceback.print_exc()
        c.record("Screens test finished", False, repr(error))
    finally:
        for name in list(screens_on):
            unplug(name)
    # Add these results to check.py's.
    path = f"{OUT}/results.txt"
    old = open(path).read().splitlines()[2:] if os.path.exists(path) else []
    new = [f"{s} {n}" + (f"  ({d})" if d else "") for s, n, d in c.results]
    lines = old + new
    fails = sum(1 for l in lines if l.startswith("FAIL"))
    warns = sum(1 for l in lines if l.startswith("WARN"))
    with open(path, "w") as f:
        f.write(f"{len(lines) - fails - warns} passed, {warns} warnings, {fails} failed\n\n" + "\n".join(lines) + "\n")
    with open(f"{OUT}/screens-results.txt", "w") as f:
        f.write("\n".join(new) + "\n")
    print(open(path).read().splitlines()[0])
    sys.exit(1 if any(l.startswith("FAIL") for l in new) else 0)
