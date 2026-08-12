#!/usr/bin/env bash

set -euo pipefail
umask 077

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly project_root="$(cd "${script_directory}/.." && pwd)"
readonly github_repository="${MURALUME_GITHUB_REPOSITORY:-MisakiHCL/Muralume}"
readonly managed_root="${project_root}/.build/muralume"
readonly workspace_parent="${managed_root}/workspaces"
readonly lock_directory="${managed_root}/locks"
readonly release_lock_path="${lock_directory}/release.lock"
readonly release_dmg_path="${project_root}/dist/macos-release/Muralume.dmg"
readonly release_checksum_path="${release_dmg_path}.sha256"
readonly release_provenance_asset_name="Muralume.release-provenance"
export MURALUME_ASC_FORBIDDEN_ROOT="${project_root}"

dual_developer_id_application="${MURALUME_DEVELOPER_ID_APPLICATION:-}"
dual_notary_keychain_profile="${MURALUME_NOTARY_KEYCHAIN_PROFILE:-}"
dual_expected_team_identifier="${MURALUME_EXPECTED_TEAM_IDENTIFIER:-}"
dual_asc_key_id="${MURALUME_ASC_KEY_ID:-}"
dual_asc_issuer_id="${MURALUME_ASC_ISSUER_ID:-}"
dual_asc_private_key_path="${MURALUME_ASC_PRIVATE_KEY_PATH:-}"
dual_gh_token="${GH_TOKEN:-}"
dual_github_token="${GITHUB_TOKEN:-}"

# shellcheck source=lib/app_store_connect_api.sh
source "${script_directory}/lib/app_store_connect_api.sh"
# shellcheck source=lib/build_cache.sh
source "${script_directory}/lib/build_cache.sh"
# shellcheck source=lib/release_provenance.sh
source "${script_directory}/lib/release_provenance.sh"
# shellcheck source=lib/release_source_snapshot.sh
source "${script_directory}/lib/release_source_snapshot.sh"
# shellcheck source=lib/release_gate_receipt.sh
source "${script_directory}/lib/release_gate_receipt.sh"

release_title="${RELEASE_TITLE:-}"
release_notes_path="${RELEASE_NOTES_FILE:-}"
selected_mode="release"
work_directory=""
source_checkout_path=""
source_checkout_registered=0
original_arguments=("$@")
remote_tag_object=""

# Give GitHub credentials only to the GitHub CLI, never to git, Xcode, Apple
# API helpers, or build phases.
gh() {
    if [[ -n "${dual_gh_token}" ]]; then
        GH_TOKEN="${dual_gh_token}" command gh "$@"
    elif [[ -n "${dual_github_token}" ]]; then
        GITHUB_TOKEN="${dual_github_token}" command gh "$@"
    else
        command gh "$@"
    fi
}

print_usage() {
    cat <<'EOF'
Usage:
  make release-dual [RELEASE_TITLE='...'] [RELEASE_NOTES_FILE=/absolute/path]
  make release-status

The dual workflow runs one immutable release gate, publishes the notarized
Developer ID DMG and checksum, uploads the matching App Store build, pushes an
annotated tag, creates the final GitHub Release, and verifies both endpoints.
It is safe to resume after a GitHub-only failure when the matching TestFlight
upload receipt exists.
EOF
}

fail() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

require_command() {
    if [[ "$1" == 'gh' ]]; then
        type -P gh >/dev/null 2>&1 \
            || fail 'Required command is unavailable: gh'
    else
        command -v "$1" >/dev/null 2>&1 \
            || fail "Required command is unavailable: $1"
    fi
}

safe_remove_work_directory() {
    [[ -n "${work_directory}" && -f "${work_directory}/.muralume-workspace" ]] \
        || return 0
    local canonical_parent
    local canonical_work_directory
    canonical_parent="$(cd "${workspace_parent}" && pwd -P)"
    canonical_work_directory="$(cd "${work_directory}" && pwd -P)"
    case "${canonical_work_directory}" in
        "${canonical_parent}"/MuralumeDualRelease.*)
            rm -rf "${canonical_work_directory}"
            ;;
        *)
            printf 'Warning: refused to remove unexpected workspace %s.\n' \
                "${canonical_work_directory}" >&2
            ;;
    esac
}

cleanup() {
    local status="$?"
    set +e
    if [[ "${source_checkout_registered}" -eq 1 \
        || -n "${source_checkout_path}" ]]; then
        release_git -C "${project_root}" worktree remove --force \
            "${source_checkout_path}" >/dev/null 2>&1 || true
        release_git -C "${project_root}" worktree prune >/dev/null 2>&1 || true
    fi
    safe_remove_work_directory
    return "${status}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --title)
            [[ "$#" -ge 2 ]] || fail '--title requires a value.'
            release_title="$2"
            shift 2
            ;;
        --notes-file)
            [[ "$#" -ge 2 ]] || fail '--notes-file requires a value.'
            release_notes_path="$2"
            shift 2
            ;;
        --status)
            selected_mode="status"
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

for required_command in cmp cp gh git lockf openssl ps rg shasum xcodebuild; do
    require_command "${required_command}"
done

mkdir -p "${workspace_parent}" "${lock_directory}"
chmod 700 "${managed_root}" "${workspace_parent}" "${lock_directory}"

# Re-exec under a kernel-backed lock. lockf releases the lock even when the
# workflow is killed, so a stale PID file can never block a later release.
standalone_lock_parent_valid=0
if [[ "${MURALUME_RELEASE_LOCK_REEXEC_TOKEN:-}" =~ ^[[:xdigit:]]{64}$ ]]; then
    /usr/bin/lockf -t 0 "${release_lock_path}" /usr/bin/true >/dev/null 2>&1 \
        || standalone_lock_parent_valid=1
