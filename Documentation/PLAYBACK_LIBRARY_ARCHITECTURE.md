# Playback, Media Library, and Finder Open Architecture

This document records the product and implementation boundaries for local
media playback introduced with the Finder file-association and playback-queue
refactor. These boundaries are part of the expected behavior, not incidental
details of the current UI.

## Product model

Muralume keeps four related concepts separate:

1. **Media library** — the durable set of videos and folders the user has
   explicitly added. Its sources use read-only security-scoped bookmarks and
   are eligible for session restore and Dynamic Desktop playback.
2. **Playback queue** — the active navigation state: membership, current item,
   ordered or shuffled pending items, previous-navigation history, forward
   history, and round position. It can be synchronized with the library without
   being rebuilt.
3. **External playback context** — a transient foreground playback intent
   created by opening files from Finder. It freezes normal session and desktop
   persistence until the context is adopted, discarded, or restored.
4. **Dynamic Desktop return context** — a snapshot of the desktop queue,
   cursor, time, and play/pause intent captured before Finder playback takes
   over the single player window.

`isExternalPlaybackContext` and `temporaryItemIDs` are deliberately
orthogonal. A Finder request can use an external presentation context while
playing items already present in the library, so “external” must not be
inferred from whether an item needs a temporary security scope.

## One player, one window

The app continues to own one playback coordinator, one AVFoundation engine,
one playback clock, and one main player window. Finder Open requests reveal or
reuse that window. Dynamic Desktop playback and foreground playback never
create competing decoders or ambiguous global playback controls.

When Finder interrupts an active Dynamic Desktop, Muralume captures the return
context, pauses the desktop presentation, returns to the player, and preserves
an explicit **Restore Dynamic Desktop** action. A failed external request
restores the previous desktop automatically. Closing the detour can also return
to the captured desktop state.

## Finder file association and default-player status

`Info.plist` registers Muralume as an alternate Viewer for exactly the formats
the media scanner accepts:

- `public.mpeg-4` for MP4
- `com.apple.quicktime-movie` for MOV
- `com.apple.m4v-video` for M4V

The app does not claim the broad `public.movie` type and does not export system
UTIs. Registration makes Muralume available in Finder’s **Open With** menu; it
does not silently make Muralume the default application.

AppKit open-file events can arrive before application startup is complete.
`AppDelegate` therefore buffers them until both launch completion and the app
coordinator are ready, then delivers each batch once. Later requests are
handled immediately. Request generations cancel stale scans, restores, and
loads so an older request cannot overwrite a newer user intent.

Default-player state is queried from Launch Services for each supported UTI.
The Settings UI reports **all**, **some**, or **none** and can explicitly set
Muralume as the default for missing supported formats. This state is never
stored as an app preference because Finder or another app can change it.

## Finder Open routing

Finder Open follows these rules:

- A single URL that resolves to an existing library item plays that item in the
  synchronized media-library queue and shows the Media Library section.
- Unknown files, or a batch containing multiple files, form an independent
  external queue. The first playable item starts immediately and the sidebar
  shows the Play Queue focused on Now Playing.
- Reopening an external URL supersedes any unresolved earlier request instead
  of appending silently.
- Unsupported or unavailable items are skipped. If part of a batch succeeds,
  the first playable item starts and the skipped count is reported without
  damaging the prior desktop return context.
- External items remain outside the durable library until the user chooses to
  add them. Promoting them transfers source ownership into the normal bookmark
  session without double-releasing the incoming security scope.

Cold-start classification waits for an already-running startup scan only when
a single file might resolve to a library item. Multi-file requests do not wait
for the entire library scan because they always form an external batch.

## Queue synchronization and navigation

The queue uses incremental mutations instead of rebuilding whenever the user
clicks an item or refreshes the library:

- `select` jumps to a requested item while preserving valid back history and
  branching away from forward history.
- `synchronizeItems` reconciles durable membership while preserving the
  current item, playback position, existing pending order, shuffle round, and
  navigation history whenever possible.
