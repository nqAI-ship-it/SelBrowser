#!/usr/bin/env python3
"""Validate portable iOS package inputs. This does not compile Swift or test iOS."""
import json
import plistlib
import re
import struct
from pathlib import Path
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
required = [
    "SelBrowser.xcodeproj/project.pbxproj",
    "SelBrowser.xcodeproj/xcshareddata/xcschemes/SelBrowser.xcscheme",
    "SelBrowser/Info.plist",
    "SelBrowser/Sources/AppDelegate.swift",
    "SelBrowser/Sources/SceneDelegate.swift",
    "SelBrowser/Sources/BrowserModels.swift",
    "SelBrowser/Sources/BrowserViewController.swift",
    "SelBrowser/Sources/BoundedIconRequest.swift",
    "SelBrowser/Sources/BrowserGlass.swift",
    "SelBrowser/Sources/BrowserWebView.swift",
    "SelBrowser/Sources/MobileBrowserChrome.swift",
    "SelBrowser/Sources/TabOverviewController.swift",
    "SelBrowser/Sources/MobileSettingsController.swift",
    "SelBrowser/Resources/Shell.html",
    "SelBrowser/Resources/tailwind.js",
    "SelBrowser/Resources/lucide.js",
    "SelBrowserUITests/BrowserKeyboardTests.swift",
    "scripts/run-ios-keyboard-tests.sh",
    ".github/workflows/ios-build.yml",
]
for name in required:
    assert (root / name).is_file(), f"Missing file: {name}"

info = plistlib.loads((root / "SelBrowser/Info.plist").read_bytes())
assert info["LSRequiresIPhoneOS"] is True
assert info["UIFileSharingEnabled"] is True
assert info["LSSupportsOpeningDocumentsInPlace"] is True
scenes = info["UIApplicationSceneManifest"]["UISceneConfigurations"]["UIWindowSceneSessionRoleApplication"]
assert scenes[0]["UISceneDelegateClassName"] == "$(PRODUCT_MODULE_NAME).SceneDelegate"
ats = info["NSAppTransportSecurity"]
assert ats["NSAllowsArbitraryLoadsInWebContent"] is True
assert not ats.get("NSAllowsArbitraryLoads", False)

project = (root / "SelBrowser.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
definitions = re.findall(r"^\s*([A-F0-9]{24})(?:\s*/\*.*?\*/)?\s*=\s*\{", project, re.M)
assert len(definitions) == len(set(definitions)), "Duplicate Xcode object IDs"
references = set(re.findall(r"\b[A-F0-9]{24}\b", project))
assert references.issubset(definitions), f"Undefined Xcode objects: {references - set(definitions)}"
assert "fileSystemSynchronizedGroups" in project
assert "IPHONEOS_DEPLOYMENT_TARGET = 16.0" in project
assert project.count("PRODUCT_BUNDLE_IDENTIFIER = com.selbrowser.ios;") == 2, "Keep the installed app's identity across updates"
assert project.count("MARKETING_VERSION = 1.1.1;") == 2
assert project.count("CURRENT_PROJECT_VERSION = 3;") == 2
scheme = ET.parse(root / "SelBrowser.xcodeproj/xcshareddata/xcschemes/SelBrowser.xcscheme")
for buildable in scheme.findall(".//BuildableReference"):
    assert buildable.attrib["BlueprintIdentifier"] in definitions

catalog = root / "SelBrowser/Assets.xcassets/AppIcon.appiconset"
contents = json.loads((catalog / "Contents.json").read_text())
for icon in contents["images"]:
    if "filename" not in icon:
        continue
    data = (catalog / icon["filename"]).read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    width, height = struct.unpack(">II", data[16:24])
    assert (width, height) == (1024, 1024)
    assert data[25] == 2, "App icon must be opaque RGB PNG"

workflow = (root / ".github/workflows/ios-build.yml").read_text(encoding="utf-8")
assert "workflow_dispatch:" in workflow
assert "runs-on: macos-15" in workflow
assert "github.event.repository.private == false" in workflow
assert "secrets." not in workflow
assert "SelBrowser-unsigned-IPA" in workflow
assert "capture-ios-previews.sh" in workflow
assert "SelBrowser-iOS-previews" in workflow
preview_script = (root / "scripts/capture-ios-previews.sh").read_bytes()
assert b"\r" not in preview_script, "Simulator script must use Unix LF line endings"
assert b"--sel-ui-preview" in preview_script
script = (root / "scripts/build-ios.sh").read_bytes()
assert b"\r" not in script, "Build script must use Unix LF line endings"
assert b"CODE_SIGNING_ALLOWED=NO" in script
assert b"Payload" in script

html = (root / "SelBrowser/Resources/Shell.html").read_text(encoding="utf-8")
assert "https://sel.browser/" not in html
assert "window.webkit.messageHandlers" in html
assert "window.chrome.webview" not in html
assert not re.search(r"<iframe\b|<webview\b", html, re.I)
for src in re.findall(r'<script[^>]+src="([^"]+)"', html):
    assert "://" not in src and (root / "SelBrowser/Resources" / src).is_file(), src

print(f"PASS: package structure, {len(definitions)} Xcode objects, scheme, plist, icon, resources and unsigned workflow")
print("Swift compilation and iPhone behavior are not verified by this script.")
