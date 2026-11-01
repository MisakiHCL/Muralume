#!/bin/bash

set -euo pipefail

readonly minimum_xcode_version="26.0.1"
readonly minimum_swift_version="6.2"

toolchain_version_at_least() {
    local actual_version="$1"
    local required_version="$2"
    local index
    local -a actual_components required_components

    IFS=. read -r -a actual_components <<<"${actual_version}"
    IFS=. read -r -a required_components <<<"${required_version}"
    for index in 0 1 2; do
        if (( 10#${actual_components[index]:-0} > 10#${required_components[index]:-0} )); then
            return 0
        elif (( 10#${actual_components[index]:-0} < 10#${required_components[index]:-0} )); then
            return 1
        fi
    done
}

main() {
    if [[ "$#" -eq 1 && "$1" == "--help" ]]; then
        printf '%s\n' \
            'Usage: ./Scripts/check_toolchain.sh [expected-xcode expected-swift-prefix]' \
            'Requires Xcode 26.0.1 and Swift 6.2 or later.' \
            'Optional CI arguments also require the selected Xcode version and Swift series.'
        return 0
    fi
    if [[ "$#" -ne 0 && "$#" -ne 2 ]]; then
        echo 'Expected either no arguments or an Xcode version and Swift prefix.' >&2
        return 64
    fi

    local expected_xcode="${1:-}"
    local expected_swift="${2:-}"
    local version_output swift_output xcode_version swift_version
    local requested_version

    for requested_version in "${expected_xcode}" "${expected_swift}"; do
        if [[ -n "${requested_version}" \
            && ! "${requested_version}" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
            echo 'Toolchain versions must contain one to three numeric components.' >&2
            return 64
        fi
    done
    version_output="$(xcodebuild -version)" || return 1
    swift_output="$(xcrun swiftc --version)" || return 1
    xcode_version="$(sed -n 's/^Xcode \([0-9][0-9.]*\)$/\1/p' <<<"${version_output}")"
    swift_version="$(sed -n 's/^Apple Swift version \([0-9][0-9.]*\).*$/\1/p' <<<"${swift_output}")"
    if [[ ! "${xcode_version}" =~ ^[0-9]+(\.[0-9]+){0,2}$ \
        || ! "${swift_version}" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
        echo 'Unable to identify the selected Xcode and Apple Swift compiler.' >&2
        return 1
    fi
    if ! toolchain_version_at_least "${xcode_version}" "${minimum_xcode_version}" \
        || ! toolchain_version_at_least "${swift_version}" "${minimum_swift_version}"; then
        printf 'Muralume requires Xcode %s+ with Swift %s+; selected Xcode %s, Swift %s.\n' \
            "${minimum_xcode_version}" "${minimum_swift_version}" \
            "${xcode_version}" "${swift_version}" >&2
        echo 'Select a supported Xcode with DEVELOPER_DIR or xcode-select.' >&2
        return 1
    fi
    if [[ -n "${expected_xcode}" && "${xcode_version}" != "${expected_xcode}" ]]; then
        printf 'Expected Xcode %s; selected Xcode %s.\n' \
            "${expected_xcode}" "${xcode_version}" >&2
        return 1
    fi
    if [[ -n "${expected_swift}" \
        && "${swift_version}" != "${expected_swift}" \
        && "${swift_version}" != "${expected_swift}."* ]]; then
        printf 'Expected Swift %s.x; selected Swift %s.\n' \
            "${expected_swift}" "${swift_version}" >&2
        return 1
    fi
    printf '%s\n' "${version_output}" "${swift_output}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