- Ordered additions enter the current pending schedule after the current
  position. Shuffled additions are interleaved into pending items without
  reshuffling survivors.
- Authoritative refreshes remove confirmed missing media and add new media to
  the pending queue. Incomplete or unavailable roots retain their prior queue
  items so an offline disk is not mistaken for deletion.
- A synchronization-created fallback cursor is never recorded as played. This
  prevents an unplayed library item from appearing as Previous when leaving a
  temporary queue.

The navigation history remains an internal control mechanism. The sidebar does
not render a “previous items” section, but Previous still returns to genuinely
played, valid queue items. A one-item queue disables manual Previous and Next.

## Playback modes and item completion

Playback order and repeat behavior are separate internal states:

- `PlaybackOrder`: ordered or shuffled queue traversal
- `PlaybackRepeatBehavior`: advance through the queue or repeat the current
  item
- `PlaybackMode`: the user-facing ordered, shuffled, or Repeat Current choice

Repeat Current changes only natural item completion. Manual Previous, Next,
and direct selection continue to navigate normally. Repetition seeks the
existing player item to zero instead of rebuilding the asset and queue.

Every one-item queue uses this same seek-to-zero completion path regardless of
the selected playback mode. This avoids unnecessary asset loading and queue
checkpoint work while preserving the user’s chosen mode for later multi-item
playback. Failed or unavailable media never enter an infinite repeat loop.

## Sidebar roles and performance

The sidebar title menu switches between two views with distinct roles:

- **Media Library** is the full, sortable, virtualized durable collection.
- **Play Queue** is the actual playback sequence, including temporary items and
  shuffle order.

The queue is not deduplicated against the library because that would hide the
real upcoming order. Instead it shows Now Playing plus a bounded window of 40
upcoming items. **Show More** expands the window by another 40 items.

Upcoming rows are direct children of a `LazyVStack`, so row views and thumbnail
tasks are created on demand. Stable section, media, and occurrence identifiers
avoid recreating the visible window merely because advancing playback shifted
every numeric index. Explicitly opening or selecting the Play Queue resets the
window and focuses Now Playing; ordinary refreshes do not collapse an expanded
window or steal the user’s scroll position.

Media Library and Play Queue rows share the same thumbnail geometry and 8-point
content inset. Current playback is communicated through row treatment and the
state icon rather than an additional colored leading bar.

## Persistence and security invariants

- External playback must never overwrite the last known durable player session
  or Dynamic Desktop preset.
- Pending coalesced saves are cancelled when an external context begins.
- Adoption, restoration, or an explicit library selection publishes durable
  queue truth only after the external persistence gate is safely released.
- Security-scoped access has one explicit owner at every stage. Normal picker
  imports are session-managed; promotion from temporary playback is
  caller-managed until ownership transfers.
- Temporary scopes, thumbnail requests, scans, playback loads, and root removal
  remain balanced across cancellation and shutdown.

## Verification expectations

The implementation recorded here passed the complete repository gate on
2026-08-11: `make test` completed in 306 seconds with 483 non-UI and 6 UI
tests (489 total), no failures, skips, or expected failures. The same gate also
passed architecture, localization, fixture, and unsigned arm64 Release-build
checks.

Automated workspace fakes do not replace Launch Services integration testing.
Before release, install Muralume in Applications and manually verify Finder
Open With, cold and warm launches, and default-player changes for MP4, MOV, and
M4V. Do not use a translocated or read-only DMG path for that validation.

Future changes to this subsystem should cover, as applicable:

- cold- and warm-start AppKit open-file delivery;
- known library items, temporary single files, and mixed external batches;
- Dynamic Desktop interruption, failure, restoration, adoption, and request
  supersession;
- complete versus incomplete refresh reconciliation;
- ordered and shuffled selection, history, forward history, and persistence
  round trips;
- one-item completion and disabled manual navigation;
- security-scope ownership during import promotion;
- Launch Services all/some/none default-player state;
- bounded projections for large queues and stable sidebar behavior.

Run `make test` before committing changes that affect these invariants.