fi
if [[ "${MURALUME_RELEASE_LOCK_HELD:-0}" != "1" \
    || "${MURALUME_RELEASE_STANDALONE_LOCK_PATH:-}" \
        != "${release_lock_path}" \
    || "${standalone_lock_parent_valid}" -ne 1 ]]; then
    unset MURALUME_RELEASE_DUAL_CAPABILITY_PATH
    unset MURALUME_RELEASE_DUAL_CAPABILITY_TOKEN
    export MURALUME_RELEASE_LOCK_HELD=1
    export MURALUME_RELEASE_STANDALONE_LOCK_PATH="${release_lock_path}"
    export MURALUME_RELEASE_LOCK_REEXEC_TOKEN="$(openssl rand -hex 32)"
    set +e
    if [[ "${#original_arguments[@]}" -eq 0 ]]; then
        /usr/bin/lockf -t 0 -k "${release_lock_path}" \
            "${script_directory}/release_dual.sh"
    else
        /usr/bin/lockf -t 0 -k "${release_lock_path}" \
            "${script_directory}/release_dual.sh" "${original_arguments[@]}"
    fi
    lock_status="$?"
    set -e
    if [[ "${lock_status}" -eq 75 ]]; then
        fail 'Another Muralume test or release workflow holds the release lock.'
    fi
    exit "${lock_status}"
fi

unset MURALUME_RELEASE_LOCK_REEXEC_TOKEN
unset MURALUME_RELEASE_STANDALONE_LOCK_PATH
unset MURALUME_DEVELOPER_ID_APPLICATION
unset MURALUME_NOTARY_KEYCHAIN_PROFILE
unset MURALUME_EXPECTED_TEAM_IDENTIFIER
unset MURALUME_ASC_KEY_ID
unset MURALUME_ASC_ISSUER_ID
unset MURALUME_ASC_PRIVATE_KEY_PATH
unset GH_TOKEN
unset GITHUB_TOKEN

source_commit="$(release_git -C "${project_root}" rev-parse 'HEAD^{commit}')" \
    || fail 'Unable to capture the source commit.'
readonly source_commit
source_tree="$(release_git -C "${project_root}" rev-parse 'HEAD^{tree}')" \
    || fail 'Unable to capture the source tree.'
readonly source_tree
marketing_version="$(
    release_xcconfig_value_at_commit \
        "${project_root}" "${source_commit}" \
        Config/Base.xcconfig MARKETING_VERSION
)" || fail 'Unable to read the Developer ID marketing version.'
readonly marketing_version
developer_id_build="$(
    release_xcconfig_value_at_commit \
        "${project_root}" "${source_commit}" \
        Config/Base.xcconfig CURRENT_PROJECT_VERSION
)" || fail 'Unable to read the Developer ID build number.'
readonly developer_id_build
app_store_version="$(
    release_xcconfig_value_at_commit \
        "${project_root}" "${source_commit}" \
        Config/AppStore.xcconfig MARKETING_VERSION
)" || fail 'Unable to read the App Store marketing version.'
readonly app_store_version
app_store_build="$(
    release_xcconfig_value_at_commit \
        "${project_root}" "${source_commit}" \
        Config/AppStore.xcconfig CURRENT_PROJECT_VERSION
)" || fail 'Unable to read the App Store build number.'
readonly app_store_build
readonly release_tag="v${marketing_version}"
readonly upload_receipt_path="${project_root}/dist/app-store/Muralume-${app_store_version}-${app_store_build}-upload.txt"
readonly release_manifest_path="${project_root}/dist/releases/${release_tag}.manifest"

[[ "${marketing_version}" == "${app_store_version}" ]] \
    || fail 'Developer ID and App Store marketing versions differ.'
[[ "${developer_id_build}" =~ ^[0-9]+$ \
    && "${app_store_build}" =~ ^[0-9]+$ \
    && "${app_store_build}" -gt "${developer_id_build}" ]] \
    || fail 'The App Store build must be newer than the Developer ID build.'
