#!/usr/bin/env bash

# A deliberately metadata-only timing journal for the resumable dual release.
# It records public stage names and immutable source identifiers, never command
# lines, environment values, credentials, paths, or build output.

readonly MURALUME_RELEASE_TIMING_JOURNAL_SCHEMA='1'

MURALUME_RELEASE_TIMING_JOURNAL_PATH=''
MURALUME_RELEASE_TIMING_RUN_IDENTIFIER=''
MURALUME_RELEASE_TIMING_ACTIVE_STAGE=''
MURALUME_RELEASE_TIMING_ACTIVE_STARTED_EPOCH=''

release_timing_journal_is_secure_file() {
    [[ "$#" -eq 1 ]] || return 64
    local timing_secure_journal_path="$1"

    [[ -f "${timing_secure_journal_path}" \
        && ! -L "${timing_secure_journal_path}" \
        && "$(stat -f '%Lp' "${timing_secure_journal_path}")" == '600' \
        && "$(stat -f '%u' "${timing_secure_journal_path}")" == "$(id -u)" ]]
}

release_timing_journal_validate() {
    [[ "$#" -eq 3 ]] || return 64
    local timing_validation_journal_path="$1"
    local expected_source_commit="$2"
    local expected_source_tree="$3"
    local timing_header

    release_timing_journal_is_secure_file "${timing_validation_journal_path}" \
        || return 1
    timing_header="$(sed -n '1,4p' "${timing_validation_journal_path}")" \
        || return 1
    [[ "${timing_header}" == "$(printf '%s\n' \
        "schema=${MURALUME_RELEASE_TIMING_JOURNAL_SCHEMA}" \
        'product=Muralume' \
        "source_commit=${expected_source_commit}" \
        "source_tree=${expected_source_tree}")" ]] || return 1

    if tail -n +5 "${timing_validation_journal_path}" \
        | /usr/bin/grep -E -v \
            $'^(stage_start\t[0-9a-f]{64}\t[a-z][a-z0-9_]{0,47}\t[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\t[0-9]+|stage_finish\t[0-9a-f]{64}\t[a-z][a-z0-9_]{0,47}\t[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\t[0-9]+\t[0-9]+\t(passed|failed|reused|skipped|processing|complete))$' \
            >/dev/null; then
        return 1
    fi
}

release_timing_journal_initialize() {
    [[ "$#" -eq 3 ]] || return 64
    local timing_initialize_journal_path="$1"
    local timing_source_commit="$2"
    local timing_source_tree="$3"
    local timing_journal_directory
    local timing_temporary_path=''

    [[ "${timing_source_commit}" =~ ^[[:xdigit:]]{40,64}$ \
        && "${timing_source_tree}" =~ ^[[:xdigit:]]{40,64}$ ]] || return 1
    if [[ -e "${timing_initialize_journal_path}" \
        || -L "${timing_initialize_journal_path}" ]]; then
        release_timing_journal_validate \
            "${timing_initialize_journal_path}" \
            "${timing_source_commit}" \
            "${timing_source_tree}"
        return
    fi

    timing_journal_directory="$(dirname "${timing_initialize_journal_path}")"
    mkdir -p "${timing_journal_directory}" || return 1
    [[ -d "${timing_journal_directory}" \
        && ! -L "${timing_journal_directory}" ]] || return 1
    chmod 700 "${timing_journal_directory}" || return 1
    timing_temporary_path="$(
        mktemp "${timing_journal_directory}/.release-timing.XXXXXX"
    )" || return 1
    if ! {
        printf 'schema=%s\n' "${MURALUME_RELEASE_TIMING_JOURNAL_SCHEMA}"
        printf 'product=Muralume\n'
        printf 'source_commit=%s\n' "${timing_source_commit}"
        printf 'source_tree=%s\n' "${timing_source_tree}"
    } >"${timing_temporary_path}" \
        || ! chmod 600 "${timing_temporary_path}" \
        || ! mv "${timing_temporary_path}" \
            "${timing_initialize_journal_path}"; then
        rm -f "${timing_temporary_path}"
        return 1
    fi
}

release_timing_journal_append_start() {
    [[ "$#" -eq 5 ]] || return 64
    local timing_start_journal_path="$1"
    local timing_run_identifier="$2"
    local timing_stage="$3"
    local timing_started_at="$4"
    local timing_started_epoch="$5"

    release_timing_journal_is_secure_file "${timing_start_journal_path}" \
        || return 1
    [[ "${timing_run_identifier}" =~ ^[0-9a-f]{64}$ \
        && "${timing_stage}" =~ ^[a-z][a-z0-9_]{0,47}$ \
        && "${timing_started_at}" \
            =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ \
        && "${timing_started_epoch}" =~ ^[0-9]+$ ]] || return 1
    printf 'stage_start\t%s\t%s\t%s\t%s\n' \
        "${timing_run_identifier}" \
        "${timing_stage}" \
        "${timing_started_at}" \
        "${timing_started_epoch}" >>"${timing_start_journal_path}"
}

