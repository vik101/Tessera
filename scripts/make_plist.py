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
    "CFBundleLocalizations": ["en", "es", "ja", "ko", "zh-Hans"],
    "CFBundleName": env("APP_NAME", "Tessera"),
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": env("VERSION", "1.0.0"),
    "CFBundleVersion": env("BUILD", "1"),
    "LSApplicationCategoryType": "public.app-category.productivity",
    "LSMinimumSystemVersion": env("MIN_MACOS", "15.0"),
    # Menu bar app: no Dock icon unless a window is open.
    "LSUIElement": True,
    "NSHighResolutionCapable": True,
    "NSHumanReadableCopyright": env("COPYRIGHT"),
    "NSSupportsAutomaticGraphicsSwitching": True,
    # Tessera settings (read by AppConfig.swift).
    "TesseraWebsiteURL": env("WEBSITE_URL"),
    "TesseraDocsURL": env("DOCS_URL"),
    "TesseraSupportEmail": env("SUPPORT_EMAIL"),
    "TesseraCheckoutURL": env("CHECKOUT_URL"),
    "TesseraLicenseAPI": env("LICENSE_API"),
    "TesseraTrialDays": env("TRIAL_DAYS", "2"),
    # Sparkle. Tessera decides when to check, from its own setting.
    "SUFeedURL": env("SPARKLE_FEED_URL"),
    "SUPublicEDKey": env("SPARKLE_PUBLIC_KEY"),
    "SUEnableAutomaticChecks": False,
}

plistlib.dump(plist, sys.stdout.buffer)
