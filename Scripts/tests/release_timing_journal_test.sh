#!/usr/bin/env bash

set -euo pipefail
umask 077

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/release_timing_journal.sh
source "${script_directory}/../lib/release_timing_journal.sh"

test_root="$(
    mktemp -d "${TMPDIR:-/tmp}/MuralumeReleaseTimingTests.XXXXXX"
)"
trap 'rm -rf "${test_root}"' EXIT

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

source_commit='0123456789012345678901234567890123456789'
source_tree='abcdefabcdefabcdefabcdefabcdefabcdefabcd'
journal_path="${test_root}/state/timing.journal"

release_timing_session_initialize \
    "${journal_path}" "${source_commit}" "${source_tree}" \
    || fail_test 'could not initialize timing session'
release_timing_stage_begin shared_gate \
    || fail_test 'could not begin a timing stage'
release_timing_stage_finish passed \
    || fail_test 'could not finish a timing stage'
release_timing_journal_validate \
    "${journal_path}" "${source_commit}" "${source_tree}" \
    || fail_test 'valid timing journal was rejected'
[[ "$(stat -f '%Lp' "${journal_path}")" == '600' ]] \
    || fail_test 'timing journal permissions are not 0600'
grep -E \
    $'^stage_finish\t[0-9a-f]{64}\tshared_gate\t[^\t]+\t[0-9]+\t[0-9]+\tpassed$' \
    "${journal_path}" >/dev/null \
    || fail_test 'timing journal did not record a sanitized completed stage'

if release_timing_stage_begin 'unsafe/path' >/dev/null 2>&1; then
    fail_test 'an unsafe stage name was accepted'
fi
if release_timing_journal_validate \
    "${journal_path}" \
    '1111111111111111111111111111111111111111' \
    "${source_tree}" >/dev/null 2>&1; then
    fail_test 'a source mismatch was accepted'
fi
printf 'credential=top-secret\n' >>"${journal_path}"
if release_timing_journal_validate \
    "${journal_path}" "${source_commit}" "${source_tree}" \
    >/dev/null 2>&1; then
    fail_test 'an unsupported journal field was accepted'
fi

printf '%s\n' 'PASS: release timing journal tests'
