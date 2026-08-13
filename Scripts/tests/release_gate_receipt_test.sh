#!/usr/bin/env bash

set -euo pipefail

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly project_root="$(cd "${script_directory}/../.." && pwd)"

# shellcheck source=../lib/release_source_snapshot.sh
source "${script_directory}/../lib/release_source_snapshot.sh"
# shellcheck source=../lib/release_gate_receipt.sh
source "${script_directory}/../lib/release_gate_receipt.sh"

test_root="$(
    mktemp -d "${TMPDIR:-/tmp}/MuralumeGateReceiptTests.XXXXXX"
)"
cleanup() {
    rm -rf "${test_root}"
}
trap cleanup EXIT

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

fake_bin="${test_root}/bin"
mkdir -p "${fake_bin}"
fake_xcodebuild="${fake_bin}/xcodebuild"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "Xcode %s\n" "${FAKE_XCODE_VERSION:-26.1.1}"' \
    'printf "Build version %s\n" "${FAKE_XCODE_BUILD:-17B100}"' \
    >"${fake_xcodebuild}"
chmod 700 "${fake_xcodebuild}"
export PATH="${fake_bin}:${PATH}"

source_commit="$(git -C "${project_root}" rev-parse 'HEAD^{commit}')"
source_tree="$(git -C "${project_root}" rev-parse 'HEAD^{tree}')"
receipt_path="${test_root}/receipts/gate.txt"

write_release_gate_receipt \
    "${receipt_path}" "${project_root}" "${source_commit}" "${source_tree}" \
    || fail_test 'could not create a release gate receipt'
[[ "$(stat -f '%Lp' "${receipt_path}")" == '600' ]] \
    || fail_test 'gate receipt permissions were not 0600'
validate_release_gate_receipt \
    "${receipt_path}" "${project_root}" "${source_commit}" "${source_tree}" \
    || fail_test 'a matching release gate receipt was rejected'
[[ "$(release_gate_receipt_value "${receipt_path}" gate_suite)" == 'all' ]] \
    || fail_test 'gate receipt did not bind the all suite'

# Sourced helpers must not redeclare caller-owned readonly workflow variables.
(
    readonly source_commit='caller-owned-commit'
    readonly source_tree='caller-owned-tree'
    readonly marketing_version='caller-owned-version'
    collision_receipt_path="${test_root}/receipts/readonly-caller.txt"
    write_release_gate_receipt \
        "${collision_receipt_path}" "${project_root}" \
        "$(git -C "${project_root}" rev-parse 'HEAD^{commit}')" \
        "$(git -C "${project_root}" rev-parse 'HEAD^{tree}')"
) || fail_test 'gate helpers collided with readonly caller variables'

if FAKE_XCODE_BUILD='DIFFERENT' validate_release_gate_receipt \
    "${receipt_path}" "${project_root}" "${source_commit}" "${source_tree}" \
    >/dev/null 2>&1; then
    fail_test 'an Xcode build mismatch was accepted'
fi

cp "${receipt_path}" "${test_root}/wrong-suite.txt"
chmod 600 "${test_root}/wrong-suite.txt"
sed -i '' 's/^gate_suite=all$/gate_suite=release-gate/' \
    "${test_root}/wrong-suite.txt"
if validate_release_gate_receipt \
    "${test_root}/wrong-suite.txt" \
    "${project_root}" "${source_commit}" "${source_tree}" \
    >/dev/null 2>&1; then
    fail_test 'a non-all gate suite was accepted'
fi

if validate_release_gate_receipt \
    "${receipt_path}" "${project_root}" \
    '0000000000000000000000000000000000000000' "${source_tree}" \
    >/dev/null 2>&1; then
    fail_test 'a source commit mismatch was accepted'
fi

chmod 644 "${receipt_path}"
if validate_release_gate_receipt \
    "${receipt_path}" "${project_root}" "${source_commit}" "${source_tree}" \
    >/dev/null 2>&1; then
    fail_test 'an insecure receipt mode was accepted'
fi
chmod 600 "${receipt_path}"

printf 'source_commit=%s\n' "${source_commit}" >>"${receipt_path}"
if validate_release_gate_receipt \
    "${receipt_path}" "${project_root}" "${source_commit}" "${source_tree}" \
    >/dev/null 2>&1; then
    fail_test 'a duplicate receipt field was accepted'
fi

printf '%s\n' 'PASS: release gate receipt tests'
