#!/usr/bin/env bash

set -euo pipefail

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly project_root="$(cd "${script_directory}/../.." && pwd)"
readonly doctor_path="${script_directory}/../release_doctor.sh"

test_root="$(mktemp -d "${TMPDIR:-/tmp}/MuralumeDoctorOrder.XXXXXX")"
cleanup() {
    rm -rf -- "${test_root}"
}
trap cleanup EXIT HUP INT TERM

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

line_of() {
    local literal="$1"
    local line
    line="$(rg -n -F "${literal}" "${doctor_path}" | sed -n '1s/:.*//p')"
    [[ "${line}" =~ ^[0-9]+$ ]] \
        || fail_test "release doctor is missing contract marker: ${literal}"
    printf '%s\n' "${line}"
}

line_of_last() {
    local literal="$1"
    local line
    line="$(rg -n -F "${literal}" "${doctor_path}" | tail -n 1 | sed 's/:.*//')"
    [[ "${line}" =~ ^[0-9]+$ ]] \
        || fail_test "release doctor is missing contract marker: ${literal}"
    printf '%s\n' "${line}"
}

first_remote_line="$(line_of 'release_git -C "${project_root}" ls-remote')"
proxy_line="$(line_of_last 'validate_local_proxy')"
github_token_line="$(line_of 'gh auth token --hostname github.com')"
asc_credentials_line="$(line_of '    validate_app_store_connect_credentials')"
asc_jwt_line="$(line_of '    app_store_connect_jwt >/dev/null')"
signing_identity_line="$(line_of 'resolve_developer_id_identity_hash')"
developer_preflight_line="$(
    line_of '    "${script_directory}/prepare_distribution_requirements.sh"'
)"
app_store_preflight_line="$(
    line_of '    "${script_directory}/release_app_store.sh"'
)"
readonly first_remote_line proxy_line github_token_line asc_credentials_line asc_jwt_line
readonly signing_identity_line developer_preflight_line app_store_preflight_line

for local_check_line in \
    "${proxy_line}" \
    "${github_token_line}" \
    "${asc_credentials_line}" \
    "${asc_jwt_line}" \
    "${signing_identity_line}" \
    "${developer_preflight_line}" \
    "${app_store_preflight_line}"; do
    [[ "${local_check_line}" -lt "${first_remote_line}" ]] \
        || fail_test 'a local proxy, credential, or signing preflight moved after networking'
done

for remote_marker in \
    'xcrun notarytool history' \
    'gh repo view "${github_repository}" --json nameWithOwner,viewerPermission' \
    'release_git -C "${project_root}" push --dry-run origin' \
    '    app_store_connect_app_id'
do
    [[ "$(line_of "${remote_marker}")" -gt "${first_remote_line}" ]] \
        || fail_test "remote check moved before origin verification: ${remote_marker}"
done

# Exercise the fail-fast boundary with real doctor control flow and fake
# network commands. Both an unavailable proxy and missing local ASC credentials
# must fail without attempting origin, notary, GitHub, or ASC connectivity.
readonly fixture_root="${test_root}/repository"
readonly fake_bin="${test_root}/bin"
readonly remote_attempt_path="${test_root}/remote-attempt"
readonly doctor_error_path="${test_root}/doctor-error"
readonly malformed_asc_key_path="${test_root}/AuthKey_MALFORMED.p8"
mkdir -p \
    "${fixture_root}/Config" \
    "${fixture_root}/Scripts/lib" \
    "${fake_bin}"
cp "${doctor_path}" "${fixture_root}/Scripts/release_doctor.sh"
for helper_name in \
    app_store_connect_api.sh \
    distribution_requirements.sh \
    release_invocation.sh \
    release_source_snapshot.sh; do
    cp "${project_root}/Scripts/lib/${helper_name}" \
        "${fixture_root}/Scripts/lib/${helper_name}"
done
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'exit 0' \
    >"${fixture_root}/Scripts/prepare_distribution_requirements.sh"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'exit 0' \
    >"${fixture_root}/Scripts/release_app_store.sh"
chmod 755 "${fixture_root}/Scripts/"*.sh

printf '%s\n' \
    'MARKETING_VERSION = 9.9.9' \
    'CURRENT_PROJECT_VERSION = 98' \
    >"${fixture_root}/Config/Base.xcconfig"
printf '%s\n' \
    'MARKETING_VERSION = 9.9.9' \
    'CURRENT_PROJECT_VERSION = 99' \
    >"${fixture_root}/Config/AppStore.xcconfig"
for private_file in \
    Release.local.mk \
    Distribution.requirements \
    AppStore.local.xcconfig \
    AppStoreConnect.local.mk; do
    printf '%s\n' 'fixture' >"${fixture_root}/Config/${private_file}"
    chmod 600 "${fixture_root}/Config/${private_file}"
done

/usr/bin/git -C "${fixture_root}" init -q
/usr/bin/git -C "${fixture_root}" config user.name 'Release Doctor Test'
/usr/bin/git -C "${fixture_root}" config user.email 'doctor@example.invalid'
/usr/bin/git -C "${fixture_root}" add .
/usr/bin/git -C "${fixture_root}" commit -qm 'doctor fixture'
/usr/bin/git -C "${fixture_root}" branch -M main
/usr/bin/git -C "${fixture_root}" remote add origin \
    https://github.com/MisakiHCL/Muralume.git

