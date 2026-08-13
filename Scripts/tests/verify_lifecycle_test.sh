#!/usr/bin/env bash

set -euo pipefail

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly project_root="$(cd "${script_directory}/../.." && pwd)"

test_root="$(mktemp -d "${TMPDIR:-/tmp}/MuralumeVerifyLifecycleTests.XXXXXX")"
test_root="$(cd "${test_root}" && pwd -P)"
readonly fixture_root="${test_root}/fixture"
readonly fake_bin="${test_root}/fake-bin"
readonly controlled_tmp="${test_root}/tmp"
readonly verify_script="${fixture_root}/Scripts/verify.sh"
readonly xcodebuild_log="${test_root}/xcodebuild.log"
readonly expected_cache_scope="${fixture_root}/.build/muralume/cache/verify/99.1-99A123"
readonly expected_derived_data="${expected_cache_scope}/DerivedData"
active_pid=""
active_release_marker=""

cleanup() {
    if [[ -n "${active_release_marker}" ]]; then
        : >"${active_release_marker}" 2>/dev/null || true
    fi
    if [[ -n "${active_pid}" ]]; then
        kill -TERM "${active_pid}" >/dev/null 2>&1 || true
        wait "${active_pid}" >/dev/null 2>&1 || true
    fi
    rm -rf "${test_root}"
}
trap cleanup EXIT

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_no_temporary_workspaces() {
    local leaked_paths

    leaked_paths="$(
        find "${controlled_tmp}" \
            -mindepth 1 \
            -maxdepth 1 \
            -name 'MuralumeVerify.*' \
            -print
    )"
    [[ -z "${leaked_paths}" ]] \
        || fail_test "temporary verify workspace leaked: ${leaked_paths}"
}

wait_for_file() {
    local path="$1"
    local attempt

    for attempt in {1..200}; do
        [[ -e "${path}" ]] && return 0
        sleep 0.025
    done
    fail_test "timed out waiting for ${path}"
}

run_default_verify() {
    env -u MURALUME_TEST_ARTIFACTS_DIR \
        PATH="${fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin" \
        TMPDIR="${controlled_tmp}" \
        FAKE_XCODEBUILD_LOG="${xcodebuild_log}" \
        FAKE_XCODEBUILD_STATUS="${FAKE_XCODEBUILD_STATUS:-0}" \
        FAKE_SIGNAL_PARENT="${FAKE_SIGNAL_PARENT:-}" \
        "${verify_script}" release
}

mkdir -p \
    "${fixture_root}/Muralume.xcodeproj" \
    "${fixture_root}/Scripts/lib" \
    "${fixture_root}/Scripts/tests" \
    "${fake_bin}" \
    "${controlled_tmp}"
cp "${project_root}/Scripts/verify.sh" "${verify_script}"
cp "${project_root}/Scripts/lib/signing_privacy.sh" \
    "${fixture_root}/Scripts/lib/signing_privacy.sh"
cp "${project_root}/Scripts/lib/workflow_lifecycle.sh" \
    "${fixture_root}/Scripts/lib/workflow_lifecycle.sh"
cp "${project_root}/Scripts/lib/build_cache.sh" \
    "${fixture_root}/Scripts/lib/build_cache.sh"
