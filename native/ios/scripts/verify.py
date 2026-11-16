#!/usr/bin/env python3
"""Static checks for the native shell and its build configuration.

These checks run on any machine with python3 (no Xcode needed) and again at the start of
every workflow, so a broken plist, a missing source file or a project file that drifted
from the folder is caught before a 20-minute macOS build.

    python3 native/ios/scripts/verify.py
"""
from __future__ import annotations

import json
import plistlib
import re
import struct
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
IOS = REPO / "native" / "ios"
APP = IOS / "OrunHomework"
PROJECT = IOS / "OrunHomework.xcodeproj"
PBXPROJ = PROJECT / "project.pbxproj"
SCHEME = PROJECT / "xcshareddata" / "xcschemes" / "OrunHomework.xcscheme"

EXPECTED_BUNDLE_ID = "com.orunhomework.app"
EXPECTED_HOST = "orunhomework.com"

failures: list[str] = []
notes: list[str] = []


def check(condition: bool, message: str) -> None:
    if condition:
        notes.append("PASS  " + message)
    else:
        failures.append(message)


def read_plist(path: Path) -> dict:
    with path.open("rb") as handle:
        return plistlib.load(handle)


def png_header(path: Path) -> tuple[int, int, int]:
    with path.open("rb") as handle:
        header = handle.read(33)
    assert header[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    width, height = struct.unpack(">II", header[16:24])
    depth_and_type = header[24:26]
    return width, height, depth_and_type[1]


# 1. Required files -----------------------------------------------------------
required = [
    APP / "OrunHomeworkApp.swift",
    APP / "Site.swift",
    APP / "WebShellModel.swift",
    APP / "WebShellScripts.swift",
    APP / "WebShellView.swift",
    APP / "Info.plist",
    APP / "PrivacyInfo.xcprivacy",
    APP / "Assets.xcassets" / "Contents.json",
    APP / "Assets.xcassets" / "AppIcon.appiconset" / "Contents.json",
    APP / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon.png",
    APP / "Assets.xcassets" / "LaunchBackground.colorset" / "Contents.json",
    PBXPROJ,
    SCHEME,
]
for path in required:
    check(path.exists(), f"file exists: {path.relative_to(REPO)}")

if failures:
    print("\n".join(failures))
    sys.exit(1)

# 2. Info.plist ---------------------------------------------------------------
info = read_plist(APP / "Info.plist")
usage_keys = ["NSMicrophoneUsageDescription", "NSCameraUsageDescription", "NSPhotoLibraryUsageDescription"]
for key in usage_keys:
    value = info.get(key)
    check(isinstance(value, str) and len(value.strip()) >= 10, f"Info.plist {key} has a real Korean purpose string")
check(info.get("ITSAppUsesNonExemptEncryption") is False, "Info.plist declares no non-exempt encryption")
check(info.get("CFBundleDisplayName") == "옳은홈워크", "Info.plist display name is 옳은홈워크")
check(info.get("CFBundleVersion") == "$(CURRENT_PROJECT_VERSION)", "Info.plist build number comes from the project")
check(info.get("CFBundleShortVersionString") == "$(MARKETING_VERSION)", "Info.plist version comes from the project")
check(isinstance(info.get("UILaunchScreen"), dict) and info["UILaunchScreen"].get("UIColorName") == "LaunchBackground",
      "launch screen uses the site's dark background instead of a white flash")
check(info.get("UIStatusBarStyle") == "UIStatusBarStyleLightContent", "status bar text is light over the dark chrome")
for key in ("UISupportedInterfaceOrientations", "UISupportedInterfaceOrientations~ipad"):
    check(isinstance(info.get(key), list) and len(info[key]) >= 2, f"Info.plist {key} declares orientations")
check("NSAppTransportSecurity" not in info, "no ATS exception: the app only loads HTTPS")

# 3. Privacy manifest --------------------------------------------------------
privacy = read_plist(APP / "PrivacyInfo.xcprivacy")
check(privacy.get("NSPrivacyTracking") is False, "privacy manifest: no tracking")
check(privacy.get("NSPrivacyCollectedDataTypes") == [], "privacy manifest: shell collects no data types itself")
check(privacy.get("NSPrivacyAccessedAPITypes") == [], "privacy manifest: no required-reason APIs")

# 4. Asset catalog -----------------------------------------------------------
for manifest in APP.glob("Assets.xcassets/**/Contents.json"):
    try:
        json.loads(manifest.read_text(encoding="utf-8"))
        notes.append(f"PASS  valid JSON: {manifest.relative_to(REPO)}")
    except json.JSONDecodeError as error:
        failures.append(f"invalid JSON in {manifest.relative_to(REPO)}: {error}")

icon = APP / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon.png"
width, height, color_type = png_header(icon)
check((width, height) == (1024, 1024), f"app icon is 1024x1024 (found {width}x{height})")
check(color_type in (0, 2), f"app icon has no alpha channel (PNG colour type {color_type})")

# 5. Site constants ----------------------------------------------------------
site_source = (APP / "Site.swift").read_text(encoding="utf-8")
check(f'static let host = "{EXPECTED_HOST}"' in site_source, f"shell loads {EXPECTED_HOST}")
check("https://orunhomework.com/" in site_source, "shell loads the HTTPS root of the live site")
model_source = (APP / "WebShellModel.swift").read_text(encoding="utf-8")
check("reloadIgnoringLocalCacheData" in model_source, "document request bypasses the local cache")
check("websiteDataStore = .default()" in model_source, "session storage persists between launches")
check("requestMediaCapturePermissionFor" in model_source, "web view grants capture to the trusted origin")

# 6. Project file ------------------------------------------------------------
pbxproj = PBXPROJ.read_text(encoding="utf-8")
check(pbxproj.startswith("// !$*UTF8*$!"), "project file has the plist header")
check(pbxproj.count("{") == pbxproj.count("}"), "project file braces balance")
check(pbxproj.count("(") == pbxproj.count(")"), "project file parentheses balance")
check(f"PRODUCT_BUNDLE_IDENTIFIER = {EXPECTED_BUNDLE_ID};" in pbxproj, f"bundle id is {EXPECTED_BUNDLE_ID}")
check("IPHONEOS_DEPLOYMENT_TARGET = 15.0;" in pbxproj, "deployment target stays iOS 15.0 like the shipped app")
check('productType = "com.apple.product-type.application";' in pbxproj, "target is an iOS application")
check("INFOPLIST_FILE = OrunHomework/Info.plist;" in pbxproj, "target uses the checked-in Info.plist")
check("ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;" in pbxproj, "target compiles the app icon")

objects = dict(re.findall(r"\n\t\t([0-9A-F]{24}) = \{ (.*?)\};", pbxproj, flags=re.S))
check(len(objects) >= 20, f"project file parses into {len(objects)} objects")
missing_refs = [ref for ref in re.findall(r"fileRef = ([0-9A-F]{24})", pbxproj) if ref not in objects]
check(not missing_refs, "every build file points at a file reference")

for file_ref in re.findall(r'path = (OrunHomework/[^;]+?); sourceTree', pbxproj):
    check((IOS / file_ref).exists(), f"project references an existing file: {file_ref}")

listed = set(re.findall(r'path = OrunHomework/([A-Za-z]+\.swift); sourceTree', pbxproj))
on_disk = {p.name for p in APP.glob("*.swift")}
check(listed == on_disk, f"project lists every Swift file (project {sorted(listed)} vs folder {sorted(on_disk)})")

# 7. Scheme ------------------------------------------------------------------
try:
    tree = ET.parse(SCHEME)
    identifier = tree.getroot().find(".//BuildableReference").get("BlueprintIdentifier")
    check(identifier in objects, "scheme points at the app target that exists")
    check(tree.getroot().find(".//BuildableReference").get("BuildableName") == "OrunHomework.app",
          "scheme builds OrunHomework.app")
except (ET.ParseError, AttributeError) as error:
    failures.append(f"scheme XML problem: {error}")

# 8. Workflows ---------------------------------------------------------------
workflows = sorted((REPO / ".github" / "workflows").glob("*.yml"))
check(bool(workflows), "workflows folder has workflow definitions")
try:
    import yaml  # optional; CI installs nothing, so fall back to a structural check
except ImportError:  # pragma: no cover
    yaml = None

for workflow in workflows:
    text = workflow.read_text(encoding="utf-8")
    if yaml is not None:
        try:
            document = yaml.safe_load(text)
            check(isinstance(document, dict) and "jobs" in document, f"{workflow.name} parses as YAML with jobs")
            for job in (document.get("jobs") or {}).values():
                for step in job.get("steps") or []:
                    script = step.get("run") or ""
                    for path in re.findall(r"(native/ios/[A-Za-z0-9_./-]+)", script):
                        if path.endswith("/"):
                            continue
                        trimmed = path.rstrip("/")
                        check((REPO / trimmed).exists() or "build" in trimmed,
                              f"{workflow.name} references an existing path: {trimmed}")
        except yaml.YAMLError as error:
            failures.append(f"{workflow.name} is not valid YAML: {error}")
    else:
        check("\t" not in text, f"{workflow.name} uses spaces, not tabs")
        check("jobs:" in text and "runs-on:" in text, f"{workflow.name} declares jobs on a runner")

print("\n".join(notes))
print()
if failures:
    print("FAILED CHECKS")
    print("\n".join(" - " + failure for failure in failures))
    sys.exit(1)
print(f"All checks passed ({len(notes)} checks).")