cat >"${fake_bin}/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *' ls-remote '*|*' push '*)
        : >"${FAKE_REMOTE_ATTEMPT_PATH}"
        exit 97
        ;;
esac
exec /usr/bin/git "$@"
EOF
cat >"${fake_bin}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *' auth token '* ]]; then
    exit 0
fi
: >"${FAKE_REMOTE_ATTEMPT_PATH}"
exit 97
EOF
cat >"${fake_bin}/curl" <<'EOF'
#!/usr/bin/env bash
: >"${FAKE_REMOTE_ATTEMPT_PATH}"
exit 97
EOF
cat >"${fake_bin}/xcrun" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *' notarytool '* ]]; then
    : >"${FAKE_REMOTE_ATTEMPT_PATH}"
fi
exit 97
EOF
cat >"${fake_bin}/xcodebuild" <<'EOF'
#!/usr/bin/env bash
if [[ "$#" -eq 1 && "$1" == '-version' ]]; then
    printf '%s\n' 'Xcode 99.1' 'Build version 99A1'
fi
exit 0
EOF
cat >"${fake_bin}/security" <<'EOF'
#!/usr/bin/env bash
printf '  1) %s%s "Developer ID%s: Fixture (%s%s)"\n' \
    'AAAAAAAAAAAAAAAAAAAA' 'AAAAAAAAAAAAAAAAAAAA' \
    ' Application' 'ABCDE' 'FGHIJ'
printf '%s\n' '     1 valid identities found'
EOF
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"${fake_bin}/nc"
chmod 755 "${fake_bin}/"*

run_doctor_fixture() {
    env \
        -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
        -u http_proxy -u https_proxy -u all_proxy \
        PATH="${fake_bin}:${PATH}" \
        FAKE_REMOTE_ATTEMPT_PATH="${remote_attempt_path}" \
        MURALUME_RELEASE_MINIMUM_FREE_GIB=0 \
        "$@" \
        "${fixture_root}/Scripts/release_doctor.sh"
}

if run_doctor_fixture \
    HTTP_PROXY=http://127.0.0.1:1 \
    > /dev/null 2>"${doctor_error_path}"; then
    fail_test 'release doctor accepted an unavailable local proxy'
fi
grep -F 'HTTP_PROXY points to an unavailable local proxy.' \
    "${doctor_error_path}" >/dev/null \
    || fail_test 'release doctor did not explain the unavailable proxy'
[[ ! -e "${remote_attempt_path}" ]] \
    || fail_test 'release doctor attempted networking after proxy preflight failed'

fixture_identity="Developer ID Application"
fixture_notary_profile='fixture-notary'
fixture_team_identifier="$(printf '%s%s' 'ABCDE' 'FGHIJ')"
if run_doctor_fixture \
    MURALUME_DEVELOPER_ID_APPLICATION="${fixture_identity}" \
    MURALUME_NOTARY_KEYCHAIN_PROFILE="${fixture_notary_profile}" \
    MURALUME_EXPECTED_TEAM_IDENTIFIER="${fixture_team_identifier}" \
    > /dev/null 2>"${doctor_error_path}"; then
    fail_test 'release doctor accepted missing App Store Connect credentials'
fi
grep -F 'App Store Connect API credentials are not configured.' \
    "${doctor_error_path}" >/dev/null \
    || fail_test 'release doctor did not explain missing ASC credentials'
[[ ! -e "${remote_attempt_path}" ]] \
    || fail_test 'release doctor attempted networking before local ASC credentials passed'

printf '%s\n' 'malformed Team API private key' >"${malformed_asc_key_path}"
chmod 600 "${malformed_asc_key_path}"
fixture_asc_key_identifier="$(printf '%s%s' 'BADKE' 'Y0001')"
fixture_asc_issuer_identifier="$(
    printf '%s%s' '11111111-2222-3333-' '4444-555555555555'
)"
if run_doctor_fixture \
    MURALUME_DEVELOPER_ID_APPLICATION="${fixture_identity}" \
    MURALUME_NOTARY_KEYCHAIN_PROFILE="${fixture_notary_profile}" \
    MURALUME_EXPECTED_TEAM_IDENTIFIER="${fixture_team_identifier}" \
    MURALUME_ASC_KEY_ID="${fixture_asc_key_identifier}" \
    MURALUME_ASC_ISSUER_ID="${fixture_asc_issuer_identifier}" \
    MURALUME_ASC_PRIVATE_KEY_PATH="${malformed_asc_key_path}" \
    > /dev/null 2>"${doctor_error_path}"; then
    fail_test 'release doctor accepted a malformed mode-0600 ASC private key'
fi
grep -F 'must be a valid P-256 EC Team API key.' \
    "${doctor_error_path}" >/dev/null \
    || fail_test 'release doctor did not explain the malformed ASC key safely'
[[ ! -e "${remote_attempt_path}" ]] \
    || fail_test 'release doctor attempted networking before parsing the ASC private key'

printf '%s\n' \
    'PASS: release doctor fails fast on local prerequisites before remote requests'
