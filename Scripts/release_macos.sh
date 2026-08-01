#!/usr/bin/env bash

set -euo pipefail

readonly local_mode="local"
readonly distribution_mode="distribution"
readonly expected_product_name="Muralume"
readonly expected_bundle_identifier="com.muralume.Muralume"
readonly expected_architecture="arm64"
readonly expected_marketing_version="1.0.0"
readonly expected_build_number="2"
readonly dmg_volume_name="Muralume"
readonly dmg_background_file_name="background.png"
readonly dmg_background_width="660"
readonly dmg_background_height="412"
readonly launch_services_register_path="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly project_root="$(cd "${script_directory}/.." && pwd)"
readonly project_path="${project_root}/Muralume.xcodeproj"
readonly entitlements_path="${project_root}/Muralume/Resources/Muralume.entitlements"
readonly release_config_path="${project_root}/Config/Release.local.mk"
readonly dmg_background_renderer_path="${script_directory}/render_dmg_background.swift"
readonly dmg_layout_tool_path="${script_directory}/configure_dmg.py"
readonly secure_timestamp_helper_path="${script_directory}/lib/secure_timestamp.sh"

# shellcheck source=lib/secure_timestamp.sh
source "${secure_timestamp_helper_path}"

selected_mode=""
requested_output_path=""
signing_identity=""
notary_profile=""
mounted_dmg=0
mounted_device=""
work_directory=""
mount_directory=""
xcode_python_path=""

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

load_attached_image_state() {
    local attach_result_path="$1"
    local expected_mount_directory="$2"
    local canonical_expected_mount_directory
    local entity_index
    local candidate_device
    local candidate_mount_directory
    local canonical_candidate_mount_directory

    canonical_expected_mount_directory="$(
        cd "${expected_mount_directory}" && pwd -P
    )"

    mounted_device=""
    for entity_index in {0..15}; do
        candidate_device="$(
            plutil -extract \
                "system-entities.${entity_index}.dev-entry" \
                raw \
                "${attach_result_path}" 2>/dev/null || true
        )"
        [[ -n "${candidate_device}" ]] || continue

        candidate_mount_directory="$(
            plutil -extract \
                "system-entities.${entity_index}.mount-point" \
                raw \
                "${attach_result_path}" 2>/dev/null || true
        )"
        [[ -n "${candidate_mount_directory}" ]] || continue
        canonical_candidate_mount_directory="$(
            cd "${candidate_mount_directory}" 2>/dev/null && pwd -P || true
        )"
        [[ "${canonical_candidate_mount_directory}" \
            == "${canonical_expected_mount_directory}" ]] || continue

        mounted_device="${candidate_device}"
        mount_directory="${canonical_candidate_mount_directory}"
        return
    done

    fail "Unable to identify the DMG mounted at ${canonical_expected_mount_directory}."
}

detach_mounted_image() {
    local detach_target="${mounted_device:-${mount_directory}}"
    [[ -n "${detach_target}" ]] \
        || fail "Unable to identify the mounted DMG for detachment."

    hdiutil detach "${detach_target}" >/dev/null
    mounted_dmg=0
    mounted_device=""
    mount_directory=""
}

