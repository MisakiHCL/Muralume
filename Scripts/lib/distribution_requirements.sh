#!/usr/bin/env bash

# Validation helpers for the maintainer-supplied designated requirement used
# by the Developer ID bridge release. This file is intended to be sourced.

resolve_developer_id_identity_hash_from_listing() {
    if [[ "$#" -ne 3 ]]; then
        echo "Developer ID identity resolution needs a configured identity, Team ID, and identity listing." >&2
        return 64
    fi

    local configured_identity="$1"
    local expected_team_identifier="$2"
    local identity_listing="$3"
    local identity_line
    local candidate_hash
    local candidate_hash_upper
    local candidate_name
    local configured_identity_upper
    local resolved_hash=""
    local match_count=0

    if [[ -z "${configured_identity}" ]]; then
        echo "A Developer ID Application identity is required." >&2
        return 1
    fi
    if [[ ! "${expected_team_identifier}" =~ ^[A-Z0-9]{10}$ ]]; then
        echo "The expected Apple Team ID is invalid." >&2
        return 1
    fi

    while IFS= read -r identity_line; do
        if [[ ! "${identity_line}" =~ ^[[:space:]]*[0-9]+\)[[:space:]]+([[:xdigit:]]{40})[[:space:]]+\"([^\"]+)\" ]]; then
            continue
        fi

        candidate_hash="${BASH_REMATCH[1]}"
        candidate_hash_upper="$(
            tr '[:lower:]' '[:upper:]' <<<"${candidate_hash}"
        )"
        candidate_name="${BASH_REMATCH[2]}"
        [[ "${candidate_name}" == "Developer ID Application:"* ]] || continue
        [[ "${candidate_name}" == *" (${expected_team_identifier})" ]] || continue

        if [[ "${configured_identity}" =~ ^[[:xdigit:]]{40}$ ]]; then
            configured_identity_upper="$(
                tr '[:lower:]' '[:upper:]' <<<"${configured_identity}"
            )"
            [[ "${candidate_hash_upper}" == "${configured_identity_upper}" ]] \
                || continue
        elif [[ "${configured_identity}" == "Developer ID Application" ]]; then
            :
        else
            [[ "${candidate_name}" == "${configured_identity}" ]] || continue
        fi

        match_count=$((match_count + 1))
        resolved_hash="${candidate_hash_upper}"
    done <<<"${identity_listing}"

    if [[ "${match_count}" -ne 1 ]]; then
        echo "The configured Developer ID identity must resolve to exactly one certificate for the expected Team." >&2
        return 1
    fi

    printf '%s\n' "${resolved_hash}"
}

resolve_developer_id_identity_hash() {
    if [[ "$#" -ne 2 ]]; then
        echo "Developer ID identity resolution needs a configured identity and Team ID." >&2
        return 64
    fi

    local identity_listing
    if ! identity_listing="$(security find-identity -v -p codesigning 2>/dev/null)"; then
        echo "Unable to read Developer ID signing identities from the Keychain." >&2
        return 1
    fi

    resolve_developer_id_identity_hash_from_listing \
        "$1" \
        "$2" \
        "${identity_listing}"
}

distribution_requirement_binary_sha256() (
    if [[ "$#" -ne 1 ]]; then
        echo "Distribution requirement hashing needs a requirement path." >&2
        return 64
    fi

    local requirement_path="$1"
    local work_directory
    local binary_path

    work_directory="$(
        mktemp -d "${TMPDIR:-/tmp}/MuralumeRequirementHash.XXXXXX"
    )" || return 1
    trap 'rm -rf "${work_directory}"' EXIT
    binary_path="${work_directory}/requirement.csreq"

    if ! csreq -r "${requirement_path}" -b "${binary_path}" \
        >/dev/null 2>&1; then
        echo "Unable to compile the distribution requirement." >&2
        return 1
    fi

    shasum -a 256 "${binary_path}" | awk '{ print $1 }'
)

