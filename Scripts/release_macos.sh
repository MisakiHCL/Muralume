#!/usr/bin/env bash

set -euo pipefail

readonly local_mode="local"
readonly distribution_mode="distribution"
readonly expected_product_name="Muralume"
readonly production_bundle_identifier="com.muralume.Muralume"
readonly local_bundle_identifier="com.muralume.Muralume.local"
readonly expected_architecture="arm64"
readonly dmg_volume_name="Muralume"
readonly dmg_background_file_name="background.png"
readonly dmg_background_width="660"
readonly dmg_background_height="412"
readonly failed_diagnostic_bundle_limit="5"
readonly failed_diagnostic_log_byte_limit="2097152"
readonly launch_services_register_path="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly project_root="$(cd "${script_directory}/.." && pwd)"
readonly release_config_path="${project_root}/Config/Release.local.mk"
readonly distribution_requirements_path="${project_root}/Config/Distribution.requirements"
readonly distribution_requirements_helper_path="${script_directory}/lib/distribution_requirements.sh"
readonly build_cache_helper_path="${script_directory}/lib/build_cache.sh"
readonly release_output_transaction_helper_path="${script_directory}/lib/release_output_transaction.sh"
readonly release_signature_validation_helper_path="${script_directory}/lib/release_signature_validation.sh"
readonly release_gate_receipt_helper_path="${script_directory}/lib/release_gate_receipt.sh"
readonly release_invocation_helper_path="${script_directory}/lib/release_invocation.sh"
readonly release_source_snapshot_helper_path="${script_directory}/lib/release_source_snapshot.sh"
readonly secure_timestamp_helper_path="${script_directory}/lib/secure_timestamp.sh"

# shellcheck source=lib/build_cache.sh
source "${build_cache_helper_path}"
# shellcheck source=lib/distribution_requirements.sh
source "${distribution_requirements_helper_path}"
# shellcheck source=lib/release_output_transaction.sh
source "${release_output_transaction_helper_path}"
# shellcheck source=lib/release_signature_validation.sh
source "${release_signature_validation_helper_path}"
# shellcheck source=lib/release_source_snapshot.sh
source "${release_source_snapshot_helper_path}"
# shellcheck source=lib/release_gate_receipt.sh
source "${release_gate_receipt_helper_path}"
# shellcheck source=lib/release_invocation.sh
source "${release_invocation_helper_path}"
# shellcheck source=lib/secure_timestamp.sh
source "${secure_timestamp_helper_path}"

selected_mode=""
requested_output_path=""
gate_receipt_path=""
gate_capability_path=""
expected_marketing_version=""
expected_build_number=""
signing_identity="${MURALUME_DEVELOPER_ID_APPLICATION:-}"
notary_profile="${MURALUME_NOTARY_KEYCHAIN_PROFILE:-}"
expected_team_identifier="${MURALUME_EXPECTED_TEAM_IDENTIFIER:-}"
resolved_signing_identity=""
selected_bundle_identifier=""
mounted_dmg=0
mounted_device=""
work_directory=""
mount_directory=""
xcode_python_path=""
source_checkout_path=""
source_checkout_registered=0
release_source_commit=""
release_source_tree=""
keep_failed_work_directory="${MURALUME_KEEP_FAILED_WORKDIR:-0}"
original_arguments=("$@")

# Keep other publication channels out of this workflow. Developer ID values
# remain exported only until lockf re-entry, then are removed before any build.
unset MURALUME_ASC_KEY_ID
unset MURALUME_ASC_ISSUER_ID
unset MURALUME_ASC_PRIVATE_KEY_PATH
unset GH_TOKEN
unset GITHUB_TOKEN

