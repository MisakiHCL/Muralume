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

staged_index_repository="${test_root}/staged-index"
new_fixture_repository "${staged_index_repository}"
staged_index_relative_path=$'Config/已暂存\nindex.xcconfig'
printf '%s\n' \
    'MURALUME_DEBUG_DEVELOPMENT_TEAM = STAGE12345' \
    > "${staged_index_repository}/${staged_index_relative_path}"
git -C "${staged_index_repository}" add "${staged_index_relative_path}"
printf '%s\n' \
    'MURALUME_DEBUG_DEVELOPMENT_TEAM = $(MURALUME_LOCAL_TEAM)' \
    > "${staged_index_repository}/${staged_index_relative_path}"
if check_tracked_signing_privacy \
    "${staged_index_repository}" >/dev/null 2>&1; then
    echo "Expected a staged synthetic secret hidden by a safe worktree to fail." >&2
    exit 1
fi

literal_path_repository="${test_root}/literal-path"
new_fixture_repository "${literal_path_repository}"
literal_secret_relative_path=':(literal)secret.xcconfig'
printf '%s\n' \
    'MURALUME_DEBUG_DEVELOPMENT_TEAM = LITER12345' \
    > "${literal_path_repository}/${literal_secret_relative_path}"
git -C "${literal_path_repository}" --literal-pathspecs add -- \
    "${literal_secret_relative_path}"
printf '%s\n' \
    'MURALUME_DEBUG_DEVELOPMENT_TEAM = $(MURALUME_LOCAL_TEAM)' \
    > "${literal_path_repository}/${literal_secret_relative_path}"
if check_tracked_signing_privacy \
    "${literal_path_repository}" >/dev/null 2>&1; then
    echo "Expected a literal-path staged secret hidden by a safe worktree to fail." >&2
    exit 1
fi

worktree_repository="${test_root}/worktree"
new_fixture_repository "${worktree_repository}"
worktree_relative_path=$'Config/工作区\nworktree.xcconfig'
printf '%s\n' \
    'MURALUME_DEBUG_DEVELOPMENT_TEAM = $(MURALUME_LOCAL_TEAM)' \
    > "${worktree_repository}/${worktree_relative_path}"
git -C "${worktree_repository}" add "${worktree_relative_path}"
printf '%s\n' \
    'MURALUME_DEBUG_DEVELOPMENT_TEAM = WORKT12345' \
    > "${worktree_repository}/${worktree_relative_path}"
if check_tracked_signing_privacy \
    "${worktree_repository}" >/dev/null 2>&1; then
    echo "Expected an unstaged synthetic secret over a safe index to fail." >&2
    exit 1
fi

untracked_repository="${test_root}/untracked"
new_fixture_repository "${untracked_repository}"
printf '%s\n' \
    'MURALUME_DEBUG_DEVELOPMENT_TEAM = UNTRK12345' \
    > "${untracked_repository}/Config/untracked.xcconfig"
if check_tracked_signing_privacy \
    "${untracked_repository}" >/dev/null 2>&1; then
    echo "Expected an untracked synthetic secret to fail." >&2
    exit 1
fi

ignored_repository="${test_root}/ignored"
new_fixture_repository "${ignored_repository}"
printf '%s\n' 'Config/Release.local.mk' > "${ignored_repository}/.gitignore"
git -C "${ignored_repository}" add .gitignore
printf '%s\n' \
    'MURALUME_DEBUG_DEVELOPMENT_TEAM = LOCAL12345' \
    > "${ignored_repository}/Config/Release.local.mk"
check_tracked_signing_privacy "${ignored_repository}" >/dev/null

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

mixed_case_repository="${test_root}/mixed-case"
new_fixture_repository "${mixed_case_repository}"
printf '%s\n' \
    'mUrAlUmE_dEbUg_DeVeLoPmEnT_tEaM = CASES12345' \
    > "${mixed_case_repository}/Config/mixed.xcconfig"
