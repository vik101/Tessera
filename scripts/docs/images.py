#!/usr/bin/env python3
"""Draws the pictures in docs/images (SVG): layouts, snap keys, snap areas, the Tree layout, windows in front.

Run from the repo's root:  python3 scripts/docs/images.py
Each picture has its own light background, so it reads the same in GitHub's light and dark themes.
"""
import os

OUT = os.path.join(os.path.dirname(__file__), "..", "..", "docs", "images")

FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"
MONO = "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"
PAPER = "#ffffff"
EDGE = "#d0d7de"
INK = "#1f2328"
SOFT = "#59636e"
SCREEN = "#eef1f5"
WINDOW = "#c9d4e3"
WINDOW_EDGE = "#8a9bb3"
ACCENT = "#4c9aff"
ACCENT_EDGE = "#1f6feb"
WAIT = "#f3f4f6"


def svg(width, height, body, title):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" width="{width}" height="{height}" '
            f'role="img" aria-label="{title}">\n<title>{title}</title>\n'
            f'<rect x="0.5" y="0.5" width="{width - 1}" height="{height - 1}" rx="12" fill="{PAPER}" stroke="{EDGE}"/>\n'
            f'{body}</svg>\n')


def text(x, y, s, size=15, weight="normal", anchor="middle", color=INK, font=FONT):
    s = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    return (f'<text x="{x}" y="{y}" font-family="{font}" font-size="{size}" font-weight="{weight}" '
            f'text-anchor="{anchor}" fill="{color}">{s}</text>\n')


def screen(x, y, w, h):
    return f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" fill="{SCREEN}" stroke="{WINDOW_EDGE}" stroke-width="1.5"/>\n'


def win(x, y, w, h, focus=False, label=None, dashed=False, fill=None, size=13):
    f = fill or (ACCENT if focus else WINDOW)
    stroke = ACCENT_EDGE if focus else WINDOW_EDGE
    dash = ' stroke-dasharray="5 4"' if dashed else ""
    out = f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" rx="4" fill="{f}" stroke="{stroke}" stroke-width="1.5"{dash}/>\n'
    if label:
        out += text(x + w / 2, y + h / 2 + size * 0.35, label, size=size, weight="bold", color="#ffffff" if focus else INK)
    return out


