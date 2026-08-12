#!/usr/bin/env bash

# Validates the short-lived capability inherited by child workflows launched
# from release_dual.sh. This prevents a normal environment variable from
# becoming a public lock/gate bypass.

validate_release_dual_capability() {
    if [[ "$#" -ne 1 ]]; then
        echo "Release capability validation needs a project root." >&2
        return 64
    fi

    local capability_project_root="$1"
    local capability_path="${MURALUME_RELEASE_DUAL_CAPABILITY_PATH:-}"
    local capability_token="${MURALUME_RELEASE_DUAL_CAPABILITY_TOKEN:-}"
    local workspace_path
    local canonical_project_root
    local canonical_workspace_root
    local canonical_workspace_path
    local stored_token
    local orchestrator_pid
    local orchestrator_command
    local capability_commit
    local capability_tree
    local current_commit
    local current_tree
    local ancestor_pid
    local ancestor_depth=0
    local ancestor_found=0
    local current_uid
    local capability_uid

    [[ "${capability_path}" == /* \
        && "${capability_token}" =~ ^[[:xdigit:]]{64}$ \
        && -f "${capability_path}" \
        && ! -L "${capability_path}" \
        && "$(stat -f '%Lp' "${capability_path}")" == '600' ]] || {
        echo "The release-dual capability is missing or unsafe." >&2
        return 1
    }
    current_uid="$(id -u)"
    capability_uid="$(stat -f '%u' "${capability_path}")"
    [[ "${capability_uid}" == "${current_uid}" ]] || {
        echo "The release-dual capability has the wrong owner." >&2
        return 1
    }

    canonical_project_root="$(cd "${capability_project_root}" && pwd -P)" \
        || return 1
    canonical_workspace_root="$(
        cd "${canonical_project_root}/.build/muralume/workspaces" && pwd -P
    )" || return 1
    workspace_path="$(dirname "${capability_path}")"
    canonical_workspace_path="$(cd "${workspace_path}" && pwd -P)" \
        || return 1
    case "${canonical_workspace_path}" in
        "${canonical_workspace_root}"/MuralumeDualRelease.*)
            ;;
        *)
            echo "The release-dual capability is outside its managed workspace." >&2
            return 1
            ;;
    esac
    [[ -f "${canonical_workspace_path}/.muralume-workspace" \
        && ! -L "${canonical_workspace_path}/.muralume-workspace" ]] || {
        echo "The release-dual workspace marker is missing." >&2
        return 1
    }
    rg -F -x "repository=${canonical_project_root}" \
        "${canonical_workspace_path}/.muralume-workspace" >/dev/null || {
        echo "The release-dual workspace marker is invalid." >&2
        return 1
    }
    stored_token="$(sed -n 's/^token=//p' "${capability_path}")"
    orchestrator_pid="$(
        sed -n 's/^orchestrator_pid=//p' "${capability_path}"
    )"
    capability_commit="$(
        sed -n 's/^source_commit=//p' "${capability_path}"
    )"
    capability_tree="$(
        sed -n 's/^source_tree=//p' "${capability_path}"
    )"
    [[ "${stored_token}" == "${capability_token}" ]] || {
        echo "The release-dual capability token does not match." >&2
        return 1
    }
    [[ "${orchestrator_pid}" =~ ^[0-9]+$ \
        && "${orchestrator_pid}" != "$$" ]] || {
        echo "The release-dual capability has an invalid orchestrator PID." >&2
        return 1
    }
    orchestrator_command="$(
        ps -p "${orchestrator_pid}" -o command= 2>/dev/null || true
    )"
    [[ "${orchestrator_command}" == *'/Scripts/release_dual.sh'* ]] || {
        echo "The release-dual capability orchestrator is not running." >&2
        return 1
    }
    ancestor_pid="${PPID}"
    while [[ "${ancestor_pid}" =~ ^[0-9]+$ \
        && "${ancestor_pid}" -gt 1 \
        && "${ancestor_depth}" -lt 12 ]]; do
        if [[ "${ancestor_pid}" == "${orchestrator_pid}" ]]; then
            ancestor_found=1
            break
        fi
        ancestor_pid="$(
            ps -p "${ancestor_pid}" -o ppid= 2>/dev/null \
                | tr -d '[:space:]'
        )"
        ancestor_depth=$((ancestor_depth + 1))
    done
    [[ "${ancestor_found}" -eq 1 ]] || {
        echo "The release-dual orchestrator is not an ancestor of this workflow." >&2
        return 1
    }
    current_commit="$(
        release_git -C "${canonical_project_root}" \
            rev-parse 'HEAD^{commit}'
    )" || return 1
    current_tree="$(
        release_git -C "${canonical_project_root}" \
            rev-parse 'HEAD^{tree}'
    )" || return 1
    [[ "${capability_commit}" == "${current_commit}" \
        && "${capability_tree}" == "${current_tree}" ]] || {
        echo "The release-dual capability source no longer matches the repository." >&2
        return 1
    }
}
