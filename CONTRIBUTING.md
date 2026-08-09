# Contributing to Muralume

Thank you for helping improve Muralume. The project is a native macOS Dynamic
Desktop app backed by one local player, one playback queue, and least-privilege
access to user-selected media.

## Before starting

- Open an issue before beginning a broad feature, dependency, persistence, or
  architecture change.
- Keep the Dynamic Desktop available in the standard build. The project does
  not maintain a reduced App Store variant that removes its core capability.
- Do not introduce accounts, uploads, telemetry, or automatic crash reporting.
- Full persistent-library work such as GRDB, stable media IDs, search, Tag, and
  pagination is deferred unless a maintainer explicitly reopens that scope.

## Local setup

Use an Apple silicon Mac with macOS 14 or later, Xcode with Swift 6 support,
and `ripgrep` installed.

```bash
git clone https://github.com/MisakiHCL/Muralume.git
cd Muralume
make test
```

`make test` performs architecture and localization checks, unit and integration
tests, XCUITest, fixture validation, and an unsigned Release build. Integration
and UI tests require an active macOS graphical session. Every XCTest invocation
must produce a readable result bundle with at least one test, no failures,
skips, or expected failures, and every Swift test source must belong to its
Xcode test target.

Debug builds use `com.muralume.Muralume.debug`, so their sandbox and media
bookmarks stay separate from the production app. The public defaults build
without an Apple account. To use a personal development team, copy
`Config/Local.xcconfig.example` to the Git-ignored `Config/Local.xcconfig` and
fill only the local copy. Do not choose a personal Team directly in tracked
project settings.

To build a local-only, ad-hoc signed installer:

```bash
make package-macos
```

Never publish that local package as an official release.
It uses `com.muralume.Muralume.local`, so replacing it cannot consume or mutate
the production app's sandbox container.

A direct Xcode Release build is also local-only and uses the same isolated
bundle identifier. Formal distribution is intentionally available only through
`make release-macos`, which overrides the production bundle identifier and
fails closed unless its private signing inputs are present.

A formal release requires a clean, committed source tree. Its marketing version
and build must increase from the latest semantic-version tag; an existing tag
for the candidate version must point to the exact source commit. The release
script creates a detached source snapshot, runs `release-gate` inside that
snapshot, and archives the same unchanged tree. It snapshots the private code
requirement before signing and installs the final DMG and checksum as a
rollback-protected pair, so the public output is not replaced after a failed
workflow.

Maintainers preparing a formal Developer ID release must copy
`Config/Release.local.mk.example` to the Git-ignored
`Config/Release.local.mk`, restrict it to mode `0600`, and fill the signing
identity, Keychain notary profile alias, and expected Team ID there. Passwords,
private keys, and App Store Connect credentials belong in Keychain or another
private credential store, never in either file.

The release also requires a mode-`0600`, Git-ignored
`Config/Distribution.requirements`. Create it only with:

```bash
make prepare-distribution-requirements
```

This controlled preparation is the only non-release workflow allowed to use
the production bundle identifier. It builds from a fresh detached checkout of
the clean source commit, creates a private Xcode archive, exports it with
`xcodebuild -exportArchive` using the `developer-id` method, and extracts only
from that export's `Muralume.app`. The temporary App uses the non-release
version `0.0.0 (1)` and is deleted afterward. The command accepts no App or
archive path, so an archive product, v1.0.3 source or identical source tree,
Debug build, local package, or existing installed App cannot become the
source. Do not hand-write or copy the requirement. If an invalid existing
private file must be replaced, review the failure first, then rerun with
`MURALUME_REPLACE_DISTRIBUTION_REQUIREMENTS=1`.

The release gate checks that the recorded source commit and tree exist in the
repository, rejects the v1.0.3 source tree, validates the requirement digest
and exact compatible Developer ID and Mac App Store branches, then embeds the
requirement and verifies that the signed App satisfies it. The recorded Xcode
version and exported-App CDHash are audit metadata, not a cryptographic
attestation after the temporary export has been deleted. Before Mac App Store
migration, validate the real Developer ID → bridge release → TestFlight/App
Store bookmark path on hardware.

## Implementation expectations

- Preserve the existing Domain → Application → Infrastructure / Features
  dependency direction.
- Route playback through the existing coordinator and engine. Do not create a
  second `AVPlayer`, decoder, queue, or playback clock.
- Treat media as untrusted input and keep file reads bounded and cancellable.
- Keep security-scoped access balanced across scanning, thumbnails, playback,
  source removal, cancellation, and shutdown.
- Use explicit types and named policy constants for product state, persisted
  keys, events, and limits.
- Put every user-visible string in both English and Simplified Chinese
  localization resources.
- Prefer native SwiftUI, AppKit, and macOS frameworks. Discuss new runtime
  dependencies before adding them.

## Tests and pull requests

Run focused tests while working and `make test` before requesting review. A pull
request should describe the user-visible outcome, affected lifecycle paths,
tests run, and any manual macOS validation still required.

For visual changes, include screenshots for English and Simplified Chinese when
text or layout differs. Do not attach personal videos, real folder paths,
security-scoped bookmarks, credentials, signing material, or private logs.

## Security reports

Do not disclose vulnerabilities in a public issue or pull request. Follow
[SECURITY.md](SECURITY.md) instead.

## License and brand

Contributions are provided under the repository's [MIT License](LICENSE). The
Muralume name and visual identity are governed separately by
[BRAND_ASSETS.md](BRAND_ASSETS.md).
