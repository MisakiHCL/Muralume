#!/usr/bin/env bash

set -euo pipefail

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly scripts_directory="$(cd "${script_directory}/.." && pwd)"

test_root="$(
    mktemp -d "${TMPDIR:-/tmp}/MuralumeReleaseWorkflowTests.XXXXXX"
)"
readonly fixture_root="${test_root}/repository"
readonly fake_bin="${test_root}/fake-bin"
readonly output_root="${test_root}/output"
readonly gate_log_path="${test_root}/gate.log"
readonly archive_log_path="${test_root}/archive.log"
readonly requirement_log_path="${test_root}/requirement.log"
readonly error_log_path="${test_root}/release-error.log"
readonly test_python_path="$(xcrun --find python3)"

cleanup() {
    rm -rf "${test_root}"
}
trap cleanup EXIT

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    local expected="$1"
    local path="$2"
    local description="$3"

    if ! grep -F -- "${expected}" "${path}" >/dev/null; then
        sed -n '1,120p' "${path}" >&2 || true
        fail_test "${description}: missing '${expected}'"
    fi
}

mkdir -p \
    "${fixture_root}/Config" \
    "${fixture_root}/Muralume/Resources" \
    "${fixture_root}/Muralume.xcodeproj" \
    "${fixture_root}/Scripts/lib" \
    "${fake_bin}" \
    "${output_root}"

cp "${scripts_directory}/release_macos.sh" \
    "${fixture_root}/Scripts/release_macos.sh"
cp "${scripts_directory}/lib/release_source_snapshot.sh" \
    "${fixture_root}/Scripts/lib/release_source_snapshot.sh"

printf '%s\n' \
    'Config/Release.local.mk' \
    'Config/Distribution.requirements' \
    >"${fixture_root}/.gitignore"
printf '%s\n' \
    'MARKETING_VERSION = 1.0.3' \
    'CURRENT_PROJECT_VERSION = 5' \
    >"${fixture_root}/Config/Base.xcconfig"
printf '%s\n' 'CODE_SIGNING_ALLOWED = NO' \
    >"${fixture_root}/Muralume.xcodeproj/project.pbxproj"
printf '%s\n' '<?xml version="1.0"?><plist version="1.0"><dict/></plist>' \
    >"${fixture_root}/Muralume/Resources/Muralume.entitlements"
printf '%s\n' '#!/usr/bin/env swift' \
    >"${fixture_root}/Scripts/render_dmg_background.swift"
printf '%s\n' '#!/usr/bin/env python3' \
    >"${fixture_root}/Scripts/configure_dmg.py"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"' \
    'printf "%s|%s|%s|%s|%s|%s\n" "${source_root}" "$(git -C "${source_root}" rev-parse HEAD)" "$(git -C "${source_root}" rev-parse "HEAD^{tree}")" "${MURALUME_TEST_ARTIFACTS_DIR}" "${GIT_NO_REPLACE_OBJECTS:-}" "${GIT_REPLACE_REF_BASE:-}" >"${FAKE_GATE_LOG_PATH}"' \
    >"${fixture_root}/Scripts/verify.sh"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'validate_distribution_requirement_provenance() {' \
    '    printf "%s|%s\n" "$1" "$(stat -f "%Lp" "$1")" >"${FAKE_REQUIREMENT_LOG_PATH}"' \
    '}' \
    'resolve_developer_id_identity_hash() {' \
    '    printf "%s\n" AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' \
    '}' \
    'verify_embedded_distribution_requirement() { return 0; }' \
    >"${fixture_root}/Scripts/lib/distribution_requirements.sh"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'commit_release_output_pair() { return 0; }' \
    >"${fixture_root}/Scripts/lib/release_output_transaction.sh"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'validate_release_privacy_manifest() { return 0; }' \
    'validate_release_entitlements_allowlist() { return 0; }' \
    'signature_has_hardened_runtime() { return 0; }' \
    >"${fixture_root}/Scripts/lib/release_signature_validation.sh"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'sign_with_secure_timestamp() { return 0; }' \
    >"${fixture_root}/Scripts/lib/secure_timestamp.sh"

