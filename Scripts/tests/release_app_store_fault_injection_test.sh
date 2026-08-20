#!/usr/bin/env bash

set -euo pipefail

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly scripts_directory="$(cd "${script_directory}/.." && pwd)"

test_root="$(
    mktemp -d "${TMPDIR:-/tmp}/MuralumeAppStoreWorkflowTests.XXXXXX"
)"
test_root="$(cd "${test_root}" && pwd -P)"
readonly fixture_root="${test_root}/repository"
readonly fake_bin="${test_root}/fake-bin"
readonly fixture_tmp="${test_root}/tmp"
readonly gate_log_path="${test_root}/gate.log"
readonly archive_log_path="${test_root}/archive.log"
readonly error_log_path="${test_root}/release-error.log"
readonly app_store_private_key_path="${test_root}/AuthKey_TESTKEY123.p8"
readonly fixture_team_identifier="ABCDEFGHIJ"
readonly fixture_key_identifier="TESTKEY123"
readonly fixture_issuer_identifier="11111111-2222-3333-4444-555555555555"
readonly diagnostic_bundle_limit=5
readonly diagnostic_log_byte_limit=2097152

cleanup() {
    rm -rf -- "${test_root}"
}
trap cleanup EXIT HUP INT TERM

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_no_default_work_directories() {
    local leftover_path

    leftover_path="$(
        find "${fixture_tmp}" \
            -mindepth 1 \
            -maxdepth 1 \
            -name 'MuralumeAppStore.*' \
            -print \
            -quit
    )"
    [[ -z "${leftover_path}" ]] \
        || fail_test "default failure retained App Store work directory ${leftover_path}"
}

assert_diagnostics_are_bounded_and_private() {
    local diagnostics_root="$1"
    local diagnostic_bundle
    local diagnostic_file
    local bundle_count=0
    local file_count
    local file_size
    local unexpected_path

    [[ -d "${diagnostics_root}" && ! -L "${diagnostics_root}" ]] \
        || fail_test 'the App Store diagnostics root is missing or unsafe'
    [[ "$(stat -f '%Lp' "${diagnostics_root}")" == "700" ]] \
        || fail_test 'the App Store diagnostics root is not mode 0700'

    unexpected_path="$(
        find "${diagnostics_root}" \
            -mindepth 1 \
            -maxdepth 1 \
            \( ! -type d -o ! -name 'failure-*' \) \
            -print \
            -quit
    )"
    [[ -z "${unexpected_path}" ]] \
        || fail_test "the diagnostics root contains an unexpected entry ${unexpected_path}"

    while IFS= read -r -d '' diagnostic_bundle; do
        bundle_count=$((bundle_count + 1))
        [[ ! -L "${diagnostic_bundle}" \
            && "$(stat -f '%Lp' "${diagnostic_bundle}")" == "700" ]] \
            || fail_test 'an App Store diagnostic bundle is not a private directory'
        unexpected_path="$(
            find "${diagnostic_bundle}" \
                -mindepth 1 \
                -maxdepth 1 \
                \( ! -type f -o ! -name '*.log' \) \
                -print \
                -quit
        )"
        [[ -z "${unexpected_path}" ]] \
            || fail_test "a diagnostic bundle contains an unexpected entry ${unexpected_path}"

        file_count=0
        while IFS= read -r -d '' diagnostic_file; do
            file_count=$((file_count + 1))
            [[ ! -L "${diagnostic_file}" \
                && "$(stat -f '%Lp' "${diagnostic_file}")" == "600" ]] \
                || fail_test 'an App Store diagnostic log is not mode 0600'
            file_size="$(stat -f '%z' "${diagnostic_file}")"
            [[ "${file_size}" -le "${diagnostic_log_byte_limit}" ]] \
                || fail_test 'an App Store diagnostic log exceeds the size limit'
        done < <(
            find "${diagnostic_bundle}" \
                -mindepth 1 \
                -maxdepth 1 \
                -type f \
                -name '*.log' \
                -print0
        )
        [[ "${file_count}" -gt 0 ]] \
            || fail_test 'an empty App Store diagnostic bundle was retained'
    done < <(
        find "${diagnostics_root}" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            -name 'failure-*' \
            -print0
    )

    [[ "${bundle_count}" -eq "${diagnostic_bundle_limit}" ]] \
        || fail_test \
            "expected ${diagnostic_bundle_limit} bounded diagnostics, found ${bundle_count}"
}

