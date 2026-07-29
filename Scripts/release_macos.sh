#!/usr/bin/env bash

set -euo pipefail

readonly local_mode="local"
readonly distribution_mode="distribution"
readonly expected_product_name="Muralume"
readonly expected_bundle_identifier="com.muralume.Muralume"
readonly expected_architecture="arm64"

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly project_root="$(cd "${script_directory}/.." && pwd)"
readonly project_path="${project_root}/Muralume.xcodeproj"
readonly entitlements_path="${project_root}/Muralume/Resources/Muralume.entitlements"
readonly release_config_path="${project_root}/Config/Release.local.mk"

selected_mode=""
requested_output_path=""
signing_identity=""
notary_profile=""
mounted_dmg=0
work_directory=""
mount_directory=""

print_usage() {
    cat <<'EOF'
Usage:
  ./Scripts/release_macos.sh --mode local --output <path>
  ./Scripts/release_macos.sh --mode distribution --output <path> \
      --signing-identity <identity-or-sha1> \
      --notary-profile <keychain-profile>

Modes:
  local         Produce an ad-hoc signed DMG for this Mac only.
  distribution  Produce a Developer ID signed and notarized DMG.
EOF
}

fail() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

require_command() {
    local command_name="$1"
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        fail "Required command is unavailable: ${command_name}"
    fi
}

cleanup() {
    local status="$?"

    if [[ "${mounted_dmg}" -eq 1 && -n "${mount_directory}" ]]; then
        hdiutil detach "${mount_directory}" >/dev/null 2>&1 || true
    fi

    if [[ "${status}" -eq 0 && -n "${work_directory}" ]]; then
        rm -rf "${work_directory}"
    elif [[ -n "${work_directory}" ]]; then
        printf 'Release work directory preserved: %s\n' \
            "${work_directory}" >&2
    fi
}
trap cleanup EXIT

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --mode)
            [[ "$#" -ge 2 ]] || fail "--mode requires a value."
            selected_mode="$2"
            shift 2
            ;;
        --output)
            [[ "$#" -ge 2 ]] || fail "--output requires a value."
            requested_output_path="$2"
            shift 2
            ;;
        --signing-identity)
            [[ "$#" -ge 2 ]] || fail "--signing-identity requires a value."
            signing_identity="$2"
            shift 2
            ;;
        --notary-profile)
            [[ "$#" -ge 2 ]] || fail "--notary-profile requires a value."
            notary_profile="$2"
            shift 2
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            fail "Unknown argument: $1"
            ;;
    esac
done

case "${selected_mode}" in
    "${local_mode}"|"${distribution_mode}")
        ;;
    *)
        fail "--mode must be either local or distribution."
        ;;
esac

[[ -n "${requested_output_path}" ]] || fail "--output is required."
[[ "${requested_output_path}" == *.dmg ]] \
    || fail "--output must use the .dmg extension."

require_command codesign
require_command ditto
require_command hdiutil
require_command lipo
require_command ln
require_command plutil
require_command shasum
require_command xcodebuild

if [[ "${selected_mode}" == "${distribution_mode}" ]]; then
    require_command rg
    require_command security
    require_command spctl
    require_command stat
    require_command xcrun

    [[ -n "${signing_identity}" ]] \
        || fail "A Developer ID Application identity is required."
    [[ -n "${notary_profile}" ]] \
        || fail "A notarytool Keychain profile is required."

    available_identities="$(security find-identity -v -p codesigning)"
    matching_identity_lines="$(
        printf '%s\n' "${available_identities}" \
            | rg -F -- "${signing_identity}" || true
    )"
    if [[ -z "${matching_identity_lines}" ]]; then
        fail "The configured Developer ID Application identity is unavailable."
    fi
    matching_identity_count="$(
        printf '%s\n' "${matching_identity_lines}" \
            | wc -l \
            | tr -d '[:space:]'
    )"
    [[ "${matching_identity_count}" == "1" ]] \
        || fail "The configured signing identity must match exactly one certificate."
    printf '%s\n' "${matching_identity_lines}" \
        | rg '"Developer ID Application:' >/dev/null \
        || fail "The configured identity is not Developer ID Application."

    if [[ -f "${release_config_path}" ]]; then
        config_permissions="$(stat -f '%Lp' "${release_config_path}")"
        [[ "${config_permissions}" == "600" ]] \
            || fail "Config/Release.local.mk must have permissions 0600."
    fi

    xcrun notarytool history \
        --keychain-profile "${notary_profile}" >/dev/null
