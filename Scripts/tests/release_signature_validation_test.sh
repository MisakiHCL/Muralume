#!/usr/bin/env bash

set -euo pipefail

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly scripts_directory="$(cd "${script_directory}/.." && pwd)"
readonly test_python_path="$(xcrun --find python3)"

# shellcheck source=../lib/release_signature_validation.sh
source "${scripts_directory}/lib/release_signature_validation.sh"

test_root="$(
    mktemp -d "${TMPDIR:-/tmp}/MuralumeReleaseSignatureTests.XXXXXX"
)"
cleanup() {
    rm -rf "${test_root}"
}
trap cleanup EXIT

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

readonly expected_entitlements_path="${test_root}/expected.plist"
readonly extra_entitlements_path="${test_root}/extra.plist"
"${test_python_path}" -c '
import plistlib
import sys

expected = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.files.bookmarks.app-scope": True,
    "com.apple.security.files.user-selected.read-write": True,
}
with open(sys.argv[1], "wb") as stream:
    plistlib.dump(expected, stream)
expected["com.apple.security.network.client"] = True
with open(sys.argv[2], "wb") as stream:
    plistlib.dump(expected, stream)
' "${expected_entitlements_path}" "${extra_entitlements_path}"

validate_release_entitlements_allowlist \
    "${test_python_path}" \
    "${expected_entitlements_path}" \
    || fail_test 'the exact entitlement allowlist should pass'
if validate_release_entitlements_allowlist \
    "${test_python_path}" \
    "${extra_entitlements_path}"; then
    fail_test 'an unexpected entitlement should fail'
fi

signature_has_hardened_runtime \
    "${test_python_path}" \
    'CodeDirectory v=20500 size=99 flags=0x10002(adhoc,runtime) hashes=1+0 location=embedded' \
    || fail_test 'the runtime CodeDirectory flag should pass'
if signature_has_hardened_runtime \
    "${test_python_path}" \
    'CodeDirectory v=20500 size=99 flags=0x2(adhoc) hashes=1+0 location=embedded'; then
    fail_test 'a signature without runtime should fail'
fi
synthetic_authority='Authority=Developer ID '
synthetic_authority+='Application: Example (ABCDEFGHIJ)'
if signature_has_hardened_runtime \
    "${test_python_path}" \
    "${synthetic_authority}"; then
    fail_test 'an authority line must not substitute for runtime flags'
fi

readonly fixture_app_bundle_path="${test_root}/Muralume.app"
readonly resources_path="${fixture_app_bundle_path}/Contents/Resources"
readonly privacy_manifest_path="${resources_path}/PrivacyInfo.xcprivacy"
mkdir -p "${resources_path}"
"${test_python_path}" -c '
import plistlib
import sys
with open(sys.argv[1], "wb") as stream:
    plistlib.dump({"NSPrivacyTracking": False}, stream)
' "${privacy_manifest_path}"
validate_release_privacy_manifest \
    "${test_python_path}" \
    "${fixture_app_bundle_path}" \
    || fail_test 'a valid bundled privacy manifest should pass'

"${test_python_path}" -c '
import plistlib
import sys
with open(sys.argv[1], "wb") as stream:
    plistlib.dump({
        "NSPrivacyTracking": False,
        "NSPrivacyCollectedDataTypes": [],
    }, stream)
' "${privacy_manifest_path}"
if validate_release_privacy_manifest \
    "${test_python_path}" \
    "${fixture_app_bundle_path}" >/dev/null 2>&1; then
    fail_test 'an extra empty privacy-manifest key should fail'
fi

rm "${privacy_manifest_path}"
if validate_release_privacy_manifest \
    "${test_python_path}" \
    "${fixture_app_bundle_path}" >/dev/null 2>&1; then
    fail_test 'a missing bundled privacy manifest should fail'
fi
printf '%s\n' 'not a plist' >"${privacy_manifest_path}"
if validate_release_privacy_manifest \
    "${test_python_path}" \
    "${fixture_app_bundle_path}" >/dev/null 2>&1; then
    fail_test 'an invalid bundled privacy manifest should fail'
fi

printf '%s\n' 'PASS: release signature policy fault-injection tests'
