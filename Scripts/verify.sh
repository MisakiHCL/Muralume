#!/bin/bash

set -euo pipefail

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly project_root="$(cd "${script_directory}/.." && pwd)"
readonly project_path="${project_root}/Muralume.xcodeproj"
readonly scheme_name="Muralume"
readonly debug_destination="platform=macOS,arch=arm64"
readonly selected_suite="${1:-all}"

# shellcheck source=lib/signing_privacy.sh
source "${script_directory}/lib/signing_privacy.sh"
# shellcheck source=lib/workflow_lifecycle.sh
source "${script_directory}/lib/workflow_lifecycle.sh"
# shellcheck source=lib/build_cache.sh
source "${script_directory}/lib/build_cache.sh"

artifacts_root=""
derived_data_path=""
test_results_root=""
verify_workspace=""
verify_workspace_owned=0
verify_cache_lock_directory=""
verify_cache_lock_owned=0
common_debug_arguments=()

unit_test_selectors=()
integration_test_selectors=()

# Shell infrastructure tests create their own repositories, caches, locks, and
# credentials. Never let a formal parent gate's private overrides leak into a
# nested fixture process.
readonly nested_test_environment_names=(
    MURALUME_TEST_ARTIFACTS_DIR
    MURALUME_TEST_DERIVED_DATA_DIR
    MURALUME_REAL_MEDIA_DIRECTORY
    MURALUME_RELEASE_LOCK_HELD
    MURALUME_RELEASE_LOCK_REEXEC_TOKEN
    MURALUME_RELEASE_STANDALONE_LOCK_PATH
    MURALUME_RELEASE_DUAL_CAPABILITY_PATH
    MURALUME_RELEASE_DUAL_CAPABILITY_TOKEN
    MURALUME_RELEASE_MINIMUM_FREE_GIB
    MURALUME_GITHUB_REPOSITORY
    MURALUME_KEEP_FAILED_WORKDIR
    MURALUME_DEVELOPER_ID_APPLICATION
    MURALUME_NOTARY_KEYCHAIN_PROFILE
    MURALUME_EXPECTED_TEAM_IDENTIFIER
    MURALUME_ASC_KEY_ID
    MURALUME_ASC_ISSUER_ID
    MURALUME_ASC_PRIVATE_KEY_PATH
    RELEASE_TITLE
    RELEASE_NOTES_FILE
    GH_TOKEN
    GITHUB_TOKEN
    GIT_NO_REPLACE_OBJECTS
    GIT_REPLACE_REF_BASE
    HTTP_PROXY
    HTTPS_PROXY
    ALL_PROXY
    http_proxy
    https_proxy
    all_proxy
)

print_usage() {
    cat <<'EOF'
Usage: ./Scripts/verify.sh [suite]

Suites:
  architecture  Check layer boundaries and perform a clean test build.
  unit          Run deterministic domain and application tests.
  integration   Run AVFoundation and real rendering-surface tests.
  ui            Launch the app through XCUITest.
  real-media    Import local media and exercise Dynamic Desktop.
  release       Build an unsigned arm64 Release app.
  release-gate  Run deterministic release checks without GUI automation.
  all           Run every check above (default).

Optional environment:
  MURALUME_TEST_ARTIFACTS_DIR  Caller-owned directory for DerivedData and test
                               results. Muralume never removes this directory.
  MURALUME_TEST_DERIVED_DATA_DIR  Caller-owned stable DerivedData cache. This
                                  overrides only DerivedData, not TestResults.
  MURALUME_REAL_MEDIA_DIRECTORY  Local media directory for real-media.
EOF
}

is_known_suite() {
    case "$1" in
        architecture|unit|integration|ui|real-media|release|release-gate|all)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

suite_uses_test_selectors() {
    case "$1" in
        unit|integration|release-gate|all)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