print_usage() {
    cat <<'EOF'
Usage:
  ./Scripts/release_macos.sh --mode local --output <path>
  ./Scripts/release_macos.sh --mode distribution --output <path>

Modes:
  local         Produce an ad-hoc signed DMG using an isolated local bundle ID.
  distribution  Produce a Developer ID signed and notarized DMG. Make supplies
                signing values through private environment variables, and a
                provenance-checked Config/Distribution.requirements prepared
                from an Xcode Developer ID export is mandatory.

The private --gate-receipt option is reserved for release-dual. Standalone
distribution releases always run their own complete gate.
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

preserve_failure_logs() {
    local source_directory="$1"
    local diagnostics_root="${project_root}/.build/muralume/diagnostics/release-macos"
    local diagnostic_bundle
    local source_log
    local destination_log
    local copied_log_count=0
    local -a diagnostic_bundles

    [[ -d "${source_directory}" ]] || return 0
    if ! mkdir -p "${diagnostics_root}" \
        || ! chmod 700 "${diagnostics_root}"; then
        printf 'Warning: unable to prepare private release diagnostics.\n' >&2
        return 0
    fi
    diagnostic_bundle="$(
        mktemp -d \
            "${diagnostics_root}/failure-$(date -u '+%Y%m%dT%H%M%SZ')-${$}.XXXXXX"
    )" || {
        printf 'Warning: unable to create a private release diagnostic bundle.\n' >&2
        return 0
    }
    if ! chmod 700 "${diagnostic_bundle}"; then
        rm -rf -- "${diagnostic_bundle}" || true
        printf 'Warning: unable to secure the private release diagnostic bundle.\n' >&2
        return 0
    fi

    while IFS= read -r -d '' source_log; do
        destination_log="${diagnostic_bundle}/$(basename "${source_log}")"
        if tail -c "${failed_diagnostic_log_byte_limit}" \
            "${source_log}" >"${destination_log}" \
            && chmod 600 "${destination_log}"; then
            copied_log_count=$((copied_log_count + 1))
        else
            rm -f -- "${destination_log}" || true
            printf 'Warning: unable to preserve release diagnostic %s.\n' \
                "$(basename "${source_log}")" >&2
        fi
    done < <(
        find "${source_directory}" \
            -maxdepth 1 \
            -type f \
            -name '*.log' \
            -print0
    )

    if [[ "${copied_log_count}" -eq 0 ]]; then
        rm -rf -- "${diagnostic_bundle}" || true
        return 0
    fi

    diagnostic_bundles=("${diagnostics_root}"/failure-*)
    while [[ "${#diagnostic_bundles[@]}" \
        -gt "${failed_diagnostic_bundle_limit}" ]]; do
        if ! rm -rf -- "${diagnostic_bundles[0]}"; then
            printf 'Warning: unable to prune an old private release diagnostic.\n' \
                >&2
            break
        fi
        diagnostic_bundles=("${diagnostics_root}"/failure-*)
    done
    printf 'Private release diagnostics: %s\n' "${diagnostic_bundle}" >&2
}

remove_release_work_directory() {
    local directory_path="$1"

    case "$(basename "${directory_path}")" in
        MuralumeRelease.*)
            rm -rf -- "${directory_path}" || {
                printf 'Warning: unable to remove release work directory: %s\n' \
                    "${directory_path}" >&2
                return 0
            }
            ;;
        *)
            printf 'Warning: refusing to remove unexpected release work directory: %s\n' \
                "${directory_path}" >&2
            ;;
    esac
}

cleanup() {
    local status="$?"
    local preserve_complete_work_directory=0

    trap - EXIT HUP INT TERM

    if [[ "${status}" -ne 0 && -n "${work_directory}" ]]; then
        preserve_failure_logs "${work_directory}" || true
        if [[ "${keep_failed_work_directory}" == "1" ]]; then
            preserve_complete_work_directory=1
        fi
    fi

    if [[ "${mounted_dmg}" -eq 1 ]]; then
        local detach_target="${mounted_device:-${mount_directory}}"
        if [[ -n "${detach_target}" ]]; then
            hdiutil detach "${detach_target}" >/dev/null 2>&1 || true
        fi
    fi

    if [[ -n "${source_checkout_path}" ]]; then
        if ! release_git -C "${project_root}" worktree remove --force \
            "${source_checkout_path}" >/dev/null 2>&1; then
            [[ ! -e "${source_checkout_path}" ]] || printf \
                'Warning: unable to unregister the isolated release source.\n' >&2
        fi
        release_git -C "${project_root}" worktree prune >/dev/null 2>&1 || true
        source_checkout_registered=0
    fi

    if [[ "${preserve_complete_work_directory}" -eq 1 ]]; then
        printf 'Release work directory preserved: %s\n' \
            "${work_directory}" >&2
    elif [[ -n "${work_directory}" ]]; then
        remove_release_work_directory "${work_directory}"
    fi

    return "${status}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

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
        --gate-receipt)
            [[ "$#" -ge 2 ]] || fail "--gate-receipt requires a value."
            gate_receipt_path="$2"
            shift 2
            ;;
        --gate-capability)
            [[ "$#" -ge 2 ]] || fail "--gate-capability requires a value."
            gate_capability_path="$2"
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