mkdir -p \
    "${fixture_root}/Config" \
    "${fixture_root}/Muralume.xcodeproj" \
    "${fixture_root}/Scripts/lib" \
    "${fake_bin}" \
    "${fixture_tmp}"

cp "${scripts_directory}/release_app_store.sh" \
    "${fixture_root}/Scripts/release_app_store.sh"
for helper_name in \
    app_store_connect_api.sh \
    app_store_packaging.sh \
    app_store_validation.sh \
    build_cache.sh \
    release_gate_receipt.sh \
    release_invocation.sh \
    release_signature_validation.sh \
    release_source_snapshot.sh; do
    cp "${scripts_directory}/lib/${helper_name}" \
        "${fixture_root}/Scripts/lib/${helper_name}"
done

printf '%s\n' \
    '/Config/AppStore.local.xcconfig' \
    '/.build/' \
    >"${fixture_root}/.gitignore"
printf '%s\n' \
    'MARKETING_VERSION = 1.1.1' \
    'CURRENT_PROJECT_VERSION = 10' \
    >"${fixture_root}/Config/Base.xcconfig"
printf '%s\n' \
    'MARKETING_VERSION = 1.1.1' \
    'CURRENT_PROJECT_VERSION = 11' \
    >"${fixture_root}/Config/AppStore.xcconfig"
printf '%s\n' 'synthetic Xcode project' \
    >"${fixture_root}/Muralume.xcodeproj/project.pbxproj"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    '[[ "$#" -eq 1 && "$1" == "release-gate" ]]' \
    'source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"' \
    'printf "%s|%s|%s|%s|%s\n" \
        "${source_root}" \
        "$(git -C "${source_root}" rev-parse "HEAD^{commit}")" \
        "$(git -C "${source_root}" rev-parse "HEAD^{tree}")" \
        "${MURALUME_TEST_ARTIFACTS_DIR}" \
        "${MURALUME_TEST_DERIVED_DATA_DIR}" \
        >"${FAKE_GATE_LOG_PATH}"' \
    >"${fixture_root}/Scripts/verify.sh"
chmod 755 \
    "${fixture_root}/Scripts/release_app_store.sh" \
    "${fixture_root}/Scripts/verify.sh"

git -C "${fixture_root}" init -q
git -C "${fixture_root}" config user.name 'App Store Workflow Test'
git -C "${fixture_root}" config user.email 'app-store-workflow@example.invalid'
git -C "${fixture_root}" add .
git -C "${fixture_root}" commit -qm 'App Store fault-injection fixture'
readonly expected_commit="$(git -C "${fixture_root}" rev-parse 'HEAD^{commit}')"
readonly expected_tree="$(git -C "${fixture_root}" rev-parse 'HEAD^{tree}')"

printf '%s\n' \
    "MURALUME_APP_STORE_DEVELOPMENT_TEAM = ${fixture_team_identifier}" \
    'MURALUME_APP_STORE_CODE_SIGN_STYLE = Automatic' \
    'MURALUME_APP_STORE_PROVISIONING_PROFILE_SPECIFIER =' \
    >"${fixture_root}/Config/AppStore.local.xcconfig"
chmod 600 "${fixture_root}/Config/AppStore.local.xcconfig"
openssl genpkey \
    -algorithm EC \
    -pkeyopt ec_paramgen_curve:P-256 \
    -pkeyopt ec_param_enc:named_curve \
    -out "${app_store_private_key_path}" \
    >/dev/null 2>&1 \
    || fail_test 'could not generate an isolated App Store Connect key'
