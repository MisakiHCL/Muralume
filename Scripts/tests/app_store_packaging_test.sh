#!/usr/bin/env bash

set -euo pipefail
umask 077

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly project_root="$(cd "${script_directory}/../.." && pwd)"
readonly helper_path="${project_root}/Scripts/lib/app_store_packaging.sh"
readonly release_script_path="${project_root}/Scripts/release_app_store.sh"
readonly test_root="$(mktemp -d "${TMPDIR:-/tmp}/MuralumeAppStorePackaging.XXXXXX")"

# The production helper delegates log capture to the release workflow. Keep a
# minimal equivalent here so this test isolates the child-process umask.
run_private_command() {
    local stage_name="$1"
    local log_path="$2"
    shift 2
    : "${stage_name}"
    "$@" >"${log_path}" 2>&1
}

# shellcheck source=../lib/app_store_packaging.sh
source "${helper_path}"

cleanup() {
    rm -rf "${test_root}"
}
trap cleanup EXIT

readonly output_path="${test_root}/exported-file"
readonly output_directory_path="${test_root}/exported-directory"
readonly packaging_log_fixture_path="${test_root}/packaging.log"
readonly private_sentinel_path="${test_root}/private-sentinel"

touch "${private_sentinel_path}"

run_app_store_packaging_command \
    "Creating fixture package" \
    "${packaging_log_fixture_path}" \
    /bin/bash -c 'umask; : >"$1"; mkdir "$2"' \
    packaging-fixture \
    "${output_path}" \
    "${output_directory_path}"

[[ "$(stat -f '%Lp' "${test_root}")" == "700" ]] \
    || { echo "Private App Store work directory did not keep mode 0700." >&2; exit 1; }
[[ "$(stat -f '%Lp' "${private_sentinel_path}")" == "600" ]] \
    || { echo "Private App Store sentinel did not keep mode 0600." >&2; exit 1; }
[[ "$(stat -f '%Lp' "${output_path}")" == "644" ]] \
    || { echo "App Store package output did not use mode 0644." >&2; exit 1; }
[[ "$(stat -f '%Lp' "${output_directory_path}")" == "755" ]] \
    || { echo "App Store package directory did not use mode 0755." >&2; exit 1; }
[[ "$(stat -f '%Lp' "${packaging_log_fixture_path}")" == "600" ]] \
    || { echo "Private App Store packaging log did not keep mode 0600." >&2; exit 1; }
[[ "$(tr -d '[:space:]' <"${packaging_log_fixture_path}")" == "0022" ]] \
    || { echo "App Store packaging subprocess did not use umask 022." >&2; exit 1; }
[[ "$(umask)" == "0077" ]] \
    || { echo "App Store packaging changed the parent private umask." >&2; exit 1; }

failure_status=0
run_app_store_packaging_command \
    "Failing fixture package" \
    "${test_root}/failure.log" \
    /bin/bash -c 'exit 23' \
    packaging-failure \
    || failure_status=$?
[[ "${failure_status}" -eq 23 ]] \
    || { echo "App Store packaging did not preserve command failure status." >&2; exit 1; }
[[ "$(stat -f '%Lp' "${test_root}/failure.log")" == "600" ]] \
    || { echo "Failed App Store packaging log did not keep mode 0600." >&2; exit 1; }
[[ "$(umask)" == "0077" ]] \
    || { echo "Failed App Store packaging changed the parent private umask." >&2; exit 1; }

readonly isolated_xcodebuild_wrapper_invocations="$(
    awk '
        /^run_app_store_packaging_command/ { wrapped = 1; next }
        wrapped && /^[[:space:]]+run_xcodebuild_with_app_store_auth archive/ {
            archive_count += 1
            wrapped = 0
            next
        }
        wrapped && /^[[:space:]]+run_xcodebuild_with_app_store_auth -exportArchive/ {
            export_count += 1
            wrapped = 0
            next
        }
        wrapped && /^[^[:space:]]/ { wrapped = 0 }
        END { printf "%d:%d", archive_count, export_count }
    ' "${release_script_path}"
)"
[[ "${isolated_xcodebuild_wrapper_invocations}" == "1:3" ]] \
    || { echo "All four App Store archive/export calls must use readable packaging permissions." >&2; exit 1; }

readonly real_xcodebuild_delegations="$(
    awk '
        /^run_xcodebuild_with_app_store_auth\(\) \{/ {
            in_wrapper = 1
            next
        }
        in_wrapper && /^}/ {
            in_wrapper = 0
            next
        }
        in_wrapper && /^[[:space:]]+xcodebuild "\$@"/ {
            delegation_count += 1
            if ($0 ~ /app_store_authentication_arguments/) {
                authenticated_delegation_count += 1
            }
        }
        END {
            printf "%d:%d", delegation_count, authenticated_delegation_count
        }
    ' "${release_script_path}"
)"
[[ "${real_xcodebuild_delegations}" == "2:1" ]] \
    || { echo "The App Store authentication wrapper must delegate both branches to xcodebuild." >&2; exit 1; }

printf 'App Store packaging permission checks passed.\n'
