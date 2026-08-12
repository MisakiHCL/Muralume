#!/usr/bin/env bash

set -euo pipefail
umask 077

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly project_root="$(cd "${script_directory}/.." && pwd)"
readonly expected_branch="main"
readonly default_github_repository="MisakiHCL/Muralume"
readonly minimum_free_gibibytes="${MURALUME_RELEASE_MINIMUM_FREE_GIB:-15}"
readonly release_config_path="${project_root}/Config/Release.local.mk"
readonly distribution_requirements_path="${project_root}/Config/Distribution.requirements"
readonly app_store_config_path="${project_root}/Config/AppStore.local.xcconfig"
readonly app_store_connect_config_path="${project_root}/Config/AppStoreConnect.local.mk"
readonly github_repository="${MURALUME_GITHUB_REPOSITORY:-${default_github_repository}}"
readonly app_store_connect_helper_path="${script_directory}/lib/app_store_connect_api.sh"
readonly release_invocation_helper_path="${script_directory}/lib/release_invocation.sh"
export MURALUME_ASC_FORBIDDEN_ROOT="${project_root}"

doctor_developer_id_application="${MURALUME_DEVELOPER_ID_APPLICATION:-}"
doctor_notary_keychain_profile="${MURALUME_NOTARY_KEYCHAIN_PROFILE:-}"
doctor_expected_team_identifier="${MURALUME_EXPECTED_TEAM_IDENTIFIER:-}"
doctor_asc_key_id="${MURALUME_ASC_KEY_ID:-}"
doctor_asc_issuer_id="${MURALUME_ASC_ISSUER_ID:-}"
doctor_asc_private_key_path="${MURALUME_ASC_PRIVATE_KEY_PATH:-}"
doctor_gh_token="${GH_TOKEN:-}"
doctor_github_token="${GITHUB_TOKEN:-}"
unset MURALUME_DEVELOPER_ID_APPLICATION
unset MURALUME_NOTARY_KEYCHAIN_PROFILE
unset MURALUME_EXPECTED_TEAM_IDENTIFIER
unset MURALUME_ASC_KEY_ID
unset MURALUME_ASC_ISSUER_ID
unset MURALUME_ASC_PRIVATE_KEY_PATH
unset GH_TOKEN
unset GITHUB_TOKEN

# shellcheck source=lib/app_store_connect_api.sh
source "${app_store_connect_helper_path}"
# shellcheck source=lib/distribution_requirements.sh
source "${script_directory}/lib/distribution_requirements.sh"
# shellcheck source=lib/release_source_snapshot.sh
source "${script_directory}/lib/release_source_snapshot.sh"
# shellcheck source=lib/release_invocation.sh
source "${release_invocation_helper_path}"

doctor_dual_capability_path=""
doctor_dual_capability_token=""
if [[ "${MURALUME_RELEASE_LOCK_HELD:-0}" == "1" ]]; then
    validate_release_dual_capability "${project_root}" \
        || {
            printf '%s\n' \
                'Release doctor failed: inherited release capability is invalid.' >&2
            exit 1
        }
    doctor_dual_capability_path="${MURALUME_RELEASE_DUAL_CAPABILITY_PATH}"
    doctor_dual_capability_token="${MURALUME_RELEASE_DUAL_CAPABILITY_TOKEN}"
elif [[ "${MURALUME_RELEASE_LOCK_HELD:-0}" != "0" ]]; then
    printf '%s\n' \
        'Release doctor failed: MURALUME_RELEASE_LOCK_HELD has an invalid value.' >&2
    exit 1
fi
unset MURALUME_RELEASE_DUAL_CAPABILITY_PATH
unset MURALUME_RELEASE_DUAL_CAPABILITY_TOKEN
unset MURALUME_RELEASE_LOCK_REEXEC_TOKEN
unset MURALUME_RELEASE_STANDALONE_LOCK_PATH

fail() {
    printf 'Release doctor failed: %s\n' "$1" >&2
    exit 1
}

gh() {
    if [[ -n "${doctor_gh_token}" ]]; then
        GH_TOKEN="${doctor_gh_token}" command gh "$@"
    elif [[ -n "${doctor_github_token}" ]]; then
        GITHUB_TOKEN="${doctor_github_token}" command gh "$@"
    else
        command gh "$@"
    fi
}

