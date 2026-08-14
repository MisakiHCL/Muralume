# Vendored DMG metadata dependencies

These packages are committed as source so the macOS packaging workflow can
write Finder layout metadata without launching Finder, installing Homebrew
packages, or downloading dependencies at build time. Versions, upstream
sources, and licenses are recorded once in
[Third-Party Notices](../../THIRD_PARTY_NOTICES.md).

Only the importable runtime packages are included. Tests, documentation,
packaging metadata, and command-line entry points are intentionally omitted.
The source is otherwise unchanged from the tags listed above.