chmod 755 "${verify_script}"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'if [[ "$#" -eq 1 && "$1" == "-version" ]]; then' \
    '    printf "%s\n" "Xcode 99.1" "Build version 99A123"' \
    '    exit 0' \
    'fi' \
    'derived_data_path=""' \
    'previous_argument=""' \
    'for argument in "$@"; do' \
    '    if [[ "${previous_argument}" == "-derivedDataPath" ]]; then' \
    '        derived_data_path="${argument}"' \
    '    fi' \
    '    previous_argument="${argument}"' \
    'done' \
    '[[ -n "${derived_data_path}" ]]' \
    'mkdir -p "${derived_data_path}"' \
    ': >"${derived_data_path}/cache-marker"' \
    'printf "%s\n" "${derived_data_path}" >>"${FAKE_XCODEBUILD_LOG}"' \
    'if [[ -n "${FAKE_XCODEBUILD_ENTERED_PATH:-}" ]]; then' \
    '    : >"${FAKE_XCODEBUILD_ENTERED_PATH}"' \
    'fi' \
    'if [[ -n "${FAKE_XCODEBUILD_RELEASE_PATH:-}" ]]; then' \
    '    while [[ ! -e "${FAKE_XCODEBUILD_RELEASE_PATH}" ]]; do' \
    '        sleep 0.025' \
    '    done' \
    'fi' \
    'if [[ -n "${FAKE_SIGNAL_PARENT:-}" ]]; then' \
    '    kill -"${FAKE_SIGNAL_PARENT}" "${PPID}"' \
    'fi' \
    'exit "${FAKE_XCODEBUILD_STATUS:-0}"' \
    >"${fake_bin}/xcodebuild"

for command_name in rg plutil xcrun; do
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' \
        >"${fake_bin}/${command_name}"
    chmod 755 "${fake_bin}/${command_name}"
done
chmod 755 "${fake_bin}/xcodebuild"

# Help and invalid input must not create either the persistent cache or a
# disposable artifact workspace, even when an artifact override is present.
help_artifacts="${test_root}/help-artifacts-must-not-exist"
MURALUME_TEST_ARTIFACTS_DIR="${help_artifacts}" \
PATH="${fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin" \
TMPDIR="${controlled_tmp}" \
    "${verify_script}" --help >/dev/null
[[ ! -e "${help_artifacts}" && ! -e "${fixture_root}/.build" ]] \
    || fail_test 'help created verify artifacts'

invalid_status=0
MURALUME_TEST_ARTIFACTS_DIR="${help_artifacts}" \
PATH="${fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin" \
TMPDIR="${controlled_tmp}" \
    "${verify_script}" not-a-suite >/dev/null 2>&1 \
    || invalid_status=$?
[[ "${invalid_status}" -eq 64 ]] \
    || fail_test "invalid suite returned ${invalid_status}, expected 64"
[[ ! -e "${help_artifacts}" && ! -e "${fixture_root}/.build" ]] \
    || fail_test 'invalid suite created verify artifacts'
assert_no_temporary_workspaces
if find "${fixture_root}/.build/muralume/workspaces" \
    -mindepth 1 -maxdepth 1 -type d -name 'verify.*' -print -quit \
    2>/dev/null | grep . >/dev/null; then
    fail_test 'successful verify left a managed workspace behind'
fi

# The default DerivedData cache is stable, while each successful workspace is
# removed before the process returns.
: >"${xcodebuild_log}"
run_default_verify >/dev/null
run_default_verify >/dev/null
[[ -f "${expected_derived_data}/cache-marker" ]] \
    || fail_test 'the stable verify DerivedData cache was not retained'
[[ ! -e "${expected_cache_scope}/.verify.lock" ]] \
    || fail_test 'a successful verify run left its cache lock behind'
[[ "$(sed -n '1p' "${xcodebuild_log}")" == "${expected_derived_data}" \
    && "$(sed -n '2p' "${xcodebuild_log}")" == "${expected_derived_data}" ]] \
    || fail_test 'successive verify runs did not reuse one stable DerivedData path'
assert_no_temporary_workspaces

# Failure keeps the reusable cache but never the disposable TestResults
# workspace or a copied DerivedData tree.
failure_status=0
FAKE_XCODEBUILD_STATUS=65 run_default_verify >/dev/null 2>&1 \
    || failure_status=$?
[[ "${failure_status}" -eq 65 ]] \
    || fail_test "failed verify returned ${failure_status}, expected 65"
[[ -d "${expected_derived_data}" \
    && ! -e "${expected_cache_scope}/.verify.lock" ]] \
    || fail_test 'failed verify removed its cache or leaked its lock'
assert_no_temporary_workspaces
if find "${controlled_tmp}" -type d -name DerivedData -print -quit \
    | grep . >/dev/null; then
    fail_test 'failed verify copied DerivedData into temporary diagnostics'
