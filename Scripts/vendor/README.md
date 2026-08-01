# Vendored DMG metadata dependencies

These packages are committed as source so the macOS packaging workflow can
write Finder layout metadata without launching Finder, installing Homebrew
packages, or downloading dependencies at build time.

| Package | Version | Upstream commit | License |
|---|---:|---|---|
| `ds_store` | 1.3.1 | `906169b4c9ce12e2d3e462ef487ea29031d2843f` | MIT; see `ds_store/LICENSE` |
| `mac_alias` | 2.2.2 | `c5c6fa8f59792a6e1b3812086e540857ef31be45` | MIT; see `mac_alias/LICENSE` |

Only the importable runtime packages are included. Tests, documentation,
packaging metadata, and command-line entry points are intentionally omitted.
The source is otherwise unchanged from the tags listed above.
