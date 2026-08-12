#!/usr/bin/env bash

set -euo pipefail

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly project_root="$(cd "${script_directory}/../.." && pwd)"

test_root="$(mktemp -d "${TMPDIR:-/tmp}/MuralumeRequirementPreparationTest.XXXXXX")"
cleanup() {
    rm -rf "${test_root}"
}
trap cleanup EXIT

readonly fixture_root="${test_root}/fixture"
readonly fake_bin="${test_root}/fake-bin"
readonly fixture_tmp="${test_root}/tmp"
readonly fake_state_root="${test_root}/fake-state"
readonly archive_extraction_marker="${test_root}/archive-requirement-was-read"
readonly archive_state_path="${fake_state_root}/archive-path"
readonly export_app_state_path="${fake_state_root}/export-app-path"
readonly archive_count_path="${fake_state_root}/archive-count"
readonly export_count_path="${fake_state_root}/export-count"
readonly fixture_bundle_identifier="com.muralume.Muralume"
readonly fixture_team_identifier="EXAMPLE123"
readonly fixture_identity_hash="1111111111111111111111111111111111111111"
readonly fixture_cdhash="CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
readonly repeated_fixture_cdhash="DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"
readonly replacement_fixture_cdhash="EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"

mkdir -p \
    "${fixture_root}/Config" \
    "${fixture_root}/Muralume.xcodeproj" \
    "${fixture_root}/Scripts/lib" \
    "${fake_bin}" \
    "${fixture_tmp}" \
    "${fake_state_root}"
cp "${project_root}/Scripts/prepare_distribution_requirements.sh" \
    "${fixture_root}/Scripts/prepare_distribution_requirements.sh"
cp "${project_root}/Scripts/lib/distribution_requirements.sh" \
    "${fixture_root}/Scripts/lib/distribution_requirements.sh"
cp "${project_root}/Scripts/lib/release_invocation.sh" \
    "${fixture_root}/Scripts/lib/release_invocation.sh"
cp "${project_root}/Scripts/lib/build_cache.sh" \
    "${fixture_root}/Scripts/lib/build_cache.sh"
cp "${project_root}/Scripts/lib/release_source_snapshot.sh" \
    "${fixture_root}/Scripts/lib/release_source_snapshot.sh"
chmod 755 "${fixture_root}/Scripts/prepare_distribution_requirements.sh"

printf '%s\n' \
    '/Config/Release.local.mk' \
    '/Config/Distribution.requirements' \
    '.build/' \
    '*.requirements' \
    >"${fixture_root}/.gitignore"
printf '%s\n' 'fixture project' >"${fixture_root}/README.md"
printf '%s\n' 'fixture Xcode project' \
    >"${fixture_root}/Muralume.xcodeproj/project.pbxproj"

git -C "${fixture_root}" init -q
git -C "${fixture_root}" add \
    .gitignore \
    README.md \
    Muralume.xcodeproj \
    Scripts
git -C "${fixture_root}" \
    -c user.name='Muralume Test' \
    -c user.email='muralume-test@example.invalid' \
    commit -q -m 'fixture v1.0.3 source'
git -C "${fixture_root}" tag v1.0.3
printf '%s\n' 'current bridge source' >"${fixture_root}/CURRENT"
git -C "${fixture_root}" add CURRENT
git -C "${fixture_root}" \
    -c user.name='Muralume Test' \
    -c user.email='muralume-test@example.invalid' \
    commit -q -m 'fixture bridge source'
readonly fixture_bridge_commit="$(git -C "${fixture_root}" rev-parse HEAD)"
readonly fixture_bridge_tree="$(git -C "${fixture_root}" rev-parse 'HEAD^{tree}')"

printf '%s\n' \
    'MURALUME_DEVELOPER_ID_APPLICATION := private' \
    'MURALUME_EXPECTED_TEAM_IDENTIFIER := private' \
    >"${fixture_root}/Config/Release.local.mk"