validate_distribution_requirement() (
    if [[ "$#" -ne 3 ]]; then
        echo "Distribution requirement validation needs a path, bundle ID, and Team ID." >&2
        return 64
    fi

    local requirement_path="$1"
    local expected_bundle_identifier="$2"
    local expected_team_identifier="$3"
    local canonical_requirement
    local expected_canonical_requirement
    local work_directory
    local expected_requirement_path
    local mac_app_store_leaf_oid='1.2.840.113635.100.6.1.9'
    local developer_id_issuer_oid='1.2.840.113635.100.6.2.6'
    local developer_id_application_leaf_oid='1.2.840.113635.100.6.1.13'

    if [[ ! -f "${requirement_path}" || ! -s "${requirement_path}" ]]; then
        echo "The Xcode-exported distribution requirement is missing or empty." >&2
        return 1
    fi
    if [[ ! "${expected_bundle_identifier}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]]; then
        echo "The expected production bundle ID is invalid." >&2
        return 1
    fi
    if [[ ! "${expected_team_identifier}" =~ ^[A-Z0-9]{10}$ ]]; then
        echo "The expected Apple Team ID is invalid." >&2
        return 1
    fi

    work_directory="$(
        mktemp -d "${TMPDIR:-/tmp}/MuralumeRequirementValidation.XXXXXX"
    )" || return 1
    trap 'rm -rf "${work_directory}"' EXIT
    expected_requirement_path="${work_directory}/expected.requirements"
    printf 'designated => anchor apple generic and identifier "%s" and (certificate leaf[field.%s] exists or certificate 1[field.%s] exists and certificate leaf[field.%s] exists and certificate leaf[subject.OU] = "%s")\n' \
        "${expected_bundle_identifier}" \
        "${mac_app_store_leaf_oid}" \
        "${developer_id_issuer_oid}" \
        "${developer_id_application_leaf_oid}" \
        "${expected_team_identifier}" \
        >"${expected_requirement_path}"

    if ! canonical_requirement="$(
        csreq -r "${requirement_path}" -t 2>/dev/null
    )"; then
        echo "The Xcode-exported distribution requirement is invalid." >&2
        return 1
    fi
    if ! expected_canonical_requirement="$(
        csreq -r "${expected_requirement_path}" -t 2>/dev/null
    )"; then
        echo "Unable to compile the expected distribution requirement." >&2
        return 1
    fi
    if [[ "${canonical_requirement}" != "${expected_canonical_requirement}" ]]; then
        echo "The distribution requirement is not the exact Xcode Mac App Store OR Developer ID structure." >&2
        return 1
    fi
)