release_timing_journal_append_finish() {
    [[ "$#" -eq 7 ]] || return 64
    local timing_finish_journal_path="$1"
    local timing_run_identifier="$2"
    local timing_stage="$3"
    local timing_finished_at="$4"
    local timing_finished_epoch="$5"
    local timing_duration_seconds="$6"
    local timing_status="$7"

    release_timing_journal_is_secure_file "${timing_finish_journal_path}" \
        || return 1
    [[ "${timing_run_identifier}" =~ ^[0-9a-f]{64}$ \
        && "${timing_stage}" =~ ^[a-z][a-z0-9_]{0,47}$ \
        && "${timing_finished_at}" \
            =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ \
        && "${timing_finished_epoch}" =~ ^[0-9]+$ \
        && "${timing_duration_seconds}" =~ ^[0-9]+$ \
        && "${timing_status}" \
            =~ ^(passed|failed|reused|skipped|processing|complete)$ ]] \
        || return 1
    printf 'stage_finish\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${timing_run_identifier}" \
        "${timing_stage}" \
        "${timing_finished_at}" \
        "${timing_finished_epoch}" \
        "${timing_duration_seconds}" \
        "${timing_status}" >>"${timing_finish_journal_path}"
}

release_timing_session_initialize() {
    [[ "$#" -eq 3 ]] || return 64
    local timing_session_journal_path="$1"
    local timing_source_commit="$2"
    local timing_source_tree="$3"

    release_timing_journal_initialize \
        "${timing_session_journal_path}" \
        "${timing_source_commit}" \
        "${timing_source_tree}" || return 1
    MURALUME_RELEASE_TIMING_JOURNAL_PATH="${timing_session_journal_path}"
    MURALUME_RELEASE_TIMING_RUN_IDENTIFIER="$(openssl rand -hex 32)" \
        || return 1
    MURALUME_RELEASE_TIMING_ACTIVE_STAGE=''
    MURALUME_RELEASE_TIMING_ACTIVE_STARTED_EPOCH=''
}

release_timing_stage_begin() {
    [[ "$#" -eq 1 ]] || return 64
    local timing_stage="$1"
    local timing_started_at
    local timing_started_epoch

    [[ -n "${MURALUME_RELEASE_TIMING_JOURNAL_PATH}" \
        && -n "${MURALUME_RELEASE_TIMING_RUN_IDENTIFIER}" \
        && -z "${MURALUME_RELEASE_TIMING_ACTIVE_STAGE}" ]] || return 1
    timing_started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" || return 1
    timing_started_epoch="$(date -u '+%s')" || return 1
    release_timing_journal_append_start \
        "${MURALUME_RELEASE_TIMING_JOURNAL_PATH}" \
        "${MURALUME_RELEASE_TIMING_RUN_IDENTIFIER}" \
        "${timing_stage}" \
        "${timing_started_at}" \
        "${timing_started_epoch}" || return 1
    MURALUME_RELEASE_TIMING_ACTIVE_STAGE="${timing_stage}"
    MURALUME_RELEASE_TIMING_ACTIVE_STARTED_EPOCH="${timing_started_epoch}"
}

release_timing_stage_finish() {
    [[ "$#" -eq 1 ]] || return 64
    local timing_status="$1"
    local timing_finished_at
    local timing_finished_epoch
    local timing_duration_seconds

    [[ -n "${MURALUME_RELEASE_TIMING_ACTIVE_STAGE}" \
        && "${MURALUME_RELEASE_TIMING_ACTIVE_STARTED_EPOCH}" \
            =~ ^[0-9]+$ ]] || return 1
    timing_finished_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" || return 1
    timing_finished_epoch="$(date -u '+%s')" || return 1
    [[ "${timing_finished_epoch}" \
        -ge "${MURALUME_RELEASE_TIMING_ACTIVE_STARTED_EPOCH}" ]] || return 1
    timing_duration_seconds=$((
        timing_finished_epoch - MURALUME_RELEASE_TIMING_ACTIVE_STARTED_EPOCH
    ))
    release_timing_journal_append_finish \
        "${MURALUME_RELEASE_TIMING_JOURNAL_PATH}" \
        "${MURALUME_RELEASE_TIMING_RUN_IDENTIFIER}" \
        "${MURALUME_RELEASE_TIMING_ACTIVE_STAGE}" \
        "${timing_finished_at}" \
        "${timing_finished_epoch}" \
        "${timing_duration_seconds}" \
        "${timing_status}" || return 1
    MURALUME_RELEASE_TIMING_ACTIVE_STAGE=''
    MURALUME_RELEASE_TIMING_ACTIVE_STARTED_EPOCH=''
}

release_timing_stage_fail_active() {
    [[ "$#" -eq 0 ]] || return 64
    [[ -n "${MURALUME_RELEASE_TIMING_ACTIVE_STAGE}" ]] || return 0
    release_timing_stage_finish failed
}
