#!/usr/bin/env bash

set -euo pipefail
umask 077

readonly check_mode="check"
readonly validate_mode="validate"
readonly upload_mode="upload"
readonly product_name="Muralume"
readonly app_store_scheme="Muralume-AppStore"
readonly app_store_configuration="AppStore"
readonly production_bundle_identifier="com.muralume.Muralume"
readonly expected_architecture="arm64"
readonly failed_diagnostic_bundle_limit="5"
readonly failed_diagnostic_log_byte_limit="2097152"

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly project_root="$(cd "${script_directory}/.." && pwd)"
readonly project_path="${project_root}/Muralume.xcodeproj"
readonly private_config_path="${project_root}/Config/AppStore.local.xcconfig"
readonly public_config_relative_path="Config/AppStore.xcconfig"
readonly base_config_relative_path="Config/Base.xcconfig"
readonly app_store_connect_helper_path="${script_directory}/lib/app_store_connect_api.sh"
readonly build_cache_helper_path="${script_directory}/lib/build_cache.sh"
export MURALUME_ASC_FORBIDDEN_ROOT="${project_root}"
readonly packaging_helper_path="${script_directory}/lib/app_store_packaging.sh"
readonly validation_helper_path="${script_directory}/lib/app_store_validation.sh"
readonly release_gate_receipt_helper_path="${script_directory}/lib/release_gate_receipt.sh"
readonly release_invocation_helper_path="${script_directory}/lib/release_invocation.sh"
readonly release_signature_helper_path="${script_directory}/lib/release_signature_validation.sh"
readonly release_source_helper_path="${script_directory}/lib/release_source_snapshot.sh"

# shellcheck source=lib/app_store_connect_api.sh
source "${app_store_connect_helper_path}"
# shellcheck source=lib/build_cache.sh
source "${build_cache_helper_path}"
# shellcheck source=lib/app_store_packaging.sh
source "${packaging_helper_path}"
# shellcheck source=lib/app_store_validation.sh
source "${validation_helper_path}"
# shellcheck source=lib/release_signature_validation.sh
source "${release_signature_helper_path}"
# shellcheck source=lib/release_source_snapshot.sh
source "${release_source_helper_path}"
# shellcheck source=lib/release_gate_receipt.sh
source "${release_gate_receipt_helper_path}"
# shellcheck source=lib/release_invocation.sh
source "${release_invocation_helper_path}"

selected_mode=""
gate_receipt_path=""
gate_capability_path=""
work_directory=""
source_checkout_path=""
source_checkout_registered=0
source_commit=""
source_tree=""
expected_team_identifier=""
private_code_sign_style=""
private_profile_specifier=""
marketing_version=""
build_number=""
xcode_python_path=""
keep_failed_work_directory="${MURALUME_KEEP_FAILED_WORKDIR:-0}"
original_arguments=("$@")
app_store_authentication_arguments=()
app_store_authentication_arguments_present=0
captured_asc_key_id="${MURALUME_ASC_KEY_ID:-}"
captured_asc_issuer_id="${MURALUME_ASC_ISSUER_ID:-}"
captured_asc_private_key_path="${MURALUME_ASC_PRIVATE_KEY_PATH:-}"

run_xcodebuild_with_app_store_auth() {
    if [[ "${app_store_authentication_arguments_present}" -eq 1 ]]; then
        xcodebuild "$@" "${app_store_authentication_arguments[@]}"
    else
        xcodebuild "$@"
    fi
}

# Make loads both release configurations. Developer ID values are always
# unrelated here. ASC values remain exported only until lockf re-entry, then
# the captured copy is used explicitly and the environment is cleared.
unset MURALUME_DEVELOPER_ID_APPLICATION
unset MURALUME_NOTARY_KEYCHAIN_PROFILE
unset MURALUME_EXPECTED_TEAM_IDENTIFIER
unset GH_TOKEN
unset GITHUB_TOKEN

print_usage() {
    cat <<'EOF'
Usage: ./Scripts/release_app_store.sh --mode <check|validate|upload>

Modes:
  check      Validate the clean source and private MAS configuration locally.
  validate   Archive the tested source and run App Store Connect validation.
  upload     Validate, then upload the same archive for TestFlight/App Store.

Use the matching Make targets so signing output stays in private mode-0600 logs.
The private --gate-receipt option is reserved for release-dual.
EOF
}

fail() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

require_command() {
    local command_name="$1"
    command -v "${command_name}" >/dev/null 2>&1 \
        || fail "Required command is unavailable: ${command_name}"
}

