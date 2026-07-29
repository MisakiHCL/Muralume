# Test Media

The fixtures are silent synthetic test patterns created with FFmpeg. They
contain no third-party footage or audio and are distributed under the
repository's MIT License.

Both fixtures are twenty seconds long, use low-resolution H.264 at 15fps, and
comfortably exceed the player chrome's auto-hide delay. The matching names make
windowed/full-screen and landscape/portrait comparisons straightforward:

- `landscape-20s-h264.mp4`: 320×180
- `portrait-20s-h264.mp4`: 180×320

Regenerate the landscape fixture with:

```sh
ffmpeg \
  -f lavfi \
  -i "testsrc2=size=320x180:rate=15" \
  -t 20 \
  -an \
  -c:v libx264 \
  -preset slow \
  -crf 38 \
  -profile:v main \
  -pix_fmt yuv420p \
  -movflags +faststart \
  landscape-20s-h264.mp4
```

Regenerate the portrait fixture with:

```sh
ffmpeg \
  -f lavfi \
  -i "testsrc2=size=180x320:rate=15" \
  -t 20 \
  -an \
  -c:v libx264 \
  -preset slow \
  -crf 38 \
  -profile:v main \
  -pix_fmt yuv420p \
  -movflags +faststart \
  portrait-20s-h264.mp4
```

Encoded bytes may differ between FFmpeg versions; tests depend on the format,
duration, dimensions, and visible color content rather than a file checksum.