fi

mkdir -p "$(dirname "${requested_output_path}")"
readonly output_directory="$(cd "$(dirname "${requested_output_path}")" && pwd)"
readonly output_path="${output_directory}/$(basename "${requested_output_path}")"
readonly checksum_path="${output_path}.sha256"

work_directory="$(mktemp -d "${TMPDIR:-/tmp}/MuralumeRelease.XXXXXX")"
readonly archive_path="${work_directory}/Muralume.xcarchive"
readonly derived_data_path="${work_directory}/DerivedData"
readonly archive_app_path="${archive_path}/Products/Applications/Muralume.app"
readonly dmg_staging_directory="${work_directory}/dmg-root"
readonly staged_app_path="${dmg_staging_directory}/Muralume.app"
readonly temporary_dmg_path="${work_directory}/Muralume.dmg"
readonly signed_entitlements_path="${work_directory}/signed-entitlements.plist"
readonly notary_result_path="${work_directory}/notary-result.plist"
mount_directory="${work_directory}/mounted-dmg"

printf 'Archiving the arm64 Release app...\n'
xcodebuild archive \
    -project "${project_path}" \
    -scheme "${expected_product_name}" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "${archive_path}" \
    -derivedDataPath "${derived_data_path}" \
    ARCHS="${expected_architecture}" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO

[[ -d "${archive_app_path}" ]] \
    || fail "The archive did not contain ${expected_product_name}.app."

mkdir -p "${dmg_staging_directory}"
ditto "${archive_app_path}" "${staged_app_path}"

for nested_code_directory in \
    "${staged_app_path}/Contents/Frameworks" \
    "${staged_app_path}/Contents/PlugIns" \
    "${staged_app_path}/Contents/XPCServices"; do
    if [[ -d "${nested_code_directory}" ]] \
        && [[ -n "$(find "${nested_code_directory}" -mindepth 1 -print -quit)" ]]; then
        fail "Nested code was added; define its entitlements and inside-out signing order."
    fi
done

if [[ "${selected_mode}" == "${distribution_mode}" ]]; then
    printf 'Signing the app with Developer ID...\n'
    codesign \
        --force \
        --options runtime \
        --timestamp \
        --entitlements "${entitlements_path}" \
        --sign "${signing_identity}" \
        "${staged_app_path}"
else
    printf 'Applying an ad-hoc signature for local installation...\n'
    codesign \
        --force \
        --options runtime \
        --entitlements "${entitlements_path}" \
        --sign - \
        "${staged_app_path}"
fi

codesign --verify --deep --strict --verbose=2 "${staged_app_path}"

readonly executable_path="${staged_app_path}/Contents/MacOS/${expected_product_name}"
[[ -f "${executable_path}" ]] \
    || fail "The app executable is missing."

actual_architectures="$(lipo -archs "${executable_path}")"
[[ "${actual_architectures}" == "${expected_architecture}" ]] \
    || fail "Expected arm64 only, found: ${actual_architectures}"

actual_bundle_identifier="$(
    plutil -extract CFBundleIdentifier raw \
        "${staged_app_path}/Contents/Info.plist"
)"
[[ "${actual_bundle_identifier}" == "${expected_bundle_identifier}" ]] \
    || fail "Unexpected bundle identifier: ${actual_bundle_identifier}"

marketing_version="$(
    plutil -extract CFBundleShortVersionString raw \
        "${staged_app_path}/Contents/Info.plist"
)"
[[ -n "${marketing_version}" ]] \
    || fail "The app version is missing."

codesign --display --entitlements :- "${staged_app_path}" \
    >"${signed_entitlements_path}" 2>/dev/null
plutil -lint "${signed_entitlements_path}" >/dev/null

sandbox_enabled="$(
    plutil -extract 'com\.apple\.security\.app-sandbox' raw -o - \
        "${signed_entitlements_path}"
)"
[[ "${sandbox_enabled}" == "true" ]] \
    || fail "The release signature must enable App Sandbox."

