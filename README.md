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
    alt="Muralume playing a local video with the playlist open"
  >
</p>

Muralume is a private, native video player that turns folders on your Mac into playlists—and any playlist into a Dynamic Desktop. It works directly with local files, without an account, cloud upload, or tracking.

> This page documents the current `main` branch. See the [latest release](https://github.com/MisakiHCL/Muralume/releases/latest) for the signed download and exact shipped scope.

## Highlights

### Private by design

Your source videos stay exactly where you put them. Muralume receives read-only access only to the folders you choose and never uploads, moves, renames, or deletes their contents. There is no account system, product telemetry, or automatic crash reporting.

### An energy-aware Dynamic Desktop

Place the current queue behind desktop files and widgets while keeping the desktop fully interactive. Muralume uses macOS-native playback, stays muted in desktop mode, does not prevent display sleep, and pauses automatically when the screen locks, the display sleeps, or the system enters a constrained state.

### Folders become playlists

Add folders from your Mac or an external drive. Muralume recursively discovers MP4, MOV, and M4V videos, generates local thumbnails, and sorts them by name, creation date, or file size—without reorganizing anything on disk.

### Focused native playback

Seek, change volume or speed, enter fullscreen, and choose ordered playback or shuffle. Shuffle visits every available video once before starting a new round. Controls stay out of the way while you watch, and global playback preferences return on the next launch.

Quit and reopen Muralume to continue from the same video, position, play or pause state, and presentation. If you were using the Dynamic Desktop, Muralume restores it directly without briefly opening the player window.

### Ready when you log in

Optionally start Muralume with macOS and restore the current queue directly as a Dynamic Desktop. The app keeps the window out of the way and exposes playback controls through its menu bar item.

## Download

[Download `Muralume.dmg`](https://github.com/MisakiHCL/Muralume/releases/latest/download/Muralume.dmg), open it, and drag Muralume into Applications.

The latest release includes a Developer ID–signed and Apple-notarized DMG plus its [SHA-256 checksum](https://github.com/MisakiHCL/Muralume/releases/latest/download/Muralume.dmg.sha256).

## Quick start

1. Add one or more folders containing videos.
2. Select a video from the playlist and choose ordered playback or shuffle.
3. Select the display button, use **Actions → Set as Dynamic Desktop**, or choose the same action from Muralume’s Dock menu.
4. To restore it automatically after login, open Settings and enable **Start Dynamic Desktop at Login** while a video queue is active. macOS may ask you to approve Muralume in Login Items.

The menu bar item lets you pause, skip, change playback speed or desktop fit, return to the player, and quit Muralume.

## Keyboard shortcuts

| Action | Shortcut |
|---|---|
| Add folder | `⌘O` |
| Set as Dynamic Desktop | `⌘D` |
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
- MP4, MOV, or M4V video
- Dynamic Desktop currently uses the primary display

Playback compatibility depends on the codecs available through macOS AVFoundation. H.264 and HEVC are common compatible choices.

## Build from source

Install Xcode with Swift 6 support and [ripgrep](https://github.com/BurntSushi/ripgrep), then run:

```bash
git clone https://github.com/MisakiHCL/Muralume.git
cd Muralume
make test
make package-macos
```

`make package-macos` creates an ad-hoc signed DMG in `dist/macos-local/` for local installation testing only.

## Open source

Source code is available under the [MIT License](LICENSE). Vendored build-tool components retain their licenses in [Third-Party Notices](THIRD_PARTY_NOTICES.md). The Muralume name, logo, app icon, and menu bar icon are excluded from the MIT grant; see the [Brand Assets Notice](BRAND_ASSETS.md).
