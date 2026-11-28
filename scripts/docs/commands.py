#!/usr/bin/env python3
"""Writes docs/commands.md from the code, so the command reference never drifts from the app.

Sources: CommandHelp.swift (every command), SnapAction.swift (every snap and its link name and key),
TextCommand.swift (the short names `place` takes).

Run from the repo's root:  python3 scripts/docs/commands.py
Check mode (fails if the file is out of date):  python3 scripts/docs/commands.py --check
"""
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CORE = os.path.join(ROOT, "Sources", "TesseraCore")
OUT = os.path.join(ROOT, "docs", "commands.md")

GROUPS = {
    "Focus": "Focus", "Move": "Move windows", "Layout": "Layouts", "Tree": "The Tree layout", "Size": "Sizes",
    "Window": "Windows", "Desktop": "Desktops", "Tessera": "Tessera itself", "Ask": "Questions (for scripts and agents)",
}
KEYS = {"leftArrow": "←", "rightArrow": "→", "upArrow": "↑", "downArrow": "↓", "returnKey": "↩", "equal": "=",
        "minus": "−", "delete": "⌫"}
MODS = {"co": "⌃⌥", "co.union(.shift)": "⌃⌥⇧", "co.union(.command)": "⌃⌥⌘"}


def read(*path):
    with open(os.path.join(CORE, *path)) as f:
        return f.read()


def entries():
    text = read("Commands", "CommandHelp.swift")
    pattern = re.compile(r'Entry\(group: "(.*?)", usage: "(.*?)",\s*summary: "(.*?)",\s*aliases: \[(.*?)\], example: "(.*?)"\)',
                         re.S)
    found = []
    for group, usage, summary, aliases, example in pattern.findall(text):
        names = re.findall(r'"(.*?)"', aliases)
        found.append({"group": group, "usage": usage, "summary": summary, "aliases": names, "example": example})
    return found


def snap_actions():
    text = read("Snapping", "SnapAction.swift")
    block = text[text.index("public enum SnapAction"):]
    block = block[:block.index("public var title")]
    cases = []
    for line in block.splitlines():
        line = line.strip()
        if line.startswith("case "):
            cases += [c.strip() for c in line[5:].split(",")]
    titles = dict(re.findall(r'case \.(\w+): "(.*?)"', text[text.index("public var title"):text.index("public var group")]))
    keys = {}
    for name, key, mods in re.findall(r'case \.(\w+): return KeyCombo\(KeyCode\.(\w+), (co(?:\.union\(\.\w+\))?)\)', text):
        keys[name] = MODS[mods] + KEYS.get(key, key.upper())
    place = read("Commands", "TextCommand.swift")
    place = place[place.index("static func place"):]
    short = {}
    for word, action in re.findall(r'"([^"]+)": \.(\w+)', place[:place.index("if let action = named")]):
        short.setdefault(action, []).append(word.replace("centre", "center").replace("maximise", "maximize"))
    rows = []
    for case in cases:
        link = re.sub(r"([A-Z])", r"-\1", case).lower()
        link = (link.replace("centre", "center").replace("maximise", "maximize")
                .replace("quarters", "fourths").replace("quarter", "fourth"))
        rows.append((titles.get(case, case), link, short.get(case, []), keys.get(case, "")))
    return rows


def anchor(name):
    return re.sub(r"[^a-z0-9 -]", "", name.lower()).replace(" ", "-")


def build():
    items = entries()
    out = ["# Command reference", "",
           "<!-- Made by scripts/docs/commands.py from the app's code. Edit CommandHelp.swift, then run the script. -->", "",
           "Every command Tessera understands. You can run each one three ways:", "",
           "| Where | Example |", "| --- | --- |",
           "| The [command line tool](cli.md) | `tessera join right` |",
           "| A key in the [config file](config.md) | `alt-shift-l = 'join right'` |",
           "| A [link](links.md), for Shortcuts and launchers | `open -g 'tessera://run?command=join%20right'` |", "",
           "AeroSpace's and Spacetile's names work too: they are listed under **Also** for each command.",
           "Chain several with `;` (always run the next), `&&` (only if the last worked) and `||` (only if it failed).",
           "Add `--window-id ID` to act on a window other than the one you're in.", ""]
    groups = []
    for item in items:
        if item["group"] not in groups:
            groups.append(item["group"])
    out += ["**Groups:** " + " · ".join(f"[{GROUPS.get(g, g)}](#{anchor(GROUPS.get(g, g))})" for g in groups)
            + " · [Snap names](#snap-names)", ""]
    counts = {}
    for item in items:
        name = item["usage"].split(" ")[0]
        counts[name] = counts.get(name, 0) + 1
    for group in groups:
        out += [f"## {GROUPS.get(group, group)}", ""]
        for item in (i for i in items if i["group"] == group):
            words = item["usage"].split(" ")
            name = words[0]
            if counts[name] > 1 and len(words) > 1:
                name += " " + words[1].split("|")[0]   # focus left, focus --window-id, layout tiles…
            out += [f"### {name}", "", "```", "tessera " + item["usage"], "```", "", item["summary"], "",
                    f"Example: `tessera {item['example']}`"]
            if item["aliases"]:
                out += ["", "Also: " + ", ".join(f"`{a}`" for a in item["aliases"])]
            out += [""]
    out += ["## Snap names", "",
            "`place NAME` (and `tessera://execute-action?name=NAME`) takes any of these. Short names work with `place` only.",
            "Keys are the defaults; change them in Settings.", "",
            "| Action | Link name | Short names for `place` | Key |", "| --- | --- | --- | --- |"]
    for title, link, short, key in snap_actions():
        out.append(f"| {title} | `{link}` | {', '.join(f'`{s}`' for s in short)} | {key} |")
    out.append("")
    return "\n".join(out)


def main():
    text = build()
    if "--check" in sys.argv:
        current = open(OUT).read() if os.path.exists(OUT) else ""
        if current != text:
            print("docs/commands.md is out of date: run python3 scripts/docs/commands.py")
            sys.exit(1)
        print("docs/commands.md is up to date")
        return
    with open(OUT, "w") as f:
        f.write(text)
    print(f"wrote docs/commands.md ({len(entries())} commands, {len(snap_actions())} snap names)")


if __name__ == "__main__":
    main()
