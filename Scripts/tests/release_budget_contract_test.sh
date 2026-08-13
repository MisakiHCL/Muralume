#!/usr/bin/env bash

set -euo pipefail

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly project_root="$(cd "${script_directory}/../.." && pwd)"
readonly makefile_path="${project_root}/Makefile"
readonly dual_script_path="${project_root}/Scripts/release_dual.sh"
readonly shared_gate_script_path="${project_root}/Scripts/lib/release_shared_gate.sh"

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

make_variable() {
    local variable_name="$1"
    local value
    value="$(
        sed -n \
            "s/^${variable_name}[[:space:]]*:=[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p" \
            "${makefile_path}"
    )"
    [[ "${value}" =~ ^[0-9]+$ ]] \
        || fail_test "${variable_name} must be one integer assignment"
    printf '%s\n' "${value}"
}

readonly total_budget="$(make_variable FORMAL_RELEASE_BUDGET_MINUTES)"
readonly preflight_budget="$(make_variable FORMAL_RELEASE_PREFLIGHT_BUDGET_MINUTES)"
readonly gate_budget="$(make_variable FORMAL_RELEASE_GATE_BUDGET_MINUTES)"
readonly developer_id_budget="$(make_variable FORMAL_RELEASE_DEVELOPER_ID_BUDGET_MINUTES)"
readonly testflight_budget="$(make_variable FORMAL_RELEASE_TESTFLIGHT_BUDGET_MINUTES)"
readonly finalize_budget="$(make_variable FORMAL_RELEASE_FINALIZE_BUDGET_MINUTES)"
readonly shared_gate_invocations="$(
    make_variable FORMAL_RELEASE_SHARED_GATE_INVOCATIONS
)"

[[ "${total_budget}" -eq 30 ]] \
    || fail_test 'the formal dual-release budget must remain 30 minutes'
[[ $((
    preflight_budget \
    + gate_budget \
    + developer_id_budget \
    + testflight_budget \
    + finalize_budget
)) -eq "${total_budget}" ]] \
    || fail_test 'phase budgets must add up exactly to the formal release budget'
[[ "${shared_gate_invocations}" -eq 1 ]] \
    || fail_test 'the formal dual release must own exactly one shared gate'

grep -F 'run_or_reuse_shared_release_gate \' \
    "${dual_script_path}" >/dev/null \
    || fail_test 'release-dual must delegate to the shared gate helper'
[[ "$(
    rg -F 'run_or_reuse_shared_release_gate \' \
        "${dual_script_path}" | wc -l | tr -d '[:space:]'
)" -eq "${shared_gate_invocations}" ]] \
    || fail_test 'release-dual must invoke its shared gate helper exactly once'
grep -F '"${gate_source_checkout_path}/Scripts/verify.sh" all' \
    "${shared_gate_script_path}" >/dev/null \
    || fail_test 'the shared gate helper must run the complete all-suite gate'
[[ "$(
    rg -F '"${gate_source_checkout_path}/Scripts/verify.sh" all' \
        "${shared_gate_script_path}" | wc -l | tr -d '[:space:]'
)" -eq "${shared_gate_invocations}" ]] \
    || fail_test 'the shared gate helper must invoke the all-suite gate exactly once'
if rg -F 'Scripts/verify.sh" release-gate' \
    "${dual_script_path}" "${shared_gate_script_path}" >/dev/null; then
    fail_test 'the formal dual-release call graph still invokes release-gate'
fi

receipt_is_forwarded() {
    local downstream_script="$1"
    awk \
        -v invocation="\"\${script_directory}/${downstream_script}\"" \
        -v receipt='--gate-receipt "${gate_receipt_path}"' '
            index($0, invocation) {
                remaining = 10
            }
            remaining > 0 && index($0, receipt) {
                found = 1
            }
            remaining > 0 {
                remaining -= 1
            }
            END {
                exit(found ? 0 : 1)
            }
        ' "${dual_script_path}"
}

for downstream_script in release_macos.sh release_app_store.sh; do
    receipt_is_forwarded "${downstream_script}" \
        || fail_test "release-dual does not pass its shared receipt to ${downstream_script}"
done

grep -F 'The only normal public GitHub + TestFlight release entry' \
    "${makefile_path}" >/dev/null \
    || fail_test 'Make help does not identify the one formal release entry'
grep -F 'do not pre-run make test' "${makefile_path}" >/dev/null \
    || fail_test 'Make help does not forbid a redundant pre-release test run'

printf '%s\n' \
    'PASS: 30-minute dual-release budget and single shared-gate contract tests'
