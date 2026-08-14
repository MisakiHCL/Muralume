# Muralume Product Planning

> Maintainer planning note. Candidate items are exploration areas, not release
> commitments. This repository is public; this document records product
> decisions but contains no confidential material. Last updated: 2026-08-14.

## Product direction

Muralume is a private, native macOS product that combines focused local-video
playback, a durable personal media library, and an energy-aware Dynamic
Desktop. It prioritizes user-owned media, local processing, clear roles for the
library, playlists, and playback queue, desktop usability, and equivalent
behavior in Developer ID and App Store distributions.

Accounts, uploads, advertising, telemetry, a hosted wallpaper catalog, and
features that require private macOS APIs are outside the current direction.

## Competitive frame

Product research should compare four reference groups instead of building an
undifferentiated feature checklist:

| Reference group | User expectation to study | Muralume opportunity | Deliberate boundary |
| --- | --- | --- | --- |
| Dynamic-wallpaper products | Discovery, scene switching, display controls, and unobtrusive desktop behavior | Make user-owned videos easy to organize and reuse as desktop scenes | Do not add a hosted catalog, social layer, or account requirement |
| Local video players | Reliable playback, format handling, subtitles, audio tracks, and keyboard control | Preserve a focused native player while closing high-value playback gaps | Do not turn Muralume into a general-purpose media workstation |
| Media-library products | Retrieval, visual browsing, collections, metadata, and source health | Make growing local libraries understandable without moving files | Do not upload, duplicate, or reorganize the user's source files |
| Apple media apps | Platform-native terminology, selection, menus, lists, and accessibility | Follow familiar macOS information architecture and interaction patterns | Do not copy service- or catalog-specific concepts that do not fit local media |

Every future comparison should record the official source and review date, the
user expectation it establishes, the observed gap or opportunity, what should
be adapted, and what should not be copied. Price, platform support,
subscriptions, and distribution terms must be rechecked before being cited.

## v1.2.0 organization milestone

### Search

- Search the Media Library and an individual playlist by video name, source,
  directory, or relative path without changing the underlying collection.
- Treat Chinese input, exact and substring matching, live folder refresh, and
  filtering a deeply scrolled collection as correctness requirements rather
  than optional refinements.
- Selecting a filtered result starts at that item while preserving the complete
  Media Library or playlist as the playback collection.

### Named playlists

- Let users create, rename, delete, search, and manually order named groups.
- Show whether a video already belongs to a playlist before another add action.
- Retain unavailable entries with their last-known identity and reconnect them
  after an unambiguous rename, move, or source return.
- Restore the last active playlist and its playback collection after relaunch.

### Automatic folder refresh

- Monitor authorized folders recursively while Muralume is running and
  converge after additions, removals, renames, and moves.
- Local file-system events normally refresh within about two seconds. A
  periodic authoritative scan catches silent event loss in about one minute
  plus scan time.
- Network folders, cloud placeholders, removable media, and FUSE-backed sources
  remain best effort. Manual **Refresh Media Library** remains the immediate
  recovery action.
- Monitoring owns no bookmark or security scope and does not install a
  background helper. Changes made while the app is closed are found at the next
  launch.

### Information architecture and UI

- Keep the navigation order and terminology consistent: **Media Library →
  Playlists → Play Queue**. **Now Playing** describes one current item, not the
  queue as a whole.
- Do not focus Search automatically when the sidebar opens; `⌘F` and an
  intentional click remain explicit focus actions.
- Use the app's translucent, neutral visual treatment for playlist naming,
  allow click-away cancellation, and use a neutral name placeholder.
- Preserve the same selection marker, accessibility semantics, and navigation
  behavior across all three sidebar surfaces.

### Dynamic Desktop included in the release range

The complete v1.1.2-to-v1.2.0 product range also includes synchronized and
per-display Dynamic Desktop layouts, durable per-display assignments, and
per-display fit. These capabilities were merged after the v1.1.2 tag and are
therefore part of the v1.2.0 release even though the organization milestone was
the focus of the later product discussion.

Implementation contracts live in
[Playback architecture](PLAYBACK_LIBRARY_ARCHITECTURE.md). Acceptance guidance
lives in [Real-media UI testing](REAL_MEDIA_UI_TESTING.md), and the distribution
workflow lives in [Dual release playbook](DUAL_RELEASE_PLAYBOOK.md).

## Explicit decisions and non-goals

- **Screen saver: removed, not deferred.** A traditional macOS screen-saver
  bundle cannot be distributed through the Mac App Store while preserving the
  same product in both channels. Muralume will support Dynamic Desktop as its
  ambient presentation and will not ship a separate screen-saver target,
  configuration entry, or Developer ID-only feature. Reconsider only if a
  compliant shared distribution path exists and the product decision is
  explicitly reopened.
- **No background monitoring.** Folder monitoring operates only while the app
  is running.
- **No cloud catalog or account layer.** Media remains local, user-selected,
  and read-only.
- **No private-API integrations.** Distribution parity and public macOS APIs
  are release gates for future features.

## Candidate directions

These are problem areas to validate, not a v1.3 commitment.

### Visual organization

Explore grid browsing, favorites or tags, smart playlists, and batch playlist
operations. Validate whether faster visual recognition is more valuable than
adding more advanced playback controls.

### Named desktop scenes

Explore combining a playlist, display layout, fit, and playback mode into a
named scene that can be switched in one action. Keep the playlist as the media
organization primitive and avoid duplicating its membership inside a scene.

### Source health

Make offline sources, expired permissions, incomplete scans, and the last
successful refresh easier to understand. The UI should distinguish a missing
file from a temporarily unavailable volume without silently removing either.

### Search discovery

Validate demand for filters, tokenized queries, and Chinese pinyin matching.
Any expansion must preserve deterministic ordering, bounded memory, responsive
10,000-item collections, and complete-collection playback semantics.

### Foreground playback fundamentals

Validate subtitles and audio-track selection against Muralume's primary use
cases. Add them only if they improve common local playback without obscuring
the Dynamic Desktop focus or creating channel-specific behavior.

Before assigning any candidate to a version, define its user problem, target
audience, success signal, cost and risk, privacy and energy impact, and App
Store/Developer ID parity check.

## Open questions

- Are users' primary libraries personal videos, generated ambient clips, or
  professional footage?
- Should playlists and desktop scenes remain separate or become directly
  bindable?
- Is visual browsing more valuable than deeper foreground-player controls?
- After v1.2 correctness work, are remaining search problems primarily about
  retrieval, terminology, or discoverability?
- Which source-health signals help users recover without exposing file-system
  implementation detail?

## Decision log

- **2026-08-14:** Search, named playlists, and automatic folder refresh form
  the v1.2 organization milestone.
- **2026-08-14:** Media Library, Playlists, and Play Queue terminology is
  finalized; Now Playing is item state only.
- **2026-08-14:** Screen saver support is removed to preserve distribution
  parity. Dynamic Desktop remains the supported ambient experience.
