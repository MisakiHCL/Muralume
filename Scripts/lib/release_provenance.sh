#!/usr/bin/env bash

# Durable publication provenance. The same strict manifest is embedded in the
# annotated tag and uploaded with the release so status checks survive local
# cache/dist cleanup and moving the checkout to another Mac.

readonly MURALUME_RELEASE_PROVENANCE_SCHEMA='1'

MURALUME_PROVENANCE_SOURCE_COMMIT=''
MURALUME_PROVENANCE_SOURCE_TREE=''
MURALUME_PROVENANCE_DMG_SHA256=''
MURALUME_PROVENANCE_APP_STORE_VERSION=''
MURALUME_PROVENANCE_APP_STORE_BUILD=''

release_provenance_value() {
    [[ "$#" -eq 2 ]] || return 64
    local provenance_path="$1"
    local provenance_key="$2"
    local provenance_matches
    provenance_matches="$(
        sed -n "s/^${provenance_key}=//p" "${provenance_path}"
    )" || return 1
    [[ -n "${provenance_matches}" \
        && "${provenance_matches}" != *$'\n'* ]] || return 1
    printf '%s\n' "${provenance_matches}"
}

release_provenance_read() {
    [[ "$#" -eq 1 ]] || return 64
    local provenance_path="$1"
    local provenance_schema
    local provenance_source_commit
    local provenance_source_tree
    local provenance_dmg_sha256
    local provenance_app_store_version
    local provenance_app_store_build

    [[ -f "${provenance_path}" && ! -L "${provenance_path}" \
        && "$(stat -f '%Lp' "${provenance_path}")" == '600' \
        && "$(stat -f '%u' "${provenance_path}")" == "$(id -u)" \
        && "$(wc -l <"${provenance_path}" | tr -d '[:space:]')" == '7' ]] \
        || return 1
    if /usr/bin/grep -E -v \
        '^(schema|product|source_commit|source_tree|dmg_sha256|app_store_version|app_store_build)=[^[:cntrl:]]+$' \
        "${provenance_path}" >/dev/null; then
        return 1
    fi
    provenance_schema="$(release_provenance_value "${provenance_path}" schema)" \
        || return 1
    [[ "$(release_provenance_value "${provenance_path}" product)" \
        == 'Muralume' ]] || return 1
    provenance_source_commit="$(
        release_provenance_value "${provenance_path}" source_commit
    )" || return 1
    provenance_source_tree="$(
        release_provenance_value "${provenance_path}" source_tree
    )" || return 1
    provenance_dmg_sha256="$(
        release_provenance_value "${provenance_path}" dmg_sha256
    )" || return 1
    provenance_app_store_version="$(
        release_provenance_value "${provenance_path}" app_store_version
    )" || return 1
    provenance_app_store_build="$(
        release_provenance_value "${provenance_path}" app_store_build
    )" || return 1

    [[ "${provenance_schema}" == "${MURALUME_RELEASE_PROVENANCE_SCHEMA}" \
        && "${provenance_source_commit}" =~ ^[[:xdigit:]]{40,64}$ \
        && "${provenance_source_tree}" =~ ^[[:xdigit:]]{40,64}$ \
        && "${provenance_dmg_sha256}" =~ ^[[:xdigit:]]{64}$ \
        && "${provenance_app_store_version}" \
            =~ ^[0-9]+\.[0-9]+\.[0-9]+$ \
        && "${provenance_app_store_build}" =~ ^[1-9][0-9]*$ ]] || return 1

    MURALUME_PROVENANCE_SOURCE_COMMIT="${provenance_source_commit}"
    MURALUME_PROVENANCE_SOURCE_TREE="${provenance_source_tree}"
    MURALUME_PROVENANCE_DMG_SHA256="$(
        printf '%s' "${provenance_dmg_sha256}" \
            | tr '[:upper:]' '[:lower:]'
    )"
    MURALUME_PROVENANCE_APP_STORE_VERSION="${provenance_app_store_version}"
    MURALUME_PROVENANCE_APP_STORE_BUILD="${provenance_app_store_build}"
}

