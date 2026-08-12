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
    # A scoped environment assignment may continue into the command on the
    # next line. Remove exactly that shell continuation before evaluating the
    # value; a literal on the left still remains concrete and is rejected.
    if [[ "${value}" == *' \' ]]; then
        value="${value%??}"
        value="${value%"${value##*[![:space:]]}"}"
    fi

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
    # Scoped shell forwarding such as KEY="${captured_key}" remains indirect;
    # the actual value still comes from a private, ignored configuration.
    [[ "${value}" =~ ^[\"\']\$\{[A-Za-z_][A-Za-z0-9_]*(:-)?\}[\"\']$ ]] \
        && return 0
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

    assignment_pattern="^[[:space:]]*[\"']?(${key_pattern})[\"']?[[:space:]]*=>[[:space:]]*(.*)$"
    if [[ "${line}" =~ ${assignment_pattern} ]]; then
        signing_privacy_matched_value="${BASH_REMATCH[2]}"
        return 0
    fi

    assignment_pattern="<key>[[:space:]]*(${key_pattern})[[:space:]]*</key>[[:space:]]*<(string|data|integer|real)>[[:space:]]*([^<]*)</(string|data|integer|real)>"
    if [[ "${line}" =~ ${assignment_pattern} ]]; then
        signing_privacy_matched_value="${BASH_REMATCH[3]}"
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

signing_privacy_key_kind() {
    local key="$1"
    local team_key_pattern="$2"
    local identity_key_pattern="$3"
    local private_key_pattern="$4"

    signing_privacy_matched_key_kind=""
    if [[ "${key}" =~ ^(${team_key_pattern})$ ]]; then
        signing_privacy_matched_key_kind="team"
    elif [[ "${key}" =~ ^(${identity_key_pattern})$ ]]; then
        signing_privacy_matched_key_kind="identity"
    elif [[ "${key}" =~ ^(${private_key_pattern})$ ]]; then
        signing_privacy_matched_key_kind="private"
    else
        return 1
    fi
}

signing_privacy_extract_pending_key_kind() {
    local line="$1"
    local all_key_pattern="$2"
    local team_key_pattern="$3"
    local identity_key_pattern="$4"
    local private_key_pattern="$5"
    local pending_pattern
    local key

    signing_privacy_matched_key_kind=""

    pending_pattern="^[[:space:]]*<key>[[:space:]]*(${all_key_pattern})[[:space:]]*</key>[[:space:]]*$"
    if [[ "${line}" =~ ${pending_pattern} ]]; then
        key="${BASH_REMATCH[1]}"
        signing_privacy_key_kind \
            "${key}" \
            "${team_key_pattern}" \
            "${identity_key_pattern}" \
            "${private_key_pattern}"
        return
    fi

    pending_pattern="^[[:space:]]*[\"']?(${all_key_pattern})[\"']?[[:space:]]*(:|=>)[[:space:]]*((#|//).*)?$"
    if [[ "${line}" =~ ${pending_pattern} ]]; then
        key="${BASH_REMATCH[1]}"
        signing_privacy_key_kind \
            "${key}" \
            "${team_key_pattern}" \
            "${identity_key_pattern}" \
            "${private_key_pattern}"
        return
    fi

    return 1
}

signing_privacy_extract_standalone_value() {
    local line="$1"
    local value_pattern

    signing_privacy_matched_value=""

    if [[ "${line}" =~ ^[[:space:]]*$ ]] ||
        [[ "${line}" =~ ^[[:space:]]*(#|//) ]] ||
        [[ "${line}" =~ ^[[:space:]]*\<\!--.*--\>[[:space:]]*$ ]]; then
        return 1
    fi

    value_pattern='^[[:space:]]*<(string|data|integer|real)>[[:space:]]*([^<]*)</(string|data|integer|real)>[[:space:]]*$'
    if [[ "${line}" =~ ${value_pattern} ]]; then
        signing_privacy_matched_value="${BASH_REMATCH[2]}"
        return 0
    fi

    value_pattern='^[[:space:]]*<(true|false)/>[[:space:]]*$'
    if [[ "${line}" =~ ${value_pattern} ]]; then
        signing_privacy_matched_value="${BASH_REMATCH[1]}"
        return 0
    fi

    signing_privacy_matched_value="${line}"
    signing_privacy_matched_value="${signing_privacy_matched_value#"${signing_privacy_matched_value%%[![:space:]]*}"}"
    signing_privacy_matched_value="${signing_privacy_matched_value%"${signing_privacy_matched_value##*[![:space:]]}"}"
    signing_privacy_matched_value="${signing_privacy_matched_value#- }"
    signing_privacy_matched_value="${signing_privacy_matched_value%,}"
    return 0
}

signing_privacy_value_is_allowed_for_kind() {
    local key_kind="$1"
    local value="$2"

    case "${key_kind}" in
        identity)
            signing_privacy_identity_is_public_default "${value}"
            ;;
        team|private)
            signing_privacy_value_is_indirect_or_empty "${value}"
            ;;
        *)
            return 1
            ;;
    esac
}

signing_privacy_report_concrete_value() {
    local relative_path="$1"
    local line_number="$2"
    local content_source="$3"
    local key_kind="$4"

    case "${key_kind}" in
        team)
            printf '%q:%d (%s): concrete Apple Team value must move to an ignored local config.\n' \
                "${relative_path}" "${line_number}" "${content_source}" >&2
            ;;
        identity)
            printf '%q:%d (%s): concrete signing identity must move to an ignored local config.\n' \
                "${relative_path}" "${line_number}" "${content_source}" >&2
            ;;
        private)
            printf '%q:%d (%s): private signing or Apple account value must move to an ignored local config.\n' \
                "${relative_path}" "${line_number}" "${content_source}" >&2
            ;;
    esac
}

signing_privacy_scan_text_stream() {
    local relative_path="$1"
    local content_source="$2"
    local team_key_pattern="$3"
    local identity_key_pattern="$4"
    local private_key_pattern="$5"
    local concrete_identity_pattern="$6"
    local concrete_requirement_team_pattern="$7"
    local candidate_content_pattern="$8"
    local private_material_header_pattern="$9"
    local all_key_pattern
    local line
    local line_number=0
    local value
    local key_kind
    local pending_key_kind=""
    local pending_key_line_number=0
    local failed=0
    local nocasematch_was_enabled=0
    local signing_privacy_matched_value
    local signing_privacy_matched_key_kind

    all_key_pattern="${team_key_pattern}|${identity_key_pattern}|${private_key_pattern}"
    shopt -q nocasematch && nocasematch_was_enabled=1
    shopt -s nocasematch

    while IFS= read -r line || [[ -n "${line}" ]]; do
        line_number=$((line_number + 1))

        if [[ "${line}" =~ ${candidate_content_pattern} ]]; then
            for key_kind in team identity private; do
                case "${key_kind}" in
                    team) value="${team_key_pattern}" ;;
                    identity) value="${identity_key_pattern}" ;;
                    private) value="${private_key_pattern}" ;;
                esac
                if signing_privacy_extract_assignment_value "${line}" "${value}"; then
                    value="${signing_privacy_matched_value}"
                    if ! signing_privacy_value_is_allowed_for_kind \
                        "${key_kind}" "${value}"; then
                        signing_privacy_report_concrete_value \
                            "${relative_path}" \
                            "${line_number}" \
                            "${content_source}" \
                            "${key_kind}"
                        failed=1
                    fi
                fi
            done

            if [[ "${line}" =~ ${concrete_identity_pattern} ]]; then
                printf '%q:%d (%s): concrete Apple certificate identity must not be tracked.\n' \
                    "${relative_path}" "${line_number}" "${content_source}" >&2
                failed=1
            fi
            if [[ "${line}" =~ ${concrete_requirement_team_pattern} ]]; then
                printf '%q:%d (%s): concrete Apple Team in a code requirement must not be tracked.\n' \
                    "${relative_path}" "${line_number}" "${content_source}" >&2
                failed=1
            fi
            if [[ "${line}" =~ ${private_material_header_pattern} ]]; then
                printf '%q:%d (%s): private-key or certificate material must not be public.\n' \
                    "${relative_path}" "${line_number}" "${content_source}" >&2
                failed=1
            fi

            if signing_privacy_extract_pending_key_kind \
                "${line}" \
                "${all_key_pattern}" \
                "${team_key_pattern}" \
                "${identity_key_pattern}" \
                "${private_key_pattern}"; then
                pending_key_kind="${signing_privacy_matched_key_kind}"
                pending_key_line_number="${line_number}"
                continue
            fi
        fi

        if [[ -n "${pending_key_kind}" ]] &&
            signing_privacy_extract_standalone_value "${line}"; then
            value="${signing_privacy_matched_value}"
            if ! signing_privacy_value_is_allowed_for_kind \
                "${pending_key_kind}" "${value}"; then
                signing_privacy_report_concrete_value \
                    "${relative_path}" \
                    "${pending_key_line_number}" \
                    "${content_source}" \
                    "${pending_key_kind}"
                failed=1
            fi
            pending_key_kind=""
            pending_key_line_number=0
        fi
    done

    if [[ -n "${pending_key_kind}" ]]; then
        printf '%q:%d (%s): sensitive signing key has no inspectable scalar value.\n' \
            "${relative_path}" "${pending_key_line_number}" "${content_source}" >&2
        failed=1
    fi

    if [[ "${nocasematch_was_enabled}" -eq 0 ]]; then
        shopt -u nocasematch
    fi
    [[ "${failed}" -eq 0 ]]
}

signing_privacy_scan_content_file() {
    local content_path="$1"
    local relative_path="$2"
    local content_source="$3"
    local normalized_path="$4"
    local team_key_pattern="$5"
    local identity_key_pattern="$6"
    local private_key_pattern="$7"
    local concrete_identity_pattern="$8"
    local concrete_requirement_team_pattern="$9"
    shift 9
    local candidate_content_pattern="$1"
    local private_material_header_pattern="$2"
    local content_probe_pattern
    local grep_status
    local plist_status

    if [[ ! -f "${content_path}" || ! -r "${content_path}" ]]; then
        printf 'Could not read signing privacy input %q (%s).\n' \
            "${relative_path}" "${content_source}" >&2
        return 1
    fi

    content_probe_pattern="${candidate_content_pattern}|${private_material_header_pattern}|bplist00"
    if LC_ALL=C grep -a -i -q -E "${content_probe_pattern}" "${content_path}"; then
        :
    else
        grep_status=$?
        if [[ "${grep_status}" -eq 1 ]]; then
            return 0
        fi
        printf 'Could not inspect signing privacy input %q (%s).\n' \
            "${relative_path}" "${content_source}" >&2
        return 1
    fi

    if LC_ALL=C grep -a -i -q -E \
        -e "${private_material_header_pattern}" "${content_path}"; then
        printf '%q (%s): private-key or certificate material must not be public.\n' \
            "${relative_path}" "${content_source}" >&2
        return 1
    else
        grep_status=$?
        if [[ "${grep_status}" -gt 1 ]]; then
            printf 'Could not inspect signing material header in %q (%s).\n' \
                "${relative_path}" "${content_source}" >&2
            return 1
        fi
    fi

    if plutil -p "${content_path}" > "${normalized_path}" 2>/dev/null; then
        signing_privacy_scan_text_stream \
            "${relative_path}" \
            "${content_source}, normalized plist" \
            "${team_key_pattern}" \
            "${identity_key_pattern}" \
            "${private_key_pattern}" \
            "${concrete_identity_pattern}" \
            "${concrete_requirement_team_pattern}" \
            "${candidate_content_pattern}" \
            "${private_material_header_pattern}" \
            < "${normalized_path}"
        return
    else
        plist_status=$?
    fi

    if LC_ALL=C grep -a -q '^bplist00' "${content_path}"; then
        echo \
            "Could not normalize binary privacy plist ${relative_path} (${content_source}); plutil status ${plist_status}." \
            >&2
        return 1
    fi
    grep_status=$?
    if [[ "${grep_status}" -gt 1 ]]; then
        printf 'Could not identify signing privacy input %q (%s).\n' \
            "${relative_path}" "${content_source}" >&2
        return 1
    fi

    signing_privacy_scan_text_stream \
        "${relative_path}" \
        "${content_source}" \
        "${team_key_pattern}" \
        "${identity_key_pattern}" \
        "${private_key_pattern}" \
        "${concrete_identity_pattern}" \
        "${concrete_requirement_team_pattern}" \
        "${candidate_content_pattern}" \
        "${private_material_header_pattern}" \
        < "${content_path}"
}

signing_privacy_check_repository() {
    local repository_root="$1"
    local scan_root="$2"
    local index_records_path="${scan_root}/index-records"
    local tracked_paths_path="${scan_root}/tracked-paths"
    local untracked_paths_path="${scan_root}/untracked-paths"
    local object_root="${scan_root}/objects"
    local normalized_path="${scan_root}/normalized"
    local relative_path
    local absolute_path
    local index_record
    local index_metadata
    local index_mode
    local index_object_id
    local index_stage
    local object_path
    local content_source
    local failure_count=0
    local team_key_pattern
    local identity_key_pattern
    local profile_key_pattern
    local private_release_key_pattern
    local account_key_pattern
    local signing_material_extension_pattern
    local concrete_identity_pattern
    local concrete_requirement_team_pattern
    local private_key_pattern
    local candidate_content_pattern
    local private_material_header_pattern
    local LC_ALL=C

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
    private_material_header_pattern='-----BEGIN[[:space:]]+((RSA|EC|DSA|OPENSSH|ENCRYPTED)[[:space:]]+)?PRIVATE[[:space:]]+KEY-----|-----BEGIN[[:space:]]+(X509[[:space:]]+)?CERTIFICATE-----'
    private_key_pattern="${profile_key_pattern}|${private_release_key_pattern}|${account_key_pattern}"
    candidate_content_pattern="${team_key_pattern}|${identity_key_pattern}|${private_key_pattern}"
    candidate_content_pattern+="|Apple Development|Apple Distribution|Developer ID Application"
    candidate_content_pattern+="|Mac Developer|3rd Party Mac Developer Application"
    candidate_content_pattern+='|certificate[[:space:]]+leaf\[subject\.OU\]'

    mkdir -p "${object_root}" || {
        echo "Could not create private signing scan object directory." >&2
        return 1
    }
    if ! git -C "${repository_root}" ls-files -z --cached --stage \
        > "${index_records_path}"; then
        echo "Could not enumerate Git index entries for signing privacy checks." >&2
        return 1
    fi
    if ! git -C "${repository_root}" ls-files -z --cached \
        > "${tracked_paths_path}"; then
        echo "Could not enumerate tracked worktree paths for signing privacy checks." >&2
        return 1
    fi
    if ! git -C "${repository_root}" ls-files -z --others --exclude-standard \
        > "${untracked_paths_path}"; then
        echo "Could not enumerate untracked worktree paths for signing privacy checks." >&2
        return 1
    fi

    while IFS= read -r -d '' index_record; do
        if [[ "${index_record}" != *$'\t'* ]]; then
            echo "Git returned a malformed index entry during signing privacy checks." >&2
            return 1
        fi
        index_metadata="${index_record%%$'\t'*}"
        relative_path="${index_record#*$'\t'}"
        if [[ ! "${index_metadata}" =~ ^([0-9]{6})[[:space:]]([0-9a-f]+)[[:space:]]([0-3])$ ]]; then
            printf 'Git returned malformed index metadata for %q.\n' \
                "${relative_path}" >&2
            return 1
        fi
        index_mode="${BASH_REMATCH[1]}"
        index_object_id="${BASH_REMATCH[2]}"
        index_stage="${BASH_REMATCH[3]}"

        if [[ "${relative_path}" =~ ${signing_material_extension_pattern} ]]; then
            printf 'Forbidden signing file in index stage %s: %q\n' \
                "${index_stage}" "${relative_path}" >&2
            failure_count=$((failure_count + 1))
        fi

        case "${index_mode}" in
            160000)
                continue
                ;;
            100644|100755|120000)
                ;;
            *)
                printf 'Unexpected Git index mode %s for %q.\n' \
                    "${index_mode}" "${relative_path}" >&2
                return 1
                ;;
        esac

        object_path="${object_root}/${index_object_id}"
        if [[ ! -f "${object_path}" ]]; then
            if ! git -C "${repository_root}" cat-file blob "${index_object_id}" \
                > "${object_path}"; then
                printf 'Could not read Git index object %s for %q.\n' \
                    "${index_object_id}" "${relative_path}" >&2
                return 1
            fi
        fi
        content_source="index stage ${index_stage}"
        if ! signing_privacy_scan_content_file \
            "${object_path}" \
            "${relative_path}" \
            "${content_source}" \
            "${normalized_path}" \
            "${team_key_pattern}" \
            "${identity_key_pattern}" \
            "${private_key_pattern}" \
            "${concrete_identity_pattern}" \
            "${concrete_requirement_team_pattern}" \
            "${candidate_content_pattern}" \
            "${private_material_header_pattern}"; then
            failure_count=$((failure_count + 1))
        fi
    done < "${index_records_path}"

    while IFS= read -r -d '' relative_path; do
        absolute_path="${repository_root}/${relative_path}"
        [[ ! -L "${absolute_path}" ]] || continue
        [[ -e "${absolute_path}" ]] || continue
        if ! signing_privacy_scan_content_file \
            "${absolute_path}" \
            "${relative_path}" \
            "worktree" \
            "${normalized_path}" \
            "${team_key_pattern}" \
            "${identity_key_pattern}" \
            "${private_key_pattern}" \
            "${concrete_identity_pattern}" \
            "${concrete_requirement_team_pattern}" \
            "${candidate_content_pattern}" \
            "${private_material_header_pattern}"; then
            failure_count=$((failure_count + 1))
        fi
    done < "${tracked_paths_path}"

    while IFS= read -r -d '' relative_path; do
        absolute_path="${repository_root}/${relative_path}"
        if [[ "${relative_path}" =~ ${signing_material_extension_pattern} ]]; then
            printf 'Forbidden untracked signing file: %q\n' "${relative_path}" >&2
            failure_count=$((failure_count + 1))
        fi
        [[ ! -L "${absolute_path}" ]] || continue
        if [[ ! -e "${absolute_path}" ]]; then
            printf 'Untracked privacy input disappeared during scanning: %q\n' \
                "${relative_path}" >&2
            return 1
        fi
        if ! signing_privacy_scan_content_file \
            "${absolute_path}" \
            "${relative_path}" \
            "untracked worktree" \
            "${normalized_path}" \
            "${team_key_pattern}" \
            "${identity_key_pattern}" \
            "${private_key_pattern}" \
            "${concrete_identity_pattern}" \
            "${concrete_requirement_team_pattern}" \
            "${candidate_content_pattern}" \
            "${private_material_header_pattern}"; then
            failure_count=$((failure_count + 1))
        fi
    done < "${untracked_paths_path}"

    if [[ "${failure_count}" -ne 0 ]]; then
        return 1
    fi
}

