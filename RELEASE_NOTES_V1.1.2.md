# Muralume v1.1.2 — Smarter energy use and cleaner playback

Muralume v1.1.2 makes Dynamic Desktop more energy-aware and improves small but
important player interactions.

## What’s new

- **Progressive energy protection:** on battery or UPS power, in Low Power
  Mode, under elevated thermal pressure, or during sustained system load,
  Muralume disconnects the decorative blurred fill while keeping the primary
  video running.
- **Automatic pause when the desktop is hidden:** Dynamic Desktop pauses after
  all of its visible desktop windows remain occluded for 750 milliseconds and
  resumes when any display becomes visible again. This uses only public macOS
  window state and does not require Accessibility or screen-recording access.
- **Battery- and thermal-aware playback:** a final battery warning or serious
  thermal pressure pauses Dynamic Desktop without interrupting intentional
  foreground viewing. Critical thermal pressure still protects all playback.
- **Better multi-display behavior:** energy and occlusion state remain correct
  while displays are connected, replaced, or waiting for their first frame.
- **Cleaner viewing controls:** click the video to dismiss an open library,
  queue, or Settings panel. Playback controls now auto-hide while paused too,
  making it easier to view or capture an unobstructed frame.
- **Shorter login setting:** the English setting is now labeled **Launch at
  Login**, so it fits cleanly in the Settings inspector.
- **More resilient releases:** the test and dual-release workflows now use
  isolated source snapshots, durable provenance, resumable endpoint checks,
  and stricter signing and App Store Connect validation.

Muralume continues to keep your media local. It requires no account, uploads no
videos, and requests read-only access only to the files and folders you choose.

## Install

Download `Muralume.dmg`, open it, and drag Muralume into Applications.

Requires an Apple silicon Mac running macOS 14 or later. The DMG is signed with
Developer ID, notarized by Apple, stapled, verified by Gatekeeper, and
accompanied by a SHA-256 checksum file.

The final SHA-256 value is published in `Muralume.dmg.sha256` alongside the DMG.
