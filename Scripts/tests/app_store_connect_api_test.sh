#!/usr/bin/env bash

set -euo pipefail

readonly asc_test_script_directory="$(
    cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
)"

# shellcheck source=../lib/app_store_connect_api.sh
source "${asc_test_script_directory}/../lib/app_store_connect_api.sh"

asc_test_root="$(
    mktemp -d "${TMPDIR:-/tmp}/MuralumeASCAPITests.XXXXXX"
)"
asc_test_cleanup() {
    rm -rf "${asc_test_root}"
}
trap asc_test_cleanup EXIT

asc_test_fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

asc_test_fixture_repository="${asc_test_root}/fixture-repository"
asc_test_credentials_directory="${asc_test_root}/credentials"
asc_test_work_directory="${asc_test_root}/work"
asc_test_fake_bin="${asc_test_root}/bin"
mkdir -p \
    "${asc_test_fixture_repository}" \
    "${asc_test_credentials_directory}" \
    "${asc_test_work_directory}" \
    "${asc_test_fake_bin}"

asc_test_private_key_path="${asc_test_credentials_directory}/AuthKey_TESTKEY001.p8"
openssl genpkey \
    -algorithm EC \
    -pkeyopt ec_paramgen_curve:P-256 \
    -out "${asc_test_private_key_path}" \
    >/dev/null 2>&1 \
    || asc_test_fail 'could not generate an isolated P-256 private key'
chmod 600 "${asc_test_private_key_path}"

export MURALUME_ASC_KEY_ID='TESTKEY001'
export MURALUME_ASC_ISSUER_ID='01234567-89ab-cdef-0123-456789abcdef'
export MURALUME_ASC_PRIVATE_KEY_PATH="${asc_test_private_key_path}"
export MURALUME_ASC_FORBIDDEN_ROOT="${asc_test_fixture_repository}"

[[ "$(stat -f '%Lp' "${asc_test_private_key_path}")" == '600' ]] \
    || asc_test_fail 'private-key fixture did not use mode 0600'
case "${asc_test_private_key_path}" in
    "${asc_test_fixture_repository}"|"${asc_test_fixture_repository}/"*)
        asc_test_fail 'private-key fixture was created inside the fixture repository'
        ;;
esac
validate_app_store_connect_credentials \
    || asc_test_fail 'valid isolated credentials were rejected'

asc_test_malformed_key_path="${asc_test_credentials_directory}/AuthKey_MALFORMED.p8"
asc_test_rsa_key_path="${asc_test_credentials_directory}/AuthKey_RSA.p8"
asc_test_key_error_path="${asc_test_root}/key-validation-error"
printf '%s\n' 'not a private key' >"${asc_test_malformed_key_path}"
chmod 600 "${asc_test_malformed_key_path}"
if MURALUME_ASC_PRIVATE_KEY_PATH="${asc_test_malformed_key_path}" \
    validate_app_store_connect_credentials \
    >/dev/null 2>"${asc_test_key_error_path}"; then
    asc_test_fail 'malformed mode-0600 private key was accepted'
fi
grep -F 'must be a valid P-256 EC Team API key' \
    "${asc_test_key_error_path}" >/dev/null \
    || asc_test_fail 'malformed private key failure was not explained safely'

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
    -out "${asc_test_rsa_key_path}" >/dev/null 2>&1 \
    || asc_test_fail 'could not generate an isolated non-EC private key'
chmod 600 "${asc_test_rsa_key_path}"
if MURALUME_ASC_PRIVATE_KEY_PATH="${asc_test_rsa_key_path}" \
    validate_app_store_connect_credentials >/dev/null 2>&1; then
    asc_test_fail 'non-P-256 private key was accepted'
fi

asc_test_jwt="$(app_store_connect_jwt)" \
    || asc_test_fail 'could not generate an App Store Connect JWT'
