#!/usr/bin/env bash

set -euo pipefail
umask 077

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly project_root="$(cd "${script_directory}/../.." && pwd)"
readonly helper_path="${project_root}/Scripts/lib/app_store_validation.sh"
readonly test_root="$(mktemp -d "${TMPDIR:-/tmp}/MuralumeAppStoreValidation.XXXXXX")"
readonly test_team="TEST12""3456"
readonly test_bundle_identifier="com.example.ValidationFixture"

# shellcheck source=../lib/app_store_validation.sh
source "${helper_path}"

cleanup() {
    rm -rf "${test_root}"
}
trap cleanup EXIT

expect_failure() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf 'Expected failure: %s\n' "${description}" >&2
        exit 1
    fi
}

write_fixture() {
    local fixture_kind="$1"
    local output_path="$2"
    local mutation="${3:-none}"

    /usr/bin/python3 -c '
import datetime
import plistlib
import sys

kind, output_path, mutation, team, bundle_identifier = sys.argv[1:]
if kind == "entitlements":
    value = {
        "com.apple.security.app-sandbox": True,
        "com.apple.security.files.bookmarks.app-scope": True,
        "com.apple.security.files.user-selected.read-write": True,
        "com.apple.application-identifier": f"{team}.{bundle_identifier}",
        "com.apple.developer.team-identifier": team,
    }
    if mutation == "beta":
        value["beta-reports-active"] = True
    elif mutation == "extra":
        value["com.apple.security.network.client"] = True
    elif mutation == "debuggable":
        value["com.apple.security.get-task-allow"] = True
elif kind == "profile":
    value = {
        "ApplicationIdentifierPrefix": [team],
        "Entitlements": {
            "com.apple.application-identifier": f"{team}.{bundle_identifier}",
            "com.apple.developer.team-identifier": team,
            "com.apple.security.get-task-allow": False,
        },
        "ExpirationDate": datetime.datetime(2035, 1, 1),
        "Platform": ["OSX"],
        "TeamIdentifier": [team],
    }
    if mutation == "expired":
        value["ExpirationDate"] = datetime.datetime(2020, 1, 1)
    elif mutation == "devices":
        value["ProvisionedDevices"] = ["fixture-device"]
elif kind == "info":
    value = {
        "CFBundleIdentifier": bundle_identifier,
        "CFBundleShortVersionString": "1.2.3",
        "CFBundleVersion": "9",
        "ITSAppUsesNonExemptEncryption": mutation == "encrypted",
    }
else:
    raise SystemExit(2)

with open(output_path, "wb") as stream:
    plistlib.dump(value, stream)
' \
        "${fixture_kind}" \
        "${output_path}" \
        "${mutation}" \
        "${test_team}" \
        "${test_bundle_identifier}"
}

readonly valid_entitlements="${test_root}/valid-entitlements.plist"
readonly beta_entitlements="${test_root}/beta-entitlements.plist"
readonly extra_entitlements="${test_root}/extra-entitlements.plist"
readonly debug_entitlements="${test_root}/debug-entitlements.plist"
readonly valid_profile="${test_root}/valid-profile.plist"
readonly expired_profile="${test_root}/expired-profile.plist"
readonly device_profile="${test_root}/device-profile.plist"
readonly valid_info="${test_root}/valid-info.plist"
readonly encrypted_info="${test_root}/encrypted-info.plist"
readonly valid_package_signature="${test_root}/valid-package-signature.log"
readonly development_status_package_signature="${test_root}/development-status-package-signature.log"
readonly unsigned_package_signature="${test_root}/unsigned-package-signature.log"
readonly developer_id_package_signature="${test_root}/developer-id-package-signature.log"
readonly readable_package_tree="${test_root}/readable-package"
readonly unreadable_package_tree="${test_root}/unreadable-package"
readonly readable_bom="${test_root}/readable.bom"
readonly unreadable_bom="${test_root}/unreadable.bom"

write_fixture entitlements "${valid_entitlements}"
write_fixture entitlements "${beta_entitlements}" beta
write_fixture entitlements "${extra_entitlements}" extra
write_fixture entitlements "${debug_entitlements}" debuggable
write_fixture profile "${valid_profile}"
write_fixture profile "${expired_profile}" expired
write_fixture profile "${device_profile}" devices
write_fixture info "${valid_info}"
write_fixture info "${encrypted_info}" encrypted
mkdir -p "${readable_package_tree}" "${unreadable_package_tree}"
chmod 755 "${readable_package_tree}" "${unreadable_package_tree}"
touch "${readable_package_tree}/resource" "${unreadable_package_tree}/resource"
chmod 644 "${readable_package_tree}/resource"
chmod 600 "${unreadable_package_tree}/resource"
/usr/bin/mkbom "${readable_package_tree}" "${readable_bom}"
/usr/bin/mkbom "${unreadable_package_tree}" "${unreadable_bom}"
printf '%s\n' \
    'Package "Muralume.pkg":' \
    '   Status: signed by a certificate trusted by macOS' \
    '   Certificate Chain:' \
    "    1. Mac Installer Distribution: Fixture (${test_team})" \
    '    2. Apple Worldwide Developer Relations Certification Authority' \
    '    3. Apple Root CA' \
    >"${valid_package_signature}"