chmod 600 "${fixture_root}/Config/Release.local.mk"

cat >"${fake_bin}/security" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" != "find-identity -v -p codesigning" ]]; then
    exit 64
fi
printf '  1) %s "Developer ID Application: Fixture (%s)"\n' \
    "${FAKE_IDENTITY_HASH}" \
    "${FAKE_TEAM_ID}"
EOF

cat >"${fake_bin}/lipo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${FAKE_ARCHITECTURE:-arm64}"
EOF

cat >"${fake_bin}/xcodebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

increment_counter() {
    local counter_path="$1"
    local count=0

    if [[ -f "${counter_path}" ]]; then
        IFS= read -r count <"${counter_path}"
    fi
    printf '%s\n' "$((count + 1))" >"${counter_path}"
}

create_app() {
    local app_path="$1"
    local bundle_identifier="$2"
    local marketing_version="$3"
    local build_number="$4"

    mkdir -p "${app_path}/Contents/MacOS"
    printf '%s\n' '#!/bin/sh' 'exit 0' \
        >"${app_path}/Contents/MacOS/Muralume"
    chmod 755 "${app_path}/Contents/MacOS/Muralume"
    /usr/bin/plutil -create xml1 "${app_path}/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundleIdentifier -string \
        "${bundle_identifier}" "${app_path}/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundleShortVersionString -string \
        "${marketing_version}" "${app_path}/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundleVersion -string \
        "${build_number}" "${app_path}/Contents/Info.plist"
}

if [[ "$#" -eq 1 && "$1" == "-version" ]]; then
    printf '%s\n' 'Xcode 26.1.1' 'Build version 17B100'
    exit 0
fi

archive_path=""
configuration=""
derived_data_path=""
destination=""
export_path=""
export_options_path=""
xcconfig_path=""
project_path=""
scheme=""
previous_argument=""
is_export=0
saw_archive_action=0
for argument in "$@"; do
    case "${previous_argument}" in
        -archivePath)
            archive_path="${argument}"
            ;;
        -configuration)
            configuration="${argument}"
            ;;
        -derivedDataPath)
            derived_data_path="${argument}"
            ;;
        -destination)
            destination="${argument}"
            ;;
        -exportPath)
            export_path="${argument}"
            ;;
        -exportOptionsPlist)
            export_options_path="${argument}"
            ;;
        -xcconfig)
            xcconfig_path="${argument}"
            ;;
        -project)
            project_path="${argument}"
            ;;
        -scheme)
            scheme="${argument}"
            ;;
    esac
    [[ "${argument}" == "-exportArchive" ]] && is_export=1
    [[ "${argument}" == "archive" ]] && saw_archive_action=1
    previous_argument="${argument}"
done