doctor_work_directory=""
cleanup() {
    [[ -z "${doctor_work_directory}" ]] \
        || rm -rf "${doctor_work_directory}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

require_command() {
    if [[ "$1" == 'gh' ]]; then
        type -P gh >/dev/null 2>&1 \
            || fail 'Required command is unavailable: gh'
    else
        command -v "$1" >/dev/null 2>&1 \
            || fail "Required command is unavailable: $1"
    fi
}

pass() {
    printf '[PASS] %s\n' "$1"
}

run_release_doctor_developer_child() {
    if [[ -n "${doctor_dual_capability_path}" ]]; then
        MURALUME_RELEASE_LOCK_HELD=1 \
        MURALUME_RELEASE_DUAL_CAPABILITY_PATH="${doctor_dual_capability_path}" \
        MURALUME_RELEASE_DUAL_CAPABILITY_TOKEN="${doctor_dual_capability_token}" \
        MURALUME_DEVELOPER_ID_APPLICATION="${doctor_developer_id_application}" \
        MURALUME_NOTARY_KEYCHAIN_PROFILE="${doctor_notary_keychain_profile}" \
        MURALUME_EXPECTED_TEAM_IDENTIFIER="${doctor_expected_team_identifier}" \
            "$@"
    else
        MURALUME_RELEASE_LOCK_HELD=0 \
        MURALUME_DEVELOPER_ID_APPLICATION="${doctor_developer_id_application}" \
        MURALUME_NOTARY_KEYCHAIN_PROFILE="${doctor_notary_keychain_profile}" \
        MURALUME_EXPECTED_TEAM_IDENTIFIER="${doctor_expected_team_identifier}" \
            "$@"
    fi
}

run_release_doctor_app_store_child() {
    if [[ -n "${doctor_dual_capability_path}" ]]; then
        MURALUME_RELEASE_LOCK_HELD=1 \
        MURALUME_RELEASE_DUAL_CAPABILITY_PATH="${doctor_dual_capability_path}" \
        MURALUME_RELEASE_DUAL_CAPABILITY_TOKEN="${doctor_dual_capability_token}" \
        MURALUME_ASC_KEY_ID="${doctor_asc_key_id}" \
        MURALUME_ASC_ISSUER_ID="${doctor_asc_issuer_id}" \
        MURALUME_ASC_PRIVATE_KEY_PATH="${doctor_asc_private_key_path}" \
            "$@"
    else
        MURALUME_RELEASE_LOCK_HELD=0 \
        MURALUME_ASC_KEY_ID="${doctor_asc_key_id}" \
        MURALUME_ASC_ISSUER_ID="${doctor_asc_issuer_id}" \
        MURALUME_ASC_PRIVATE_KEY_PATH="${doctor_asc_private_key_path}" \
            "$@"
    fi
}

xcconfig_value() {
    if [[ "$#" -ne 2 ]]; then
        fail 'xcconfig_value needs a path and key.'
    fi

    local config_path="$1"
    local key="$2"
    local values
    values="$(
        sed -n \
            "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\([^[:space:]#]*\)[[:space:]]*\(#.*\)\{0,1\}$/\1/p" \
            "${config_path}"
    )"
    [[ -n "${values}" && "${values}" != *$'\n'* ]] \
        || fail "${config_path} must define ${key} exactly once."
    printf '%s\n' "${values}"
}

validate_private_file() {
    local file_path="$1"
    local display_name="$2"

    [[ -f "${file_path}" && ! -L "${file_path}" ]] \
        || fail "${display_name} is missing or is not a regular file."
    [[ "$(stat -f '%Lp' "${file_path}")" == '600' ]] \
        || fail "${display_name} must have permissions 0600."
}

validate_local_proxy() {
    local variable_name
    local proxy_url
    local authority
    local host
    local port
    local connection_host

    for variable_name in HTTP_PROXY HTTPS_PROXY ALL_PROXY \
        http_proxy https_proxy all_proxy; do
        proxy_url="${!variable_name:-}"
        [[ -n "${proxy_url}" ]] || continue
        authority="${proxy_url#*://}"
        authority="${authority%%/*}"
        authority="${authority##*@}"
        host="${authority%:*}"
        port="${authority##*:}"
        case "${host}" in
            127.0.0.1|localhost|::1|'[::1]')
                [[ "${port}" =~ ^[0-9]+$ ]] \
                    || fail "${variable_name} has an invalid local proxy port."
                connection_host="${host}"
                [[ "${host}" != '[::1]' ]] || connection_host='::1'
                nc -z -w 2 "${connection_host}" "${port}" >/dev/null 2>&1 \
                    || fail "${variable_name} points to an unavailable local proxy."
                ;;
        esac
    done
    pass 'Configured local proxy endpoints are reachable'
}

