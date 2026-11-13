#!/usr/bin/env python3
"""Writes the app's Info.plist from scripts/config.env values (passed as environment variables)."""
import os
import plistlib
import sys


def env(name, default=""):
    return os.environ.get(name, default)


plist = {
    "CFBundleDevelopmentRegion": "en",
    "CFBundleDisplayName": env("APP_NAME", "Tessera"),
    "CFBundleExecutable": env("APP_NAME", "Tessera"),
    "CFBundleIconFile": "AppIcon",
    "CFBundleIdentifier": env("BUNDLE_ID", "com.example.Tessera"),
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": env("APP_NAME", "Tessera"),
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": env("VERSION", "1.0.0"),
    "CFBundleVersion": env("BUILD", "1"),
    "LSApplicationCategoryType": "public.app-category.productivity",
    "LSMinimumSystemVersion": env("MIN_MACOS", "15.0"),
    # Menu bar app: no Dock icon.
    "LSUIElement": True,
    "NSHighResolutionCapable": True,
    "NSHumanReadableCopyright": env("COPYRIGHT"),
}

plistlib.dump(plist, sys.stdout.buffer)
