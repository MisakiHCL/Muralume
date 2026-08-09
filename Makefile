SHELL := /bin/bash

VERBOSE ?= 0

-include Config/Release.local.mk

MURALUME_DEVELOPER_ID_APPLICATION ?=
MURALUME_NOTARY_KEYCHAIN_PROFILE ?=
MURALUME_EXPECTED_TEAM_IDENTIFIER ?=
MURALUME_REPLACE_DISTRIBUTION_REQUIREMENTS ?= 0
export MURALUME_DEVELOPER_ID_APPLICATION
export MURALUME_NOTARY_KEYCHAIN_PROFILE
export MURALUME_EXPECTED_TEAM_IDENTIFIER

LOCAL_DMG := $(abspath dist/macos-local/Muralume.dmg)
RELEASE_DMG := $(abspath dist/macos-release/Muralume.dmg)

.PHONY: help test test-steps package-macos package-macos-steps prepare-distribution-requirements release-macos release-macos-steps

define run-quiet-workflow
	@if [[ "$(VERBOSE)" == "1" ]]; then \
		$(MAKE) --no-print-directory $(1); \
	else \
		./Scripts/run_quiet_workflow.sh "$(2)" \
			$(MAKE) --no-print-directory $(1); \
	fi
endef

help:
	@printf '%s\n' \
		'Muralume workflows' \
		'' \
		'  make test                   Run the complete automated test suite' \
		'  make package-macos          Build a local-only, ad-hoc signed DMG' \
		'  make prepare-distribution-requirements' \
		'                              Export and record the private bridge requirement' \
		'  make release-macos          Build, sign, notarize, and verify the release DMG' \
		'' \
		'Set VERBOSE=1 to stream complete build output.'

test:
	+$(call run-quiet-workflow,test-steps,test)

test-steps:
	./Scripts/verify.sh all

package-macos:
	@printf 'Building the local Muralume DMG...\n'
	+$(call run-quiet-workflow,package-macos-steps,package-macos)
	@printf '\nLocal DMG ready (not for public distribution):\n  %s\n' "$(LOCAL_DMG)"

package-macos-steps:
	./Scripts/release_macos.sh \
		--mode local \
		--output "$(LOCAL_DMG)"

prepare-distribution-requirements:
	@printf 'Preparing the private Xcode-exported distribution requirement...\n'
	@if [[ "$(MURALUME_REPLACE_DISTRIBUTION_REQUIREMENTS)" == "1" ]]; then \
		./Scripts/prepare_distribution_requirements.sh --replace; \
	else \
		./Scripts/prepare_distribution_requirements.sh; \
	fi

release-macos:
	@printf 'Building, signing, and notarizing the Muralume DMG...\n'
	+$(call run-quiet-workflow,release-macos-steps,release-macos)
	@printf '\nNotarized DMG ready:\n  %s\n' "$(RELEASE_DMG)"
	@printf 'Checksum:\n  %s.sha256\n' "$(RELEASE_DMG)"

release-macos-steps:
	@./Scripts/prepare_distribution_requirements.sh --check
	./Scripts/verify.sh release-gate
	@./Scripts/release_macos.sh \
		--mode distribution \
		--output "$(RELEASE_DMG)"
