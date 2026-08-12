#!/usr/bin/env bash

set -euo pipefail

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly scripts_directory="$(cd "${script_directory}/.." && pwd)"
readonly lifecycle_helper_path="${scripts_directory}/lib/workflow_lifecycle.sh"

test_root="$(
    mktemp -d "${TMPDIR:-/tmp}/MuralumeWorkflowLifecycleTests.XXXXXX"
)"
cleanup() {
    rm -rf "${test_root}"
}
trap cleanup EXIT

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_mode() {
    local expected_mode="$1"
    local target_path="$2"
    local description="$3"

    [[ "$(stat -f '%Lp' "${target_path}")" == "${expected_mode}" ]] \
        || fail_test "${description} did not use mode ${expected_mode}"
}

assert_absent() {
    local target_path="$1"
    local description="$2"

    [[ ! -e "${target_path}" && ! -L "${target_path}" ]] \
        || fail_test "${description} was not removed"
}

repository_root="${test_root}/repository"
mkdir -p "${repository_root}"
repository_root="$(cd "${repository_root}" && pwd -P)"
readonly repository_root

# shellcheck source=../lib/workflow_lifecycle.sh
source "${lifecycle_helper_path}"
workflow_lifecycle_initialize "${repository_root}"

[[ "${MURALUME_LIFECYCLE_ROOT}" \
    == "${repository_root}/.build/muralume" ]] \
    || fail_test 'lifecycle root was not repository-local'
assert_mode 700 "${MURALUME_LIFECYCLE_ROOT}" 'lifecycle root'
assert_mode 700 "${MURALUME_LIFECYCLE_WORKSPACES_ROOT}" 'workspace root'
assert_mode 700 "${MURALUME_LIFECYCLE_DIAGNOSTICS_ROOT}" 'diagnostics root'
assert_mode 700 "${MURALUME_LIFECYCLE_LOGS_ROOT}" 'log root'
assert_mode 700 "${MURALUME_LIFECYCLE_LOCKS_ROOT}" 'lock root'

success_workspace="$(workflow_create_workspace success)"
assert_mode 700 "${success_workspace}" 'success workspace'
assert_mode 600 \
    "${success_workspace}/${MURALUME_WORKFLOW_WORKSPACE_MARKER}" \
    'success workspace marker'
printf '%s\n' payload >"${success_workspace}/large-build-product"
workflow_cleanup_workspace "${success_workspace}" 0
assert_absent "${success_workspace}" 'successful workspace'

failure_workspace="$(workflow_create_workspace failure)"
printf '%s\n' payload >"${failure_workspace}/DerivedData"
MURALUME_KEEP_FAILED_WORKDIR=0
workflow_cleanup_workspace "${failure_workspace}" 65
assert_absent "${failure_workspace}" 'failed default workspace'

kept_workspace="$(workflow_create_workspace kept-failure)"
printf '%s\n' payload >"${kept_workspace}/archive"
MURALUME_KEEP_FAILED_WORKDIR=1
workflow_cleanup_workspace "${kept_workspace}" 70 2>/dev/null
[[ -d "${kept_workspace}" ]] \
    || fail_test 'explicit failed-workspace retention was ignored'
assert_mode 700 "${kept_workspace}" 'retained failed workspace'
MURALUME_KEEP_FAILED_WORKDIR=0
workflow_safe_remove_workspace "${kept_workspace}"
assert_absent "${kept_workspace}" 'explicitly retained workspace cleanup'

outside_workspace="${test_root}/outside-workspace"
mkdir "${outside_workspace}"
printf 'repository=%s\n' "${repository_root}" \
    >"${outside_workspace}/${MURALUME_WORKFLOW_WORKSPACE_MARKER}"
if workflow_safe_remove_workspace "${outside_workspace}" >/dev/null 2>&1; then
    fail_test 'workspace cleanup accepted a marked external directory'
fi
[[ -d "${outside_workspace}" ]] \
    || fail_test 'workspace cleanup damaged an external directory'

unmarked_workspace="${MURALUME_LIFECYCLE_WORKSPACES_ROOT}/unmarked"
mkdir "${unmarked_workspace}"
if workflow_safe_remove_workspace "${unmarked_workspace}" >/dev/null 2>&1; then
    fail_test 'workspace cleanup accepted an unmarked managed directory'
fi
[[ -d "${unmarked_workspace}" ]] \
    || fail_test 'workspace cleanup damaged an unmarked directory'