read_only_folder_access="$(
    plutil -extract 'com\.apple\.security\.files\.user-selected\.read-only' raw -o - \
        "${signed_entitlements_path}"
)"
[[ "${read_only_folder_access}" == "true" ]] \
    || fail "The release signature must allow read-only user-selected folders."

app_scoped_bookmarks="$(
    plutil -extract 'com\.apple\.security\.files\.bookmarks\.app-scope' raw -o - \
        "${signed_entitlements_path}"
)"
[[ "${app_scoped_bookmarks}" == "true" ]] \
    || fail "The release signature must enable app-scoped bookmarks."

if plutil -extract 'com\.apple\.security\.get-task-allow' raw -o - \
    "${signed_entitlements_path}" >/dev/null 2>&1; then
    fail "Release entitlements must not contain get-task-allow."
fi

if [[ "${selected_mode}" == "${distribution_mode}" ]]; then
    signature_details="$(codesign --display --verbose=4 \
        "${staged_app_path}" 2>&1)"
    printf '%s\n' "${signature_details}" \
        | rg '^Authority=Developer ID Application:' >/dev/null \
        || fail "The app is not signed by Developer ID Application."
    printf '%s\n' "${signature_details}" \
        | rg '^Timestamp=' >/dev/null \
        || fail "The app signature has no secure timestamp."
    printf '%s\n' "${signature_details}" \
        | rg '^TeamIdentifier=[A-Z0-9]+$' >/dev/null \
        || fail "The app signature has no valid TeamIdentifier."
fi

ln -s /Applications "${dmg_staging_directory}/Applications"

printf 'Creating the DMG...\n'
hdiutil create \
    -format UDZO \
    -fs HFS+ \
    -imagekey zlib-level=9 \
    -volname "${expected_product_name} ${marketing_version}" \
    -srcfolder "${dmg_staging_directory}" \
    "${temporary_dmg_path}"

if [[ "${selected_mode}" == "${distribution_mode}" ]]; then
    printf 'Signing and notarizing the DMG...\n'
    codesign \
        --force \
        --timestamp \
        --sign "${signing_identity}" \
        "${temporary_dmg_path}"
    codesign --verify --verbose=2 "${temporary_dmg_path}"

    xcrun notarytool submit "${temporary_dmg_path}" \
        --keychain-profile "${notary_profile}" \
        --wait \
        --output-format plist >"${notary_result_path}"

    notary_status="$(plutil -extract status raw "${notary_result_path}")"
    [[ "${notary_status}" == "Accepted" ]] \
        || fail "Apple notarization status was ${notary_status}."

    xcrun stapler staple "${temporary_dmg_path}"
    xcrun stapler validate "${temporary_dmg_path}"
    codesign --verify --verbose=2 "${temporary_dmg_path}"
fi

hdiutil verify "${temporary_dmg_path}"

mkdir -p "${mount_directory}"
hdiutil attach \
    -readonly \
    -nobrowse \
    -mountpoint "${mount_directory}" \
    "${temporary_dmg_path}" >/dev/null
mounted_dmg=1

readonly mounted_app_path="${mount_directory}/Muralume.app"
[[ -d "${mounted_app_path}" ]] \
    || fail "The DMG does not contain Muralume.app."
[[ -L "${mount_directory}/Applications" ]] \
    || fail "The DMG does not contain an Applications shortcut."
[[ "$(readlink "${mount_directory}/Applications")" == "/Applications" ]] \
    || fail "The Applications shortcut has an unexpected target."

codesign --verify --deep --strict --verbose=2 "${mounted_app_path}"

if [[ "${selected_mode}" == "${distribution_mode}" ]]; then
    spctl --assess \
        --type open \
        --context context:primary-signature \
        --verbose=4 \
        "${temporary_dmg_path}"
    spctl --assess \
        --type execute \
        --verbose=4 \
        "${mounted_app_path}"
fi

hdiutil detach "${mount_directory}" >/dev/null
mounted_dmg=0

mv -f "${temporary_dmg_path}" "${output_path}"

(
    cd "${output_directory}"
    shasum -a 256 "$(basename "${output_path}")" \
        >"$(basename "${checksum_path}")"
    shasum -a 256 -c "$(basename "${checksum_path}")"
)

printf 'DMG: %s\n' "${output_path}"
printf 'SHA-256: %s\n' "${checksum_path}"
