#!/usr/bin/env bash

set -euo pipefail
umask 077

readonly expected_product_name="Muralume"
readonly production_bundle_identifier="com.muralume.Muralume"
readonly expected_architecture="arm64"
readonly provenance_marketing_version="0.0.0"
readonly provenance_build_number="1"
readonly launch_services_register_path="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly project_root="$(cd "${script_directory}/.." && pwd)"
readonly release_config_path="${project_root}/Config/Release.local.mk"
readonly distribution_requirements_path="${project_root}/Config/Distribution.requirements"
readonly distribution_requirements_helper_path="${script_directory}/lib/distribution_requirements.sh"

# shellcheck source=lib/distribution_requirements.sh
source "${distribution_requirements_helper_path}"

selected_mode="prepare"
replace_existing=0
work_directory=""
temporary_install_path=""
archive_app_path=""
exported_app_path=""
source_checkout_path=""
build_project_path=""

configured_signing_identity="${MURALUME_DEVELOPER_ID_APPLICATION:-}"
expected_team_identifier="${MURALUME_EXPECTED_TEAM_IDENTIFIER:-}"

print_usage() {
    cat <<'EOF'
Usage:
  make prepare-distribution-requirements
  ./Scripts/prepare_distribution_requirements.sh --check

Options:
  --check    Validate the existing private requirement without building.
  --replace  Replace an invalid existing private requirement after a fresh
             Xcode Developer ID archive and export succeeds.

The preparation command intentionally accepts no App or archive path. It only
extracts from the App produced by its own xcodebuild -exportArchive invocation.
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

unregister_temporary_app() {
    local app_path="$1"
    if [[ -n "${app_path}" && -d "${app_path}" \
        && -x "${launch_services_register_path}" ]]; then
        "${launch_services_register_path}" -u "${app_path}" \
            >/dev/null 2>&1 || true
    fi
}

cleanup() {
    local status="$?"

    # lsregister adds com.apple.provenance metadata asynchronously on current
    # macOS releases, which makes a preserved signed App fail codesign checks.
    # Only unregister disposable Apps on success immediately before deletion;
    # failure artifacts must remain intact for private forensic review.
    if [[ "${status}" -eq 0 ]]; then
        unregister_temporary_app "${exported_app_path}"
        unregister_temporary_app "${archive_app_path}"
    fi

    if [[ -n "${temporary_install_path}" \
        && -e "${temporary_install_path}" ]]; then
        rm -f "${temporary_install_path}"
    fi

    if [[ -n "${source_checkout_path}" ]]; then
        git -C "${project_root}" worktree remove --force \
            "${source_checkout_path}" >/dev/null 2>&1 || true
    fi

    if [[ -n "${work_directory}" ]]; then
        if [[ "${status}" -eq 0 ]]; then
            rm -rf "${work_directory}"
        else
            chmod -R go-rwx "${work_directory}" >/dev/null 2>&1 || true
            printf 'Private requirement preparation logs preserved at: %s\n' \
                "${work_directory}" >&2
        fi
    fi
}
trap cleanup EXIT

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --check)
            selected_mode="check"
            shift
            ;;
        --replace)
            replace_existing=1
            shift
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

if [[ "${selected_mode}" == "check" && "${replace_existing}" -eq 1 ]]; then
    fail "--check and --replace cannot be combined."
fi

require_command awk
require_command cmp
require_command codesign
require_command csreq
require_command git
require_command mktemp
require_command mv
require_command plutil
require_command sed
require_command shasum
require_command stat

[[ "${expected_team_identifier}" =~ ^[A-Z0-9]{10}$ ]] \
    || fail "A 10-character expected Apple Team ID is required."
[[ -f "${release_config_path}" ]] \
    || fail "Config/Release.local.mk is required."
release_config_permissions="$(stat -f '%Lp' "${release_config_path}")"
[[ "${release_config_permissions}" == "600" ]] \
    || fail "Config/Release.local.mk must have permissions 0600."

if git -C "${project_root}" ls-files --error-unmatch \
    "Config/Distribution.requirements" >/dev/null 2>&1; then
    fail "Config/Distribution.requirements must never be tracked."
fi
git -C "${project_root}" check-ignore -q \
    "Config/Distribution.requirements" \
    || fail "Config/Distribution.requirements must be ignored by Git."

if [[ -L "${distribution_requirements_path}" ]]; then
    fail "Config/Distribution.requirements must not be a symbolic link."
