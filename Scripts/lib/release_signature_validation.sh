#!/usr/bin/env bash

# Signature policy helpers used by the release workflow. This file is intended
# to be sourced.

validate_release_entitlements_allowlist() {
    if [[ "$#" -ne 2 ]]; then
        echo "Release entitlement validation needs Python and a plist path." >&2
        return 64
    fi

    local python_path="$1"
    local entitlements_path="$2"

    "${python_path}" -c '
import plistlib
import sys

expected = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.files.bookmarks.app-scope": True,
    "com.apple.security.files.user-selected.read-only": True,
}
with open(sys.argv[1], "rb") as stream:
    actual = plistlib.load(stream)
raise SystemExit(0 if actual == expected else 1)
' "${entitlements_path}"
}

signature_has_hardened_runtime() {
    if [[ "$#" -ne 2 ]]; then
        echo "Hardened Runtime validation needs Python and signature details." >&2
        return 64
    fi

    local python_path="$1"
    local signature_details="$2"

    "${python_path}" -c '
import re
import sys

for line in sys.argv[1].splitlines():
    match = re.match(
        r"^CodeDirectory .* flags=0x[0-9a-fA-F]+\(([^)]*)\)",
        line,
    )
    if match and "runtime" in {
        flag.strip() for flag in match.group(1).split(",")
    }:
        raise SystemExit(0)
raise SystemExit(1)
' "${signature_details}"
}

validate_release_privacy_manifest() {
    if [[ "$#" -ne 2 ]]; then
        echo "Privacy manifest validation needs Python and an App bundle path." >&2
        return 64
    fi

    local python_path="$1"
    local app_bundle_path="$2"
    local manifest_path="${app_bundle_path}/Contents/Resources/PrivacyInfo.xcprivacy"

    if [[ ! -f "${manifest_path}" || -L "${manifest_path}" ]]; then
        echo "The staged App is missing its regular-file PrivacyInfo.xcprivacy." >&2
        return 1
    fi
    if ! "${python_path}" -c '
import plistlib
import sys

with open(sys.argv[1], "rb") as stream:
    actual = plistlib.load(stream)
expected = {"NSPrivacyTracking": False}
raise SystemExit(0 if actual == expected else 1)
' "${manifest_path}"; then
        echo "The staged App privacy manifest must contain only NSPrivacyTracking=false." >&2
        return 1
    fi
}