printf '%s\n' \
    'Package "Muralume.pkg":' \
    '   Status: no signature' \
    >"${unsigned_package_signature}"
printf '%s\n' \
    'Package "Muralume.pkg":' \
    '   Status: signed by a developer certificate issued by Apple (Development)' \
    '   Certificate Chain:' \
    "    1. 3rd Party Mac Developer Installer: Fixture (${test_team})" \
    '    2. Apple Worldwide Developer Relations Certification Authority' \
    '    3. Apple Root CA' \
    >"${development_status_package_signature}"
printf '%s\n' \
    'Package "Muralume.pkg":' \
    '   Status: signed by a developer certificate issued by Apple (Development)' \
    '   Certificate Chain:' \
    "    1. Developer ID Installer: Fixture (${test_team})" \
    '    2. Developer ID Certification Authority' \
    '    3. Apple Root CA' \
    >"${developer_id_package_signature}"

validate_app_store_entitlements \
    /usr/bin/python3 \
    "${valid_entitlements}" \
    "${test_team}" \
    "${test_bundle_identifier}"
(
    readonly entitlements_path="${test_root}/not-the-signed-entitlements.plist"
    validate_app_store_entitlements \
        /usr/bin/python3 \
        "${valid_entitlements}" \
        "${test_team}" \
        "${test_bundle_identifier}"
)
validate_app_store_entitlements \
    /usr/bin/python3 \
    "${beta_entitlements}" \
    "${test_team}" \
    "${test_bundle_identifier}"
expect_failure \
    "unexpected App Store entitlement" \
    validate_app_store_entitlements \
    /usr/bin/python3 \
    "${extra_entitlements}" \
    "${test_team}" \
    "${test_bundle_identifier}"
expect_failure \
    "debuggable App Store entitlement" \
    validate_app_store_entitlements \
    /usr/bin/python3 \
    "${debug_entitlements}" \
    "${test_team}" \
    "${test_bundle_identifier}"

validate_app_store_provisioning_profile \
    /usr/bin/python3 \
    "${valid_profile}" \
    "${test_team}" \
    "${test_bundle_identifier}"
expect_failure \
    "expired App Store profile" \
    validate_app_store_provisioning_profile \
    /usr/bin/python3 \
    "${expired_profile}" \
    "${test_team}" \
    "${test_bundle_identifier}"
expect_failure \
    "device-bound App Store profile" \
    validate_app_store_provisioning_profile \
    /usr/bin/python3 \
    "${device_profile}" \
    "${test_team}" \
    "${test_bundle_identifier}"

validate_app_store_info_plist \
    /usr/bin/python3 \
    "${valid_info}" \
    "${test_bundle_identifier}" \
    1.2.3 \
    9
expect_failure \
    "non-exempt encryption declaration" \
    validate_app_store_info_plist \
    /usr/bin/python3 \
    "${encrypted_info}" \
    "${test_bundle_identifier}" \
    1.2.3 \
    9

validate_app_store_bom_permissions /usr/bin/lsbom "${readable_bom}"
expect_failure \
    "root-only App Store package file" \
    validate_app_store_bom_permissions \
    /usr/bin/lsbom \
    "${unreadable_bom}"

validate_app_store_package_signature_log \
    /usr/bin/python3 \
    "${valid_package_signature}" \
    "${test_team}"
validate_app_store_package_signature_log \
    /usr/bin/python3 \
    "${development_status_package_signature}" \
    "${test_team}"
# The release script owns a readonly variable with this name. Exercise the
# helper under the same Bash dynamic-scope conditions so a local-name
# collision cannot silently redirect validation to another log.
(
    readonly signature_log_path="${test_root}/not-the-package-signature.log"
    validate_app_store_package_signature_log \
        /usr/bin/python3 \
        "${development_status_package_signature}" \
        "${test_team}"
)
expect_failure \
    "unsigned App Store package" \
    validate_app_store_package_signature_log \
    /usr/bin/python3 \
    "${unsigned_package_signature}" \
    "${test_team}"
expect_failure \
    "Developer ID installer package" \
    validate_app_store_package_signature_log \
    /usr/bin/python3 \
    "${developer_id_package_signature}" \
    "${test_team}"

printf 'App Store archive validation checks passed.\n'
