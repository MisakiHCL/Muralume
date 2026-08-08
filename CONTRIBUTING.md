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
and UI tests require an active macOS graphical session.

To build a local-only, ad-hoc signed installer:

```bash
make package-macos
```

Never publish that local package as an official release.

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