chmod +x \
    "${fixture_root}/Scripts/release_macos.sh" \
    "${fixture_root}/Scripts/verify.sh"

git -C "${fixture_root}" init -q
git -C "${fixture_root}" config user.name 'Release Workflow Test'
git -C "${fixture_root}" config user.email 'release-workflow@example.invalid'
git -C "${fixture_root}" add .
git -C "${fixture_root}" commit -qm 'release 1.0.3 fixture'
git -C "${fixture_root}" tag v1.0.3

printf '%s\n' \
    'MARKETING_VERSION = 1.1.1' \
    'CURRENT_PROJECT_VERSION = 10' \
    >"${fixture_root}/Config/Base.xcconfig"
git -C "${fixture_root}" add Config/Base.xcconfig
git -C "${fixture_root}" commit -qm 'release 1.1.1 candidate fixture'
readonly expected_commit="$(git -C "${fixture_root}" rev-parse HEAD)"
readonly expected_tree="$(git -C "${fixture_root}" rev-parse 'HEAD^{tree}')"

printf '%s\n' 'private release configuration fixture' \
    >"${fixture_root}/Config/Release.local.mk"
printf '%s\n' 'private requirement fixture' \
    >"${fixture_root}/Config/Distribution.requirements"
chmod 600 \
    "${fixture_root}/Config/Release.local.mk" \
    "${fixture_root}/Config/Distribution.requirements"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'if [[ "$1" == "--find" && "$2" == "python3" ]]; then' \
    '    printf "%s\n" "${FAKE_PYTHON_PATH}"' \
    '    exit 0' \
    'fi' \
    'if [[ "$1" == "notarytool" && "$2" == "history" ]]; then' \
    '    exit 0' \
    'fi' \
    'exit 64' \
    >"${fake_bin}/xcrun"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'project_path=""' \
    'previous=""' \
    'for argument in "$@"; do' \
    '    if [[ "${previous}" == "-project" ]]; then project_path="${argument}"; fi' \
    '    previous="${argument}"' \
    'done' \
    'source_root="$(cd "${project_path%/Muralume.xcodeproj}" && pwd -P)"' \
    'printf "%s|%s|%s|%s|%s\n" "${source_root}" "$(git -C "${source_root}" rev-parse HEAD)" "$(git -C "${source_root}" rev-parse "HEAD^{tree}")" "${GIT_NO_REPLACE_OBJECTS:-}" "${GIT_REPLACE_REF_BASE:-}" >"${FAKE_ARCHIVE_LOG_PATH}"' \
    'exit 97' \
    >"${fake_bin}/xcodebuild"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"${fake_bin}/rg"
chmod +x \
    "${fake_bin}/rg" \
    "${fake_bin}/xcrun" \
    "${fake_bin}/xcodebuild"

run_fixture_release() {
    local identity_variable='MURALUME_DEVELOPER_ID_'
    local notary_variable='MURALUME_NOTARY_KEYCHAIN_'
    local team_variable='MURALUME_EXPECTED_TEAM_'
    identity_variable+='APPLICATION'
    notary_variable+='PROFILE'
    team_variable+='IDENTIFIER'

    env \
        "PATH=${fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin" \
        "FAKE_PYTHON_PATH=${test_python_path}" \
        "FAKE_GATE_LOG_PATH=${gate_log_path}" \
        "FAKE_ARCHIVE_LOG_PATH=${archive_log_path}" \
        "FAKE_REQUIREMENT_LOG_PATH=${requirement_log_path}" \
        "${identity_variable}=Developer ID Application" \
        "${notary_variable}=TEST-NOTARY-PROFILE" \
        "${team_variable}=ABCDEFGHIJ" \
        "${fixture_root}/Scripts/release_macos.sh" \
            --mode distribution \
            --output "${output_root}/Muralume.dmg"
}

printf '%s\n' 'dirty' >"${fixture_root}/untracked.txt"
if run_fixture_release >/dev/null 2>"${error_log_path}"; then
    fail_test 'an untracked release source should fail'
