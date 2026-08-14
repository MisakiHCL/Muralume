# Contributing to Muralume

Thank you for helping improve Muralume. It is a native macOS app for local
video playback, media organization, and Dynamic Desktop presentation.

## Before starting

- Open an issue before beginning a broad feature, dependency, persistence, or
  architecture change.
- Keep user media local and read-only. Do not add accounts, uploads, product
  telemetry, advertising, or automatic crash reporting.
- Discuss new runtime dependencies before adding them.
- Keep user-visible behavior consistent in English and Simplified Chinese.

## Local setup

Use an Apple silicon Mac with macOS 14 or later, Xcode with Swift 6 support,
and `ripgrep` installed.

```bash
git clone https://github.com/MisakiHCL/Muralume.git
cd Muralume
make test
```

`make test` runs architecture and localization checks, unit and integration
tests, the UI suite, fixture validation, and an unsigned Release build. UI
tests require an active macOS graphical session.

Debug builds use a separate bundle identifier and data container. If local
development requires an Apple development team, copy
`Config/Local.xcconfig.example` to the Git-ignored
`Config/Local.xcconfig` and put local signing values only in that copy.

To create an ad-hoc signed package for local installation testing, run:

```bash
make package-macos
```

The resulting package is not an official release and must not be published as
one. Official version notes and binaries are available through
[GitHub Releases](https://github.com/MisakiHCL/Muralume/releases).

## Implementation expectations

- Preserve the Domain → Application → Infrastructure / Features dependency
  direction.
- Route foreground playback through the existing coordinator and engine.
  Avoid parallel playback state or an unrelated playback clock.
- Treat media as untrusted input and keep file reads, scans, thumbnails, and
  background work bounded and cancellable.
- Keep security-scoped access balanced across scanning, playback, source
  removal, cancellation, and shutdown.
- Use explicit types and named constants for product state, persisted keys,
  events, and operational limits.
- Put every user-visible string in both English and Simplified Chinese
  localization resources.
- Follow the existing design system and accessibility conventions. UI spacing
  should normally follow the project's 4-point grid.
- Keep caches bounded and give them explicit invalidation and teardown paths.

## Tests and pull requests

Run focused tests while working and `make test` before requesting review. A
pull request should describe:

- the user-visible outcome;
- the scope of the change;
- automated tests run;
- manual macOS validation still required; and
- lifecycle, privacy, accessibility, or localization effects.

Include English and Simplified Chinese screenshots for visual changes when
text or layout differs. Do not attach personal videos, real folder paths,
security-scoped bookmarks, credentials, signing material, or private logs.

## Security reports

Do not disclose vulnerabilities in a public issue or pull request. Follow the
[Security Policy](SECURITY.md) instead.

## License and brand

Contributions are provided under the repository's [MIT License](LICENSE). The
Muralume name and visual identity are governed separately by the
[Brand Assets Notice](BRAND_ASSETS.md).