fi

# A supplied artifact directory belongs to the caller on both success and
# failure. Only the transient lock created inside it may be removed.
caller_artifacts="${test_root}/caller-artifacts"
mkdir -p "${caller_artifacts}"
printf '%s\n' 'caller-owned' >"${caller_artifacts}/sentinel"
MURALUME_TEST_ARTIFACTS_DIR="${caller_artifacts}" \
PATH="${fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin" \
TMPDIR="${controlled_tmp}" \
FAKE_XCODEBUILD_LOG="${xcodebuild_log}" \
FAKE_XCODEBUILD_STATUS=0 \
    "${verify_script}" release >/dev/null
caller_failure_status=0
MURALUME_TEST_ARTIFACTS_DIR="${caller_artifacts}" \
PATH="${fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin" \
TMPDIR="${controlled_tmp}" \
FAKE_XCODEBUILD_LOG="${xcodebuild_log}" \
FAKE_XCODEBUILD_STATUS=66 \
    "${verify_script}" release >/dev/null 2>&1 \
    || caller_failure_status=$?
[[ "${caller_failure_status}" -eq 66 ]] \
    || fail_test 'caller-owned artifact failure did not preserve command status'
[[ "$(<"${caller_artifacts}/sentinel")" == 'caller-owned' \
    && -d "${caller_artifacts}/DerivedData" \
    && ! -e "${caller_artifacts}/.verify.lock" ]] \
    || fail_test 'verify deleted or damaged caller-owned artifacts'
assert_no_temporary_workspaces

# A live owner causes a fail-fast status before a second xcodebuild starts.
: >"${xcodebuild_log}"
entered_marker="${test_root}/concurrent-entered"
release_marker="${test_root}/concurrent-release"
active_release_marker="${release_marker}"
env -u MURALUME_TEST_ARTIFACTS_DIR \
    PATH="${fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin" \
    TMPDIR="${controlled_tmp}" \
    FAKE_XCODEBUILD_LOG="${xcodebuild_log}" \
    FAKE_XCODEBUILD_ENTERED_PATH="${entered_marker}" \
    FAKE_XCODEBUILD_RELEASE_PATH="${release_marker}" \
    "${verify_script}" release >/dev/null 2>&1 &
active_pid=$!
wait_for_file "${entered_marker}"
concurrent_status=0
run_default_verify >/dev/null 2>"${test_root}/concurrent-error" \
    || concurrent_status=$?
[[ "${concurrent_status}" -eq 75 ]] \
    || fail_test "concurrent verify returned ${concurrent_status}, expected 75"
grep -F 'already in use by process' "${test_root}/concurrent-error" >/dev/null \
    || fail_test 'concurrent verify did not explain the cache lock'
[[ "$(wc -l <"${xcodebuild_log}" | tr -d '[:space:]')" -eq 1 ]] \
    || fail_test 'the rejected concurrent verify invoked xcodebuild'
: >"${release_marker}"
wait "${active_pid}"
active_pid=""
active_release_marker=""
assert_no_temporary_workspaces
[[ ! -e "${expected_cache_scope}/.verify.lock" ]] \
    || fail_test 'the concurrent owner did not release its cache lock'

# Dead-owner metadata is reclaimed without deleting the cache itself.
mkdir "${expected_cache_scope}/.verify.lock"
printf '%s\n' '99999999' >"${expected_cache_scope}/.verify.lock/owner.pid"
run_default_verify >/dev/null
[[ -f "${expected_derived_data}/cache-marker" \
    && ! -e "${expected_cache_scope}/.verify.lock" ]] \
    || fail_test 'a stale verify cache lock was not safely reclaimed'
assert_no_temporary_workspaces

