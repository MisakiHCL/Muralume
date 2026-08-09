#!/usr/bin/env bash

set -euo pipefail

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly scripts_directory="$(cd "${script_directory}/.." && pwd)"
readonly quiet_workflow_script="${scripts_directory}/run_quiet_workflow.sh"
readonly private_marker="SYNTHETIC_PRIVATE_SIGNING_METADATA"

test_root="$(mktemp -d "${TMPDIR:-/tmp}/MuralumeQuietWorkflowTests.XXXXXX")"
cleanup() {
    rm -rf "${test_root}"
}
trap cleanup EXIT

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

printf '%s\n' 'PASS: quiet workflow privacy tests'