cleanup() {
    local status="$?"

    if [[ "${mounted_dmg}" -eq 1 ]]; then
        local detach_target="${mounted_device:-${mount_directory}}"
        if [[ -n "${detach_target}" ]]; then
            hdiutil detach "${detach_target}" >/dev/null 2>&1 || true
        fi
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
require_command diskutil
require_command ditto
require_command hdiutil
require_command lipo
require_command ln
require_command plutil
require_command shasum
require_command sips
require_command sync
require_command xcrun
require_command xcodebuild

xcode_python_path="$(xcrun --find python3 2>/dev/null || true)"
[[ -x "${xcode_python_path}" ]] \
    || fail "Xcode's Python 3 runtime is unavailable."
"${xcode_python_path}" -c \
    'import sys; raise SystemExit(0 if sys.version_info >= (3, 7) else 1)' \
    || fail "The DMG metadata generator requires Python 3.7 or newer."

if [[ "${selected_mode}" == "${distribution_mode}" ]]; then
    require_command rg
    require_command security
    require_command spctl
    require_command stat
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
readonly dmg_background_directory="${dmg_staging_directory}/.background"
readonly dmg_background_path="${dmg_background_directory}/${dmg_background_file_name}"
readonly writable_dmg_path="${work_directory}/Muralume-layout.dmg"
readonly temporary_dmg_path="${work_directory}/Muralume.dmg"
readonly layout_attach_result_path="${work_directory}/layout-attach.plist"
readonly verification_attach_result_path="${work_directory}/verification-attach.plist"
readonly layout_mount_directory="${work_directory}/layout-mount"
readonly verification_mount_directory="${work_directory}/verification-mount"
readonly signed_entitlements_path="${work_directory}/signed-entitlements.plist"
readonly notary_result_path="${work_directory}/notary-result.plist"
mount_directory=""

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

# Xcode registers every built macOS application with LaunchServices, including
# this disposable archive path. Remove only that exact record before the
# temporary archive disappears; installed copies with the same bundle ID stay
# registered independently.
if [[ -x "${launch_services_register_path}" ]] \
    && ! "${launch_services_register_path}" -u \
        "${archive_app_path}" >/dev/null 2>&1; then
    printf 'Warning: unable to unregister temporary archive from LaunchServices.\n' \
        >&2
fi

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
    sign_with_secure_timestamp \
        "${expected_product_name}.app" \
        "${staged_app_path}" \
        --force \
        --options runtime \
        --entitlements "${entitlements_path}" \
        --sign "${signing_identity}"
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
[[ "${marketing_version}" == "${expected_marketing_version}" ]] \
    || fail "Expected version ${expected_marketing_version}, found: ${marketing_version}"

build_number="$(
    plutil -extract CFBundleVersion raw \
        "${staged_app_path}/Contents/Info.plist"
)"
[[ "${build_number}" == "${expected_build_number}" ]] \
    || fail "Expected build ${expected_build_number}, found: ${build_number}"

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

app_icon_file_name="$(
    plutil -extract CFBundleIconFile raw \
        "${staged_app_path}/Contents/Info.plist"
)"
[[ -n "${app_icon_file_name}" ]] \
    || fail "The built app does not declare CFBundleIconFile."
if [[ "${app_icon_file_name}" != *.icns ]]; then
    app_icon_file_name="${app_icon_file_name}.icns"
fi
app_icon_path="${staged_app_path}/Contents/Resources/${app_icon_file_name}"
[[ -f "${app_icon_path}" ]] \
    || fail "The declared application icon is missing: ${app_icon_file_name}"
ditto "${app_icon_path}" "${dmg_staging_directory}/.VolumeIcon.icns"

printf 'Rendering the DMG background...\n'
xcrun swift "${dmg_background_renderer_path}" \
    --output "${dmg_background_path}"

actual_background_width="$(
    sips -g pixelWidth "${dmg_background_path}" 2>/dev/null \
        | awk '/pixelWidth:/ { print $2 }'
)"
actual_background_height="$(
    sips -g pixelHeight "${dmg_background_path}" 2>/dev/null \
        | awk '/pixelHeight:/ { print $2 }'
)"
[[ "${actual_background_width}" == "${dmg_background_width}" ]] \
    || fail "Unexpected DMG background width: ${actual_background_width}"
[[ "${actual_background_height}" == "${dmg_background_height}" ]] \
    || fail "Unexpected DMG background height: ${actual_background_height}"

printf 'Creating and arranging the DMG...\n'
hdiutil create \
    -format UDRW \
    -fs HFS+ \
    -volname "${dmg_volume_name}" \
    -srcfolder "${dmg_staging_directory}" \
    "${writable_dmg_path}"

mkdir -p "${layout_mount_directory}"
mount_directory="$(cd "${layout_mount_directory}" && pwd -P)"
hdiutil attach \
    -readwrite \
    -noautoopen \
    -nobrowse \
    -mountpoint "${mount_directory}" \
    -plist \
    "${writable_dmg_path}" >"${layout_attach_result_path}"
mounted_dmg=1
load_attached_image_state \
    "${layout_attach_result_path}" \
    "${layout_mount_directory}"

xcrun SetFile -a C "${mount_directory}"

"${xcode_python_path}" "${dmg_layout_tool_path}" configure \
    --mount-path "${mount_directory}" \
    --application-name "${expected_product_name}.app" \
    --background-file-name "${dmg_background_file_name}" \
    --volume-name "${dmg_volume_name}"

