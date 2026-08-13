#!/usr/bin/env bash

set -euo pipefail
umask 077

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly project_root="$(cd "${script_directory}/../.." && pwd)"

test_root="$(
    mktemp -d "${TMPDIR:-/tmp}/MuralumeDualReleaseStateTests.XXXXXX"
)"
cleanup() {
    local exit_code="$?"
    rm -rf "${test_root}"
    trap - EXIT
    exit "${exit_code}"
}
trap cleanup EXIT

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    if [[ -n "${release_output:-}" ]]; then
        printf '%s\n' '--- release output ---' >&2
        printf '%s\n' "${release_output}" >&2
    fi
    exit 1
}

readonly fixture_repository="${test_root}/repository"
readonly fixture_origin="${test_root}/origin.git"
readonly fake_bin="${test_root}/bin"
readonly remote_assets="${test_root}/remote-assets"
readonly github_state_path="${test_root}/github-state"
readonly github_assets_state_path="${test_root}/github-assets-state"
readonly invocation_log_path="${test_root}/invocations.log"
readonly private_key_path="${test_root}/AuthKey_FIXTURE.p8"
readonly release_tag='v9.9.9'

mkdir -p \
    "${fixture_repository}/Config" \
    "${fixture_repository}/Scripts/lib" \
    "${fake_bin}" \
    "${remote_assets}"

cp "${project_root}/Scripts/release_dual.sh" \
    "${fixture_repository}/Scripts/release_dual.sh"
for helper_name in \
    app_store_connect_api.sh \
    build_cache.sh \
    release_gate_receipt.sh \
    release_provenance.sh \
    release_source_snapshot.sh \
    release_github_state.sh \
    release_shared_gate.sh \
    release_timing_journal.sh; do
    cp "${project_root}/Scripts/lib/${helper_name}" \
        "${fixture_repository}/Scripts/lib/${helper_name}"
done

printf '%s\n' \
    'MARKETING_VERSION = 9.9.9' \
    'CURRENT_PROJECT_VERSION = 1' \
    >"${fixture_repository}/Config/Base.xcconfig"
printf '%s\n' \
    'MARKETING_VERSION = 9.9.9' \
    'CURRENT_PROJECT_VERSION = 2' \
    >"${fixture_repository}/Config/AppStore.xcconfig"
printf '%s\n' '.build/' 'dist/' \
    >"${fixture_repository}/.gitignore"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "verify %s\n" "$1" >>"${FAKE_INVOCATION_LOG}"' \
    'exit 0' \
    >"${fixture_repository}/Scripts/verify.sh"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'exit 0' \
    >"${fixture_repository}/Scripts/release_doctor.sh"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" prepare_distribution_requirements >>"${FAKE_INVOCATION_LOG}"' \
    'exit 97' \
    >"${fixture_repository}/Scripts/prepare_distribution_requirements.sh"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" release_macos >>"${FAKE_INVOCATION_LOG}"' \
    'exit 98' \
    >"${fixture_repository}/Scripts/release_macos.sh"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" release_app_store >>"${FAKE_INVOCATION_LOG}"' \
    'exit 99' \
    >"${fixture_repository}/Scripts/release_app_store.sh"
