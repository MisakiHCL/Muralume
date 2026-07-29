#!/usr/bin/env bash

set -u

if [[ "$#" -lt 2 ]]; then
    printf 'Usage: %s <workflow> <command> [args...]\n' "$0" >&2
    exit 64
fi

readonly workflow_name="$1"
shift

readonly log_file="$(mktemp "${TMPDIR:-/tmp}/Muralume-${workflow_name}.log.XXXXXX")"
readonly start_seconds="${SECONDS}"
keep_log=0

cleanup() {
    if [[ "${keep_log}" -eq 0 ]]; then
        rm -f "${log_file}"
    fi
}
trap cleanup EXIT

if "$@" >"${log_file}" 2>&1; then
    printf '[PASS] %s completed in %ss\n' \
        "${workflow_name}" "$((SECONDS - start_seconds))"
else
    readonly status="$?"
    keep_log=1
    printf '[FAIL] %s failed after %ss\n' \
        "${workflow_name}" "$((SECONDS - start_seconds))" >&2
    printf '%s\n' '--- last 40 log lines ---' >&2
    tail -n 40 "${log_file}" >&2
    printf '%s\n' '--- end of log ---' >&2
    printf 'Full log: %s\n' "${log_file}" >&2
    printf 'Run again with full output: make %s VERBOSE=1\n' \
        "${workflow_name}" >&2
    exit "${status}"
fi