asc_test_jwt_segment_count="$(
    printf '%s' "${asc_test_jwt}" \
        | awk -F. '{ print NF }'
)"
[[ "${asc_test_jwt_segment_count}" == '3' ]] \
    || asc_test_fail 'JWT did not contain exactly three segments'
[[ "${asc_test_jwt}" \
    =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]] \
    || asc_test_fail 'JWT was not base64url encoded'
ruby -rbase64 -rjson -ropenssl -e '
def decode_segment(value)
  padding = "=" * ((4 - value.length % 4) % 4)
  JSON.parse(Base64.urlsafe_decode64(value + padding))
end

def decode_bytes(value)
  padding = "=" * ((4 - value.length % 4) % 4)
  Base64.urlsafe_decode64(value + padding)
end

segments = ARGV.fetch(0).split(".")
abort "unexpected JWT segment count" unless segments.length == 3
header = decode_segment(segments.fetch(0))
payload = decode_segment(segments.fetch(1))
abort "unexpected JWT algorithm" unless header["alg"] == "ES256"
abort "unexpected JWT key ID" unless header["kid"] == ENV.fetch("MURALUME_ASC_KEY_ID")
abort "unexpected JWT issuer" unless payload["iss"] == ENV.fetch("MURALUME_ASC_ISSUER_ID")
abort "unexpected JWT audience" unless payload["aud"] == "appstoreconnect-v1"
abort "unexpected JWT lifetime" unless payload["exp"] - payload["iat"] == 600
signature = decode_bytes(segments.fetch(2))
abort "unexpected ES256 signature length" unless signature.bytesize == 64
r = OpenSSL::BN.new(signature.byteslice(0, 32), 2)
s = OpenSSL::BN.new(signature.byteslice(32, 32), 2)
der_signature = OpenSSL::ASN1::Sequence.new([
  OpenSSL::ASN1::Integer.new(r),
  OpenSSL::ASN1::Integer.new(s),
]).to_der
unsigned = segments.first(2).join(".")
digest = OpenSSL::Digest::SHA256.digest(unsigned)
key = OpenSSL::PKey::EC.new(File.binread(ENV.fetch("MURALUME_ASC_PRIVATE_KEY_PATH")))
abort "invalid ES256 signature" unless key.dsa_verify_asn1(digest, der_signature)
' "${asc_test_jwt}" \
    || asc_test_fail 'JWT claims did not match App Store Connect requirements'

export FAKE_ASC_CURL_ARGUMENTS_PATH="${asc_test_root}/curl-arguments"
export FAKE_ASC_CURL_CONFIG_PATH="${asc_test_root}/curl-config"
export FAKE_ASC_CURL_HTTP_STATUS='200'
export FAKE_ASC_CURL_DEFAULT_RESPONSE_PATH="${asc_test_root}/default-response.json"
export FAKE_ASC_CURL_APPS_RESPONSE_PATH="${asc_test_root}/apps-response.json"
export FAKE_ASC_CURL_PRERELEASE_RESPONSE_PATH="${asc_test_root}/prerelease-response.json"
printf '%s\n' '{"data":[]}' >"${FAKE_ASC_CURL_DEFAULT_RESPONSE_PATH}"
printf '%s\n' '{"data":[{"type":"apps","id":"app-123"}]}' \
    >"${FAKE_ASC_CURL_APPS_RESPONSE_PATH}"