fi
if [[ -e "${distribution_requirements_path}" ]]; then
    [[ -f "${distribution_requirements_path}" ]] \
        || fail "Config/Distribution.requirements must be a regular file."
    existing_permissions="$(
        stat -f '%Lp' "${distribution_requirements_path}"
    )"
    [[ "${existing_permissions}" == "600" ]] \
        || fail "Config/Distribution.requirements must have permissions 0600."
fi

v1_0_3_source_commit="$(
    git -C "${project_root}" rev-parse 'v1.0.3^{commit}' 2>/dev/null
)" || fail "The immutable v1.0.3 source tag is required for provenance validation."

validate_installed_requirement() {
    validate_distribution_requirement_provenance \
        "${distribution_requirements_path}" \
        "${production_bundle_identifier}" \
        "${expected_team_identifier}" \
        "${project_root}" \
        "${v1_0_3_source_commit}"
}

if [[ "${selected_mode}" == "check" ]]; then
    [[ -f "${distribution_requirements_path}" ]] \
        || fail "Config/Distribution.requirements is missing. Run make prepare-distribution-requirements first."
    validate_installed_requirement \
        || fail "Config/Distribution.requirements failed provenance validation."
    printf 'Distribution requirement provenance checks passed.\n'
    exit 0
fi

require_command find
require_command lipo
require_command security
require_command xcodebuild

[[ -n "${configured_signing_identity}" ]] \
    || fail "A Developer ID Application identity is required."

if [[ -n "$(
    git -C "${project_root}" status --porcelain --untracked-files=normal
)" ]]; then
    fail "Requirement preparation requires a clean tracked worktree and no unignored files."
fi

source_git_commit="$(git -C "${project_root}" rev-parse HEAD)"
source_git_tree="$(git -C "${project_root}" rev-parse 'HEAD^{tree}')"
v1_0_3_source_tree=""
if [[ -n "${v1_0_3_source_commit}" ]]; then
    v1_0_3_source_tree="$(
        git -C "${project_root}" rev-parse "${v1_0_3_source_commit}^{tree}"
    )"
fi
if [[ -n "${v1_0_3_source_commit}" \
    && ( "${source_git_commit}" == "${v1_0_3_source_commit}" \
        || "${source_git_tree}" == "${v1_0_3_source_tree}" ) ]]; then
    fail "The v1.0.3 release source or source tree cannot prepare the bridge requirement."
fi

if [[ -f "${distribution_requirements_path}" ]] \
    && ! validate_installed_requirement >/dev/null 2>&1 \
    && [[ "${replace_existing}" -ne 1 ]]; then
    fail "The existing requirement is invalid. Re-run with --replace only after reviewing the failure."
fi

resolved_signing_identity="$(
    resolve_developer_id_identity_hash \
        "${configured_signing_identity}" \
        "${expected_team_identifier}"
)" || fail "The Developer ID Application identity could not be resolved."

xcode_version_output="$(xcodebuild -version)" \
    || fail "Unable to read the Xcode version."
xcode_version="$(
    sed -n 's/^Xcode //p' <<<"${xcode_version_output}"
)"
xcode_build="$(
    sed -n 's/^Build version //p' <<<"${xcode_version_output}"
)"
[[ "${xcode_version}" =~ ^[0-9]+([.][0-9A-Za-z]+)+$ \
    && "${xcode_build}" =~ ^[0-9A-Za-z.]+$ ]] \
    || fail "Unable to parse the Xcode version and build."

work_directory="$(
    mktemp -d "${TMPDIR:-/tmp}/MuralumeRequirementPreparation.XXXXXX"
)"
chmod 700 "${work_directory}"

readonly archive_path="${work_directory}/Muralume.xcarchive"
readonly derived_data_path="${work_directory}/DerivedData"
readonly export_path="${work_directory}/DeveloperIDExport"
readonly archive_xcconfig_path="${work_directory}/Archive.xcconfig"
readonly export_options_path="${work_directory}/ExportOptions.plist"
readonly archive_log_path="${work_directory}/archive.log"
readonly export_log_path="${work_directory}/export.log"
readonly extraction_log_path="${work_directory}/requirement-extraction.log"
readonly checkout_log_path="${work_directory}/source-checkout.log"
readonly raw_requirement_path="${work_directory}/exported.requirements"
readonly prepared_requirement_path="${work_directory}/prepared.requirements"
archive_app_path="${archive_path}/Products/Applications/${expected_product_name}.app"
exported_app_path="${export_path}/${expected_product_name}.app"
source_checkout_path="${work_directory}/Source"

if ! git -C "${project_root}" worktree add --detach \
    "${source_checkout_path}" "${source_git_commit}" \
    >"${checkout_log_path}" 2>&1; then
    fail "Unable to create the private detached source checkout. The private log is ${checkout_log_path}."
