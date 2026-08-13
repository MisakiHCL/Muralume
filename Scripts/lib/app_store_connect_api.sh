#!/usr/bin/env bash

# Read-only App Store Connect API helpers. Team API credentials stay in a
# Git-ignored mode-0600 config and the private .p8 never enters the repository.

readonly MURALUME_ASC_API_BASE_URL='https://api.appstoreconnect.apple.com'

validate_app_store_connect_private_key() {
    if [[ "$#" -ne 1 ]]; then
        echo "App Store Connect private-key validation needs one path." >&2
        return 64
    fi

    local asc_validation_private_key_path="$1"

    # Team API keys sign ES256 JWTs. Parse and exercise the key locally so a
    # malformed, public-only, RSA, or wrong-curve .p8 fails before networking.
    if ! ruby -ropenssl -e '
path = ARGV.fetch(0)
key = OpenSSL::PKey.read(File.binread(path))
abort unless key.is_a?(OpenSSL::PKey::EC)
abort unless key.private?
abort unless key.group.curve_name == "prime256v1"
digest = OpenSSL::Digest::SHA256.digest("Muralume ASC local key validation")
signature = key.dsa_sign_asn1(digest)
abort unless key.dsa_verify_asn1(digest, signature)
' "${asc_validation_private_key_path}" >/dev/null 2>&1; then
        echo "The App Store Connect private key must be a valid P-256 EC Team API key." >&2
        return 1
    fi
}