release_verify_cache_lock() {
    local recorded_pid=""

    [[ "${verify_cache_lock_owned}" -eq 1 \
        && -n "${verify_cache_lock_directory}" ]] || return 0
    if [[ -f "${verify_cache_lock_directory}/owner.pid" \
        && ! -L "${verify_cache_lock_directory}/owner.pid" ]]; then
        IFS= read -r recorded_pid \
            <"${verify_cache_lock_directory}/owner.pid" || true
    fi
    if [[ "${recorded_pid}" == "$$" ]]; then
        rm -rf -- "${verify_cache_lock_directory}"
    fi
    verify_cache_lock_owned=0
}

acquire_verify_cache_lock() {
    local lock_directory="$1"
    local owner_pid=""
    local stale_lock_directory

    verify_cache_lock_directory="${lock_directory}"
    if mkdir "${verify_cache_lock_directory}" 2>/dev/null; then
        chmod 700 "${verify_cache_lock_directory}"
        printf '%s\n' "$$" >"${verify_cache_lock_directory}/owner.pid"
        chmod 600 "${verify_cache_lock_directory}/owner.pid"
        verify_cache_lock_owned=1
        return 0
    fi

    if [[ -L "${verify_cache_lock_directory}" \
        || ! -d "${verify_cache_lock_directory}" \
        || ! -f "${verify_cache_lock_directory}/owner.pid" \
        || -L "${verify_cache_lock_directory}/owner.pid" ]]; then
        echo "The verify build cache lock is invalid: ${verify_cache_lock_directory}" >&2
        return 75
    fi
    IFS= read -r owner_pid <"${verify_cache_lock_directory}/owner.pid" || true
    case "${owner_pid}" in
        ''|*[!0-9]*)
            echo "The verify build cache lock has invalid owner metadata." >&2
            return 75
            ;;
    esac
    if kill -0 "${owner_pid}" 2>/dev/null; then
        printf 'The verify build cache is already in use by process %s.\n' \
            "${owner_pid}" >&2
        return 75
    fi

    stale_lock_directory="${verify_cache_lock_directory}.stale.$$"
    if [[ -e "${stale_lock_directory}" || -L "${stale_lock_directory}" ]]; then
        echo "The stale verify lock quarantine path already exists." >&2
        return 75
    fi
    if ! mv "${verify_cache_lock_directory}" "${stale_lock_directory}"; then
        echo "Another process changed the stale verify build cache lock." >&2
        return 75
    fi
    rm -rf -- "${stale_lock_directory}"

    if ! mkdir "${verify_cache_lock_directory}" 2>/dev/null; then
        echo "Another process acquired the verify build cache lock." >&2
        return 75
    fi
    chmod 700 "${verify_cache_lock_directory}"
    printf '%s\n' "$$" >"${verify_cache_lock_directory}/owner.pid"
    chmod 600 "${verify_cache_lock_directory}/owner.pid"
    verify_cache_lock_owned=1
}

