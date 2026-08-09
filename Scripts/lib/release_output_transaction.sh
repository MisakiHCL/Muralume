#!/usr/bin/env bash

# Fail-safe publication of a DMG and its checksum. This file is intended to be
# sourced. POSIX filesystems cannot atomically replace two directory entries,
# so the transaction keeps same-filesystem backups and rolls both entries back
# if any move or final verification fails.

commit_release_output_pair() (
    if [[ "$#" -ne 4 ]]; then
        echo "Release output publication needs a source DMG, output DMG, checksum path, and verified digest." >&2
        return 64
    fi

    set -euo pipefail

    local source_dmg_path="$1"
    local output_dmg_path="$2"
    local output_checksum_path="$3"
    local expected_digest="$4"
    local transaction_directory
    local transaction_dmg_name
    local transaction_checksum_name
    local checksum_directory
    local pending_dmg_path=""
    local pending_checksum_path=""
    local backup_dmg_path=""
    local backup_checksum_path=""
    local old_dmg_backed_up=0
    local old_checksum_backed_up=0
    local new_dmg_installed=0
    local new_checksum_installed=0
    local transaction_complete=0
    local rollback_failed=0
    local actual_digest
    local move_command="${MURALUME_RELEASE_OUTPUT_MOVE_COMMAND:-mv}"

    transaction_directory="$(
        cd "$(dirname "${output_dmg_path}")" && pwd -P
    )" || return 1
    transaction_dmg_name="$(basename "${output_dmg_path}")" || return 1
    transaction_checksum_name="$(basename "${output_checksum_path}")" \
        || return 1
    checksum_directory="$(
        cd "$(dirname "${output_checksum_path}")" && pwd -P
    )" || return 1

    if [[ ! -f "${source_dmg_path}" || -L "${source_dmg_path}" ]]; then
        echo "The verified release DMG is missing or is a symbolic link." >&2
        return 1
    fi
    if [[ ! "${expected_digest}" =~ ^[[:xdigit:]]{64}$ ]]; then
        echo "The verified release DMG digest is invalid." >&2
        return 1
    fi
    if [[ "${checksum_directory}" != "${transaction_directory}" ]]; then
        echo "The release DMG and checksum must use the same output directory." >&2
        return 1
    fi
    if [[ -L "${output_dmg_path}" \
        || ( -e "${output_dmg_path}" && ! -f "${output_dmg_path}" ) ]]; then
        echo "The existing release DMG must be a regular file." >&2
        return 1
    fi
    if [[ -L "${output_checksum_path}" \
        || ( -e "${output_checksum_path}" \
            && ! -f "${output_checksum_path}" ) ]]; then
        echo "The existing release checksum must be a regular file." >&2
        return 1
    fi

    cleanup_release_output_transaction() {
        local original_status="$?"

        set +e
        if [[ "${transaction_complete}" -ne 1 ]]; then
            if [[ "${old_dmg_backed_up}" -eq 1 \
                || "${new_dmg_installed}" -eq 1 ]]; then
                rm -f "${output_dmg_path}"
            fi
            if [[ "${old_checksum_backed_up}" -eq 1 \
                || "${new_checksum_installed}" -eq 1 ]]; then
                rm -f "${output_checksum_path}"
            fi

            if [[ "${old_dmg_backed_up}" -eq 1 ]]; then
                if ! "${move_command}" "${backup_dmg_path}" \
                    "${output_dmg_path}"; then
                    rollback_failed=1
                fi
            fi
            if [[ "${old_checksum_backed_up}" -eq 1 ]]; then
                if ! "${move_command}" "${backup_checksum_path}" \
                    "${output_checksum_path}"; then
                    rollback_failed=1
                fi
            fi
        fi

        rm -f "${pending_dmg_path}" "${pending_checksum_path}"
        if [[ "${transaction_complete}" -eq 1 ]]; then
            rm -f "${backup_dmg_path}" "${backup_checksum_path}"
        fi

        if [[ "${rollback_failed}" -eq 1 ]]; then
            printf 'Release output rollback needs manual recovery from:\n  %s\n  %s\n' \
                "${backup_dmg_path}" \
                "${backup_checksum_path}" >&2
            return 125
        fi
        return "${original_status}"
    }
    trap cleanup_release_output_transaction EXIT
    trap 'exit 130' HUP INT TERM

    pending_dmg_path="$(
        mktemp "${transaction_directory}/.${transaction_dmg_name}.pending.XXXXXX"
    )" || return 1
    pending_checksum_path="$(
        mktemp "${transaction_directory}/.${transaction_checksum_name}.pending.XXXXXX"
    )" || return 1

    cp -p "${source_dmg_path}" "${pending_dmg_path}" || return 1
    actual_digest="$(
        shasum -a 256 "${pending_dmg_path}" | awk '{ print $1 }'
    )" || return 1
    [[ "${actual_digest}" == "${expected_digest}" ]] \
        || return 1
    printf '%s  %s\n' "${expected_digest}" "${transaction_dmg_name}" \
        >"${pending_checksum_path}" || return 1

    if [[ -e "${output_dmg_path}" ]]; then
        backup_dmg_path="$(
            mktemp "${transaction_directory}/.${transaction_dmg_name}.backup.XXXXXX"
        )" || return 1
        rm -f "${backup_dmg_path}" || return 1
        "${move_command}" "${output_dmg_path}" "${backup_dmg_path}" \
            || return 1
        old_dmg_backed_up=1
    fi
    if [[ -e "${output_checksum_path}" ]]; then
        backup_checksum_path="$(
            mktemp "${transaction_directory}/.${transaction_checksum_name}.backup.XXXXXX"
        )" || return 1
        rm -f "${backup_checksum_path}" || return 1
        "${move_command}" "${output_checksum_path}" \
            "${backup_checksum_path}" || return 1
        old_checksum_backed_up=1
    fi

    "${move_command}" "${pending_dmg_path}" "${output_dmg_path}" || return 1
    new_dmg_installed=1
    pending_dmg_path=""
    "${move_command}" "${pending_checksum_path}" "${output_checksum_path}" \
        || return 1
    new_checksum_installed=1
    pending_checksum_path=""

    (
        cd "${transaction_directory}"
        shasum -a 256 -c "${transaction_checksum_name}"
    ) || return 1
    [[ "$(<"${output_checksum_path}")" \
        == "${expected_digest}  ${transaction_dmg_name}" ]] \
        || return 1
    transaction_complete=1
)
