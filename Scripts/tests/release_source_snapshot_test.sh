#!/usr/bin/env bash

set -euo pipefail

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly scripts_directory="$(cd "${script_directory}/.." && pwd)"
readonly test_python_path="$(xcrun --find python3)"

# shellcheck source=../lib/release_source_snapshot.sh
source "${scripts_directory}/lib/release_source_snapshot.sh"

test_root="$(
    mktemp -d "${TMPDIR:-/tmp}/MuralumeReleaseSourceTests.XXXXXX"
)"
readonly fixture_repository_path="${test_root}/repository"
readonly fixture_snapshot_path="${test_root}/snapshot"
cleanup() {
    git -C "${fixture_repository_path}" worktree remove --force \
        "${fixture_snapshot_path}" >/dev/null 2>&1 || true
    rm -rf "${test_root}"
}
trap cleanup EXIT

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

write_base_config() {
    local version="$1"
    local build="$2"

    printf 'MARKETING_VERSION = %s\nCURRENT_PROJECT_VERSION = %s\n' \
        "${version}" \
        "${build}" \
        >"${fixture_repository_path}/Config/Base.xcconfig"
}

mkdir -p "${fixture_repository_path}/Config"
git -C "${fixture_repository_path}" init -q
git -C "${fixture_repository_path}" config user.name 'Release Test'
git -C "${fixture_repository_path}" config user.email 'release-test@example.invalid'

write_base_config 1.0.3 5
git -C "${fixture_repository_path}" add Config/Base.xcconfig
git -C "${fixture_repository_path}" commit -qm 'release 1.0.3'
git -C "${fixture_repository_path}" tag v1.0.3

write_base_config 1.0.4 5
git -C "${fixture_repository_path}" add Config/Base.xcconfig
git -C "${fixture_repository_path}" commit -qm 'invalid reused build'
invalid_build_commit="$(git -C "${fixture_repository_path}" rev-parse HEAD)"
if validate_formal_release_version \
    "${fixture_repository_path}" \
    "${invalid_build_commit}" \
    1.0.4 \
    5 \
    "${test_python_path}" >/dev/null 2>&1; then
    fail_test 'a new release must increase the previous build number'
fi

write_base_config 1.0.4 6
git -C "${fixture_repository_path}" add Config/Base.xcconfig
git -C "${fixture_repository_path}" commit -qm 'release 1.0.4 candidate'
source_commit="$(git -C "${fixture_repository_path}" rev-parse HEAD)"
source_tree="$(git -C "${fixture_repository_path}" rev-parse 'HEAD^{tree}')"

verify_clean_release_repository "${fixture_repository_path}" \
    || fail_test 'the committed fixture should be clean'
validate_formal_release_version \
    "${fixture_repository_path}" \
    "${source_commit}" \
    1.0.4 \
    6 \
    "${test_python_path}" \
    || fail_test 'a strictly newer untagged release should pass'

git -C "${fixture_repository_path}" tag v1.0.4 v1.0.3
if validate_formal_release_version \
    "${fixture_repository_path}" \
    "${source_commit}" \
    1.0.4 \
    6 \
    "${test_python_path}" >/dev/null 2>&1; then
    fail_test 'an existing release tag on another commit should fail'
fi
git -C "${fixture_repository_path}" tag -f v1.0.4 \
    "${source_commit}" >/dev/null
validate_formal_release_version \
    "${fixture_repository_path}" \
    "${source_commit}" \
    1.0.4 \
    6 \
    "${test_python_path}" \
    || fail_test 'an existing release tag on the captured commit should pass'

candidate_branch="$(
    git -C "${fixture_repository_path}" symbolic-ref --short HEAD
)"
git -C "${fixture_repository_path}" checkout -qb higher-version-fixture
write_base_config 1.1.0 7
git -C "${fixture_repository_path}" add Config/Base.xcconfig
git -C "${fixture_repository_path}" commit -qm 'higher release fixture'
git -C "${fixture_repository_path}" tag v1.1.0
git -C "${fixture_repository_path}" checkout -q "${candidate_branch}"
if validate_formal_release_version \
    "${fixture_repository_path}" \
    "${source_commit}" \
    1.0.4 \
    6 \
    "${test_python_path}" >/dev/null 2>&1; then
    fail_test 'an existing candidate tag must not hide a higher release version'
fi
git -C "${fixture_repository_path}" tag -d v1.1.0 >/dev/null
git -C "${fixture_repository_path}" branch -D higher-version-fixture \
    >/dev/null