release_provenance_write() {
    [[ "$#" -eq 6 ]] || return 64
    local provenance_path="$1"
    local provenance_source_commit="$2"
    local provenance_source_tree="$3"
    local provenance_dmg_sha256="$4"
    local provenance_app_store_version="$5"
    local provenance_app_store_build="$6"
    local provenance_directory
    local provenance_temporary_path=''
    local provenance_normalized_digest

    [[ "${provenance_source_commit}" =~ ^[[:xdigit:]]{40,64}$ \
        && "${provenance_source_tree}" =~ ^[[:xdigit:]]{40,64}$ \
        && "${provenance_dmg_sha256}" =~ ^[[:xdigit:]]{64}$ \
        && "${provenance_app_store_version}" \
            =~ ^[0-9]+\.[0-9]+\.[0-9]+$ \
        && "${provenance_app_store_build}" =~ ^[1-9][0-9]*$ ]] || return 1
    provenance_directory="$(dirname "${provenance_path}")" || return 1
    [[ ! -L "${provenance_path}" \
        && (! -e "${provenance_path}" \
            || -f "${provenance_path}") ]] || return 1
    provenance_normalized_digest="$(
        printf '%s' "${provenance_dmg_sha256}" \
            | tr '[:upper:]' '[:lower:]'
    )"
    mkdir -p "${provenance_directory}" || return 1
    chmod 700 "${provenance_directory}" || return 1
    provenance_temporary_path="$(
        mktemp "${provenance_directory}/.Muralume-release.XXXXXX"
    )" || return 1
    if ! {
        printf 'schema=%s\n' "${MURALUME_RELEASE_PROVENANCE_SCHEMA}"
        printf 'product=Muralume\n'
        printf 'source_commit=%s\n' "${provenance_source_commit}"
        printf 'source_tree=%s\n' "${provenance_source_tree}"
        printf 'dmg_sha256=%s\n' "${provenance_normalized_digest}"
        printf 'app_store_version=%s\n' "${provenance_app_store_version}"
        printf 'app_store_build=%s\n' "${provenance_app_store_build}"
    } >"${provenance_temporary_path}" \
        || ! chmod 600 "${provenance_temporary_path}" \
        || ! mv -f "${provenance_temporary_path}" "${provenance_path}"; then
        rm -f "${provenance_temporary_path}"
        return 1
    fi
}

release_provenance_matches() {
    [[ "$#" -eq 5 ]] || return 64
    local provenance_expected_commit="$1"
    local provenance_expected_tree="$2"
    local provenance_expected_digest="$3"
    local provenance_expected_version="$4"
    local provenance_expected_build="$5"

    local provenance_normalized_expected_digest
    provenance_normalized_expected_digest="$(
        printf '%s' "${provenance_expected_digest}" \
            | tr '[:upper:]' '[:lower:]'
    )"
    [[ "${MURALUME_PROVENANCE_SOURCE_COMMIT}" \
            == "${provenance_expected_commit}" \
        && "${MURALUME_PROVENANCE_SOURCE_TREE}" \
            == "${provenance_expected_tree}" \
        && (-z "${provenance_expected_digest}" \
            || "${MURALUME_PROVENANCE_DMG_SHA256}" \
                == "${provenance_normalized_expected_digest}") \
        && "${MURALUME_PROVENANCE_APP_STORE_VERSION}" \
            == "${provenance_expected_version}" \
        && "${MURALUME_PROVENANCE_APP_STORE_BUILD}" \
            == "${provenance_expected_build}" ]]
}

release_testflight_state_is_complete() {
    [[ "$#" -eq 1 ]] || return 64
    [[ "$1" == 'VALID' ]]
}
