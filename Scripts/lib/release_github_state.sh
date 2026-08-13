#!/usr/bin/env bash

# GitHub Release inspection and resumable draft creation for release_dual.sh.
# The caller supplies the authenticated gh wrapper and immutable release globals.

github_release_exists=0
github_release_identity_valid=0
github_release_is_draft=0
github_release_assets=''
github_release_assets_exact=0
github_release_assets_valid=0
github_release_asset_policy_valid=0
github_release_is_complete=0
github_release_url=''
github_release_digest=''
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
    github_release_assets=''
    github_release_assets_exact=0
    github_release_assets_valid=0
    github_release_asset_policy_valid=0
    github_release_is_complete=0
    github_release_url=''
    github_release_digest=''
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
    github_release_assets=''
}
