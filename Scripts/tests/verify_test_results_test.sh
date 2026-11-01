#!/usr/bin/env bash

set -euo pipefail

readonly test_script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly project_root="$(cd "${test_script_directory}/../.." && pwd)"

test_root="$(mktemp -d "${TMPDIR:-/tmp}/MuralumeVerifyResults.XXXXXX")"
cleanup() {
    rm -rf "${test_root}"
}
trap cleanup EXIT

fake_bin="${test_root}/bin"
artifacts_path="${test_root}/artifacts"
mkdir -p "${fake_bin}" "${artifacts_path}"

cat > "${fake_bin}/xcodebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

derived_data_path=""
test_specification_path=""
result_bundle_path=""
bundle_identifier=""
needs_build=0

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -derivedDataPath)
            shift
            derived_data_path="$1"
            ;;
        -xctestrun)
            shift
            test_specification_path="$1"
            ;;
        -resultBundlePath)
            shift
            result_bundle_path="$1"
            ;;
        MURALUME_APP_BUNDLE_IDENTIFIER=*)
            bundle_identifier="${1#*=}"
            ;;
        build-for-testing)
            needs_build=1
            ;;
    esac
    shift
done

if [[ "${needs_build}" -eq 1 ]]; then
    # Model generated products rather than bypassing the real identity and
    # attachment-privacy gates in the verification runner.
    python3 - "${derived_data_path}" "${bundle_identifier}" <<'PY'
from pathlib import Path
import plistlib
import sys

products = Path(sys.argv[1]) / "Build/Products"
info = products / "Debug/Muralume.app/Contents/Info.plist"
info.parent.mkdir(parents=True, exist_ok=True)
info.write_bytes(plistlib.dumps({"CFBundleIdentifier": sys.argv[2]}))
targets = {
    name: {
        "TestBundlePath": f"__TESTROOT__/Debug/{name}.xctest",
        "SystemAttachmentLifetime": "keepAlways",
    }
    for name in ("MuralumeTests", "MuralumeUITests")
}
(products / "Muralume-fixture.xctestrun").write_bytes(plistlib.dumps(targets))
PY
    exit 0
fi

# The fake execution must receive the generated specification after the
# production privacy pass, just like test-without-building does in Xcode.
python3 - "${test_specification_path}" <<'PY'
from pathlib import Path
import plistlib
import sys

specification = plistlib.loads(Path(sys.argv[1]).read_bytes())
targets = [target for target in specification.values()
           if isinstance(target, dict) and "TestBundlePath" in target]
if len(targets) != 2 or any(target.get("SystemAttachmentLifetime") != "keepNever"
                            for target in targets):
    raise SystemExit("The test runner did not disable automatic screen attachments")
PY
[[ -n "${result_bundle_path}" ]]
mkdir -p "${result_bundle_path}"
printf '%s\n' "${result_bundle_path}" >> "${FAKE_XCODEBUILD_PATH_LOG}"
exit "${FAKE_XCODEBUILD_STATUS:-0}"
EOF

cat > "${fake_bin}/xcrun" <<'EOF'
#!/usr/bin/env bash
set -u

if [[ "${FAKE_XCRESULTTOOL_STATUS:-0}" -ne 0 ]]; then
    exit "${FAKE_XCRESULTTOOL_STATUS}"
fi
printf '%s\n' "${FAKE_XCRESULT_SUMMARY}"
EOF

chmod +x "${fake_bin}/xcodebuild" "${fake_bin}/xcrun"

readonly passing_summary='{"totalTestCount":1,"passedTests":1,"failedTests":0,"skippedTests":0,"expectedFailures":0,"result":"Passed"}'
readonly zero_tests_summary='{"totalTestCount":0,"passedTests":0,"failedTests":0,"skippedTests":0,"expectedFailures":0,"result":"unknown"}'
readonly failed_summary='{"totalTestCount":1,"passedTests":0,"failedTests":1,"skippedTests":0,"expectedFailures":0,"result":"Failed"}'
readonly skipped_summary='{"totalTestCount":1,"passedTests":0,"failedTests":0,"skippedTests":1,"expectedFailures":0,"result":"Skipped"}'
readonly inconsistent_summary='{"totalTestCount":2,"passedTests":1,"failedTests":0,"skippedTests":0,"expectedFailures":0,"result":"Passed"}'

