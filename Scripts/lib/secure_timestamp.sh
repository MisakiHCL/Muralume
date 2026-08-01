#!/usr/bin/env bash

# This file is intended to be sourced. It deliberately does not change the
# caller's shell options.

# Signs one code object using Apple's secure timestamp service.
#
# Usage:
#   sign_with_secure_timestamp <label> <target> [codesign arguments...]
#
# The helper appends --timestamp and the target to the supplied codesign
# arguments. It must be called before notarization and before replacing a
# previously published artifact.
#
# Tests may replace the external commands with executable paths or shell
# function names through these environment variables:
#   MURALUME_CODESIGN_COMMAND
#   MURALUME_SLEEP_COMMAND
sign_with_secure_timestamp() {
    if [[ "$#" -lt 2 ]]; then
        printf '%s\n' \
            'Usage: sign_with_secure_timestamp <label> <target> [codesign arguments...]' \
            >&2
        return 64
    fi

    local label="$1"
    local target="$2"
    shift 2

    local codesign_command="${MURALUME_CODESIGN_COMMAND:-codesign}"
    local sleep_command="${MURALUME_SLEEP_COMMAND:-sleep}"
    local maximum_attempts=5
    local -a retry_delays=(2 4 8 16)
    local attempt
    local delay
    local signing_output
    local signing_status

    for ((attempt = 1; attempt <= maximum_attempts; attempt += 1)); do
        if signing_output="$(
            "${codesign_command}" \
                "$@" \
                --timestamp \
                "${target}" 2>&1
        )"; then
            if [[ -n "${signing_output}" ]]; then
                printf '%s\n' "${signing_output}" >&2
            fi
            return 0
        else
            signing_status="$?"
        fi

        if [[ -n "${signing_output}" ]]; then
            printf '%s\n' "${signing_output}" >&2
        fi

        case "${signing_output}" in
            *[Tt][Ii][Mm][Ee][Ss][Tt][Aa][Mm][Pp]*)
                ;;
            *)
                return "${signing_status}"
                ;;
        esac

        if [[ "${attempt}" -eq "${maximum_attempts}" ]]; then
            printf 'Error: secure timestamp signing for %s failed after %d attempts.\n' \
                "${label}" \
                "${maximum_attempts}" >&2
            printf '%s\n' \
                'No notarization was submitted, and the existing release output was not replaced.' \
                >&2
            return "${signing_status}"
        fi

        delay="${retry_delays[$((attempt - 1))]}"
        printf 'Secure timestamp attempt %d/%d for %s failed; retrying in %ss.\n' \
            "${attempt}" \
            "${maximum_attempts}" \
            "${label}" \
            "${delay}" >&2
        "${sleep_command}" "${delay}"
    done
}