check_tracked_signing_privacy() {
    local repository_root="$1"
    local scan_root
    local scan_status=0
    local cleanup_status=0
    local original_umask
    local required_command

    for required_command in git grep plutil; do
        if ! command -v "${required_command}" >/dev/null 2>&1; then
            echo "Required signing privacy command is unavailable: ${required_command}" >&2
            return 1
        fi
    done

    original_umask="$(umask)"
    umask 077
    if ! scan_root="$(
        mktemp -d "${TMPDIR:-/tmp}/MuralumeSigningPrivacyScan.XXXXXX"
    )"; then
        umask "${original_umask}"
        echo "Could not create private signing privacy scan directory." >&2
        return 1
    fi
    umask "${original_umask}"
    if ! chmod 700 "${scan_root}"; then
        echo "Could not secure signing privacy scan directory." >&2
        rm -rf -- "${scan_root}"
        return 1
    fi

    signing_privacy_check_repository \
        "${repository_root}" "${scan_root}" || scan_status=$?
    rm -rf -- "${scan_root}" || cleanup_status=$?

    if [[ "${cleanup_status}" -ne 0 ]]; then
        echo "Could not remove private signing privacy scan directory." >&2
        scan_status=1
    fi
    if [[ "${scan_status}" -ne 0 ]]; then
        echo "Signing privacy checks failed." >&2
        return 1
    fi

    echo "Signing privacy checks passed."
}
