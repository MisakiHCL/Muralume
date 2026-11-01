# Contributing to Muralume

Thank you for helping improve Muralume. It is a native macOS app for local
video playback, media organization, and Dynamic Desktop presentation.

## Before starting

- Open an issue before beginning a broad feature, dependency, persistence, or
  architecture change.
- Keep user media local and read-only. Do not add accounts, uploads, product
  telemetry, advertising, or automatic crash reporting.
- Discuss new runtime dependencies before adding them.
- Keep user-visible behavior consistent across all supported languages.

## Local setup

Use an Apple silicon Mac, Xcode 26.0.1 or later with Swift 6.2 or later, and
`ripgrep` installed. The app supports macOS 14 or later; building it also
requires a macOS version supported by the selected Xcode.

```bash
git clone https://github.com/MisakiHCL/Muralume.git
cd Muralume
make test
```

`make test` runs architecture and localization checks, unit and integration
tests, the UI suite, fixture validation, and an unsigned Release build. UI
tests require an active macOS graphical session.

Run `./Scripts/check_toolchain.sh` to check the selected compiler, or
`./Scripts/verify.sh compatibility` to compile the Debug app and test targets
plus an unsigned Release app without running tests. CI pins Xcode 26.0.1 on
macOS 15 for this minimum-toolchain build and Xcode 26.6 on macOS 26 for the
deterministic release gate. These builds do not verify runtime behavior on
macOS 14.

Debug builds use a separate bundle identifier and data container. If local
development requires an Apple development team, copy
`Config/Local.xcconfig.example` to the Git-ignored
`Config/Local.xcconfig` and put local signing values only in that copy.

Verification commands build a dedicated test app, and each UI test uses its
own playlist session. Run UI tests with `./Scripts/verify.sh ui`; their launch
checks require the isolated test identity configured by that command.

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
- Put every user-visible string in all supported localization resources. Use
  natural interface wording, keep terminology consistent, and preserve format
  arguments. Keep plural forms in the localization dictionaries.
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

When images help explain a visual change, capture only the app window or
affected control in English and another affected language. Do not attach personal videos, real folder paths,
security-scoped bookmarks, credentials, signing material, or private logs.

## Security reports

Do not disclose vulnerabilities in a public issue or pull request. Follow the
[Security Policy](SECURITY.md) instead.

## License and brand

Contributions are provided under the repository's [MIT License](LICENSE). The
Muralume name and visual identity are governed separately by the
[Brand Assets Notice](BRAND_ASSETS.md).