validate_distribution_requirement_provenance() (
    if [[ "$#" -lt 4 || "$#" -gt 5 ]]; then
        echo "Distribution requirement provenance validation needs a path, bundle ID, Team ID, repository, and optional forbidden commit." >&2
        return 64
    fi

    local requirement_path="$1"
    local expected_bundle_identifier="$2"
    local expected_team_identifier="$3"
    local repository_path="$4"
    local forbidden_source_commit="${5:-}"
    local provenance_line_count
    local provenance_schema
    local source_kind
    local export_method
    local bundle_identifier
    local team_identifier
    local source_app_version
    local source_app_build
    local source_git_commit
    local source_git_tree
    local xcode_version
    local xcode_build
    local exported_app_cdhash
    local expected_requirement_sha256
    local actual_requirement_sha256
    local expected_requirement_sha256_lowercase
    local actual_requirement_sha256_lowercase
    local resolved_source_commit
    local resolved_source_tree
    local forbidden_source_tree=""

    provenance_value() {
        local key="$1"
        local matches
        local match_count

        matches="$(
            sed -n "s/^# muralume-${key}: //p" "${requirement_path}"
        )"
        match_count="$(
            sed -n "s/^# muralume-${key}: //p" "${requirement_path}" \
                | wc -l \
                | tr -d '[:space:]'
        )"
        if [[ "${match_count}" != "1" || -z "${matches}" ]]; then
            echo "The distribution requirement has missing or ambiguous provenance." >&2
            return 1
        fi
        printf '%s\n' "${matches}"
    }

    validate_distribution_requirement \
        "${requirement_path}" \
        "${expected_bundle_identifier}" \
        "${expected_team_identifier}" \
        || return 1

    provenance_line_count="$(
        sed -n '/^# muralume-/p' "${requirement_path}" \
            | wc -l \
            | tr -d '[:space:]'
    )"
    if [[ "${provenance_line_count}" != "13" ]]; then
        echo "The distribution requirement provenance has an unexpected shape." >&2
        return 1
    fi

    provenance_schema="$(provenance_value 'provenance-schema')" || return 1
    source_kind="$(provenance_value 'source-kind')" || return 1
    export_method="$(provenance_value 'export-method')" || return 1
    bundle_identifier="$(provenance_value 'bundle-identifier')" || return 1
    team_identifier="$(provenance_value 'team-identifier')" || return 1
    source_app_version="$(provenance_value 'source-app-version')" || return 1
    source_app_build="$(provenance_value 'source-app-build')" || return 1
    source_git_commit="$(provenance_value 'source-git-commit')" || return 1
    source_git_tree="$(provenance_value 'source-git-tree')" || return 1
    xcode_version="$(provenance_value 'xcode-version')" || return 1
    xcode_build="$(provenance_value 'xcode-build')" || return 1
    exported_app_cdhash="$(provenance_value 'exported-app-cdhash')" || return 1
    expected_requirement_sha256="$(
        provenance_value 'compiled-requirement-sha256'
    )" || return 1

    if [[ "${provenance_schema}" != "1" \
        || "${source_kind}" != "xcode-developer-id-export" \
        || "${export_method}" != "developer-id" \
        || "${bundle_identifier}" != "${expected_bundle_identifier}" \
        || "${team_identifier}" != "${expected_team_identifier}" \
        || "${source_app_version}" != "0.0.0" \
        || "${source_app_build}" != "1" ]]; then
        echo "The distribution requirement provenance does not describe the controlled Xcode export." >&2
        return 1
    fi
    if [[ ! "${source_git_commit}" =~ ^[0-9a-f]{40,64}$ \
        || ! "${source_git_tree}" =~ ^[0-9a-f]{40,64}$ \
        || ! "${xcode_version}" =~ ^[0-9]+([.][0-9A-Za-z]+)+$ \
        || ! "${xcode_build}" =~ ^[0-9A-Za-z.]+$ \
        || ! "${exported_app_cdhash}" =~ ^[[:xdigit:]]{40,64}$ \
        || ! "${expected_requirement_sha256}" =~ ^[[:xdigit:]]{64}$ ]]; then
        echo "The distribution requirement provenance contains an invalid value." >&2
        return 1
    fi
    if [[ ! -d "${repository_path}" ]] \
        || ! git -C "${repository_path}" rev-parse --git-dir \
            >/dev/null 2>&1; then
        echo "The distribution requirement provenance repository is unavailable." >&2
        return 1
    fi
    resolved_source_commit="$(
        git -C "${repository_path}" rev-parse --verify \
            "${source_git_commit}^{commit}" 2>/dev/null
    )" || {
        echo "The distribution requirement source commit is absent from this repository." >&2
        return 1
    }
    resolved_source_tree="$(
        git -C "${repository_path}" rev-parse --verify \
            "${resolved_source_commit}^{tree}" 2>/dev/null
    )" || return 1
    if [[ "${resolved_source_commit}" != "${source_git_commit}" \
        || "${resolved_source_tree}" != "${source_git_tree}" ]]; then
        echo "The distribution requirement source tree does not belong to its source commit." >&2
        return 1
    fi
    if [[ -n "${forbidden_source_commit}" ]]; then
        [[ "${forbidden_source_commit}" =~ ^[0-9a-f]{40,64}$ ]] || {
            echo "The forbidden distribution source commit is invalid." >&2
            return 1
        }
        forbidden_source_tree="$(
            git -C "${repository_path}" rev-parse --verify \
                "${forbidden_source_commit}^{tree}" 2>/dev/null
        )" || {
            echo "The forbidden distribution source commit is absent from this repository." >&2
            return 1
        }
    fi
    if [[ -n "${forbidden_source_commit}" \
        && ( "${source_git_commit}" == "${forbidden_source_commit}" \
            || "${source_git_tree}" == "${forbidden_source_tree}" ) ]]; then
        echo "The distribution requirement must not come from the v1.0.3 release source or tree." >&2
        return 1
    fi

    actual_requirement_sha256="$(
        distribution_requirement_binary_sha256 "${requirement_path}"
    )" || return 1
    actual_requirement_sha256_lowercase="$(
        tr '[:upper:]' '[:lower:]' <<<"${actual_requirement_sha256}"
    )"
    expected_requirement_sha256_lowercase="$(
        tr '[:upper:]' '[:lower:]' <<<"${expected_requirement_sha256}"
    )"
    if [[ "${actual_requirement_sha256_lowercase}" \
        != "${expected_requirement_sha256_lowercase}" ]]; then
        echo "The distribution requirement does not match its provenance digest." >&2
        return 1
    fi
)

