#!/usr/bin/env bash

# Shared lifecycle primitives for Muralume build, test, and release workflows.
# This file is intended to be sourced and remains compatible with macOS Bash 3.2.

readonly MURALUME_WORKFLOW_WORKSPACE_MARKER='.muralume-workspace'
readonly MURALUME_WORKFLOW_LOCK_MARKER='.muralume-lock'
readonly MURALUME_WORKFLOW_DEFAULT_RETENTION='5'
readonly MURALUME_WORKFLOW_DEFAULT_DIAGNOSTIC_MAX_BYTES='1048576'

workflow_lifecycle_error() {
    printf 'Workflow lifecycle error: %s\n' "$1" >&2
}

workflow_lifecycle_valid_component() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

workflow_lifecycle_canonical_existing_directory() {
    local _mwl_directory_path="$1"

    [[ -d "${_mwl_directory_path}" && ! -L "${_mwl_directory_path}" ]] \
        || return 1
    (
        cd "${_mwl_directory_path}" >/dev/null 2>&1
        pwd -P
    )
}

workflow_lifecycle_path_is_within() {
    local _mwl_candidate_path="$1"
    local _mwl_parent_path="$2"

    [[ "${_mwl_candidate_path}" == "${_mwl_parent_path}/"* ]]
}

workflow_lifecycle_path_is_exact_directory() {
    local _mwl_expected_path="$1"
    local _mwl_canonical_path

    _mwl_canonical_path="$(
        workflow_lifecycle_canonical_existing_directory "${_mwl_expected_path}"
    )" || return 1
    [[ "${_mwl_canonical_path}" == "${_mwl_expected_path}" ]]
}