git -C "${mixed_case_repository}" add Config/mixed.xcconfig
if check_tracked_signing_privacy \
    "${mixed_case_repository}" >/dev/null 2>&1; then
    echo "Expected case-insensitive signing keys to fail." >&2
    exit 1
fi

multiline_json_repository="${test_root}/multiline-json"
new_fixture_repository "${multiline_json_repository}"
printf '%s\n' \
    '{' \
    '  "aSc_KeY_iD":' \
    '  "SYNTHETIC-JSON-KEY"' \
    '}' \
    > "${multiline_json_repository}/Config/signing.json"
git -C "${multiline_json_repository}" add Config/signing.json
if check_tracked_signing_privacy \
    "${multiline_json_repository}" >/dev/null 2>&1; then
    echo "Expected a multiline JSON signing value to fail." >&2
    exit 1
fi

multiline_xml_repository="${test_root}/multiline-xml"
new_fixture_repository "${multiline_xml_repository}"
printf '%s\n' \
    '<?xml version="1.0" encoding="UTF-8"?>' \
    '<plist version="1.0">' \
    '<dict>' \
    '<key>TeAm_Id</key>' \
    '<string>SYNTHETIC-XML-TEAM</string>' \
    '</dict>' \
    '</plist>' \
    > "${multiline_xml_repository}/Config/signing.plist"
git -C "${multiline_xml_repository}" add Config/signing.plist
if check_tracked_signing_privacy \
    "${multiline_xml_repository}" >/dev/null 2>&1; then
    echo "Expected a multiline XML plist signing value to fail." >&2
    exit 1
fi

adjacent_binary_plist_repository="${test_root}/adjacent-binary-plist"
new_fixture_repository "${adjacent_binary_plist_repository}"
binary_plist_source="${test_root}/adjacent-binary-source.plist"
binary_plist_key_prefix='AsC_IsSuEr_'
printf '%s\n' \
    '<?xml version="1.0" encoding="UTF-8"?>' \
    '<plist version="1.0"><dict>' \
    > "${binary_plist_source}"
printf '<key>%s%s</key><string>%s</string>\n' \
    "${binary_plist_key_prefix}" \
    'Id' \
    'SYNTHETIC-BINARY-ISSUER' \
    >> "${binary_plist_source}"
printf '%s\n' \
    '</dict></plist>' \
    >> "${binary_plist_source}"
plutil -convert binary1 \
    -o "${adjacent_binary_plist_repository}/Config/signing.bin" \
    "${binary_plist_source}"
git -C "${adjacent_binary_plist_repository}" add Config/signing.bin
if check_tracked_signing_privacy \
    "${adjacent_binary_plist_repository}" >/dev/null 2>&1; then
    echo "Expected an adjacent key/value in a binary plist to fail." >&2
    exit 1
fi

multiline_yaml_repository="${test_root}/multiline-yaml"
new_fixture_repository "${multiline_yaml_repository}"
multiline_yaml_key_prefix='IsSuEr_'
printf '%s%s: # synthetic multiline value\n' \
    "${multiline_yaml_key_prefix}" \
    'Id' \
    > "${multiline_yaml_repository}/Config/signing.yml"
printf '%s\n' \
    '  SYNTHETIC-YAML-ISSUER' \
    >> "${multiline_yaml_repository}/Config/signing.yml"
git -C "${multiline_yaml_repository}" add Config/signing.yml
if check_tracked_signing_privacy \
    "${multiline_yaml_repository}" >/dev/null 2>&1; then
    echo "Expected a multiline YAML signing value to fail." >&2
    exit 1
fi

binary_material_repository="${test_root}/binary-material"
new_fixture_repository "${binary_material_repository}"
private_key_header='-----BEGIN PRIVATE '
private_key_header+='KEY-----'
certificate_header='-----BEGIN '
certificate_header+='CERTIFICATE-----'
printf '\0%s\0%s\0' "${private_key_header}" "${certificate_header}" \
    > "${binary_material_repository}/Config/material.bin"