if [[ -n "${release_notes_path}" \
    && "${release_notes_path}" != /* ]]; then
    release_notes_path="${project_root}/${release_notes_path}"
fi
[[ -z "${release_notes_path}" \
    || (-f "${release_notes_path}" && ! -L "${release_notes_path}") ]] \
    || fail 'The release notes path must be a regular file.'
[[ -n "${release_title}" ]] \
    || release_title="Muralume ${release_tag}"

remote_tag_records="$(
    release_git -C "${project_root}" ls-remote origin \
        "refs/tags/${release_tag}" \
        "refs/tags/${release_tag}^{}"
)" || fail "Unable to inspect the remote ${release_tag} before release."
if [[ -n "${remote_tag_records}" ]]; then
    remote_tag_object="$(
        printf '%s\n' "${remote_tag_records}" \
            | awk -v tag="refs/tags/${release_tag}" \
                '$2 == tag { print $1; exit }'
    )"
    remote_tag_commit="$(
        printf '%s\n' "${remote_tag_records}" \
            | awk -v peeled="refs/tags/${release_tag}^{}" \
                '$2 == peeled { print $1; found = 1 } \
                 END { if (!found) exit 1 }'
    )" || remote_tag_commit="$(
        printf '%s\n' "${remote_tag_records}" \
            | awk -v tag="refs/tags/${release_tag}" \
                '$2 == tag { print $1; exit }'
    )"
    [[ "${remote_tag_commit}" == "${source_commit}" ]] \
        || fail "Remote ${release_tag} points to a different source commit."
fi

release_manifest_digest=""
durable_testflight_provenance=0
local_tag_has_full_provenance=0
local_tag_needs_replacement=0
if [[ -f "${release_manifest_path}" && ! -L "${release_manifest_path}" ]]; then
    release_provenance_read "${release_manifest_path}" \
        || fail 'The local release manifest is invalid.'
    release_provenance_matches \
        "${source_commit}" "${source_tree}" '' \
        "${app_store_version}" "${app_store_build}" \
        || fail 'The local release manifest does not match this source/build.'
    release_manifest_digest="${MURALUME_PROVENANCE_DMG_SHA256}"
fi

local_tag_object="$(
    release_git -C "${project_root}" rev-parse \
        "refs/tags/${release_tag}" 2>/dev/null || true
)"
if [[ -n "${remote_tag_object}" ]]; then
    if [[ "${local_tag_object}" != "${remote_tag_object}" ]]; then
        release_git -C "${project_root}" fetch --no-tags --force origin \
            "refs/tags/${release_tag}:refs/tags/${release_tag}" >/dev/null \
            || fail "Unable to fetch remote ${release_tag}."
    fi
fi
if release_git -C "${project_root}" cat-file -e \
    "refs/tags/${release_tag}^{tag}" 2>/dev/null; then
    release_tag_message="$(
        release_git -C "${project_root}" cat-file tag \
            "refs/tags/${release_tag}" \
            | sed '1,/^$/d'
    )"
    tag_manifest_commit="$(printf '%s\n' "${release_tag_message}" | sed -n 's/^Muralume-Source-Commit: //p')"
    tag_manifest_tree="$(printf '%s\n' "${release_tag_message}" | sed -n 's/^Muralume-Source-Tree: //p')"
    tag_manifest_digest="$(printf '%s\n' "${release_tag_message}" | sed -n 's/^Muralume-DMG-SHA256: //p')"
    tag_manifest_app_version="$(printf '%s\n' "${release_tag_message}" | sed -n 's/^Muralume-App-Store-Version: //p')"
    tag_manifest_app_build="$(printf '%s\n' "${release_tag_message}" | sed -n 's/^Muralume-App-Store-Build: //p')"
    if [[ -n "${tag_manifest_commit}" || -n "${tag_manifest_digest}" ]]; then
        [[ "${tag_manifest_commit}" == "${source_commit}" \
            && "${tag_manifest_digest}" =~ ^[[:xdigit:]]{64}$ ]] \
            || fail 'The release tag contains invalid provenance.'
        if [[ -n "${tag_manifest_tree}" \
            || -n "${tag_manifest_app_version}" \
            || -n "${tag_manifest_app_build}" ]]; then
            [[ "${tag_manifest_tree}" == "${source_tree}" \
                && "${tag_manifest_app_version}" == "${app_store_version}" \
                && "${tag_manifest_app_build}" == "${app_store_build}" ]] \
                || fail 'The release tag App Store provenance is invalid.'
            local_tag_has_full_provenance=1
            [[ -z "${remote_tag_object}" ]] \
                || durable_testflight_provenance=1
        fi
        if [[ -n "${release_manifest_digest}" \
            && "${release_manifest_digest}" != "${tag_manifest_digest}" ]]; then
            fail 'The local and tag release manifests disagree.'
        fi
        release_manifest_digest="${tag_manifest_digest}"
    fi
fi
if [[ -n "${local_tag_object}" ]]; then
    local_tag_commit="$(
        release_git -C "${project_root}" rev-parse \
            "refs/tags/${release_tag}^{commit}"
    )" || fail "Unable to resolve local ${release_tag}."
    [[ "${local_tag_commit}" == "${source_commit}" ]] \
        || fail "Local ${release_tag} points to a different source commit."
    if [[ -z "${remote_tag_object}" \
        && "${local_tag_has_full_provenance}" -ne 1 ]]; then
        local_tag_needs_replacement=1
    fi
fi

receipt_value() {
    local receipt_path="$1"
    local key="$2"
    local value
    value="$(sed -n "s/^${key}=//p" "${receipt_path}")" || return 1
    [[ -n "${value}" && "${value}" != *$'\n'* ]] || return 1
    printf '%s\n' "${value}"
}

release_checksum_digest() {
    [[ "$#" -eq 1 ]] || return 64
    local checksum_source_path="$1"
    [[ -f "${checksum_source_path}" && ! -L "${checksum_source_path}" \
        && "$(wc -l <"${checksum_source_path}" | tr -d '[:space:]')" == '1' ]] \
        || return 1
    LC_ALL=C /usr/bin/grep -E \
        '^[0-9a-f]{64}  Muralume\.dmg$' "${checksum_source_path}" \
        >/dev/null || return 1
    awk '{ print $1 }' "${checksum_source_path}"
}

has_matching_upload_receipt() {
    [[ -f "${upload_receipt_path}" && ! -L "${upload_receipt_path}" \
        && "$(stat -f '%Lp' "${upload_receipt_path}")" == '600' ]] \
        || return 1
    [[ "$(receipt_value "${upload_receipt_path}" product)" == 'Muralume' \
        && "$(receipt_value "${upload_receipt_path}" marketing_version)" \
            == "${app_store_version}" \
        && "$(receipt_value "${upload_receipt_path}" build_number)" \
            == "${app_store_build}" \
        && "$(receipt_value "${upload_receipt_path}" source_commit)" \
            == "${source_commit}" \
        && "$(receipt_value "${upload_receipt_path}" source_tree)" \
            == "${source_tree}" ]]
}

local_release_assets_valid=0
local_release_digest=""
inspect_local_release_assets() {
    local_release_assets_valid=0
    local_release_digest=""
    [[ -f "${release_dmg_path}" && ! -L "${release_dmg_path}" \
        && -f "${release_checksum_path}" \
        && ! -L "${release_checksum_path}" ]] || return 0
    local_release_digest="$(
        release_checksum_digest "${release_checksum_path}"
    )" || return 0
    [[ "${local_release_digest}" =~ ^[[:xdigit:]]{64}$ \
        && "$(shasum -a 256 "${release_dmg_path}" | awk '{ print $1 }')" \
            == "${local_release_digest}" ]] || return 0
    if [[ -n "${release_manifest_digest}" \
        && "${release_manifest_digest}" != "${local_release_digest}" ]]; then
        return 0
    fi
    local_release_assets_valid=1
}
inspect_local_release_assets

github_release_exists=0
github_release_identity_valid=0
github_release_is_draft=0
github_release_assets=""
github_release_assets_exact=0
github_release_assets_valid=0
github_release_asset_policy_valid=0
github_release_is_complete=0
github_release_url=""
github_release_digest=""
github_release_has_provenance=0
inspect_github_release() {
    local release_fields
    local release_error_path="${work_directory}/github-release-view.error"
    local latest_tag
    local remote_tag_commit
    local expected_asset_digest
    local remote_checksum_digest
    local downloaded_directory="${work_directory}/GitHubAssets"
    local remote_dmg_digest
    local remote_provenance_path

    if ! release_fields="$(
        gh release view "${release_tag}" --repo "${github_repository}" \
            --json tagName,isDraft,isPrerelease,url \
            --jq '[.tagName, .isDraft, .isPrerelease, .url] | @tsv' \
            2>"${release_error_path}"
    )"; then
        if rg -q '(HTTP 404|release not found|not found)' \
            "${release_error_path}"; then
            return 0
        fi
        printf '%s\n' 'GitHub Release inspection failed before publication.' >&2
        return 1
    fi
    github_release_exists=1
    IFS=$'\t' read -r remote_tag remote_draft remote_prerelease \
        github_release_url <<<"${release_fields}"
    [[ "${remote_tag}" == "${release_tag}" ]] || return 0
    [[ "${remote_draft}" != 'true' ]] || github_release_is_draft=1
    remote_tag_commit="$(
        gh api "repos/${github_repository}/commits/${release_tag}" --jq '.sha'
    )" || return 1
    [[ "${remote_tag_commit}" == "${source_commit}" ]] || return 0
    github_release_identity_valid=1

    github_release_assets="$(
        gh release view "${release_tag}" --repo "${github_repository}" \
            --json assets --jq '.assets[].name' | sort
    )" || return 1
    if [[ -n "${github_release_assets}" ]]; then
        if printf '%s\n' "${github_release_assets}" \
            | /usr/bin/grep -E -v \
                '^(Muralume\.dmg|Muralume\.dmg\.sha256|Muralume\.release-provenance)$' \
                >/dev/null; then
            return 0
        fi
        [[ "$(printf '%s\n' "${github_release_assets}" | wc -l \
            | tr -d '[:space:]')" \
            == "$(printf '%s\n' "${github_release_assets}" | sort -u \
                | wc -l | tr -d '[:space:]')" ]] || return 0
    fi
    github_release_asset_policy_valid=1
    [[ -n "${github_release_assets}" ]] || {
        github_release_assets_valid=1
        return 0
    }
    mkdir -p "${downloaded_directory}"
    if printf '%s\n' "${github_release_assets}" \
        | rg -x 'Muralume\.release-provenance' >/dev/null; then
        gh release download "${release_tag}" --repo "${github_repository}" \
            --dir "${downloaded_directory}" \
            --pattern 'Muralume.release-provenance' >/dev/null || return 1
        remote_provenance_path="${downloaded_directory}/${release_provenance_asset_name}"
        chmod 600 "${remote_provenance_path}" || return 1
        release_provenance_read "${remote_provenance_path}" || return 0
        release_provenance_matches \
            "${source_commit}" "${source_tree}" '' \
            "${app_store_version}" "${app_store_build}" || return 0
        if [[ -n "${release_manifest_digest}" \
            && "${release_manifest_digest}" \
                != "${MURALUME_PROVENANCE_DMG_SHA256}" ]]; then
            return 0
        fi
        release_manifest_digest="${MURALUME_PROVENANCE_DMG_SHA256}"
        durable_testflight_provenance=1
        github_release_has_provenance=1
    fi
    if printf '%s\n' "${github_release_assets}" \
        | rg -x 'Muralume\.dmg\.sha256' >/dev/null; then
        gh release download "${release_tag}" --repo "${github_repository}" \
            --dir "${downloaded_directory}" \
            --pattern 'Muralume.dmg.sha256' >/dev/null || return 1
        remote_checksum_digest="$(
            release_checksum_digest \
                "${downloaded_directory}/Muralume.dmg.sha256"
        )" || return 0
        [[ "${remote_checksum_digest}" =~ ^[[:xdigit:]]{64}$ ]] || return 0
    fi
    if printf '%s\n' "${github_release_assets}" \
        | rg -x 'Muralume\.dmg' >/dev/null; then
        gh release download "${release_tag}" --repo "${github_repository}" \
            --dir "${downloaded_directory}" \
            --pattern 'Muralume.dmg' >/dev/null || return 1
        remote_dmg_digest="$(
            shasum -a 256 "${downloaded_directory}/Muralume.dmg" \
                | awk '{ print $1 }'
        )"
        [[ "${remote_dmg_digest}" =~ ^[[:xdigit:]]{64}$ ]] || return 0
    fi
    expected_asset_digest="${release_manifest_digest}"
    [[ -n "${expected_asset_digest}" \
        || "${local_release_assets_valid}" -ne 1 ]] \
        || expected_asset_digest="${local_release_digest}"
    # Never turn an untrusted partial upload into its own provenance. Recovery
    # requires a digest already pinned by the tag/local manifest or by the
    # original locally verified signed asset pair.
    [[ "${expected_asset_digest}" =~ ^[[:xdigit:]]{64}$ ]] || return 0
    [[ -z "${remote_checksum_digest}" \
        || "${remote_checksum_digest}" == "${expected_asset_digest}" ]] \
        || return 0
    [[ -z "${remote_dmg_digest}" \
        || "${remote_dmg_digest}" == "${expected_asset_digest}" ]] \
        || return 0
    github_release_digest="${expected_asset_digest}"
    if [[ -n "${release_manifest_digest}" \
        && "${release_manifest_digest}" != "${github_release_digest}" ]]; then
        return 0
    fi
    release_manifest_digest="${github_release_digest}"
    [[ "${github_release_assets}" \
        == $'Muralume.dmg\nMuralume.dmg.sha256\nMuralume.release-provenance' ]] \
        || {
            github_release_assets_valid=1
            return 0
        }
    github_release_assets_exact=1
    github_release_assets_valid=1

    [[ "${remote_draft}" == 'false' \
        && "${remote_prerelease}" == 'false' ]] || return 0
    latest_tag="$(
        gh api "repos/${github_repository}/releases/latest" --jq '.tag_name'
    )" || return 1
    [[ "${latest_tag}" == "${release_tag}" ]] || return 0
    github_release_is_complete=1
}

reset_github_release_state() {
    github_release_exists=0
    github_release_identity_valid=0
    github_release_is_draft=0
    github_release_assets=""
    github_release_assets_exact=0
    github_release_assets_valid=0
    github_release_asset_policy_valid=0
    github_release_is_complete=0
    github_release_url=""
    github_release_digest=""
    github_release_has_provenance=0
    rm -rf "${work_directory}/GitHubAssets"
}

create_github_draft_release_if_missing() {
    [[ "${github_release_exists}" -eq 0 ]] || return 0
    local -a create_arguments
    create_arguments=(
        release create "${release_tag}"
        --repo "${github_repository}"
        --title "${release_title}"
        --verify-tag
        --draft
    )
    if [[ -n "${release_notes_path}" ]]; then
        create_arguments+=(--notes-file "${release_notes_path}")
    else
        create_arguments+=(--generate-notes)
    fi
    gh "${create_arguments[@]}" || return 1
    github_release_exists=1
    github_release_is_draft=1
    github_release_assets=""
}

work_directory="$(
    mktemp -d "${workspace_parent}/MuralumeDualRelease.XXXXXX"
)"
chmod 700 "${work_directory}"
{
    printf 'schema=1\n'
    printf 'repository=%s\n' "${project_root}"
} >"${work_directory}/.muralume-workspace"
chmod 600 "${work_directory}/.muralume-workspace"
readonly gate_capability_path="${work_directory}/release-dual.capability"
release_dual_capability_token="$(openssl rand -hex 32)"
{
    printf 'token=%s\n' "${release_dual_capability_token}"
    printf 'orchestrator_pid=%s\n' "$$"
    printf 'source_commit=%s\n' "${source_commit}"
    printf 'source_tree=%s\n' "${source_tree}"
} >"${gate_capability_path}"
chmod 600 "${gate_capability_path}"

inspect_github_release \
    || fail 'Unable to establish the current GitHub Release state.'
testflight_state="UNKNOWN"
testflight_remote_present=0
upload_complete=0
local_upload_receipt_matches=0
has_matching_upload_receipt && local_upload_receipt_matches=1
refresh_testflight_state() {
    testflight_state="$(
        MURALUME_ASC_KEY_ID="${dual_asc_key_id}" \
        MURALUME_ASC_ISSUER_ID="${dual_asc_issuer_id}" \
        MURALUME_ASC_PRIVATE_KEY_PATH="${dual_asc_private_key_path}" \
            app_store_connect_testflight_build_state \
            'com.muralume.Muralume' \
            "${app_store_version}" \
            "${app_store_build}" \
            "${work_directory}"
    )" || return 1
    case "${testflight_state}" in
        VALID)
            testflight_remote_present=1
            if has_matching_upload_receipt \
                || [[ "${durable_testflight_provenance}" -eq 1 ]]; then
                upload_complete=1
            else
                upload_complete=0
            fi
            ;;
        PROCESSING)
            testflight_remote_present=1
            upload_complete=0
            ;;
        MISSING)
            testflight_remote_present=0
            upload_complete=0
            ;;
        FAILED|INVALID|UNKNOWN)
            testflight_remote_present=1
            upload_complete=0
            ;;
        *)
            fail "App Store Connect returned an unsupported build state: ${testflight_state}"
            ;;
    esac
}

MURALUME_ASC_KEY_ID="${dual_asc_key_id}" \
MURALUME_ASC_ISSUER_ID="${dual_asc_issuer_id}" \
MURALUME_ASC_PRIVATE_KEY_PATH="${dual_asc_private_key_path}" \
    validate_app_store_connect_credentials \
    || fail 'Configure the App Store Connect API key before release/status.'
refresh_testflight_state \
    || fail 'Unable to verify the TestFlight build remotely.'

if [[ "${selected_mode}" == "status" ]]; then
    printf 'Source: %s (%s)\n' "${source_commit}" "${source_tree}"
    printf 'Version: %s (Developer ID %s, App Store %s)\n' \
        "${marketing_version}" "${developer_id_build}" "${app_store_build}"
    if [[ "${upload_complete}" -eq 1 ]]; then
        printf '[PASS] TestFlight build exists remotely (%s) with matching provenance receipt\n' \
            "${testflight_state}"
    elif [[ "${testflight_remote_present}" -eq 1 ]]; then
        printf '[BLOCKED] TestFlight build exists remotely (%s), but local source provenance is unverified\n' \
            "${testflight_state}"
    else
        printf '[MISS] TestFlight build does not exist remotely\n'
    fi
    [[ "${github_release_is_complete}" -eq 1 ]] \
        && printf '[PASS] Final latest GitHub Release: %s\n' \
            "${github_release_url}" \
        || printf '[MISS] Complete latest GitHub Release\n'
    [[ "${upload_complete}" -eq 1 \
        && "${github_release_is_complete}" -eq 1 ]]
    exit
fi

MURALUME_RELEASE_DUAL_CAPABILITY_PATH="${gate_capability_path}" \
MURALUME_RELEASE_DUAL_CAPABILITY_TOKEN="${release_dual_capability_token}" \
MURALUME_DEVELOPER_ID_APPLICATION="${dual_developer_id_application}" \
MURALUME_NOTARY_KEYCHAIN_PROFILE="${dual_notary_keychain_profile}" \
MURALUME_EXPECTED_TEAM_IDENTIFIER="${dual_expected_team_identifier}" \
MURALUME_ASC_KEY_ID="${dual_asc_key_id}" \
MURALUME_ASC_ISSUER_ID="${dual_asc_issuer_id}" \
MURALUME_ASC_PRIVATE_KEY_PATH="${dual_asc_private_key_path}" \
GH_TOKEN="${dual_gh_token}" \
GITHUB_TOKEN="${dual_github_token}" \
    "${script_directory}/release_doctor.sh"

if [[ "${upload_complete}" -eq 1 \
    && "${github_release_is_complete}" -eq 1 ]]; then
    printf 'Muralume %s is already fully published.\n' "${marketing_version}"
    printf 'GitHub Release: %s\n' "${github_release_url}"
    exit 0
fi
if [[ "${testflight_remote_present}" -eq 1 \
    && "${upload_complete}" -eq 0 \
    && "${testflight_state}" != 'PROCESSING' ]]; then
    fail 'This TestFlight build number already exists, but its local source receipt is missing/mismatched or processing failed. Do not upload it again.'
fi
if [[ "${testflight_remote_present}" -eq 0 \
    && "${local_upload_receipt_matches}" -eq 1 ]]; then
    fail 'A matching upload acceptance receipt exists, but App Store Connect does not yet show the build. Do not retry this build number; wait and run release-status.'
fi
if [[ "${testflight_state}" == 'PROCESSING' ]]; then
    fail 'The TestFlight build is still processing. Wait and run release-status; it is not yet a complete publication.'
fi
if [[ "${github_release_exists}" -eq 1 \
    && "${github_release_identity_valid}" -eq 0 ]]; then
    fail 'The existing GitHub Release tag does not resolve to this source commit.'
fi
github_release_is_legacy_pair=0
[[ "${github_release_assets}" == $'Muralume.dmg\nMuralume.dmg.sha256' \
    && "${github_release_assets_valid}" -eq 1 \
    && "${github_release_has_provenance}" -eq 0 ]] \
    && github_release_is_legacy_pair=1
if [[ "${github_release_exists}" -eq 1 \
    && "${github_release_is_draft}" -eq 0 \
    && ("${github_release_assets_exact}" -ne 1 \
        || "${github_release_assets_valid}" -ne 1) \
    && "${github_release_is_legacy_pair}" -ne 1 ]]; then
    fail 'An already-public GitHub Release is incomplete or invalid; refusing to mutate it automatically.'
fi

github_side_complete="${github_release_is_complete}"
github_assets_ready=0
[[ "${github_release_assets_exact}" -eq 1 \
    && "${github_release_assets_valid}" -eq 1 ]] \
    && github_assets_ready=1
if [[ "${github_release_exists}" -eq 1 \
    && "${github_release_asset_policy_valid}" -eq 0 ]]; then
    fail 'The existing GitHub Release contains unsupported/extra assets; refusing to publish it.'
fi
if [[ -n "${github_release_assets}" \
    && "${github_release_assets_valid}" -eq 0 ]]; then
    fail 'The existing GitHub Release assets fail checksum/source verification; refusing to overwrite public artifacts.'
fi

developer_id_assets_ready=0
github_upload_dmg_path="${release_dmg_path}"
github_upload_checksum_path="${release_checksum_path}"
if [[ "${github_assets_ready}" -eq 1 ]]; then
    developer_id_assets_ready=1
elif [[ "${github_release_is_legacy_pair}" -eq 1 ]]; then
    developer_id_assets_ready=1
elif [[ "${github_release_assets}" == 'Muralume.dmg' ]]; then
    github_upload_checksum_path="${work_directory}/Muralume.dmg.sha256"
    printf '%s  Muralume.dmg\n' "${github_release_digest}" \
        >"${github_upload_checksum_path}"
    chmod 600 "${github_upload_checksum_path}"
    developer_id_assets_ready=1
elif [[ "${github_release_assets}" == 'Muralume.dmg.sha256' ]]; then
    [[ "${local_release_assets_valid}" -eq 1 \
        && "${local_release_digest}" == "${github_release_digest}" ]] \
        || fail 'The draft contains only a checksum and the matching signed DMG is unavailable; refusing a nondeterministic rebuild.'
    developer_id_assets_ready=1
elif [[ -n "${release_manifest_digest}" ]]; then
    [[ "${local_release_assets_valid}" -eq 1 \
        && "${local_release_digest}" == "${release_manifest_digest}" ]] \
        || fail 'Immutable release provenance exists but its original signed DMG is unavailable; refusing to rebuild different bytes.'
    developer_id_assets_ready=1
fi

readonly source_checkout_parent="${managed_root}/checkouts/release-dual"
mkdir -p "${source_checkout_parent}"
chmod 700 "${managed_root}/checkouts" "${source_checkout_parent}"
source_checkout_path="${source_checkout_parent}/Source"
release_reclaim_managed_worktree "${project_root}" "${source_checkout_path}" \
    || fail 'Unable to reclaim a stale dual-release source checkout.'
release_git -C "${project_root}" worktree add --detach \
    "${source_checkout_path}" "${source_commit}" >/dev/null \
    || fail 'Unable to create the shared release-gate source snapshot.'
source_checkout_registered=1
verify_release_source_snapshot \
    "${source_checkout_path}" "${source_commit}" "${source_tree}" \
    || fail 'The shared release-gate source snapshot is invalid.'

readonly gate_artifacts_path="${work_directory}/GateArtifacts"
gate_derived_data_path="$(
    muralume_prepare_xcode_cache "${project_root}" release-gate
)" || fail 'Unable to prepare the shared release-gate cache.'
readonly gate_derived_data_path
readonly gate_receipt_path="${work_directory}/release-gate.txt"
printf 'Running the shared release gate for %s...\n' "${source_commit}"
env \
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
    MURALUME_TEST_ARTIFACTS_DIR="${gate_artifacts_path}" \
    MURALUME_TEST_DERIVED_DATA_DIR="${gate_derived_data_path}" \
    "${source_checkout_path}/Scripts/verify.sh" release-gate
verify_release_source_snapshot \
    "${source_checkout_path}" "${source_commit}" "${source_tree}" \
    || fail 'The source changed during the shared release gate.'
write_release_gate_receipt \
    "${gate_receipt_path}" "${project_root}" "${source_commit}" "${source_tree}" \
    || fail 'Unable to write the shared release-gate receipt.'

release_git -C "${project_root}" worktree remove --force \
    "${source_checkout_path}" >/dev/null \
    || fail 'Unable to unregister the shared release-gate source snapshot.'
source_checkout_registered=0
source_checkout_path=""

if [[ "${github_side_complete}" -eq 1 \
    || "${developer_id_assets_ready}" -eq 1 ]]; then
    printf 'Verified GitHub assets already exist; Developer ID build will not be repeated.\n'
else
    MURALUME_RELEASE_DUAL_CAPABILITY_PATH="${gate_capability_path}" \
    MURALUME_RELEASE_DUAL_CAPABILITY_TOKEN="${release_dual_capability_token}" \
    MURALUME_DEVELOPER_ID_APPLICATION="${dual_developer_id_application}" \
    MURALUME_NOTARY_KEYCHAIN_PROFILE="${dual_notary_keychain_profile}" \
    MURALUME_EXPECTED_TEAM_IDENTIFIER="${dual_expected_team_identifier}" \
        "${script_directory}/prepare_distribution_requirements.sh" --check
    MURALUME_RELEASE_DUAL_CAPABILITY_PATH="${gate_capability_path}" \
    MURALUME_RELEASE_DUAL_CAPABILITY_TOKEN="${release_dual_capability_token}" \
    MURALUME_DEVELOPER_ID_APPLICATION="${dual_developer_id_application}" \
    MURALUME_NOTARY_KEYCHAIN_PROFILE="${dual_notary_keychain_profile}" \
    MURALUME_EXPECTED_TEAM_IDENTIFIER="${dual_expected_team_identifier}" \
        "${script_directory}/release_macos.sh" \
        --mode distribution \
        --output "${release_dmg_path}" \
        --gate-receipt "${gate_receipt_path}" \
        --gate-capability "${gate_capability_path}"

    [[ -f "${release_dmg_path}" && -f "${release_checksum_path}" ]] \
        || fail 'The Developer ID release assets are missing.'
    (
        cd "$(dirname "${release_dmg_path}")"
        shasum -a 256 -c "$(basename "${release_checksum_path}")" >/dev/null
    ) || fail 'The Developer ID release checksum is invalid.'
fi

if [[ "${github_side_complete}" -eq 0 ]]; then
    if [[ "${developer_id_assets_ready}" -eq 0 ]]; then
        inspect_local_release_assets
        [[ "${local_release_assets_valid}" -eq 1 ]] \
            || fail 'The freshly built Developer ID release assets are invalid.'
        built_release_digest="${local_release_digest}"
    else
        built_release_digest="${github_release_digest:-${local_release_digest}}"
    fi
    [[ "${built_release_digest}" =~ ^[[:xdigit:]]{64}$ ]] \
        || fail 'The release asset digest is unavailable.'
    if [[ -n "${release_manifest_digest}" \
        && "${release_manifest_digest}" != "${built_release_digest}" ]]; then
        fail 'The rebuilt DMG differs from immutable release provenance; refusing to publish it.'
    fi
    release_manifest_digest="${built_release_digest}"
    release_provenance_write \
        "${release_manifest_path}" \
        "${source_commit}" "${source_tree}" "${release_manifest_digest}" \
        "${app_store_version}" "${app_store_build}" \
        || fail 'Unable to persist the durable release manifest.'
fi
github_upload_provenance_path="${work_directory}/${release_provenance_asset_name}"
if [[ -f "${release_manifest_path}" && ! -L "${release_manifest_path}" ]]; then
    cp "${release_manifest_path}" "${github_upload_provenance_path}" \
        || fail 'Unable to stage the release provenance asset.'
    chmod 600 "${github_upload_provenance_path}" \
        || fail 'Unable to secure the release provenance asset.'
fi

# Publish immutable provenance before the irreversible TestFlight upload. A
# crash or a cleaned local dist directory can then resume from the remote tag.
verify_clean_release_repository "${project_root}" \
    || fail 'The repository changed before release provenance was published.'
[[ "$(release_git -C "${project_root}" rev-parse 'HEAD^{commit}')" \
    == "${source_commit}" ]] \
    || fail 'HEAD changed before release provenance was published.'
if [[ -n "${remote_tag_object}" ]]; then
    if [[ "${local_tag_has_full_provenance}" -eq 1 ]]; then
        [[ "${release_manifest_digest}" =~ ^[[:xdigit:]]{64}$ ]] \
            || fail "Remote ${release_tag} has invalid release provenance."
    elif [[ "${github_release_has_provenance}" -ne 1 ]]; then
        [[ -f "${github_upload_provenance_path}" \
            && "${release_manifest_digest}" =~ ^[[:xdigit:]]{64}$ ]] \
            || fail "Remote ${release_tag} cannot be migrated without verified provenance."
        create_github_draft_release_if_missing \
            || fail 'Unable to create a private Release for provenance migration.'
        gh release upload "${release_tag}" \
            "${github_upload_provenance_path}" \
            --repo "${github_repository}" \
            || fail 'Unable to upload durable provenance for the legacy tag.'
        reset_github_release_state
        inspect_github_release \
            || fail 'Unable to verify migrated release provenance.'
        [[ "${github_release_has_provenance}" -eq 1 \
            && "${github_release_assets_valid}" -eq 1 ]] \
            || fail 'The migrated release provenance failed remote verification.'
        github_side_complete="${github_release_is_complete}"
    fi
    durable_testflight_provenance=1
elif [[ -n "${local_tag_object}" \
    && "${local_tag_needs_replacement}" -eq 0 ]]; then
    [[ "${local_tag_has_full_provenance}" -eq 1 \
        && "${release_manifest_digest}" =~ ^[[:xdigit:]]{64}$ ]] \
        || fail "Local ${release_tag} lacks durable release provenance."
else
    if [[ "${local_tag_needs_replacement}" -eq 1 ]]; then
        release_git -C "${project_root}" tag -d "${release_tag}" >/dev/null \
            || fail "Unable to replace unpublished local ${release_tag}."
    fi
    release_git -C "${project_root}" tag -a "${release_tag}" \
        -m "Muralume ${marketing_version}" \
        -m "Muralume-Source-Commit: ${source_commit}" \
        -m "Muralume-Source-Tree: ${source_tree}" \
        -m "Muralume-DMG-SHA256: ${release_manifest_digest}" \
        -m "Muralume-App-Store-Version: ${app_store_version}" \
        -m "Muralume-App-Store-Build: ${app_store_build}" \
        || fail "Unable to create annotated ${release_tag}."
    local_tag_has_full_provenance=1
fi
if [[ -z "${remote_tag_object}" ]]; then
    release_git -C "${project_root}" push --atomic origin \
        main "refs/tags/${release_tag}" \
        || fail "Unable to publish ${release_tag} provenance."
fi
durable_testflight_provenance=1

# Complete and verify the private GitHub transaction before TestFlight. The
# only operation deferred until Apple reports VALID is making this draft public.
if [[ "${github_side_complete}" -eq 0 ]]; then
    create_github_draft_release_if_missing \
        || fail 'Unable to create the draft GitHub Release.'
    if [[ "${github_release_is_draft}" -eq 0 ]]; then
        [[ "${github_release_assets_exact}" -eq 1 \
            && "${github_release_assets_valid}" -eq 1 ]] \
            || fail 'An already-public GitHub Release cannot be repaired automatically.'
    else
        if ! printf '%s\n' "${github_release_assets}" \
            | rg -x 'Muralume\.dmg' >/dev/null; then
            gh release upload "${release_tag}" "${github_upload_dmg_path}" \
                --repo "${github_repository}"
        fi
        if ! printf '%s\n' "${github_release_assets}" \
            | rg -x 'Muralume\.dmg\.sha256' >/dev/null; then
            gh release upload "${release_tag}" "${github_upload_checksum_path}" \
                --repo "${github_repository}"
        fi
        if ! printf '%s\n' "${github_release_assets}" \
            | rg -x 'Muralume\.release-provenance' >/dev/null; then
            [[ -f "${github_upload_provenance_path}" ]] \
                || fail 'The release provenance upload asset is missing.'
            gh release upload "${release_tag}" \
                "${github_upload_provenance_path}" \
                --repo "${github_repository}"
        fi
        reset_github_release_state
        inspect_github_release \
            || fail 'Unable to verify the draft GitHub Release assets.'
        [[ "${github_release_exists}" -eq 1 \
            && "${github_release_identity_valid}" -eq 1 \
            && "${github_release_is_draft}" -eq 1 \
            && "${github_release_assets_exact}" -eq 1 \
            && "${github_release_assets_valid}" -eq 1 ]] \
            || fail 'The draft GitHub Release is incomplete; it will remain private.'
    fi
fi

if [[ "${upload_complete}" -eq 1 ]]; then
    printf 'Matching TestFlight receipt found; upload will not be repeated.\n'
else
    MURALUME_RELEASE_DUAL_CAPABILITY_PATH="${gate_capability_path}" \
    MURALUME_RELEASE_DUAL_CAPABILITY_TOKEN="${release_dual_capability_token}" \
    MURALUME_ASC_KEY_ID="${dual_asc_key_id}" \
    MURALUME_ASC_ISSUER_ID="${dual_asc_issuer_id}" \
    MURALUME_ASC_PRIVATE_KEY_PATH="${dual_asc_private_key_path}" \
        "${script_directory}/release_app_store.sh" \
        --mode upload \
        --gate-receipt "${gate_receipt_path}" \
        --gate-capability "${gate_capability_path}"
    poll_attempt=0
    poll_limit="${MURALUME_ASC_BUILD_POLL_ATTEMPTS:-40}"
    [[ "${poll_limit}" =~ ^[0-9]+$ && "${poll_limit}" -gt 0 ]] \
        || fail 'MURALUME_ASC_BUILD_POLL_ATTEMPTS must be a positive integer.'
    while [[ "${poll_attempt}" -lt "${poll_limit}" ]]; do
        poll_attempt=$((poll_attempt + 1))
        refresh_testflight_state \
            || fail 'Unable to confirm the uploaded TestFlight build remotely.'
        [[ "${testflight_state}" != 'VALID' \
            && "${testflight_state}" != 'FAILED' \
            && "${testflight_state}" != 'INVALID' ]] || break
        sleep 15
    done
    [[ "${upload_complete}" -eq 1 ]] \
        || fail 'The upload returned, but App Store Connect did not confirm a matching build and provenance receipt. Do not retry this build number until its remote state is checked.'
fi

refresh_testflight_state \
    || fail 'Unable to perform the final TestFlight remote verification.'
[[ "${testflight_state}" == 'VALID' && "${upload_complete}" -eq 1 ]] \
    || fail 'TestFlight is not VALID with matching source provenance; the dual release is incomplete.'

if [[ "${github_side_complete}" -eq 0 ]]; then
    if [[ "${github_release_is_draft}" -eq 0 ]]; then
        gh release edit "${release_tag}" \
            --repo "${github_repository}" \
            --title "${release_title}" \
            --prerelease=false \
            --latest \
            --verify-tag
        github_side_complete=1
    fi
fi

if [[ "${github_side_complete}" -eq 0 ]]; then
    release_edit_arguments=(
        release edit "${release_tag}"
        --repo "${github_repository}"
        --title "${release_title}"
        --draft=false
        --prerelease=false
        --latest
        --verify-tag
    )
    if [[ -n "${release_notes_path}" ]]; then
        release_edit_arguments+=(--notes-file "${release_notes_path}")
    fi
    gh "${release_edit_arguments[@]}"
fi

refresh_testflight_state \
    || fail 'Unable to verify TestFlight after GitHub publication.'
[[ "${testflight_state}" == 'VALID' && "${upload_complete}" -eq 1 ]] \
    || fail 'TestFlight stopped being VALID before the release completed.'

reset_github_release_state
inspect_github_release \
    || fail 'Unable to re-read the GitHub Release after publication.'
[[ "${github_release_is_complete}" -eq 1 ]] \
    || fail 'The final GitHub Release failed post-publication verification.'

printf '\nMuralume %s is fully published from %s.\n' \
    "${marketing_version}" "${source_commit}"
printf 'GitHub Release: %s\n' "${github_release_url}"
printf 'TestFlight build: %s (%s)\n' \
    "${app_store_version}" "${app_store_build}"
