#!/usr/bin/env bash

# Run or safely reuse the one all-suite gate shared by both release endpoints.
# The caller owns source_checkout_path/source_checkout_registered so its EXIT
# trap can still reclaim a checkout after interruption.

run_or_reuse_shared_release_gate() {
    [[ "$#" -eq 8 ]] || return 64
    local gate_project_root="$1"
    local gate_managed_root="$2"
    local gate_work_directory="$3"
    local gate_receipt_path="$4"
    local gate_source_commit="$5"
    local gate_source_tree="$6"
    local gate_source_checkout_parent="$7"
    local gate_source_checkout_path="$8"
    local gate_artifacts_path
    local gate_derived_data_path

    if [[ -e "${gate_receipt_path}" || -L "${gate_receipt_path}" ]]; then
        validate_release_gate_receipt \
            "${gate_receipt_path}" \
            "${gate_project_root}" \
            "${gate_source_commit}" \
            "${gate_source_tree}" || return 1
        printf 'Reusing the persistent all-suite release gate for %s.\n' \
            "${gate_source_commit}"
        return 10
    fi

    mkdir -p "${gate_source_checkout_parent}" || return 1
    chmod 700 \
        "${gate_managed_root}/checkouts" \
        "${gate_source_checkout_parent}" || return 1
    release_reclaim_managed_worktree \
        "${gate_project_root}" "${gate_source_checkout_path}" || return 1
    release_git -C "${gate_project_root}" worktree add --detach \
        "${gate_source_checkout_path}" "${gate_source_commit}" \
        >/dev/null || return 1
    source_checkout_path="${gate_source_checkout_path}"
    source_checkout_registered=1
    verify_release_source_snapshot \
        "${gate_source_checkout_path}" \
        "${gate_source_commit}" \
        "${gate_source_tree}" || return 1

    gate_artifacts_path="${gate_work_directory}/GateArtifacts"
    gate_derived_data_path="$(
        muralume_prepare_xcode_cache "${gate_project_root}" release-gate
    )" || return 1
    printf 'Running the shared all-suite release gate for %s...\n' \
        "${gate_source_commit}"
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
        "${gate_source_checkout_path}/Scripts/verify.sh" all || return 1
    verify_release_source_snapshot \
        "${gate_source_checkout_path}" \
        "${gate_source_commit}" \
        "${gate_source_tree}" || return 1
    write_release_gate_receipt \
        "${gate_receipt_path}" \
        "${gate_project_root}" \
        "${gate_source_commit}" \
        "${gate_source_tree}" || return 1
    validate_release_gate_receipt \
        "${gate_receipt_path}" \
        "${gate_project_root}" \
        "${gate_source_commit}" \
        "${gate_source_tree}" || return 1

    release_git -C "${gate_project_root}" worktree remove --force \
        "${gate_source_checkout_path}" >/dev/null || return 1
    source_checkout_registered=0
    source_checkout_path=''
}
