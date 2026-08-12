#!/usr/bin/env bash

set -euo pipefail

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly scripts_directory="$(cd "${script_directory}/.." && pwd)"
readonly production_quiet_workflow_script="${scripts_directory}/run_quiet_workflow.sh"
readonly lifecycle_helper_path="${scripts_directory}/lib/workflow_lifecycle.sh"
readonly private_marker="SYNTHETIC_PRIVATE_SIGNING_METADATA"

test_root="$(mktemp -d "${TMPDIR:-/tmp}/MuralumeQuietWorkflowTests.XXXXXX")"
cleanup() {
    rm -rf "${test_root}"
}
trap cleanup EXIT

readonly fixture_repository="${test_root}/repository"
mkdir -p "${fixture_repository}/Scripts/lib"
cp "${production_quiet_workflow_script}" \
    "${fixture_repository}/Scripts/run_quiet_workflow.sh"
cp "${lifecycle_helper_path}" \
    "${fixture_repository}/Scripts/lib/workflow_lifecycle.sh"
chmod 700 "${fixture_repository}/Scripts/run_quiet_workflow.sh"
readonly quiet_workflow_script="${fixture_repository}/Scripts/run_quiet_workflow.sh"
readonly managed_log_root="${fixture_repository}/.build/muralume/diagnostics/logs"
export MURALUME_LOG_RETENTION=5

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

failing_command="${test_root}/failing-command.sh"
cat >"${failing_command}" <<EOF
#!/usr/bin/env bash
printf '%s\n' '${private_marker}' >&2
exit 17
EOF
chmod 700 "${failing_command}"

release_error_path="${test_root}/release-error"
set +e
"${quiet_workflow_script}" release-macos \
    "${failing_command}" >/dev/null 2>"${release_error_path}"
release_status="$?"
set -e
[[ "${release_status}" -eq 17 ]] \
    || fail_test "release failure returned ${release_status}, expected 17"
if grep -F "${private_marker}" "${release_error_path}" >/dev/null; then
    fail_test 'release failure echoed private signing metadata'
fi
grep -F 'signing metadata may be private' "${release_error_path}" >/dev/null \
    || fail_test 'release failure did not explain private output suppression'
if grep -F 'VERBOSE=1' "${release_error_path}" >/dev/null; then
    fail_test 'release failure suggested a privacy-unsafe verbose rerun'
fi

release_log_path="$(
    sed -n 's/^Full log: //p' "${release_error_path}"
)"
[[ -f "${release_log_path}" && ! -L "${release_log_path}" ]] \
    || fail_test 'private release log was not retained as a regular file'
[[ "$(stat -f '%Lp' "${release_log_path}")" == '600' ]] \
    || fail_test 'private release log permissions were not 0600'
grep -F "${private_marker}" "${release_log_path}" >/dev/null \
    || fail_test 'private release log lost the diagnostic output'
rm -f "${release_log_path}"

for private_workflow in release-dual validate-testflight upload-testflight; do
    private_error_path="${test_root}/${private_workflow}-error"
    set +e
    "${quiet_workflow_script}" "${private_workflow}" \
        "${failing_command}" >/dev/null 2>"${private_error_path}"
    private_status="$?"
    set -e
    [[ "${private_status}" -eq 17 ]] \
        || fail_test "${private_workflow} returned ${private_status}, expected 17"
    if grep -F "${private_marker}" "${private_error_path}" >/dev/null; then
        fail_test "${private_workflow} echoed private signing metadata"
    fi
    if grep -F 'VERBOSE=1' "${private_error_path}" >/dev/null; then
        fail_test "${private_workflow} suggested a privacy-unsafe verbose rerun"
    fi
    private_log_path="$(sed -n 's/^Full log: //p' "${private_error_path}")"
    [[ -f "${private_log_path}" && ! -L "${private_log_path}" ]] \
        || fail_test "${private_workflow} did not retain its private log"
    [[ "$(stat -f '%Lp' "${private_log_path}")" == '600' ]] \
        || fail_test "${private_workflow} log permissions were not 0600"
    grep -F "${private_marker}" "${private_log_path}" >/dev/null \
        || fail_test "${private_workflow} private log lost diagnostics"
    rm -f "${private_log_path}"
done

normal_error_path="${test_root}/normal-error"
set +e
"${quiet_workflow_script}" test \
    "${failing_command}" >/dev/null 2>"${normal_error_path}"
normal_status="$?"
set -e
[[ "${normal_status}" -eq 17 ]] \
    || fail_test "normal failure returned ${normal_status}, expected 17"
grep -F "${private_marker}" "${normal_error_path}" >/dev/null \
    || fail_test 'normal workflow did not show its diagnostic tail'
grep -F 'VERBOSE=1' "${normal_error_path}" >/dev/null \
    || fail_test 'normal workflow lost its verbose rerun guidance'
normal_log_path="$(sed -n 's/^Full log: //p' "${normal_error_path}")"
rm -f "${normal_log_path}"

success_output_path="${test_root}/success-output"
log_count_before_success="$(
    find "${managed_log_root}" -maxdepth 1 -type f -name '*.log.*' \
        | wc -l \
        | tr -d '[:space:]'
)"
"${quiet_workflow_script}" test /usr/bin/true >"${success_output_path}"
grep -F '[PASS] test completed' "${success_output_path}" >/dev/null \
    || fail_test 'successful quiet workflow did not report success'
log_count_after_success="$(
    find "${managed_log_root}" -maxdepth 1 -type f -name '*.log.*' \
        | wc -l \
        | tr -d '[:space:]'
)"
[[ "${log_count_after_success}" == "${log_count_before_success}" ]] \
    || fail_test 'successful quiet workflow retained its active log'

rotation_index=0
while [[ "${rotation_index}" -lt 8 ]]; do
    rotation_error_path="${test_root}/rotation-error-${rotation_index}"
    set +e
    "${quiet_workflow_script}" "rotation-${rotation_index}" \
        "${failing_command}" >/dev/null 2>"${rotation_error_path}"
    rotation_status="$?"
    set -e
    [[ "${rotation_status}" -eq 17 ]] \
        || fail_test \
            "rotated failure returned ${rotation_status}, expected 17"
    rotation_index=$((rotation_index + 1))
done

retained_log_count="$(
    find "${managed_log_root}" -maxdepth 1 -type f -name '*.log.*' \
        | wc -l \
        | tr -d '[:space:]'
)"
[[ "${retained_log_count}" == '5' ]] \
    || fail_test 'quiet workflow log rotation did not retain exactly five logs'
[[ "$(stat -f '%Lp' "${managed_log_root}")" == '700' ]] \
    || fail_test 'managed quiet workflow log directory was not mode 0700'
while IFS= read -r retained_log_path; do
    [[ -n "${retained_log_path}" ]] || continue
    [[ -f "${retained_log_path}" && ! -L "${retained_log_path}" ]] \
        || fail_test 'log rotation retained an unsafe entry'
    [[ "$(stat -f '%Lp' "${retained_log_path}")" == '600' ]] \
        || fail_test 'rotated quiet workflow log was not mode 0600'
    grep -F "${private_marker}" "${retained_log_path}" >/dev/null \
        || fail_test 'rotated quiet workflow log lost diagnostics'
done < <(
    find "${managed_log_root}" \
        -maxdepth 1 \
        -type f \
        -name '*.log.*' \
        -print
)

printf '%s\n' 'PASS: quiet workflow privacy tests'