trim_whitespace() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "${value}"
}

validate_private_app_store_config() {
    local config_path="$1"
    local line
    local key
    local value
    local team_count=0
    local style_count=0
    local profile_count=0

    [[ -f "${config_path}" && ! -L "${config_path}" ]] \
        || fail "Config/AppStore.local.xcconfig is required and must be a regular file."
    [[ "$(stat -f '%Lp' "${config_path}")" == "600" ]] \
        || fail "Config/AppStore.local.xcconfig must have permissions 0600."

    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line%$'\r'}"
        [[ "${line}" =~ ^[[:space:]]*$ ]] && continue
        [[ "${line}" =~ ^[[:space:]]*// ]] && continue
        [[ "${line}" == *"="* ]] \
            || fail "The private App Store config contains an unsupported directive."
        key="$(trim_whitespace "${line%%=*}")"
        value="$(trim_whitespace "${line#*=}")"
        case "${key}" in
            MURALUME_APP_STORE_DEVELOPMENT_TEAM)
                team_count=$((team_count + 1))
                expected_team_identifier="${value}"
                ;;
            MURALUME_APP_STORE_CODE_SIGN_STYLE)
                style_count=$((style_count + 1))
                private_code_sign_style="${value}"
                ;;
            MURALUME_APP_STORE_PROVISIONING_PROFILE_SPECIFIER)
                profile_count=$((profile_count + 1))
                private_profile_specifier="${value}"
                ;;
            *)
                fail "The private App Store config contains an unsupported build setting."
                ;;
        esac
    done < "${config_path}"

    [[ "${team_count}" -eq 1 \
        && "${expected_team_identifier}" =~ ^[A-Z0-9]{10}$ ]] \
        || fail "The private App Store config must define one valid Team ID."
    [[ "${style_count}" -eq 1 \
        && "${private_code_sign_style}" == "Automatic" ]] \
        || fail "The App Store upload workflow requires Automatic signing."
    [[ "${profile_count}" -eq 1 && -z "${private_profile_specifier}" ]] \
        || fail "Automatic App Store signing must not pin a provisioning profile."
}

run_private_command() {
    local stage_name="$1"
    local log_path="$2"
    shift 2
    local command_status=0

    printf '%s...\n' "${stage_name}"
    if "$@" >"${log_path}" 2>&1; then
        return
    else
        command_status=$?
    fi
    printf 'Error: %s failed. Private log: %s\n' \
        "${stage_name}" "${log_path}" >&2
    return "${command_status}"
}

resolved_build_setting() {
    local settings_path="$1"
    local setting_key="$2"
    local values
    local value_count

    values="$(
        awk -v key="${setting_key}" '
            $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
                value = $0
                sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", value)
                print value
            }
        ' "${settings_path}" | sort -u
    )"
    value_count="$(printf '%s\n' "${values}" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
    [[ "${value_count}" == "1" ]] \
        || fail "Resolved App Store build settings do not contain one ${setting_key}."
    printf '%s\n' "${values}"
}

validate_resolved_build_settings() {
    local settings_path="$1"
    local resolved_bundle_identifier
    local resolved_version
    local resolved_build
    local resolved_style
    local resolved_team
    local resolved_architectures
    local sandbox_enabled
    local hardened_runtime_enabled

    resolved_bundle_identifier="$(
        resolved_build_setting "${settings_path}" PRODUCT_BUNDLE_IDENTIFIER
    )"
    resolved_version="$(resolved_build_setting "${settings_path}" MARKETING_VERSION)"
    resolved_build="$(resolved_build_setting "${settings_path}" CURRENT_PROJECT_VERSION)"
    resolved_style="$(resolved_build_setting "${settings_path}" CODE_SIGN_STYLE)"
    resolved_team="$(resolved_build_setting "${settings_path}" DEVELOPMENT_TEAM)"
    resolved_architectures="$(resolved_build_setting "${settings_path}" ARCHS)"
    sandbox_enabled="$(resolved_build_setting "${settings_path}" ENABLE_APP_SANDBOX)"
    hardened_runtime_enabled="$(
        resolved_build_setting "${settings_path}" ENABLE_HARDENED_RUNTIME
    )"

    [[ "${resolved_bundle_identifier}" == "${production_bundle_identifier}" ]] \
        || fail "The App Store configuration resolved an unexpected bundle identifier."
    [[ "${resolved_version}" == "${marketing_version}" \
        && "${resolved_build}" == "${build_number}" ]] \
        || fail "The resolved App Store version differs from the captured source config."
    [[ "${resolved_style}" == "Automatic" ]] \
        || fail "The resolved App Store configuration is not using Automatic signing."
    [[ "${resolved_team}" == "${expected_team_identifier}" ]] \
        || fail "The resolved App Store Team does not match the private config."
    [[ "${resolved_architectures}" == "${expected_architecture}" ]] \
        || fail "The App Store configuration must build arm64 only."
    [[ "${sandbox_enabled}" == "YES" \
        && "${hardened_runtime_enabled}" == "YES" ]] \
        || fail "The App Store configuration must enable Sandbox and Hardened Runtime."
}

