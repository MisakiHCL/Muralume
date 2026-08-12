#!/usr/bin/env bash

# A release gate receipt is deliberately narrow: it proves that the caller
# completed the gate for one immutable source/Xcode combination. It is not a
# general-purpose "skip tests" switch.

readonly MURALUME_RELEASE_GATE_RECEIPT_SCHEMA="1"

release_gate_xcode_identity() {
    if [[ "$#" -ne 0 ]]; then
        echo "Xcode identity lookup accepts no arguments." >&2
        return 64
    fi

    xcodebuild -version | awk '
        NR == 1 && $1 == "Xcode" { print "xcode_version=" $2 }
        NR == 2 && $1 == "Build" && $2 == "version" {
            print "xcode_build=" $3
        }
    '
}

release_gate_script_digest_at_commit() {
    if [[ "$#" -ne 2 ]]; then
        echo "Gate digest lookup needs a repository and commit." >&2
        return 64
    fi

    local gate_repository_path="$1"
    local gate_source_commit="$2"

    release_git -C "${gate_repository_path}" show \
        "${gate_source_commit}:Scripts/verify.sh" \
        | shasum -a 256 \
        | awk '{ print $1 }'
}

write_release_gate_receipt() {
    if [[ "$#" -ne 4 ]]; then
        echo "Gate receipt creation needs a path, repository, commit, and tree." >&2
        return 64
    fi

    local gate_receipt_path="$1"
    local gate_repository_path="$2"
    local gate_source_commit="$3"
    local gate_source_tree="$4"
    local gate_receipt_directory
    local gate_temporary_receipt_path=""
    local gate_xcode_identity
    local gate_script_digest

    [[ "${gate_source_commit}" =~ ^[[:xdigit:]]{40,64}$ \
        && "${gate_source_tree}" =~ ^[[:xdigit:]]{40,64}$ ]] || {
        echo "Gate receipt source identifiers are invalid." >&2
        return 1
    }

    gate_receipt_directory="$(dirname "${gate_receipt_path}")"
    mkdir -p "${gate_receipt_directory}" || return 1
    chmod 700 "${gate_receipt_directory}" || return 1
    gate_temporary_receipt_path="$(
        mktemp "${gate_receipt_directory}/.release-gate.XXXXXX"
    )" || return 1
    gate_xcode_identity="$(release_gate_xcode_identity)" || {
        rm -f "${gate_temporary_receipt_path}"
        return 1
    }
    gate_script_digest="$(
        release_gate_script_digest_at_commit \
            "${gate_repository_path}" "${gate_source_commit}"
    )" || {
        rm -f "${gate_temporary_receipt_path}"
        return 1
    }

    if ! {
        printf 'schema=%s\n' "${MURALUME_RELEASE_GATE_RECEIPT_SCHEMA}"
        printf 'product=Muralume\n'
        printf 'source_commit=%s\n' "${gate_source_commit}"
        printf 'source_tree=%s\n' "${gate_source_tree}"
        printf '%s\n' "${gate_xcode_identity}"
        printf 'gate_script_sha256=%s\n' "${gate_script_digest}"
        printf 'completed_at_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    } >"${gate_temporary_receipt_path}"; then
        rm -f "${gate_temporary_receipt_path}"
        return 1
    fi
    chmod 600 "${gate_temporary_receipt_path}" || {
        rm -f "${gate_temporary_receipt_path}"
        return 1
    }
    mv -f "${gate_temporary_receipt_path}" "${gate_receipt_path}"
}

release_gate_receipt_value() {
    if [[ "$#" -ne 2 ]]; then
        echo "Gate receipt lookup needs a path and key." >&2
        return 64
    fi

    local receipt_path="$1"
    local requested_key="$2"
    local matches

    matches="$(
        sed -n "s/^${requested_key}=//p" "${receipt_path}"
    )" || return 1
    [[ -n "${matches}" && "${matches}" != *$'\n'* ]] || {
        echo "Gate receipt must define ${requested_key} exactly once." >&2
        return 1
    }
    printf '%s\n' "${matches}"
}

validate_release_gate_receipt() {
    if [[ "$#" -ne 4 ]]; then
        echo "Gate receipt validation needs a path, repository, commit, and tree." >&2
        return 64
    fi

    local receipt_path="$1"
    local repository_path="$2"
    local expected_commit="$3"
    local expected_tree="$4"
    local actual_schema
    local actual_product
    local actual_commit
    local actual_tree
    local actual_xcode_version
    local actual_xcode_build
    local actual_gate_digest
    local expected_xcode_version
    local expected_xcode_build
    local expected_gate_digest
    local line_count

    [[ -f "${receipt_path}" && ! -L "${receipt_path}" ]] || {
        echo "The release gate receipt must be a regular file." >&2
        return 1
    }
    [[ "$(stat -f '%Lp' "${receipt_path}")" == "600" ]] || {
        echo "The release gate receipt must have permissions 0600." >&2
        return 1
    }
    line_count="$(wc -l <"${receipt_path}" | tr -d '[:space:]')"
    [[ "${line_count}" == "8" ]] || {
        echo "The release gate receipt has an unexpected shape." >&2
        return 1
    }
    if rg -n -v \
        '^(schema|product|source_commit|source_tree|xcode_version|xcode_build|gate_script_sha256|completed_at_utc)=[^[:cntrl:]]+$' \
        "${receipt_path}" >/dev/null; then
        echo "The release gate receipt contains an unsupported field." >&2
        return 1
    fi

    actual_schema="$(release_gate_receipt_value "${receipt_path}" schema)" \
        || return 1
    actual_product="$(release_gate_receipt_value "${receipt_path}" product)" \
        || return 1
    actual_commit="$(release_gate_receipt_value "${receipt_path}" source_commit)" \
        || return 1
    actual_tree="$(release_gate_receipt_value "${receipt_path}" source_tree)" \
        || return 1
    actual_xcode_version="$(
        release_gate_receipt_value "${receipt_path}" xcode_version
    )" || return 1
    actual_xcode_build="$(
        release_gate_receipt_value "${receipt_path}" xcode_build
    )" || return 1
    actual_gate_digest="$(
        release_gate_receipt_value "${receipt_path}" gate_script_sha256
    )" || return 1

    expected_xcode_version="$(
        release_gate_xcode_identity | sed -n 's/^xcode_version=//p'
    )" || return 1
    expected_xcode_build="$(
        release_gate_xcode_identity | sed -n 's/^xcode_build=//p'
    )" || return 1
    expected_gate_digest="$(
        release_gate_script_digest_at_commit \
            "${repository_path}" "${expected_commit}"
    )" || return 1

    [[ "${actual_schema}" == "${MURALUME_RELEASE_GATE_RECEIPT_SCHEMA}" \
        && "${actual_product}" == "Muralume" \
        && "${actual_commit}" == "${expected_commit}" \
        && "${actual_tree}" == "${expected_tree}" \
        && "${actual_xcode_version}" == "${expected_xcode_version}" \
        && "${actual_xcode_build}" == "${expected_xcode_build}" \
        && "${actual_gate_digest}" == "${expected_gate_digest}" ]] || {
        echo "The release gate receipt does not match this source and Xcode." >&2
        return 1
    }
}
