#!/usr/bin/env bash

# Git source snapshot helpers for formal distribution releases. This file is
# intended to be sourced.

release_git() {
    env \
        -u GIT_DIR \
        -u GIT_WORK_TREE \
        -u GIT_INDEX_FILE \
        -u GIT_OBJECT_DIRECTORY \
        -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
        -u GIT_COMMON_DIR \
        -u GIT_CONFIG \
        -u GIT_CONFIG_GLOBAL \
        -u GIT_CONFIG_SYSTEM \
        -u GIT_CONFIG_PARAMETERS \
        -u GIT_NAMESPACE \
        GIT_CONFIG_COUNT=0 \
        GIT_NO_REPLACE_OBJECTS=1 \
        git "$@"
}

reject_release_git_object_overrides() {
    if [[ "$#" -ne 1 ]]; then
        echo "Release Git override validation needs a repository path." >&2
        return 64
    fi

    local repository_path="$1"
    local git_common_directory
    local replace_ref
    local replace_refs

    replace_refs="$(
        release_git -C "${repository_path}" for-each-ref \
            --format='%(refname)' \
            refs/replace
    )" || return 1
    replace_ref="$(printf '%s\n' "${replace_refs}" | sed -n '1p')"
    if [[ -n "${replace_ref}" ]]; then
        echo "Formal releases reject Git replace refs: ${replace_ref}" >&2
        return 1
    fi

    git_common_directory="$(
        release_git -C "${repository_path}" rev-parse --git-common-dir \
            2>/dev/null
    )" || return 1
    case "${git_common_directory}" in
        /*)
            ;;
        *)
            git_common_directory="${repository_path}/${git_common_directory}"
            ;;
    esac
    git_common_directory="$(
        cd "${git_common_directory}" && pwd -P
    )" || return 1
    if [[ -e "${git_common_directory}/info/grafts" \
        || -L "${git_common_directory}/info/grafts" ]]; then
        echo "Formal releases reject the legacy Git info/grafts mechanism." >&2
        return 1
    fi
}

verify_clean_release_repository() {
    if [[ "$#" -ne 1 ]]; then
        echo "Release source validation needs a repository path." >&2
        return 64
    fi

    local repository_path="$1"
    local repository_status

    release_git -C "${repository_path}" rev-parse --verify 'HEAD^{commit}' \
        >/dev/null 2>&1 || {
        echo "The release source repository has no valid HEAD commit." >&2
        return 1
    }
    repository_status="$(
        release_git -C "${repository_path}" status \
            --porcelain=v1 \
            --untracked-files=all
    )" || return 1
    if [[ -n "${repository_status}" ]]; then
        echo "A formal release requires a clean tracked worktree and no unignored files." >&2
        return 1
    fi
}

release_reclaim_managed_worktree() {
    if [[ "$#" -ne 2 ]]; then
        echo "Managed worktree cleanup needs a repository and path." >&2
        return 64
    fi
    local reclaim_repository_path="$1"
    local reclaim_checkout_path="$2"
    local reclaim_repository_root
    local reclaim_checkout_parent
    local reclaim_common_directory
    local reclaim_checkout_common_directory

    [[ "${reclaim_checkout_path}" == /* ]] || return 1
    reclaim_repository_root="$(
        cd "${reclaim_repository_path}" && pwd -P
    )" || return 1
    reclaim_checkout_parent="$(dirname "${reclaim_checkout_path}")"
    [[ -d "${reclaim_checkout_parent}" \
        && "$(cd "${reclaim_checkout_parent}" && pwd -P)" \
            == "${reclaim_repository_root}/.build/muralume/checkouts/"* ]] \
        || return 1

    release_git -C "${reclaim_repository_root}" worktree remove --force \
        "${reclaim_checkout_path}" >/dev/null 2>&1 || true
    release_git -C "${reclaim_repository_root}" worktree prune \
        >/dev/null 2>&1 || return 1
    [[ ! -e "${reclaim_checkout_path}" \
        && ! -L "${reclaim_checkout_path}" ]] && return 0
    [[ -d "${reclaim_checkout_path}" \
        && ! -L "${reclaim_checkout_path}" \
        && -f "${reclaim_checkout_path}/.git" \
        && ! -L "${reclaim_checkout_path}/.git" ]] || return 1
    reclaim_common_directory="$(
        release_git -C "${reclaim_repository_root}" rev-parse --git-common-dir
    )" || return 1
    case "${reclaim_common_directory}" in
        /*) reclaim_common_directory="$(cd "${reclaim_common_directory}" && pwd -P)" ;;
        *) reclaim_common_directory="$(cd "${reclaim_repository_root}/${reclaim_common_directory}" && pwd -P)" ;;
    esac || return 1
    reclaim_checkout_common_directory="$(
        release_git -C "${reclaim_checkout_path}" rev-parse --git-common-dir
    )" || return 1
    case "${reclaim_checkout_common_directory}" in
        /*) reclaim_checkout_common_directory="$(cd "${reclaim_checkout_common_directory}" && pwd -P)" ;;
        *) reclaim_checkout_common_directory="$(cd "${reclaim_checkout_path}/${reclaim_checkout_common_directory}" && pwd -P)" ;;
    esac || return 1
    [[ "${reclaim_checkout_common_directory}" \
        == "${reclaim_common_directory}" ]] || return 1
    rm -rf -- "${reclaim_checkout_path}"
    release_git -C "${reclaim_repository_root}" worktree prune \
        >/dev/null 2>&1
}

verify_release_source_snapshot() {
    if [[ "$#" -ne 3 ]]; then
        echo "Release snapshot validation needs a checkout, commit, and tree." >&2
        return 64
    fi

    local checkout_path="$1"
    local expected_commit="$2"
    local expected_tree="$3"
    local actual_commit
    local actual_tree
    local checkout_status

    actual_commit="$(
        release_git -C "${checkout_path}" rev-parse --verify \
            'HEAD^{commit}' 2>/dev/null
    )" || return 1
    actual_tree="$(
        release_git -C "${checkout_path}" rev-parse --verify \
            'HEAD^{tree}' 2>/dev/null
    )" || return 1
    checkout_status="$(
        release_git -C "${checkout_path}" status \
            --porcelain=v1 \
            --untracked-files=all
    )" || return 1

    if [[ "${actual_commit}" != "${expected_commit}" \
        || "${actual_tree}" != "${expected_tree}" \
        || -n "${checkout_status}" ]]; then
        echo "The isolated release source no longer matches the captured clean HEAD and tree." >&2
        return 1
    fi
}

release_xcconfig_value_at_commit() {
    if [[ "$#" -ne 4 ]]; then
        echo "Release xcconfig lookup needs a repository, commit, path, and key." >&2
        return 64
    fi

    local repository_path="$1"
    local commit="$2"
    local config_path="$3"
    local setting_key="$4"
    local config_content
    local matches
    local match_count

    config_content="$(
        release_git -C "${repository_path}" show \
            "${commit}:${config_path}" 2>/dev/null
    )" || {
        echo "The captured release source is missing ${config_path}." >&2
        return 1
    }
    matches="$(
        printf '%s\n' "${config_content}" \
            | sed -n \
                "s/^[[:space:]]*${setting_key}[[:space:]]*=[[:space:]]*\([^[:space:]#]*\)[[:space:]]*\(#.*\)\{0,1\}$/\1/p"
    )"
    match_count="$(
        printf '%s\n' "${matches}" \
            | sed '/^$/d' \
            | wc -l \
            | tr -d '[:space:]'
    )"
    if [[ "${match_count}" != "1" ]]; then
        echo "${config_path} must define ${setting_key} exactly once." >&2
        return 1
    fi
    printf '%s\n' "${matches}"
}

validate_formal_release_version() {
    if [[ "$#" -ne 5 ]]; then
        echo "Formal release version validation needs a repository, commit, version, build, and Python." >&2
        return 64
    fi

    local release_repository_path="$1"
    local release_source_commit="$2"
    local release_expected_version="$3"
    local release_expected_build="$4"
    local release_python_path="$5"
    local config_path='Config/Base.xcconfig'
    local configured_version
    local configured_build
    local expected_tag
    local tagged_commit
    local candidate_tag
    local candidate_version
    local candidate_configured_version
    local candidate_build
    local previous_release_count=0
    local release_tags

    [[ "${release_expected_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        echo "The formal release version must be a three-component semantic version." >&2
        return 1
    }
    [[ "${release_expected_build}" =~ ^[0-9]+$ ]] || {
        echo "The formal release build number must be an integer." >&2
        return 1
    }

    configured_version="$(
        release_xcconfig_value_at_commit \
            "${release_repository_path}" \
            "${release_source_commit}" \
            "${config_path}" \
            MARKETING_VERSION
    )" || return 1
    configured_build="$(
        release_xcconfig_value_at_commit \
            "${release_repository_path}" \
            "${release_source_commit}" \
            "${config_path}" \
            CURRENT_PROJECT_VERSION
    )" || return 1
    if [[ "${configured_version}" != "${release_expected_version}" \
        || "${configured_build}" != "${release_expected_build}" ]]; then
        echo "The formal release version and build must come from the captured Base.xcconfig." >&2
        return 1
    fi

    expected_tag="v${release_expected_version}"
    if tagged_commit="$(
        release_git -C "${release_repository_path}" rev-parse --verify \
            "refs/tags/${expected_tag}^{commit}" 2>/dev/null
    )"; then
        if [[ "${tagged_commit}" != "${release_source_commit}" ]]; then
            echo "${expected_tag} already points to a different source commit." >&2
            return 1
        fi
    fi

    release_tags="$(
        release_git -C "${release_repository_path}" tag --list 'v*'
    )" || return 1
    while IFS= read -r candidate_tag; do
        [[ "${candidate_tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
            || continue
        [[ "${candidate_tag}" != "${expected_tag}" ]] || continue
        previous_release_count=$((previous_release_count + 1))
        candidate_version="${candidate_tag#v}"

        candidate_configured_version="$(
            release_xcconfig_value_at_commit \
                "${release_repository_path}" \
                "${candidate_tag}^{commit}" \
                "${config_path}" \
                MARKETING_VERSION
        )" || return 1
        if [[ "${candidate_configured_version}" != "${candidate_version}" ]]; then
            echo "${candidate_tag} does not match its Base.xcconfig version." >&2
            return 1
        fi
        candidate_build="$(
            release_xcconfig_value_at_commit \
                "${release_repository_path}" \
                "${candidate_tag}^{commit}" \
                "${config_path}" \
                CURRENT_PROJECT_VERSION
        )" || return 1
        [[ "${candidate_build}" =~ ^[0-9]+$ ]] || {
            echo "${candidate_tag} has an invalid Base.xcconfig build number." >&2
            return 1
        }

        if ! "${release_python_path}" -c '
import sys

def version(value):
    return tuple(int(component) for component in value.split("."))

raise SystemExit(0 if version(sys.argv[1]) > version(sys.argv[2]) else 1)
' "${release_expected_version}" "${candidate_version}"; then
            echo "The release version must be greater than ${candidate_tag}." >&2
            return 1
        fi
        if ! "${release_python_path}" -c '
import sys
raise SystemExit(0 if int(sys.argv[1]) > int(sys.argv[2]) else 1)
' "${release_expected_build}" "${candidate_build}"; then
            echo "The release build must be greater than ${candidate_tag} build ${candidate_build}." >&2
            return 1
        fi
    done <<<"${release_tags}"
    if [[ "${previous_release_count}" -eq 0 ]]; then
        echo "A previous semantic-version release tag is required." >&2
        return 1
    fi
}
