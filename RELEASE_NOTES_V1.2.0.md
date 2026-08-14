# Muralume v1.2.0 — Search, playlists, and a more personal desktop

Muralume v1.2.0 makes larger local video collections easier to find, organize,
and keep up to date. It also introduces flexible multi-display Dynamic Desktop
layouts while keeping every video local and under your control.

## What's new

- **Fast Media Library search:** press `⌘F` to search video names, sources,
  folders, and relative paths. Results stay in the original collection order,
  and selecting one still plays the complete library from that video.
- **Named playlists:** create your own ordered groups, add videos from the
  library, drag to reorder them, rename or delete a playlist, and search inside
  it. Muralume shows when a video is already included and restores the active
  playlist after relaunch.
- **Automatic folder refresh:** while Muralume is running, additions,
  deletions, renames, and moves inside authorized folders update the Media
  Library automatically. A periodic full scan recovers changes that a drive or
  file-system provider does not report, and manual refresh remains available.
- **Resilient file references:** playlist and queue entries can follow an
  unambiguous rename or move on the same volume. Offline entries remain visible
  instead of being silently removed, ready to reconnect when their source
  returns.
- **Per-display Dynamic Desktop:** choose synchronized playback across enabled
  displays or assign one independently looping video to each display. Each
  display keeps its own fit and durable assignment across disconnects and
  reconnects.
- **Clearer sidebar roles:** Media Library, Playlists, and Play Queue now use a
  consistent order, selection state, and terminology in English and Simplified
  Chinese. Now Playing refers only to the current video.
- **Polished native interaction:** Search no longer takes focus when the
  sidebar opens, playlist creation uses Muralume's translucent neutral styling,
  and click-away or Escape cancels naming. Search results reliably stay visible
  during Chinese input, live refreshes, and deep-list filtering.
- **Safer restoration and releases:** playback sessions and desktop presets
  preserve their collection identity, queue references migrate to the new
  durable schema, and the dual-channel release workflow has stricter source,
  signing, provenance, and App Store Connect checks.

Muralume continues to keep your media local. It requires no account, uploads no
videos, installs no background monitoring helper, and requests read-only access
only to the files and folders you choose.

## Install

Download `Muralume.dmg`, open it, and drag Muralume into Applications.

Requires an Apple silicon Mac running macOS 14 or later. The DMG is signed with
Developer ID, notarized by Apple, stapled, verified by Gatekeeper, and
accompanied by a SHA-256 checksum file.

The final SHA-256 value is published in `Muralume.dmg.sha256` alongside the DMG.
