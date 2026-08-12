#!/usr/bin/env bash

set -euo pipefail
umask 077

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../lib/release_provenance.sh
source "${script_directory}/../lib/release_provenance.sh"

test_root="$(
    mktemp -d "${TMPDIR:-/tmp}/MuralumeReleaseProvenanceTests.XXXXXX"
)"
cleanup() {
    local status="$?"
    rm -rf "${test_root}"
    trap - EXIT
    exit "${status}"
}
trap cleanup EXIT

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

readonly expected_commit='1111111111111111111111111111111111111111'
readonly expected_tree='2222222222222222222222222222222222222222'
readonly expected_digest='3333333333333333333333333333333333333333333333333333333333333333'
readonly expected_version='1.2.3'
readonly expected_build='42'
readonly manifest_path="${test_root}/release.manifest"

release_provenance_write \
    "${manifest_path}" \
    "${expected_commit}" \
    "${expected_tree}" \
    "${expected_digest}" \
    "${expected_version}" \
    "${expected_build}" \
    || fail_test 'could not write a valid release provenance manifest'

[[ -f "${manifest_path}" && ! -L "${manifest_path}" ]] \
    || fail_test 'the written manifest is not a regular file'
[[ "$(stat -f '%Lp' "${manifest_path}")" == '600' ]] \
    || fail_test 'the written manifest permissions were not 0600'

release_provenance_read "${manifest_path}" \
    || fail_test 'could not read a valid release provenance manifest'
[[ "${MURALUME_PROVENANCE_SOURCE_COMMIT}" == "${expected_commit}" \
    && "${MURALUME_PROVENANCE_SOURCE_TREE}" == "${expected_tree}" \
    && "${MURALUME_PROVENANCE_DMG_SHA256}" == "${expected_digest}" \
    && "${MURALUME_PROVENANCE_APP_STORE_VERSION}" \
        == "${expected_version}" \
    && "${MURALUME_PROVENANCE_APP_STORE_BUILD}" == "${expected_build}" ]] \
    || fail_test 'the parsed provenance values did not match the manifest'

release_provenance_matches \
    "${expected_commit}" \
    "${expected_tree}" \
    "${expected_digest}" \
    "${expected_version}" \
    "${expected_build}" \
    || fail_test 'matching release provenance was rejected'
release_provenance_matches \
    "${expected_commit}" \
    "${expected_tree}" \
    '' \
    "${expected_version}" \
    "${expected_build}" \
    || fail_test 'an intentionally omitted digest constraint was rejected'

if release_provenance_matches \
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    "${expected_tree}" \
    "${expected_digest}" \
    "${expected_version}" \
    "${expected_build}"; then
    fail_test 'a source commit mismatch was accepted'
fi
if release_provenance_matches \
    "${expected_commit}" \
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
    "${expected_digest}" \
    "${expected_version}" \
    "${expected_build}"; then
    fail_test 'a source tree mismatch was accepted'
fi
if release_provenance_matches \
    "${expected_commit}" \
    "${expected_tree}" \
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' \
    "${expected_version}" \
    "${expected_build}"; then
    fail_test 'a DMG digest mismatch was accepted'
fi
if release_provenance_matches \
    "${expected_commit}" \
    "${expected_tree}" \
    "${expected_digest}" \
    '1.2.4' \
    "${expected_build}"; then
    fail_test 'an App Store version mismatch was accepted'
fi
if release_provenance_matches \
    "${expected_commit}" \
    "${expected_tree}" \
    "${expected_digest}" \
    "${expected_version}" \
    '43'; then
    fail_test 'an App Store build mismatch was accepted'
fi

# The helper's module-prefixed names must not collide with common readonly
# variables owned by release callers.
(
    readonly source_commit='caller-owned-commit'
    readonly source_tree='caller-owned-tree'
    readonly release_manifest_digest='caller-owned-digest'
    readonly app_store_version='caller-owned-version'
    readonly app_store_build='caller-owned-build'
    release_provenance_read "${manifest_path}"
    release_provenance_matches \
        "${expected_commit}" \
        "${expected_tree}" \
        "${expected_digest}" \
        "${expected_version}" \
        "${expected_build}"
) || fail_test 'provenance helpers collided with readonly caller variables'

copy_manifest() {
    local destination="$1"
    cp "${manifest_path}" "${destination}"
    chmod 600 "${destination}"
}

duplicate_manifest="${test_root}/duplicate.manifest"
copy_manifest "${duplicate_manifest}"
printf 'source_commit=%s\n' "${expected_commit}" >>"${duplicate_manifest}"
if release_provenance_read "${duplicate_manifest}" >/dev/null 2>&1; then
    fail_test 'a duplicate provenance field was accepted'
