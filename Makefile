SHELL := /bin/bash

VERBOSE ?= 0

-include Config/Release.local.mk
-include Config/AppStoreConnect.local.mk
-include .env.test.local

MURALUME_DEVELOPER_ID_APPLICATION ?=
MURALUME_NOTARY_KEYCHAIN_PROFILE ?=
MURALUME_EXPECTED_TEAM_IDENTIFIER ?=
MURALUME_REPLACE_DISTRIBUTION_REQUIREMENTS ?= 0
MURALUME_REAL_MEDIA_DIRECTORY ?=
MURALUME_ASC_KEY_ID ?=
MURALUME_ASC_ISSUER_ID ?=
MURALUME_ASC_PRIVATE_KEY_PATH ?=
RELEASE_TITLE ?=
RELEASE_NOTES_FILE ?=
export MURALUME_REAL_MEDIA_DIRECTORY
export RELEASE_TITLE
export RELEASE_NOTES_FILE

developer-release-targets := prepare-distribution-requirements release-doctor release-dual release-dual-steps release-macos release-macos-steps
app-store-release-targets := release-doctor release-status release-dual release-dual-steps mas-preflight validate-testflight validate-testflight-steps upload-testflight upload-testflight-steps
$(developer-release-targets): export MURALUME_DEVELOPER_ID_APPLICATION := $(MURALUME_DEVELOPER_ID_APPLICATION)
$(developer-release-targets): export MURALUME_NOTARY_KEYCHAIN_PROFILE := $(MURALUME_NOTARY_KEYCHAIN_PROFILE)
$(developer-release-targets): export MURALUME_EXPECTED_TEAM_IDENTIFIER := $(MURALUME_EXPECTED_TEAM_IDENTIFIER)
$(app-store-release-targets): export MURALUME_ASC_KEY_ID := $(MURALUME_ASC_KEY_ID)
$(app-store-release-targets): export MURALUME_ASC_ISSUER_ID := $(MURALUME_ASC_ISSUER_ID)
$(app-store-release-targets): export MURALUME_ASC_PRIVATE_KEY_PATH := $(MURALUME_ASC_PRIVATE_KEY_PATH)

LOCAL_DMG := $(abspath dist/macos-local/Muralume.dmg)
RELEASE_DMG := $(abspath dist/macos-release/Muralume.dmg)

.PHONY: help test test-steps test-real-media package-macos package-macos-steps prepare-distribution-requirements release-doctor release-status release-dual release-dual-steps release-macos release-macos-steps mas-preflight validate-testflight validate-testflight-steps upload-testflight upload-testflight-steps

define run-quiet-workflow
	@if [[ "$(VERBOSE)" == "1" \
		&& "$(2)" != "release-macos" \
		&& "$(2)" != "release-dual" \
		&& "$(2)" != "validate-testflight" \
		&& "$(2)" != "upload-testflight" ]]; then \
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
		'  make test-real-media        Import local media and exercise Dynamic Desktop' \
		'  make package-macos          Build a local-only, ad-hoc signed DMG' \
		'  make prepare-distribution-requirements' \
		'                              Export and record the private bridge requirement' \
		'  make release-macos          Build, sign, notarize, and verify the release DMG' \
		'  make release-doctor         Check GitHub, Apple, signing, proxy, and disk access' \
		'  make release-status         Verify GitHub Release and TestFlight remote state' \
		'  make release-dual           Publish one complete GitHub + TestFlight release' \
		'  make mas-preflight          Check the private Mac App Store configuration' \
		'  make validate-testflight    Archive and validate with App Store Connect' \
		'  make upload-testflight      Validate and upload a TestFlight/App Store build' \
		'' \
		'Set VERBOSE=1 to stream complete non-signing build output.'

test:
	+$(call run-quiet-workflow,test-steps,test)

test-steps:
	./Scripts/verify.sh all

test-real-media:
	@if [[ -z "$(MURALUME_REAL_MEDIA_DIRECTORY)" \
		|| ! -d "$(MURALUME_REAL_MEDIA_DIRECTORY)" ]]; then \
		echo 'Set MURALUME_REAL_MEDIA_DIRECTORY to a readable media directory.' >&2; \
		exit 64; \
	fi
	@./Scripts/verify.sh real-media

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
	@./Scripts/release_macos.sh \
		--mode distribution \
		--output "$(RELEASE_DMG)"

release-doctor:
	@./Scripts/release_doctor.sh

release-status:
	@./Scripts/release_dual.sh --status

release-dual:
	@printf 'Publishing the complete Muralume GitHub + TestFlight release...\n'
	+$(call run-quiet-workflow,release-dual-steps,release-dual)

release-dual-steps:
	@./Scripts/release_dual.sh

mas-preflight:
	@./Scripts/release_app_store.sh --mode check

validate-testflight:
	@printf 'Validating a private Muralume App Store archive...\n'
	+$(call run-quiet-workflow,validate-testflight-steps,validate-testflight)

validate-testflight-steps:
	@./Scripts/release_app_store.sh --mode validate

upload-testflight:
	@printf 'Uploading a validated Muralume build to App Store Connect...\n'
	+$(call run-quiet-workflow,upload-testflight-steps,upload-testflight)

upload-testflight-steps:
	@./Scripts/release_app_store.sh --mode upload
