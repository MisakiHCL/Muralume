# Test Media

The fixtures are synthetic test patterns created with FFmpeg. They contain no
third-party footage or audio and are distributed under the repository's MIT
License.

The landscape and portrait fixtures are silent, twenty seconds long, use
low-resolution H.264 at 15fps, and
comfortably exceed the player chrome's auto-hide delay. The matching names make
windowed/full-screen and landscape/portrait comparisons straightforward:

- `landscape-20s-h264.mp4`: 320×180
- `portrait-20s-h264.mp4`: 180×320
- `alternate-tracks-5s.mp4`: 160×90 with two AAC audio options and two
  embedded `mov_text` subtitle options

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

Regenerate the alternate-track fixture with:

```sh
ffmpeg \
  -f lavfi -i "testsrc2=size=160x90:rate=15:duration=5" \
  -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=5" \
  -f lavfi -i "sine=frequency=660:sample_rate=44100:duration=5" \
  -i english-5s.srt \
  -i chinese-5s.srt \
  -map 0:v -map 1:a -map 2:a -map 3:s -map 4:s \
  -c:v libx264 -preset slow -crf 38 -profile:v main -pix_fmt yuv420p \
  -c:a aac -b:a 32k -c:s mov_text \
  -metadata:s:a:0 language=eng -metadata:s:a:0 title=English \
  -metadata:s:a:1 language=spa -metadata:s:a:1 title=Español \
  -metadata:s:s:0 language=eng -metadata:s:s:0 title="English CC" \
  -metadata:s:s:1 language=zho -metadata:s:s:1 title=简体中文 \
  -disposition:a:0 default -disposition:a:1 0 \
  -disposition:s:0 default -disposition:s:1 0 \
  -movflags +faststart \
  alternate-tracks-5s.mp4
```
