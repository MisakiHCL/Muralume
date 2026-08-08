#!/bin/bash

set -euo pipefail

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly project_root="$(cd "${script_directory}/.." && pwd)"
readonly project_path="${project_root}/Muralume.xcodeproj"
readonly scheme_name="Muralume"
readonly debug_destination="platform=macOS,arch=arm64"
readonly selected_suite="${1:-all}"

readonly artifacts_root="${MURALUME_TEST_ARTIFACTS_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/MuralumeVerify.XXXXXX")}"
readonly derived_data_path="${artifacts_root}/DerivedData"

readonly -a common_debug_arguments=(
    -project "${project_path}"
    -scheme "${scheme_name}"
    -configuration Debug
    -destination "${debug_destination}"
    -derivedDataPath "${derived_data_path}"
)

unit_test_selectors=()
integration_test_selectors=()

print_usage() {
    cat <<'EOF'
Usage: ./Scripts/verify.sh [suite]

Suites:
  architecture  Check layer boundaries and perform a clean test build.
  unit          Run deterministic domain and application tests.
  integration   Run AVFoundation and real rendering-surface tests.
  ui            Launch the app through XCUITest.
  release       Build an unsigned arm64 Release app.
  release-gate  Run deterministic release checks without GUI automation.
  all           Run every check above (default).

Optional environment:
  MURALUME_TEST_ARTIFACTS_DIR  Directory for DerivedData and test results.
EOF
}

require_command() {
    local command_name="$1"
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        echo "Required command is unavailable: ${command_name}" >&2
        exit 1
    fi
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

check_architecture() {
    local retired_entry
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
    check_localization_key_parity
    "${script_directory}/tests/secure_timestamp_test.sh"

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
    xcodebuild \
        "${common_debug_arguments[@]}" \
        "${unit_test_selectors[@]}" \
        test
}

run_integration_tests() {
    xcodebuild \
        "${common_debug_arguments[@]}" \
        "${integration_test_selectors[@]}" \
        test
}

run_ui_tests() {
    xcodebuild \
        "${common_debug_arguments[@]}" \
        -only-testing:MuralumeUITests \
        test
}

run_non_ui_debug_tests_without_building() {
    xcodebuild \
        "${common_debug_arguments[@]}" \
        -only-testing:MuralumeTests \
        test-without-building
}

run_ui_tests_without_building() {
    xcodebuild \
        "${common_debug_arguments[@]}" \
        -only-testing:MuralumeUITests \
        test-without-building
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

require_command rg
require_command plutil
require_command xcodebuild
mkdir -p "${artifacts_root}"
load_test_selectors

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
    release)
        build_release
        ;;
    release-gate)
        run_release_gate
        ;;
    all)
        run_all
        ;;
    help|-h|--help)
        print_usage
        ;;
    *)
        echo "Unknown suite: ${selected_suite}" >&2
        print_usage >&2
        exit 64
        ;;
esac

echo "Artifacts: ${artifacts_root}"