printf '%s\n' '{"data":[],"included":[]}' \
    >"${FAKE_ASC_CURL_PRERELEASE_RESPONSE_PATH}"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    ': >"${FAKE_ASC_CURL_ARGUMENTS_PATH}"' \
    'for fake_curl_argument in "$@"; do' \
    '    printf "%s\n" "${fake_curl_argument}" >>"${FAKE_ASC_CURL_ARGUMENTS_PATH}"' \
    'done' \
    'cat >"${FAKE_ASC_CURL_CONFIG_PATH}"' \
    'fake_curl_output_path=""' \
    'fake_curl_response_path="${FAKE_ASC_CURL_DEFAULT_RESPONSE_PATH}"' \
    'fake_curl_previous_argument=""' \
    'for fake_curl_argument in "$@"; do' \
    '    if [[ "${fake_curl_previous_argument}" == "--output" ]]; then' \
    '        fake_curl_output_path="${fake_curl_argument}"' \
    '    fi' \
    '    case "${fake_curl_argument}" in' \
    '        */v1/apps)' \
    '            fake_curl_response_path="${FAKE_ASC_CURL_APPS_RESPONSE_PATH}"' \
    '            ;;' \
    '        */v1/preReleaseVersions)' \
    '            fake_curl_response_path="${FAKE_ASC_CURL_PRERELEASE_RESPONSE_PATH}"' \
    '            ;;' \
    '    esac' \
    '    fake_curl_previous_argument="${fake_curl_argument}"' \
    'done' \
    '[[ -n "${fake_curl_output_path}" ]] || exit 64' \
    'cp "${fake_curl_response_path}" "${fake_curl_output_path}"' \
    'printf "%s" "${FAKE_ASC_CURL_HTTP_STATUS}"' \
    >"${asc_test_fake_bin}/curl"
chmod 700 "${asc_test_fake_bin}/curl"
export PATH="${asc_test_fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin"

asc_test_get_output="${asc_test_work_directory}/get.json"
app_store_connect_get \
    "${asc_test_get_output}" '/v1/example' \
    --data-urlencode 'filter[value]=example' \
    || asc_test_fail 'a successful App Store Connect GET failed'
[[ "$(stat -f '%Lp' "${asc_test_get_output}")" == '600' ]] \
    || asc_test_fail 'API response did not use mode 0600'
asc_test_authorization_line="$(
    sed -n 's/^header = "Authorization: Bearer \(.*\)"$/\1/p' \
        "${FAKE_ASC_CURL_CONFIG_PATH}"
)"
[[ "${asc_test_authorization_line}" \
    =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]] \
    || asc_test_fail 'JWT was not supplied through curl standard-input config'
if grep -F -- "${asc_test_authorization_line}" \
    "${FAKE_ASC_CURL_ARGUMENTS_PATH}" >/dev/null; then
    asc_test_fail 'JWT leaked into curl argv'
fi
if grep -F 'Authorization: Bearer' \
    "${FAKE_ASC_CURL_ARGUMENTS_PATH}" >/dev/null; then
    asc_test_fail 'authorization header leaked into curl argv'
fi
grep -F -x -- '--config' "${FAKE_ASC_CURL_ARGUMENTS_PATH}" >/dev/null \
    || asc_test_fail 'curl was not configured through standard input'

export FAKE_ASC_CURL_HTTP_STATUS='401'
if app_store_connect_get \
    "${asc_test_work_directory}/unauthorized.json" '/v1/example' \
    >/dev/null 2>&1; then
    asc_test_fail 'an HTTP 401 response was accepted'
fi
export FAKE_ASC_CURL_HTTP_STATUS='200'

asc_test_app_id="$(
    app_store_connect_app_id \
        'com.example.Muralume' "${asc_test_work_directory}"
)" || asc_test_fail 'unique App Store Connect app lookup failed'
[[ "${asc_test_app_id}" == 'app-123' ]] \
    || asc_test_fail 'unique App Store Connect app lookup returned the wrong ID'
printf '%s\n' \
    '{"data":[{"type":"apps","id":"app-1"},{"type":"apps","id":"app-2"}]}' \
    >"${FAKE_ASC_CURL_APPS_RESPONSE_PATH}"
if app_store_connect_app_id \
    'com.example.Muralume' "${asc_test_work_directory}" \
    >/dev/null 2>&1; then
    asc_test_fail 'duplicate App Store Connect apps were accepted'
fi
printf '%s\n' '{"data":[]}' >"${FAKE_ASC_CURL_APPS_RESPONSE_PATH}"
if app_store_connect_app_id \
    'com.example.Muralume' "${asc_test_work_directory}" \
    >/dev/null 2>&1; then
    asc_test_fail 'a missing App Store Connect app was accepted'
