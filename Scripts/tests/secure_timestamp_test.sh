#!/usr/bin/env bash

set -euo pipefail

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly scripts_directory="$(cd "${script_directory}/.." && pwd)"

# shellcheck source=../lib/secure_timestamp.sh
source "${scripts_directory}/lib/secure_timestamp.sh"

test_directory="$(
    mktemp -d "${TMPDIR:-/tmp}/MuralumeSecureTimestampTests.XXXXXX"
)"

cleanup() {
    rm -rf "${test_directory}"
}
trap cleanup EXIT

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_equal() {
    local expected="$1"
    local actual="$2"
    local description="$3"

    if [[ "${actual}" != "${expected}" ]]; then
        fail_test "${description}: expected '${expected}', found '${actual}'"
    fi
}

assert_contains() {
    local expected_text="$1"
    local file_path="$2"
    local description="$3"

    if ! grep -F -- "${expected_text}" "${file_path}" >/dev/null; then
        fail_test "${description}: missing '${expected_text}'"
    fi
}

line_count() {
    local file_path="$1"

    wc -l <"${file_path}" | tr -d '[:space:]'
}

fake_codesign() {
    local completed_attempts
    local current_attempt

    completed_attempts="$(line_count "${FAKE_CODESIGN_CALLS_PATH}")"
    current_attempt="$((completed_attempts + 1))"
    printf '%s\n' "$*" >>"${FAKE_CODESIGN_CALLS_PATH}"

    case "${FAKE_CODESIGN_MODE}" in
        succeeds_after_two_timestamp_failures)
            if [[ "${current_attempt}" -eq 1 ]]; then
                printf '%s\n' 'The TIMESTAMP service is not available.' >&2
                return 17
            fi
            if [[ "${current_attempt}" -eq 2 ]]; then
                printf '%s\n' 'A timestamp was expected but was not found.' >&2
                return 17
            fi
            return 0
            ;;
        non_timestamp_failure)
            printf '%s\n' 'errSecInternalComponent' >&2
            return 42
            ;;
        timestamp_exhausted)
            printf '%s\n' 'A timestamp was expected but was not found.' >&2
            return 23
            ;;
        *)
            printf 'Unknown fake codesign mode: %s\n' \
                "${FAKE_CODESIGN_MODE}" >&2
            return 64
            ;;
    esac
}

fake_sleep() {
    printf '%s\n' "$1" >>"${FAKE_SLEEP_CALLS_PATH}"
}

run_signing_case() {
    local mode="$1"
    local case_directory="$2"
    local target_path="${case_directory}/Muralume.dmg"

    mkdir -p "${case_directory}"
    : >"${case_directory}/codesign-calls"
    : >"${case_directory}/sleep-calls"
    : >"${target_path}"

    MURALUME_CODESIGN_COMMAND=fake_codesign \
    MURALUME_SLEEP_COMMAND=fake_sleep \
    FAKE_CODESIGN_MODE="${mode}" \
    FAKE_CODESIGN_CALLS_PATH="${case_directory}/codesign-calls" \
    FAKE_SLEEP_CALLS_PATH="${case_directory}/sleep-calls" \
        sign_with_secure_timestamp \
            "${mode}" \
            "${target_path}" \
            --force \
            --sign TEST-IDENTITY
}

test_retries_timestamp_failures_until_success() {
    local case_directory="${test_directory}/eventual-success"
    local output_path="${case_directory}/output"
    local error_path="${case_directory}/error"
    local timestamp_argument_count

    mkdir -p "${case_directory}"
    if ! run_signing_case \
        succeeds_after_two_timestamp_failures \
        "${case_directory}" >"${output_path}" 2>"${error_path}"; then
        fail_test 'timestamp failures should succeed on the third attempt'
    fi

    assert_equal \
        3 \
        "$(line_count "${case_directory}/codesign-calls")" \
        'codesign attempt count'
    assert_equal \
        $'2\n4' \
        "$(<"${case_directory}/sleep-calls")" \
        'retry delays'
    timestamp_argument_count="$(
        grep -c -- '--timestamp' "${case_directory}/codesign-calls" || true
    )"
    assert_equal 3 "${timestamp_argument_count}" 'secure timestamp argument count'
    assert_contains \
        'Secure timestamp attempt 1/5' \
        "${error_path}" \
        'first retry notice'
    assert_contains \
        'Secure timestamp attempt 2/5' \
        "${error_path}" \
        'second retry notice'
}

test_does_not_retry_non_timestamp_failure() {
    local case_directory="${test_directory}/permanent-failure"
    local output_path="${case_directory}/output"
    local error_path="${case_directory}/error"
    local status

    mkdir -p "${case_directory}"
    if run_signing_case \
        non_timestamp_failure \
        "${case_directory}" >"${output_path}" 2>"${error_path}"; then
        status=0
    else
        status="$?"
    fi

    assert_equal 42 "${status}" 'non-timestamp exit status'
    assert_equal \
        1 \
        "$(line_count "${case_directory}/codesign-calls")" \
        'non-timestamp codesign attempt count'
    assert_equal \
        0 \
        "$(line_count "${case_directory}/sleep-calls")" \
        'non-timestamp sleep count'
    assert_contains \
        'errSecInternalComponent' \
        "${error_path}" \
        'original codesign error'
}

test_reports_timestamp_exhaustion() {
    local case_directory="${test_directory}/exhausted"
    local output_path="${case_directory}/output"
    local error_path="${case_directory}/error"
    local status

    mkdir -p "${case_directory}"
    if run_signing_case \
        timestamp_exhausted \
        "${case_directory}" >"${output_path}" 2>"${error_path}"; then
        status=0
    else
        status="$?"
    fi

    assert_equal 23 "${status}" 'exhausted timestamp exit status'
    assert_equal \
        5 \
        "$(line_count "${case_directory}/codesign-calls")" \
        'exhausted codesign attempt count'
    assert_equal \
        $'2\n4\n8\n16' \
        "$(<"${case_directory}/sleep-calls")" \
        'exhausted retry delays'
    assert_contains \
        'failed after 5 attempts' \
        "${error_path}" \
        'exhaustion summary'
    assert_contains \
        'No notarization was submitted' \
        "${error_path}" \
        'notarization safety statement'
    assert_contains \
        'existing release output was not replaced' \
        "${error_path}" \
        'published output safety statement'
}

test_retries_timestamp_failures_until_success
test_does_not_retry_non_timestamp_failure
test_reports_timestamp_exhaustion

printf '%s\n' 'PASS: secure timestamp retry tests'