chmod 600 "${app_store_private_key_path}"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'exit 0' \
    >"${fake_bin}/python3"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'if [[ "$#" -eq 2 && "$1" == "--find" && "$2" == "python3" ]]; then' \
    '    printf "%s\n" "${FAKE_BIN_PATH}/python3"' \
    '    exit 0' \
    'fi' \
    'exit 64' \
    >"${fake_bin}/xcrun"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    '[[ "$*" == "find-identity -v -p codesigning" ]] || exit 64' \
    'printf "%s\n" "  0 valid identities found"' \
    >"${fake_bin}/security"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'if [[ "$#" -eq 1 && "$1" == "-version" ]]; then' \
    '    printf "%s\n" "Xcode 26.1.1" "Build version 17B100"' \
    '    exit 0' \
    'fi' \
    'saw_settings=0' \
    'saw_archive=0' \
    'archive_path=""' \
    'project_path=""' \
    'previous_argument=""' \
    'for argument in "$@"; do' \
    '    case "${previous_argument}" in' \
    '        -archivePath) archive_path="${argument}" ;;' \
    '        -project) project_path="${argument}" ;;' \
    '    esac' \
    '    [[ "${argument}" == "-showBuildSettings" ]] && saw_settings=1' \
    '    [[ "${argument}" == "archive" ]] && saw_archive=1' \
    '    previous_argument="${argument}"' \
    'done' \
    'if [[ "${saw_settings}" -eq 1 ]]; then' \
    '    printf "%s\n" \' \
    '        "    PRODUCT_BUNDLE_IDENTIFIER = com.muralume.Muralume" \' \
    '        "    MARKETING_VERSION = 1.1.1" \' \
    '        "    CURRENT_PROJECT_VERSION = 11" \' \
    '        "    CODE_SIGN_STYLE = Automatic"' \
    '    printf "    DEVELOPMENT_%s = %s\n" "TEAM" "${FAKE_APP_STORE_TEAM}"' \
    '    printf "%s\n" \' \
    '        "    ARCHS = arm64" \' \
    '        "    ENABLE_APP_SANDBOX = YES" \' \
    '        "    ENABLE_HARDENED_RUNTIME = YES"' \
    '    exit 0' \
    'fi' \
    '[[ "${saw_archive}" -eq 1 && -n "${archive_path}" && -n "${project_path}" ]] \
        || exit 64' \
    'source_root="$(cd "${project_path%/Muralume.xcodeproj}" && pwd -P)"' \
    'work_directory="${archive_path%/Muralume.xcarchive}"' \
    'printf "%s\n" "synthetic App Store archive failure" \
        >"${work_directory}/synthetic-archive.log"' \
    'printf "%s|%s|%s\n" \
        "${source_root}" \
        "$(git -C "${source_root}" rev-parse "HEAD^{commit}")" \
        "$(git -C "${source_root}" rev-parse "HEAD^{tree}")" \
        >"${FAKE_ARCHIVE_LOG_PATH}"' \
    'printf "%s\n" "synthetic App Store archive failure"' \
    'exit 97' \
    >"${fake_bin}/xcodebuild"
chmod 755 \
    "${fake_bin}/python3" \
    "${fake_bin}/security" \
    "${fake_bin}/xcodebuild" \
    "${fake_bin}/xcrun"

run_fixture_release() {
    local keep_failed_workdir="$1"

    env \
        -u MURALUME_RELEASE_DUAL_CAPABILITY_PATH \
        -u MURALUME_RELEASE_DUAL_CAPABILITY_TOKEN \
        "PATH=${fake_bin}:${PATH}" \
        "FAKE_ARCHIVE_LOG_PATH=${archive_log_path}" \
        "FAKE_BIN_PATH=${fake_bin}" \
        "FAKE_GATE_LOG_PATH=${gate_log_path}" \
        "FAKE_APP_STORE_TEAM=${fixture_team_identifier}" \
        "MURALUME_ASC_ISSUER_ID=${fixture_issuer_identifier}" \
        "MURALUME_ASC_KEY_ID=${fixture_key_identifier}" \
        "MURALUME_ASC_PRIVATE_KEY_PATH=${app_store_private_key_path}" \
        "MURALUME_KEEP_FAILED_WORKDIR=${keep_failed_workdir}" \
        'MURALUME_RELEASE_LOCK_HELD=0' \
        "TMPDIR=${fixture_tmp}" \
        "${fixture_root}/Scripts/release_app_store.sh" \
            --mode validate
}

