# Test Media

`sample-h264.mp4` is a silent, two-second synthetic test pattern created with
FFmpeg for automated playback and thumbnail tests. It contains no third-party
footage or audio and is distributed under the repository's MIT License.

An equivalent fixture can be regenerated with:

```sh
ffmpeg \
  -f lavfi \
  -i "testsrc2=size=320x180:rate=30" \
  -t 2 \
  -an \
  -c:v libx264 \
  -profile:v main \
  -pix_fmt yuv420p \
  -movflags +faststart \
  sample-h264.mp4
```

Encoded bytes may differ between FFmpeg versions; tests depend on the format,
duration, dimensions, and visible color content rather than a file checksum.