validate_disk_space() {
    [[ "${minimum_free_gibibytes}" =~ ^[0-9]+$ ]] \
        || fail 'MURALUME_RELEASE_MINIMUM_FREE_GIB must be an integer.'
    local available_kibibytes
    local required_kibibytes
    available_kibibytes="$(
        df -Pk "${project_root}" | awk 'NR == 2 { print $4 }'
    )"
    required_kibibytes=$((minimum_free_gibibytes * 1024 * 1024))
    [[ "${available_kibibytes}" =~ ^[0-9]+$ \
        && "${available_kibibytes}" -ge "${required_kibibytes}" ]] \
        || fail "At least ${minimum_free_gibibytes} GiB of free disk space is required."
    pass "Free disk space is at least ${minimum_free_gibibytes} GiB"
}

for required_command in \
    awk curl df gh git nc rg ruby security sed stat xcrun xcodebuild; do
    require_command "${required_command}"
done

[[ "$(release_git -C "${project_root}" branch --show-current)" == "${expected_branch}" ]] \
    || fail "Formal releases must run from ${expected_branch}."
reject_release_git_object_overrides "${project_root}" \
    || fail 'Git object replacement is configured.'
verify_clean_release_repository "${project_root}" \
    || fail 'The source repository is not clean.'
source_commit="$(release_git -C "${project_root}" rev-parse 'HEAD^{commit}')" \
    || fail 'Unable to resolve HEAD.'
readonly source_commit
origin_commit="$(
    release_git -C "${project_root}" ls-remote --exit-code origin refs/heads/main \
        | awk 'NR == 1 { print $1 }'
)" || fail 'Unable to read the current remote main commit.'
readonly origin_commit
[[ "${source_commit}" == "${origin_commit}" ]] \
    || fail 'HEAD must match the locally fetched origin/main before release.'
origin_url="$(release_git -C "${project_root}" remote get-url origin)" \
    || fail 'Unable to read the origin URL.'
readonly origin_url
case "${origin_url}" in
    "https://github.com/${github_repository}"|\
    "https://github.com/${github_repository}.git"|\
    "git@github.com:${github_repository}"|\
    "git@github.com:${github_repository}.git"|\
    "ssh://git@github.com/${github_repository}"|\
    "ssh://git@github.com/${github_repository}.git")
        ;;
    *)
        fail "origin does not point to ${github_repository}."
        ;;
esac
pass "Clean ${expected_branch} source matches origin/main (${source_commit})"

validate_private_file "${release_config_path}" 'Config/Release.local.mk'
validate_private_file \
    "${distribution_requirements_path}" 'Config/Distribution.requirements'
validate_private_file \
    "${app_store_config_path}" 'Config/AppStore.local.xcconfig'
validate_private_file \
    "${app_store_connect_config_path}" 'Config/AppStoreConnect.local.mk'
pass 'Private release configuration is present with mode 0600'

