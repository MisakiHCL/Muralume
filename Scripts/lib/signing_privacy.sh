#!/usr/bin/env bash

# Static guard for signing material that must remain outside the public repo.

signing_privacy_value_is_indirect_or_empty() {
    local value="$1"

    value="${value%%#*}"
    if [[ "${value}" =~ ^(.*[^[:space:]])[[:space:]]+//.*$ ]]; then
        value="${BASH_REMATCH[1]}"
    fi
    value="${value%;}"
    value="${value%,}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    if [[ "${#value}" -ge 2 ]]; then
        case "${value}" in
            \"*\")
                value="${value:1:${#value}-2}"
                ;;
            \'*\')
                value="${value:1:${#value}-2}"
                ;;
        esac
    fi

    [[ -z "${value}" || "${value}" == "null" || "${value}" == "~" ]] \
        && return 0
    [[ "${value}" =~ ^\<[^\>]+\>$ ]] && return 0
    [[ "${value}" =~ ^(YOUR|EXAMPLE|REPLACE)_[A-Z0-9_]+$ ]] && return 0
    [[ "${value}" =~ ^\$\([A-Za-z_][A-Za-z0-9_.-]*\)$ ]] && return 0
    [[ "${value}" =~ ^\$\{[A-Za-z_][A-Za-z0-9_]*(:-)?\}$ ]] && return 0
    [[ "${value}" =~ ^\$[A-Za-z_][A-Za-z0-9_]*$ ]] && return 0
    [[ "${value}" =~ ^ENV\[[\"\'][A-Za-z_][A-Za-z0-9_]*[\"\']\]$ ]] \
        && return 0
    [[ "${value}" =~ ^ENV\.fetch\([\"\'][A-Za-z_][A-Za-z0-9_]*[\"\']\)$ ]] \
        && return 0

    return 1
}

signing_privacy_extract_assignment_value() {
    local line="$1"
    local key_pattern="$2"
    local assignment_pattern

    signing_privacy_matched_value=""

    assignment_pattern="(^|[[:space:]])(${key_pattern})(\\[[^]]*\\])?[[:space:]]*[:?+]?=[[:space:]]*(.*)$"
    if [[ "${line}" =~ ${assignment_pattern} ]]; then
        signing_privacy_matched_value="${BASH_REMATCH[4]}"
        return 0
    fi

    assignment_pattern="(^|[,{][[:space:]]*)[\"'](${key_pattern})[\"'][[:space:]]*:[[:space:]]*([^,}]*)([,}]|$)"
    if [[ "${line}" =~ ${assignment_pattern} ]]; then
        signing_privacy_matched_value="${BASH_REMATCH[3]}"
        return 0
    fi

    assignment_pattern="^[[:space:]]*(${key_pattern})[[:space:]]*:[[:space:]]*(.*)$"
    if [[ "${line}" =~ ${assignment_pattern} ]]; then
        signing_privacy_matched_value="${BASH_REMATCH[2]}"
        return 0
    fi

    assignment_pattern="^[[:space:]]*(${key_pattern})[[:space:]]*\\([[:space:]]*([^,)]*)"
    if [[ "${line}" =~ ${assignment_pattern} ]]; then
        signing_privacy_matched_value="${BASH_REMATCH[2]}"
        return 0
    fi

    return 1
}

signing_privacy_identity_is_public_default() {
    local value="$1"

    signing_privacy_value_is_indirect_or_empty "${value}" && return 0

    value="${value%%#*}"
    value="${value%;}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    case "${value}" in
        -|'"-"'|'Apple Development'|'"Apple Development"'|\
        'Apple Distribution'|'"Apple Distribution"'|\
        'Developer ID Application'|'"Developer ID Application"')
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

check_tracked_signing_privacy() {
    local repository_root="$1"
    local relative_path
    local absolute_path
    local line
    local line_number
    local value
    local failure_count=0
    local tracked_secret_path_count=0
    local team_key_pattern
    local identity_key_pattern
    local profile_key_pattern
    local private_release_key_pattern
    local account_key_pattern
    local signing_material_extension_pattern
    local concrete_identity_pattern
    local concrete_requirement_team_pattern
    local signing_privacy_matched_value

    team_key_pattern='[A-Z0-9_]*DEVELOPMENT_''TEAM|DevelopmentTeam|MURALUME_EXPECTED_''TEAM_IDENTIFIER|FASTLANE_TEAM_ID|FASTLANE_ITC_TEAM_ID|team_id|itc_team_id|developer_portal_team_id|export_team_id'
    identity_key_pattern='CODE_SIGN_IDENTITY|EXPANDED_CODE_SIGN_IDENTITY|code_signing_identity'
    profile_key_pattern='PROVISIONING_PROFILE|PROVISIONING_PROFILE_SPECIFIER|provisioning_profile|provisioning_profile_specifier|profile_name'
    private_release_key_pattern='MURALUME_DEVELOPER_ID_APPLICATION|MURALUME_NOTARY_KEYCHAIN_PROFILE'
    account_key_pattern='APPLE_ID|APPLE_ACCOUNT|NOTARY_APPLE_ID|ASC_USERNAME|ASC_KEY_ID|ASC_ISSUER_ID|ASC_KEY_CONTENT|APP_STORE_CONNECT_KEY_ID|APP_STORE_CONNECT_ISSUER_ID|APP_STORE_CONNECT_KEY_CONTENT|APP_STORE_CONNECT_API_KEY|FASTLANE_USER|FASTLANE_PASSWORD|FASTLANE_SESSION|FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD|MATCH_PASSWORD|apple_id|username|key_id|issuer_id|key_filepath|key_content|api_key_path'
    signing_material_extension_pattern='\.([cC][eE][rR]|[pP]12|[pP][fF][xX]|[pP]8|[kK][eE][yY]|[pP][eE][mM]|'
    signing_material_extension_pattern+='[rR][eE][qQ][uU][iI][rR][eE][mM][eE][nN][tT][sS]|'
    signing_material_extension_pattern+='[mM][oO][bB][iI][lL][eE][pP][rR][oO][vV][iI][sS][iI][oO][nN]|'
    signing_material_extension_pattern+='[pP][rR][oO][vV][iI][sS][iI][oO][nN][pP][rR][oO][fF][iI][lL][eE]|'
    signing_material_extension_pattern+='[dD][eE][vV][eE][lL][oO][pP][eE][rR][pP][rR][oO][fF][iI][lL][eE])$'
    concrete_identity_pattern='(Apple Development|Apple Distribution|Developer ID Application|Mac Developer|3rd Party Mac Developer Application):[^()]+\([A-Z0-9]{10}\)'
    concrete_requirement_team_pattern='certificate[[:space:]]+leaf\[subject\.OU\][[:space:]]*=[[:space:]]*[\"]?[A-Z0-9]{10}[\"]?'

    while IFS= read -r -d '' relative_path; do
        absolute_path="${repository_root}/${relative_path}"

        if [[ "${relative_path}" =~ ${signing_material_extension_pattern} ]]; then
            printf 'Forbidden signing file: %q\n' "${relative_path}" >&2
            tracked_secret_path_count=$((tracked_secret_path_count + 1))
            failure_count=$((failure_count + 1))
        fi

        [[ -f "${absolute_path}" ]] || continue
        LC_ALL=C grep -Iq . "${absolute_path}" || continue

        line_number=0
        while IFS= read -r line || [[ -n "${line}" ]]; do
            line_number=$((line_number + 1))

            if signing_privacy_extract_assignment_value \
                "${line}" "${team_key_pattern}"; then
                value="${signing_privacy_matched_value}"
                if ! signing_privacy_value_is_indirect_or_empty "${value}"; then
                    printf '%q:%d: concrete Apple Team value must move to an ignored local config.\n' \
                        "${relative_path}" "${line_number}" >&2
                    failure_count=$((failure_count + 1))
                fi
            fi

            if signing_privacy_extract_assignment_value \
                "${line}" "${identity_key_pattern}"; then
                value="${signing_privacy_matched_value}"
                if ! signing_privacy_identity_is_public_default "${value}"; then
                    printf '%q:%d: concrete signing identity must move to an ignored local config.\n' \
                        "${relative_path}" "${line_number}" >&2
                    failure_count=$((failure_count + 1))
                fi
            fi

            if signing_privacy_extract_assignment_value \
                "${line}" \
                "${profile_key_pattern}|${private_release_key_pattern}|${account_key_pattern}"; then
                value="${signing_privacy_matched_value}"
                if ! signing_privacy_value_is_indirect_or_empty "${value}"; then
                    printf '%q:%d: private signing or Apple account value must move to an ignored local config.\n' \
                        "${relative_path}" "${line_number}" >&2
                    failure_count=$((failure_count + 1))
                fi
            fi

            if [[ "${line}" =~ ${concrete_identity_pattern} ]]; then
                printf '%q:%d: concrete Apple certificate identity must not be tracked.\n' \
                    "${relative_path}" "${line_number}" >&2
                failure_count=$((failure_count + 1))
            fi
            if [[ "${line}" =~ ${concrete_requirement_team_pattern} ]]; then
                printf '%q:%d: concrete Apple Team in a code requirement must not be tracked.\n' \
                    "${relative_path}" "${line_number}" >&2
                failure_count=$((failure_count + 1))
            fi
        done < "${absolute_path}"
    done < <(
        git -C "${repository_root}" \
            ls-files -z --cached --others --exclude-standard
    )

    if [[ "${tracked_secret_path_count}" -ne 0 ]]; then
        echo "Signing certificates, keys, profiles, and Xcode account exports must not be tracked." >&2
    fi

    if [[ "${failure_count}" -ne 0 ]]; then
        echo "Tracked signing privacy checks failed." >&2
        return 1
    fi

    echo "Tracked signing privacy checks passed."
}