initialize_verify_lifecycle() {
    local cache_scope_root

    if [[ "${MURALUME_TEST_ARTIFACTS_DIR+x}" == "x" ]]; then
        [[ -n "${MURALUME_TEST_ARTIFACTS_DIR}" ]] || {
            echo "MURALUME_TEST_ARTIFACTS_DIR must not be empty." >&2
            return 64
        }
        mkdir -p "${MURALUME_TEST_ARTIFACTS_DIR}"
        artifacts_root="$(cd "${MURALUME_TEST_ARTIFACTS_DIR}" && pwd -P)"
        cache_scope_root="${artifacts_root}"
        derived_data_path="${artifacts_root}/DerivedData"
        test_results_root="${artifacts_root}/TestResults"
    else
        workflow_lifecycle_initialize "${project_root}" || return 1
        verify_workspace="$(workflow_create_workspace verify)" || return 1
        verify_workspace_owned=1
        artifacts_root="${verify_workspace}"
        test_results_root="${verify_workspace}/TestResults"

        if [[ "${MURALUME_TEST_DERIVED_DATA_DIR+x}" != "x" ]]; then
            derived_data_path="$(
                muralume_prepare_xcode_cache "${project_root}" verify
            )" || return 1
            cache_scope_root="$(dirname "${derived_data_path}")"
        fi
    fi

    if [[ "${MURALUME_TEST_DERIVED_DATA_DIR+x}" == "x" ]]; then
        [[ "${MURALUME_TEST_DERIVED_DATA_DIR}" == /* \
            && -n "${MURALUME_TEST_DERIVED_DATA_DIR}" \
            && ! -L "${MURALUME_TEST_DERIVED_DATA_DIR}" ]] || {
            echo "MURALUME_TEST_DERIVED_DATA_DIR must be an absolute non-symlink path." >&2
            return 64
        }
        mkdir -p "${MURALUME_TEST_DERIVED_DATA_DIR}"
        derived_data_path="$(
            cd "${MURALUME_TEST_DERIVED_DATA_DIR}" && pwd -P
        )"
        cache_scope_root="$(dirname "${derived_data_path}")"
    fi

    acquire_verify_cache_lock "${cache_scope_root}/.verify.lock" || return
    common_debug_arguments=(
        -project "${project_path}"
        -scheme "${scheme_name}"
        -configuration Debug
        -destination "${debug_destination}"
        -derivedDataPath "${derived_data_path}"
    )
}

cleanup_verify_lifecycle() {
    local status="$?"

    trap - EXIT HUP INT TERM
    if [[ "${verify_workspace_owned}" -eq 1 \
        && -n "${verify_workspace}" ]]; then
        workflow_safe_remove_workspace "${verify_workspace}" || true
        verify_workspace_owned=0
    fi
    release_verify_cache_lock
    exit "${status}"
}

install_verify_lifecycle_traps() {
    trap cleanup_verify_lifecycle EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

require_command() {
    local command_name="$1"
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        echo "Required command is unavailable: ${command_name}" >&2
        exit 1
    fi
}

run_shell_infrastructure_test() {
    if [[ "$#" -ne 1 ]]; then
        echo "Shell infrastructure test dispatch needs one path." >&2
        return 64
    fi

    local shell_test_path="$1"
    local environment_name
    local -a isolated_environment=(env)

    for environment_name in "${nested_test_environment_names[@]}"; do
        isolated_environment+=(-u "${environment_name}")
    done
    "${isolated_environment[@]}" "${shell_test_path}"
}

reject_imports() {
    local layer_name="$1"
    local source_directory="$2"
    local forbidden_pattern="$3"
    local findings
    local search_status

    if [[ ! -d "${source_directory}" ]]; then
        echo "Expected source directory is missing: ${source_directory}" >&2
        return 1
    fi

    if findings="$(rg -n --glob '*.swift' "${forbidden_pattern}" "${source_directory}")"; then
        printf '%s\n' "${findings}"
        echo "${layer_name} imports a framework outside its allowed boundary." >&2
        return 1
    else
        search_status=$?
    fi
    if [[ "${search_status}" -ne 1 ]]; then
        echo "Could not inspect ${layer_name} imports." >&2
        return "${search_status}"
    fi
}

reject_references() {
    local scope_name="$1"
    local search_location="$2"
    local forbidden_pattern="$3"
    local failure_message="$4"
    local findings
    local search_status

    if [[ ! -e "${search_location}" ]]; then
        echo "Expected architecture input is missing: ${search_location}" >&2
        return 1
    fi

    if findings="$(rg -n "${forbidden_pattern}" "${search_location}")"; then
        printf '%s\n' "${findings}"
        echo "${scope_name}: ${failure_message}" >&2
        return 1
    else
        search_status=$?
    fi
    if [[ "${search_status}" -ne 1 ]]; then
        echo "Could not inspect architecture references in ${scope_name}." >&2
        return "${search_status}"
    fi
}

localization_keys() {
    local strings_file="$1"

    rg -N -o '^"[^"]+"[[:space:]]*=' "${strings_file}" \
        | sed -E 's/^"([^"]+)"[[:space:]]*=$/\1/' \
        | sort
}

check_localization_key_parity() {
    local english_strings="${project_root}/Muralume/Resources/en.lproj/Localizable.strings"
    local chinese_strings="${project_root}/Muralume/Resources/zh-Hans.lproj/Localizable.strings"

    if ! diff -u \
        <(localization_keys "${english_strings}") \
        <(localization_keys "${chinese_strings}"); then
        echo "English and Simplified Chinese localization keys differ." >&2
        return 1
    fi

    echo "Localization key parity checks passed."
}

discover_test_classes() {
    local source_directory="$1"
    local findings
    local search_status

    if [[ ! -d "${source_directory}" ]]; then
        echo "Expected test directory is missing: ${source_directory}" >&2
        return 1
    fi

    if findings="$(
        rg \
            -N \
            --no-filename \
            -o \
            'class [A-Za-z_][A-Za-z0-9_]*: XCTestCase' \
            "${source_directory}"
    )"; then
        printf '%s\n' "${findings}" \
            | sed -E 's/^class ([A-Za-z_][A-Za-z0-9_]*): XCTestCase$/\1/' \
            | sort -u
        return
    else
        search_status=$?
    fi

    if [[ "${search_status}" -eq 1 ]]; then
        echo "No XCTestCase classes found in ${source_directory}." >&2
        return 1
    fi
    echo "Could not discover tests in ${source_directory}." >&2
    return "${search_status}"
}

load_test_selectors() {
    local unit_test_classes
    local integration_test_classes
    local test_class

    unit_test_classes="$(discover_test_classes "${project_root}/MuralumeTests/Unit")"
    integration_test_classes="$(
        discover_test_classes "${project_root}/MuralumeTests/Integration"
    )"

    while IFS= read -r test_class; do
        unit_test_selectors+=("-only-testing:MuralumeTests/${test_class}")
    done <<< "${unit_test_classes}"

    while IFS= read -r test_class; do
        integration_test_selectors+=("-only-testing:MuralumeTests/${test_class}")
    done <<< "${integration_test_classes}"

    readonly unit_test_selectors
    readonly integration_test_selectors
}

xcresult_summary_value() {
    local summary_path="$1"
    local key="$2"
    local value

    if ! value="$(plutil -extract "${key}" raw -o - "${summary_path}" 2>/dev/null)"; then
        echo "Test result summary is missing or has an invalid ${key}: ${summary_path}" >&2
        return 1
    fi
    printf '%s\n' "${value}"
}

xcresult_summary_integer() {
    local summary_path="$1"
    local key="$2"
    local value

    if ! value="$(xcresult_summary_value "${summary_path}" "${key}")"; then
        return 1
    fi
    case "${value}" in
        ''|*[!0-9]*)
            echo "Test result summary has a non-integer ${key}: ${value}" >&2
            return 1
            ;;
    esac
    printf '%s\n' "${value}"
}

assert_xcresult_passed() {
    local result_bundle_path="$1"
    local summary_path="${result_bundle_path}.summary.json"
    local total_count
    local passed_count
    local failed_count
    local skipped_count
    local expected_failure_count
    local result

    if [[ ! -d "${result_bundle_path}" ]]; then
        echo "Expected XCTest result bundle is missing: ${result_bundle_path}" >&2
        return 1
    fi
    if ! xcrun xcresulttool get test-results summary \
        --path "${result_bundle_path}" \
        --compact > "${summary_path}"; then
        echo "Could not read XCTest result summary: ${result_bundle_path}" >&2
        return 1
    fi

    if ! total_count="$(xcresult_summary_integer "${summary_path}" totalTestCount)" ||
        ! passed_count="$(xcresult_summary_integer "${summary_path}" passedTests)" ||
        ! failed_count="$(xcresult_summary_integer "${summary_path}" failedTests)" ||
        ! skipped_count="$(xcresult_summary_integer "${summary_path}" skippedTests)" ||
        ! expected_failure_count="$(
            xcresult_summary_integer "${summary_path}" expectedFailures
        )" ||
        ! result="$(xcresult_summary_value "${summary_path}" result)"; then
        return 1
    fi

    if [[ "${total_count}" -eq 0 ]]; then
        echo "XCTest executed zero tests: ${result_bundle_path}" >&2
        return 1
    fi
    if [[ "${failed_count}" -ne 0 ]]; then
        echo "XCTest reported ${failed_count} failed test(s): ${result_bundle_path}" >&2
        return 1
    fi
    if [[ "${skipped_count}" -ne 0 ]]; then
        echo "XCTest reported ${skipped_count} skipped test(s): ${result_bundle_path}" >&2
        return 1
    fi
    if [[ "${expected_failure_count}" -ne 0 ]]; then
        echo "XCTest reported ${expected_failure_count} expected failure(s): ${result_bundle_path}" >&2
        return 1
    fi
    if [[ "${passed_count}" -ne "${total_count}" ]]; then
        echo \
            "XCTest result counts are inconsistent: total=${total_count}, passed=${passed_count}." \
            >&2
        return 1
    fi
    if [[ "${result}" != "Passed" ]]; then
        echo "XCTest result is not Passed (${result}): ${result_bundle_path}" >&2
        return 1
    fi

    echo \
        "Verified XCTest result: ${passed_count} passed, 0 failed, 0 skipped (${result_bundle_path})."
}

new_test_result_bundle_path() {
    local invocation_name="$1"
    local invocation_directory

    mkdir -p "${test_results_root}"
    invocation_directory="$(
        mktemp -d "${test_results_root}/${invocation_name}.XXXXXX"
    )"
    printf '%s/%s.xcresult\n' "${invocation_directory}" "${invocation_name}"
}

run_xcode_test_invocation() {
    local invocation_name="$1"
    shift
    local result_bundle_path
    local xcodebuild_status=0
    local result_validation_status=0

    result_bundle_path="$(new_test_result_bundle_path "${invocation_name}")"
    echo "Writing XCTest results to ${result_bundle_path}"
    if xcodebuild \
        "${common_debug_arguments[@]}" \
        -resultBundlePath "${result_bundle_path}" \
        "$@"; then
        :
    else
        xcodebuild_status=$?
    fi

    assert_xcresult_passed "${result_bundle_path}" || result_validation_status=$?
    if [[ "${xcodebuild_status}" -ne 0 ]]; then
        echo \
            "xcodebuild test invocation failed with status ${xcodebuild_status}: ${invocation_name}" \
            >&2
        return "${xcodebuild_status}"
    fi
    if [[ "${result_validation_status}" -ne 0 ]]; then
        return "${result_validation_status}"
    fi
}

run_xcode_test_specification() {
    local invocation_name="$1"
    local test_specification_path="$2"
    shift 2
    local result_bundle_path
    local xcodebuild_status=0
    local result_validation_status=0

    result_bundle_path="$(new_test_result_bundle_path "${invocation_name}")"
    echo "Writing XCTest results to ${result_bundle_path}"
    if xcodebuild \
        -xctestrun "${test_specification_path}" \
        -destination "${debug_destination}" \
        -derivedDataPath "${derived_data_path}" \
        -resultBundlePath "${result_bundle_path}" \
        "$@"; then
        :
    else
        xcodebuild_status=$?
    fi

    assert_xcresult_passed "${result_bundle_path}" || result_validation_status=$?
    if [[ "${xcodebuild_status}" -ne 0 ]]; then
        echo \
            "xcodebuild test invocation failed with status ${xcodebuild_status}: ${invocation_name}" \
            >&2
        return "${xcodebuild_status}"
    fi
    if [[ "${result_validation_status}" -ne 0 ]]; then
        return "${result_validation_status}"
    fi
}

assert_test_sources_belong_to_target() {
    local source_directory="$1"
    local target_name="$2"
    local intermediates_root="${derived_data_path}/Build/Intermediates.noindex"
    local source_file
    local source_count=0
    local file_list
    local -a swift_file_lists=()

    while IFS= read -r -d '' file_list; do
        swift_file_lists+=("${file_list}")
    done < <(
        find "${intermediates_root}" \
            -type f \
            -path "*/${target_name}.build/Objects-normal/*/${target_name}.SwiftFileList" \
            -print0
    )

    if [[ "${#swift_file_lists[@]}" -eq 0 ]]; then
        echo "Could not find Xcode Swift source list for test target ${target_name}." >&2
        return 1
    fi

    while IFS= read -r -d '' source_file; do
        source_count=$((source_count + 1))
        if ! rg -F -x -q -- "${source_file}" "${swift_file_lists[@]}"; then
            echo \
                "XCTestCase source is not compiled by ${target_name}: ${source_file}" \
                >&2
            return 1
        fi
    done < <(find "${source_directory}" -type f -name '*.swift' -print0)

    if [[ "${source_count}" -eq 0 ]]; then
        echo "No Swift test source files found in ${source_directory}." >&2
        return 1
    fi
    echo \
        "Verified ${source_count} Swift test source file(s) belong to ${target_name}."
}

check_architecture() {
    local retired_entry
    local shell_test_path
    local shell_test_count=0
    local -a retired_entries=(
        "${project_root}/Muralume/Core"
        "${project_root}/Muralume/Desktop"
        "${project_root}/Muralume/Playback"
        "${project_root}/Muralume/System"
        "${project_root}/Muralume/UI"
        "${project_root}/Muralume/App/AppModel.swift"
        "${project_root}/Muralume/App/UserSelectedMediaSession.swift"
    )

    echo "Checking architecture boundaries..."
    plutil -lint "${project_path}/project.pbxproj"
    check_tracked_signing_privacy "${project_root}"
    check_localization_key_parity
    while IFS= read -r shell_test_path; do
        [[ -n "${shell_test_path}" ]] || continue
        shell_test_count=$((shell_test_count + 1))
        run_shell_infrastructure_test "${shell_test_path}"
    done < <(
        find "${script_directory}/tests" \
            -maxdepth 1 \
            -type f \
            -name '*_test.sh' \
            -print \
            | LC_ALL=C sort
    )
    [[ "${shell_test_count}" -gt 0 ]] || {
        echo "No shell infrastructure tests were discovered." >&2
        return 1
    }

    reject_imports \
        "Domain" \
        "${project_root}/Muralume/Domain" \
        '^import (AppKit|AVFoundation|Combine|SwiftUI|GRDB)$'

    reject_imports \
        "Application" \
        "${project_root}/Muralume/Application" \
        '^import (AppKit|AVFoundation|SwiftUI|GRDB)$'

    reject_imports \
        "Features" \
        "${project_root}/Muralume/Features" \
        '^import (AVFoundation|GRDB)$'

    reject_references \
        "Application" \
        "${project_root}/Muralume/Application" \
        '\b(AVFoundationPlaybackEngine|MacDesktopHost|MacMainWindowPresenter|MacMediaSourcePicker|PlayerLayerSurfaceView|SystemLifecycleMonitor|UserSelectedMediaSession)\b' \
        "application code references a concrete infrastructure type."

    reject_references \
        "Features" \
        "${project_root}/Muralume/Features" \
        '\b(AppCoordinator|AVFoundationPlaybackEngine|MacDesktopHost|MacMainWindowPresenter|MacMediaSourcePicker|PlayerLayerSurfaceView|UserSelectedMediaSession)\b' \
        "feature code references App or a concrete infrastructure type."

    reject_references \
        "Player controls" \
        "${project_root}/Muralume/Features/Player/PlayerControlBar.swift" \
        '\.keyboardShortcut\(' \
        "player shortcuts must have a single owner in the app command menu."

    reject_references \
        "App menu ownership" \
        "${project_root}/Muralume/App" \
        '\b(CommandMenu|CommandGroup|SettingsLink|commandsRemoved|commandsReplaced)\b|NSMenu\.didAddItemNotification' \
        "the AppKit main menu must not be replaced or pruned by a SwiftUI command graph."

    reject_references \
        "In-window settings" \
        "${project_root}/Muralume" \
        '\b(MacSettingsWindowController|MuralumeSettingsRootView|settingsWindowWidth|settingsWindowHeight)\b' \
        "settings must stay inside the single player window."

    reject_references \
        "Settings presentation" \
        "${project_root}/Muralume/Features/Settings/SettingsView.swift" \
        '\.(sheet|popover)\(|\b(NSWindow|NSPanel|UserDefaultsAppPreferencesStore)\b' \
        "settings must use the shared player side-panel slot and injected state."

    reject_references \
        "Settings side-panel glass" \
        "${project_root}/Muralume/Features/Settings/SettingsView.swift" \
        '\.muralumePanel\(' \
        "the stable PlayerScreen side-panel shell must own the only Material."

    reject_references \
        "Playlist side-panel glass" \
        "${project_root}/Muralume/Features/Library/LibraryQueueSidebar.swift" \
        '\.muralumePanel\(' \
        "the stable PlayerScreen side-panel shell must own the only Material."

    for retired_entry in "${retired_entries[@]}"; do
        if [[ -e "${retired_entry}" ]]; then
            echo "Retired source entry still exists: ${retired_entry}" >&2
            return 1
        fi
    done

    reject_references \
        "Xcode project" \
        "${project_path}/project.pbxproj" \
        '(AppModel|AppConstants|PlaybackModels|MacSystemConstants)\.swift' \
        "the project references a retired source file."

    echo "Static architecture checks passed."
}

build_for_testing() {
    xcodebuild "${common_debug_arguments[@]}" build-for-testing
}

verify_architecture() {
    check_architecture
    build_for_testing
}

run_unit_tests() {
    run_xcode_test_invocation \
        unit \
        "${unit_test_selectors[@]}" \
        test
    assert_test_sources_belong_to_target \
        "${project_root}/MuralumeTests/Unit" \
        MuralumeTests
}

run_integration_tests() {
    run_xcode_test_invocation \
        integration \
        "${integration_test_selectors[@]}" \
        test
    assert_test_sources_belong_to_target \
        "${project_root}/MuralumeTests/Integration" \
        MuralumeTests
}

run_ui_tests() {
    run_xcode_test_invocation \
        ui \
        -only-testing:MuralumeUITests \
        -skip-testing:MuralumeUITests/MuralumeRealMediaTests \
        test
    assert_test_sources_belong_to_target \
        "${project_root}/MuralumeUITests" \
        MuralumeUITests
}

run_real_media_tests() {
    local test_specification_path
    local media_file_path=""
    local media_file_size=""
    local candidate_path
    local candidate_size

    if [[ -z "${MURALUME_REAL_MEDIA_DIRECTORY:-}" \
        || ! -d "${MURALUME_REAL_MEDIA_DIRECTORY}" ]]; then
        echo "real-media requires a readable MURALUME_REAL_MEDIA_DIRECTORY." >&2
        return 64
    fi

    while IFS= read -r -d '' candidate_path; do
        candidate_size="$(stat -f '%z' "${candidate_path}")"
        if [[ -z "${media_file_path}" \
            || "${candidate_size}" -lt "${media_file_size}" \
            || ( "${candidate_size}" -eq "${media_file_size}" \
                && "${candidate_path}" < "${media_file_path}" ) ]]; then
            media_file_path="${candidate_path}"
            media_file_size="${candidate_size}"
        fi
    done < <(
        find "${MURALUME_REAL_MEDIA_DIRECTORY}" \
            -maxdepth 1 \
            -type f \
            -iname '*.mp4' \
            -print0
    )
    if [[ -z "${media_file_path}" ]]; then
        echo "No MP4 file exists in MURALUME_REAL_MEDIA_DIRECTORY." >&2
        return 66
    fi

    build_for_testing
    test_specification_path="$(
        find "${derived_data_path}/Build/Products" \
            -maxdepth 1 \
            -type f \
            -name '*.xctestrun' \
            -print \
            -quit
    )"
    if [[ -z "${test_specification_path}" ]]; then
        echo "Could not find the generated XCTest run specification." >&2
        return 1
    fi
    if plutil \
        -extract MuralumeUITests.EnvironmentVariables.MURALUME_REAL_MEDIA_FILE \
        raw \
        -o /dev/null \
        "${test_specification_path}" 2>/dev/null; then
        plutil \
            -replace MuralumeUITests.EnvironmentVariables.MURALUME_REAL_MEDIA_FILE \
            -string "${media_file_path}" \
            "${test_specification_path}"
    else
        plutil \
            -insert MuralumeUITests.EnvironmentVariables.MURALUME_REAL_MEDIA_FILE \
            -string "${media_file_path}" \
            "${test_specification_path}"
    fi

    run_xcode_test_specification \
        real-media \
        "${test_specification_path}" \
        -only-testing:MuralumeUITests/MuralumeRealMediaTests \
        test-without-building
    assert_test_sources_belong_to_target \
        "${project_root}/MuralumeUITests" \
        MuralumeUITests
}

run_non_ui_debug_tests_without_building() {
    run_xcode_test_invocation \
        non-ui \
        -only-testing:MuralumeTests \
        test-without-building
    assert_test_sources_belong_to_target \
        "${project_root}/MuralumeTests" \
        MuralumeTests
}

run_ui_tests_without_building() {
    run_xcode_test_invocation \
        ui-without-building \
        -only-testing:MuralumeUITests \
        -skip-testing:MuralumeUITests/MuralumeRealMediaTests \
        test-without-building
    assert_test_sources_belong_to_target \
        "${project_root}/MuralumeUITests" \
        MuralumeUITests
}

run_all_debug_tests_without_building() {
    run_non_ui_debug_tests_without_building
    run_ui_tests_without_building
}

check_bundled_resources() {
    local app_bundle="${derived_data_path}/Build/Products/Debug/Muralume.app"
    local test_bundle="${app_bundle}/Contents/PlugIns/MuralumeTests.xctest"
    local -a required_resources=(
        "${app_bundle}/Contents/Resources/AppIcon.icns"
        "${app_bundle}/Contents/Resources/Assets.car"
        "${app_bundle}/Contents/Resources/PrivacyInfo.xcprivacy"
        "${app_bundle}/Contents/Resources/en.lproj/Localizable.strings"
        "${app_bundle}/Contents/Resources/zh-Hans.lproj/Localizable.strings"
        "${test_bundle}/Contents/Resources/landscape-20s-h264.mp4"
        "${test_bundle}/Contents/Resources/portrait-20s-h264.mp4"
    )
    local resource_path

    for resource_path in "${required_resources[@]}"; do
        if [[ ! -f "${resource_path}" ]]; then
            echo "Expected bundled resource is missing: ${resource_path}" >&2
            return 1
        fi
    done

    echo "Bundled resource checks passed."
}

build_release() {
    xcodebuild \
        -project "${project_path}" \
        -scheme "${scheme_name}" \
        -configuration Release \
        -destination "generic/platform=macOS" \
        -derivedDataPath "${derived_data_path}" \
        CODE_SIGNING_ALLOWED=NO \
        build
}

run_all() {
    check_architecture
    build_for_testing
    run_all_debug_tests_without_building
    check_bundled_resources
    build_release
}

run_release_gate() {
    check_architecture
    build_for_testing
    run_non_ui_debug_tests_without_building
    check_bundled_resources
    build_release
}

main() {
    case "${selected_suite}" in
        help|-h|--help)
            print_usage
            return
            ;;
    esac
    if ! is_known_suite "${selected_suite}"; then
        echo "Unknown suite: ${selected_suite}" >&2
        print_usage >&2
        return 64
    fi

    require_command rg
    require_command plutil
    require_command xcodebuild
    require_command xcrun
    install_verify_lifecycle_traps
    initialize_verify_lifecycle
    mkdir -p "${artifacts_root}"
    if suite_uses_test_selectors "${selected_suite}"; then
        load_test_selectors
    fi

    case "${selected_suite}" in
        architecture)
            verify_architecture
            ;;
        unit)
            run_unit_tests
            ;;
        integration)
            run_integration_tests
            ;;
        ui)
            run_ui_tests
            ;;
        real-media)
            run_real_media_tests
            ;;
        release)
            build_release
            ;;
        release-gate)
            run_release_gate
            ;;
        all)
            run_all
            ;;
    esac
    if [[ "${verify_workspace_owned}" -eq 1 ]]; then
        echo "DerivedData cache: ${derived_data_path}"
    else
        echo "Artifacts: ${artifacts_root}"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