run_fake_invocation() {
    local summary="$1"
    local invocation_name="$2"
    local xcodebuild_status="${3:-0}"
    local xcresulttool_status="${4:-0}"

    PATH="${fake_bin}:${PATH}" \
    MURALUME_TEST_ARTIFACTS_DIR="${artifacts_path}" \
    MURALUME_TEST_DERIVED_DATA_DIR="${artifacts_path}/DerivedData" \
    FAKE_XCODEBUILD_PATH_LOG="${test_root}/result-paths.log" \
    FAKE_XCODEBUILD_STATUS="${xcodebuild_status}" \
    FAKE_XCRESULTTOOL_STATUS="${xcresulttool_status}" \
    FAKE_XCRESULT_SUMMARY="${summary}" \
        bash -c '
            set -euo pipefail
            source "$1"
            install_verify_lifecycle_traps
            initialize_verify_lifecycle
            mkdir -p "${artifacts_root}"
            run_xcode_test_invocation "$2" test
        ' verify-test "${project_root}/Scripts/verify.sh" "${invocation_name}"
}

expect_failure() {
    local description="$1"
    shift

    if "$@" >/dev/null 2>&1; then
        echo "Expected failure: ${description}" >&2
        exit 1
    fi
}

run_membership_check() {
    local source_directory="$1"

    PATH="${fake_bin}:${PATH}" \
    MURALUME_TEST_ARTIFACTS_DIR="${artifacts_path}" \
    MURALUME_TEST_DERIVED_DATA_DIR="${artifacts_path}/DerivedData" \
        bash -c '
            set -euo pipefail
            source "$1"
            install_verify_lifecycle_traps
            initialize_verify_lifecycle
            assert_test_sources_belong_to_target "$2" FakeTests
        ' verify-test "${project_root}/Scripts/verify.sh" "${source_directory}"
}

run_fake_invocation "${passing_summary}" passing >/dev/null
run_fake_invocation "${passing_summary}" passing >/dev/null

result_path_count="$(wc -l < "${test_root}/result-paths.log" | tr -d '[:space:]')"
unique_result_path_count="$(sort -u "${test_root}/result-paths.log" | wc -l | tr -d '[:space:]')"
if [[ "${result_path_count}" -ne 2 || "${unique_result_path_count}" -ne 2 ]]; then
    echo "Expected every xcodebuild test invocation to use a unique result bundle." >&2
    exit 1
fi

expect_failure \
    "xcodebuild exit 0 with zero executed tests must fail" \
    run_fake_invocation "${zero_tests_summary}" zero-tests
expect_failure \
    "a failed test in xcresult must fail even if xcodebuild exits 0" \
    run_fake_invocation "${failed_summary}" failed-test
expect_failure \
    "a skipped test in xcresult must fail" \
    run_fake_invocation "${skipped_summary}" skipped-test
expect_failure \
    "inconsistent xcresult counts must fail" \
    run_fake_invocation "${inconsistent_summary}" inconsistent
expect_failure \
    "missing required xcresult fields must fail" \
    run_fake_invocation '{"result":"Passed"}' missing-fields
expect_failure \
    "xcresulttool failure must fail closed" \
    run_fake_invocation "${passing_summary}" unreadable-result 0 1
expect_failure \
    "xcodebuild failure must fail even with a passing summary" \
    run_fake_invocation "${passing_summary}" failed-command 65

membership_sources="${test_root}/MembershipTests"
membership_file_list_directory="${artifacts_path}/DerivedData/Build/Intermediates.noindex/Muralume.build/Debug/FakeTests.build/Objects-normal/arm64"
membership_file_list="${membership_file_list_directory}/FakeTests.SwiftFileList"
registered_test_source="${membership_sources}/RegisteredTests.swift"
unregistered_test_source="${membership_sources}/UnregisteredTests.swift"
mkdir -p "${membership_sources}" "${membership_file_list_directory}"
printf '%s\n' \
    'import XCTest' \
    'final class RegisteredTests: XCTestCase {}' \
    > "${registered_test_source}"
printf '%s\n' "${registered_test_source}" > "${membership_file_list}"
run_membership_check "${membership_sources}" >/dev/null

printf '%s\n' \
    'import XCTest' \
    'final class UnregisteredTests: XCTestCase {}' \
    > "${unregistered_test_source}"
expect_failure \
    "an XCTestCase source omitted from the Xcode test target must fail" \
    run_membership_check "${membership_sources}"

extension_membership_sources="${test_root}/ExtensionMembershipTests"
extension_registered_source="${extension_membership_sources}/RegisteredTests.swift"
extension_omitted_source="${extension_membership_sources}/OmittedExtensionTests.swift"
mkdir -p "${extension_membership_sources}"
printf '%s\n' \
    'import XCTest' \
    'final class RegisteredTests: XCTestCase {}' \
    > "${extension_registered_source}"
printf '%s\n' \
    'extension RegisteredTests {' \
    '    func testOmittedBehavior() {}' \
    '}' \
    > "${extension_omitted_source}"
printf '%s\n' "${extension_registered_source}" > "${membership_file_list}"
expect_failure \
    "a test extension source omitted from the Xcode test target must fail" \
    run_membership_check "${extension_membership_sources}"

echo "XCTest result gate fault-injection checks passed."
