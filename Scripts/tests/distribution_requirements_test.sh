#!/usr/bin/env bash

set -euo pipefail

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly project_root="$(cd "${script_directory}/../.." && pwd)"

# shellcheck source=../lib/distribution_requirements.sh
source "${project_root}/Scripts/lib/distribution_requirements.sh"

test_root="$(mktemp -d "${TMPDIR:-/tmp}/MuralumeDistributionRequirements.XXXXXX")"
cleanup() {
    rm -rf "${test_root}"
}
trap cleanup EXIT

readonly fixture_bundle_identifier="com.muralume.RequirementFixture"
readonly fixture_team_identifier="EXAMPLE123"
readonly valid_requirement_path="${test_root}/valid.requirements"
readonly fixture_identity_hash="1111111111111111111111111111111111111111"

fixture_identity_name="Developer ID Application: Example Maintainer ("
fixture_identity_name+="${fixture_team_identifier})"
fixture_identity_listing="$(
    printf '  1) %s "%s"\n' \
        "${fixture_identity_hash}" \
        "${fixture_identity_name}"
)"
resolved_identity_hash="$(
    resolve_developer_id_identity_hash_from_listing \
        "${fixture_identity_name}" \
        "${fixture_team_identifier}" \
        "${fixture_identity_listing}"
)"
if [[ "${resolved_identity_hash}" != "${fixture_identity_hash}" ]]; then
    echo "Expected exact Developer ID identity resolution to return its SHA-1." >&2
    exit 1
fi
if resolve_developer_id_identity_hash_from_listing \
    "Developer ID Application" \
    "REPLACE123" \
    "${fixture_identity_listing}" >/dev/null 2>&1; then
    echo "Expected Developer ID identity resolution to reject another Team." >&2
    exit 1
fi

printf 'designated => anchor apple generic and identifier "%s" and (certificate leaf[field.1.2.840.113635.100.6.1.9] exists or certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "%s")\n' \
    "${fixture_bundle_identifier}" \
    "${fixture_team_identifier}" \
    >"${valid_requirement_path}"

validate_distribution_requirement \
    "${valid_requirement_path}" \
    "${fixture_bundle_identifier}" \
    "${fixture_team_identifier}"

readonly reordered_equivalent_requirement_path="${test_root}/reordered-equivalent.requirements"
printf 'designated => identifier "%s" and anchor apple generic and (certificate leaf[field.1.2.840.113635.100.6.1.9] exists or certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "%s")\n' \
    "${fixture_bundle_identifier}" \
    "${fixture_team_identifier}" \
    >"${reordered_equivalent_requirement_path}"
if validate_distribution_requirement \
    "${reordered_equivalent_requirement_path}" \
    "${fixture_bundle_identifier}" \
    "${fixture_team_identifier}" >/dev/null 2>&1; then
    echo "Expected a non-Xcode clause ordering to fail exact validation." >&2
    exit 1
fi

readonly permissive_requirement_path="${test_root}/permissive.requirements"
printf 'designated => (anchor apple generic and identifier "%s" and (certificate leaf[field.1.2.840.113635.100.6.1.9] exists or certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "%s")) or true\n' \
    "${fixture_bundle_identifier}" \
    "${fixture_team_identifier}" \
    >"${permissive_requirement_path}"
if validate_distribution_requirement \
    "${permissive_requirement_path}" \
    "${fixture_bundle_identifier}" \
    "${fixture_team_identifier}" >/dev/null 2>&1; then
    echo "Expected a compatible branch widened by OR true to fail." >&2
    exit 1
fi

readonly extra_slot_requirement_path="${test_root}/extra-slot.requirements"
{
    cat "${valid_requirement_path}"
    printf 'host => identifier "%s"\n' "${fixture_bundle_identifier}"
} >"${extra_slot_requirement_path}"
if validate_distribution_requirement \
    "${extra_slot_requirement_path}" \
    "${fixture_bundle_identifier}" \
    "${fixture_team_identifier}" >/dev/null 2>&1; then
    echo "Expected an extra requirement slot to fail exact validation." >&2
    exit 1
fi

readonly prepared_requirement_path="${test_root}/prepared.requirements"
readonly fixture_cdhash="CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
readonly provenance_repository="${test_root}/provenance-repository"
mkdir -p "${provenance_repository}"
git -C "${provenance_repository}" init -q
printf '%s\n' 'v1.0.3 source' >"${provenance_repository}/source.txt"
git -C "${provenance_repository}" add source.txt
git -C "${provenance_repository}" \
    -c user.name='Muralume Tests' \
    -c user.email='tests@muralume.invalid' \
    commit -q -m 'fixture v1.0.3 source'
readonly fixture_forbidden_commit="$(
    git -C "${provenance_repository}" rev-parse HEAD
)"
printf '%s\n' 'bridge source' >"${provenance_repository}/source.txt"
git -C "${provenance_repository}" add source.txt
git -C "${provenance_repository}" \
    -c user.name='Muralume Tests' \
    -c user.email='tests@muralume.invalid' \
    commit -q -m 'fixture bridge source'