run_expected_archive_failure() {
    local keep_failed_workdir="$1"
    local release_status

    set +e
    run_fixture_release "${keep_failed_workdir}" \
        >/dev/null 2>"${error_log_path}"
    release_status="$?"
    set -e
    if [[ "${release_status}" -ne 97 ]]; then
        sed -n '1,160p' "${error_log_path}" >&2 || true
        fail_test \
            "the injected App Store archive failure returned ${release_status}, expected 97"
    fi
}

run_expected_archive_failure 0
[[ -s "${gate_log_path}" ]] \
    || fail_test 'the isolated App Store release gate did not run'
[[ -s "${archive_log_path}" ]] \
    || fail_test 'the isolated App Store archive did not run'

IFS='|' read -r gate_root gate_commit gate_tree gate_artifacts gate_derived_data \
    <"${gate_log_path}"
IFS='|' read -r archive_root archive_commit archive_tree \
    <"${archive_log_path}"
[[ "${gate_root}" == "${archive_root}" && "${gate_root}" != "${fixture_root}" ]] \
    || fail_test 'the App Store gate and archive did not use one isolated source checkout'
[[ "${gate_commit}" == "${expected_commit}" \
    && "${archive_commit}" == "${expected_commit}" ]] \
    || fail_test 'the App Store gate or archive used the wrong commit'
[[ "${gate_tree}" == "${expected_tree}" \
    && "${archive_tree}" == "${expected_tree}" ]] \
    || fail_test 'the App Store gate or archive used the wrong source tree'
if [[ "${gate_artifacts}" != \
        "${fixture_tmp}"/MuralumeAppStore.*/ReleaseGate \
    || "${gate_derived_data}" != \
        "${fixture_root}"/.build/muralume/cache/release-gate/*/DerivedData ]]; then
    printf 'Gate artifacts: %s\nGate DerivedData: %s\n' \
        "${gate_artifacts}" "${gate_derived_data}" >&2
    fail_test 'the App Store gate did not use bounded artifacts and stable cache lanes'
fi
assert_no_default_work_directories
[[ ! -e "${fixture_root}/.build/muralume/checkouts/release-app-store/Source" ]] \
    || fail_test 'the default failure left an App Store source checkout behind'

# More failures prove that diagnostics are retained privately and pruned to the
# configured bound instead of accumulating with every release attempt.
for _ in 1 2 3 4 5 6; do
    run_expected_archive_failure 0
    assert_no_default_work_directories
done
readonly diagnostic_root="${fixture_root}/.build/muralume/diagnostics/release-app-store"
assert_diagnostics_are_bounded_and_private "${diagnostic_root}"

run_expected_archive_failure 1
preserved_work_directory="$(
    sed -n 's/^Private App Store work directory preserved: //p' \
        "${error_log_path}" \
        | tail -n 1
)"
[[ "${preserved_work_directory}" == "${fixture_tmp}"/MuralumeAppStore.* \
    && -d "${preserved_work_directory}" \
    && ! -L "${preserved_work_directory}" ]] \
    || fail_test 'MURALUME_KEEP_FAILED_WORKDIR=1 did not preserve the private work directory'
[[ -f "${preserved_work_directory}/synthetic-archive.log" ]] \
    || fail_test 'the explicitly preserved work directory lost the archive diagnostic'
[[ ! -e "${fixture_root}/.build/muralume/checkouts/release-app-store/Source" ]] \
    || fail_test 'the opt-in failure left the App Store source checkout directory behind'
if git -C "${fixture_root}" worktree list --porcelain \
    | grep -F -- '/checkouts/release-app-store/Source' >/dev/null; then
    fail_test 'the opt-in failure left the App Store source worktree registered'
fi
assert_diagnostics_are_bounded_and_private "${diagnostic_root}"

rm -rf -- "${preserved_work_directory}"
assert_no_default_work_directories

printf '%s\n' 'PASS: App Store workflow snapshot fault-injection tests'