validate_xcode_developer_id_exported_app() (
    if [[ "$#" -ne 8 ]]; then
        echo "Developer ID export validation needs an app, product, bundle, Team, architecture, version, build, and work directory." >&2
        return 64
    fi

    local app_path="$1"
    local product_name="$2"
    local expected_bundle_identifier="$3"
    local expected_team_identifier="$4"
    local expected_app_architecture="$5"
    local expected_marketing_version="$6"
    local expected_build_number="$7"
    local work_directory="$8"
    local executable_path="${app_path}/Contents/MacOS/${product_name}"
    local entitlements_path="${work_directory}/exported-app-entitlements.plist"
    local developer_id_requirement_path="${work_directory}/developer-id-export.requirement"
    local signature_details
    local signing_identifier
    local signing_team_identifier
    local signing_authority
    local exported_app_cdhash
    local actual_architectures
    local actual_bundle_identifier
    local actual_marketing_version
    local actual_build_number
    local entitlement_value
    local developer_id_issuer_oid='1.2.840.113635.100.6.2.6'
    local developer_id_application_leaf_oid='1.2.840.113635.100.6.1.13'

    if [[ ! -d "${app_path}" || -L "${app_path}" ]]; then
        echo "The Xcode Developer ID export app is missing or is a symbolic link." >&2
        return 1
    fi
    if [[ ! -f "${executable_path}" ]]; then
        echo "The Xcode Developer ID export executable is missing." >&2
        return 1
    fi
    if ! codesign --verify --deep --strict "${app_path}" \
        >/dev/null 2>&1; then
        echo "The Xcode Developer ID export signature is invalid." >&2
        return 1
    fi

    actual_bundle_identifier="$(
        plutil -extract CFBundleIdentifier raw \
            "${app_path}/Contents/Info.plist" 2>/dev/null
    )" || return 1
    actual_marketing_version="$(
        plutil -extract CFBundleShortVersionString raw \
            "${app_path}/Contents/Info.plist" 2>/dev/null
    )" || return 1
    actual_build_number="$(
        plutil -extract CFBundleVersion raw \
            "${app_path}/Contents/Info.plist" 2>/dev/null
    )" || return 1
    if [[ "${actual_bundle_identifier}" != "${expected_bundle_identifier}" \
        || "${actual_marketing_version}" != "${expected_marketing_version}" \
        || "${actual_build_number}" != "${expected_build_number}" ]]; then
        echo "The Xcode Developer ID export has an unexpected bundle identity or provenance-only version." >&2
        return 1
    fi

    actual_architectures="$(lipo -archs "${executable_path}" 2>/dev/null)" \
        || return 1
    if [[ "${actual_architectures}" != "${expected_app_architecture}" ]]; then
        echo "The Xcode Developer ID export has an unexpected architecture." >&2
        return 1
    fi

    signature_details="$(
        codesign --display --verbose=4 "${app_path}" 2>&1
    )" || return 1
    signing_identifier="$(
        sed -n 's/^Identifier=//p' <<<"${signature_details}"
    )"
    signing_team_identifier="$(
        sed -n 's/^TeamIdentifier=//p' <<<"${signature_details}"
    )"
    signing_authority="$(
        sed -n 's/^Authority=//p' <<<"${signature_details}" | sed -n '1p'
    )"
    exported_app_cdhash="$(
        sed -n 's/^CDHash=//p' <<<"${signature_details}"
    )"
    if [[ "${signing_identifier}" != "${expected_bundle_identifier}" \
        || "${signing_team_identifier}" != "${expected_team_identifier}" \
        || "${signing_authority}" != "Developer ID Application:"* \
        || "${signing_authority}" != *" (${expected_team_identifier})" \
        || ! "${exported_app_cdhash}" =~ ^[[:xdigit:]]{40,64}$ ]]; then
        echo "The Xcode export is not signed by the expected Developer ID application identity." >&2
        return 1
    fi
    if [[ "${signature_details}" != *$'\nTimestamp='* \
        || "${signature_details}" != *'(runtime)'* ]]; then
        echo "The Xcode Developer ID export lacks a secure timestamp or Hardened Runtime." >&2
        return 1
    fi

    if ! codesign --display --entitlements :- "${app_path}" \
        >"${entitlements_path}" 2>/dev/null \
        || ! plutil -lint "${entitlements_path}" >/dev/null; then
        echo "Unable to read the Xcode Developer ID export entitlements." >&2
        return 1
    fi
    for entitlement_value in \
        'com\.apple\.security\.app-sandbox' \
        'com\.apple\.security\.files\.user-selected\.read-write' \
        'com\.apple\.security\.files\.bookmarks\.app-scope'; do
        if [[ "$(
            plutil -extract "${entitlement_value}" raw -o - \
                "${entitlements_path}" 2>/dev/null || true
        )" != "true" ]]; then
            echo "The Xcode Developer ID export is missing a required production entitlement." >&2
            return 1
        fi
    done
    if plutil -extract 'com\.apple\.security\.get-task-allow' raw -o - \
        "${entitlements_path}" >/dev/null 2>&1; then
        echo "The Xcode Developer ID export must not contain get-task-allow." >&2
        return 1
    fi

    printf 'anchor apple generic and certificate 1[field.%s] exists and certificate leaf[field.%s] exists and certificate leaf[subject.OU] = "%s"\n' \
        "${developer_id_issuer_oid}" \
        "${developer_id_application_leaf_oid}" \
        "${expected_team_identifier}" \
        >"${developer_id_requirement_path}"
    if ! codesign --verify --strict \
        -R "${developer_id_requirement_path}" \
        "${app_path}" >/dev/null 2>&1; then
        echo "The Xcode export does not satisfy the expected Developer ID certificate requirement." >&2
        return 1
    fi

    tr '[:lower:]' '[:upper:]' <<<"${exported_app_cdhash}"
)

