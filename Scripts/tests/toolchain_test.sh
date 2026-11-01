#!/bin/bash

set -euo pipefail

readonly project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/MuralumeToolchainTests.XXXXXX")"
trap 'rm -rf "${test_root}"' EXIT
mkdir "${test_root}/bin"

cat >"${test_root}/bin/xcodebuild" <<'EOF'
#!/bin/bash
printf 'Xcode %s\nBuild version fixture\n' "${FAKE_XCODE_VERSION:-26.0.1}"
EOF
cat >"${test_root}/bin/xcrun" <<'EOF'
#!/bin/bash
printf 'Apple Swift version %s (fixture)\nTarget: arm64-apple-macosx\n' "${FAKE_SWIFT_VERSION:-6.2}"
EOF
chmod 755 "${test_root}/bin/xcodebuild" "${test_root}/bin/xcrun"
export PATH="${test_root}/bin:/usr/bin:/bin:/usr/sbin:/sbin"

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

check_toolchain() {
    "${project_root}/Scripts/check_toolchain.sh" "$@" >"${test_root}/output" 2>&1
}

expect_rejection() {
    local expected_status="$1"
    local expected_message="$2"
    shift 2
    local status=0
    check_toolchain "$@" || status=$?
    [[ "${status}" -eq "${expected_status}" ]] \
        || fail_test "toolchain check returned ${status}, expected ${expected_status}"
    grep -F "${expected_message}" "${test_root}/output" >/dev/null \
        || fail_test "missing toolchain diagnostic: ${expected_message}"
}

check_toolchain || fail_test 'minimum toolchain was rejected'
check_toolchain 26.0.1 6.2 || fail_test 'minimum pinned CI toolchain was rejected'
FAKE_XCODE_VERSION=26.6 FAKE_SWIFT_VERSION=6.3.2 \
    check_toolchain 26.6 6.3 || fail_test 'current CI Swift patch version was rejected'
FAKE_XCODE_VERSION=27.1 FAKE_SWIFT_VERSION=6.4 \
    check_toolchain || fail_test 'newer local toolchain was rejected'
FAKE_XCODE_VERSION=16.4 FAKE_SWIFT_VERSION=6.1 \
    expect_rejection 1 'Muralume requires Xcode 26.0.1+ with Swift 6.2+'
FAKE_XCODE_VERSION=26.0 FAKE_SWIFT_VERSION=6.2 \
    expect_rejection 1 'Muralume requires Xcode 26.0.1+'
FAKE_XCODE_VERSION=26.6 FAKE_SWIFT_VERSION=6.1.9 \
    expect_rejection 1 'Muralume requires Xcode 26.0.1+ with Swift 6.2+'
FAKE_XCODE_VERSION=27.1 FAKE_SWIFT_VERSION=6.4 \
    expect_rejection 1 'Expected Xcode 26.6' 26.6 6.3
FAKE_XCODE_VERSION=26.6 FAKE_SWIFT_VERSION=6.4 \
    expect_rejection 1 'Expected Swift 6.3.x' 26.6 6.3
FAKE_XCODE_VERSION=invalid \
    expect_rejection 1 'Unable to identify the selected Xcode'
FAKE_SWIFT_VERSION=invalid \
    expect_rejection 1 'Unable to identify the selected Xcode'
expect_rejection 64 'Expected either no arguments' 26.6
expect_rejection 64 'Toolchain versions must contain' 26.6 invalid

printf '%s\n' 'PASS: minimum and pinned CI toolchain checks'