readonly fixture_source_commit="$(
    git -C "${provenance_repository}" rev-parse HEAD
)"
readonly fixture_source_tree="$(
    git -C "${provenance_repository}" rev-parse 'HEAD^{tree}'
)"
readonly same_tree_different_commit="$(
    printf '%s\n' 'same tree, distinct commit' \
        | git -C "${provenance_repository}" \
            -c user.name='Muralume Tests' \
            -c user.email='tests@muralume.invalid' \
            commit-tree "${fixture_source_tree}" -p "${fixture_source_commit}"
)"
compiled_requirement_sha256="$(
    distribution_requirement_binary_sha256 "${valid_requirement_path}"
)"
{
    printf '# muralume-provenance-schema: 1\n'
    printf '# muralume-source-kind: xcode-developer-id-export\n'
    printf '# muralume-export-method: developer-id\n'
    printf '# muralume-bundle-identifier: %s\n' \
        "${fixture_bundle_identifier}"
    printf '# muralume-team-identifier: %s\n' \
        "${fixture_team_identifier}"
    printf '# muralume-source-app-version: 0.0.0\n'
    printf '# muralume-source-app-build: 1\n'
    printf '# muralume-source-git-commit: %s\n' "${fixture_source_commit}"
    printf '# muralume-source-git-tree: %s\n' "${fixture_source_tree}"
    printf '# muralume-xcode-version: 26.1.1\n'
    printf '# muralume-xcode-build: 17B100\n'
    printf '# muralume-exported-app-cdhash: %s\n' "${fixture_cdhash}"
    printf '# muralume-compiled-requirement-sha256: %s\n' \
        "${compiled_requirement_sha256}"
    cat "${valid_requirement_path}"
} >"${prepared_requirement_path}"
validate_distribution_requirement_provenance \
    "${prepared_requirement_path}" \
    "${fixture_bundle_identifier}" \
    "${fixture_team_identifier}" \
    "${provenance_repository}" \
    "${fixture_forbidden_commit}"
if validate_distribution_requirement_provenance \
    "${prepared_requirement_path}" \
    "${fixture_bundle_identifier}" \
    "${fixture_team_identifier}" \
    "${provenance_repository}" \
    "${fixture_source_commit}" >/dev/null 2>&1; then
    echo "Expected provenance from the forbidden release source to fail." >&2
    exit 1
fi
if validate_distribution_requirement_provenance \
    "${prepared_requirement_path}" \
    "${fixture_bundle_identifier}" \
    "${fixture_team_identifier}" \
    "${provenance_repository}" \
    "${same_tree_different_commit}" >/dev/null 2>&1; then
    echo "Expected provenance from a forbidden source tree to fail." >&2
    exit 1
fi

readonly wrong_tree_requirement_path="${test_root}/wrong-tree.requirements"
forbidden_tree="$(
    git -C "${provenance_repository}" rev-parse \
        "${fixture_forbidden_commit}^{tree}"
)"
sed "s/^# muralume-source-git-tree: .*/# muralume-source-git-tree: ${forbidden_tree}/" \
    "${prepared_requirement_path}" >"${wrong_tree_requirement_path}"
if validate_distribution_requirement_provenance \
    "${wrong_tree_requirement_path}" \
    "${fixture_bundle_identifier}" \
    "${fixture_team_identifier}" \
    "${provenance_repository}" >/dev/null 2>&1; then
    echo "Expected a source tree unrelated to its source commit to fail." >&2
    exit 1
fi

readonly missing_commit_requirement_path="${test_root}/missing-commit.requirements"
sed 's/^# muralume-source-git-commit: .*/# muralume-source-git-commit: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' \
    "${prepared_requirement_path}" >"${missing_commit_requirement_path}"
if validate_distribution_requirement_provenance \
    "${missing_commit_requirement_path}" \
    "${fixture_bundle_identifier}" \
    "${fixture_team_identifier}" \
    "${provenance_repository}" >/dev/null 2>&1; then
    echo "Expected an unknown source commit to fail." >&2
    exit 1
fi

readonly wrong_digest_requirement_path="${test_root}/wrong-digest.requirements"
sed 's/^# muralume-compiled-requirement-sha256: .*/# muralume-compiled-requirement-sha256: 0000000000000000000000000000000000000000000000000000000000000000/' \
    "${prepared_requirement_path}" >"${wrong_digest_requirement_path}"
if validate_distribution_requirement_provenance \
    "${wrong_digest_requirement_path}" \
    "${fixture_bundle_identifier}" \
    "${fixture_team_identifier}" \
    "${provenance_repository}" >/dev/null 2>&1; then
    echo "Expected a mismatched provenance digest to fail." >&2
    exit 1
fi

if validate_distribution_requirement \
    "${test_root}/missing.requirements" \
    "${fixture_bundle_identifier}" \
    "${fixture_team_identifier}" >/dev/null 2>&1; then
    echo "Expected a missing distribution requirement to fail." >&2
    exit 1