if [[ "${is_export}" -eq 0 ]]; then
    [[ "${saw_archive_action}" -eq 1 ]]
    [[ -n "${archive_path}" && -n "${derived_data_path}" \
        && -n "${xcconfig_path}" ]]
    work_directory="${archive_path%/Muralume.xcarchive}"
    source_root="${work_directory}/Source"
    [[ "${archive_path}" == "${work_directory}/Muralume.xcarchive" ]]
    [[ "${work_directory}" == \
        "${FAKE_TMP_ROOT}"/MuralumeRequirementPreparation.* ]]
    [[ "${project_path}" == "${source_root}/Muralume.xcodeproj" ]]
    [[ -f "${project_path}/project.pbxproj" ]]
    [[ "${scheme}" == "Muralume" ]]
    [[ "${configuration}" == "Release" ]]
    [[ "${destination}" == "generic/platform=macOS" ]]
    [[ "${derived_data_path}" == \
        "${FAKE_FIXTURE_ROOT}"/.build/muralume/cache/release-requirements/*/DerivedData ]]
    [[ "${xcconfig_path}" == "${work_directory}/Archive.xcconfig" ]]
    [[ "$(git -C "${source_root}" rev-parse HEAD)" \
        == "${FAKE_EXPECTED_SOURCE_COMMIT}" ]]
    [[ "$(git -C "${source_root}" rev-parse 'HEAD^{tree}')" \
        == "${FAKE_EXPECTED_SOURCE_TREE}" ]]
    if git -C "${source_root}" symbolic-ref -q HEAD >/dev/null 2>&1; then
        exit 65
    fi
    /usr/bin/grep -Fx 'ARCHS = arm64' "${xcconfig_path}" >/dev/null
    /usr/bin/grep -Fx 'ONLY_ACTIVE_ARCH = NO' "${xcconfig_path}" >/dev/null
    /usr/bin/grep -Fx \
        "MURALUME_APP_BUNDLE_IDENTIFIER = ${FAKE_BUNDLE_ID}" \
        "${xcconfig_path}" >/dev/null
    /usr/bin/grep -F "PRODUCT_BUNDLE_IDENTIFIER = ${FAKE_BUNDLE_ID}" \
        "${xcconfig_path}" >/dev/null
    /usr/bin/grep -Fx 'CODE_SIGN_STYLE = Manual' \
        "${xcconfig_path}" >/dev/null
    /usr/bin/grep -F "CODE_SIGN_IDENTITY = ${FAKE_IDENTITY_HASH}" \
        "${xcconfig_path}" >/dev/null
    /usr/bin/grep -F "DEVELOPMENT_TEAM = ${FAKE_TEAM_ID}" \
        "${xcconfig_path}" >/dev/null
    /usr/bin/grep -Fx 'PROVISIONING_PROFILE_SPECIFIER =' \
        "${xcconfig_path}" >/dev/null
    /usr/bin/grep -Fx 'CODE_SIGNING_ALLOWED = YES' \
        "${xcconfig_path}" >/dev/null
    /usr/bin/grep -Fx 'CODE_SIGNING_REQUIRED = YES' \
        "${xcconfig_path}" >/dev/null
    /usr/bin/grep -Fx 'OTHER_CODE_SIGN_FLAGS =' \
        "${xcconfig_path}" >/dev/null
    /usr/bin/grep -Fx 'MARKETING_VERSION = 0.0.0' \
        "${xcconfig_path}" >/dev/null
    /usr/bin/grep -Fx 'CURRENT_PROJECT_VERSION = 1' \
        "${xcconfig_path}" >/dev/null
    increment_counter "${FAKE_ARCHIVE_COUNT_PATH}"
    [[ "${FAKE_ARCHIVE_FAIL:-0}" != "1" ]] || exit 31
    printf '%s\n' "${archive_path}" >"${FAKE_ARCHIVE_STATE_PATH}"
    create_app \
        "${archive_path}/Products/Applications/Muralume.app" \
        "${FAKE_BUNDLE_ID}" \
        '0.0.0' \
        '1'
    exit 0
fi

[[ -n "${archive_path}" && -n "${export_path}" \
    && -n "${export_options_path}" ]]
IFS= read -r recorded_archive_path <"${FAKE_ARCHIVE_STATE_PATH}"
[[ "${archive_path}" == "${recorded_archive_path}" ]]
work_directory="${archive_path%/Muralume.xcarchive}"
[[ "${export_path}" == "${work_directory}/DeveloperIDExport" ]]
[[ "${export_options_path}" == "${work_directory}/ExportOptions.plist" ]]
[[ -d "${archive_path}/Products/Applications/Muralume.app" ]]
[[ "$(/usr/bin/plutil -extract method raw "${export_options_path}")" \
    == "developer-id" ]]
[[ "$(/usr/bin/plutil -extract destination raw "${export_options_path}")" \
    == "export" ]]
[[ "$(/usr/bin/plutil -extract signingStyle raw "${export_options_path}")" \
    == "manual" ]]
[[ "$(/usr/bin/plutil -extract signingCertificate raw "${export_options_path}")" \
    == "${FAKE_IDENTITY_HASH}" ]]
[[ "$(/usr/bin/plutil -extract teamID raw "${export_options_path}")" \
    == "${FAKE_TEAM_ID}" ]]
[[ "$(/usr/bin/plutil -extract distributionBundleIdentifier raw \
    "${export_options_path}")" == "${FAKE_BUNDLE_ID}" ]]
increment_counter "${FAKE_EXPORT_COUNT_PATH}"
[[ "${FAKE_EXPORT_FAIL:-0}" != "1" ]] || exit 32
printf '%s\n' "${export_path}/Muralume.app" \
    >"${FAKE_EXPORT_APP_STATE_PATH}"

case "${FAKE_EXPORT_MODE:-valid}" in
    missing)
        mkdir -p "${export_path}"
        exit 0
        ;;
    local)
        exported_bundle_identifier="${FAKE_BUNDLE_ID}.local"
        exported_marketing_version='0.0.0'
        ;;
    debug)
        exported_bundle_identifier="${FAKE_BUNDLE_ID}.debug"
        exported_marketing_version='0.0.0'
        ;;
    v103)
        exported_bundle_identifier="${FAKE_BUNDLE_ID}"
        exported_marketing_version='1.0.3'
        ;;
    *)
        exported_bundle_identifier="${FAKE_BUNDLE_ID}"
        exported_marketing_version='0.0.0'
        ;;
esac
create_app \
    "${export_path}/Muralume.app" \
    "${exported_bundle_identifier}" \
    "${exported_marketing_version}" \
    '1'
if [[ "${FAKE_EXPORT_MODE:-valid}" == "ambiguous" ]]; then
    create_app \
        "${export_path}/Other.app" \
        "com.muralume.Other" \
        '0.0.0' \
        '1'
fi
EOF

cat >"${fake_bin}/codesign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

is_requirement_display=0
is_entitlements_display=0
is_verbose_display=0
is_verify=0
last_argument=""
for argument in "$@"; do
    [[ "${argument}" == "-r-" ]] && is_requirement_display=1
    [[ "${argument}" == "--entitlements" ]] && is_entitlements_display=1
    [[ "${argument}" == "--verbose=4" ]] && is_verbose_display=1
    [[ "${argument}" == "--verify" ]] && is_verify=1
    last_argument="${argument}"
done

IFS= read -r expected_exported_app <"${FAKE_EXPORT_APP_STATE_PATH}"
IFS= read -r recorded_archive_path <"${FAKE_ARCHIVE_STATE_PATH}"
recorded_archive_app="${recorded_archive_path}/Products/Applications/Muralume.app"

if [[ "${is_requirement_display}" -eq 1 ]]; then
    if [[ "${last_argument}" == "${recorded_archive_app}" ]]; then
        : >"${FAKE_ARCHIVE_EXTRACTION_MARKER}"
        exit 71
    fi
    [[ "${last_argument}" == "${expected_exported_app}" ]] || exit 72
    printf 'designated => anchor apple generic and identifier "%s" and (certificate leaf[field.1.2.840.113635.100.6.1.9] exists or certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "%s")\n' \
        "${FAKE_BUNDLE_ID}" \
        "${FAKE_TEAM_ID}"
    exit 0
fi

[[ "${last_argument}" == "${expected_exported_app}" ]] || exit 72

if [[ "${is_entitlements_display}" -eq 1 ]]; then
    if [[ "${FAKE_ENTITLEMENTS_MODE:-valid}" == "missing-bookmark" ]]; then
        bookmark_entry=""
    else
        bookmark_entry='<key>com.apple.security.files.bookmarks.app-scope</key><true/>'
    fi
    printf '%s\n' \
        '<?xml version="1.0" encoding="UTF-8"?>' \
        '<plist version="1.0"><dict>' \
        '<key>com.apple.security.app-sandbox</key><true/>' \
        '<key>com.apple.security.files.user-selected.read-only</key><true/>' \
        "${bookmark_entry}" \
        '</dict></plist>'
    exit 0
fi

if [[ "${is_verbose_display}" -eq 1 ]]; then
    bundle_identifier="$(
        /usr/bin/plutil -extract CFBundleIdentifier raw \
            "${last_argument}/Contents/Info.plist"
    )"
    signature_team="${FAKE_SIGNATURE_TEAM:-${FAKE_TEAM_ID}}"
    printf 'Executable=%s\n' "${last_argument}/Contents/MacOS/Muralume"
    printf 'Identifier=%s\n' "${bundle_identifier}"
    if [[ "${FAKE_AUTHORITY_MODE:-developer-id}" == "developer-id" ]]; then
        printf 'Authority=Developer ID Application: Fixture (%s)\n' \
            "${signature_team}"
    else
        printf 'Authority=Apple Development: Fixture (%s)\n' \
            "${signature_team}"
    fi
    printf 'Authority=Developer ID Certification Authority\n'
    printf 'Authority=Apple Root CA\n'
    if [[ "${FAKE_TIMESTAMP_MODE:-present}" == "present" ]]; then
        printf 'Timestamp=Aug 9, 2026 at 12:00:00\n'
    fi
    printf 'TeamIdentifier=%s\n' "${signature_team}"
    if [[ "${FAKE_RUNTIME_MODE:-present}" == "present" ]]; then
        printf 'flags=0x10000(runtime)\n'
    else
        printf 'flags=0x0(none)\n'
    fi
    printf 'CDHash=%s\n' "${FAKE_CDHASH}"
    exit 0
fi

if [[ "${is_verify}" -eq 1 ]]; then
    [[ "${FAKE_CODESIGN_VERIFY_FAIL:-0}" != "1" ]] || exit 73
    exit 0
fi

exit 64
EOF

chmod 755 \
    "${fake_bin}/security" \
    "${fake_bin}/lipo" \
    "${fake_bin}/xcodebuild" \
    "${fake_bin}/codesign"

fixture_identity_name="Developer ID Application: Fixture ("
fixture_identity_name+="${fixture_team_identifier})"
export PATH="${fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin"
export TMPDIR="${fixture_tmp}"
export MURALUME_DEVELOPER_ID_APPLICATION="${fixture_identity_name}"
export MURALUME_EXPECTED_TEAM_IDENTIFIER="${fixture_team_identifier}"
export FAKE_BUNDLE_ID="${fixture_bundle_identifier}"
export FAKE_TEAM_ID="${fixture_team_identifier}"
export FAKE_IDENTITY_HASH="${fixture_identity_hash}"
export FAKE_CDHASH="${fixture_cdhash}"
export FAKE_ARCHIVE_EXTRACTION_MARKER="${archive_extraction_marker}"
export FAKE_ARCHIVE_STATE_PATH="${archive_state_path}"
export FAKE_EXPORT_APP_STATE_PATH="${export_app_state_path}"
export FAKE_ARCHIVE_COUNT_PATH="${archive_count_path}"
export FAKE_EXPORT_COUNT_PATH="${export_count_path}"
export FAKE_TMP_ROOT="${fixture_tmp}"
export FAKE_FIXTURE_ROOT="${fixture_root}"
export FAKE_EXPECTED_SOURCE_COMMIT="${fixture_bridge_commit}"
export FAKE_EXPECTED_SOURCE_TREE="${fixture_bridge_tree}"

readonly preparation_script="${fixture_root}/Scripts/prepare_distribution_requirements.sh"
readonly fixture_requirement_path="${fixture_root}/Config/Distribution.requirements"
readonly command_log="${test_root}/command.log"
readonly requirement_backup_path="${test_root}/Distribution.requirements.backup"

counter_value() {
    local counter_path="$1"
    local count=0

    if [[ -f "${counter_path}" ]]; then
        IFS= read -r count <"${counter_path}"
    fi
    printf '%s\n' "${count}"
}

assert_workflow_counts() {
    local expected_archive_count="$1"
    local expected_export_count="$2"
    local description="$3"
    local actual_archive_count
    local actual_export_count

    actual_archive_count="$(counter_value "${archive_count_path}")"
    actual_export_count="$(counter_value "${export_count_path}")"
    if [[ "${actual_archive_count}" != "${expected_archive_count}" \
        || "${actual_export_count}" != "${expected_export_count}" ]]; then
        printf 'Unexpected archive/export counts after %s: %s/%s, expected %s/%s.\n' \
            "${description}" \
            "${actual_archive_count}" \
            "${actual_export_count}" \
            "${expected_archive_count}" \
            "${expected_export_count}" >&2
        exit 1
    fi
}

assert_requirement_unchanged() {
    local description="$1"
    local current_metadata

    if [[ ! -f "${fixture_requirement_path}" \
        || -L "${fixture_requirement_path}" ]] \
        || ! cmp -s "${requirement_backup_path}" \
            "${fixture_requirement_path}"; then
        printf 'Requirement content or file type changed after %s.\n' \
            "${description}" >&2
        exit 1
    fi
    current_metadata="$(
        stat -f '%d:%i:%Lp:%HT' "${fixture_requirement_path}"
    )"
    if [[ "${current_metadata}" != "${original_requirement_metadata}" ]]; then
        printf 'Requirement device/inode/mode/type changed after %s.\n' \
            "${description}" >&2
        exit 1
    fi
}

assert_failed_preparation_preserves_requirement() {
    local description="$1"
    local expected_error="$2"
    local expected_archive_delta="$3"
    local expected_export_delta="$4"
    local before_archive_count
    local before_export_count
    local expected_archive_count
    local expected_export_count
    shift 4

    before_archive_count="$(counter_value "${archive_count_path}")"
    before_export_count="$(counter_value "${export_count_path}")"
    expected_archive_count=$((before_archive_count + expected_archive_delta))
    expected_export_count=$((before_export_count + expected_export_delta))

    if env "$@" "${preparation_script}" --replace \
        >"${command_log}" 2>&1; then
        printf 'Expected %s to fail.\n' "${description}" >&2
        exit 1
    fi
    if ! grep -F "${expected_error}" "${command_log}" >/dev/null; then
        printf 'Failure did not reach the expected stage for %s.\n' \
            "${description}" >&2
        exit 1
    fi
    assert_workflow_counts \
        "${expected_archive_count}" \
        "${expected_export_count}" \
        "${description}"
    assert_requirement_unchanged "${description}"
    if find "${fixture_tmp}" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -name 'MuralumeRequirementPreparation.*' \
        -print \
        -quit | grep . >/dev/null; then
        printf 'A failed preparation work directory leaked after %s.\n' \
            "${description}" >&2
        exit 1
    fi
}

if "${preparation_script}" --app "${fixture_root}/Muralume.app" \
    >"${command_log}" 2>&1; then
    echo "Expected an arbitrary App source argument to be rejected." >&2
    exit 1
fi
if "${preparation_script}" --check >"${command_log}" 2>&1; then
    echo "Expected a missing private requirement to fail the early check." >&2
    exit 1
fi

"${preparation_script}" >"${command_log}" 2>&1
if grep -F 'readonly variable' "${command_log}" >/dev/null; then
    echo "Expected preparation helpers not to shadow readonly workflow constants." >&2
    exit 1
fi
[[ -f "${fixture_requirement_path}" && ! -L "${fixture_requirement_path}" ]]
[[ "$(stat -f '%Lp' "${fixture_requirement_path}")" == "600" ]]
[[ ! -e "${archive_extraction_marker}" ]]
grep -F '# muralume-source-kind: xcode-developer-id-export' \
    "${fixture_requirement_path}" >/dev/null

# shellcheck source=../lib/distribution_requirements.sh
source "${project_root}/Scripts/lib/distribution_requirements.sh"
fixture_v1_0_3_commit="$(
    git -C "${fixture_root}" rev-parse 'v1.0.3^{commit}'
)"
validate_distribution_requirement_provenance \
    "${fixture_requirement_path}" \
    "${fixture_bundle_identifier}" \
    "${fixture_team_identifier}" \
    "${fixture_root}" \
    "${fixture_v1_0_3_commit}"
"${preparation_script}" --check >"${command_log}" 2>&1

assert_workflow_counts 1 1 'initial preparation'
cp -p "${fixture_requirement_path}" "${requirement_backup_path}"
readonly original_requirement_metadata="$(
    stat -f '%d:%i:%Lp:%HT' "${fixture_requirement_path}"
)"

env FAKE_CDHASH="${repeated_fixture_cdhash}" \
    "${preparation_script}" >"${command_log}" 2>&1
assert_workflow_counts 2 2 'equivalent repeated preparation'
assert_requirement_unchanged 'equivalent repeated preparation'

env FAKE_CDHASH="${replacement_fixture_cdhash}" \
    "${preparation_script}" --replace >"${command_log}" 2>&1
assert_workflow_counts 3 3 'successful no-fault --replace control'
assert_requirement_unchanged 'successful no-fault --replace control'

git -C "${fixture_root}" checkout -q --detach v1.0.3
assert_failed_preparation_preserves_requirement \
    'the checked-out v1.0.3 source' \
    'The v1.0.3 release source or source tree cannot prepare the bridge requirement.' \
    0 \
    0
git -C "${fixture_root}" checkout -q --detach "${fixture_bridge_commit}"
"${preparation_script}" --check >"${command_log}" 2>&1

assert_failed_preparation_preserves_requirement \
    'a local bundle export' \
    'The Xcode Developer ID export failed identity validation.' \
    1 \
    1 \
    FAKE_EXPORT_MODE=local
assert_failed_preparation_preserves_requirement \
    'a Debug bundle export' \
    'The Xcode Developer ID export failed identity validation.' \
    1 \
    1 \
    FAKE_EXPORT_MODE=debug
assert_failed_preparation_preserves_requirement \
    'a v1.0.3 export' \
    'The Xcode Developer ID export failed identity validation.' \
    1 \
    1 \
    FAKE_EXPORT_MODE=v103
assert_failed_preparation_preserves_requirement \
    'an export with no App' \
    'The Developer ID export must contain exactly one top-level Muralume.app.' \
    1 \
    1 \
    FAKE_EXPORT_MODE=missing
assert_failed_preparation_preserves_requirement \
    'an ambiguous export directory' \
    'The Developer ID export must contain exactly one top-level Muralume.app.' \
    1 \
    1 \
    FAKE_EXPORT_MODE=ambiguous
assert_failed_preparation_preserves_requirement \
    'an export without a secure timestamp' \
    'The Xcode Developer ID export failed identity validation.' \
    1 \
    1 \
    FAKE_TIMESTAMP_MODE=missing
assert_failed_preparation_preserves_requirement \
    'an Apple Development export' \
    'The Xcode Developer ID export failed identity validation.' \
    1 \
    1 \
    FAKE_AUTHORITY_MODE=apple-development
assert_failed_preparation_preserves_requirement \
    'an export from another Team' \
    'The Xcode Developer ID export failed identity validation.' \
    1 \
    1 \
    FAKE_SIGNATURE_TEAM=REPLACE123
assert_failed_preparation_preserves_requirement \
    'an export without Hardened Runtime' \
    'The Xcode Developer ID export failed identity validation.' \
    1 \
    1 \
    FAKE_RUNTIME_MODE=missing
assert_failed_preparation_preserves_requirement \
    'an export with the wrong architecture' \
    'The Xcode Developer ID export failed identity validation.' \
    1 \
    1 \
    FAKE_ARCHITECTURE=x86_64
assert_failed_preparation_preserves_requirement \
    'an export missing bookmark entitlement' \
    'The Xcode Developer ID export failed identity validation.' \
    1 \
    1 \
    FAKE_ENTITLEMENTS_MODE=missing-bookmark
assert_failed_preparation_preserves_requirement \
    'a failed codesign verification' \
    'The Xcode Developer ID export failed identity validation.' \
    1 \
    1 \
    FAKE_CODESIGN_VERIFY_FAIL=1
assert_failed_preparation_preserves_requirement \
    'a failed Xcode archive' \
    'Xcode archive failed.' \
    1 \
    0 \
    FAKE_ARCHIVE_FAIL=1
assert_failed_preparation_preserves_requirement \
    'a failed xcodebuild export' \
    'Xcode Developer ID export failed.' \
    1 \
    1 \
    FAKE_EXPORT_FAIL=1

readonly diagnostics_root="${fixture_root}/.build/muralume/diagnostics/prepare-distribution-requirements"
diagnostic_bundle_count="$(
    find "${diagnostics_root}" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -name 'failure-*' \
        -print | wc -l | tr -d '[:space:]'
)"
[[ "${diagnostic_bundle_count}" -le 5 ]] \
    || {
        echo 'Requirement preparation retained more than five diagnostic bundles.' >&2
        exit 1
    }
while IFS= read -r -d '' diagnostic_bundle; do
    [[ "$(stat -f '%Lp' "${diagnostic_bundle}")" == "700" ]] \
        || {
            echo 'A requirement diagnostic bundle was not mode 0700.' >&2
            exit 1
        }
    while IFS= read -r -d '' diagnostic_log; do
        [[ "$(stat -f '%Lp' "${diagnostic_log}")" == "600" ]] \
            || {
                echo 'A requirement diagnostic log was not mode 0600.' >&2
                exit 1
            }
    done < <(find "${diagnostic_bundle}" -type f -name '*.log' -print0)
done < <(
    find "${diagnostics_root}" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -name 'failure-*' \
        -print0
)

before_preserved_archive_count="$(counter_value "${archive_count_path}")"
before_preserved_export_count="$(counter_value "${export_count_path}")"
set +e
env MURALUME_KEEP_FAILED_WORKDIR=1 FAKE_ARCHIVE_FAIL=1 \
    "${preparation_script}" --replace >"${command_log}" 2>&1
preserved_preparation_status="$?"
set -e
[[ "${preserved_preparation_status}" -ne 0 ]] \
    || {
        echo 'Expected the opt-in preserved preparation to fail.' >&2
        exit 1
    }
assert_workflow_counts \
    "$((before_preserved_archive_count + 1))" \
    "${before_preserved_export_count}" \
    'opt-in preserved preparation'
assert_requirement_unchanged 'opt-in preserved preparation'
preserved_work_directory="$(
    sed -n \
        's/^Private requirement preparation work directory preserved: //p' \
        "${command_log}" | tail -n 1
)"
[[ -d "${preserved_work_directory}" ]] \
    || {
        echo 'MURALUME_KEEP_FAILED_WORKDIR=1 did not preserve the requirement work directory.' >&2
        exit 1
    }
[[ -d "${preserved_work_directory}/Source" \
    && -f "${preserved_work_directory}/archive.log" ]] \
    || {
        echo 'The opt-in requirement work directory was not a complete failure scene.' >&2
        exit 1
    }
git -C "${fixture_root}" worktree remove --force \
    "${preserved_work_directory}/Source" >/dev/null
rm -rf "${preserved_work_directory}"

[[ ! -e "${archive_extraction_marker}" ]]
echo "Distribution requirement preparation fault-injection checks passed."