chmod 755 "${fixture_repository}/Scripts/"*.sh

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "Xcode 26.1.1\n"' \
    'printf "Build version %s\n" "${FAKE_XCODE_BUILD:-17B100}"' \
    >"${fake_bin}/xcodebuild"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'exit 0' \
    >"${fake_bin}/sleep"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "/usr/bin/lockf -t 0 -k %s %s\n" \' \
    '    "${FAKE_RELEASE_LOCK_PATH}" "${FAKE_RELEASE_SCRIPT_PATH}"' \
    >"${fake_bin}/ps"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'output_path=""' \
    'endpoint=""' \
    'while [[ "$#" -gt 0 ]]; do' \
    '    case "$1" in' \
    '        --output)' \
    '            output_path="$2"' \
    '            shift 2' \
    '            ;;' \
    '        http://*|https://*)' \
    '            endpoint="$1"' \
    '            shift' \
    '            ;;' \
    '        *)' \
    '            shift' \
    '            ;;' \
    '    esac' \
    'done' \
    'while IFS= read -r _ignored; do :; done' \
    '[[ -n "${output_path}" && -n "${endpoint}" ]] || exit 2' \
    'case "${endpoint}" in' \
    '    */v1/apps)' \
    '        printf "%s\n" '\''{"data":[{"id":"fixture-app"}]}'\'' \' \
    '            >"${output_path}"' \
    '        ;;' \
    '    */v1/preReleaseVersions)' \
    '        printf '\''{"data":[],"included":[{"type":"builds","attributes":{"version":"%s","processingState":"%s"}}]}\n'\'' \' \
    '            "${FAKE_APP_STORE_BUILD}" "${FAKE_TESTFLIGHT_STATE}" \' \
    '            >"${output_path}"' \
    '        ;;' \
    '    *)' \
    '        exit 3' \
    '        ;;' \
    'esac' \
    'printf 200' \
    >"${fake_bin}/curl"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'if [[ "$1" == "release" && "$2" == "view" ]]; then' \
    '    json_fields=""' \
    '    previous=""' \
    '    for argument in "$@"; do' \
    '        if [[ "${previous}" == "--json" ]]; then' \
    '            json_fields="${argument}"' \
    '            break' \
    '        fi' \
    '        previous="${argument}"' \
    '    done' \
    '    if [[ "${json_fields}" == "assets" ]]; then' \
    '        case "$(cat "${FAKE_GITHUB_ASSETS_STATE_PATH}")" in' \
    '            exact)' \
    '                printf "Muralume.dmg\nMuralume.dmg.sha256\nMuralume.release-provenance\n"' \
    '                ;;' \
    '            legacy)' \
    '                printf "Muralume.dmg\nMuralume.dmg.sha256\n"' \
    '                ;;' \
    '            extra)' \
    '                printf "Muralume.dmg\nMuralume.dmg.sha256\nMuralume.release-provenance\nsurprise.zip\n"' \
    '                ;;' \
    '            *)' \
    '                exit 4' \
    '                ;;' \
    '        esac' \
    '    else' \
    '        release_state="$(cat "${FAKE_GITHUB_STATE_PATH}")"' \
    '        draft=false' \
    '        [[ "${release_state}" != "draft" ]] || draft=true' \
    '        printf "%s\t%s\tfalse\thttps://example.invalid/release\n" \' \
    '            "${FAKE_RELEASE_TAG}" "${draft}"' \
    '    fi' \
    'elif [[ "$1" == "release" && "$2" == "download" ]]; then' \
    '    destination=""' \
    '    pattern=""' \
    '    while [[ "$#" -gt 0 ]]; do' \
    '        case "$1" in' \
    '            --dir)' \
    '                destination="$2"' \
    '                shift 2' \
    '                ;;' \
    '            --pattern)' \
    '                pattern="$2"' \
    '                shift 2' \
    '                ;;' \
    '            *)' \
    '                shift' \
    '                ;;' \
    '        esac' \
    '    done' \
    '    cp "${FAKE_REMOTE_ASSETS}/${pattern}" "${destination}/${pattern}"' \
    'elif [[ "$1" == "release" && "$2" == "edit" ]]; then' \
    '    printf "%s\n" final >"${FAKE_GITHUB_STATE_PATH}"' \
    'elif [[ "$1" == "release" && "$2" == "upload" ]]; then' \
    '    uploaded_path="$4"' \
    '    uploaded_name="$(basename "${uploaded_path}")"' \
    '    printf "gh_release_upload %s\n" "${uploaded_name}" >>"${FAKE_INVOCATION_LOG}"' \
    '    cp "${uploaded_path}" "${FAKE_REMOTE_ASSETS}/${uploaded_name}"' \
    '    if [[ "${uploaded_name}" == "Muralume.release-provenance" ]]; then' \
    '        printf "%s\n" exact >"${FAKE_GITHUB_ASSETS_STATE_PATH}"' \
    '    fi' \
    'elif [[ "$1" == "api" ]]; then' \
    '    case "$2" in' \
    '        */commits/*)' \
    '            printf "%s\n" "${FAKE_SOURCE_COMMIT}"' \
    '            ;;' \
    '        */releases/latest)' \
    '            printf "%s\n" "${FAKE_RELEASE_TAG}"' \
    '            ;;' \
    '        *)' \
    '            exit 6' \
    '            ;;' \
    '    esac' \
    'else' \
    '    exit 7' \
    'fi' \
    >"${fake_bin}/gh"