# Both supported termination signals must run the same workspace and lock
# cleanup as normal exit. The foreground fake xcodebuild signals its waiting
# parent so Bash does not apply the ignored-SIGINT rule used for async jobs.
for signal_case in INT TERM; do
    signal_status=0
    FAKE_SIGNAL_PARENT="${signal_case}" \
        run_default_verify >/dev/null 2>&1 || signal_status=$?
    expected_signal_status=130
    [[ "${signal_case}" == "TERM" ]] && expected_signal_status=143
    [[ "${signal_status}" -eq "${expected_signal_status}" ]] \
        || fail_test \
            "${signal_case} verify returned ${signal_status}, expected ${expected_signal_status}"
    [[ ! -e "${expected_cache_scope}/.verify.lock" ]] \
        || fail_test "${signal_case} verify left its cache lock behind"
    assert_no_temporary_workspaces
done

# Shell infrastructure tests are discovered dynamically and run in stable
# lexical order, so adding a new *_test.sh cannot silently omit it from CI.
discovery_log="${test_root}/discovery.log"
for test_name in z-last a-first; do
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        "printf '%s\\n' '${test_name}' >>\"\${FAKE_DISCOVERY_LOG}\"" \
        >"${fixture_root}/Scripts/tests/${test_name}_test.sh"
    chmod 755 "${fixture_root}/Scripts/tests/${test_name}_test.sh"
done
PATH="${fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin" \
FAKE_DISCOVERY_LOG="${discovery_log}" \
    bash -c '
        set -euo pipefail
        source "$1"
        check_tracked_signing_privacy() { return 0; }
        check_localization_key_parity() { return 0; }
        reject_imports() { return 0; }
        reject_references() { return 0; }
        check_architecture
    ' discovery-test "${verify_script}" >/dev/null
[[ "$(sed -n '1p' "${discovery_log}")" == 'a-first' \
    && "$(sed -n '2p' "${discovery_log}")" == 'z-last' ]] \
    || fail_test 'shell infrastructure tests were not auto-discovered in stable order'

# A formal parent gate owns a live cache lock and exports private credentials,
# proxies, and capability values. The central dispatcher must remove all of
# them before launching nested fixture tests, without releasing the parent lock.
formal_gate_artifacts="${test_root}/formal-gate-artifacts"
formal_gate_derived_data="${formal_gate_artifacts}/DerivedData"
formal_gate_probe="${test_root}/formal-gate-probe"
mkdir -p "${formal_gate_derived_data}"
MURALUME_TEST_ARTIFACTS_DIR="${formal_gate_artifacts}" \
MURALUME_TEST_DERIVED_DATA_DIR="${formal_gate_derived_data}" \
PATH="${fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin" \
TMPDIR="${controlled_tmp}" \
    bash -c '
        set -euo pipefail
        source "$1"
        install_verify_lifecycle_traps
        initialize_verify_lifecycle
        probe="$2"
        {
            printf "%s\n" "#!/usr/bin/env bash" "set -euo pipefail"
            for environment_name in "${nested_test_environment_names[@]}"; do
                printf "[[ -z \"\${%s+x}\" ]] || exit 91\n" \
                    "${environment_name}"
            done
            printf "%s\n" ": >\"\${FAKE_FORMAL_GATE_PROBE}\""
        } >"${probe}.sh"
        chmod 755 "${probe}.sh"
        MURALUME_RELEASE_LOCK_HELD=1 \
        MURALUME_RELEASE_DUAL_CAPABILITY_PATH=/private/synthetic-capability \
        MURALUME_ASC_KEY_ID=SHOULDCLEAR \
        HTTPS_PROXY=http://127.0.0.1:1 \
        FAKE_FORMAL_GATE_PROBE="${probe}" \
            run_shell_infrastructure_test "${probe}.sh"
        [[ -f "${MURALUME_TEST_ARTIFACTS_DIR}/.verify.lock/owner.pid" ]]
    ' formal-gate-test "${verify_script}" "${formal_gate_probe}" >/dev/null
[[ -f "${formal_gate_probe}" \
    && ! -e "${formal_gate_artifacts}/.verify.lock" ]] \
    || fail_test 'formal parent gate environment isolation or lock cleanup failed'

printf '%s\n' 'PASS: verify workspace, cache, lock, and discovery lifecycle tests'