fi
build_project_path="${source_checkout_path}/Muralume.xcodeproj"
[[ -d "${build_project_path}" ]] \
    || fail "The detached source checkout is missing Muralume.xcodeproj."

{
    printf 'ARCHS = %s\n' "${expected_architecture}"
    printf 'ONLY_ACTIVE_ARCH = NO\n'
    printf 'MURALUME_APP_BUNDLE_IDENTIFIER = %s\n' \
        "${production_bundle_identifier}"
    printf 'PRODUCT_BUNDLE_IDENTIFIER = %s\n' \
        "${production_bundle_identifier}"
    printf 'CODE_SIGN_STYLE = Manual\n'
    printf '%s = %s\n' \
        'CODE_SIGN_IDENTITY' \
        "${resolved_signing_identity}"
    printf '%s = %s\n' \
        'DEVELOPMENT_TEAM' \
        "${expected_team_identifier}"
    printf 'PROVISIONING_PROFILE_SPECIFIER =\n'
    printf 'CODE_SIGNING_ALLOWED = YES\n'
    printf 'CODE_SIGNING_REQUIRED = YES\n'
    printf 'OTHER_CODE_SIGN_FLAGS =\n'
    printf 'MARKETING_VERSION = %s\n' "${provenance_marketing_version}"
    printf 'CURRENT_PROJECT_VERSION = %s\n' "${provenance_build_number}"
} >"${archive_xcconfig_path}"

plutil -create xml1 "${export_options_path}"
plutil -insert destination -string export "${export_options_path}"
plutil -insert method -string developer-id "${export_options_path}"
plutil -insert signingStyle -string manual "${export_options_path}"
plutil -insert signingCertificate -string \
    "${resolved_signing_identity}" "${export_options_path}"
plutil -insert teamID -string \
    "${expected_team_identifier}" "${export_options_path}"
plutil -insert distributionBundleIdentifier -string \
    "${production_bundle_identifier}" "${export_options_path}"

printf 'Creating a private Xcode Developer ID archive...\n'
if ! xcodebuild \
    -project "${build_project_path}" \
    -scheme "${expected_product_name}" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "${archive_path}" \
    -derivedDataPath "${derived_data_path}" \
    -xcconfig "${archive_xcconfig_path}" \
    archive >"${archive_log_path}" 2>&1; then
    fail "Xcode archive failed. The private log is ${archive_log_path}."
fi
[[ -d "${archive_app_path}" && ! -L "${archive_app_path}" ]] \
    || fail "The fresh Xcode archive did not contain the expected App."

printf 'Exporting the archive with Xcode method developer-id...\n'
if ! xcodebuild \
    -exportArchive \
    -archivePath "${archive_path}" \
    -exportPath "${export_path}" \
    -exportOptionsPlist "${export_options_path}" \
    >"${export_log_path}" 2>&1; then
    fail "Xcode Developer ID export failed. The private log is ${export_log_path}."
fi

top_level_app_count="$(
    find "${export_path}" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -name '*.app' \
        -print \
        | wc -l \
        | tr -d '[:space:]'
)"
[[ "${top_level_app_count}" == "1" \
    && -d "${exported_app_path}" \
    && ! -L "${exported_app_path}" ]] \
    || fail "The Developer ID export must contain exactly one top-level Muralume.app."

canonical_export_path="$(cd "${export_path}" && pwd -P)"
canonical_exported_app_parent="$(
    cd "$(dirname "${exported_app_path}")" && pwd -P
)"
[[ "${canonical_exported_app_parent}" == "${canonical_export_path}" ]] \
    || fail "The requirement source escaped the fresh Xcode export directory."

archive_inode="$(stat -f '%d:%i' "${archive_app_path}")"
export_inode="$(stat -f '%d:%i' "${exported_app_path}")"
[[ "${archive_inode}" != "${export_inode}" ]] \
    || fail "The exported App must be distinct from the archive App."

exported_app_cdhash="$(
    validate_xcode_developer_id_exported_app \
        "${exported_app_path}" \
        "${expected_product_name}" \
        "${production_bundle_identifier}" \
        "${expected_team_identifier}" \
        "${expected_architecture}" \
        "${provenance_marketing_version}" \
        "${provenance_build_number}" \
        "${work_directory}"
)" || fail "The Xcode Developer ID export failed identity validation."