git -C "${binary_material_repository}" add Config/material.bin
if check_tracked_signing_privacy \
    "${binary_material_repository}" >/dev/null 2>&1; then
    echo "Expected binary private-key and certificate headers to fail." >&2
    exit 1
fi

binary_certificate_repository="${test_root}/binary-certificate"
new_fixture_repository "${binary_certificate_repository}"
printf '\0%s\0' "${certificate_header}" \
    > "${binary_certificate_repository}/Config/certificate.bin"
git -C "${binary_certificate_repository}" add Config/certificate.bin
if check_tracked_signing_privacy \
    "${binary_certificate_repository}" >/dev/null 2>&1; then
    echo "Expected a binary certificate header to fail." >&2
    exit 1
fi

unmerged_repository="${test_root}/unmerged"
new_fixture_repository "${unmerged_repository}"
unmerged_safe_object="$(
    printf '%s\n' 'DEVELOPMENT_TEAM = $(MURALUME_LOCAL_TEAM)' \
        | git -C "${unmerged_repository}" hash-object -w --stdin
)"
unmerged_secret_object="$(
    printf '%s\n' 'DEVELOPMENT_TEAM = MERGE12345' \
        | git -C "${unmerged_repository}" hash-object -w --stdin
)"
printf '100644 %s 1\tConfig/conflicted.xcconfig\n' \
    "${unmerged_safe_object}" \
    > "${test_root}/unmerged-index-info"
printf '100644 %s 2\tConfig/conflicted.xcconfig\n' \
    "${unmerged_secret_object}" \
    >> "${test_root}/unmerged-index-info"
printf '100644 %s 3\tConfig/conflicted.xcconfig\n' \
    "${unmerged_safe_object}" \
    >> "${test_root}/unmerged-index-info"
git -C "${unmerged_repository}" update-index --index-info \
    < "${test_root}/unmerged-index-info"
if check_tracked_signing_privacy \
    "${unmerged_repository}" >/dev/null 2>&1; then
    echo "Expected a synthetic secret in an unmerged index stage to fail." >&2
    exit 1
fi

real_git_path="$(command -v git)"
failing_git_directory="${test_root}/failing-git-bin"
mkdir -p "${failing_git_directory}"
cat > "${failing_git_directory}/git" <<'EOF'
#!/usr/bin/env bash
set -u

for argument in "$@"; do
    if [[ "${argument}" == "${SIGNING_PRIVACY_FAIL_GIT_SUBCOMMAND}" ]]; then
        exit 97
    fi
done
exec "${SIGNING_PRIVACY_REAL_GIT}" "$@"
EOF
chmod +x "${failing_git_directory}/git"

if (
    export PATH="${failing_git_directory}:${PATH}"
    export SIGNING_PRIVACY_REAL_GIT="${real_git_path}"
    export SIGNING_PRIVACY_FAIL_GIT_SUBCOMMAND="ls-files"
    check_tracked_signing_privacy "${safe_repository}" >/dev/null 2>&1
); then
    echo "Expected a git ls-files failure to fail closed." >&2
    exit 1
fi

if (
    export PATH="${failing_git_directory}:${PATH}"
    export SIGNING_PRIVACY_REAL_GIT="${real_git_path}"
    export SIGNING_PRIVACY_FAIL_GIT_SUBCOMMAND="cat-file"
    check_tracked_signing_privacy "${safe_repository}" >/dev/null 2>&1
); then
    echo "Expected a git cat-file failure to fail closed." >&2
    exit 1
fi

non_git_directory="${test_root}/not-a-repository"
mkdir -p "${non_git_directory}"
if check_tracked_signing_privacy "${non_git_directory}" >/dev/null 2>&1; then
    echo "Expected a non-Git directory to fail closed." >&2
    exit 1
fi

echo "Signing privacy fault-injection checks passed."
