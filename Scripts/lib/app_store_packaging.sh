#!/usr/bin/env bash

# Run only Xcode's App Store archive/export subprocesses with install-safe file
# permissions. The parent workflow keeps umask 077 so its logs, export options,
# and signing metadata remain private inside a mode-0700 work directory.
run_app_store_packaging_process() (
    umask 022
    exec "$@"
)

run_app_store_packaging_command() {
    if [[ "$#" -lt 3 ]]; then
        echo "App Store packaging needs a stage, a private log, and a command." >&2
        return 64
    fi

    local packaging_stage_name="$1"
    local packaging_private_log_path="$2"
    shift 2

    run_private_command \
        "${packaging_stage_name}" \
        "${packaging_private_log_path}" \
        run_app_store_packaging_process \
        "$@"
}