validate_app_store_connect_credentials() {
    local asc_key_id="${MURALUME_ASC_KEY_ID:-}"
    local asc_issuer_id="${MURALUME_ASC_ISSUER_ID:-}"
    local asc_private_key_path="${MURALUME_ASC_PRIVATE_KEY_PATH:-}"

    [[ "${asc_key_id}" =~ ^[A-Z0-9]{10}$ ]] || {
        echo "MURALUME_ASC_KEY_ID must be a 10-character key ID." >&2
        return 1
    }
    [[ "${asc_issuer_id}" \
        =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || {
        echo "MURALUME_ASC_ISSUER_ID must be a UUID." >&2
        return 1
    }
    [[ "${asc_private_key_path}" == /* \
        && -f "${asc_private_key_path}" \
        && ! -L "${asc_private_key_path}" ]] || {
        echo "MURALUME_ASC_PRIVATE_KEY_PATH must be an absolute regular-file path." >&2
        return 1
    }
    [[ "$(stat -f '%Lp' "${asc_private_key_path}")" == '600' ]] || {
        echo "The App Store Connect private key must have permissions 0600." >&2
        return 1
    }
    [[ "$(stat -f '%u' "${asc_private_key_path}")" == "$(id -u)" ]] || {
        echo "The App Store Connect private key must be owned by the current user." >&2
        return 1
    }
    if [[ -n "${MURALUME_ASC_FORBIDDEN_ROOT:-}" ]]; then
        local asc_canonical_forbidden_root
        local asc_canonical_private_key_directory
        asc_canonical_forbidden_root="$(
            cd "${MURALUME_ASC_FORBIDDEN_ROOT}" && pwd -P
        )" || return 1
        asc_canonical_private_key_directory="$(
            cd "$(dirname "${asc_private_key_path}")" && pwd -P
        )" || return 1
        case "${asc_canonical_private_key_directory}" in
            "${asc_canonical_forbidden_root}"|"${asc_canonical_forbidden_root}/"*)
                echo "The App Store Connect private key must stay outside the repository." >&2
                return 1
                ;;
        esac
    fi
    validate_app_store_connect_private_key "${asc_private_key_path}"
}

app_store_connect_jwt() {
    validate_app_store_connect_credentials || return 1

    MURALUME_ASC_JWT_KEY_ID="${MURALUME_ASC_KEY_ID}" \
    MURALUME_ASC_JWT_ISSUER_ID="${MURALUME_ASC_ISSUER_ID}" \
    MURALUME_ASC_JWT_PRIVATE_KEY_PATH="${MURALUME_ASC_PRIVATE_KEY_PATH}" \
        ruby -rbase64 -rjson -ropenssl -e '
def base64url(value)
  Base64.urlsafe_encode64(value, padding: false)
end

header = {
  alg: "ES256",
  kid: ENV.fetch("MURALUME_ASC_JWT_KEY_ID"),
  typ: "JWT",
}
now = Time.now.to_i
payload = {
  iss: ENV.fetch("MURALUME_ASC_JWT_ISSUER_ID"),
  iat: now,
  exp: now + 600,
  aud: "appstoreconnect-v1",
}
unsigned = [header, payload].map { |part| base64url(JSON.generate(part)) }.join(".")
key = OpenSSL::PKey::EC.new(File.binread(ENV.fetch("MURALUME_ASC_JWT_PRIVATE_KEY_PATH")))
der_signature = key.dsa_sign_asn1(OpenSSL::Digest::SHA256.digest(unsigned))
integers = OpenSSL::ASN1.decode(der_signature).value.map(&:value)
signature_hex = integers.map { |integer| integer.to_s(16).rjust(64, "0") }.join
signature = [signature_hex].pack("H*")
puts "#{unsigned}.#{base64url(signature)}"
'
}

app_store_connect_get() {
    if [[ "$#" -lt 2 ]]; then
        echo "App Store Connect GET needs an output path and endpoint." >&2
        return 64
    fi

    local asc_output_path="$1"
    local asc_endpoint="$2"
    shift 2
    local asc_jwt
    local asc_http_status

    asc_jwt="$(app_store_connect_jwt)" || return 1
    asc_http_status="$(
        printf 'header = "Authorization: Bearer %s"\n' "${asc_jwt}" \
            | curl --silent --show-error \
                --config - \
                --connect-timeout 10 \
                --max-time 45 \
                --retry 2 \
                --retry-delay 1 \
                --get \
                --output "${asc_output_path}" \
                --write-out '%{http_code}' \
                --header 'Accept: application/json' \
                "${MURALUME_ASC_API_BASE_URL}${asc_endpoint}" \
                "$@"
    )" || return 1
    chmod 600 "${asc_output_path}" || return 1
    [[ "${asc_http_status}" == '200' ]] || {
        printf 'App Store Connect API returned HTTP %s.\n' \
            "${asc_http_status}" >&2
        return 1
    }
}

app_store_connect_app_id() {
    if [[ "$#" -ne 2 ]]; then
        echo "App lookup needs a bundle identifier and work directory." >&2
        return 64
    fi

    local asc_bundle_identifier="$1"
    local asc_work_directory="$2"
    local asc_response_path="${asc_work_directory}/asc-apps.json"

    app_store_connect_get \
        "${asc_response_path}" \
        '/v1/apps' \
        --data-urlencode "filter[bundleId]=${asc_bundle_identifier}" \
        --data-urlencode 'limit=2' || return 1
    ruby -rjson -e '
response = JSON.parse(File.binread(ARGV.fetch(0)))
apps = response.fetch("data")
abort "Expected exactly one App Store Connect app." unless apps.length == 1
puts apps.fetch(0).fetch("id")
' "${asc_response_path}"
}

app_store_connect_testflight_build_state() {
    if [[ "$#" -ne 4 ]]; then
        echo "TestFlight lookup needs a bundle ID, version, build, and work directory." >&2
        return 64
    fi

    local asc_bundle_identifier="$1"
    local asc_marketing_version="$2"
    local asc_build_number="$3"
    local asc_work_directory="$4"
    local asc_app_id
    local asc_response_path="${asc_work_directory}/asc-testflight-builds.json"

    asc_app_id="$(
        app_store_connect_app_id \
            "${asc_bundle_identifier}" "${asc_work_directory}"
    )" || return 1
    app_store_connect_get \
        "${asc_response_path}" \
        '/v1/preReleaseVersions' \
        --data-urlencode "filter[app]=${asc_app_id}" \
        --data-urlencode "filter[version]=${asc_marketing_version}" \
        --data-urlencode 'filter[platform]=MAC_OS' \
        --data-urlencode "filter[builds.version]=${asc_build_number}" \
        --data-urlencode 'include=builds' \
        --data-urlencode 'limit=2' \
        --data-urlencode 'limit[builds]=2' || return 1
    ruby -rjson -e '
response = JSON.parse(File.binread(ARGV.fetch(0)))
expected_build = ARGV.fetch(1)
matching = response.fetch("included", []).select do |resource|
  resource["type"] == "builds" && resource.dig("attributes", "version") == expected_build
end
if matching.empty?
  puts "MISSING"
elsif matching.length == 1
  puts matching.fetch(0).dig("attributes", "processingState") || "UNKNOWN"
else
  abort "App Store Connect returned duplicate TestFlight build numbers."
end
' "${asc_response_path}" "${asc_build_number}"
}
