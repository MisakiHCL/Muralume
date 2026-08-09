#!/usr/bin/env bash

set -euo pipefail

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly scripts_directory="$(cd "${script_directory}/.." && pwd)"

# shellcheck source=../lib/release_output_transaction.sh
source "${scripts_directory}/lib/release_output_transaction.sh"

test_root="$(
    mktemp -d "${TMPDIR:-/tmp}/MuralumeReleaseOutputTests.XXXXXX"
)"
cleanup() {
    rm -rf "${test_root}"
}
trap cleanup EXIT

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_file_content() {
    local expected="$1"
    local path="$2"
    local description="$3"

    [[ -f "${path}" ]] || fail_test "${description}: file is missing"
    [[ "$(<"${path}")" == "${expected}" ]] \
        || fail_test "${description}: content changed"
}

assert_no_transaction_artifacts() {
    local directory="$1"
    local artifacts

    artifacts="$(
        find "${directory}" -maxdepth 1 \
            \( -name '*.pending.*' -o -name '*.backup.*' \) \
            -print
    )"
    [[ -z "${artifacts}" ]] \
        || fail_test "transaction artifacts were not cleaned: ${artifacts}"
}

fault_injected_move() {
    local count

    count="$(<"${FAKE_MOVE_COUNT_PATH}")"
    count=$((count + 1))
    printf '%s\n' "${count}" >"${FAKE_MOVE_COUNT_PATH}"
    if [[ "${count}" -eq "${FAKE_MOVE_FAILURE_AT}" ]]; then
        return 91
    fi
    command mv "$@"
}

tampering_move() {
    local count

    count="$(<"${FAKE_MOVE_COUNT_PATH}")"
    count=$((count + 1))
    printf '%s\n' "${count}" >"${FAKE_MOVE_COUNT_PATH}"
    command mv "$@"
    if [[ "${count}" -eq 4 ]]; then
        printf '%s\n' 'tampered after installation' >>"$2"
    fi
}

run_success_case() {
    local case_root="${test_root}/success"
    local source_path="${case_root}/new.dmg"
    local output_path="${case_root}/Muralume.dmg"
    local checksum_path="${output_path}.sha256"
    local expected_digest

    mkdir -p "${case_root}"
    printf '%s\n' 'new release bytes' >"${source_path}"
    printf '%s\n' 'old release bytes' >"${output_path}"
    printf '%s\n' 'old checksum' >"${checksum_path}"
    expected_digest="$(shasum -a 256 "${source_path}" | awk '{ print $1 }')"

    commit_release_output_pair \
        "${source_path}" \
        "${output_path}" \
        "${checksum_path}" \
        "${expected_digest}"
    assert_file_content 'new release bytes' "${output_path}" 'published DMG'
    (
        cd "${case_root}"
        shasum -a 256 -c "$(basename "${checksum_path}")" >/dev/null
    ) || fail_test 'published checksum did not verify'
    assert_no_transaction_artifacts "${case_root}"
}

run_second_install_move_failure_case() {
    local case_root="${test_root}/move-failure"
    local source_path="${case_root}/new.dmg"
    local output_path="${case_root}/Muralume.dmg"
    local checksum_path="${output_path}.sha256"
    local move_count_path="${case_root}/move-count"
    local expected_digest

    mkdir -p "${case_root}"
    printf '%s\n' 'new release bytes' >"${source_path}"
    printf '%s\n' 'old release bytes' >"${output_path}"
    printf '%s\n' 'old checksum' >"${checksum_path}"
    printf '%s\n' 0 >"${move_count_path}"
    expected_digest="$(shasum -a 256 "${source_path}" | awk '{ print $1 }')"

    if MURALUME_RELEASE_OUTPUT_MOVE_COMMAND=fault_injected_move \
        FAKE_MOVE_COUNT_PATH="${move_count_path}" \
        FAKE_MOVE_FAILURE_AT=4 \
        commit_release_output_pair \
            "${source_path}" \
            "${output_path}" \
            "${checksum_path}" \
            "${expected_digest}" >/dev/null 2>&1; then
        fail_test 'the second publication move should fail'
    fi
    assert_file_content 'old release bytes' "${output_path}" \
        'DMG rollback after checksum move failure'
    assert_file_content 'old checksum' "${checksum_path}" \
        'checksum rollback after checksum move failure'
    assert_no_transaction_artifacts "${case_root}"
}

run_final_verification_failure_case() {
    local case_root="${test_root}/verification-failure"
    local source_path="${case_root}/new.dmg"
    local output_path="${case_root}/Muralume.dmg"
    local checksum_path="${output_path}.sha256"
    local move_count_path="${case_root}/move-count"
    local expected_digest

    mkdir -p "${case_root}"
    printf '%s\n' 'new release bytes' >"${source_path}"
    printf '%s\n' 'old release bytes' >"${output_path}"
    printf '%s\n' 'old checksum' >"${checksum_path}"
    printf '%s\n' 0 >"${move_count_path}"
    expected_digest="$(shasum -a 256 "${source_path}" | awk '{ print $1 }')"

    if MURALUME_RELEASE_OUTPUT_MOVE_COMMAND=tampering_move \
        FAKE_MOVE_COUNT_PATH="${move_count_path}" \
        commit_release_output_pair \
            "${source_path}" \
            "${output_path}" \
            "${checksum_path}" \
            "${expected_digest}" >/dev/null 2>&1; then
        fail_test 'tampering before final verification should fail'
    fi
    assert_file_content 'old release bytes' "${output_path}" \
        'DMG rollback after final verification failure'
    assert_file_content 'old checksum' "${checksum_path}" \
        'checksum rollback after final verification failure'
    assert_no_transaction_artifacts "${case_root}"
}

run_verified_digest_mismatch_case() {
    local case_root="${test_root}/digest-mismatch"
    local source_path="${case_root}/new.dmg"
    local output_path="${case_root}/Muralume.dmg"
    local checksum_path="${output_path}.sha256"
    local verified_digest

    mkdir -p "${case_root}"
    printf '%s\n' 'verified release bytes' >"${source_path}"
    verified_digest="$(shasum -a 256 "${source_path}" | awk '{ print $1 }')"
    printf '%s\n' 'changed after verification' >"${source_path}"
    printf '%s\n' 'old release bytes' >"${output_path}"
    printf '%s\n' 'old checksum' >"${checksum_path}"

    if commit_release_output_pair \
        "${source_path}" \
        "${output_path}" \
        "${checksum_path}" \
        "${verified_digest}" >/dev/null 2>&1; then
        fail_test 'a DMG changed after verification should fail publication'
    fi
    assert_file_content 'old release bytes' "${output_path}" \
        'DMG preservation after verified digest mismatch'
    assert_file_content 'old checksum' "${checksum_path}" \
        'checksum preservation after verified digest mismatch'
    assert_no_transaction_artifacts "${case_root}"
}

run_success_case
run_second_install_move_failure_case
run_final_verification_failure_case
run_verified_digest_mismatch_case

printf '%s\n' 'PASS: release output transaction fault-injection tests'