workflow_lifecycle_safe_remove_marked_directory() {
    if [[ "$#" -ne 4 ]]; then
        workflow_lifecycle_error \
            'marked directory removal needs a path, parent, marker, and marker line.'
        return 64
    fi
    workflow_lifecycle_require_initialized || return 1

    local _mwl_directory_path="$1"
    local _mwl_managed_parent="$2"
    local _mwl_marker_name="$3"
    local _mwl_expected_marker_line="$4"
    local _mwl_canonical_directory
    local _mwl_canonical_parent
    local _mwl_marker_path

    case "${_mwl_managed_parent}" in
        "${MURALUME_LIFECYCLE_WORKSPACES_ROOT}"|\
        "${MURALUME_LIFECYCLE_DIAGNOSTICS_ROOT}"|\
        "${MURALUME_LIFECYCLE_LOCKS_ROOT}")
            ;;
        *)
            workflow_lifecycle_error \
                'marked directory removal rejects an unmanaged parent.'
            return 1
            ;;
    esac

    case "${_mwl_directory_path}" in
        /*)
            ;;
        *)
            workflow_lifecycle_error 'marked directory removal rejects relative paths.'
            return 1
            ;;
    esac
    [[ -d "${_mwl_directory_path}" && ! -L "${_mwl_directory_path}" ]] || {
        workflow_lifecycle_error \
            'marked directory removal needs an existing regular directory.'
        return 1
    }
    _mwl_canonical_directory="$(
        workflow_lifecycle_canonical_existing_directory "${_mwl_directory_path}"
    )" || return 1
    _mwl_canonical_parent="$(
        workflow_lifecycle_canonical_existing_directory "${_mwl_managed_parent}"
    )" || return 1
    workflow_lifecycle_path_is_within \
        "${_mwl_canonical_directory}" "${_mwl_canonical_parent}" || {
        workflow_lifecycle_error \
            'marked directory removal rejects paths outside the managed parent.'
        return 1
    }
    _mwl_marker_path="${_mwl_canonical_directory}/${_mwl_marker_name}"
    [[ -f "${_mwl_marker_path}" && ! -L "${_mwl_marker_path}" ]] || {
        workflow_lifecycle_error \
            'marked directory removal rejected a directory without its marker.'
        return 1
    }
    grep -F -x \
        "${_mwl_expected_marker_line}" \
        "${_mwl_marker_path}" >/dev/null || {
        workflow_lifecycle_error 'marked directory removal found an invalid marker.'
        return 1
    }

    rm -rf -- "${_mwl_canonical_directory}"
}

workflow_lifecycle_initialize() {
    if [[ "$#" -ne 1 ]]; then
        workflow_lifecycle_error 'initialize needs a repository root.'
        return 64
    fi

    local _mwl_repository_root
    local _mwl_build_root
    local _mwl_root
    local _mwl_managed_path
    local _mwl_canonical_managed_path

    _mwl_repository_root="$(
        workflow_lifecycle_canonical_existing_directory "$1"
    )" || {
        workflow_lifecycle_error 'repository root must be an existing regular directory.'
        return 1
    }

    _mwl_build_root="${_mwl_repository_root}/.build"
    if [[ -L "${_mwl_build_root}" \
        || ( -e "${_mwl_build_root}" && ! -d "${_mwl_build_root}" ) ]]; then
        workflow_lifecycle_error \
            'repository .build must be a regular directory, not a link or file.'
        return 1
    fi
    mkdir -p "${_mwl_build_root}" || return 1
    _mwl_canonical_managed_path="$(
        workflow_lifecycle_canonical_existing_directory "${_mwl_build_root}"
    )" || return 1
    [[ "${_mwl_canonical_managed_path}" == "${_mwl_build_root}" ]] || {
        workflow_lifecycle_error 'repository .build resolves outside its expected path.'
        return 1
    }

    _mwl_root="${_mwl_build_root}/muralume"
    case "${_mwl_root}" in
        /*)
            ;;
        *)
            workflow_lifecycle_error 'lifecycle root must be absolute.'
            return 1
            ;;
    esac
    if [[ -L "${_mwl_root}" ]]; then
        workflow_lifecycle_error 'lifecycle root must not be a symbolic link.'
        return 1
    fi

    umask 077
    mkdir -p "${_mwl_root}" || return 1
    chmod 700 "${_mwl_root}" || return 1
    _mwl_root="$(
        workflow_lifecycle_canonical_existing_directory "${_mwl_root}"
    )" || return 1
    [[ "${_mwl_root}" == "${_mwl_build_root}/muralume" ]] || {
        workflow_lifecycle_error 'lifecycle root resolves outside repository .build.'
        return 1
    }

    MURALUME_LIFECYCLE_REPOSITORY_ROOT="${_mwl_repository_root}"
    MURALUME_LIFECYCLE_ROOT="${_mwl_root}"
    MURALUME_LIFECYCLE_WORKSPACES_ROOT="${_mwl_root}/workspaces"
    MURALUME_LIFECYCLE_DIAGNOSTICS_ROOT="${_mwl_root}/diagnostics"
    MURALUME_LIFECYCLE_LOGS_ROOT="${MURALUME_LIFECYCLE_DIAGNOSTICS_ROOT}/logs"
    MURALUME_LIFECYCLE_LOCKS_ROOT="${_mwl_root}/locks"

    for _mwl_managed_path in \
        "${MURALUME_LIFECYCLE_WORKSPACES_ROOT}" \
        "${MURALUME_LIFECYCLE_DIAGNOSTICS_ROOT}" \
        "${MURALUME_LIFECYCLE_LOGS_ROOT}" \
        "${MURALUME_LIFECYCLE_LOCKS_ROOT}"; do
        if [[ -L "${_mwl_managed_path}" \
            || ( -e "${_mwl_managed_path}" \
                && ! -d "${_mwl_managed_path}" ) ]]; then
            workflow_lifecycle_error \
                'managed lifecycle paths must be regular directories.'
            return 1
        fi
        mkdir -p "${_mwl_managed_path}" || return 1
        _mwl_canonical_managed_path="$(
            workflow_lifecycle_canonical_existing_directory \
                "${_mwl_managed_path}"
        )" || return 1
        [[ "${_mwl_canonical_managed_path}" == "${_mwl_managed_path}" ]] || {
            workflow_lifecycle_error \
                'a managed lifecycle directory resolves outside its expected path.'
            return 1
        }
    done
    chmod 700 \
        "${MURALUME_LIFECYCLE_WORKSPACES_ROOT}" \
        "${MURALUME_LIFECYCLE_DIAGNOSTICS_ROOT}" \
        "${MURALUME_LIFECYCLE_LOGS_ROOT}" \
        "${MURALUME_LIFECYCLE_LOCKS_ROOT}" || return 1

    export MURALUME_LIFECYCLE_REPOSITORY_ROOT
    export MURALUME_LIFECYCLE_ROOT
    export MURALUME_LIFECYCLE_WORKSPACES_ROOT
    export MURALUME_LIFECYCLE_DIAGNOSTICS_ROOT
    export MURALUME_LIFECYCLE_LOGS_ROOT
    export MURALUME_LIFECYCLE_LOCKS_ROOT
}

workflow_lifecycle_require_initialized() {
    [[ -n "${MURALUME_LIFECYCLE_REPOSITORY_ROOT:-}" \
        && -n "${MURALUME_LIFECYCLE_ROOT:-}" \
        && -n "${MURALUME_LIFECYCLE_WORKSPACES_ROOT:-}" \
        && -n "${MURALUME_LIFECYCLE_DIAGNOSTICS_ROOT:-}" \
        && -n "${MURALUME_LIFECYCLE_LOGS_ROOT:-}" \
        && -n "${MURALUME_LIFECYCLE_LOCKS_ROOT:-}" ]] || {
        workflow_lifecycle_error 'initialize must run before lifecycle operations.'
        return 1
    }

    local _mwl_expected_root="${MURALUME_LIFECYCLE_REPOSITORY_ROOT}/.build/muralume"
    local _mwl_expected_diagnostics="${_mwl_expected_root}/diagnostics"

    [[ "${MURALUME_LIFECYCLE_ROOT}" == "${_mwl_expected_root}" \
        && "${MURALUME_LIFECYCLE_WORKSPACES_ROOT}" \
            == "${_mwl_expected_root}/workspaces" \
        && "${MURALUME_LIFECYCLE_DIAGNOSTICS_ROOT}" \
            == "${_mwl_expected_diagnostics}" \
        && "${MURALUME_LIFECYCLE_LOGS_ROOT}" \
            == "${_mwl_expected_diagnostics}/logs" \
        && "${MURALUME_LIFECYCLE_LOCKS_ROOT}" \
            == "${_mwl_expected_root}/locks" ]] || {
        workflow_lifecycle_error 'managed lifecycle paths were changed after initialization.'
        return 1
    }
    workflow_lifecycle_path_is_exact_directory \
        "${MURALUME_LIFECYCLE_REPOSITORY_ROOT}" || return 1
    workflow_lifecycle_path_is_exact_directory \
        "${MURALUME_LIFECYCLE_ROOT}" || return 1
    workflow_lifecycle_path_is_exact_directory \
        "${MURALUME_LIFECYCLE_WORKSPACES_ROOT}" || return 1
    workflow_lifecycle_path_is_exact_directory \
        "${MURALUME_LIFECYCLE_DIAGNOSTICS_ROOT}" || return 1
    workflow_lifecycle_path_is_exact_directory \
        "${MURALUME_LIFECYCLE_LOGS_ROOT}" || return 1
    workflow_lifecycle_path_is_exact_directory \
        "${MURALUME_LIFECYCLE_LOCKS_ROOT}" || return 1
}

workflow_create_workspace() {
    if [[ "$#" -ne 1 ]] || ! workflow_lifecycle_valid_component "$1"; then
        workflow_lifecycle_error 'workspace name must be one safe path component.'
        return 64
    fi
    workflow_lifecycle_require_initialized || return 1

    local _mwl_workspace_path
    _mwl_workspace_path="$(
        mktemp -d "${MURALUME_LIFECYCLE_WORKSPACES_ROOT}/$1.XXXXXX"
    )" || return 1
    chmod 700 "${_mwl_workspace_path}" || {
        rmdir "${_mwl_workspace_path}" >/dev/null 2>&1 || true
        return 1
    }
    if ! {
        printf 'schema=1\n'
        printf 'repository=%s\n' "${MURALUME_LIFECYCLE_REPOSITORY_ROOT}"
    } >"${_mwl_workspace_path}/${MURALUME_WORKFLOW_WORKSPACE_MARKER}"; then
        rm -f "${_mwl_workspace_path}/${MURALUME_WORKFLOW_WORKSPACE_MARKER}" \
            >/dev/null 2>&1 || true
        rmdir "${_mwl_workspace_path}" >/dev/null 2>&1 || true
        return 1
    fi
    if ! chmod 600 \
        "${_mwl_workspace_path}/${MURALUME_WORKFLOW_WORKSPACE_MARKER}"; then
        rm -f "${_mwl_workspace_path}/${MURALUME_WORKFLOW_WORKSPACE_MARKER}" \
            >/dev/null 2>&1 || true
        rmdir "${_mwl_workspace_path}" >/dev/null 2>&1 || true
        return 1
    fi
    printf '%s\n' "${_mwl_workspace_path}"
}

workflow_safe_remove_workspace() {
    if [[ "$#" -ne 1 ]]; then
        workflow_lifecycle_error 'workspace removal needs one path.'
        return 64
    fi
    workflow_lifecycle_require_initialized || return 1

    local _mwl_workspace_path="$1"
    workflow_lifecycle_safe_remove_marked_directory \
        "${_mwl_workspace_path}" \
        "${MURALUME_LIFECYCLE_WORKSPACES_ROOT}" \
        "${MURALUME_WORKFLOW_WORKSPACE_MARKER}" \
        "repository=${MURALUME_LIFECYCLE_REPOSITORY_ROOT}"
}

workflow_lifecycle_retention_value() {
    local _mwl_requested_value="${1:-${MURALUME_WORKFLOW_DEFAULT_RETENTION}}"

    case "${_mwl_requested_value}" in
        ''|*[!0-9]*)
            workflow_lifecycle_error 'retention count must be a non-negative integer.'
            return 1
            ;;
    esac
    printf '%s\n' "${_mwl_requested_value}"
}

workflow_rotate_directories() {
    if [[ "$#" -lt 2 || "$#" -gt 4 ]]; then
        workflow_lifecycle_error \
            'directory rotation needs a parent, prefix, optional count, and protected path.'
        return 64
    fi
    workflow_lifecycle_require_initialized || return 1

    local _mwl_directory_path="$1"
    local _mwl_entry_prefix="$2"
    local _mwl_retention_count
    local _mwl_canonical_directory
    local _mwl_canonical_diagnostics_root
    local _mwl_candidate_path
    local _mwl_candidate_count=0
    local _mwl_protected_path="${4:-}"

    workflow_lifecycle_valid_component "${_mwl_entry_prefix}" || {
        workflow_lifecycle_error 'rotation prefix must be one safe path component.'
        return 1
    }
    _mwl_retention_count="$(
        workflow_lifecycle_retention_value "${3:-}"
    )" || return 1
    _mwl_canonical_directory="$(
        workflow_lifecycle_canonical_existing_directory "${_mwl_directory_path}"
    )" || return 1
    _mwl_canonical_diagnostics_root="$(
        workflow_lifecycle_canonical_existing_directory \
            "${MURALUME_LIFECYCLE_DIAGNOSTICS_ROOT}"
    )" || return 1
    if [[ "${_mwl_canonical_directory}" \
        != "${_mwl_canonical_diagnostics_root}" ]]; then
        workflow_lifecycle_path_is_within \
            "${_mwl_canonical_directory}" \
            "${_mwl_canonical_diagnostics_root}" || {
            workflow_lifecycle_error 'rotation rejects directories outside diagnostics.'
            return 1
        }
    fi
    if [[ -n "${_mwl_protected_path}" ]]; then
        [[ "${_mwl_retention_count}" -gt 0 ]] || {
            workflow_lifecycle_error \
                'directory rotation needs positive retention for a protected entry.'
            return 1
        }
        case "${_mwl_protected_path}" in
            "${_mwl_canonical_directory}/"*)
                ;;
            *)
                workflow_lifecycle_error \
                    'protected directory is outside the rotation parent.'
                return 1
                ;;
        esac
        [[ -d "${_mwl_protected_path}" \
            && ! -L "${_mwl_protected_path}" ]] || {
            workflow_lifecycle_error \
                'protected directory must be a regular directory.'
            return 1
        }
        _mwl_candidate_count=1
    fi

    while IFS= read -r _mwl_candidate_path; do
        [[ -n "${_mwl_candidate_path}" ]] || continue
        [[ "${_mwl_candidate_path}" != "${_mwl_protected_path}" ]] || continue
        _mwl_candidate_count=$((_mwl_candidate_count + 1))
        if [[ "${_mwl_candidate_count}" -gt "${_mwl_retention_count}" ]]; then
            workflow_lifecycle_safe_remove_marked_directory \
                "${_mwl_candidate_path}" \
                "${_mwl_canonical_directory}" \
                "${MURALUME_WORKFLOW_WORKSPACE_MARKER}" \
                "repository=${MURALUME_LIFECYCLE_REPOSITORY_ROOT}" || return 1
        fi
    done < <(
        find "${_mwl_canonical_directory}" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            -name "${_mwl_entry_prefix}.*" \
            -print \
            | sort -r
    )
}

workflow_create_diagnostic_directory() {
    if [[ "$#" -ne 1 ]] || ! workflow_lifecycle_valid_component "$1"; then
        workflow_lifecycle_error 'diagnostic name must be one safe path component.'
        return 64
    fi
    workflow_lifecycle_require_initialized || return 1

    local _mwl_diagnostic_path
    local _mwl_timestamp
    _mwl_timestamp="$(date -u '+%Y%m%dT%H%M%SZ')" || return 1
    _mwl_diagnostic_path="$(
        mktemp -d \
            "${MURALUME_LIFECYCLE_DIAGNOSTICS_ROOT}/$1.${_mwl_timestamp}.XXXXXX"
    )" || return 1
    chmod 700 "${_mwl_diagnostic_path}" || {
        rmdir "${_mwl_diagnostic_path}" >/dev/null 2>&1 || true
        return 1
    }
    if ! {
        printf 'schema=1\n'
        printf 'repository=%s\n' "${MURALUME_LIFECYCLE_REPOSITORY_ROOT}"
    } >"${_mwl_diagnostic_path}/${MURALUME_WORKFLOW_WORKSPACE_MARKER}"; then
        rm -f "${_mwl_diagnostic_path}/${MURALUME_WORKFLOW_WORKSPACE_MARKER}" \
            >/dev/null 2>&1 || true
        rmdir "${_mwl_diagnostic_path}" >/dev/null 2>&1 || true
        return 1
    fi
    if ! chmod 600 \
        "${_mwl_diagnostic_path}/${MURALUME_WORKFLOW_WORKSPACE_MARKER}"; then
        rm -f "${_mwl_diagnostic_path}/${MURALUME_WORKFLOW_WORKSPACE_MARKER}" \
            >/dev/null 2>&1 || true
        rmdir "${_mwl_diagnostic_path}" >/dev/null 2>&1 || true
        return 1
    fi
    if ! workflow_rotate_directories \
        "${MURALUME_LIFECYCLE_DIAGNOSTICS_ROOT}" \
        "$1" \
        "${MURALUME_DIAGNOSTIC_RETENTION:-${MURALUME_WORKFLOW_DEFAULT_RETENTION}}" \
        "${_mwl_diagnostic_path}"; then
        workflow_lifecycle_safe_remove_marked_directory \
            "${_mwl_diagnostic_path}" \
            "${MURALUME_LIFECYCLE_DIAGNOSTICS_ROOT}" \
            "${MURALUME_WORKFLOW_WORKSPACE_MARKER}" \
            "repository=${MURALUME_LIFECYCLE_REPOSITORY_ROOT}" \
            >/dev/null 2>&1 || true
        return 1
    fi
    printf '%s\n' "${_mwl_diagnostic_path}"
}

workflow_copy_diagnostic_file() {
    if [[ "$#" -lt 2 || "$#" -gt 4 ]]; then
        workflow_lifecycle_error 'diagnostic copy needs a source, destination, optional name and size.'
        return 64
    fi
    workflow_lifecycle_require_initialized || return 1

    local _mwl_source_path="$1"
    local _mwl_diagnostic_directory="$2"
    local _mwl_destination_name="${3:-$(basename "$1")}"
    local _mwl_maximum_bytes="${4:-${MURALUME_WORKFLOW_DEFAULT_DIAGNOSTIC_MAX_BYTES}}"
    local _mwl_canonical_diagnostic_directory
    local _mwl_canonical_diagnostics_root
    local _mwl_source_size

    [[ -f "${_mwl_source_path}" && ! -L "${_mwl_source_path}" ]] || return 0
    workflow_lifecycle_valid_component "${_mwl_destination_name}" || {
        workflow_lifecycle_error 'diagnostic destination name is unsafe.'
        return 1
    }
    case "${_mwl_maximum_bytes}" in
        ''|*[!0-9]*)
            workflow_lifecycle_error 'diagnostic maximum size must be an integer.'
            return 1
            ;;
    esac
    _mwl_canonical_diagnostic_directory="$(
        workflow_lifecycle_canonical_existing_directory \
            "${_mwl_diagnostic_directory}"
    )" || return 1
    _mwl_canonical_diagnostics_root="$(
        workflow_lifecycle_canonical_existing_directory \
            "${MURALUME_LIFECYCLE_DIAGNOSTICS_ROOT}"
    )" || return 1
    workflow_lifecycle_path_is_within \
        "${_mwl_canonical_diagnostic_directory}" \
        "${_mwl_canonical_diagnostics_root}" || {
        workflow_lifecycle_error 'diagnostic copy destination is outside diagnostics.'
        return 1
    }
    _mwl_source_size="$(stat -f '%z' "${_mwl_source_path}")" || return 1
    if [[ "${_mwl_source_size}" -gt "${_mwl_maximum_bytes}" ]]; then
        tail -c "${_mwl_maximum_bytes}" "${_mwl_source_path}" \
            >"${_mwl_canonical_diagnostic_directory}/${_mwl_destination_name}" \
            || return 1
    else
        cp "${_mwl_source_path}" \
            "${_mwl_canonical_diagnostic_directory}/${_mwl_destination_name}" \
            || return 1
    fi
    chmod 600 \
        "${_mwl_canonical_diagnostic_directory}/${_mwl_destination_name}"
}

workflow_cleanup_workspace() {
    if [[ "$#" -ne 2 ]]; then
        workflow_lifecycle_error 'workspace cleanup needs a path and status.'
        return 64
    fi

    local _mwl_workspace_path="$1"
    local _mwl_workflow_status="$2"

    case "${_mwl_workflow_status}" in
        ''|*[!0-9]*)
            workflow_lifecycle_error 'workspace status must be a non-negative integer.'
            return 64
            ;;
    esac
    if [[ "${_mwl_workflow_status}" -ne 0 \
        && "${MURALUME_KEEP_FAILED_WORKDIR:-0}" == '1' ]]; then
        chmod 700 "${_mwl_workspace_path}" >/dev/null 2>&1 || true
        printf 'Workflow workspace preserved: %s\n' \
            "${_mwl_workspace_path}" >&2
        return 0
    fi
    workflow_safe_remove_workspace "${_mwl_workspace_path}"
}

workflow_lifecycle_lock_path() {
    if [[ "$#" -ne 1 ]] || ! workflow_lifecycle_valid_component "$1"; then
        workflow_lifecycle_error 'lock name must be one safe path component.'
        return 64
    fi
    workflow_lifecycle_require_initialized || return 1
    printf '%s/%s.lock\n' "${MURALUME_LIFECYCLE_LOCKS_ROOT}" "$1"
}

workflow_lifecycle_lock_pid() {
    local _mwl_lock_path="$1"
    local _mwl_lock_pid

    _mwl_lock_pid="$(
        sed -n 's/^pid=//p' "${_mwl_lock_path}/metadata" 2>/dev/null
    )"
    case "${_mwl_lock_pid}" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac
    printf '%s\n' "${_mwl_lock_pid}"
}

workflow_acquire_lock() {
    if [[ "$#" -lt 1 || "$#" -gt 2 ]]; then
        workflow_lifecycle_error 'lock acquisition needs a name and optional command.'
        return 64
    fi

    local _mwl_lock_name="$1"
    local _mwl_command_description="${2:-$0}"
    local _mwl_lock_path
    local _mwl_lock_pid
    local _mwl_lock_attempt
    local _mwl_stale_lock_path

    _mwl_command_description="${_mwl_command_description//$'\r'/ }"
    _mwl_command_description="${_mwl_command_description//$'\n'/ }"

    _mwl_lock_path="$(
        workflow_lifecycle_lock_path "${_mwl_lock_name}"
    )" || return 1
    for _mwl_lock_attempt in 1 2; do
        if mkdir "${_mwl_lock_path}" 2>/dev/null; then
            if ! chmod 700 "${_mwl_lock_path}"; then
                rmdir "${_mwl_lock_path}" >/dev/null 2>&1 || true
                return 1
            fi
            if ! {
                printf '%s\n' "${MURALUME_WORKFLOW_LOCK_MARKER}"
                printf 'pid=%s\n' "$$"
                printf 'command=%s\n' "${_mwl_command_description}"
                printf 'created_at_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
            } >"${_mwl_lock_path}/metadata"; then
                rm -f "${_mwl_lock_path}/metadata" >/dev/null 2>&1 || true
                rmdir "${_mwl_lock_path}" >/dev/null 2>&1 || true
                return 1
            fi
            if ! chmod 600 "${_mwl_lock_path}/metadata"; then
                rm -f "${_mwl_lock_path}/metadata" >/dev/null 2>&1 || true
                rmdir "${_mwl_lock_path}" >/dev/null 2>&1 || true
                return 1
            fi
            printf '%s\n' "${_mwl_lock_path}"
            return 0
        fi
        [[ -d "${_mwl_lock_path}" && ! -L "${_mwl_lock_path}" ]] || {
            workflow_lifecycle_error "lock path is unsafe: ${_mwl_lock_path}"
            return 1
        }
        if _mwl_lock_pid="$(
            workflow_lifecycle_lock_pid "${_mwl_lock_path}"
        )" && kill -0 "${_mwl_lock_pid}" 2>/dev/null; then
            workflow_lifecycle_error \
                "workflow lock ${_mwl_lock_name} is held by PID ${_mwl_lock_pid}."
            return 75
        fi
        grep -F -x "${MURALUME_WORKFLOW_LOCK_MARKER}" \
            "${_mwl_lock_path}/metadata" >/dev/null 2>&1 || {
            workflow_lifecycle_error 'stale lock has no trusted marker.'
            return 1
        }
        _mwl_stale_lock_path="${_mwl_lock_path}.stale.$$"
        if mv \
            "${_mwl_lock_path}" \
            "${_mwl_stale_lock_path}" 2>/dev/null; then
            workflow_lifecycle_safe_remove_marked_directory \
                "${_mwl_stale_lock_path}" \
                "${MURALUME_LIFECYCLE_LOCKS_ROOT}" \
                metadata \
                "${MURALUME_WORKFLOW_LOCK_MARKER}" || return 1
        fi
    done

    workflow_lifecycle_error \
        "unable to acquire workflow lock ${_mwl_lock_name}."
    return 75
}

workflow_release_lock() {
    if [[ "$#" -ne 1 ]]; then
        workflow_lifecycle_error 'lock release needs a name.'
        return 64
    fi

    local _mwl_lock_name="$1"
    local _mwl_lock_path
    local _mwl_lock_pid

    _mwl_lock_path="$(
        workflow_lifecycle_lock_path "${_mwl_lock_name}"
    )" || return 1
    [[ -d "${_mwl_lock_path}" && ! -L "${_mwl_lock_path}" ]] || return 0
    grep -F -x "${MURALUME_WORKFLOW_LOCK_MARKER}" \
        "${_mwl_lock_path}/metadata" >/dev/null 2>&1 || {
        workflow_lifecycle_error 'lock release rejected an untrusted lock.'
        return 1
    }
    _mwl_lock_pid="$(workflow_lifecycle_lock_pid "${_mwl_lock_path}")" || {
        workflow_lifecycle_error 'lock release found invalid metadata.'
        return 1
    }
    [[ "${_mwl_lock_pid}" == "$$" ]] || {
        workflow_lifecycle_error 'lock release rejected a lock owned by another process.'
        return 1
    }
    workflow_lifecycle_safe_remove_marked_directory \
        "${_mwl_lock_path}" \
        "${MURALUME_LIFECYCLE_LOCKS_ROOT}" \
        metadata \
        "${MURALUME_WORKFLOW_LOCK_MARKER}"
}

workflow_rotate_logs() {
    if [[ "$#" -gt 2 ]]; then
        workflow_lifecycle_error \
            'log rotation accepts an optional retention count and protected path.'
        return 64
    fi
    workflow_lifecycle_require_initialized || return 1

    local _mwl_retention_count
    local _mwl_protected_path="${2:-}"
    local _mwl_log_path
    local _mwl_log_count=0
    _mwl_retention_count="$(
        workflow_lifecycle_retention_value "${1:-}"
    )" || return 1

    if [[ -n "${_mwl_protected_path}" ]]; then
        case "${_mwl_protected_path}" in
            "${MURALUME_LIFECYCLE_LOGS_ROOT}/"*)
                ;;
            *)
                workflow_lifecycle_error 'protected log is outside the managed log root.'
                return 1
                ;;
        esac
        [[ -f "${_mwl_protected_path}" \
            && ! -L "${_mwl_protected_path}" ]] || {
            workflow_lifecycle_error 'protected log must be a regular file.'
            return 1
        }
        _mwl_log_count=1
    fi

    while IFS= read -r _mwl_log_path; do
        [[ -n "${_mwl_log_path}" ]] || continue
        [[ "${_mwl_log_path}" != "${_mwl_protected_path}" ]] || continue
        _mwl_log_count=$((_mwl_log_count + 1))
        if [[ "${_mwl_log_count}" -gt "${_mwl_retention_count}" ]]; then
            [[ -f "${_mwl_log_path}" && ! -L "${_mwl_log_path}" ]] || {
                workflow_lifecycle_error 'log rotation encountered an unsafe entry.'
                return 1
            }
            workflow_lifecycle_path_is_within \
                "${_mwl_log_path}" \
                "${MURALUME_LIFECYCLE_LOGS_ROOT}" || return 1
            rm -f -- "${_mwl_log_path}" || return 1
        fi
    done < <(
        find "${MURALUME_LIFECYCLE_LOGS_ROOT}" \
            -mindepth 1 \
            -maxdepth 1 \
            -type f \
            -name '*.log.*' \
            -print \
            | sort -r
    )
}

workflow_create_log() {
    if [[ "$#" -ne 1 ]] || ! workflow_lifecycle_valid_component "$1"; then
        workflow_lifecycle_error 'log workflow must be one safe path component.'
        return 64
    fi
    workflow_lifecycle_require_initialized || return 1

    local _mwl_log_path
    local _mwl_timestamp
    _mwl_timestamp="$(date -u '+%Y%m%dT%H%M%SZ')" || return 1
    _mwl_log_path="$(
        mktemp \
            "${MURALUME_LIFECYCLE_LOGS_ROOT}/$1.${_mwl_timestamp}.$$.log.XXXXXX"
    )" || return 1
    if ! chmod 600 "${_mwl_log_path}"; then
        rm -f "${_mwl_log_path}" >/dev/null 2>&1 || true
        return 1
    fi
    printf '%s\n' "${_mwl_log_path}"
}