fi
printf '%s\n' '{"data":[{"type":"apps","id":"app-123"}]}' \
    >"${FAKE_ASC_CURL_APPS_RESPONSE_PATH}"

printf '%s\n' '{"data":[],"included":[]}' \
    >"${FAKE_ASC_CURL_PRERELEASE_RESPONSE_PATH}"
asc_test_state="$(
    app_store_connect_testflight_build_state \
        'com.example.Muralume' '1.2.3' '42' "${asc_test_work_directory}"
)" || asc_test_fail 'missing TestFlight state lookup failed'
[[ "${asc_test_state}" == 'MISSING' ]] \
    || asc_test_fail "missing TestFlight build parsed as ${asc_test_state}"

printf '%s\n' \
    '{"data":[],"included":[{"type":"builds","id":"build-42","attributes":{"version":"42","processingState":"PROCESSING"}}]}' \
    >"${FAKE_ASC_CURL_PRERELEASE_RESPONSE_PATH}"
asc_test_state="$(
    app_store_connect_testflight_build_state \
        'com.example.Muralume' '1.2.3' '42' "${asc_test_work_directory}"
)" || asc_test_fail 'processing TestFlight state lookup failed'
[[ "${asc_test_state}" == 'PROCESSING' ]] \
    || asc_test_fail "processing TestFlight build parsed as ${asc_test_state}"

printf '%s\n' \
    '{"data":[],"included":[{"type":"builds","id":"build-42","attributes":{"version":"42","processingState":"VALID"}}]}' \
    >"${FAKE_ASC_CURL_PRERELEASE_RESPONSE_PATH}"
asc_test_state="$(
    app_store_connect_testflight_build_state \
        'com.example.Muralume' '1.2.3' '42' "${asc_test_work_directory}"
)" || asc_test_fail 'valid TestFlight state lookup failed'
[[ "${asc_test_state}" == 'VALID' ]] \
    || asc_test_fail "valid TestFlight build parsed as ${asc_test_state}"

# Sourced helpers must not try to redeclare caller-owned readonly variables.
(
    readonly_collision_suffix='id'
    readonly "key_${readonly_collision_suffix}=caller-key-id"
    readonly "issuer_${readonly_collision_suffix}=caller-issuer-id"
    readonly private_key_path='caller-private-key-path'
    readonly canonical_forbidden_root='caller-forbidden-root'
    readonly canonical_private_key_directory='caller-key-directory'
    validate_app_store_connect_credentials
) || asc_test_fail 'credential validation collided with readonly caller variables'

(
    readonly output_path='caller-output-path'
    readonly endpoint='caller-endpoint'
    readonly jwt='caller-jwt'
    readonly http_status='caller-http-status'
    app_store_connect_get \
        "${asc_test_work_directory}/readonly-get.json" '/v1/example'
) || asc_test_fail 'GET helper collided with readonly caller variables'

(
    readonly bundle_identifier='caller-bundle-identifier'
    readonly work_directory='caller-work-directory'
    readonly response_path='caller-response-path'
    app_store_connect_app_id \
        'com.example.Muralume' "${asc_test_work_directory}" >/dev/null
) || asc_test_fail 'app lookup collided with readonly caller variables'

(
    readonly bundle_identifier='caller-bundle-identifier'
    readonly marketing_version='caller-marketing-version'
    readonly build_number='caller-build-number'
    readonly work_directory='caller-work-directory'
    readonly app_id='caller-app-id'
    readonly response_path='caller-response-path'
    app_store_connect_testflight_build_state \
        'com.example.Muralume' '1.2.3' '42' "${asc_test_work_directory}" \
        >/dev/null
) || asc_test_fail 'TestFlight lookup collided with readonly caller variables'

printf '%s\n' 'PASS: App Store Connect API isolation and parsing tests'