def arrow(x1, y1, x2, y2, color=SOFT):
    return (f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{color}" stroke-width="2" marker-end="url(#head)"/>\n')


MARKER = (f'<defs><marker id="head" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto">'
          f'<path d="M0,0 L10,5 L0,10 z" fill="{SOFT}"/></marker></defs>\n')


def tiles(x, y, w, h, parts, gap=4, focus=0, labels=None):
    """parts: list of (fx, fy, fw, fh) shares of the screen."""
    out = ""
    for i, (fx, fy, fw, fh) in enumerate(parts):
        out += win(x + fx * w + gap / 2, y + fy * h + gap / 2, fw * w - gap, fh * h - gap, focus=(i == focus),
                   label=labels[i] if labels else None)
    return out


# ---------- layouts ----------

def layouts():
    W, H = 900, 520
    cell_w, cell_h = 190, 119
    body = text(W / 2, 40, "Eight layout styles: pick one per desktop, with one key", size=20, weight="bold")
    third = 1 / 3
    styles = [
        ("Auto", "⌃⌥1", [(0, 0, .5, 1), (.5, 0, .5, .5), (.5, .5, .5, .5)], "picks for you"),
        ("Columns", "⌃⌥2", [(0, 0, third, 1), (third, 0, third, 1), (2 * third, 0, third, 1)], "side by side"),
        ("Rows", "⌃⌥3", [(0, 0, 1, third), (0, third, 1, third), (0, 2 * third, 1, third)], "one above another"),
        ("Grid", "⌃⌥4", [(0, 0, third, .5), (third, 0, third, .5), (2 * third, 0, third, .5),
                         (0, .5, .5, .5), (.5, .5, .5, .5)], "even grid"),
        ("Main + Side", "⌃⌥5", [(0, 0, .6, 1), (.6, 0, .4, third), (.6, third, .4, third), (.6, 2 * third, .4, third)],
         "one big, the rest beside"),
        ("Tree", "⌃⌥6", [(0, 0, .5, 1), (.5, 0, .5, .5), (.5, .5, .25, .5), (.75, .5, .25, .5)], "you split by hand"),
        ("Stack", "⌃⌥7", None, "each fills the desktop"),
        ("Float", "⌃⌥8", None, "Tessera hands off"),
    ]
    for i, (name, key, parts, note) in enumerate(styles):
        col, row = i % 4, i // 4
        x = 30 + col * (cell_w + 23)
        y = 70 + row * (cell_h + 95)
        body += screen(x, y, cell_w, cell_h)
        if parts:
            body += tiles(x + 4, y + 4, cell_w - 8, cell_h - 8, parts)
        elif name == "Stack":
            for k in range(3, -1, -1):
                body += win(x + 8 + k * 6, y + 8 + k * 6, cell_w - 40, cell_h - 40, focus=(k == 0))
        else:
            body += win(x + 14, y + 16, 90, 58)
            body += win(x + 84, y + 44, 86, 56, focus=True)
            body += win(x + 40, y + 70, 70, 40)
        body += text(x + cell_w / 2, y + cell_h + 26, name, size=17, weight="bold")
        body += text(x + cell_w / 2, y + cell_h + 48, f"{key} · {note}", size=14, color=SOFT)
    body += text(W / 2, H - 22, "Blue is the window you're in. ⌃⌥L steps through the first five.", size=14, color=SOFT)
    return svg(W, H, body, "Tessera's eight layout styles")


# ---------- snap keys ----------

def snap_keys():
    W, H = 900, 700
    cell_w, cell_h = 150, 94
    third = 1 / 3
    actions = [
        ("Left Half", "⌃⌥←", (0, 0, .5, 1)), ("Right Half", "⌃⌥→", (.5, 0, .5, 1)),
        ("Top Half", "⌃⌥↑", (0, 0, 1, .5)), ("Bottom Half", "⌃⌥↓", (0, .5, 1, .5)),
        ("Top Left", "⌃⌥U", (0, 0, .5, .5)), ("Top Right", "⌃⌥I", (.5, 0, .5, .5)),
        ("Bottom Left", "⌃⌥J", (0, .5, .5, .5)), ("Bottom Right", "⌃⌥K", (.5, .5, .5, .5)),
        ("First Third", "⌃⌥D", (0, 0, third, 1)), ("Centre Third", "⌃⌥F", (third, 0, third, 1)),
        ("Last Third", "⌃⌥G", (2 * third, 0, third, 1)), ("First Two Thirds", "⌃⌥E", (0, 0, 2 * third, 1)),
        ("Last Two Thirds", "⌃⌥T", (third, 0, 2 * third, 1)), ("Maximise", "⌃⌥↩", (0, 0, 1, 1)),
        ("Maximise Height", "⌃⌥⇧↑", (.3, 0, .4, 1)), ("Centre", "⌃⌥C", (.25, .2, .5, .6)),
    ]
    body = text(W / 2, 40, "Snap one window with a key (Rectangle's keys)", size=20, weight="bold")
    for i, (name, key, (fx, fy, fw, fh)) in enumerate(actions):
        col, row = i % 4, i // 4
        x = 42 + col * (cell_w + 66)
        y = 70 + row * (cell_h + 52)
        body += screen(x, y, cell_w, cell_h)
        body += win(x + 3 + fx * (cell_w - 6), y + 3 + fy * (cell_h - 6), fw * (cell_w - 6), fh * (cell_h - 6), focus=True)
        body += text(x + cell_w / 2, y + cell_h + 20, name, size=14, weight="bold")
        body += text(x + cell_w / 2, y + cell_h + 38, key, size=14, color=SOFT)
    body += text(W / 2, H - 20, "Press ⌃⌥← or ⌃⌥→ again for ⅔, then ⅓. ⌃⌥⌫ puts the window back.", size=14, color=SOFT)
    return svg(W, H, body, "Tessera's snap keys and where each puts a window")


# ---------- snap areas ----------

def snap_areas():
    W, H = 900, 500
    x, y, w, h = 210, 92, 480, 300
    zone = "#cfe3ff"
    body = MARKER + text(W / 2, 40, "Drag a window by its title bar to an edge or corner", size=20, weight="bold")
    body += screen(x, y, w, h)
    e, c = 22, 60  # edge strip, corner size
    # Edges.
    body += f'<rect x="{x + c}" y="{y}" width="{w - 2 * c}" height="{e}" fill="{zone}"/>\n'
    body += f'<rect x="{x}" y="{y + c}" width="{e}" height="{h - 2 * c}" fill="{zone}"/>\n'
    body += f'<rect x="{x + w - e}" y="{y + c}" width="{e}" height="{h - 2 * c}" fill="{zone}"/>\n'
    for k in range(3):
        bx = x + c + k * (w - 2 * c) / 3
        body += f'<rect x="{bx + 2}" y="{y + h - e}" width="{(w - 2 * c) / 3 - 4}" height="{e}" fill="{zone}"/>\n'
    for cx, cy in [(x, y), (x + w - c, y), (x, y + h - c), (x + w - c, y + h - c)]:
        body += f'<rect x="{cx}" y="{cy}" width="{c}" height="{c}" rx="4" fill="{ACCENT}" opacity="0.55"/>\n'
    body += text(x + w / 2, y + h / 2 - 6, "a window you drag", size=15, color=SOFT)
    body += text(x + w / 2, y + h / 2 + 16, "(a blue outline shows where it goes)", size=14, color=SOFT)
    # Labels.
    body += text(x + w / 2, y - 12, "top edge: maximise", size=15, weight="bold")
    body += text(x - 14, y + h / 2 + 5, "left edge:", size=15, weight="bold", anchor="end")
    body += text(x - 14, y + h / 2 + 25, "left half", size=15, anchor="end")
    body += text(x + w + 14, y + h / 2 + 5, "right edge:", size=15, weight="bold", anchor="start")
    body += text(x + w + 14, y + h / 2 + 25, "right half", size=15, anchor="start")
    body += text(x + w / 2, y + h + 26, "bottom edge: a third (left, middle or right)", size=15, weight="bold")
    body += text(x - 14, y + 30, "corners:", size=15, weight="bold", anchor="end")
    body += text(x - 14, y + 50, "a quarter", size=15, anchor="end")
    body += text(W / 2, H - 22, "Drag a snapped window away and it gets its old size back.", size=14, color=SOFT)
    return svg(W, H, body, "Where to drag a window to snap it")


# ---------- the Tree layout ----------

def tree():
    W, H = 900, 400
    body = MARKER + text(W / 2, 40, "The Tree layout: splits inside splits", size=20, weight="bold")

    def node(cx, cy, label, sub, kind):
        fill = ACCENT if kind == "window" else "#ffffff"
        color = "#ffffff" if kind == "window" else INK
        w = 120 if kind == "window" else 170
        out = f'<rect x="{cx - w / 2}" y="{cy - 26}" width="{w}" height="52" rx="8" fill="{fill}" stroke="{ACCENT_EDGE if kind == "window" else WINDOW_EDGE}" stroke-width="1.5"/>\n'
        out += text(cx, cy - 3, label, size=16, weight="bold", color=color)
        out += text(cx, cy + 16, sub, size=12, color=color if kind == "window" else SOFT)
        return out

    def link(x1, y1, x2, y2):
        return f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{WINDOW_EDGE}" stroke-width="2"/>\n'

    # Tree on the left.
    body += link(200, 120, 105, 205) + link(200, 120, 300, 205)
    body += link(300, 230, 240, 305) + link(300, 230, 370, 305)
    body += node(200, 110, "H split", "side by side", "split")
    body += node(105, 215, "a", "window", "window")
    body += node(300, 215, "V split", "one above another", "split")
    body += node(240, 315, "b", "window", "window")
    body += node(370, 315, "c", "window", "window")
    body += arrow(455, 210, 520, 210)
    body += text(487, 196, "makes", size=13, color=SOFT)
    # The screen it makes.
    sx, sy, sw, sh = 540, 100, 320, 210
    body += screen(sx, sy, sw, sh)
    body += win(sx + 6, sy + 6, sw / 2 - 9, sh - 12, focus=True, label="a", size=20)
    body += win(sx + sw / 2 + 3, sy + 6, sw / 2 - 9, sh / 2 - 9, label="b", size=20)
    body += win(sx + sw / 2 + 3, sy + sh / 2 + 3, sw / 2 - 9, sh / 2 - 9, label="c", size=20)
    body += text(sx + sw / 2, sy + sh + 28, "tessera tree  →  H[a V[b c]]", size=15, font=MONO)
    body += text(W / 2, H - 18, "Windows are the leaves. Each split runs one way and can be tiles or an accordion.",
                 size=14, color=SOFT)
    return svg(W, H, body, "How a Tree layout's splits become windows on the screen")


def tree_steps():
    W, H = 900, 300
    pw, ph = 150, 100
    body = MARKER + text(W / 2, 40, "Changing the tree, one command at a time", size=20, weight="bold")
    xs = [24, 266, 508, 750]
    y = 104
    half, third = 0.5, 1 / 3
    panels = [
        [(0, 0, third, 1, "a"), (third, 0, third, 1, "b"), (2 * third, 0, third, 1, "c")],
        [(0, 0, half, 1, "a"), (half, 0, half, half, "b"), (half, half, half, half, "c")],
        [(0, 0, third, 1, "a"), (third, 0, third, 1, "c"), (2 * third, 0, third, 1, "b")],
        None,
    ]
    focus = ["b", "b", "c", "c"]
    captions = ["H[a b c]", "H[a V[b c]]", "H[a c b]", "HA[a c b]"]
    commands = [["join right"], ["move left"], ["layout", "accordion"]]
    for i, x in enumerate(xs):
        body += screen(x, y, pw, ph)
        if panels[i]:
            for fx, fy, fw, fh, name in panels[i]:
                body += win(x + 4 + fx * (pw - 8) + 2, y + 4 + fy * (ph - 8) + 2, fw * (pw - 8) - 4, fh * (ph - 8) - 4,
                            focus=(name == focus[i]), label=name, size=16)
        else:
            # Accordion: every window spans the split, less a strip for each neighbour.
            body += win(x + 6, y + 6, pw - 12 - 30, ph - 12, label=None)
            body += win(x + 6 + 30, y + 6, pw - 12 - 30, ph - 12, label=None)
            body += win(x + 6 + 15, y + 6, pw - 12 - 30, ph - 12, focus=True, label="c", size=16)
            body += text(x + 13, y + ph / 2 + 5, "a", size=12, weight="bold")
            body += text(x + pw - 13, y + ph / 2 + 5, "b", size=12, weight="bold")
        body += text(x + pw / 2, y + ph + 26, captions[i], size=14, font=MONO, color=SOFT)
        if i < 3:
            mid = (x + pw + xs[i + 1]) / 2
            body += arrow(x + pw + 10, y + ph / 2, xs[i + 1] - 10, y + ph / 2)
            lines = commands[i]
            for k, line in enumerate(lines):
                body += text(mid, y + ph / 2 - 12 - (len(lines) - 1 - k) * 17, line, size=13, font=MONO)
    body += text(W / 2, H - 22, "Blue is the window you're in; each command acts on it.", size=14, color=SOFT)
    return svg(W, H, body, "Three Tree commands: join, move and accordion")


# ---------- windows in front ----------

def front_windows():
    W, H = 900, 400
    body = MARKER + text(W / 2, 40, "A few windows sit in front; the rest wait off the edge", size=20, weight="bold")
    sw, sh = 330, 200

    def panel(x, front, waiting, focus):
        y = 80
        out = screen(x, y, sw, sh)
        third = (sw - 12) / 3
        for i, name in enumerate(front):
            out += win(x + 6 + i * third + 2, y + 6, third - 4, sh - 12, focus=(name == focus), label=name, size=14)
        out += text(x + 6, y + sh + 38, "waiting:", size=14, color=SOFT, anchor="start")
        for k, name in enumerate(waiting):
            out += win(x + 80 + k * 110, y + sh + 16, 100, 34, dashed=True, fill=WAIT, label=name, size=13)
        return out

    body += panel(40, ["Safari", "Terminal", "TextEdit"], ["Chrome", "Mail"], None)
    body += arrow(390, 180, 500, 180)
    body += text(445, 160, "click Chrome", size=13, color=SOFT)
    body += text(445, 206, "in the Dock", size=13, color=SOFT)
    body += panel(530, ["Safari", "Terminal", "Chrome"], ["TextEdit", "Mail"], "Chrome")
    body += text(W / 2, H - 18, "Chrome takes the spot of the window you used least lately. Nothing else moves.",
                 size=14, color=SOFT)
    return svg(W, H, body, "How a waiting window comes forward")


def main():
    os.makedirs(OUT, exist_ok=True)
    pictures = {
        "layouts.svg": layouts(), "snap-keys.svg": snap_keys(), "snap-areas.svg": snap_areas(),
        "tree.svg": tree(), "tree-steps.svg": tree_steps(), "front-windows.svg": front_windows(),
    }
    for name, content in pictures.items():
        with open(os.path.join(OUT, name), "w") as f:
            f.write(content)
        print("wrote docs/images/" + name)


if __name__ == "__main__":
    main()
