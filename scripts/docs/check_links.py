#!/usr/bin/env python3
"""Checks every relative link and #anchor in the Markdown docs. Run from the repo's root."""
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
FILES = ["README.md", "CONTRIBUTING.md", "CHANGELOG.md"] + [os.path.join("docs", f) for f in sorted(os.listdir(os.path.join(ROOT, "docs"))) if f.endswith(".md")]


def anchors(path):
    """GitHub's heading anchors: lower case, punctuation dropped, spaces to hyphens, repeats numbered."""
    seen = {}
    found = set()
    in_code = False
    for line in open(path, encoding="utf-8"):
        if line.startswith("```"):
            in_code = not in_code
        if in_code or not line.startswith("#"):
            continue
        title = line.lstrip("#").strip()
        title = re.sub(r"`([^`]*)`", r"\1", title)
        title = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", title)
        slug = re.sub(r"[^\w\- ]", "", title.lower()).replace(" ", "-")
        n = seen.get(slug, 0)
        seen[slug] = n + 1
        found.add(slug if n == 0 else f"{slug}-{n}")
    return found


def links(path):
    text = open(path, encoding="utf-8").read()
    text = re.sub(r"```.*?```", "", text, flags=re.S)
    for target in re.findall(r"\]\(([^)\s]+)\)", text) + re.findall(r'(?:href|src)="([^"]+)"', text):
        if re.match(r"^(https?:|mailto:)", target):
            continue
        yield target


problems = 0
for name in FILES:
    path = os.path.join(ROOT, name)
    if not os.path.exists(path):
        continue
    for target in links(path):
        file_part, _, anchor = target.partition("#")
        dest = os.path.normpath(os.path.join(os.path.dirname(path), file_part)) if file_part else path
        if not os.path.exists(dest):
            print(f"{name}: missing file {target}")
            problems += 1
            continue
        if anchor and dest.endswith(".md") and anchor not in anchors(dest):
            print(f"{name}: missing anchor {target}")
            problems += 1
print(f"{problems} problems in {len(FILES)} files")
sys.exit(1 if problems else 0)
