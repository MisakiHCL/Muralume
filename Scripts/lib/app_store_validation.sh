#!/usr/bin/env bash

# Validation helpers for the Mac App Store archive workflow. This file is
# intended to be sourced by release_app_store.sh and its fault-injection tests.

validate_app_store_entitlements() {
    if [[ "$#" -ne 4 ]]; then
        echo "App Store entitlement validation needs Python, a plist, a Team, and a bundle ID." >&2
        return 64
    fi

    local python_path="$1"
    # Avoid colliding with the release script's readonly path under Bash's
    # dynamic scoping rules.
    local signed_entitlements_path="$2"
    local expected_team="$3"
    local expected_bundle_identifier="$4"

    "${python_path}" -c '
import plistlib
import sys

path, team, bundle_identifier = sys.argv[1:]
with open(path, "rb") as stream:
    actual = plistlib.load(stream)

required = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.files.bookmarks.app-scope": True,
    "com.apple.security.files.user-selected.read-only": True,
    "com.apple.application-identifier": f"{team}.{bundle_identifier}",
    "com.apple.developer.team-identifier": team,
}
allowed = set(required) | {
    "beta-reports-active",
    "com.apple.security.get-task-allow",
}

if not isinstance(actual, dict):
    raise SystemExit(1)
if any(actual.get(key) != value for key, value in required.items()):
    raise SystemExit(1)
if set(actual) - allowed:
    raise SystemExit(1)
if actual.get("com.apple.security.get-task-allow", False) is not False:
    raise SystemExit(1)
if "beta-reports-active" in actual and actual["beta-reports-active"] is not True:
    raise SystemExit(1)
' "${signed_entitlements_path}" "${expected_team}" "${expected_bundle_identifier}"
}

validate_app_store_provisioning_profile() {
    if [[ "$#" -ne 4 ]]; then
        echo "App Store profile validation needs Python, a plist, a Team, and a bundle ID." >&2
        return 64
    fi

    local python_path="$1"
    local profile_path="$2"
    local expected_team="$3"
    local expected_bundle_identifier="$4"

    "${python_path}" -c '
import datetime
import plistlib
import sys

path, team, bundle_identifier = sys.argv[1:]
with open(path, "rb") as stream:
    profile = plistlib.load(stream)

if not isinstance(profile, dict):
    raise SystemExit(1)
teams = profile.get("TeamIdentifier")
prefixes = profile.get("ApplicationIdentifierPrefix")
entitlements = profile.get("Entitlements")
platforms = profile.get("Platform")
expiration = profile.get("ExpirationDate")

if teams != [team] or prefixes != [team]:
    raise SystemExit(1)
if not isinstance(entitlements, dict):
    raise SystemExit(1)
if entitlements.get("com.apple.application-identifier") != f"{team}.{bundle_identifier}":
    raise SystemExit(1)
if entitlements.get("com.apple.developer.team-identifier") != team:
    raise SystemExit(1)
if entitlements.get("com.apple.security.get-task-allow", False) is not False:
    raise SystemExit(1)
if profile.get("ProvisionsAllDevices", False) is not False:
    raise SystemExit(1)
if "ProvisionedDevices" in profile:
    raise SystemExit(1)
if not isinstance(platforms, list) or not ({"OSX", "macOS"} & set(platforms)):
    raise SystemExit(1)
if not isinstance(expiration, datetime.datetime):
    raise SystemExit(1)
now = datetime.datetime.now(expiration.tzinfo) if expiration.tzinfo else datetime.datetime.now()
if expiration <= now:
    raise SystemExit(1)
' "${profile_path}" "${expected_team}" "${expected_bundle_identifier}"
}

validate_app_store_bom_permissions() {
    if [[ "$#" -ne 2 ]]; then
        echo "App Store package permissions need lsbom and a Bom path." >&2
        return 64
    fi

    local bom_lsbom_path="$1"
    local bom_manifest_path="$2"

    "${bom_lsbom_path}" -p m "${bom_manifest_path}" | awk '
        $1 ~ /^100[0-7][0-7][0-7]$/ {
            regular_file_count += 1
            other_permissions = substr($1, 6, 1) + 0
            if (other_permissions < 4) invalid_permissions = 1
        }
        $1 ~ /^40[0-7][0-7][0-7]$/ {
            directory_count += 1
            other_permissions = substr($1, 5, 1) + 0
            if (other_permissions != 5 && other_permissions != 7) {
                invalid_permissions = 1
            }
        }
        END {
            if (regular_file_count == 0 || directory_count == 0) exit 1
            exit invalid_permissions ? 1 : 0
        }
    '
}

validate_app_store_info_plist() {
    if [[ "$#" -ne 5 ]]; then
        echo "App Store Info.plist validation needs Python, a plist, bundle ID, version, and build." >&2
        return 64
    fi

    local python_path="$1"
    local info_path="$2"
    local expected_bundle_identifier="$3"
    local expected_marketing_version="$4"
    local expected_build_number="$5"

    "${python_path}" -c '
import plistlib
import sys

path, bundle_identifier, marketing_version, build_number = sys.argv[1:]
with open(path, "rb") as stream:
    info = plistlib.load(stream)

expected = {
    "CFBundleIdentifier": bundle_identifier,
    "CFBundleShortVersionString": marketing_version,
    "CFBundleVersion": build_number,
    "ITSAppUsesNonExemptEncryption": False,
}
raise SystemExit(0 if all(info.get(key) == value for key, value in expected.items()) else 1)
' \
        "${info_path}" \
        "${expected_bundle_identifier}" \
        "${expected_marketing_version}" \
        "${expected_build_number}"
}

validate_app_store_package_signature_log() {
    if [[ "$#" -ne 3 ]]; then
        echo "App Store package signature validation needs Python, a log, and a Team." >&2
        return 64
    fi

    local python_path="$1"
    # Keep this name distinct from the release script's readonly
    # signature_log_path. Bash uses dynamic scope, so reusing that name would
    # leave this function reading the later App signature log instead of the
    # package signature log.
    local package_signature_log_path="$2"
    local expected_team="$3"

    "${python_path}" -c '
import re
import sys

path, team = sys.argv[1:]
with open(path, "r", encoding="utf-8", errors="replace") as stream:
    lines = stream.read().splitlines()

status_lines = [line.strip() for line in lines if line.strip().startswith("Status:")]
accepted_status = False
if len(status_lines) == 1:
    status = status_lines[0]
    rejected_status_words = {"expired", "invalid", "no signature", "revoked", "untrusted"}
    accepted_status = (
        status.startswith("Status: signed by ")
        and ("Apple" in status or "trusted by macOS" in status or "trusted by Mac OS X" in status)
        and not any(word in status.lower() for word in rejected_status_words)
    )
leaf_pattern = re.compile(
    r"^\s*1\.\s+(Mac Installer Distribution|"
    r"3rd Party Mac Developer Installer):.+\(" + re.escape(team) + r"\)\s*$"
)
leaf_matches = [line for line in lines if leaf_pattern.match(line)]
has_developer_id = any("Developer ID Installer:" in line for line in lines)
has_wwdr = any("Apple Worldwide Developer Relations Certification Authority" in line for line in lines)
has_apple_root = any(
    re.search(r"^\s*\d+\.\s+Apple Root CA(?:\s+-\s+G\d+)?\s*$", line)
    for line in lines
)
valid = (
    accepted_status
    and len(leaf_matches) == 1
    and has_wwdr
    and has_apple_root
    and not has_developer_id
)
raise SystemExit(0 if valid else 1)
' "${package_signature_log_path}" "${expected_team}"
}