create_export_options() {
    local export_mode="$1"
    local output_path="$2"

    "${xcode_python_path}" -c '
import plistlib
import sys

mode, output_path, team, bundle_identifier = sys.argv[1:]
options = {
    "destination": "export" if mode == "inspect" else "upload",
    "distributionBundleIdentifier": bundle_identifier,
    "manageAppVersionAndBuildNumber": False,
    "method": "validation" if mode == "validate" else "app-store-connect",
    "signingStyle": "automatic",
    "teamID": team,
}
if mode in {"inspect", "upload"}:
    options.update({
        "testFlightInternalTestingOnly": False,
        "uploadSymbols": True,
    })
with open(output_path, "wb") as stream:
    plistlib.dump(options, stream, fmt=plistlib.FMT_XML, sort_keys=True)
' "${export_mode}" "${output_path}" \
        "${expected_team_identifier}" "${production_bundle_identifier}"
    chmod 600 "${output_path}"
}

write_upload_receipt() {
    local receipt_directory="$1"
    local receipt_path="$2"
    local temporary_receipt_path

    mkdir -p "${receipt_directory}" || return 1
    temporary_receipt_path="$(
        mktemp "${receipt_directory}/.Muralume-upload.XXXXXX"
    )" || return 1
    if ! {
        printf 'product=Muralume\n'
        printf 'bundle_identifier=%s\n' "${production_bundle_identifier}"
        printf 'marketing_version=%s\n' "${marketing_version}"
        printf 'build_number=%s\n' "${build_number}"
        printf 'source_commit=%s\n' "${source_commit}"
        printf 'source_tree=%s\n' "${source_tree}"
        printf 'uploaded_at_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        xcodebuild -version | awk '
            NR == 1 { print "xcode_version=" $2 }
            NR == 2 { print "xcode_build=" $3 }
        '
    } >"${temporary_receipt_path}"; then
        rm -f "${temporary_receipt_path}"
        return 1
    fi
    if ! chmod 600 "${temporary_receipt_path}" \
        || ! mv -f "${temporary_receipt_path}" "${receipt_path}"; then
        rm -f "${temporary_receipt_path}"
        return 1
    fi
}

preserve_failure_logs() {
    local source_directory="$1"
    local diagnostics_root="${project_root}/.build/muralume/diagnostics/release-app-store"
    local diagnostic_bundle
    local source_log
    local destination_log
    local copied_log_count=0
    local -a diagnostic_bundles

    [[ -d "${source_directory}" ]] || return 0
    if ! mkdir -p "${diagnostics_root}" \
        || ! chmod 700 "${diagnostics_root}"; then
        printf 'Warning: unable to prepare private App Store diagnostics.\n' >&2
        return 0
    fi
    diagnostic_bundle="$(
        mktemp -d \
            "${diagnostics_root}/failure-$(date -u '+%Y%m%dT%H%M%SZ')-${$}.XXXXXX"
    )" || {
        printf 'Warning: unable to create a private App Store diagnostic bundle.\n' >&2
        return 0
    }
    if ! chmod 700 "${diagnostic_bundle}"; then
        rm -rf -- "${diagnostic_bundle}" || true
        printf 'Warning: unable to secure the private App Store diagnostic bundle.\n' >&2
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
            printf 'Warning: unable to preserve App Store diagnostic %s.\n' \
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
            printf 'Warning: unable to prune an old private App Store diagnostic.\n' \
                >&2
            break
        fi
        diagnostic_bundles=("${diagnostics_root}"/failure-*)
    done
    printf 'Private App Store diagnostics: %s\n' "${diagnostic_bundle}" >&2
}