fi

missing_manifest="${test_root}/missing.manifest"
sed '/^source_tree=/d' "${manifest_path}" >"${missing_manifest}"
chmod 600 "${missing_manifest}"
if release_provenance_read "${missing_manifest}" >/dev/null 2>&1; then
    fail_test 'a missing provenance field was accepted'
fi

unknown_manifest="${test_root}/unknown.manifest"
copy_manifest "${unknown_manifest}"
printf 'unexpected=value\n' >>"${unknown_manifest}"
if release_provenance_read "${unknown_manifest}" >/dev/null 2>&1; then
    fail_test 'an unknown provenance field was accepted'
fi

tampered_manifest="${test_root}/tampered.manifest"
sed 's/^dmg_sha256=.*/dmg_sha256=not-a-sha256/' \
    "${manifest_path}" >"${tampered_manifest}"
chmod 600 "${tampered_manifest}"
if release_provenance_read "${tampered_manifest}" >/dev/null 2>&1; then
    fail_test 'a malformed DMG digest was accepted'
fi

invalid_version_manifest="${test_root}/invalid-version.manifest"
sed 's/^app_store_version=.*/app_store_version=1.2/' \
    "${manifest_path}" >"${invalid_version_manifest}"
chmod 600 "${invalid_version_manifest}"
if release_provenance_read \
    "${invalid_version_manifest}" >/dev/null 2>&1; then
    fail_test 'a malformed App Store version was accepted'
fi

invalid_build_manifest="${test_root}/invalid-build.manifest"
sed 's/^app_store_build=.*/app_store_build=4a/' \
    "${manifest_path}" >"${invalid_build_manifest}"
chmod 600 "${invalid_build_manifest}"
if release_provenance_read "${invalid_build_manifest}" >/dev/null 2>&1; then
    fail_test 'a malformed App Store build was accepted'
fi

insecure_manifest="${test_root}/insecure.manifest"
copy_manifest "${insecure_manifest}"
chmod 644 "${insecure_manifest}"
if release_provenance_read "${insecure_manifest}" >/dev/null 2>&1; then
    fail_test 'an insecure manifest mode was accepted'
fi

symlink_manifest="${test_root}/symlink.manifest"
ln -s "${manifest_path}" "${symlink_manifest}"
if release_provenance_read "${symlink_manifest}" >/dev/null 2>&1; then
    fail_test 'a symlink manifest was accepted for reading'
fi

symlink_target="${test_root}/symlink-target.txt"
printf 'do not overwrite\n' >"${symlink_target}"
write_symlink="${test_root}/write-symlink.manifest"
ln -s "${symlink_target}" "${write_symlink}"
if release_provenance_write \
    "${write_symlink}" \
    "${expected_commit}" \
    "${expected_tree}" \
    "${expected_digest}" \
    "${expected_version}" \
    "${expected_build}" >/dev/null 2>&1; then
    fail_test 'a symlink manifest destination was accepted for writing'
fi
[[ "$(cat "${symlink_target}")" == 'do not overwrite' ]] \
    || fail_test 'the symlink target was modified'

directory_manifest="${test_root}/directory.manifest"
mkdir "${directory_manifest}"
if release_provenance_write \
    "${directory_manifest}" \
    "${expected_commit}" "${expected_tree}" "${expected_digest}" \
    "${expected_version}" "${expected_build}" >/dev/null 2>&1; then
    fail_test 'a directory manifest destination was accepted for writing'
fi

# Invalid data must be rejected before replacement, leaving a previously valid
# durable manifest untouched.
manifest_before_failed_write="$(shasum -a 256 "${manifest_path}")"
if release_provenance_write \
    "${manifest_path}" \
    "${expected_commit}" \
    "${expected_tree}" \
    'invalid-digest' \
    "${expected_version}" \
    "${expected_build}" >/dev/null 2>&1; then
    fail_test 'an invalid digest was accepted for writing'
fi
[[ "$(shasum -a 256 "${manifest_path}")" \
    == "${manifest_before_failed_write}" ]] \
    || fail_test 'a failed write modified the durable manifest'

release_testflight_state_is_complete VALID \
    || fail_test 'VALID was not treated as a complete TestFlight build'
for incomplete_state in PROCESSING FAILED INVALID UNKNOWN MISSING ''; do
    if release_testflight_state_is_complete "${incomplete_state}"; then
        fail_test "${incomplete_state:-empty state} was treated as complete"
    fi
done

printf '%s\n' 'PASS: durable release provenance and TestFlight state tests'