fi
assert_contains \
    'A formal release requires a clean tracked worktree and no unignored files.' \
    "${error_log_path}" \
    'dirty source rejection'
[[ ! -e "${gate_log_path}" ]] \
    || fail_test 'the release gate must not run for dirty source'
rm "${fixture_root}/untracked.txt"

if GIT_REPLACE_REF_BASE='refs/synthetic-replacements' \
    run_fixture_release >/dev/null 2>"${error_log_path}"; then
    fail_test 'a custom Git replacement ref base should fail'
fi
assert_contains \
    'A formal release rejects GIT_REPLACE_REF_BASE.' \
    "${error_log_path}" \
    'custom replacement ref-base rejection'

git -C "${fixture_root}" replace \
    "${expected_commit}" \
    "$(git -C "${fixture_root}" rev-parse 'v1.0.3^{commit}')"
if run_fixture_release >/dev/null 2>"${error_log_path}"; then
    fail_test 'a Git replace ref should fail the formal workflow'
fi
assert_contains \
    'Formal releases reject Git replace refs:' \
    "${error_log_path}" \
    'replace-ref rejection'
git -C "${fixture_root}" replace -d "${expected_commit}" >/dev/null

set +e
run_fixture_release >/dev/null 2>"${error_log_path}"
release_status="$?"
set -e
[[ "${release_status}" -eq 97 ]] \
    || fail_test "the injected archive failure returned ${release_status}, expected 97"
[[ -s "${gate_log_path}" ]] || fail_test 'the isolated release gate did not run'
[[ -s "${archive_log_path}" ]] || fail_test 'the isolated archive did not run'

IFS='|' read -r gate_root gate_commit gate_tree gate_artifacts \
    gate_no_replace gate_replace_base \
    <"${gate_log_path}"
IFS='|' read -r archive_root archive_commit archive_tree \
    archive_no_replace archive_replace_base \
    <"${archive_log_path}"
[[ "${gate_root}" == "${archive_root}" ]] \
    || fail_test \
        "release gate (${gate_root}) and archive (${archive_root}) did not use the same source snapshot"
[[ "${gate_root}" != "${fixture_root}" ]] \
    || fail_test 'formal release unexpectedly used the live worktree'
[[ "${gate_commit}" == "${expected_commit}" \
    && "${archive_commit}" == "${expected_commit}" ]] \
    || fail_test 'release gate or archive used the wrong HEAD'
[[ "${gate_tree}" == "${expected_tree}" \
    && "${archive_tree}" == "${expected_tree}" ]] \
    || fail_test 'release gate or archive used the wrong source tree'
[[ "${gate_no_replace}" == "1" \
    && "${archive_no_replace}" == "1" \
    && -z "${gate_replace_base}" \
    && -z "${archive_replace_base}" ]] \
    || fail_test 'Git object replacement was not disabled for gate and archive'
[[ "$(basename "${gate_artifacts}")" == "ReleaseGate" \
    && "$(basename "$(dirname "${gate_artifacts}")")" \
        == "$(basename "${gate_root%/source}")" ]] \
    || fail_test 'release gate artifacts escaped the private work directory'

IFS='|' read -r requirement_snapshot requirement_mode \
    <"${requirement_log_path}"
[[ "${requirement_snapshot}" != \
    "${fixture_root}/Config/Distribution.requirements" ]] \
    || fail_test 'provenance validation used the mutable live requirement'
[[ "$(basename "${requirement_snapshot}")" == "Distribution.requirements" \
    && "$(basename "$(dirname "${requirement_snapshot}")")" \
        == "$(basename "${gate_root%/source}")" ]] \
    || fail_test 'the requirement snapshot was outside the private work directory'
[[ "${requirement_mode}" == "400" ]] \
    || fail_test 'the requirement snapshot was not read-only'
[[ -f "${requirement_snapshot}" ]] \
    || fail_test 'the private requirement snapshot was not preserved after failure'

printf '%s\n' 'PASS: release workflow snapshot fault-injection tests'
