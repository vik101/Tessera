#!/usr/bin/env python3
"""Localization helper for Tessera.

Every visible string in the Swift code goes through L("..."). The source of truth for
translations is Resources/Localizable.xcstrings (Xcode's String Catalog format, which
Xcode can also edit).

  python3 scripts/strings.py extract  Resources/Localizable.xcstrings   # add new keys, list stale ones
  python3 scripts/strings.py check    Resources/Localizable.xcstrings   # fail if a translation is missing
  python3 scripts/strings.py compile  Resources/Localizable.xcstrings OUT_DIR  # write *.lproj/Localizable.strings
"""
import json
import pathlib
import re
import sys

LANGUAGES = ["es", "ja", "ko", "zh-Hans"]
ROOT = pathlib.Path(__file__).resolve().parent.parent
PATTERN = re.compile(r'\bL\(\s*"((?:[^"\\]|\\.)*)"')


def swift_unescape(text):
    return (text.replace('\\"', '"').replace("\\n", "\n").replace("\\t", "\t").replace("\\\\", "\\"))


def extract_keys():
    keys = set()
    for path in sorted((ROOT / "Sources").rglob("*.swift")):
        for match in PATTERN.finditer(path.read_text(encoding="utf-8")):
            keys.add(swift_unescape(match.group(1)))
    return keys


def load(path):
    path = pathlib.Path(path)
    if path.exists():
        return json.loads(path.read_text(encoding="utf-8"))
    return {"sourceLanguage": "en", "strings": {}, "version": "1.0"}


def save(catalog, path):
    catalog["strings"] = dict(sorted(catalog["strings"].items(), key=lambda item: item[0].lower()))
    pathlib.Path(path).write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def translation(entry, language):
    unit = entry.get("localizations", {}).get(language, {}).get("stringUnit", {})
    return unit.get("value") if unit.get("state") in ("translated", "needs_review") else None


def extract(path):
    catalog = load(path)
    keys = extract_keys()
    added = [key for key in keys if key not in catalog["strings"]]
    for key in added:
        catalog["strings"][key] = {}
    stale = [key for key in catalog["strings"] if key not in keys]
    for key in stale:
        catalog["strings"][key]["extractionState"] = "stale"
    save(catalog, path)
    print(f"{len(keys)} keys, {len(added)} added, {len(stale)} stale")


def check(path):
    catalog = load(path)
    keys = extract_keys()
    missing = []
    for key in sorted(keys):
        entry = catalog["strings"].get(key)
        for language in LANGUAGES:
            if entry is None or not translation(entry, language):
                missing.append((language, key))
            elif entry and translation(entry, language):
                # Format specifiers must match, or the app could crash.
                spec = re.compile(r"%(?:\d+\$)?(?:@|ld|lld|d|f|lf)")
                if sorted(spec.findall(key)) != sorted(spec.findall(translation(entry, language))):
                    missing.append((language, f"{key}  [format specifiers differ]"))
    for language, key in missing:
        print(f"missing {language}: {key}")
    print(f"{len(keys)} keys, {len(missing)} problems")
    sys.exit(1 if missing else 0)


def escape_strings(text):
    return text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def compile_catalog(path, out_dir):
    catalog = load(path)
    out = pathlib.Path(out_dir)
    for language in ["en"] + LANGUAGES:
        lines = []
        for key, entry in catalog["strings"].items():
            value = key if language == "en" else translation(entry, language)
            if value is None:
                continue
            lines.append(f'"{escape_strings(key)}" = "{escape_strings(value)}";')
        folder = out / f"{language}.lproj"
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "Localizable.strings").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Wrote {len(LANGUAGES) + 1} languages to {out}")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    command, catalog_path = sys.argv[1], sys.argv[2]
    if command == "extract":
        extract(catalog_path)
    elif command == "check":
        check(catalog_path)
    elif command == "compile":
        compile_catalog(catalog_path, sys.argv[3])
    else:
        print(__doc__)
        sys.exit(2)