chmod 755 "${fake_bin}/"*

git -C "${fixture_repository}" init -q
git -C "${fixture_repository}" checkout -qb main
git -C "${fixture_repository}" config user.name 'Dual Release Test'
git -C "${fixture_repository}" config user.email \
    'dual-release-test@example.invalid'
git -C "${fixture_repository}" add .
git -C "${fixture_repository}" commit -qm 'fixture release source'

source_commit="$(git -C "${fixture_repository}" rev-parse 'HEAD^{commit}')"
source_tree="$(git -C "${fixture_repository}" rev-parse 'HEAD^{tree}')"
printf '%s\n' 'signed fixture DMG bytes' \
    >"${remote_assets}/Muralume.dmg"
release_digest="$(
    shasum -a 256 "${remote_assets}/Muralume.dmg" | awk '{ print $1 }'
)"
printf '%s  Muralume.dmg\n' "${release_digest}" \
    >"${remote_assets}/Muralume.dmg.sha256"

mkdir -p \
    "${fixture_repository}/dist/macos-release" \
    "${fixture_repository}/dist/releases"
cp "${remote_assets}/Muralume.dmg" \
    "${fixture_repository}/dist/macos-release/Muralume.dmg"
cp "${remote_assets}/Muralume.dmg.sha256" \
    "${fixture_repository}/dist/macos-release/Muralume.dmg.sha256"
release_manifest_path="${fixture_repository}/dist/releases/${release_tag}.manifest"
printf '%s\n' \
    'schema=1' \
    'product=Muralume' \
    "source_commit=${source_commit}" \
    "source_tree=${source_tree}" \
    "dmg_sha256=${release_digest}" \
    'app_store_version=9.9.9' \
    'app_store_build=2' \
    >"${release_manifest_path}"
chmod 600 "${release_manifest_path}"
cp "${release_manifest_path}" \
    "${remote_assets}/Muralume.release-provenance"

git -C "${fixture_repository}" tag -a "${release_tag}" \
    -m 'Muralume 9.9.9' \
    -m "Muralume-Source-Commit: ${source_commit}" \
    -m "Muralume-Source-Tree: ${source_tree}" \
    -m "Muralume-DMG-SHA256: ${release_digest}" \
    -m 'Muralume-App-Store-Version: 9.9.9' \
    -m 'Muralume-App-Store-Build: 2'
git init --bare -q "${fixture_origin}"
git -C "${fixture_repository}" remote add origin "${fixture_origin}"
git -C "${fixture_repository}" push -q -u origin \
    main "refs/tags/${release_tag}"

mkdir -p "${fixture_repository}/dist/app-store"
upload_receipt_path="${fixture_repository}/dist/app-store/Muralume-9.9.9-2-upload.txt"
printf '%s\n' \
    'product=Muralume' \
    'marketing_version=9.9.9' \
    'build_number=2' \
    "source_commit=${source_commit}" \
    "source_tree=${source_tree}" \
    >"${upload_receipt_path}"
chmod 600 "${upload_receipt_path}"

openssl ecparam -name prime256v1 -genkey -noout \
    -out "${private_key_path}" 2>/dev/null
chmod 600 "${private_key_path}"