fi

readonly malformed_requirement_path="${test_root}/malformed.requirements"
printf '%s\n' 'this is not a code requirement' \
    >"${malformed_requirement_path}"
if validate_distribution_requirement \
    "${malformed_requirement_path}" \
    "${fixture_bundle_identifier}" \
    "${fixture_team_identifier}" >/dev/null 2>&1; then
    echo "Expected malformed requirement source to fail." >&2
    exit 1
fi

if validate_distribution_requirement \
    "${valid_requirement_path}" \
    "com.muralume.WrongFixture" \
    "${fixture_team_identifier}" >/dev/null 2>&1; then
    echo "Expected a mismatched bundle ID to fail." >&2
    exit 1
fi

readonly developer_id_only_requirement_path="${test_root}/developer-id-only.requirements"
printf 'designated => anchor apple generic and identifier "%s" and certificate leaf[subject.OU] = "%s" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists\n' \
    "${fixture_bundle_identifier}" \
    "${fixture_team_identifier}" \
    >"${developer_id_only_requirement_path}"
if validate_distribution_requirement \
    "${developer_id_only_requirement_path}" \
    "${fixture_bundle_identifier}" \
    "${fixture_team_identifier}" >/dev/null 2>&1; then
    echo "Expected a requirement without the Mac App Store branch to fail." >&2
    exit 1
fi

readonly mas_absent_requirement_path="${test_root}/mas-absent.requirements"
printf 'designated => anchor apple generic and identifier "%s" and (certificate leaf[field.1.2.840.113635.100.6.1.9] absent or certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "%s")\n' \
    "${fixture_bundle_identifier}" \
    "${fixture_team_identifier}" \
    >"${mas_absent_requirement_path}"
if validate_distribution_requirement \
    "${mas_absent_requirement_path}" \
    "${fixture_bundle_identifier}" \
    "${fixture_team_identifier}" >/dev/null 2>&1; then
    echo "Expected a requirement with a Mac App Store absent test to fail." >&2
    exit 1
fi

readonly wrong_and_requirement_path="${test_root}/wrong-and.requirements"
printf 'designated => anchor apple generic and identifier "%s" and certificate leaf[field.1.2.840.113635.100.6.1.9] exists and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "%s"\n' \
    "${fixture_bundle_identifier}" \
    "${fixture_team_identifier}" \
    >"${wrong_and_requirement_path}"
if validate_distribution_requirement \
    "${wrong_and_requirement_path}" \
    "${fixture_bundle_identifier}" \
    "${fixture_team_identifier}" >/dev/null 2>&1; then
    echo "Expected a requirement that ANDs the distribution branches to fail." >&2
    exit 1
fi

readonly wrong_slot_requirement_path="${test_root}/wrong-slot.requirements"
printf 'designated => anchor apple generic and identifier "%s" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "%s"\nhost => anchor apple generic and identifier "%s" and (certificate leaf[field.1.2.840.113635.100.6.1.9] exists or certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "%s")\n' \
    "${fixture_bundle_identifier}" \
    "${fixture_team_identifier}" \
    "${fixture_bundle_identifier}" \
    "${fixture_team_identifier}" \
    >"${wrong_slot_requirement_path}"
if validate_distribution_requirement \
    "${wrong_slot_requirement_path}" \
    "${fixture_bundle_identifier}" \
    "${fixture_team_identifier}" >/dev/null 2>&1; then
    echo "Expected a Mac App Store OID outside the designated slot to fail." >&2
    exit 1
fi

if validate_distribution_requirement \
    "${valid_requirement_path}" \
    "${fixture_bundle_identifier}" \
    "REPLACE123" >/dev/null 2>&1; then
    echo "Expected a mismatched Team ID to fail." >&2
    exit 1
fi

readonly executable_path="${test_root}/requirement-fixture"
readonly embedded_requirement_path="${test_root}/embedded-source.requirements"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"${executable_path}"
chmod 700 "${executable_path}"
printf 'designated => identifier "%s"\n' "${fixture_bundle_identifier}" \
    >"${embedded_requirement_path}"
codesign \
    --force \
    --identifier "${fixture_bundle_identifier}" \
    --requirements "${embedded_requirement_path}" \
    --sign - \
    "${executable_path}" >/dev/null 2>&1
verify_embedded_distribution_requirement \
    "${executable_path}" \
    "${embedded_requirement_path}" \
    "${test_root}"

printf '%s\n' 'designated => identifier "com.muralume.OtherFixture"' \
    >"${embedded_requirement_path}"
if verify_embedded_distribution_requirement \
    "${executable_path}" \
    "${embedded_requirement_path}" \
    "${test_root}" >/dev/null 2>&1; then
    echo "Expected an embedded requirement mismatch to fail." >&2
    exit 1
fi

echo "Distribution requirement fault-injection checks passed."
