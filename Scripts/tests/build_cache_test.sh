#!/usr/bin/env bash

set -euo pipefail

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly project_root="$(cd "${script_directory}/../.." && pwd)"
# shellcheck source=../lib/build_cache.sh
source "${script_directory}/../lib/build_cache.sh"

test_root="$(mktemp -d "${TMPDIR:-/tmp}/MuralumeBuildCacheTests.XXXXXX")"
cleanup() { rm -rf "${test_root}"; }
trap cleanup EXIT
fail_test() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

fake_bin="${test_root}/bin"
repository="${test_root}/repository"
mkdir -p "${fake_bin}" "${repository}"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "Xcode ${FAKE_XCODE_VERSION:-99.1}" "Build version ${FAKE_XCODE_BUILD:-99A1}"' \
    >"${fake_bin}/xcodebuild"
chmod 700 "${fake_bin}/xcodebuild"
export PATH="${fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin"

first_cache="$(muralume_prepare_xcode_cache "${repository}" release-test)"
second_cache="$(muralume_prepare_xcode_cache "${repository}" release-test)"
[[ "${first_cache}" == "${second_cache}" && -d "${first_cache}" ]] \
    || fail_test 'stable Xcode identity did not reuse one cache'

(
    readonly cache_marker_temporary='caller-owned-marker'
    muralume_prepare_xcode_cache \
        "${repository}" readonly-caller >/dev/null
) || fail_test 'cache helper collided with a readonly caller variable'

FAKE_XCODE_BUILD=99A2 muralume_prepare_xcode_cache \
    "${repository}" release-test >/dev/null
FAKE_XCODE_BUILD=99A3 muralume_prepare_xcode_cache \
    "${repository}" release-test >/dev/null
cache_count="$(
    find "${repository}/.build/muralume/cache/release-test" \
        -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d '[:space:]'
)"
[[ "${cache_count}" -eq 2 ]] \
    || fail_test 'old Xcode caches were not bounded to two identities'

for symlink_component in build muralume cache lane key derived marker; do
    symlink_repository="${test_root}/symlink-${symlink_component}"
    outside="${test_root}/outside-${symlink_component}"
    mkdir -p "${symlink_repository}/.build" "${outside}"
    case "${symlink_component}" in
        build)
            rmdir "${symlink_repository}/.build"
            ln -s "${outside}" "${symlink_repository}/.build"
            ;;
        muralume)
            ln -s "${outside}" "${symlink_repository}/.build/muralume"
            ;;
        cache)
            mkdir "${symlink_repository}/.build/muralume"
            ln -s "${outside}" "${symlink_repository}/.build/muralume/cache"
            ;;
        lane)
            mkdir -p "${symlink_repository}/.build/muralume/cache"
            ln -s "${outside}" \
                "${symlink_repository}/.build/muralume/cache/release-test"
            ;;
        key)
            mkdir -p "${symlink_repository}/.build/muralume/cache/release-test"
            ln -s "${outside}" \
                "${symlink_repository}/.build/muralume/cache/release-test/99.1-99A1"
            ;;
        derived)
            mkdir -p \
                "${symlink_repository}/.build/muralume/cache/release-test/99.1-99A1"
            ln -s "${outside}" \
                "${symlink_repository}/.build/muralume/cache/release-test/99.1-99A1/DerivedData"
            ;;
        marker)
            mkdir -p \
                "${symlink_repository}/.build/muralume/cache/release-test/99.1-99A1/DerivedData"
            ln -s "${outside}/marker" \
                "${symlink_repository}/.build/muralume/cache/release-test/99.1-99A1/.muralume-cache"
            ;;
    esac
    if muralume_prepare_xcode_cache \
        "${symlink_repository}" release-test >/dev/null 2>&1; then
        fail_test "cache accepted ${symlink_component} symlink"
    fi
done

marker_directory_repository="${test_root}/marker-directory"
mkdir -p \
    "${marker_directory_repository}/.build/muralume/cache/release-test/99.1-99A1/DerivedData" \
    "${marker_directory_repository}/.build/muralume/cache/release-test/99.1-99A1/.muralume-cache"
if muralume_prepare_xcode_cache \
    "${marker_directory_repository}" release-test >/dev/null 2>&1; then
    fail_test 'cache accepted a marker directory'
fi

active_repository="${test_root}/active-retention"
mkdir -p "${active_repository}"
FAKE_XCODE_BUILD=99A1 muralume_prepare_xcode_cache \
    "${active_repository}" release-test >/dev/null
touch "${active_repository}/.build/muralume/cache/release-test/99.1-99A1/.active"
FAKE_XCODE_BUILD=99A2 muralume_prepare_xcode_cache \
    "${active_repository}" release-test >/dev/null
FAKE_XCODE_BUILD=99A3 muralume_prepare_xcode_cache \
    "${active_repository}" release-test >/dev/null
[[ -d "${active_repository}/.build/muralume/cache/release-test/99.1-99A1" ]] \
    || fail_test 'retention removed an active cache'

printf '%s\n' 'PASS: stable Xcode cache safety and retention tests'