case "${keep_failed_work_directory}" in
    0|1)
        ;;
    *)
        fail "MURALUME_KEEP_FAILED_WORKDIR must be either 0 or 1."
        ;;
esac

case "${selected_mode}" in
    "${local_mode}")
        selected_bundle_identifier="${local_bundle_identifier}"
        ;;
    "${distribution_mode}")
        selected_bundle_identifier="${production_bundle_identifier}"
        ;;
    *)
        fail "--mode must be either local or distribution."
        ;;
esac

if [[ "${MURALUME_RELEASE_LOCK_HELD:-0}" == "1" \
    && "${MURALUME_RELEASE_DUAL_CAPABILITY_PATH:-}" != "" ]]; then
    validate_release_dual_capability "${project_root}" \
        || fail "The inherited release lock capability is invalid."
elif [[ "${MURALUME_RELEASE_LOCK_HELD:-0}" == "1" \
    && "${MURALUME_RELEASE_STANDALONE_LOCK_PATH:-}" \
        == "${project_root}/.build/muralume/locks/release.lock" ]]; then
    [[ "${MURALUME_RELEASE_LOCK_REEXEC_TOKEN:-}" =~ ^[[:xdigit:]]{64}$ ]] \
        || fail "The inherited standalone release lock is invalid."
    /usr/bin/lockf -t 0 "${MURALUME_RELEASE_STANDALONE_LOCK_PATH}" \
        /usr/bin/true >/dev/null 2>&1 \
        && fail "The inherited standalone release lock is not held."
elif [[ "${MURALUME_RELEASE_LOCK_HELD:-0}" != "0" ]]; then
    fail "MURALUME_RELEASE_LOCK_HELD has an invalid value."