verify_embedded_distribution_requirement() {
    if [[ "$#" -ne 3 ]]; then
        echo "Embedded requirement verification needs an app, requirement, and work directory." >&2
        return 64
    fi

    local app_path="$1"
    local requirement_path="$2"
    local work_directory="$3"
    local extracted_requirement_path="${work_directory}/embedded.requirements"
    local expected_canonical_path="${work_directory}/expected-requirements.txt"
    local actual_canonical_path="${work_directory}/embedded-requirements.txt"
    local expected_designated_path="${work_directory}/expected-designated.requirement"
    local actual_designated_path="${work_directory}/embedded-designated.requirement"
    local external_requirement_path="${work_directory}/expected-external.requirement"
    local expected_binary_path="${work_directory}/expected-requirement.csreq"
    local actual_binary_path="${work_directory}/embedded-requirement.csreq"

    if ! codesign --display -r- "${app_path}" \
        >"${extracted_requirement_path}" 2>/dev/null; then
        echo "Unable to extract the signed app's designated requirement." >&2
        return 1
    fi
    if ! csreq -r "${requirement_path}" -t \
        >"${expected_canonical_path}" 2>/dev/null \
        || ! csreq -r "${extracted_requirement_path}" -t \
            >"${actual_canonical_path}" 2>/dev/null; then
        echo "Unable to canonicalize the expected or embedded designated requirement." >&2
        return 1
    fi
    sed -n '/^designated => /p' "${expected_canonical_path}" \
        >"${expected_designated_path}"
    sed -n '/^designated => /p' "${actual_canonical_path}" \
        >"${actual_designated_path}"
    sed -n 's/^designated => //p' "${expected_canonical_path}" \
        >"${external_requirement_path}"
    if [[ ! -s "${expected_designated_path}" \
        || ! -s "${actual_designated_path}" \
        || ! -s "${external_requirement_path}" ]] \
        || ! csreq -r "${expected_designated_path}" -b "${expected_binary_path}" \
            >/dev/null 2>&1 \
        || ! csreq -r "${actual_designated_path}" -b "${actual_binary_path}" \
            >/dev/null 2>&1; then
        echo "Unable to compile the expected or embedded designated requirement." >&2
        return 1
    fi
    if ! cmp -s "${expected_binary_path}" "${actual_binary_path}"; then
        echo "The signed app did not embed the supplied designated requirement." >&2
        return 1
    fi
    if ! codesign --verify --strict -R "${external_requirement_path}" "${app_path}" \
        >/dev/null 2>&1; then
        echo "The signed app does not satisfy the supplied designated requirement." >&2
        return 1
    fi
}
