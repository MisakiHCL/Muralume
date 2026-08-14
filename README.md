<p align="center">
  <img
    src="Muralume/Resources/Assets.xcassets/BrandMark.imageset/BrandMark.png"
    width="112"
    height="112"
    alt="Muralume logo"
  >
</p>

<h1 align="center">Muralume</h1>

<p align="center"><strong>Your videos. Your Mac. Your desktop in motion.</strong></p>

<p align="center">
  <strong>English</strong> · <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <a href="https://github.com/MisakiHCL/Muralume/releases/latest"><strong>Download the latest release</strong></a>
  · Apple silicon · macOS 14+
</p>

<p align="center">
  <img
    src=".github/assets/muralume-player-v1-en.png"
    width="1200"
    alt="Muralume playing a local video with the Media Library open"
  >
</p>

Muralume is a private, native macOS app that turns your own videos into a
Dynamic Desktop. It combines a focused local player, a searchable Media
Library, named playlists, and multi-display desktop playback without accounts,
cloud uploads, advertising, or tracking.

## See it in motion

This short tour shows how a local video becomes a Dynamic Desktop while files,
widgets, and normal desktop interaction remain available.

https://github.com/user-attachments/assets/9a6f92f6-ec13-476c-a863-55134aa03f3a

## Features

- **Your local media:** Add individual videos, folders, or both. Muralume keeps
  source files in place and accesses only the items you choose.
- **Media Library:** Browse thumbnails, sort your collection, search by name or
  location, and automatically discover folder changes while the app is open.
- **Named playlists:** Create custom groups, add and reorder videos, search
  within a playlist, and continue from the same playlist after relaunch.
- **Clear playback controls:** Use ordered playback, shuffle, Repeat Current Video,
  seeking, volume, speed, fullscreen, and a separate Play Queue.
- **Dynamic Desktop:** Place video behind desktop files and widgets, use one
  synchronized queue across displays, or assign an independent loop to each
  display.
- **Private and native:** Local processing, read-only media access, no account,
  no uploads, no product telemetry, and no automatic crash reporting.
- **Session recovery:** Reopen Muralume to restore the current session; enable
  Launch at Login to restore the Dynamic Desktop after signing in.

## Get started

1. Choose **Add Media…** or drag videos and folders from Finder.
2. Browse or search the Media Library, then play a video or organize it into a
   named playlist.
3. Choose ordered playback, shuffle, or Repeat Current Video from the player.
4. Press `⌘D` to use the current playback collection as a Dynamic Desktop, or
   press `⇧⌘D` to customize displays.

## Download

[Download `Muralume.dmg`](https://github.com/MisakiHCL/Muralume/releases/latest/download/Muralume.dmg),
open it, and drag Muralume into Applications. Official version notes and
checksums are published with each [GitHub Release](https://github.com/MisakiHCL/Muralume/releases).

## Keyboard shortcuts

| Action | Shortcut |
|---|---|
| Add videos or folders | `⌘O` |
| Search videos | `⌘F` |
| Set as Dynamic Desktop | `⌘D` |
| Customize display layout | `⇧⌘D` |
| Play / pause | `Space` |
| Back / forward 10 seconds | `←` / `→` |
| Previous / next video | `⌘←` / `⌘→` |
| Volume down / up | `↓` / `↑` |
| Mute / unmute | `M` |
| Enter / exit fullscreen | `F` |
| Open settings | `⌘,` |

## System requirements

- Apple silicon Mac
- macOS 14 or later
- A video in an AVFoundation-compatible format, including common MP4, MOV, M4V, MPEG,
  MPEG-TS, 3GP, 3G2, AVI, and DV files

Playback compatibility depends on the codecs available through macOS.

## Build from source

Install Xcode with Swift 6 support and
[ripgrep](https://github.com/BurntSushi/ripgrep), then run:

```bash
git clone https://github.com/MisakiHCL/Muralume.git
cd Muralume
make test
make package-macos
```

`make package-macos` creates a local, ad-hoc signed DMG for development and
installation testing. It is not an official distribution build.

## Open source

Source code is available under the [MIT License](LICENSE). Before contributing,
read [Contributing](CONTRIBUTING.md), the [Security Policy](SECURITY.md), and the
[Community Code of Conduct](CODE_OF_CONDUCT.md). Vendored build components retain
their licenses in [Third-Party Notices](THIRD_PARTY_NOTICES.md). The Muralume
name and visual assets are excluded from the MIT grant; see the
[Brand Assets Notice](BRAND_ASSETS.md).