git -C "${fixture_repository_path}" checkout -qb higher-build-fixture
write_base_config 1.0.2 99
git -C "${fixture_repository_path}" add Config/Base.xcconfig
git -C "${fixture_repository_path}" commit -qm 'higher historical build fixture'
git -C "${fixture_repository_path}" tag v1.0.2
git -C "${fixture_repository_path}" checkout -q "${candidate_branch}"
if validate_formal_release_version \
    "${fixture_repository_path}" \
    "${source_commit}" \
    1.0.4 \
    6 \
    "${test_python_path}" >/dev/null 2>&1; then
    fail_test 'an existing candidate tag must not hide a higher historical build'
fi
git -C "${fixture_repository_path}" tag -d v1.0.2 >/dev/null
git -C "${fixture_repository_path}" branch -D higher-build-fixture \
    >/dev/null

v1_0_3_commit="$(
    git -C "${fixture_repository_path}" rev-parse 'v1.0.3^{commit}'
)"
git -C "${fixture_repository_path}" replace \
    "${source_commit}" \
    "${v1_0_3_commit}"
if reject_release_git_object_overrides \
    "${fixture_repository_path}" >/dev/null 2>&1; then
    fail_test 'a Git replace ref should block a formal release'
fi
[[ "$(release_git -C "${fixture_repository_path}" \
    rev-parse "${source_commit}^{tree}")" == "${source_tree}" ]] \
    || fail_test 'release_git did not disable Git object replacement'
git -C "${fixture_repository_path}" replace -d "${source_commit}" \
    >/dev/null

git_common_directory="$(
    git -C "${fixture_repository_path}" rev-parse --git-common-dir
)"
mkdir -p "${fixture_repository_path}/${git_common_directory}/info"
: >"${fixture_repository_path}/${git_common_directory}/info/grafts"
if reject_release_git_object_overrides \
    "${fixture_repository_path}" >/dev/null 2>&1; then
    fail_test 'legacy Git grafts should block a formal release'
fi
rm "${fixture_repository_path}/${git_common_directory}/info/grafts"
reject_release_git_object_overrides "${fixture_repository_path}" \
    || fail_test 'a repository without replace refs or grafts should pass'

override_repository_path="${test_root}/override-repository"
git -C "${test_root}" init -q "${override_repository_path}"
if [[ "$(GIT_DIR="${override_repository_path}/.git" \
    GIT_WORK_TREE="${override_repository_path}" \
    release_git -C "${fixture_repository_path}" rev-parse 'HEAD^{commit}')" \
    != "${source_commit}" ]]; then
    fail_test 'release_git accepted repository environment overrides'
fi

stale_checkout_parent="${fixture_repository_path}/.build/muralume/checkouts/test"
stale_checkout_path="${stale_checkout_parent}/Source"
mkdir -p "${stale_checkout_parent}"
git -C "${fixture_repository_path}" worktree add --detach \
    "${stale_checkout_path}" "${source_commit}" >/dev/null
release_reclaim_managed_worktree \
    "${fixture_repository_path}" "${stale_checkout_path}" \
    || fail_test 'a stale managed worktree could not be reclaimed'
[[ ! -e "${stale_checkout_path}" ]] \
    || fail_test 'stale managed worktree files remained after reclaim'
if git -C "${fixture_repository_path}" worktree list --porcelain \
    | /usr/bin/grep -F "worktree ${stale_checkout_path}" >/dev/null; then
    fail_test 'stale managed worktree registration remained after reclaim'
fi

git -C "${fixture_repository_path}" worktree add --detach \
    "${fixture_snapshot_path}" \
    "${source_commit}" >/dev/null
verify_release_source_snapshot \
    "${fixture_snapshot_path}" \
    "${source_commit}" \
    "${source_tree}" \
    || fail_test 'the detached snapshot should match the captured identity'

printf '%s\n' 'untracked' >"${fixture_repository_path}/untracked.txt"
if verify_clean_release_repository \
    "${fixture_repository_path}" >/dev/null 2>&1; then
    fail_test 'untracked source should block a formal release'
fi
rm "${fixture_repository_path}/untracked.txt"

printf '%s\n' '# changed' \
    >>"${fixture_snapshot_path}/Config/Base.xcconfig"
if verify_release_source_snapshot \
    "${fixture_snapshot_path}" \
    "${source_commit}" \
    "${source_tree}" >/dev/null 2>&1; then
    fail_test 'a changed detached snapshot should fail validation'
fi

printf '%s\n' 'PASS: release source snapshot and version fault-injection tests'