release_output=''
release_exit_code=0
selected_fake_xcode_build='17B100'
run_release() {
    local github_state="$1"
    local github_assets="$2"
    local testflight_state="$3"
    shift 3

    printf '%s\n' "${github_state}" >"${github_state_path}"
    printf '%s\n' "${github_assets}" >"${github_assets_state_path}"
    : >"${invocation_log_path}"
    set +e
    release_output="$(
        env \
            PATH="${fake_bin}:${PATH}" \
            FAKE_APP_STORE_BUILD=2 \
            FAKE_XCODE_BUILD="${selected_fake_xcode_build}" \
            FAKE_GITHUB_ASSETS_STATE_PATH="${github_assets_state_path}" \
            FAKE_GITHUB_STATE_PATH="${github_state_path}" \
            FAKE_INVOCATION_LOG="${invocation_log_path}" \
            FAKE_RELEASE_LOCK_PATH="${fixture_repository}/.build/muralume/locks/release.lock" \
            FAKE_RELEASE_SCRIPT_PATH="${fixture_repository}/Scripts/release_dual.sh" \
            FAKE_RELEASE_TAG="${release_tag}" \
            FAKE_REMOTE_ASSETS="${remote_assets}" \
            FAKE_SOURCE_COMMIT="${source_commit}" \
            FAKE_TESTFLIGHT_STATE="${testflight_state}" \
            MURALUME_ASC_ISSUER_ID='11111111-2222-3333-4444-555555555555' \
            MURALUME_ASC_KEY_ID='ABCDE12345' \
            MURALUME_ASC_PRIVATE_KEY_PATH="${private_key_path}" \
            MURALUME_ASC_BUILD_POLL_ATTEMPTS=1 \
            MURALUME_GITHUB_REPOSITORY='Fixture/Muralume' \
            "${fixture_repository}/Scripts/release_dual.sh" "$@" 2>&1
    )"
    release_exit_code="$?"
    set -e
}

run_release final exact PROCESSING --status
[[ "${release_exit_code}" -ne 0 ]] \
    || fail_test 'PROCESSING unexpectedly produced a successful status'
printf '%s\n' "${release_output}" \
    | grep -F '[BLOCKED] TestFlight build exists remotely (PROCESSING)' \
        >/dev/null \
    || fail_test 'PROCESSING was not reported as blocked'
if printf '%s\n' "${release_output}" \
    | grep -F '[PASS] TestFlight' >/dev/null; then
    fail_test 'PROCESSING was reported as a complete TestFlight publication'
fi

run_release final exact VALID --status
[[ "${release_exit_code}" -eq 0 ]] \
    || fail_test 'VALID with matching provenance and exact assets did not pass'
printf '%s\n' "${release_output}" \
    | grep -F '[PASS] TestFlight build exists remotely (VALID)' >/dev/null \
    || fail_test 'VALID TestFlight state did not report PASS'
printf '%s\n' "${release_output}" \
    | grep -F '[PASS] Final latest GitHub Release:' >/dev/null \
    || fail_test 'the exact three-asset final GitHub Release did not report PASS'

run_release final extra VALID --status
[[ "${release_exit_code}" -ne 0 ]] \
    || fail_test 'a GitHub Release containing an extra asset passed status'
if printf '%s\n' "${release_output}" \
    | grep -F '[PASS] Final latest GitHub Release:' >/dev/null; then
    fail_test 'a GitHub Release containing an extra asset reported PASS'
fi

run_release draft exact VALID --title 'Fixture release'
[[ "${release_exit_code}" -eq 0 ]] \
    || fail_test 'an exact valid draft could not resume to completion'
[[ "$(cat "${github_state_path}")" == 'final' ]] \
    || fail_test 'the exact valid draft was not finalized'
[[ "$(<"${invocation_log_path}")" == 'verify all' ]] \
    || fail_test 'the first exact draft did not run exactly one all-suite gate'
printf '%s\n' "${release_output}" \
    | grep -F 'Developer ID build will not be repeated.' >/dev/null \
    || fail_test 'the exact draft did not take the no-rebuild recovery path'

run_release final exact PROCESSING \
    --title 'Fixture processing recovery'
[[ "${release_exit_code}" -ne 0 ]] \
    || fail_test 'a still-processing TestFlight build completed publication'
[[ ! -s "${invocation_log_path}" ]] \
    || fail_test 'PROCESSING recovery reran the gate, build, or upload'
printf '%s\n' "${release_output}" \
    | grep -F 'Reusing the persistent all-suite release gate' >/dev/null \
    || fail_test 'PROCESSING recovery did not reuse the persistent gate'
printf '%s\n' "${release_output}" \
    | grep -F 'without rebuilding or uploading' >/dev/null \
    || fail_test 'PROCESSING recovery did not stop with resumable guidance'
timing_journal_path="$(
    find "${fixture_repository}/.build/muralume/release-state" \
        -type f -name timing.journal -print -quit
)"
[[ -n "${timing_journal_path}" ]] \
    || fail_test 'PROCESSING recovery did not persist a timing journal'
