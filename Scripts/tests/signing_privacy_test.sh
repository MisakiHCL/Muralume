#!/usr/bin/env bash

set -euo pipefail

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly project_root="$(cd "${script_directory}/../.." && pwd)"

# shellcheck source=../lib/signing_privacy.sh
source "${project_root}/Scripts/lib/signing_privacy.sh"

test_root="$(mktemp -d "${TMPDIR:-/tmp}/MuralumeSigningPrivacy.XXXXXX")"
cleanup() {
    rm -rf "${test_root}"
}
trap cleanup EXIT

new_fixture_repository() {
    local repository_path="$1"

    mkdir -p "${repository_path}/Config"
    git -C "${repository_path}" init -q
}

safe_repository="${test_root}/safe"
new_fixture_repository "${safe_repository}"
printf '%s\n' \
    'DEVELOPMENT_TEAM = $(MURALUME_LOCAL_TEAM)' \
    'CODE_SIGN_IDENTITY = Apple Development' \
    'PROVISIONING_PROFILE_SPECIFIER =' \
    > "${safe_repository}/Config/Debug.xcconfig"
git -C "${safe_repository}" add Config/Debug.xcconfig
check_tracked_signing_privacy "${safe_repository}" >/dev/null

team_repository="${test_root}/team"
new_fixture_repository "${team_repository}"
printf '%s\n' "MURALUME_DEBUG_DEVELOPMENT_"'TEAM = ABCDE12345' \
    > "${team_repository}/Config/Debug.xcconfig"
git -C "${team_repository}" add Config/Debug.xcconfig
if check_tracked_signing_privacy "${team_repository}" >/dev/null 2>&1; then
    echo "Expected a concrete Team ID to fail the privacy gate." >&2
    exit 1
fi

profile_repository="${test_root}/profile"
new_fixture_repository "${profile_repository}"
printf '%s\n' "MURALUME_NOTARY_"'KEYCHAIN_PROFILE := private-profile' \
    > "${profile_repository}/Config/Release.mk"
git -C "${profile_repository}" add Config/Release.mk
if check_tracked_signing_privacy "${profile_repository}" >/dev/null 2>&1; then
    echo "Expected a concrete Keychain profile to fail the privacy gate." >&2
    exit 1
fi

certificate_repository="${test_root}/certificate"
new_fixture_repository "${certificate_repository}"
certificate_extension="p12"
touch "${certificate_repository}/Config/signing.${certificate_extension}"
git -C "${certificate_repository}" add "Config/signing.${certificate_extension}"
if check_tracked_signing_privacy "${certificate_repository}" >/dev/null 2>&1; then
    echo "Expected tracked signing material to fail the privacy gate." >&2
    exit 1
fi

mixed_value_repository="${test_root}/mixed-value"
new_fixture_repository "${mixed_value_repository}"
printf '%s\n' \
    'DEVELOPMENT_TEAM = ABCDE12345 $(inherited)' \
    > "${mixed_value_repository}/Config/Debug.xcconfig"
git -C "${mixed_value_repository}" add Config/Debug.xcconfig
if check_tracked_signing_privacy "${mixed_value_repository}" >/dev/null 2>&1; then
    echo "Expected a concrete Team ID mixed with a variable to fail." >&2
    exit 1
fi

camel_case_repository="${test_root}/camel-case"
new_fixture_repository "${camel_case_repository}"
printf '%s\n' \
    'DevelopmentTeam = ABCDE12345;' \
    > "${camel_case_repository}/Config/project.pbxproj"
git -C "${camel_case_repository}" add Config/project.pbxproj
if check_tracked_signing_privacy "${camel_case_repository}" >/dev/null 2>&1; then
    echo "Expected a concrete pbxproj DevelopmentTeam to fail." >&2
    exit 1
fi

pfx_repository="${test_root}/pfx"
new_fixture_repository "${pfx_repository}"
touch "${pfx_repository}/Config/signing.pfx"
git -C "${pfx_repository}" add Config/signing.pfx
if check_tracked_signing_privacy "${pfx_repository}" >/dev/null 2>&1; then
    echo "Expected a tracked PFX signing archive to fail." >&2
    exit 1
fi

unicode_certificate_repository="${test_root}/unicode-certificate"
new_fixture_repository "${unicode_certificate_repository}"
unicode_certificate_relative_path='Config/开发证书.p12'
touch "${unicode_certificate_repository}/${unicode_certificate_relative_path}"
git -C "${unicode_certificate_repository}" add \
    "${unicode_certificate_relative_path}"
if check_tracked_signing_privacy \
    "${unicode_certificate_repository}" >/dev/null 2>&1; then
    echo "Expected a tracked certificate with a non-ASCII path to fail." >&2
    exit 1
fi

newline_certificate_repository="${test_root}/newline-certificate"
new_fixture_repository "${newline_certificate_repository}"
newline_certificate_relative_path=$'Config/line\nbreak.p12'
touch "${newline_certificate_repository}/${newline_certificate_relative_path}"
git -C "${newline_certificate_repository}" add \
    "${newline_certificate_relative_path}"
if check_tracked_signing_privacy \
    "${newline_certificate_repository}" >/dev/null 2>&1; then
    echo "Expected a tracked certificate with a newline in its path to fail." >&2
    exit 1
fi

json_repository="${test_root}/json"
new_fixture_repository "${json_repository}"
private_team_value="ABCDE12345"
private_key_value="PRIVATEKEY"
printf '{"%s":"%s","%s":"%s"}\n' \
    "team_id" "${private_team_value}" "key_id" "${private_key_value}" \
    > "${json_repository}/Config/signing.json"
git -C "${json_repository}" add Config/signing.json
if check_tracked_signing_privacy "${json_repository}" >/dev/null 2>&1; then
    echo "Expected concrete JSON signing account values to fail." >&2
    exit 1
fi

yaml_repository="${test_root}/yaml"
new_fixture_repository "${yaml_repository}"
private_issuer_value="PRIVATE-ISSUER-ID"
printf '%s: %s\n' \
    "issuer_id" "${private_issuer_value}" \
    > "${yaml_repository}/Config/signing.yml"
git -C "${yaml_repository}" add Config/signing.yml
if check_tracked_signing_privacy "${yaml_repository}" >/dev/null 2>&1; then
    echo "Expected a concrete YAML signing account value to fail." >&2
    exit 1
fi

echo "Signing privacy fault-injection checks passed."