if [[ "$(git -C "${source_checkout_path}" rev-parse HEAD)" \
        != "${source_git_commit}" \
    || "$(git -C "${source_checkout_path}" rev-parse 'HEAD^{tree}')" \
        != "${source_git_tree}" \
    || -n "$(git -C "${source_checkout_path}" status --porcelain --untracked-files=normal)" ]]; then
    fail "The detached source checkout changed while Xcode created the export."
fi

# This is the only requirement extraction in the preparation workflow. The
# archive App is deliberately never passed to codesign --display -r-.
if ! codesign --display -r- "${exported_app_path}" \
    >"${raw_requirement_path}" 2>"${extraction_log_path}"; then
    fail "Unable to extract the designated requirement from the Xcode Developer ID export."
fi
validate_distribution_requirement \
    "${raw_requirement_path}" \
    "${production_bundle_identifier}" \
    "${expected_team_identifier}" \
    || fail "Xcode did not export the required Mac App Store OR Developer ID requirement."
verify_embedded_distribution_requirement \
    "${exported_app_path}" \
    "${raw_requirement_path}" \
    "${work_directory}" \
    || fail "The extracted requirement does not match the Xcode Developer ID export."

compiled_requirement_sha256="$(
    distribution_requirement_binary_sha256 "${raw_requirement_path}"
)" || fail "Unable to hash the extracted distribution requirement."

{
    printf '# muralume-provenance-schema: 1\n'
    printf '# muralume-source-kind: xcode-developer-id-export\n'
    printf '# muralume-export-method: developer-id\n'
    printf '# muralume-bundle-identifier: %s\n' \
        "${production_bundle_identifier}"
    printf '# muralume-team-identifier: %s\n' \
        "${expected_team_identifier}"
    printf '# muralume-source-app-version: %s\n' \
        "${provenance_marketing_version}"
    printf '# muralume-source-app-build: %s\n' \
        "${provenance_build_number}"
    printf '# muralume-source-git-commit: %s\n' "${source_git_commit}"
    printf '# muralume-source-git-tree: %s\n' "${source_git_tree}"
    printf '# muralume-xcode-version: %s\n' "${xcode_version}"
    printf '# muralume-xcode-build: %s\n' "${xcode_build}"
    printf '# muralume-exported-app-cdhash: %s\n' \
        "${exported_app_cdhash}"
    printf '# muralume-compiled-requirement-sha256: %s\n' \
        "${compiled_requirement_sha256}"
    cat "${raw_requirement_path}"
} >"${prepared_requirement_path}"

chmod 600 "${prepared_requirement_path}"
validate_distribution_requirement_provenance \
    "${prepared_requirement_path}" \
    "${production_bundle_identifier}" \
    "${expected_team_identifier}" \
    "${project_root}" \
    "${v1_0_3_source_commit}" \
    || fail "The prepared distribution requirement provenance is invalid."
verify_embedded_distribution_requirement \
    "${exported_app_path}" \
    "${prepared_requirement_path}" \
    "${work_directory}" \
    || fail "The provenance-wrapped requirement no longer matches the exported App."

if [[ -f "${distribution_requirements_path}" ]] \
    && validate_installed_requirement >/dev/null 2>&1; then
    existing_requirement_sha256="$(
        distribution_requirement_binary_sha256 \
            "${distribution_requirements_path}"
    )"
    if [[ "${existing_requirement_sha256}" \
        == "${compiled_requirement_sha256}" ]]; then
        printf 'Config/Distribution.requirements is already equivalent; leaving it unchanged.\n'
        exit 0
    fi
    [[ "${replace_existing}" -eq 1 ]] \
        || fail "Xcode exported a different requirement. Review it before using --replace."
fi

temporary_install_path="$(
    mktemp "${project_root}/Config/.Distribution.XXXXXX.requirements"
)"
chmod 600 "${temporary_install_path}"
cp "${prepared_requirement_path}" "${temporary_install_path}"
chmod 600 "${temporary_install_path}"
validate_distribution_requirement_provenance \
    "${temporary_install_path}" \
    "${production_bundle_identifier}" \
    "${expected_team_identifier}" \
    "${project_root}" \
    "${v1_0_3_source_commit}" \
    || fail "The final temporary requirement failed validation."

mv -f "${temporary_install_path}" "${distribution_requirements_path}"
temporary_install_path=""
final_permissions="$(stat -f '%Lp' "${distribution_requirements_path}")"
[[ "${final_permissions}" == "600" ]] \
    || fail "The installed distribution requirement does not have permissions 0600."
validate_installed_requirement \
    || fail "The installed distribution requirement failed final validation."

printf 'Prepared private requirement: %s\n' \
    "${distribution_requirements_path}"