remove_app_store_work_directory() {
    local directory_path="$1"

    case "$(basename "${directory_path}")" in
        MuralumeAppStore.*)
            rm -rf -- "${directory_path}" || {
                printf 'Warning: unable to remove App Store work directory: %s\n' \
                    "${directory_path}" >&2
                return 0
            }
            ;;
        *)
            printf 'Warning: refusing to remove unexpected App Store work directory: %s\n' \
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

    if [[ -n "${source_checkout_path}" ]]; then
        if ! release_git -C "${project_root}" worktree remove --force \
            "${source_checkout_path}" >/dev/null 2>&1; then
            [[ ! -e "${source_checkout_path}" ]] || printf \
                'Warning: unable to unregister the isolated App Store source.\n' >&2
        fi
        release_git -C "${project_root}" worktree prune >/dev/null 2>&1 || true
        source_checkout_registered=0
    fi

    if [[ "${preserve_complete_work_directory}" -eq 1 ]]; then
        printf 'Private App Store work directory preserved: %s\n' \
            "${work_directory}" >&2
    elif [[ -n "${work_directory}" ]]; then
        remove_app_store_work_directory "${work_directory}"
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
    "${check_mode}"|"${validate_mode}"|"${upload_mode}")
        ;;
    *)
        fail "--mode must be check, validate, or upload."
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
    [[ "${selected_mode}" != "${check_mode}" \
        && "${gate_receipt_path}" == /* \
        && "${gate_capability_path}" == /* \
        && "${MURALUME_RELEASE_LOCK_HELD:-0}" == "1" \
        && "${gate_capability_path}" \
            == "${MURALUME_RELEASE_DUAL_CAPABILITY_PATH:-}" ]] \
        || fail "Shared gate reuse is only available inside release-dual."
fi

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
            "${script_directory}/release_app_store.sh"
    else
        /usr/bin/lockf -t 0 -k "${release_lock_path}" \
            "${script_directory}/release_app_store.sh" "${original_arguments[@]}"
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
unset MURALUME_ASC_KEY_ID
unset MURALUME_ASC_ISSUER_ID
unset MURALUME_ASC_PRIVATE_KEY_PATH

[[ -z "${GIT_REPLACE_REF_BASE:-}" ]] \
    || fail "The App Store workflow rejects GIT_REPLACE_REF_BASE."
export GIT_NO_REPLACE_OBJECTS=1
unset GIT_REPLACE_REF_BASE

require_command awk
require_command chmod
require_command codesign
require_command cp
require_command git
require_command lipo
require_command lsbom
require_command plutil
require_command pkgutil
require_command rg
require_command security
require_command stat
require_command xcrun
require_command xcodebuild

app_store_connect_setting_count=0
[[ -z "${captured_asc_key_id}" ]] \
    || app_store_connect_setting_count=$((app_store_connect_setting_count + 1))
[[ -z "${captured_asc_issuer_id}" ]] \
    || app_store_connect_setting_count=$((app_store_connect_setting_count + 1))
[[ -z "${captured_asc_private_key_path}" ]] \
    || app_store_connect_setting_count=$((app_store_connect_setting_count + 1))
case "${app_store_connect_setting_count}" in
    0)
        ;;
    3)
        MURALUME_ASC_KEY_ID="${captured_asc_key_id}" \
        MURALUME_ASC_ISSUER_ID="${captured_asc_issuer_id}" \
        MURALUME_ASC_PRIVATE_KEY_PATH="${captured_asc_private_key_path}" \
        validate_app_store_connect_credentials \
            || fail "The App Store Connect API credentials are invalid."
        app_store_authentication_arguments=(
            -authenticationKeyPath "${captured_asc_private_key_path}"
            -authenticationKeyID "${captured_asc_key_id}"
            -authenticationKeyIssuerID "${captured_asc_issuer_id}"
        )
        app_store_authentication_arguments_present=1
        unset MURALUME_ASC_KEY_ID
        unset MURALUME_ASC_ISSUER_ID
        unset MURALUME_ASC_PRIVATE_KEY_PATH
        ;;
    *)
        fail "Configure all three App Store Connect API credential values or none."
        ;;
esac

xcode_python_path="$(xcrun --find python3 2>/dev/null || true)"
[[ -x "${xcode_python_path}" ]] \
    || fail "Xcode's Python 3 runtime is unavailable."

validate_private_app_store_config "${private_config_path}"
reject_release_git_object_overrides "${project_root}" \
    || fail "The App Store repository uses forbidden Git object overrides."
verify_clean_release_repository "${project_root}" \
    || fail "The App Store source repository is not clean."

source_commit="$(release_git -C "${project_root}" rev-parse --verify 'HEAD^{commit}')"
source_tree="$(release_git -C "${project_root}" rev-parse --verify 'HEAD^{tree}')"
if [[ -n "${gate_receipt_path}" ]]; then
    validate_release_gate_receipt \
        "${gate_receipt_path}" \
        "${project_root}" \
        "${source_commit}" \
        "${source_tree}" \
        || fail "The shared release gate receipt is invalid."
fi
marketing_version="$(
    release_xcconfig_value_at_commit \
        "${project_root}" \
        "${source_commit}" \
        "${public_config_relative_path}" \
        MARKETING_VERSION
)"
build_number="$(
    release_xcconfig_value_at_commit \
        "${project_root}" \
        "${source_commit}" \
        "${public_config_relative_path}" \
        CURRENT_PROJECT_VERSION
)"
base_marketing_version="$(
    release_xcconfig_value_at_commit \
        "${project_root}" \
        "${source_commit}" \
        "${base_config_relative_path}" \
        MARKETING_VERSION
)"
base_build_number="$(
    release_xcconfig_value_at_commit \
        "${project_root}" \
        "${source_commit}" \
        "${base_config_relative_path}" \
        CURRENT_PROJECT_VERSION
)"

[[ "${marketing_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "The App Store marketing version must use three numeric components."
[[ "${build_number}" =~ ^[0-9]+$ && "${base_build_number}" =~ ^[0-9]+$ ]] \
    || fail "The App Store and base build numbers must be integers."
[[ "${marketing_version}" == "${base_marketing_version}" ]] \
    || fail "The App Store and Developer ID marketing versions must match."
[[ "${build_number}" -gt "${base_build_number}" ]] \
    || fail "The App Store build number must be newer than the Developer ID build."

work_directory="$(mktemp -d "${TMPDIR:-/tmp}/MuralumeAppStore.XXXXXX")"
chmod 700 "${work_directory}"
derived_data_path="$(
    muralume_prepare_xcode_cache "${project_root}" release-app-store
)" || fail "Unable to prepare the App Store Xcode cache."
readonly derived_data_path
readonly settings_log_path="${work_directory}/show-build-settings.log"
readonly settings_derived_data_path="${derived_data_path}"
readonly identity_log_path="${work_directory}/code-signing-identities.log"

run_private_command \
    "Resolving isolated App Store build settings" \
    "${settings_log_path}" \
    xcodebuild \
        -project "${project_path}" \
        -scheme "${app_store_scheme}" \
        -configuration "${app_store_configuration}" \
        -derivedDataPath "${settings_derived_data_path}" \
        -showBuildSettings
validate_resolved_build_settings "${settings_log_path}"

security find-identity -v -p codesigning >"${identity_log_path}" 2>&1 || true
apple_distribution_identity_count="$(
    awk '
        /"Apple Distribution:|"3rd Party Mac Developer Application:|"Mac App Distribution:/ {
            count += 1
        }
        END { print count + 0 }
    ' "${identity_log_path}"
)"
if [[ "${apple_distribution_identity_count}" -eq 0 ]]; then
    printf '%s\n' \
        'No local Apple Distribution identity is installed; Xcode automatic signing will request managed signing assets.'
fi

printf 'App Store preflight passed for Muralume %s (%s).\n' \
    "${marketing_version}" "${build_number}"
[[ "${selected_mode}" != "${check_mode}" ]] || exit 0

readonly archive_path="${work_directory}/Muralume.xcarchive"
readonly archive_app_path="${archive_path}/Products/Applications/Muralume.app"
readonly release_gate_artifacts_path="${work_directory}/ReleaseGate"
release_gate_derived_data_path="$(
    muralume_prepare_xcode_cache "${project_root}" release-gate
)" || fail "Unable to prepare the release-gate Xcode cache."
readonly release_gate_derived_data_path
readonly release_gate_log_path="${work_directory}/release-gate.log"
readonly archive_log_path="${work_directory}/archive.log"
readonly archive_signature_log_path="${work_directory}/archive-signature-verification.log"
readonly archive_signature_details_path="${work_directory}/archive-signature-details.log"
readonly inspection_options_path="${work_directory}/InspectionExportOptions.plist"
readonly inspection_export_path="${work_directory}/Inspection"
readonly inspection_log_path="${work_directory}/app-store-inspection-export.log"
readonly inspection_package_log_path="${work_directory}/inspection-package-signature.log"
readonly inspection_expanded_path="${work_directory}/InspectionExpanded"
readonly signature_log_path="${work_directory}/signature-verification.log"
readonly signature_details_path="${work_directory}/signature-details.log"
readonly entitlements_path="${work_directory}/signed-entitlements.plist"
readonly profile_plist_path="${work_directory}/embedded-profile.plist"
readonly validation_options_path="${work_directory}/ValidationExportOptions.plist"
readonly validation_export_path="${work_directory}/Validation"
readonly validation_log_path="${work_directory}/app-store-validation.log"
readonly upload_options_path="${work_directory}/UploadExportOptions.plist"
readonly upload_export_path="${work_directory}/Upload"
readonly upload_log_path="${work_directory}/app-store-upload.log"

readonly source_checkout_parent="${project_root}/.build/muralume/checkouts/release-app-store"
mkdir -p "${source_checkout_parent}"
chmod 700 \
    "${project_root}/.build/muralume/checkouts" \
    "${source_checkout_parent}"
source_checkout_path="${source_checkout_parent}/Source"
release_reclaim_managed_worktree "${project_root}" "${source_checkout_path}" \
    || fail "Unable to reclaim a stale App Store source checkout."
if ! release_git -C "${project_root}" worktree add --detach \
    "${source_checkout_path}" "${source_commit}" >/dev/null; then
    fail "Unable to create the isolated App Store source checkout."
fi
source_checkout_registered=1
cp -p "${private_config_path}" \
    "${source_checkout_path}/Config/AppStore.local.xcconfig"
chmod 400 "${source_checkout_path}/Config/AppStore.local.xcconfig"
verify_release_source_snapshot \
    "${source_checkout_path}" "${source_commit}" "${source_tree}" \
    || fail "The isolated App Store source does not match the captured HEAD."

if [[ -n "${gate_receipt_path}" ]]; then
    printf 'Reusing the source- and Xcode-bound shared release gate.\n'
    validate_release_gate_receipt \
        "${gate_receipt_path}" \
        "${project_root}" \
        "${source_commit}" \
        "${source_tree}" \
        || fail "The shared release gate receipt changed before archive."
else
    run_private_command \
        "Testing the isolated App Store source" \
        "${release_gate_log_path}" \
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
            "${source_checkout_path}/Scripts/verify.sh" release-gate
fi
verify_release_source_snapshot \
    "${source_checkout_path}" "${source_commit}" "${source_tree}" \
    || fail "The tested App Store source changed before archive."

run_app_store_packaging_command \
    "Archiving the signed App Store app" \
    "${archive_log_path}" \
    run_xcodebuild_with_app_store_auth archive \
        -project "${source_checkout_path}/Muralume.xcodeproj" \
        -scheme "${app_store_scheme}" \
        -configuration "${app_store_configuration}" \
        -destination "generic/platform=macOS" \
        -archivePath "${archive_path}" \
        -derivedDataPath "${derived_data_path}" \
        -allowProvisioningUpdates \
        ARCHS="${expected_architecture}" \
        ONLY_ACTIVE_ARCH=NO

[[ -d "${archive_app_path}" && ! -L "${archive_app_path}" ]] \
    || fail "The App Store archive is missing Muralume.app."
validate_app_store_info_plist \
    "${xcode_python_path}" \
    "${archive_app_path}/Contents/Info.plist" \
    "${production_bundle_identifier}" \
    "${marketing_version}" \
    "${build_number}" \
    || fail "The App Store archive has invalid identity, version, or export compliance metadata."
validate_release_privacy_manifest "${xcode_python_path}" "${archive_app_path}" \
    || fail "The App Store archive privacy manifest failed validation."

readonly archive_executable_path="${archive_app_path}/Contents/MacOS/${product_name}"
[[ -f "${archive_executable_path}" && ! -L "${archive_executable_path}" ]] \
    || fail "The App Store archive executable is missing."
[[ "$(lipo -archs "${archive_executable_path}")" == "${expected_architecture}" ]] \
    || fail "The App Store archive is not arm64-only."

run_private_command \
    "Verifying the development-signed archive" \
    "${archive_signature_log_path}" \
    codesign --verify --deep --strict --verbose=4 "${archive_app_path}"
codesign --display --verbose=4 "${archive_app_path}" \
    >"${archive_signature_details_path}" 2>&1
if rg '^Authority=Developer ID Application:' \
    "${archive_signature_details_path}" >/dev/null; then
    fail "The App Store archive must not use Developer ID signing."
fi
rg '^Authority=(Apple Development|Apple Distribution|3rd Party Mac Developer Application|Mac App Distribution):' \
    "${archive_signature_details_path}" >/dev/null \
    || fail "The archive is not signed by an Apple development or distribution identity."
archive_team_identifier="$(
    sed -n 's/^TeamIdentifier=//p' \
        "${archive_signature_details_path}" | sort -u
)"
[[ "${archive_team_identifier}" == "${expected_team_identifier}" ]] \
    || fail "The App Store archive signature does not match the private Team."
signature_has_hardened_runtime \
    "${xcode_python_path}" \
    "$(<"${archive_signature_details_path}")" \
    || fail "The App Store archive does not enable Hardened Runtime."

create_export_options inspect "${inspection_options_path}"
mkdir -p "${inspection_export_path}"
run_app_store_packaging_command \
    "Exporting a local App Store inspection package" \
    "${inspection_log_path}" \
    run_xcodebuild_with_app_store_auth -exportArchive \
        -archivePath "${archive_path}" \
        -exportPath "${inspection_export_path}" \
        -exportOptionsPlist "${inspection_options_path}" \
        -allowProvisioningUpdates

inspection_package_path=""
inspection_package_count=0
while IFS= read -r -d '' candidate_package_path; do
    inspection_package_count=$((inspection_package_count + 1))
    inspection_package_path="${candidate_package_path}"
done < <(
    find "${inspection_export_path}" \
        -maxdepth 2 \
        -type f \
        -name '*.pkg' \
        -print0
)
[[ "${inspection_package_count}" -eq 1 \
    && -f "${inspection_package_path}" \
    && ! -L "${inspection_package_path}" ]] \
    || fail "The App Store inspection export must contain exactly one regular package."

run_private_command \
    "Verifying the exported App Store package signature" \
    "${inspection_package_log_path}" \
    pkgutil --check-signature "${inspection_package_path}"
validate_app_store_package_signature_log \
    "${xcode_python_path}" \
    "${inspection_package_log_path}" \
    "${expected_team_identifier}" \
    || fail "The exported package does not have a trusted App Store installer signature."
run_private_command \
    "Expanding the exported App Store package" \
    "${work_directory}/inspection-package-expand.log" \
    pkgutil --expand-full \
        "${inspection_package_path}" \
        "${inspection_expanded_path}"

inspection_bom_path=""
inspection_bom_count=0
while IFS= read -r -d '' candidate_bom_path; do
    inspection_bom_count=$((inspection_bom_count + 1))
    inspection_bom_path="${candidate_bom_path}"
done < <(
    find "${inspection_expanded_path}" -type f -name Bom -print0
)
[[ "${inspection_bom_count}" -eq 1 ]] \
    || fail "The inspection package must contain exactly one component Bom."
validate_app_store_bom_permissions /usr/bin/lsbom "${inspection_bom_path}" \
    || fail "The App Store package contains files that non-root users cannot read."

inspection_app_path=""
inspection_app_count=0
while IFS= read -r -d '' candidate_app_path; do
    inspection_app_count=$((inspection_app_count + 1))
    inspection_app_path="${candidate_app_path}"
done < <(
    find "${inspection_expanded_path}" \
        -type d \
        -name "${product_name}.app" \
        -prune \
        -print0
)
[[ "${inspection_app_count}" -eq 1 \
    && -d "${inspection_app_path}" \
    && ! -L "${inspection_app_path}" ]] \
    || fail "The inspection package must contain exactly one Muralume.app."

validate_app_store_info_plist \
    "${xcode_python_path}" \
    "${inspection_app_path}/Contents/Info.plist" \
    "${production_bundle_identifier}" \
    "${marketing_version}" \
    "${build_number}" \
    || fail "The exported App Store app has invalid identity, version, or compliance metadata."
validate_release_privacy_manifest \
    "${xcode_python_path}" "${inspection_app_path}" \
    || fail "The exported App Store app privacy manifest failed validation."

inspection_executable_path="${inspection_app_path}/Contents/MacOS/${product_name}"
[[ -f "${inspection_executable_path}" && ! -L "${inspection_executable_path}" ]] \
    || fail "The exported App Store executable is missing."
[[ "$(lipo -archs "${inspection_executable_path}")" == "${expected_architecture}" ]] \
    || fail "The exported App Store app is not arm64-only."

run_private_command \
    "Verifying the distribution-signed App Store app" \
    "${signature_log_path}" \
    codesign --verify --deep --strict --verbose=4 "${inspection_app_path}"
codesign --display --verbose=4 "${inspection_app_path}" \
    >"${signature_details_path}" 2>&1
rg '^Authority=(Apple Distribution|3rd Party Mac Developer Application|Mac App Distribution):' \
    "${signature_details_path}" >/dev/null \
    || fail "The exported app is not signed with an App Store distribution identity."
if rg '^Authority=Developer ID Application:' \
    "${signature_details_path}" >/dev/null; then
    fail "The exported App Store app must not use Developer ID signing."
fi
actual_team_identifier="$(
    sed -n 's/^TeamIdentifier=//p' "${signature_details_path}" | sort -u
)"
[[ "${actual_team_identifier}" == "${expected_team_identifier}" ]] \
    || fail "The exported App Store signature does not match the private Team."
signature_has_hardened_runtime \
    "${xcode_python_path}" \
    "$(<"${signature_details_path}")" \
    || fail "The exported App Store app does not enable Hardened Runtime."

codesign --display --entitlements :- "${inspection_app_path}" \
    >"${entitlements_path}" 2>/dev/null
plutil -lint "${entitlements_path}" >/dev/null
validate_app_store_entitlements \
    "${xcode_python_path}" \
    "${entitlements_path}" \
    "${expected_team_identifier}" \
    "${production_bundle_identifier}" \
    || fail "The exported App Store entitlements are missing, changed, or unexpected."

embedded_profile_path="${inspection_app_path}/Contents/embedded.provisionprofile"
[[ -f "${embedded_profile_path}" && ! -L "${embedded_profile_path}" ]] \
    || fail "The exported App Store app is missing its embedded provisioning profile."
security cms -D -i "${embedded_profile_path}" >"${profile_plist_path}" 2>/dev/null \
    || fail "The embedded App Store provisioning profile cannot be decoded."
plutil -lint "${profile_plist_path}" >/dev/null
validate_app_store_provisioning_profile \
    "${xcode_python_path}" \
    "${profile_plist_path}" \
    "${expected_team_identifier}" \
    "${production_bundle_identifier}" \
    || fail "The embedded provisioning profile is not a valid production macOS profile."

for nested_code_directory in \
    "${inspection_app_path}/Contents/Frameworks" \
    "${inspection_app_path}/Contents/PlugIns" \
    "${inspection_app_path}/Contents/XPCServices"; do
    if [[ -d "${nested_code_directory}" ]] \
        && [[ -n "$(find "${nested_code_directory}" -mindepth 1 -print -quit)" ]]; then
        fail "Nested code was added without an App Store signing policy."
    fi
done

create_export_options validate "${validation_options_path}"
mkdir -p "${validation_export_path}"
run_app_store_packaging_command \
    "Validating the archive with App Store Connect" \
    "${validation_log_path}" \
    run_xcodebuild_with_app_store_auth -exportArchive \
        -archivePath "${archive_path}" \
        -exportPath "${validation_export_path}" \
        -exportOptionsPlist "${validation_options_path}" \
        -allowProvisioningUpdates

verify_release_source_snapshot \
    "${source_checkout_path}" "${source_commit}" "${source_tree}" \
    || fail "The App Store source changed during validation."
verify_clean_release_repository "${project_root}" \
    || fail "The original repository changed during App Store validation."
reject_release_git_object_overrides "${project_root}" \
    || fail "The repository gained forbidden Git object overrides during validation."
[[ "$(release_git -C "${project_root}" rev-parse --verify 'HEAD^{commit}')" \
    == "${source_commit}" ]] \
    || fail "The source HEAD changed during App Store validation."
[[ "$(release_git -C "${project_root}" rev-parse --verify 'HEAD^{tree}')" \
    == "${source_tree}" ]] \
    || fail "The source tree changed during App Store validation."

if [[ "${selected_mode}" == "${validate_mode}" ]]; then
    printf 'App Store Connect accepted validation for Muralume %s (%s).\n' \
        "${marketing_version}" "${build_number}"
    exit 0
fi

create_export_options upload "${upload_options_path}"
mkdir -p "${upload_export_path}"
run_app_store_packaging_command \
    "Uploading the validated archive to App Store Connect" \
    "${upload_log_path}" \
    run_xcodebuild_with_app_store_auth -exportArchive \
        -archivePath "${archive_path}" \
        -exportPath "${upload_export_path}" \
        -exportOptionsPlist "${upload_options_path}" \
        -allowProvisioningUpdates

receipt_directory="${project_root}/dist/app-store"
receipt_path="${receipt_directory}/Muralume-${marketing_version}-${build_number}-upload.txt"
printf 'Uploaded Muralume %s (%s) to App Store Connect from source %s.\n' \
    "${marketing_version}" "${build_number}" "${source_commit}"
if write_upload_receipt "${receipt_directory}" "${receipt_path}"; then
    printf 'Local redacted receipt: %s\n' "${receipt_path}"
else
    printf '%s\n' \
        'Warning: upload succeeded, but the optional local receipt could not be written. Do not retry this build number.' \
        >&2
fi
