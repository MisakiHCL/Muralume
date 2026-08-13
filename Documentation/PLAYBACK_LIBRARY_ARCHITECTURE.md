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

## Energy and lifecycle policy

Energy protection is progressive and presentation-aware. Muralume keeps a set
of active constraint reasons instead of replacing one Boolean with the latest
signal, so clearing Low Power Mode cannot accidentally re-enable an effect
while battery, load, or thermal pressure is still active. Suspension reasons
are scoped separately to foreground playback, Dynamic Desktop, or every
presentation.

| Signal | Behavior |
| --- | --- |
| AC power with no internal battery | Run normally. An unreadable power state fails open. |
| Battery or UPS power, Low Power Mode, an early battery warning, fair thermal pressure, or sustained system load | Disconnect the decorative blurred fill while keeping the primary video active. |
| Every revealed Dynamic Desktop window is occluded | Pause Dynamic Desktop after a 750 ms debounce; keep playing while any display remains visible. |
| Final battery warning or serious thermal pressure | Pause Dynamic Desktop only, without interrupting intentional foreground viewing. |
| Critical thermal pressure, system/display sleep, or an inactive user session | Pause every applicable presentation. |

System-load protection samples only while Dynamic Desktop is active. It reads
the one-minute load average every five seconds, divides it by the active logical
processor count, enters after three consecutive samples at or above 0.85, and
recovers after six consecutive samples at or below 0.60. This is runnable-queue
pressure rather than CPU utilization, and it never causes a hard pause. Thermal
state remains the public fallback for GPU, media-engine, and aggregate heat.

Fullscreen-app handling uses only the public occlusion state of Muralume's own
desktop windows. It does not enumerate other applications, use private window
server APIs, or require Accessibility or screen-recording permission. Pending
hot-plug surfaces do not override the last known visibility of already revealed
windows.

The shared `AVPlayer` prevents display sleep only while attached to the
foreground player surface. Dynamic Desktop and detached playback surfaces leave
normal display-sleep policy in control. Power-source listeners, window
observers, and load timers are removed during teardown, and stale timer
generations cannot reactivate monitoring after a stop or presentation change.

## Finder file association and default-player status

`Info.plist` registers Muralume as an alternate Viewer for exactly the formats
the media scanner accepts:

- `public.mpeg-4` for MP4
- `com.apple.quicktime-movie` for MOV
- `com.apple.m4v-video` for M4V
- `public.mpeg` for MPEG-1 and MPEG-2 program streams
- `public.mpeg-2-video` for MPEG-2 elementary video
- `public.mpeg-2-transport-stream` for MPEG-2 transport streams and AVCHD
- `public.3gpp` for 3GPP
- `public.3gpp2` for 3GPP2
- `public.avi` for AVI
- `public.dv-movie` for DV

The app does not claim the broad `public.movie` type and does not export system
UTIs. Registration makes Muralume available in Finder’s **Open With** menu; it
does not silently make Muralume the default application.

These UTIs and their extension aliases are a container allowlist, not a codec
guarantee. Actual decoding still depends on the codecs available to
AVFoundation on the current macOS installation.

AppKit open-file events can arrive before application startup is complete.
`AppDelegate` therefore buffers them until both launch completion and the app
coordinator are ready, then delivers each batch once. Later requests are
handled immediately. Request generations cancel stale scans, restores, and
loads so an older request cannot overwrite a newer user intent.

Default-player state is queried from Launch Services for each supported UTI.
The Settings UI reports **all**, **some**, or **none** and can explicitly set
Muralume as the default for missing supported formats. It deliberately does
not enumerate every format in the settings row; unsupported files are
explained at the point where the user tries to add or open them. This state is
never stored as an app preference because Finder or another app can change it.

## Picker and drop imports

Picker and Finder-drop imports use the same extension policy as scanning and
file association. Rejections distinguish unsupported file containers from
bookmark, access, capacity, and folder-overlap failures so the UI does not
mislabel unrelated errors as format incompatibility. A wholly unsupported
selection reports that the file format is not supported yet; a mixed selection
imports accepted sources and reports that unsupported formats were skipped.

Settings blocks ordinary player commands and picker actions, but the video
area remains an intentional drop target. A drop while Settings is open is
therefore validated and imported without dismissing Settings. Unsupported
files still produce the status banner; accepted files enter the library
without autoplaying behind the settings panel.

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

`make test` is the complete repository gate. It covers architecture and
localization checks, deterministic unit and integration tests, macOS UI tests,
bundled resources, and the unsigned arm64 Release build. Use
`./Scripts/verify.sh release-gate` when a non-interactive environment cannot
run UI automation, and run `./Scripts/verify.sh ui` separately on a Mac that
has been authorized for XCTest automation.

On a local development Mac, enable developer-tool access once before the first
unattended UI-test run:

```bash
sudo /usr/sbin/DevToolsSecurity -enable
```

The initiating application may also need one-time approval under macOS Privacy
& Security. Keep a stable launcher for automated runs so the operating system
does not treat each invocation as a different automation client.

Automated workspace fakes do not replace Launch Services integration testing.
Before release, install Muralume in Applications and manually verify Finder
Open With, cold and warm launches, and default-player changes for every
supported content type. Do not use a translocated or read-only DMG path for
that validation.

Future changes to this subsystem should cover, as applicable:

- cold- and warm-start AppKit open-file delivery;
- known library items, temporary single files, and mixed external batches;
- Dynamic Desktop interruption, failure, restoration, adoption, and request
  supersession;
- overlapping power, Low Power Mode, load, and thermal reasons with independent
  recovery order;
- single- and multi-display occlusion debounce, Spaces, Stage Manager, and
  hot-plugged surfaces that are not ready for display yet;
- load-sampler activation, hysteresis, stale generations, stop, and teardown;
- complete versus incomplete refresh reconciliation;
- ordered and shuffled selection, history, forward history, and persistence
  round trips;
- one-item completion and disabled manual navigation;
- security-scope ownership during import promotion;
- unsupported, partially supported, and settings-visible drop imports;
- Launch Services all/some/none default-player state;
- bounded projections for large queues and stable sidebar behavior.

Run `make test` before committing changes that affect these invariants.