fi
if [[ -n "${gate_receipt_path}" || -n "${gate_capability_path}" ]]; then
    [[ "${selected_mode}" == "${distribution_mode}" \
        && "${gate_receipt_path}" == /* \
        && "${gate_capability_path}" == /* \
        && "${MURALUME_RELEASE_LOCK_HELD:-0}" == "1" \
        && "${gate_capability_path}" \
            == "${MURALUME_RELEASE_DUAL_CAPABILITY_PATH:-}" ]] \
        || fail "Shared gate reuse is only available inside release-dual."
fi

if [[ "${selected_mode}" == "${distribution_mode}" ]]; then
    [[ -z "${GIT_REPLACE_REF_BASE:-}" ]] \
        || fail "A formal release rejects GIT_REPLACE_REF_BASE."
    export GIT_NO_REPLACE_OBJECTS=1
    unset GIT_REPLACE_REF_BASE
fi

[[ -n "${requested_output_path}" ]] || fail "--output is required."
[[ "${requested_output_path}" == *.dmg ]] \
    || fail "--output must use the .dmg extension."

if [[ "${MURALUME_RELEASE_LOCK_HELD:-0}" != "1" ]]; then
    readonly lock_directory="${project_root}/.build/muralume/locks"
    readonly release_lock_path="${lock_directory}/release.lock"
    mkdir -p "${lock_directory}"
    chmod 700 "${project_root}/.build/muralume" "${lock_directory}"
    export MURALUME_RELEASE_LOCK_HELD=1
    export MURALUME_RELEASE_STANDALONE_LOCK_PATH="${release_lock_path}"
    export MURALUME_RELEASE_LOCK_REEXEC_TOKEN="$(openssl rand -hex 32)"
    set +e
    if [[ "${#original_arguments[@]}" -eq 0 ]]; then
        /usr/bin/lockf -t 0 -k "${release_lock_path}" \
            "${script_directory}/release_macos.sh"
    else
        /usr/bin/lockf -t 0 -k "${release_lock_path}" \
            "${script_directory}/release_macos.sh" "${original_arguments[@]}"
    fi
    lock_status="$?"
    set -e
    if [[ "${lock_status}" -eq 75 ]]; then
        printf '%s\n' 'Error: another Muralume release workflow is running.' >&2
    fi
    exit "${lock_status}"
fi

# The wrapper keeps the kernel lock. Its re-entry proof and a dual capability
# are single-use so descendant build phases cannot start another release.
unset MURALUME_RELEASE_LOCK_REEXEC_TOKEN
unset MURALUME_RELEASE_STANDALONE_LOCK_PATH
unset MURALUME_RELEASE_DUAL_CAPABILITY_PATH
unset MURALUME_RELEASE_DUAL_CAPABILITY_TOKEN
unset MURALUME_DEVELOPER_ID_APPLICATION
unset MURALUME_NOTARY_KEYCHAIN_PROFILE
unset MURALUME_EXPECTED_TEAM_IDENTIFIER

require_command codesign
require_command chmod
require_command cp
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
    require_command cmp
    require_command csreq
    require_command git
    require_command rg
    require_command security
    require_command spctl
    require_command stat
    [[ -n "${signing_identity}" ]] \
        || fail "A Developer ID Application identity is required."
    [[ -n "${notary_profile}" ]] \
        || fail "A notarytool Keychain profile is required."
    [[ "${expected_team_identifier}" =~ ^[A-Z0-9]{10}$ ]] \
        || fail "A 10-character expected Apple Team ID is required."

    [[ -f "${release_config_path}" && ! -L "${release_config_path}" ]] \
        || fail "Config/Release.local.mk is required for a formal release."
    config_permissions="$(stat -f '%Lp' "${release_config_path}")"
    [[ "${config_permissions}" == "600" ]] \
        || fail "Config/Release.local.mk must have permissions 0600."

    [[ -f "${distribution_requirements_path}" \
        && ! -L "${distribution_requirements_path}" ]] \
        || fail "Config/Distribution.requirements is required for a formal release."
    requirements_permissions="$(
        stat -f '%Lp' "${distribution_requirements_path}"
    )"
    [[ "${requirements_permissions}" == "600" ]] \
        || fail "Config/Distribution.requirements must have permissions 0600."
    reject_release_git_object_overrides "${project_root}" \
        || fail "The formal release repository uses forbidden Git object overrides."
    verify_clean_release_repository "${project_root}" \
        || fail "The formal release source is not clean."
    release_source_commit="$(
        release_git -C "${project_root}" rev-parse --verify 'HEAD^{commit}'
    )"
    release_source_tree="$(
        release_git -C "${project_root}" rev-parse --verify 'HEAD^{tree}'
    )"
    expected_marketing_version="$(
        release_xcconfig_value_at_commit \
            "${project_root}" "${release_source_commit}" \
            Config/Base.xcconfig MARKETING_VERSION
    )"
    expected_build_number="$(
        release_xcconfig_value_at_commit \
            "${project_root}" "${release_source_commit}" \
            Config/Base.xcconfig CURRENT_PROJECT_VERSION
    )"
    validate_formal_release_version \
        "${project_root}" \
        "${release_source_commit}" \
        "${expected_marketing_version}" \
        "${expected_build_number}" \
        "${xcode_python_path}" \
        || fail "The formal release version or tag state is invalid."
    if [[ -n "${gate_receipt_path}" ]]; then
        validate_release_gate_receipt \
            "${gate_receipt_path}" \
            "${project_root}" \
            "${release_source_commit}" \
            "${release_source_tree}" \
            || fail "The shared release gate receipt is invalid."
    fi
else
    expected_marketing_version="$(
        sed -n \
            's/^[[:space:]]*MARKETING_VERSION[[:space:]]*=[[:space:]]*\([^[:space:]#]*\).*$/\1/p' \
            "${project_root}/Config/Base.xcconfig"
    )"
    expected_build_number="$(
        sed -n \
            's/^[[:space:]]*CURRENT_PROJECT_VERSION[[:space:]]*=[[:space:]]*\([^[:space:]#]*\).*$/\1/p' \
            "${project_root}/Config/Base.xcconfig"
    )"
fi

mkdir -p "$(dirname "${requested_output_path}")"
readonly output_directory="$(cd "$(dirname "${requested_output_path}")" && pwd)"
readonly output_path="${output_directory}/$(basename "${requested_output_path}")"
readonly checksum_path="${output_path}.sha256"

work_directory="$(mktemp -d "${TMPDIR:-/tmp}/MuralumeRelease.XXXXXX")"
chmod 700 "${work_directory}"
readonly archive_path="${work_directory}/Muralume.xcarchive"
derived_data_path="$(
    muralume_prepare_xcode_cache \
        "${project_root}" "release-macos-${selected_mode}"
)" || fail "Unable to prepare the Developer ID Xcode cache."
readonly derived_data_path
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
readonly distribution_requirements_snapshot_path="${work_directory}/Distribution.requirements"
readonly release_gate_artifacts_path="${work_directory}/ReleaseGate"
release_gate_derived_data_path="$(
    muralume_prepare_xcode_cache "${project_root}" release-gate
)" || fail "Unable to prepare the release-gate Xcode cache."
readonly release_gate_derived_data_path
mount_directory=""

build_project_root="${project_root}"
requirements_snapshot_digest=""
if [[ "${selected_mode}" == "${distribution_mode}" ]]; then
    cp -p \
        "${distribution_requirements_path}" \
        "${distribution_requirements_snapshot_path}"
    chmod 400 "${distribution_requirements_snapshot_path}"
    [[ -f "${distribution_requirements_snapshot_path}" \
        && ! -L "${distribution_requirements_snapshot_path}" ]] \
        || fail "The private distribution requirement snapshot is invalid."
    [[ "$(stat -f '%Lp' "${distribution_requirements_snapshot_path}")" \
        == "400" ]] \
        || fail "The private distribution requirement snapshot must be read-only."

    v1_0_3_source_commit="$(
        release_git -C "${project_root}" rev-parse \
            'v1.0.3^{commit}' 2>/dev/null
    )" || fail "The immutable v1.0.3 source tag is required for provenance validation."
    validate_distribution_requirement_provenance \
        "${distribution_requirements_snapshot_path}" \
        "${production_bundle_identifier}" \
        "${expected_team_identifier}" \
        "${project_root}" \
        "${v1_0_3_source_commit}" \
        || fail "The Xcode-exported distribution requirement snapshot failed provenance validation."
    requirements_snapshot_digest="$(
        shasum -a 256 "${distribution_requirements_snapshot_path}" \
            | awk '{ print $1 }'
    )"

    resolved_signing_identity="$(
        resolve_developer_id_identity_hash \
            "${signing_identity}" \
            "${expected_team_identifier}"
    )" || fail "The configured Developer ID Application identity is unavailable or ambiguous."
    xcrun notarytool history \
        --keychain-profile "${notary_profile}" >/dev/null

    readonly source_checkout_parent="${project_root}/.build/muralume/checkouts/release-macos"
    mkdir -p "${source_checkout_parent}"
    chmod 700 \
        "${project_root}/.build/muralume/checkouts" \
        "${source_checkout_parent}"
    source_checkout_path="${source_checkout_parent}/Source"
    release_reclaim_managed_worktree "${project_root}" "${source_checkout_path}" \
        || fail "Unable to reclaim a stale Developer ID source checkout."
    if ! release_git -C "${project_root}" worktree add --detach \
        "${source_checkout_path}" \
        "${release_source_commit}" >/dev/null; then
        fail "Unable to create the isolated release source checkout."
    fi
    source_checkout_registered=1
    verify_release_source_snapshot \
        "${source_checkout_path}" \
        "${release_source_commit}" \
        "${release_source_tree}" \
        || fail "The isolated release source does not match the captured HEAD."
    build_project_root="${source_checkout_path}"

    if [[ -n "${gate_receipt_path}" ]]; then
        printf 'Reusing the source- and Xcode-bound shared release gate.\n'
        validate_release_gate_receipt \
            "${gate_receipt_path}" \
            "${project_root}" \
            "${release_source_commit}" \
            "${release_source_tree}" \
            || fail "The shared release gate receipt changed before archive."
    else
        printf 'Testing isolated release source %s (%s)...\n' \
            "${release_source_commit}" \
            "${release_source_tree}"
        [[ -x "${build_project_root}/Scripts/verify.sh" ]] \
            || fail "The isolated release source has no executable release gate."
        /usr/bin/env \
            -u MURALUME_RELEASE_LOCK_HELD \
            -u MURALUME_RELEASE_LOCK_REEXEC_TOKEN \
            -u MURALUME_RELEASE_STANDALONE_LOCK_PATH \
            -u MURALUME_RELEASE_DUAL_CAPABILITY_PATH \
            -u MURALUME_RELEASE_DUAL_CAPABILITY_TOKEN \
            -u MURALUME_ASC_KEY_ID \
            -u MURALUME_ASC_ISSUER_ID \
            -u MURALUME_ASC_PRIVATE_KEY_PATH \
            -u MURALUME_DEVELOPER_ID_APPLICATION \
            -u MURALUME_NOTARY_KEYCHAIN_PROFILE \
            -u MURALUME_EXPECTED_TEAM_IDENTIFIER \
            -u GH_TOKEN \
            -u GITHUB_TOKEN \
            MURALUME_TEST_ARTIFACTS_DIR="${release_gate_artifacts_path}" \
            MURALUME_TEST_DERIVED_DATA_DIR="${release_gate_derived_data_path}" \
            "${build_project_root}/Scripts/verify.sh" release-gate
    fi
    verify_release_source_snapshot \
        "${source_checkout_path}" \
        "${release_source_commit}" \
        "${release_source_tree}" \
        || fail "The tested release source changed before archive."
fi
readonly build_project_root
readonly build_project_path="${build_project_root}/Muralume.xcodeproj"
readonly build_entitlements_path="${build_project_root}/Muralume/Resources/Muralume.entitlements"
readonly build_dmg_background_renderer_path="${build_project_root}/Scripts/render_dmg_background.swift"
readonly build_dmg_layout_tool_path="${build_project_root}/Scripts/configure_dmg.py"

printf 'Archiving the arm64 Release app...\n'
xcodebuild archive \
    -project "${build_project_path}" \
    -scheme "${expected_product_name}" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "${archive_path}" \
    -derivedDataPath "${derived_data_path}" \
    ARCHS="${expected_architecture}" \
    ONLY_ACTIVE_ARCH=NO \
    PRODUCT_BUNDLE_IDENTIFIER="${selected_bundle_identifier}" \
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
validate_release_privacy_manifest \
    "${xcode_python_path}" \
    "${staged_app_path}" \
    || fail "The staged App privacy manifest failed validation."

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
    [[ "$(
        shasum -a 256 "${distribution_requirements_snapshot_path}" \
            | awk '{ print $1 }'
    )" == "${requirements_snapshot_digest}" ]] \
        || fail "The private distribution requirement snapshot changed before signing."
    printf 'Signing the app with Developer ID...\n'
    sign_with_secure_timestamp \
        "${expected_product_name}.app" \
        "${staged_app_path}" \
        --force \
        --options runtime \
        --entitlements "${build_entitlements_path}" \
        --requirements "${distribution_requirements_snapshot_path}" \
        --sign "${resolved_signing_identity}"
else
    printf 'Applying an ad-hoc signature for local installation...\n'
    codesign \
        --force \
        --options runtime \
        --entitlements "${build_entitlements_path}" \
        --sign - \
        "${staged_app_path}"
fi

codesign --verify --deep --strict --verbose=2 "${staged_app_path}"

if [[ "${selected_mode}" == "${distribution_mode}" ]]; then
    verify_embedded_distribution_requirement \
        "${staged_app_path}" \
        "${distribution_requirements_snapshot_path}" \
        "${work_directory}" \
        || fail "The signed app's designated requirement failed verification."
fi

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
[[ "${actual_bundle_identifier}" == "${selected_bundle_identifier}" ]] \
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
validate_release_entitlements_allowlist \
    "${xcode_python_path}" \
    "${signed_entitlements_path}" \
    || fail "Release entitlements contain a missing, changed, or unexpected key."

sandbox_enabled="$(
    plutil -extract 'com\.apple\.security\.app-sandbox' raw -o - \
        "${signed_entitlements_path}"
)"
[[ "${sandbox_enabled}" == "true" ]] \
    || fail "The release signature must enable App Sandbox."

user_selected_file_access="$(
    plutil -extract 'com\.apple\.security\.files\.user-selected\.read-write' raw -o - \
        "${signed_entitlements_path}"
)"
[[ "${user_selected_file_access}" == "true" ]] \
    || fail "The release signature must allow access to user-selected files."

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

signature_details="$(codesign --display --verbose=4 \
    "${staged_app_path}" 2>&1)"
signature_has_hardened_runtime \
    "${xcode_python_path}" \
    "${signature_details}" \
    || fail "The app signature does not enable Hardened Runtime."

if [[ "${selected_mode}" == "${distribution_mode}" ]]; then
    printf '%s\n' "${signature_details}" \
        | rg '^Authority=Developer ID Application:' >/dev/null \
        || fail "The app is not signed by Developer ID Application."
    printf '%s\n' "${signature_details}" \
        | rg '^Timestamp=' >/dev/null \
        || fail "The app signature has no secure timestamp."
    printf '%s\n' "${signature_details}" \
        | rg '^TeamIdentifier=[A-Z0-9]{10}$' >/dev/null \
        || fail "The app signature has no valid TeamIdentifier."
    actual_app_team_identifier="$(
        printf '%s\n' "${signature_details}" \
            | sed -n 's/^TeamIdentifier=//p'
    )"
    [[ "${actual_app_team_identifier}" == "${expected_team_identifier}" ]] \
        || fail "The app signature does not match the configured Apple Team."
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
xcrun swift "${build_dmg_background_renderer_path}" \
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

"${xcode_python_path}" "${build_dmg_layout_tool_path}" configure \
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
        --sign "${resolved_signing_identity}"
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
        | rg '^TeamIdentifier=[A-Z0-9]{10}$' >/dev/null \
        || fail "The DMG signature has no valid TeamIdentifier."
    actual_dmg_team_identifier="$(
        printf '%s\n' "${dmg_signature_details}" \
            | sed -n 's/^TeamIdentifier=//p'
    )"
    [[ "${actual_dmg_team_identifier}" == "${expected_team_identifier}" ]] \
        || fail "The DMG signature does not match the configured Apple Team."

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
"${xcode_python_path}" "${build_dmg_layout_tool_path}" verify \
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
validate_release_privacy_manifest \
    "${xcode_python_path}" \
    "${mounted_app_path}" \
    || fail "The mounted App privacy manifest failed validation."

if [[ "${selected_mode}" == "${distribution_mode}" ]]; then
    spctl --assess \
        --type open \
        --context context:primary-signature \
        --verbose=4 \
        "${temporary_dmg_path}" >/dev/null 2>&1 \
        || fail "Gatekeeper rejected the notarized DMG."
    spctl --assess \
        --type execute \
        --verbose=4 \
        "${mounted_app_path}" >/dev/null 2>&1 \
        || fail "Gatekeeper rejected the mounted application."
fi

detach_mounted_image

verified_temporary_dmg_digest="$(
    shasum -a 256 "${temporary_dmg_path}" | awk '{ print $1 }'
)"
[[ "${verified_temporary_dmg_digest}" =~ ^[[:xdigit:]]{64}$ ]] \
    || fail "Unable to capture the verified DMG digest."

if [[ "${selected_mode}" == "${distribution_mode}" ]]; then
    verify_release_source_snapshot \
        "${source_checkout_path}" \
        "${release_source_commit}" \
        "${release_source_tree}" \
        || fail "The tested release source changed during packaging."
    verify_clean_release_repository "${project_root}" \
        || fail "The original release repository changed during packaging."
    reject_release_git_object_overrides "${project_root}" \
        || fail "The release repository gained a forbidden Git object override."
    [[ "$(release_git -C "${project_root}" rev-parse --verify 'HEAD^{commit}')" \
        == "${release_source_commit}" ]] \
        || fail "The release HEAD changed during packaging."
    [[ "$(release_git -C "${project_root}" rev-parse --verify 'HEAD^{tree}')" \
        == "${release_source_tree}" ]] \
        || fail "The release tree changed during packaging."
    validate_formal_release_version \
        "${project_root}" \
        "${release_source_commit}" \
        "${expected_marketing_version}" \
        "${expected_build_number}" \
        "${xcode_python_path}" \
        || fail "The formal release version or tag state changed during packaging."
    [[ "$(
        shasum -a 256 "${distribution_requirements_snapshot_path}" \
            | awk '{ print $1 }'
    )" == "${requirements_snapshot_digest}" ]] \
        || fail "The private distribution requirement snapshot changed during packaging."
fi

commit_release_output_pair \
    "${temporary_dmg_path}" \
    "${output_path}" \
    "${checksum_path}" \
    "${verified_temporary_dmg_digest}" \
    || fail "The verified DMG and checksum could not be published safely."

printf 'DMG: %s\n' "${output_path}"
printf 'SHA-256: %s\n' "${checksum_path}"