linked_workspace="${MURALUME_LIFECYCLE_WORKSPACES_ROOT}/linked"
ln -s "${outside_workspace}" "${linked_workspace}"
if workflow_safe_remove_workspace "${linked_workspace}" >/dev/null 2>&1; then
    fail_test 'workspace cleanup followed a symbolic link'
fi
[[ -L "${linked_workspace}" && -d "${outside_workspace}" ]] \
    || fail_test 'workspace cleanup damaged a symbolic-link target'

diagnostic_source="${test_root}/diagnostic-source.log"
printf '%s' '0123456789' >"${diagnostic_source}"
diagnostic_directory="$(workflow_create_diagnostic_directory bounded-copy)"
workflow_copy_diagnostic_file \
    "${diagnostic_source}" \
    "${diagnostic_directory}" \
    tail.log \
    4
assert_mode 700 "${diagnostic_directory}" 'diagnostic directory'
assert_mode 600 "${diagnostic_directory}/tail.log" 'diagnostic file'
[[ "$(<"${diagnostic_directory}/tail.log")" == '6789' ]] \
    || fail_test 'diagnostic copy did not enforce its size cap'

MURALUME_DIAGNOSTIC_RETENTION=5
diagnostic_index=0
while [[ "${diagnostic_index}" -lt 7 ]]; do
    workflow_create_diagnostic_directory retained >/dev/null
    diagnostic_index=$((diagnostic_index + 1))
done
retained_diagnostic_count="$(
    find "${MURALUME_LIFECYCLE_DIAGNOSTICS_ROOT}" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -name 'retained.*' \
        | wc -l \
        | tr -d '[:space:]'
)"
[[ "${retained_diagnostic_count}" == '5' ]] \
    || fail_test 'diagnostic retention did not keep exactly five entries'
while IFS= read -r retained_diagnostic; do
    [[ -n "${retained_diagnostic}" ]] || continue
    assert_mode 700 "${retained_diagnostic}" 'retained diagnostic directory'
    assert_mode 600 \
        "${retained_diagnostic}/${MURALUME_WORKFLOW_WORKSPACE_MARKER}" \
        'retained diagnostic marker'
done < <(
    find "${MURALUME_LIFECYCLE_DIAGNOSTICS_ROOT}" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -name 'retained.*' \
        -print
)

workflow_acquire_lock active-lock 'lifecycle owner' >/dev/null
active_lock_path="$(workflow_lifecycle_lock_path active-lock)"
assert_mode 700 "${active_lock_path}" 'active lock directory'
assert_mode 600 "${active_lock_path}/metadata" 'active lock metadata'
grep -F -x "pid=$$" "${active_lock_path}/metadata" >/dev/null \
    || fail_test 'active lock metadata did not record its PID'
grep -F -x 'command=lifecycle owner' "${active_lock_path}/metadata" >/dev/null \
    || fail_test 'active lock metadata did not record its command'

set +e
/bin/bash -c '
    set -u
    source "$1"
    workflow_lifecycle_initialize "$2"
    workflow_acquire_lock active-lock contender >/dev/null
' lifecycle-contender "${lifecycle_helper_path}" "${repository_root}" \
    >/dev/null 2>&1
lock_conflict_status="$?"
set -e
[[ "${lock_conflict_status}" -eq 75 ]] \
    || fail_test "active lock conflict returned ${lock_conflict_status}, expected 75"
workflow_release_lock active-lock
assert_absent "${active_lock_path}" 'released active lock'

stale_pid=999999
while kill -0 "${stale_pid}" 2>/dev/null; do
    stale_pid=$((stale_pid + 1))
done
stale_lock_path="$(workflow_lifecycle_lock_path stale-lock)"
mkdir "${stale_lock_path}"
{
    printf '%s\n' "${MURALUME_WORKFLOW_LOCK_MARKER}"
    printf 'pid=%s\n' "${stale_pid}"
    printf 'command=stale owner\n'
} >"${stale_lock_path}/metadata"
chmod 700 "${stale_lock_path}"
chmod 600 "${stale_lock_path}/metadata"
workflow_acquire_lock stale-lock replacement >/dev/null
grep -F -x "pid=$$" "${stale_lock_path}/metadata" >/dev/null \
    || fail_test 'stale lock was not replaced by the current owner'
grep -F -x 'command=replacement' "${stale_lock_path}/metadata" >/dev/null \
    || fail_test 'stale lock replacement did not refresh command metadata'
workflow_release_lock stale-lock
assert_absent "${stale_lock_path}" 'recovered stale lock'

printf '%s\n' 'PASS: workflow lifecycle safety and retention tests'
