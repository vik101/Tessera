#!/usr/bin/env python3
"""Writes a one-item Sparkle appcast for a release.

    make_appcast.py --version 2.5.0 --build 9 --url https://…/Tessera.zip \
        --signature 'sparkle:edSignature="…" length="…"' --notes CHANGELOG.md > appcast.xml

The release notes are this version's section of CHANGELOG.md, shown in Sparkle's update window.
"""
import argparse
import email.utils
import html
import re
import sys

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def notes_for(path, version):
    """The bullet lines under '## <version>' in the changelog, as simple HTML."""
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        return ""
    match = re.search(rf"^## {re.escape(version)}\b.*?$(.*?)(?=^## |\Z)", text, re.S | re.M)
    if not match:
        return ""
    items = [line[2:].strip() for line in match.group(1).splitlines() if line.startswith("- ")]
    return "<ul>" + "".join(f"<li>{html.escape(item)}</li>" for item in items) + "</ul>"


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--version", required=True)
    p.add_argument("--build", required=True)
    p.add_argument("--url", required=True)
    p.add_argument("--signature", required=True, help="sign_update's output")
    p.add_argument("--notes", default="CHANGELOG.md")
    p.add_argument("--min-macos", default="15.0")
    a = p.parse_args()

    sig = re.search(r'edSignature="([^"]+)"', a.signature)
    length = re.search(r'length="(\d+)"', a.signature)
    if not sig or not length:
        sys.exit(f"sign_update output not understood: {a.signature!r}")

    notes = notes_for(a.notes, a.version)
    date = email.utils.formatdate(usegmt=True)
    print(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="{SPARKLE}">
  <channel>
    <title>Tessera</title>
    <item>
      <title>Tessera {html.escape(a.version)}</title>
      <pubDate>{date}</pubDate>
      <sparkle:version>{html.escape(a.build)}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(a.version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{html.escape(a.min_macos)}</sparkle:minimumSystemVersion>
      <description><![CDATA[{notes}]]></description>
      <enclosure url="{html.escape(a.url)}" type="application/octet-stream"
                 sparkle:edSignature="{sig.group(1)}" length="{length.group(1)}"/>
    </item>
  </channel>
</rss>""")


if __name__ == "__main__":
    main()