base_version="$(
    xcconfig_value "${project_root}/Config/Base.xcconfig" MARKETING_VERSION
)" || fail 'Unable to read the Developer ID version.'
readonly base_version
base_build="$(
    xcconfig_value "${project_root}/Config/Base.xcconfig" CURRENT_PROJECT_VERSION
)" || fail 'Unable to read the Developer ID build.'
readonly base_build
app_store_version="$(
    xcconfig_value "${project_root}/Config/AppStore.xcconfig" MARKETING_VERSION
)" || fail 'Unable to read the App Store version.'
readonly app_store_version
app_store_build="$(
    xcconfig_value \
        "${project_root}/Config/AppStore.xcconfig" CURRENT_PROJECT_VERSION
)" || fail 'Unable to read the App Store build.'
readonly app_store_build
[[ "${base_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ \
    && "${base_build}" =~ ^[0-9]+$ \
    && "${app_store_build}" =~ ^[0-9]+$ \
    && "${base_version}" == "${app_store_version}" \
    && "${app_store_build}" -gt "${base_build}" ]] \
    || fail 'Developer ID and App Store versions/builds are inconsistent.'
pass "Version pair is ${base_version} (${base_build}/${app_store_build})"

xcodebuild -license check >/dev/null 2>&1 \
    || fail 'The Xcode license has not been accepted.'
xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1 \
    || fail 'Xcode first-launch components are not ready.'
pass "$(xcodebuild -version | tr '\n' ' ' | sed 's/[[:space:]]*$//')"

validate_disk_space
validate_local_proxy

[[ -n "${doctor_developer_id_application}" ]] \
    || fail 'MURALUME_DEVELOPER_ID_APPLICATION is not configured.'
[[ -n "${doctor_notary_keychain_profile}" ]] \
    || fail 'MURALUME_NOTARY_KEYCHAIN_PROFILE is not configured.'
[[ "${doctor_expected_team_identifier}" =~ ^[A-Z0-9]{10}$ ]] \
    || fail 'MURALUME_EXPECTED_TEAM_IDENTIFIER is not configured.'
resolve_developer_id_identity_hash \
    "${doctor_developer_id_application}" \
    "${doctor_expected_team_identifier}" >/dev/null \
    || fail 'The Developer ID identity is unavailable or ambiguous.'
pass 'Developer ID signing identity is available'

xcrun notarytool history \
    --keychain-profile "${doctor_notary_keychain_profile}" >/dev/null \
    || fail 'The notarytool Keychain profile is unavailable.'
pass 'Apple notarization credentials are available'

gh auth status --hostname github.com >/dev/null \
    || fail 'GitHub CLI is not authenticated.'
authenticated_repository="$(
    gh repo view "${github_repository}" --json nameWithOwner,viewerPermission \
        --jq '[.nameWithOwner, .viewerPermission] | @tsv'
)" || fail 'GitHub CLI could not read repository permissions.'
IFS=$'\t' read -r authenticated_repository_name github_permission \
    <<<"${authenticated_repository}"
[[ "${authenticated_repository_name}" == "${github_repository}" ]] \
    || fail 'GitHub CLI cannot access the release repository.'
case "${github_permission}" in
    ADMIN|MAINTAIN|WRITE)
        ;;
    *)
        fail 'GitHub CLI does not have write permission for the release repository.'
        ;;
esac
release_git -C "${project_root}" push --dry-run origin \
    HEAD:refs/heads/main >/dev/null \
    || fail 'Git push credentials cannot update origin/main.'
pass "GitHub CLI and Git can publish to ${github_repository}"

MURALUME_ASC_KEY_ID="${doctor_asc_key_id}" \
MURALUME_ASC_ISSUER_ID="${doctor_asc_issuer_id}" \
MURALUME_ASC_PRIVATE_KEY_PATH="${doctor_asc_private_key_path}" \
    validate_app_store_connect_credentials \
    || fail 'App Store Connect API credentials are not configured.'
doctor_work_directory="$(
    mktemp -d "${TMPDIR:-/tmp}/MuralumeReleaseDoctor.XXXXXX"
)"
chmod 700 "${doctor_work_directory}"
MURALUME_ASC_KEY_ID="${doctor_asc_key_id}" \
MURALUME_ASC_ISSUER_ID="${doctor_asc_issuer_id}" \
MURALUME_ASC_PRIVATE_KEY_PATH="${doctor_asc_private_key_path}" \
    app_store_connect_app_id \
    "${production_bundle_identifier:-com.muralume.Muralume}" \
    "${doctor_work_directory}" >/dev/null \
    || fail 'App Store Connect API cannot access the Muralume app.'
pass 'App Store Connect API authentication and app access passed'

run_release_doctor_developer_child \
    "${script_directory}/prepare_distribution_requirements.sh" \
    --check >/dev/null
pass 'Developer ID distribution requirement is valid'
run_release_doctor_app_store_child \
    "${script_directory}/release_app_store.sh" \
    --mode check >/dev/null
pass 'App Store automatic-signing preflight passed'

printf 'Release doctor passed for Muralume %s.\n' "${base_version}"