if [[ -d "${mount_directory}/.fseventsd" ]]; then
    rm -r "${mount_directory}/.fseventsd"
fi

sync
detach_mounted_image

hdiutil convert "${writable_dmg_path}" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "${temporary_dmg_path}" >/dev/null

if [[ "${selected_mode}" == "${distribution_mode}" ]]; then
    printf 'Signing and notarizing the DMG...\n'
    sign_with_secure_timestamp \
        "${expected_product_name}.dmg" \
        "${temporary_dmg_path}" \
        --force \
        --sign "${signing_identity}"
    codesign --verify --verbose=2 "${temporary_dmg_path}"

    dmg_signature_details="$(codesign --display --verbose=4 \
        "${temporary_dmg_path}" 2>&1)"
    printf '%s\n' "${dmg_signature_details}" \
        | rg '^Authority=Developer ID Application:' >/dev/null \
        || fail "The DMG is not signed by Developer ID Application."
    printf '%s\n' "${dmg_signature_details}" \
        | rg '^Timestamp=' >/dev/null \
        || fail "The DMG signature has no secure timestamp."
    printf '%s\n' "${dmg_signature_details}" \
        | rg '^TeamIdentifier=[A-Z0-9]+$' >/dev/null \
        || fail "The DMG signature has no valid TeamIdentifier."

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

mkdir -p "${verification_mount_directory}"
mount_directory="$(cd "${verification_mount_directory}" && pwd -P)"
hdiutil attach \
    -readonly \
    -noautoopen \
    -nobrowse \
    -mountpoint "${mount_directory}" \
    -plist \
    "${temporary_dmg_path}" >"${verification_attach_result_path}"
mounted_dmg=1
load_attached_image_state \
    "${verification_attach_result_path}" \
    "${verification_mount_directory}"

mounted_volume_name="$(
    diskutil info -plist "${mount_directory}" \
        | plutil -extract VolumeName raw -
)"
[[ "${mounted_volume_name}" == "${dmg_volume_name}" ]] \
    || fail "Unexpected DMG volume name: ${mounted_volume_name}"

readonly mounted_app_path="${mount_directory}/Muralume.app"
[[ -d "${mounted_app_path}" ]] \
    || fail "The DMG does not contain Muralume.app."
[[ -L "${mount_directory}/Applications" ]] \
    || fail "The DMG does not contain an Applications shortcut."
[[ "$(readlink "${mount_directory}/Applications")" == "/Applications" ]] \
    || fail "The Applications shortcut has an unexpected target."
[[ -f "${mount_directory}/.DS_Store" ]] \
    || fail "The DMG does not contain Finder layout metadata."
[[ -f "${mount_directory}/.background/${dmg_background_file_name}" ]] \
    || fail "The DMG does not contain its branded background."
[[ -f "${mount_directory}/.VolumeIcon.icns" ]] \
    || fail "The DMG does not contain its custom volume icon."
"${xcode_python_path}" "${dmg_layout_tool_path}" verify \
    --mount-path "${mount_directory}" \
    --application-name "${expected_product_name}.app" \
    --background-file-name "${dmg_background_file_name}" \
    --volume-name "${dmg_volume_name}"
mounted_volume_attributes="$(xcrun GetFileInfo -a "${mount_directory}")"
[[ "${mounted_volume_attributes}" == *C* ]] \
    || fail "The DMG volume is missing its custom icon flag."

visible_root_item_count="$(
    find "${mount_directory}" \
        -mindepth 1 \
        -maxdepth 1 \
        ! -name '.*' \
        -print \
        | wc -l \
        | tr -d '[:space:]'
)"
[[ "${visible_root_item_count}" == "2" ]] \
    || fail "The DMG root must expose exactly two visible items."

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

detach_mounted_image

mv -f "${temporary_dmg_path}" "${output_path}"

(
    cd "${output_directory}"
    shasum -a 256 "$(basename "${output_path}")" \
        >"$(basename "${checksum_path}")"
    shasum -a 256 -c "$(basename "${checksum_path}")"
)

printf 'DMG: %s\n' "${output_path}"
printf 'SHA-256: %s\n' "${checksum_path}"
