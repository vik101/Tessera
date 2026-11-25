#!/usr/bin/env python3
"""Tessera 3.0 on real windows: the Tree, Stack and Float layouts, the command language through the
`tessera` command line tool, the config file (bindings, modes, rules, callbacks, gaps), desktops,
window commands, dim and border, fn-drag and drop zones. Also re-checks old promises in the new
layouts: nothing moves when you switch layout, windows come back where they were, desktops never jump.

Runs after check.py and screens.py (same Tessera). Results are added to results.txt.
"""
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check as c  # noqa: E402  (shares the helpers and the results list)

OUT = c.OUT
CLI = os.environ.get("TESSERA_CLI", "")
CONFIG = os.path.expanduser("~/.config/tessera/tessera.toml")   # replaced by the path Tessera reports
TEXTEDIT = "com.apple.TextEdit"
OTHERS = ["com.apple.finder", "com.apple.Safari", "com.google.Chrome", "com.apple.Terminal"]
record = c.record


# ---------- helpers ----------

def cli(*args, timeout=15):
    try:
        p = subprocess.run([CLI, *args], capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "timed out"
    except OSError as error:
        return -2, "", str(error)


def run(*args, wait=0.9):
    """A command that should work. Returns its output."""
    code, out, err = cli(*args)
    if code != 0:
        print(f"tessera {' '.join(args)} → {code}: {err.strip()}", flush=True)
    time.sleep(wait)
    return out


def ask(*args):
    code, out, err = cli(*args, "--json")
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        print(f"tessera {' '.join(args)} --json → {code}: {out[:300]} {err[:300]}", flush=True)
        return None


def cg():
    return {w["id"]: [round(v) for v in w["frame"]] for w in c.windows()["windows"]}


def textedit_ids():
    """TextEdit's normal windows on screen, left to right then top to bottom."""
    wins = [w for w in c.windows()["windows"] if w["owner"] == "TextEdit" and w["frame"][2] > 100]
    return [w["id"] for w in sorted(wins, key=lambda w: (round(w["frame"][0]), round(w["frame"][1])))]


def focus(window_id):
    run("focus", "--window-id", str(window_id), wait=0.7)


def tree():
    """The Tree layout of the main screen as text, with window ids."""
    rows = ask("tree") or []
    main = (c.dump().get("displays") or [{}])[0].get("id")
    row = next((r for r in rows if r.get("display-id") == main), rows[0] if rows else {})
    return row.get("tree", "")


def shape(text, names):
    """H[12 V[13 14]] → H[a V[b c]] using names {id: letter}."""
    import re
    return re.sub(r"\d+", lambda m: names.get(int(m.group()), m.group()), text)


def main_style():
    """The layout style Tessera is using on the main screen."""
    d = c.dump()
    main = (d.get("displays") or [{}])[0].get("id")
    plans = d.get("autoTile", {}).get("plans", {})
    return (plans.get(main) or {}).get("style")


def visible():
    d = c.dump()
    return d["displays"][0]["visible"]


def settle():
    return c.settled_dump()


def left_to_right(ids):
    f = cg()
    return sorted(ids, key=lambda i: (f.get(i, [0, 0])[0], f.get(i, [0, 0])[1]))


def no_overlaps(ids):
    f = cg()
    for i, a in enumerate(ids):
        for b in ids[i + 1:]:
            if a in f and b in f and c.overlap(f[a], f[b]) > 4:
                return False
    return True


def fresh(count):
    """Exactly `count` TextEdit windows in front, every other app hidden, auto-tile on, no gaps."""
    c.post("set:autoTile=1", 0.3)
    c.post("set:frontLimit=none", 0.3)
    c.post("set:gap=0", 0.3)
    c.activate(TEXTEDIT)
    for bundle in OTHERS:
        c.keys("hide", bundle)
    c.keys("unminimize", TEXTEDIT)
    c.keys("close-untitled", TEXTEDIT)
    time.sleep(1.0)
    while len(textedit_ids()) < count:
        c.activate(TEXTEDIT)
        c.keys("press", "cmd", c.K["n"])
        time.sleep(0.8)
    # Close any extra windows (minimising them would bring them back later, with every other
    # minimised window, when a check un-minimises one).
    for extra in textedit_ids()[count:]:
        cli("--window-id", str(extra), "close")
        time.sleep(0.6)
    time.sleep(1.0)
    return textedit_ids()[:count]


# ---------- the command line tool ----------

def command_line():
    record("The command line tool is in the app", bool(CLI) and os.access(CLI, os.X_OK), CLI)
    code, out, _ = cli("version")
    record("tessera version answers", code == 0 and out.startswith("Tessera "), f"{code}: {out.strip()}")
    code, out, _ = cli("help")
    record("tessera help lists the commands", code == 0 and "list-windows" in out and "join" in out, f"{code}, {len(out)} characters")
    code, out, _ = cli("help", "workspace")
    record("tessera help explains one command (by an AeroSpace name too)", code == 0 and "desktop" in out, out.strip()[:120])
    code, _, err = cli("frobnicate")
    record("An unknown command exits 3 and says so", code == 3 and "unknown command" in err, f"{code}: {err.strip()}")
    code, _, err = cli("focus", "sideways")
    record("A bad argument exits 3 and says why", code == 3 and "direction" in err, f"{code}: {err.strip()}")
    code, _, err = cli("--window-id", "999999", "close")
    record("A window that doesn't exist exits 1", code == 1 and "999999" in err, f"{code}: {err.strip()}")
    wins = ask("list-windows")
    record("list-windows --json is a list with ids, apps, titles, desktops and states",
           isinstance(wins, list) and wins and all(k in wins[0] for k in ("window-id", "app-bundle-id", "window-title", "desktop", "state", "frame")),
           f"{str(wins)[:300]}")
    code, out, _ = cli("list-windows", "--count")
    record("list-windows --count matches the list", code == 0 and wins is not None and out.strip() == str(len(wins)), f"{out.strip()} vs {len(wins or [])}")
    code, out, _ = cli("list-windows", "--format", "%{window-id}:%{app-name}")
    record("list-windows --format fills placeholders", code == 0 and ":" in out and "%{" not in out, out[:120])
    displays = ask("list-displays")
    record("list-displays --json names the main screen", isinstance(displays, list) and any(d.get("main") for d in displays or []),
           str(displays)[:300])
    desks = ask("list-desktops")
    record("list-desktops --json shows the desktop on screen", isinstance(desks, list) and any(d.get("showing") for d in desks or []),
           str(desks)[:300])
    apps = ask("list-apps")
    record("list-apps --json includes TextEdit", isinstance(apps, list) and any(a.get("app-bundle-id") == TEXTEDIT for a in apps or []))
    code, out, _ = cli("list-modes", "--current")
    record("list-modes --current is main", code == 0 and out.strip() == "main", out.strip())
    code, out, _ = cli("false || echo fallback")
    record("A command line with || runs the fallback", code == 0 and "fallback" in out, f"{code}: {out.strip()}")
    code, out, _ = cli("true && echo both; echo end")
    record("A command line with && and ; runs every part", code == 0 and "both" in out and "end" in out, out.strip())


# ---------- Tree layout ----------

def tree_layout():
    ids = fresh(3)
    record("Three TextEdit windows for the tree checks", len(ids) == 3, f"{ids}")
    if len(ids) < 3:
        return ids
    run("layout", "columns", wait=1.5)
    before = cg()
    run("layout", "tree", wait=1.5)
    after = cg()
    moved = [i for i in ids if not c.close(before.get(i), after.get(i), 3)]
    record("Switching Columns → Tree moves nothing", not moved, f"moved {moved}: {[(before.get(i), after.get(i)) for i in moved]}")
    a, b, cc = left_to_right(ids)
    names = {a: "a", b: "b", cc: "c"}
    record("The tree is the three columns", shape(tree(), names) == "H[a b c]", shape(tree(), names))

    focus(b)
    run("join", "right", wait=1.5)
    record("join right makes a column of b and c", shape(tree(), names) == "H[a V[b c]]", shape(tree(), names))
    f = cg()
    V = visible()
    ok = f[b][0] == f[cc][0] and f[b][1] < f[cc][1] and f[a][0] + f[a][2] <= f[b][0] + 2
    record("…b sits above c, right of a", ok, f"a {f[a]} b {f[b]} c {f[cc]}")
    record("…a keeps its third, the column takes two", abs(f[a][2] - V[2] / 3) <= 3, f"a {f[a]} on {V}")

    focus(cc)
    run("move", "left", wait=1.5)
    record("move left takes c out of the column, beside a", shape(tree(), names) == "H[a c b]", shape(tree(), names))
    run("swap", "right", wait=1.5)
    record("swap right trades c and b", shape(tree(), names) == "H[a b c]", shape(tree(), names))

    run("layout", "tiles", "vertical", wait=1.5)
    record("layout tiles vertical: the root runs top to bottom", shape(tree(), names) == "V[a b c]", shape(tree(), names))
    f = cg()
    record("…three rows", f[a][1] < f[b][1] < f[cc][1] and f[a][0] == f[b][0] == f[cc][0], f"{[f[i] for i in (a, b, cc)]}")
    run("layout", "horizontal", wait=1.5)
    record("layout horizontal turns it back", shape(tree(), names) == "H[a b c]", shape(tree(), names))

    run("layout", "accordion", wait=1.5)
    f = cg()
    widths = sorted(f[i][2] for i in (a, b, cc))
    record("Accordion: each window spans the screen less a strip per neighbour",
           shape(tree(), names) == "HA[a b c]" and abs(widths[-1] - (V[2] - 30)) <= 3 and abs(widths[0] - (V[2] - 60)) <= 3,
           f"{shape(tree(), names)} widths {widths} on {V[2]}")
    run("layout", "tiles", wait=1.5)

    focus(a)
    old = cg()[a][2]
    run("resize", "width", "+100", wait=1.5)
    record("resize width +100 grows the tile by 100 points", abs(cg()[a][2] - (old + 100)) <= 3, f"{old} → {cg()[a][2]}")
    run("balance", wait=1.5)
    f = cg()
    record("balance evens them out", max(f[i][2] for i in (a, b, cc)) - min(f[i][2] for i in (a, b, cc)) <= 2, f"{[f[i][2] for i in (a, b, cc)]}")
    run("mirror", "horizontal", wait=1.5)
    record("mirror horizontal reverses them", left_to_right([a, b, cc]) == [cc, b, a], shape(tree(), names))
    run("rotate", "90", wait=1.5)
    record("rotate 90 makes rows", shape(tree(), names).startswith("V["), shape(tree(), names))
    run("rotate", "270", wait=1.5)
    record("rotate 270 turns them back", shape(tree(), names).startswith("H["), shape(tree(), names))
    run("mirror", "horizontal", wait=1.5)

    # A new window splits the window you're in, the way you preselected.
    focus(a)
    run("preselect", "down", wait=0.3)
    c.keys("press", "cmd", c.K["n"])
    time.sleep(2.0)
    new = [i for i in textedit_ids() if i not in ids]
    f = cg()
    if new:
        d = new[0]
        names[d] = "d"
        record("preselect down: the new window opens below the one you're in", shape(tree(), names) == "H[V[a d] b c]",
               f"{shape(tree(), names)} a {f.get(a)} d {f.get(d)}")
        run("--window-id", str(d), "close", wait=2.0)
        record("Closing it gives its space back", shape(tree(), names) == "H[a b c]" and c.close(cg()[a], old_frame_full(a, f), 3),
               f"{shape(tree(), names)} a {cg().get(a)}")
    else:
        record("preselect down: a new window opened", False, "no new TextEdit window")

    # Minimise and bring back: the window returns to its own spot.
    focus(b)
    spot = cg()[b]
    c.keys("press", "cmd", c.K["m"])
    time.sleep(1.5)
    record("Minimising b lets a and c fill the space", shape(tree(), names) == "H[a c]", shape(tree(), names))
    c.keys("unminimize", TEXTEDIT)
    time.sleep(2.0)
    record("Bringing b back puts it in the same spot", c.close(cg().get(b), spot, 3) and shape(tree(), names) == "H[a b c]",
           f"{cg().get(b)} vs {spot}, {shape(tree(), names)}")

    # Float and tile again: back to its spot.
    focus(b)
    run("float", "on", wait=1.5)
    record("float on takes b out of the tree", shape(tree(), names) == "H[a c]", shape(tree(), names))
    run("float", "off", wait=1.5)
    record("float off puts it back where it was", shape(tree(), names) == "H[a b c]" and c.close(cg().get(b), spot, 3),
           f"{shape(tree(), names)} {cg().get(b)} vs {spot}")

    # Zoom fills the desktop, then goes back.
    focus(a)
    tile = cg()[a]
    run("zoom", wait=1.5)
    record("zoom: the window fills the desktop", c.close(cg()[a], V, 3), f"{cg()[a]} vs {V}")
    run("zoom", wait=1.5)
    record("zoom again: back to its tile", c.close(cg()[a], tile, 3), f"{cg()[a]} vs {tile}")

    # Snap by hand, then pick Tree again: the latest command wins.
    run("place", "left-half", wait=1.5)
    record("A hand snap in the Tree layout keeps its spot", c.close(cg()[a], c.part(V, 0, 0, .5, 1), 3), f"{cg()[a]}")
    run("layout", "tree", wait=1.5)
    record("Picking Tree again puts it back in the tree", a in [int(x) for x in tree().replace("[", " ").replace("]", " ").split() if x.isdigit()],
           tree())
    record("Tree windows never overlap", no_overlaps([a, b, cc]))
    return [a, b, cc]


def old_frame_full(window, frames):
    """a's frame before the new window split it: its column at full height."""
    f = frames.get(window)
    V = visible()
    return [f[0], V[1], f[2], V[3]] if f else None


# ---------- dropping windows on tiles ----------

def drop_zones(ids):
    if len(ids) < 3:
        return
    run("layout", "columns", wait=1.0)
    run("layout", "tree", wait=1.5)
    a, b, cc = left_to_right(ids)
    names = {a: "a", b: "b", cc: "c"}
    f = cg()
    # Drag a by its title bar onto the bottom edge of c: it sits below c.
    c.keys("drag", str(f[a][0] + 120), str(f[a][1] + 12), str(f[cc][0] + f[cc][2] // 2), str(f[cc][1] + f[cc][3] - 40))
    time.sleep(1.8)
    record("Dropping a near c's bottom edge puts it below c", shape(tree(), names) == "H[b V[c a]]", shape(tree(), names))
    f = cg()
    # Drag a onto the middle of b: they swap.
    c.keys("drag", str(f[a][0] + 120), str(f[a][1] + 12), str(f[b][0] + f[b][2] // 2), str(f[b][1] + f[b][3] // 2))
    time.sleep(1.8)
    record("Dropping a on the middle of b swaps them", shape(tree(), names) == "H[a V[c b]]", shape(tree(), names))

    # fn-drag from the middle of a window (not the title bar).
    f = cg()
    c.keys("drag-mod", "fn", str(f[a][0] + f[a][2] // 2), str(f[a][1] + f[a][3] // 2),
           str(f[b][0] + f[b][2] // 2), str(f[b][1] + f[b][3] // 2))
    time.sleep(1.8)
    record("fn-drag from the middle of a tile onto another swaps them", shape(tree(), names) == "H[b V[c a]]", shape(tree(), names))

    # fn-drag a floating window: it just moves.
    focus(b)
    run("float", "on", wait=1.0)
    run("place", "center", wait=1.0)
    start = cg()[b]
    c.keys("drag-mod", "fn", str(start[0] + start[2] // 2), str(start[1] + start[3] // 2),
           str(start[0] + start[2] // 2 - 150), str(start[1] + start[3] // 2 + 80))
    time.sleep(1.0)
    now = cg()[b]
    record("fn-drag moves a floating window from anywhere in it", abs(now[0] - (start[0] - 150)) <= 6 and abs(now[1] - (start[1] + 80)) <= 6,
           f"{start} → {now}")
    run("float", "off", wait=1.2)


# ---------- Stack and Float layouts ----------

def stack_and_float(ids):
    if len(ids) < 3:
        return
    V = visible()
    before_tree = tree()
    run("layout", "stack", wait=1.5)
    f = cg()
    record("Stack: every window fills the desktop", all(c.close(f.get(i), V, 3) for i in ids), f"{[f.get(i) for i in ids]} vs {V}")
    focus(ids[0])
    run("stack", "next", wait=1.0)
    d = c.dump()
    record("stack next shows the next window", d.get("focused") != ids[0] and d.get("focused") in ids, f"focused {d.get('focused')}")
    front = [w["id"] for w in c.windows()["windows"] if w["id"] in ids]
    record("…and it's on top", front and front[0] == d.get("focused"), f"front {front}")

    run("layout", "float", wait=1.5)
    focus(ids[1])
    run("place", "left-half", wait=1.0)
    run("place", "center", wait=1.0)
    before = cg()
    time.sleep(2.0)
    after = cg()
    record("Float layout: windows stay where you put them", all(c.close(before.get(i), after.get(i), 2) for i in ids),
           f"{[(before.get(i), after.get(i)) for i in ids]}")
    code, out, _ = cli("list-windows", "--format", "%{window-id} %{state}")
    states = dict(line.split() for line in out.strip().splitlines() if len(line.split()) == 2)
    record("…and none of them counts as tiled", all(states.get(str(i)) == "floating" for i in ids), out.strip()[:200])
    run("layout", "tree", wait=1.5)
    record("Back to Tree: tiled again, no overlaps", no_overlaps(ids))
    names = dict(zip(sorted(ids), "xyz"))
    record("…and the tree is the one from before Stack and Float", shape(tree(), names) == shape(before_tree, names),
           f"{shape(before_tree, names)} → {shape(tree(), names)}")


# ---------- window commands ----------

def window_commands(ids):
    if len(ids) < 3:
        return
    run("layout", "columns", wait=1.0)
    run("layout", "tree", wait=1.5)
    focus(ids[0])
    run("move-mouse", "window-force-center", wait=0.5)
    x, y = (int(v) for v in c.keys("mouse").split())
    f = cg()[ids[0]]
    record("move-mouse window-force-center puts the pointer in the middle of the window",
           abs(x - (f[0] + f[2] // 2)) <= 3 and abs(y - (f[1] + f[3] // 2)) <= 3, f"pointer {x},{y} window {f}")

    # Focus by direction and order.
    a, b, cc = left_to_right(ids)
    focus(b)
    run("focus", "left", wait=0.8)
    record("focus left goes to the tile on the left", c.dump().get("focused") == a, f"{c.dump().get('focused')} want {a}")
    run("focus", "back", wait=0.8)
    record("focus back returns to the window before", c.dump().get("focused") == b, f"{c.dump().get('focused')} want {b}")
    focus(cc)
    run("focus", "--wrap-around", "right", wait=0.8)
    record("focus right --wrap-around goes round to the left-most", c.dump().get("focused") == a, f"{c.dump().get('focused')} want {a}")
    run("focus", "next", wait=0.8)
    record("focus next follows the layout order", c.dump().get("focused") in (b, cc), f"{c.dump().get('focused')}")

    # Minimise and close through the command line.
    c.activate(TEXTEDIT)
    c.keys("press", "cmd", c.K["n"])
    time.sleep(1.5)
    extra = [i for i in textedit_ids() if i not in ids]
    if extra:
        e = extra[0]
        run("--window-id", str(e), "minimize", wait=1.5)
        record("minimize (by window id) minimises it", e not in textedit_ids())
        c.keys("unminimize", TEXTEDIT)
        time.sleep(1.5)
        run("--window-id", str(e), "close", wait=2.0)
        record("close (by window id) closes it", e not in textedit_ids())

    # Native full screen and back.
    focus(a)
    run("native-fullscreen", "on", wait=3.0)
    state = next((w["state"] for w in ask("list-windows", "--all") or [] if w["window-id"] == a), None)
    record("native-fullscreen on", state == "fullscreen", f"state {state}")
    run("native-fullscreen", "off", wait=3.0)
    state = next((w["state"] for w in ask("list-windows", "--all") or [] if w["window-id"] == a), None)
    record("native-fullscreen off: tiled again", state == "tiled", f"state {state}")

    # Look: dim and border (off by default).
    d = c.dump()
    record("Dim and border are off by default", d.get("decorations") == {"border": False, "dim": False}, f"{d.get('decorations')}")
    run("dim", "on", wait=1.0)
    run("border", "on", wait=1.0)
    c.shot("v3-dim-border")
    d = c.dump()
    record("dim on and border on show them", d.get("decorations") == {"border": True, "dim": True}, f"{d.get('decorations')}")
    focus(a)
    fb = cg()[b]
    c.keys("click", str(fb[0] + fb[2] // 2), str(fb[1] + fb[3] // 2))
    time.sleep(1.0)
    record("A click on a dimmed window still reaches it", c.dump().get("focused") == b, f"focused {c.dump().get('focused')} want {b}")
    d = c.dump()
    record("…and the border follows the focus", d.get("decorations", {}).get("border") is True)
    run("toggle", "dim", wait=0.6)
    run("border", "off", wait=0.6)
    record("…and off again", c.dump().get("decorations") == {"border": False, "dim": False}, f"{c.dump().get('decorations')}")

    # Shell commands get the window's id.
    for path in ("/tmp/tessera-exec.txt",):
        if os.path.exists(path):
            os.remove(path)
    focus(a)
    run("exec-and-forget", "echo $TESSERA_WINDOW_ID > /tmp/tessera-exec.txt", wait=1.0)
    got = open("/tmp/tessera-exec.txt").read().strip() if os.path.exists("/tmp/tessera-exec.txt") else ""
    record("exec-and-forget runs a shell command with TESSERA_WINDOW_ID", got == str(a), f"{got!r} want {a}")


# ---------- events ----------

def subscribe(ids):
    if len(ids) < 2:
        return
    process = subprocess.Popen([CLI, "subscribe", "focus-changed"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    time.sleep(1.0)
    focus(ids[0])
    focus(ids[1])
    time.sleep(1.0)
    process.terminate()
    try:
        out, _ = process.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        out = ""
    events = [json.loads(line) for line in out.splitlines() if line.strip().startswith("{")]
    record("subscribe focus-changed prints a JSON line per focus change",
           any(e.get("event") == "focus-changed" and e.get("window-id") == ids[1] for e in events), out.strip()[:300])


# ---------- desktops ----------

def desktops(ids):
    d = c.dump()
    home, spaces = c.desktops(d)
    if len(spaces) < 2:
        c.keys("space-add")
        time.sleep(1.0)
        home, spaces = c.desktops(c.dump())
    if len(spaces) < 2:
        record("Two desktops for the desktop checks", False, f"{spaces}", warn=True)
        return
    settled = {i: c.frame_of(i) for i in ids}
    moves = c.dump()["autoTile"]["moves"]
    run("desktop", "2", wait=0)
    jumps = c.watch_for_jumps(settled, 2.0)
    now, _ = c.desktops(c.dump())
    record("desktop 2 switches to desktop 2", now == spaces[1], f"now {now}, desktop 2 is {spaces[1]}")
    run("desktop", "last", wait=0)
    jumps += c.watch_for_jumps(settled, 2.0)
    now, _ = c.desktops(c.dump())
    record("desktop last goes back", now == home, f"now {now}, home {home}")
    record("Switching desktops by command: no window jumped (Tree layout)", not jumps, "; ".join(jumps[:4]))
    record("…and Tessera moved nothing", c.settled_dump()["autoTile"]["moves"] == moves,
           f"{c.dump()['autoTile']['moves'] - moves} moves")
    run("desktop", "next", wait=2.0)
    now, _ = c.desktops(c.dump())
    record("desktop next", now == spaces[1], f"now {now}")
    run("desktop", "prev", wait=2.0)
    now, _ = c.desktops(c.dump())
    record("desktop prev", now == home, f"now {now}")

    # Send a window to desktop 2 and follow it; then send it back without following.
    if ids:
        w = ids[-1]
        focus(w)
        run("send-to-desktop", "2", wait=5.0)
        d = c.dump()
        on = next((x["spaces"] for x in d["windows"] if x["id"] == w), [])
        now, _ = c.desktops(d)
        others = [(x["owner"], x["id"], [round(v) for v in x["frame"]]) for x in c.windows()["windows"]][:8]
        record("send-to-desktop 2 takes the window there, and you with it", spaces[1] in on and now == spaces[1],
               f"window on {on}, now {now}; on screen {others}; " + " | ".join(l for l in d.get("log", []) if "Send" in l)[-400:])
        focus(w)
        run("move-node-to-workspace", "1", wait=6.0)
        d = c.dump()
        now, _ = c.desktops(d)
        record("move-node-to-workspace 1 (AeroSpace's) sends it back and you stay", now == spaces[1], f"now {now}")
        run("desktop", "1", wait=2.0)
        time.sleep(1.0)
        record("The window is back on desktop 1", w in [x["id"] for x in c.windows()["windows"]])


# ---------- the config file ----------

def write_config(text):
    os.makedirs(os.path.dirname(CONFIG), exist_ok=True)
    with open(CONFIG, "w") as f:
        f.write(text)


def config_file(ids):
    global CONFIG
    if len(ids) < 3:
        return
    CONFIG = c.dump().get("config", {}).get("path") or CONFIG
    record("Tessera looks for its config file in ~/.config/tessera", CONFIG.endswith("/.config/tessera/tessera.toml"), CONFIG)
    for path in ("/tmp/tessera-focus.log", "/tmp/tessera-desktop.log"):
        if os.path.exists(path):
            os.remove(path)
    write_config("""
layout = 'tree'
on-focus-changed = ['exec-and-forget echo $TESSERA_WINDOW_ID >> /tmp/tessera-focus.log']
exec-on-workspace-change = ['/bin/bash', '-c', 'echo $AEROSPACE_FOCUSED_WORKSPACE >> /tmp/tessera-desktop.log']

[gaps]
inner.horizontal = 10
inner.vertical = 10
outer.left = 20
outer.right = 20
outer.top = 20
outer.bottom = 20

[mode.main.binding]
ctrl-alt-shift-t = 'layout tree'
ctrl-alt-shift-c = 'layout columns'
ctrl-alt-shift-r = 'mode resize'

[mode.resize.binding]
h = 'resize width -50'
l = 'resize width +50'
esc = 'mode main'

[[on-window-detected]]
if.app-id = 'com.apple.TextEdit'
if.window-title-regex-substring = 'float-me'
run = 'layout floating'
""")
    code, out, err = cli("reload-config")
    record("reload-config reads a good file", code == 0, f"{code}: {out.strip()} {err.strip()}")
    d = c.dump()
    record("…with no problems", not d.get("config", {}).get("warnings") and not d.get("config", {}).get("error"), f"{d.get('config')}")
    record("…and every key in it is Tessera's", not d.get("failedKeys"), f"taken: {d.get('failedKeys')}")
    record("…and its modes are known", "resize" in (d.get("modes") or []), f"{d.get('modes')}")
    time.sleep(1.5)
    V = visible()
    f = cg()
    lefts = sorted(f[i][0] for i in ids)
    record("Gaps from the file: 20 at the screen's edges", abs(lefts[0] - (V[0] + 20)) <= 2, f"left-most x {lefts[0]}, screen {V}")
    xs = sorted(ids, key=lambda i: f[i][0])
    if all(f[i][1] == f[xs[0]][1] for i in xs):
        between = f[xs[1]][0] - (f[xs[0]][0] + f[xs[0]][2])
        record("…and 10 between windows", abs(between - 10) <= 2, f"{between}")

    c.keys("press", "ctrl,opt,shift", c.K["c"])
    time.sleep(1.5)
    record("A key from the file runs its command (columns)", main_style() == "columns", f"{main_style()}")
    c.keys("press", "ctrl,opt,shift", c.K["t"])
    time.sleep(1.5)
    record("…and another (tree)", main_style() == "tree", f"{main_style()}")

    # Binding modes: in resize mode, plain h and l resize.
    focus(ids[0])
    c.keys("press", "ctrl,opt,shift", "0x0F")   # r
    time.sleep(0.8)
    code, out, _ = cli("list-modes", "--current")
    record("A key switches to the resize mode", out.strip() == "resize", out.strip())
    old = cg()[ids[0]][2]
    c.keys("press", "", "0x04")   # h
    time.sleep(1.3)
    record("In resize mode, h makes the window 50 points narrower", abs(cg()[ids[0]][2] - (old - 50)) <= 3, f"{old} → {cg()[ids[0]][2]}")
    c.keys("press", "", c.K["esc"])
    time.sleep(0.8)
    code, out, _ = cli("list-modes", "--current")
    record("esc goes back to main", out.strip() == "main", out.strip())
    record("The status menu knows the mode is main again", c.dump().get("mode") == "main")

    # Window rules: a TextEdit document called float-me floats.
    with open("/tmp/tessera-docs/float-me.txt", "w") as fh:
        fh.write("float me\n")
    subprocess.run(["open", "-a", "TextEdit", "/tmp/tessera-docs/float-me.txt"], timeout=20)
    time.sleep(3.0)
    rows = ask("list-windows") or []
    floated = [r for r in rows if "float-me" in r.get("window-title", "")]
    record("A rule from the file floats the matching window", floated and floated[0]["state"] == "floating", f"{floated}")
    for r in floated:
        run("--window-id", str(r["window-id"]), "close", wait=1.0)

    # Callbacks.
    focus(ids[1])
    focus(ids[2])
    time.sleep(1.0)
    log = open("/tmp/tessera-focus.log").read().split() if os.path.exists("/tmp/tessera-focus.log") else []
    record("on-focus-changed runs, with the window's id", str(ids[2]) in log, f"{log[-5:]}")

    # A broken file keeps the last good config.
    write_config("layout = 'tree'\n[gaps\ninner = 4\n")
    code, out, err = cli("reload-config")
    record("A broken file: reload-config fails and says where", code == 1 and "line 2" in err, f"{code}: {err.strip()}")
    time.sleep(1.0)
    f = cg()
    record("…and the last good config stays (gaps still 20)", abs(min(f[i][0] for i in ids) - (V[0] + 20)) <= 2,
           f"{[f[i] for i in ids]}")
    code, out, _ = cli("config")
    record("tessera config shows the problem", code == 0 and "line 2" in out, out.strip()[:300])

    # An AeroSpace config, imported.
    with open(os.path.expanduser("~/.aerospace.toml"), "w") as fh:
        fh.write("""
[gaps]
inner.horizontal = 6
inner.vertical = 6
outer.left = 6
outer.right = 6
outer.top = 6
outer.bottom = 6
[mode.main.binding]
ctrl-alt-shift-j = 'focus down'
alt-shift-a = 'move-node-to-workspace A'
[[on-window-detected]]
if.app-id = 'com.apple.calculator'
run = 'layout floating'
""")
    c.post("import-aerospace", 2.0)
    d = c.dump()
    text = open(CONFIG).read() if os.path.exists(CONFIG) else ""
    header = text.split("\n\n", 1)[0]
    record("Importing an AeroSpace config writes Tessera's file and lists what won't work",
           text.startswith("# Imported from AeroSpace") and "don't work in Tessera" in header, header[:400])
    record("…and keeps the old file as .bak", os.path.exists(CONFIG + ".bak"))
    record("…and Tessera reads it", d.get("config", {}).get("rules") == 1 and not d.get("config", {}).get("error"), f"{d.get('config')}")
    time.sleep(1.0)
    f = cg()
    record("…with its gaps", abs(min(f[i][0] for i in ids) - (V[0] + 6)) <= 2, f"{[f[i] for i in ids]}")

    # No file: back to Settings.
    os.remove(CONFIG)
    if os.path.exists(CONFIG + ".bak"):
        os.remove(CONFIG + ".bak")
    os.remove(os.path.expanduser("~/.aerospace.toml"))
    code, out, _ = cli("reload-config")
    time.sleep(1.5)
    f = cg()
    record("Without a config file, Settings rule again (no gaps)", code == 0 and abs(min(f[i][0] for i in ids) - V[0]) <= 2,
           f"{code}: {out.strip()} {[f[i] for i in ids]}")


# ---------- the end ----------

def tidy():
    for command in ("dim off", "border off", "mode main", "layout auto", "enable off"):
        cli(*command.split())
    c.post("set:layout=auto", 0.5)


def unreachable():
    running = subprocess.run(["pgrep", "-x", "Tessera"], capture_output=True).returncode == 0
    record("Tessera is still running after the 3.0 checks", running)
    subprocess.run(["pkill", "-x", "Tessera"], timeout=10)
    time.sleep(2.0)
    code, _, err = cli("list-windows")
    record("With Tessera quit, the command line tool exits 2 and says so", code == 2 and "isn't running" in err, f"{code}: {err.strip()}")
    code, out, _ = cli("help")
    record("…but help still works", code == 0 and "list-windows" in out)
    code, _, err = cli("focus", "nowhere")
    record("…and a typo is still explained (exit 3)", code == 3, f"{code}: {err.strip()}")


def main():
    if not CLI:
        record("TESSERA_CLI is set for the 3.0 checks", False)
        return
    d = c.dump()
    if not d:
        record("Tessera answers before the 3.0 checks", False)
        return
    command_line()
    ids = tree_layout()
    drop_zones(ids)
    stack_and_float(ids)
    window_commands(ids)
    subscribe(ids)
    config_file(ids)
    desktops(ids)
    tidy()
    unreachable()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:  # Keep going so the results still get saved.
        import traceback
        traceback.print_exc()
        record("3.0 test script finished", False, repr(error))
    # Add these results to check.py's and screens.py's.
    path = f"{OUT}/results.txt"
    old = open(path).read().splitlines()[2:] if os.path.exists(path) else []
    new = [f"{s} {n}" + (f"  ({d})" if d else "") for s, n, d in c.results]
    lines = old + new
    fails = sum(1 for l in lines if l.startswith("FAIL"))
    warns = sum(1 for l in lines if l.startswith("WARN"))
    with open(path, "w") as f:
        f.write(f"{len(lines) - fails - warns} passed, {warns} warnings, {fails} failed\n\n" + "\n".join(lines) + "\n")
    mine = [l for l in new if l.startswith("FAIL")]
    with open(f"{OUT}/results-v3.txt", "w") as f:
        f.write(f"{len(new) - len(mine)} of {len(new)} passed\n\n" + "\n".join(new) + "\n")
    print(open(f"{OUT}/results-v3.txt").read().splitlines()[0])
    sys.exit(1 if mine else 0)