grep -E \
    $'^stage_finish\t[0-9a-f]{64}\ttestflight_processing\t[^\t]+\t[0-9]+\t[0-9]+\tprocessing$' \
    "${timing_journal_path}" >/dev/null \
    || fail_test 'PROCESSING recovery was not journaled as processing'
if grep -E \
    $'^stage_finish\t[0-9a-f]{64}\ttestflight_processing\t[^\t]+\t[0-9]+\t[0-9]+\tfailed$' \
    "${timing_journal_path}" >/dev/null; then
    fail_test 'external TestFlight processing was journaled as a failure'
fi

rm -f "${upload_receipt_path}"
run_release final exact PROCESSING \
    --title 'Fixture durable processing recovery'
[[ "${release_exit_code}" -ne 0 ]] \
    || fail_test 'durable no-receipt PROCESSING unexpectedly completed'
[[ ! -s "${invocation_log_path}" ]] \
    || fail_test 'durable no-receipt PROCESSING reran gate, build, or upload'
printf '%s\n' "${release_output}" \
    | grep -F 'Reusing the persistent all-suite release gate' >/dev/null \
    || fail_test 'durable no-receipt PROCESSING did not reuse the gate'
if printf '%s\n' "${release_output}" \
    | grep -F 'without a matching local receipt or durable' >/dev/null; then
    fail_test 'full remote provenance was not accepted without a local receipt'
fi
printf '%s\n' \
    'product=Muralume' \
    'marketing_version=9.9.9' \
    'build_number=2' \
    "source_commit=${source_commit}" \
    "source_tree=${source_tree}" \
    >"${upload_receipt_path}"
chmod 600 "${upload_receipt_path}"

selected_fake_xcode_build='17B200'
run_release draft exact VALID --title 'Fixture Xcode upgrade'
[[ "${release_exit_code}" -eq 0 ]] \
    || fail_test 'a legitimate Xcode upgrade could not create a new gate state'
[[ "$(<"${invocation_log_path}")" == 'verify all' ]] \
    || fail_test 'an Xcode identity change did not run exactly one new all-suite gate'
printf '%s\n' "${release_output}" \
    | grep -F 'Running the shared all-suite release gate' >/dev/null \
    || fail_test 'the Xcode upgrade incorrectly reused the old gate receipt'

git -C "${fixture_repository}" tag -d "${release_tag}" >/dev/null
git -C "${fixture_repository}" tag -a "${release_tag}" \
    -m 'Muralume 9.9.9 legacy annotated tag'
git -C "${fixture_repository}" push -q --force origin \
    "refs/tags/${release_tag}"
rm -f "${remote_assets}/Muralume.release-provenance"

run_release final legacy VALID --title 'Fixture legacy migration'
[[ "${release_exit_code}" -eq 0 ]] \
    || fail_test 'a legacy two-asset Release could not migrate to durable provenance'
[[ "$(cat "${github_assets_state_path}")" == 'exact' ]] \
    || fail_test 'legacy migration did not produce the exact three-asset set'
[[ "$(cat "${github_state_path}")" == 'final' ]] \
    || fail_test 'legacy migration did not retain a final GitHub Release'
[[ "$(wc -l <"${invocation_log_path}" | tr -d '[:space:]')" == '1' ]] \
    || fail_test 'legacy migration invoked more than the provenance upload'
grep -Fx 'gh_release_upload Muralume.release-provenance' \
    "${invocation_log_path}" >/dev/null \
    || fail_test 'legacy migration did not upload only the provenance asset'
if grep -E '(release_macos|release_app_store|prepare_distribution_requirements|Muralume\.dmg($|\.sha256))' \
    "${invocation_log_path}" >/dev/null; then
    fail_test 'legacy migration rebuilt or re-uploaded the existing DMG pair'
fi
printf '%s\n' "${release_output}" \
    | grep -F 'Developer ID build will not be repeated.' >/dev/null \
    || fail_test 'legacy migration did not use the verified existing DMG pair'
printf '%s\n' "${release_output}" \
    | grep -F 'is fully published from' >/dev/null \
    || fail_test 'legacy migration did not finish with remote verification'

run_release final exact VALID --status
[[ "${release_exit_code}" -eq 0 ]] \
    || fail_test 'the migrated three-asset Release failed final status verification'

printf '%s\n' \
    'PASS: dual-release status, exact-draft, and legacy-provenance migration tests'
