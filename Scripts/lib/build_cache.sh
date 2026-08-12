#!/usr/bin/env bash

# Stable, lane-isolated Xcode cache paths. Signed Developer ID and App Store
# archives intentionally never share a lane.

muralume_xcode_cache_key() {
    local version_output
    local xcode_version
    local xcode_build

    version_output="$(
        MURALUME_XCODE_CACHE_IDENTITY_ONLY=1 xcodebuild -version
    )" || return 1
    xcode_version="$(sed -n 's/^Xcode //p' <<<"${version_output}")"
    xcode_build="$(sed -n 's/^Build version //p' <<<"${version_output}")"
    [[ -n "${xcode_version}" && -n "${xcode_build}" ]] || {
        echo "Unable to determine the Xcode build cache identity." >&2
        return 1
    }
    printf '%s-%s' "${xcode_version}" "${xcode_build}" \
        | LC_ALL=C tr -c \
            'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-' '-'
    printf '\n'
}

muralume_prepare_xcode_cache() {
    if [[ "$#" -ne 2 \
        || ! "$2" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        echo "Xcode cache preparation needs a project root and safe lane." >&2
        return 64
    fi

    local cache_project_root="$1"
    local lane="$2"
    local cache_key
    local cache_path
    local canonical_project_root
    local cache_component
    local _muralume_cache_marker_temporary=""
    local -a cache_components

    [[ "${cache_project_root}" == /* && -d "${cache_project_root}" ]] || {
        echo "Xcode cache project root is unsafe." >&2
        return 1
    }
    canonical_project_root="$(cd "${cache_project_root}" && pwd -P)" || return 1
    cache_key="$(muralume_xcode_cache_key)" || return 1
    cache_components=(
        "${canonical_project_root}/.build"
        "${canonical_project_root}/.build/muralume"
        "${canonical_project_root}/.build/muralume/cache"
        "${canonical_project_root}/.build/muralume/cache/${lane}"
        "${canonical_project_root}/.build/muralume/cache/${lane}/${cache_key}"
        "${canonical_project_root}/.build/muralume/cache/${lane}/${cache_key}/DerivedData"
    )
    for cache_component in "${cache_components[@]}"; do
        [[ ! -L "${cache_component}" ]] || {
            echo "Xcode cache path must not contain symbolic links." >&2
            return 1
        }
        mkdir -p "${cache_component}" || return 1
        [[ "$(cd "${cache_component}" && pwd -P)" \
            == "${canonical_project_root}/.build"* ]] || {
            echo "Xcode cache escaped the project .build directory." >&2
            return 1
        }
    done
    cache_path="${canonical_project_root}/.build/muralume/cache/${lane}/${cache_key}"
    chmod 700 \
        "${canonical_project_root}/.build/muralume" \
        "${canonical_project_root}/.build/muralume/cache" \
        "${canonical_project_root}/.build/muralume/cache/${lane}" \
        "${cache_path}" \
        "${cache_path}/DerivedData" || return 1
    [[ ! -L "${cache_path}/.muralume-cache" \
        && (! -e "${cache_path}/.muralume-cache" \
        || (-f "${cache_path}/.muralume-cache" \
            && ! -L "${cache_path}/.muralume-cache")) ]] || {
        echo "Xcode cache marker must be a regular file." >&2
        return 1
    }
    _muralume_cache_marker_temporary="$(
        mktemp "${cache_path}/.muralume-cache.XXXXXX"
    )" || return 1
    if ! {
        printf 'schema=1\n'
        printf 'repository=%s\n' "${canonical_project_root}"
        printf 'lane=%s\n' "${lane}"
    } >"${_muralume_cache_marker_temporary}" \
        || ! chmod 600 "${_muralume_cache_marker_temporary}" \
        || ! mv -f "${_muralume_cache_marker_temporary}" \
            "${cache_path}/.muralume-cache"; then
        rm -f "${_muralume_cache_marker_temporary}"
        return 1
    fi
    muralume_prune_xcode_caches \
        "${canonical_project_root}" "${lane}" "${cache_path}" \
        "${MURALUME_XCODE_CACHE_RETENTION:-2}" || return 1
    printf '%s/DerivedData\n' "${cache_path}"
}

muralume_prune_xcode_caches() {
    if [[ "$#" -ne 4 ]]; then
        echo "Xcode cache pruning needs a project, lane, current path, and count." >&2
        return 64
    fi

    local cache_project_root="$1"
    local lane="$2"
    local current_cache_path="$3"
    local retention_count="$4"
    local lane_root="${cache_project_root}/.build/muralume/cache/${lane}"
    local candidate_path
    local candidate_mtime
    local oldest_path
    local oldest_mtime
    local marked_cache_count

    [[ "${retention_count}" =~ ^[1-9][0-9]*$ ]] || {
        echo "MURALUME_XCODE_CACHE_RETENTION must be a positive integer." >&2
        return 1
    }
    while :; do
        marked_cache_count=0
        oldest_path=""
        oldest_mtime=""
        for candidate_path in "${lane_root}"/*; do
            [[ -d "${candidate_path}" \
                && ! -L "${candidate_path}" \
                && -f "${candidate_path}/.muralume-cache" \
                && ! -L "${candidate_path}/.muralume-cache" ]] || continue
            marked_cache_count=$((marked_cache_count + 1))
            [[ "${candidate_path}" != "${current_cache_path}" \
                && ! -e "${candidate_path}/.verify.lock" \
                && ! -e "${candidate_path}/.active" ]] || continue
            candidate_mtime="$(stat -f '%m' "${candidate_path}")" || return 1
            if [[ -z "${oldest_mtime}" \
                || "${candidate_mtime}" -lt "${oldest_mtime}" ]]; then
                oldest_mtime="${candidate_mtime}"
                oldest_path="${candidate_path}"
            fi
        done
        [[ "${marked_cache_count}" -le "${retention_count}" ]] && break
        [[ -n "${oldest_path}" ]] || break
        /usr/bin/grep -F -x "repository=${cache_project_root}" \
            "${oldest_path}/.muralume-cache" >/dev/null || return 1
        /usr/bin/grep -F -x "lane=${lane}" \
            "${oldest_path}/.muralume-cache" >/dev/null || return 1
        [[ "$(dirname "${oldest_path}")" == "${lane_root}" ]] || return 1
        rm -rf -- "${oldest_path}" || return 1
    done
}
