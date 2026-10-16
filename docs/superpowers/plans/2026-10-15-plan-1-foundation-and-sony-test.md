# Paper Plane — Plan 1: Foundation and Sony Test

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Set up the repo, answer the biggest open question (what the Sony accepts over AirPlay), and build the tested core that decides how to convert any video. This covers everything that needs neither Xcode nor the Sony results.

**Architecture:**
- A Swift package, `PaperPlaneCore` in `core/`, holds pure, testable logic:
  - `ResolvedInput`: what to feed ffmpeg.
  - `MediaProbe`: ffprobe output → `MediaInfo`.
  - `ConversionPlanner`: `MediaInfo` + TV profile → `ConversionPlan`.
  - The plan's ffmpeg command line.
- A throwaway AppKit app in `spikes/sony-test/` plays test HLS streams on the Sony through Apple's AirPlay, to find out what the TV accepts.

**Tech Stack:**
- Swift 6 with Swift Testing. The Command Line Tools are enough; no Xcode needed.
- AVFoundation / AVKit.
- Homebrew ffmpeg, for development only.
- Python 3 helper scripts, bash.

**Spec:** [docs/superpowers/specs/2026-10-15-paper-plane-design.md](../specs/2026-10-15-paper-plane-design.md)

## Where this plan fits

| Plan | Covers | Written |
|---|---|---|
| **1 (this)** | Repo scaffold, test media, the Sony test (Milestone 0), the core probe → plan → ffmpeg-arguments logic (first part of Milestone 1) | Now |
| 2 | Rest of Milestone 1: `scripts/build-ffmpeg.sh` (bundled ffmpeg), `Transcoder`, `StreamServer`, Xcode app with menu bar + remote window, AirPlay playback of a dropped file, CI on the owner's GitHub | After the Sony results, once Xcode is installed |
| 3 | Milestone 2: `SegmentWindow`, restart-on-seek, audio switching, subtitles (both kinds, sidecar `.srt`), Now Playing, sleep assertion, error handling | After Plan 2 |
| 4 | Milestone 3: Chrome/Brave extension, `paperplane-host`, `BrowserBridge` | After Plan 3 |
| 5 | Milestones 4–5: yt-dlp, Paste a link, first release | After Plan 4 |

The Sony results can change Plan 2's design. For example, if the TV can't follow a growing playlist, the stream format changes. That's why later plans are written after the Sony results, not now.

## Global Constraints

- **Platform:** macOS 14+, Apple Silicon (arm64) only.
- **Language and tests:** Swift 6 language mode (`swift-tools-version: 6.0`). Tests use Swift Testing (`import Testing`), not XCTest.
- **No Xcode in this plan:** run the core tests with `scripts/test-core.sh`, which adds the Command Line Tools' Swift Testing paths. Arguments are passed through, e.g. `scripts/test-core.sh --filter ResolvedInputTests`.
- **License:** GPL-3.0. `LICENSE` holds the full text from gnu.org.
- **Ownership:** this is the owner's personal project.
  - Commits use a repo-local personal git identity, never the work address in the global git config.
  - Nothing in the repo names the owner's employer.
- **Commit trailer:** every commit message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **ffmpeg / ffprobe:**
  - Development uses Homebrew's build (`brew install ffmpeg`), found via `PAPERPLANE_FFMPEG` / `PAPERPLANE_FFPROBE` or `PATH`.
  - It isn't shipped. The bundled build arrives in Plan 2.
  - Homebrew's build has no `libass` or `zimg`, so tests that need `subtitles` or `zscale` must skip themselves.
- **HLS output (spec §4):** fMP4 segments, 6 s target, EVENT playlist, files `index.m3u8`, `init.mp4`, `seg_%05d.m4s`.
- **Privacy (spec §5.4):**
  - Cookies and auth headers never appear in logs or error messages.
  - URL query strings are redacted.
  - Header values are stripped of CR/LF.
- **Identifiers:** use the `dev.paperplane` prefix.
- **Spikes:** code in `spikes/` is throwaway and is never imported by product code.

## Review Focus

These inputs are implied by the spec but not covered by its feature descriptions. Each is pinned by tests in the task named.

1. **Cover art embedded in a file.** An attached-picture stream, often listed first, must never be picked as the video. Pinned in Task 4 (`parsesTracksAndSkipsCoverArt`), Task 5 (`skipsEmbeddedCoverArt`) and Task 8 (`h264_coverart.mkv`).
2. **File names with spaces, colons, apostrophes and accents** (`Movie: Part 1 (Director's Cut) é.mp4`). They must reach ffprobe and ffmpeg intact, as one argument. Pinned in Task 1 (`fileInputUsesPlainPathAndFileNameTitle`), Task 5 (`handlesAwkwardFileNames`), Task 7 (`copyPlanFromTheStart`) and Task 8.
3. **10-bit H.264 ("Hi10P", common in anime releases).** It must be re-encoded, because Apple's decoders can't play it. Pinned in Task 6 (`reencodesTenBitH264BecauseAppleCannotDecodeIt`) and Task 8 (`h264_10bit_aac.mkv`, output pixel format `yuv420p`).
4. **7.1 lossless audio** (TrueHD, FLAC or DTS-HD from Blu-ray rips). It must come out as E-AC3 5.1, since the encoder's maximum is 6 channels, never a failed encode. Pinned in Task 6 (8-channel cases), Task 7 (`-ac 6`) and Task 8 (`h264_flac_71.mkv`).
5. **Files that aren't usable video** (corrupt, or audio-only). They must fail with a clear, redacted error, not a crash or a hung ffmpeg. Pinned in Task 5 (`corruptFileThrowsFFprobeFailed`, `audioOnlyFileHasNoVideo`) and Task 8 (`audioOnlyFileIsRejectedBeforeConverting`).

## File Map

| File | Responsibility | Task |
|---|---|---|
| `.gitignore`, `README.md`, `LICENSE` | Repo basics | 1 |
| `scripts/test-core.sh` | Runs core tests with or without Xcode | 1 |
| `core/Package.swift` | `PaperPlaneCore` Swift package | 1 |
| `core/Sources/PaperPlaneCore/Media/ResolvedInput.swift` | ffmpeg input(s) + safe HTTP header options | 1 |
| `scripts/check-test-media.py` | Verifies the generated test clips | 2 |
| `scripts/make-test-media.sh` | Generates test clips into `testdata/media/` (git-ignored) | 2 |
| `scripts/serve-hls.py` | Dev/test HTTP server with HLS MIME types | 2 |
| `spikes/sony-test/*` | Throwaway Sony test app + stream builders | 3 |
| `docs/sony-test-results.md` | Sony test results and the decisions they drive | 3, 9 |
| `core/Sources/PaperPlaneCore/Media/MediaInfo.swift` | Track and media model | 4 |
| `core/Sources/PaperPlaneCore/Media/FFprobeParser.swift` | ffprobe JSON → `MediaInfo`, `MediaProbeError` | 4 |
| `core/Sources/PaperPlaneCore/Support/ToolPaths.swift` | Finds ffmpeg / ffprobe | 5 |
| `core/Sources/PaperPlaneCore/Support/ProcessRunner.swift` | Runs a tool, captures output without deadlocks | 5 |
| `core/Sources/PaperPlaneCore/Support/Redaction.swift` | Keeps secrets out of error messages | 5 |
| `core/Sources/PaperPlaneCore/Media/MediaProbe.swift` | Runs ffprobe for each input, merges results | 5 |
| `core/Sources/PaperPlaneCore/Conversion/ConversionPlan.swift` | `OutputProfile`, `TrackChoice`, plan types, `PlanError` | 6 |
| `core/Sources/PaperPlaneCore/Conversion/ConversionPlanner.swift` | Spec §4.1 decision rules | 6 |
| `core/Sources/PaperPlaneCore/Conversion/FFmpegArguments.swift` | Plan → ffmpeg command line | 7 |
| `core/Tests/PaperPlaneCoreTests/*` | Tests (one file per unit, plus `TestSupport.swift` and `PipelineTests.swift`) | 1–9 |

---

### Task 1: Repository scaffold and `ResolvedInput`

**Files:**
- Create: `.gitignore`, `README.md`, `LICENSE`, `scripts/test-core.sh`, `core/Package.swift`
- Create: `core/Sources/PaperPlaneCore/Media/ResolvedInput.swift`
- Test: `core/Tests/PaperPlaneCoreTests/ResolvedInputTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public struct ResolvedInput: Equatable, Sendable` with `inputs: [Input]`, `title: String`, `init(inputs:title:)`, and `static func file(_ url: URL) -> ResolvedInput`.
  - `public struct ResolvedInput.Input: Equatable, Sendable` with `url: URL`, `headers: [String: String]`, `init(url:headers: = [:])`, `var ffmpegLocation: String` (a plain path for files) and `var ffmpegOptions: [String]` (`-user_agent` / `-headers`, for web inputs only).

- [ ] **Step 1: Set the repo-local git identity**

The owner held the first commit until a personal identity is set, because the global git config has their work address. Ask the owner for the personal name and email to use, then run these, substituting their answers:

```bash
git config user.name "Owner's Name"
git config user.email "owner@personal.example"
git config user.email
```

Expected: the last command prints the personal address the owner gave.

- [ ] **Step 2: Commit the design docs**

```bash
git add docs/superpowers/specs/2026-10-15-paper-plane-design.md docs/superpowers/plans/2026-10-15-plan-1-foundation-and-sony-test.md
git commit -m "docs: design spec and plan 1" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 3: Add the scaffold files**

`.gitignore`:

```gitignore
.DS_Store
xcuserdata/
DerivedData/

# Swift package build output
/core/.build/
/core/.swiftpm/

# Generated test clips (scripts/make-test-media.sh)
/testdata/media/

# Sony test spike output
/spikes/sony-test/build/
/spikes/sony-test/streams/

# Browser extension (later plans)
/extension/node_modules/
/extension/dist/
```

`README.md`:

````markdown
# Paper Plane

Send any video on your Mac to your AirPlay TV: MKV and other local files, or the video playing in Chrome or Brave.

> Early development. There's nothing to install yet.

## How it works

Paper Plane converts on the fly whatever your TV can't play, copying everything it can, using ffmpeg. It serves the stream from your Mac and hands it to the TV with macOS's own AirPlay. The full design is in [docs/superpowers/specs/2026-10-15-paper-plane-design.md](docs/superpowers/specs/2026-10-15-paper-plane-design.md).

## Development

You need macOS 14 or later on Apple Silicon, and Swift 6. The Command Line Tools are enough for now.

```bash
brew install ffmpeg            # development and tests only; the app will bundle its own build
scripts/make-test-media.sh     # generates test clips into testdata/media/
scripts/test-core.sh           # runs the PaperPlaneCore tests
```

## License

GPL-3.0. See [LICENSE](LICENSE).
````

`LICENSE`: download the official text and check it:

```bash
curl -fsSL https://www.gnu.org/licenses/gpl-3.0.txt -o LICENSE
sed -n '1,3p' LICENSE
```

Expected: `GNU GENERAL PUBLIC LICENSE` and `Version 3, 29 June 2007`.

`scripts/test-core.sh` (then `chmod +x scripts/test-core.sh`):

```bash
#!/usr/bin/env bash
# Runs the PaperPlaneCore tests. Works with full Xcode, and with only the Command Line
# Tools, which ship Swift Testing outside the compiler's default search path.
set -euo pipefail
cd "$(dirname "$0")/../core"
DEVELOPER_DIR="$(xcode-select -p)"
if [[ "$DEVELOPER_DIR" == *CommandLineTools* ]]; then
  FRAMEWORKS="$DEVELOPER_DIR/Library/Developer/Frameworks"
  LIBS="$DEVELOPER_DIR/Library/Developer/usr/lib"
  exec swift test \
    -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
    -Xlinker -F -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$LIBS" \
    "$@"
fi
exec swift test "$@"
```

`core/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaperPlaneCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PaperPlaneCore", targets: ["PaperPlaneCore"]),
    ],
    targets: [
        .target(name: "PaperPlaneCore"),
        .testTarget(name: "PaperPlaneCoreTests", dependencies: ["PaperPlaneCore"]),
    ]
)
```

- [ ] **Step 4: Write the failing test**

`core/Tests/PaperPlaneCoreTests/ResolvedInputTests.swift`:

```swift
import Foundation
import Testing
@testable import PaperPlaneCore

struct ResolvedInputTests {
    @Test func fileInputUsesPlainPathAndFileNameTitle() {
        let url = URL(fileURLWithPath: "/Movies/Movie: Part 1 (Director's Cut) é.mkv")
        let input = ResolvedInput.file(url)
        #expect(input.title == "Movie: Part 1 (Director's Cut) é")
        #expect(input.inputs.count == 1)
        #expect(input.inputs[0].ffmpegLocation == "/Movies/Movie: Part 1 (Director's Cut) é.mkv")
        #expect(input.inputs[0].ffmpegOptions == [])
    }

    @Test func webInputPassesUserAgentAndSortedHeaders() {
        let input = ResolvedInput.Input(
            url: URL(string: "https://cdn.example.com/v/master.m3u8?token=abc")!,
            headers: ["Referer": "https://example.com/watch", "Cookie": "a=1; b=2", "user-agent": "Chrome/140"])
        #expect(input.ffmpegLocation == "https://cdn.example.com/v/master.m3u8?token=abc")
        #expect(input.ffmpegOptions == [
            "-user_agent", "Chrome/140",
            "-headers", "Cookie: a=1; b=2\r\nReferer: https://example.com/watch\r\n",
        ])
    }

    @Test func webInputWithoutHeadersHasNoOptions() {
        let input = ResolvedInput.Input(url: URL(string: "https://example.com/v.mp4")!)
        #expect(input.ffmpegOptions == [])
    }

    @Test func headerLineBreaksAreStripped() {
        let input = ResolvedInput.Input(
            url: URL(string: "https://example.com/v.mp4")!,
            headers: ["Cookie": "a=1\r\nX-Injected: yes"])
        #expect(input.ffmpegOptions == ["-headers", "Cookie: a=1X-Injected: yes\r\n"])
    }
}
```

- [ ] **Step 5: Run it and watch it fail**

Run: `scripts/test-core.sh --filter ResolvedInputTests`
Expected: the build fails because `ResolvedInput` doesn't exist yet. You'll see either `cannot find 'ResolvedInput' in scope` or SwiftPM reporting that target `PaperPlaneCore` has no sources.

- [ ] **Step 6: Implement `ResolvedInput`**

`core/Sources/PaperPlaneCore/Media/ResolvedInput.swift`:

```swift
import Foundation

/// The ffmpeg input(s) for one playback. Web videos can arrive as separate video and
/// audio streams, so there may be more than one.
public struct ResolvedInput: Equatable, Sendable {
    public struct Input: Equatable, Sendable {
        public var url: URL
        /// HTTP headers the site expects (cookies, referer, user agent). Never logged.
        public var headers: [String: String]

        public init(url: URL, headers: [String: String] = [:]) {
            self.url = url
            self.headers = headers
        }

        /// What to pass to ffmpeg's `-i`: a plain path for files, the full URL otherwise.
        public var ffmpegLocation: String {
            url.isFileURL ? url.path : url.absoluteString
        }

        /// Options that must come right before this input's `-i` (ffmpeg) or the input (ffprobe).
        public var ffmpegOptions: [String] {
            guard !url.isFileURL else { return [] }
            var remaining = Dictionary(
                headers.map { (Self.stripLineBreaks($0.key), Self.stripLineBreaks($0.value)) },
                uniquingKeysWith: { first, _ in first })
            var options: [String] = []
            if let key = remaining.keys.first(where: { $0.lowercased() == "user-agent" }),
               let agent = remaining.removeValue(forKey: key) {
                options += ["-user_agent", agent]
            }
            if !remaining.isEmpty {
                let block = remaining.keys.sorted().map { "\($0): \(remaining[$0]!)\r\n" }.joined()
                options += ["-headers", block]
            }
            return options
        }

        /// Removes CR and LF so a header value can't smuggle in extra headers.
        private static func stripLineBreaks(_ text: String) -> String {
            String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 != "\r" && $0 != "\n" }))
        }
    }

    public var inputs: [Input]
    public var title: String

    public init(inputs: [Input], title: String) {
        self.inputs = inputs
        self.title = title
    }

    /// A local file, titled by its name without the extension.
    public static func file(_ url: URL) -> ResolvedInput {
        ResolvedInput(inputs: [Input(url: url)], title: url.deletingPathExtension().lastPathComponent)
    }
}
```

- [ ] **Step 7: Run the tests**

Run: `scripts/test-core.sh --filter ResolvedInputTests`
Expected: `✔ Test run with 4 tests in 1 suite passed`

- [ ] **Step 8: Commit**

```bash
git add .gitignore README.md LICENSE scripts/test-core.sh core/Package.swift core/Sources core/Tests
git commit -m "chore: scaffold repo; feat(core): ResolvedInput with safe ffmpeg header options" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Test media and dev tools

**Files:**
- Create: `scripts/check-test-media.py`, `scripts/make-test-media.sh`, `scripts/serve-hls.py`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `testdata/media/` with the clips listed in `check-test-media.py`: `h264_aac.mp4`, `h264_ac3_51.mkv`, `hevc_eac3_51.mkv`, `hevc_hdr10_aac.mkv`, `vp9_opus.webm`, `av1_flac_51.mkv`, `mpeg2_dts_51.mkv`, `h264_flac_71.mkv`, `h264_10bit_aac.mkv`, `h264_noaudio.mkv`, `h264_coverart.mkv`, `h264_multiaudio.mkv`, `audio_only.m4a`, `corrupt.mkv` and `Movie: Part 1 (Director's Cut) é.mp4`. All clips are 10 s and 1280×720.
  - `scripts/serve-hls.py <dir> [--bind ADDR] [--port N] [--verbose]`, which prints `PORT <n>` once listening.

- [ ] **Step 1: Install Homebrew ffmpeg (development only)**

```bash
brew install ffmpeg
ffmpeg -hide_banner -encoders | grep -E ' (libx264|libx265|libvpx-vp9|libsvtav1|h264_videotoolbox|hevc_videotoolbox) '
```

Expected: six lines, one for each encoder named.

- [ ] **Step 2: Write the checker (the test for this task)**

`scripts/check-test-media.py` (then `chmod +x`):

```python
#!/usr/bin/env python3
"""Checks testdata/media against what scripts/make-test-media.sh is meant to produce.

Exits non-zero, naming each problem, if a clip is missing or has the wrong streams.
"""
import json
import pathlib
import shutil
import subprocess
import sys

MEDIA = pathlib.Path(__file__).resolve().parent.parent / "testdata" / "media"

# file -> streams that must be present: (codec types allowed, codec name, channels or None)
EXPECTED = {
    "h264_aac.mp4": [("video", "h264", None), ("audio", "aac", 2)],
    "h264_ac3_51.mkv": [("video", "h264", None), ("audio", "ac3", 6), ("subtitle", "subrip", None)],
    "hevc_eac3_51.mkv": [("video", "hevc", None), ("audio", "eac3", 6)],
    "hevc_hdr10_aac.mkv": [("video", "hevc", None), ("audio", "aac", 2)],
    "vp9_opus.webm": [("video", "vp9", None), ("audio", "opus", 2)],
    "av1_flac_51.mkv": [("video", "av1", None), ("audio", "flac", 6)],
    "mpeg2_dts_51.mkv": [("video", "mpeg2video", None), ("audio", "dts", 6)],
    "h264_flac_71.mkv": [("video", "h264", None), ("audio", "flac", 8)],
    "h264_10bit_aac.mkv": [("video", "h264", None), ("audio", "aac", 2)],
    "h264_noaudio.mkv": [("video", "h264", None)],
    # Matroska exposes image attachments either as an attachment or as an attached-picture video stream.
    "h264_coverart.mkv": [("video", "h264", None), ("video|attachment", "png", None), ("audio", "aac", 2)],
    "h264_multiaudio.mkv": [("video", "h264", None), ("audio", "aac", 2), ("audio", "ac3", 6)],
    "audio_only.m4a": [("audio", "aac", 2)],
    "Movie: Part 1 (Director's Cut) é.mp4": [("video", "h264", None), ("audio", "aac", 2)],
}

# file -> fields the first real video stream must have
VIDEO_FIELDS = {
    "h264_10bit_aac.mkv": {"pix_fmt": "yuv420p10le"},
    "hevc_hdr10_aac.mkv": {"color_transfer": "smpte2084"},
}


def probe(path):
    result = subprocess.run(
        ["ffprobe", "-v", "error", "-print_format", "json", "-show_streams", str(path)],
        capture_output=True, text=True)
    if result.returncode != 0:
        return None
    return json.loads(result.stdout).get("streams", [])


def problems_for(name, expected):
    path = MEDIA / name
    if not path.exists():
        return ["missing (run scripts/make-test-media.sh)"]
    streams = probe(path)
    if streams is None:
        return ["ffprobe could not read it"]
    problems = []
    for types, codec, channels in expected:
        if not any(s.get("codec_type") in types.split("|") and s.get("codec_name") == codec
                   and (channels is None or s.get("channels") == channels) for s in streams):
            wanted = f"{types} {codec}" + (f" with {channels} channels" if channels else "")
            problems.append(f"no {wanted} stream")
    video = next((s for s in streams if s.get("codec_type") == "video"
                  and not s.get("disposition", {}).get("attached_pic")), None)
    for field, value in VIDEO_FIELDS.get(name, {}).items():
        if video is None or video.get(field) != value:
            problems.append(f"video {field} is {video and video.get(field)!r}, expected {value!r}")
    if name == "h264_multiaudio.mkv":
        default = [s.get("codec_name") for s in streams
                   if s.get("codec_type") == "audio" and s.get("disposition", {}).get("default")]
        if default != ["ac3"]:
            problems.append(f"default audio tracks are {default}, expected ['ac3']")
    return problems


def main():
    if shutil.which("ffprobe") is None:
        sys.exit("ffprobe not found: brew install ffmpeg")
    failures = 0
    for name, expected in EXPECTED.items():
        problems = problems_for(name, expected)
        failures += bool(problems)
        print(("ok   " if not problems else "FAIL ") + name + "".join(f"\n       {p}" for p in problems))
    corrupt = MEDIA / "corrupt.mkv"
    if not corrupt.exists() or probe(corrupt) is not None:
        failures += 1
        print("FAIL corrupt.mkv\n       should exist and be unreadable by ffprobe")
    else:
        print("ok   corrupt.mkv")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
```

- [ ] **Step 3: Run it and watch it fail**

Run: `python3 -I scripts/check-test-media.py`
Expected: every line is `FAIL … missing (run scripts/make-test-media.sh)`, and the exit status is 1.

- [ ] **Step 4: Write the generator**

`scripts/make-test-media.sh` (then `chmod +x`):

```bash
#!/usr/bin/env bash
# Generates ~10-second test clips covering every input row of the spec's conversion table
# (§4.1) into testdata/media/. Development only: uses Homebrew's ffmpeg (brew install ffmpeg).
# A clip whose encoder is missing is skipped with a warning; tests needing it then fail
# loudly in scripts/check-test-media.py rather than silently.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=testdata/media
mkdir -p "$OUT"
DUR=10
SKIPPED=()

VIDEO="testsrc=size=1280x720:rate=30:duration=$DUR"
STEREO="sine=frequency=440:sample_rate=48000:duration=$DUR"
TONES51="0.2*sin(330*2*PI*t)|0.2*sin(440*2*PI*t)|0.2*sin(550*2*PI*t)|0.2*sin(60*2*PI*t)|0.2*sin(660*2*PI*t)|0.2*sin(770*2*PI*t)"
SURROUND51="aevalsrc=$TONES51:s=48000:d=$DUR:c=5.1"
SURROUND71="aevalsrc=$TONES51|0.2*sin(880*2*PI*t)|0.2*sin(990*2*PI*t):s=48000:d=$DUR:c=7.1"
X264=(-c:v libx264 -preset veryfast -pix_fmt yuv420p -g 30)
HDR10_PARAMS="log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc"
HDR10_PARAMS+=":master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400"

clip() { # clip <output file> <ffmpeg arguments...>
  local file=$1
  shift
  if ffmpeg -hide_banner -loglevel error -y "$@" "$OUT/$file"; then
    echo "made    $file"
  else
    echo "SKIPPED $file (ffmpeg failed; see the error above)" >&2
    rm -f "$OUT/$file"
    SKIPPED+=("$file")
  fi
}

cat > "$OUT/sample.srt" <<'EOF'
1
00:00:01,000 --> 00:00:04,000
Paper Plane test subtitle one

2
00:00:05,000 --> 00:00:08,000
Paper Plane test subtitle two
EOF
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=red:s=300x300" -frames:v 1 "$OUT/cover.png"

clip h264_aac.mp4 -f lavfi -i "$VIDEO" -f lavfi -i "$STEREO" "${X264[@]}" -c:a aac -b:a 128k -ac 2
clip h264_ac3_51.mkv -f lavfi -i "$VIDEO" -f lavfi -i "$SURROUND51" -i "$OUT/sample.srt" \
  -map 0:v -map 1:a -map 2:s "${X264[@]}" -c:a ac3 -b:a 448k -c:s srt
clip hevc_eac3_51.mkv -f lavfi -i "$VIDEO" -f lavfi -i "$SURROUND51" \
  -c:v libx265 -preset ultrafast -x265-params log-level=error -pix_fmt yuv420p -g 30 -c:a eac3 -b:a 640k
clip hevc_hdr10_aac.mkv -f lavfi -i "$VIDEO" -f lavfi -i "$STEREO" \
  -c:v libx265 -preset ultrafast -pix_fmt yuv420p10le -g 30 -x265-params "$HDR10_PARAMS" \
  -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc -c:a aac -b:a 128k -ac 2
clip vp9_opus.webm -f lavfi -i "$VIDEO" -f lavfi -i "$STEREO" \
  -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -b:v 1M -c:a libopus -b:a 96k -ac 2
clip av1_flac_51.mkv -f lavfi -i "$VIDEO" -f lavfi -i "$SURROUND51" \
  -c:v libsvtav1 -preset 12 -crf 45 -pix_fmt yuv420p -c:a flac
clip mpeg2_dts_51.mkv -f lavfi -i "$VIDEO" -f lavfi -i "$SURROUND51" \
  -c:v mpeg2video -q:v 5 -af "aformat=channel_layouts=5.1(side)" -c:a dca -strict -2
clip h264_flac_71.mkv -f lavfi -i "$VIDEO" -f lavfi -i "$SURROUND71" "${X264[@]}" -c:a flac
clip h264_10bit_aac.mkv -f lavfi -i "$VIDEO" -f lavfi -i "$STEREO" \
  -c:v libx264 -preset veryfast -pix_fmt yuv420p10le -profile:v high10 -g 30 -c:a aac -b:a 128k -ac 2
clip h264_noaudio.mkv -f lavfi -i "$VIDEO" "${X264[@]}"
clip h264_coverart.mkv -f lavfi -i "$VIDEO" -f lavfi -i "$STEREO" "${X264[@]}" -c:a aac -b:a 128k -ac 2 \
  -attach "$OUT/cover.png" -metadata:s:t mimetype=image/png
clip h264_multiaudio.mkv -f lavfi -i "$VIDEO" -f lavfi -i "$STEREO" -f lavfi -i "$SURROUND51" \
  -map 0:v -map 1:a -map 2:a "${X264[@]}" \
  -c:a:0 aac -b:a:0 128k -ac:a:0 2 -c:a:1 ac3 -b:a:1 448k \
  -metadata:s:a:0 language=eng -metadata:s:a:1 language=jpn -disposition:a:0 0 -disposition:a:1 default
clip audio_only.m4a -f lavfi -i "$STEREO" -c:a aac -b:a 128k -ac 2

printf 'This is not a video file.\n' > "$OUT/corrupt.mkv"
echo "made    corrupt.mkv"
if [[ -f "$OUT/h264_aac.mp4" ]]; then
  cp "$OUT/h264_aac.mp4" "$OUT/Movie: Part 1 (Director's Cut) é.mp4"
  echo "made    Movie: Part 1 (Director's Cut) é.mp4"
fi

if ((${#SKIPPED[@]})); then
  echo "Skipped ${#SKIPPED[@]} clip(s): ${SKIPPED[*]}" >&2
  exit 1
fi
echo "All test media in $OUT"
```

- [ ] **Step 5: Generate and check**

Run: `scripts/make-test-media.sh && python3 -I scripts/check-test-media.py`
Expected:
- The generator ends with `All test media in testdata/media`.
- The checker prints `ok` for all 15 entries and exits 0.

If only `mpeg2_dts_51.mkv` is skipped and the error mentions the channel layout, change that clip's `-af` value to `aformat=channel_layouts=5.1` and rerun. If any other clip is skipped, stop and report the ffmpeg error to the owner. Don't weaken the checker.

- [ ] **Step 6: Write the HLS dev server**

`scripts/serve-hls.py` (then `chmod +x`):

```python
#!/usr/bin/env python3
"""Serve a folder over HTTP with correct HLS MIME types.

Development and test helper (the Sony test and the pipeline tests use it); the app
has its own server. Prints "PORT <n>" once listening, so callers can pass --port 0.
"""
import argparse
import functools
import http.server

HLS_TYPES = {
    ".m3u8": "application/vnd.apple.mpegurl",
    ".m4s": "video/iso.segment",
    ".mp4": "video/mp4",
    ".ts": "video/mp2t",
    ".vtt": "text/vtt",
}


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map, **HLS_TYPES}

    def log_message(self, format, *args):
        if self.server.verbose:
            super().log_message(format, *args)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory")
    parser.add_argument("--bind", default="127.0.0.1", help="use 0.0.0.0 so a TV can connect")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--verbose", action="store_true", help="log every request")
    options = parser.parse_args()

    handler = functools.partial(Handler, directory=options.directory)
    server = http.server.ThreadingHTTPServer((options.bind, options.port), handler)
    server.verbose = options.verbose
    print(f"PORT {server.server_address[1]}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
```

- [ ] **Step 7: Check the server's content types**

```bash
D=$(mktemp -d); printf '#EXTM3U\n' > "$D/index.m3u8"; printf 'x' > "$D/seg_00000.m4s"; printf 'WEBVTT\n' > "$D/subs.vtt"
python3 scripts/serve-hls.py "$D" > "$D.log" & SERVER=$!
until grep -q PORT "$D.log"; do :; done; PORT=$(awk '/^PORT/{print $2}' "$D.log")
for f in index.m3u8 seg_00000.m4s subs.vtt missing.m3u8; do curl -s -o /dev/null -w "$f %{http_code} %{content_type}\n" "http://127.0.0.1:$PORT/$f"; done
kill $SERVER
```

Expected:

```
index.m3u8 200 application/vnd.apple.mpegurl
seg_00000.m4s 200 video/iso.segment
subs.vtt 200 text/vtt
missing.m3u8 404 text/html;charset=utf-8
```

- [ ] **Step 8: Commit**

```bash
git add scripts/check-test-media.py scripts/make-test-media.sh scripts/serve-hls.py
git commit -m "test: generated test media, media checker and HLS dev server" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Sony test (Milestone 0)

This task needs the owner at the Sony for Step 6. Steps 1–5 can be done without them. Tasks 4–8 don't depend on this task, so if the owner isn't available, continue with Task 4 and come back.

**Files:**
- Create: `spikes/sony-test/main.swift`, `spikes/sony-test/Info.plist`, `spikes/sony-test/build.sh`, `spikes/sony-test/make-streams.sh`, `spikes/sony-test/start-live.sh`
- Create: `docs/sony-test-results.md`

**Interfaces:**
- Consumes: `scripts/serve-hls.py` (Task 2), Homebrew ffmpeg.
- Produces: a completed `docs/sony-test-results.md` (the Results table). Task 9 turns it into decisions.

- [ ] **Step 1: Write the spike app**

`spikes/sony-test/main.swift`:

```swift
// Throwaway Milestone 0 spike: play test HLS streams from this Mac on an AirPlay TV and
// show what the player reports. Not shipped; see docs/sony-test-results.md.
//
// Usage: build/SonyTest.app/Contents/MacOS/SonyTest http://<mac-lan-ip>:8642

import AppKit
import AVFoundation
import AVKit

let streams: [(name: String, path: String)] = [
    ("1 Baseline H.264 + AAC", "baseline/index.m3u8"),
    ("2 HEVC + AAC", "hevc/index.m3u8"),
    ("3 H.264 + AC3 5.1", "ac3/index.m3u8"),
    ("4 H.264 + E-AC3 5.1", "eac3/index.m3u8"),
    ("5 WebVTT subtitles", "webvtt/master.m3u8"),
    ("6 HDR10 HEVC (4K)", "hdr10/index.m3u8"),
    ("7 Live (growing EVENT playlist)", "live/index.m3u8"),
]

@MainActor
final class Controller: NSObject, NSApplicationDelegate {
    let baseURL: URL
    let player = AVPlayer()
    let streamPicker = NSPopUpButton()
    let status = NSTextField(wrappingLabelWithString: "")
    var window: NSWindow?
    var timer: Timer?

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        player.allowsExternalPlayback = true
        let routePicker = AVRoutePickerView()
        routePicker.player = player  // On macOS this is what makes video (not just audio) AirPlay devices appear.

        streams.forEach { streamPicker.addItem(withTitle: $0.name) }
        let loadRow = NSStackView(views: [streamPicker, button("Load", #selector(load)), routePicker])
        let controlRow = NSStackView(views: [
            button("Play", #selector(play)), button("Pause", #selector(pause)),
            button("Seek to start", #selector(seekToStart)), button("−30 s", #selector(back30)),
            button("+30 s", #selector(forward30)), button("+5 min", #selector(forward5min)),
            button("Subtitles on/off", #selector(toggleSubtitles)),
        ])
        status.font = .monospacedSystemFont(ofSize: 12, weight: .regular)

        let stack = NSStackView(views: [loadRow, controlRow, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 240),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Sony Test"
        window.contentView = stack
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    @objc func load() {
        let url = baseURL.appendingPathComponent(streams[streamPicker.indexOfSelectedItem].path)
        print("Loading \(url.absoluteString)")
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()
    }

    @objc func play() { player.play() }
    @objc func pause() { player.pause() }
    @objc func back30() { skip(by: -30) }
    @objc func forward30() { skip(by: 30) }
    @objc func forward5min() { skip(by: 300) }

    @objc func seekToStart() {
        player.seek(to: .zero) { finished in print("Seek to start finished: \(finished)") }
    }

    private func skip(by seconds: Double) {
        let target = CMTimeAdd(player.currentTime(), CMTime(seconds: seconds, preferredTimescale: 600))
        player.seek(to: target) { finished in print("Skip \(seconds) s finished: \(finished)") }
    }

    @objc func toggleSubtitles() {
        guard let item = player.currentItem else { return }
        Task { @MainActor in
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else {
                print("This stream has no subtitle tracks")
                return
            }
            let isOn = item.currentMediaSelection.selectedMediaOption(in: group) != nil
            let next = isOn ? nil : group.options.first
            item.select(next, in: group)
            print("Subtitles: \(next?.displayName ?? "off")")
        }
    }

    private func refresh() {
        let item = player.currentItem
        let duration = item?.duration.seconds ?? .nan
        let seekable = item?.seekableTimeRanges
            .map { String(format: "%.0f–%.0f s", $0.timeRangeValue.start.seconds, $0.timeRangeValue.end.seconds) }
            .joined(separator: ", ") ?? "–"
        status.stringValue = [
            String(format: "Time %.1f s    Duration %@", player.currentTime().seconds,
                   duration.isFinite ? String(format: "%.1f s", duration) : "indefinite (live)"),
            "Seekable: \(seekable)",
            "On TV (isExternalPlaybackActive): \(player.isExternalPlaybackActive ? "YES" : "no")",
            "Item: \(describe(item?.status))    Rate: \(player.rate)",
            "Error: \(item?.error?.localizedDescription ?? "none")",
        ].joined(separator: "\n")
    }

    private func describe(_ status: AVPlayerItem.Status?) -> String {
        switch status {
        case .readyToPlay: "ready"
        case .failed: "FAILED"
        case .unknown: "loading"
        case nil: "nothing loaded"
        @unknown default: "unknown"
        }
    }
}

guard CommandLine.arguments.count == 2, let baseURL = URL(string: CommandLine.arguments[1]) else {
    print("Usage: SonyTest http://<mac-lan-ip>:8642")
    exit(2)
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = Controller(baseURL: baseURL)  // app.delegate is weak; this keeps it alive
    app.delegate = controller
    app.setActivationPolicy(.regular)
    app.run()
}
```

`spikes/sony-test/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>dev.paperplane.spike.sonytest</string>
    <key>CFBundleName</key>
    <string>SonyTest</string>
    <key>CFBundleExecutable</key>
    <string>SonyTest</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.0.1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Sony Test streams test video from this Mac to your TV.</string>
</dict>
</plist>
```

`spikes/sony-test/build.sh` (then `chmod +x`):

```bash
#!/usr/bin/env bash
# Builds the throwaway Sony test app with the Command Line Tools (no Xcode needed).
set -euo pipefail
cd "$(dirname "$0")"
APP=build/SonyTest.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -swift-version 5 -O -target arm64-apple-macos14.0 main.swift -o "$APP/Contents/MacOS/SonyTest"
codesign --force --sign - "$APP"
echo "Built $APP"
```

- [ ] **Step 2: Build it**

Run: `spikes/sony-test/build.sh && spikes/sony-test/build/SonyTest.app/Contents/MacOS/SonyTest; echo "exit=$?"`
Expected: `Built build/SonyTest.app`, then `Usage: SonyTest http://<mac-lan-ip>:8642` and `exit=2`.

- [ ] **Step 3: Write the stream builders**

`spikes/sony-test/make-streams.sh` (then `chmod +x`):

```bash
#!/usr/bin/env bash
# Builds the HLS test streams for the Sony test (Milestone 0) into spikes/sony-test/streams/.
# Throwaway. The 4K HDR stream takes a few minutes to encode.
set -euo pipefail
cd "$(dirname "$0")"
OUT=streams
DUR=120
rm -rf "$OUT/baseline" "$OUT/hevc" "$OUT/ac3" "$OUT/eac3" "$OUT/webvtt" "$OUT/hdr10"
mkdir -p "$OUT"

VIDEO=(-f lavfi -i "testsrc=size=1920x1080:rate=30:duration=$DUR")
STEREO=(-f lavfi -i "sine=frequency=440:sample_rate=48000:duration=$DUR")
TONES="0.3*sin(330*2*PI*t)|0.3*sin(440*2*PI*t)|0.3*sin(550*2*PI*t)|0.3*sin(60*2*PI*t)|0.3*sin(660*2*PI*t)|0.3*sin(770*2*PI*t)"
SURROUND=(-f lavfi -i "aevalsrc=$TONES:s=48000:d=$DUR:c=5.1")
X264=(-c:v libx264 -preset veryfast -pix_fmt yuv420p -g 60)
AAC=(-c:a aac -b:a 128k -ac 2)
HDR10_PARAMS="log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc"
HDR10_PARAMS+=":master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400"

hls() { # hls <name> <ffmpeg input and codec arguments...> → streams/<name>/index.m3u8 (fMP4, VOD)
  local name=$1
  shift
  mkdir -p "$OUT/$name"
  echo "== $name"
  ffmpeg -hide_banner -loglevel error -y "$@" \
    -f hls -hls_time 6 -hls_playlist_type vod -hls_segment_type fmp4 -hls_flags independent_segments \
    -hls_segment_filename "$OUT/$name/seg_%05d.m4s" "$OUT/$name/index.m3u8"
}

hls baseline "${VIDEO[@]}" "${STEREO[@]}" "${X264[@]}" "${AAC[@]}"
hls hevc "${VIDEO[@]}" "${STEREO[@]}" -c:v libx265 -preset ultrafast -x265-params log-level=error \
  -tag:v hvc1 -pix_fmt yuv420p -g 60 "${AAC[@]}"
hls ac3 "${VIDEO[@]}" "${SURROUND[@]}" "${X264[@]}" -c:a ac3 -b:a 448k
hls eac3 "${VIDEO[@]}" "${SURROUND[@]}" "${X264[@]}" -c:a eac3 -b:a 640k
hls hdr10 -f lavfi -i "testsrc2=size=3840x2160:rate=30:duration=$DUR" "${STEREO[@]}" \
  -c:v libx265 -preset ultrafast -tag:v hvc1 -pix_fmt yuv420p10le -g 60 -x265-params "$HDR10_PARAMS" \
  -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc "${AAC[@]}"

# WebVTT: H.264/AAC in MPEG-TS segments plus a hand-written subtitle playlist and master playlist.
# This checks whether the TV draws subtitles at all; exact cue timing isn't what's being tested.
echo "== webvtt"
mkdir -p "$OUT/webvtt"
ffmpeg -hide_banner -loglevel error -y "${VIDEO[@]}" "${STEREO[@]}" "${X264[@]}" "${AAC[@]}" \
  -muxdelay 0 -muxpreload 0 \
  -f hls -hls_time 6 -hls_playlist_type vod -hls_segment_type mpegts \
  -hls_segment_filename "$OUT/webvtt/seg_%05d.ts" "$OUT/webvtt/av.m3u8"
{
  echo "WEBVTT"
  echo "X-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000"
  echo
  for ((s = 0; s < DUR; s += 5)); do
    printf '00:%02d:%02d.000 --> 00:%02d:%02d.000\nSubtitle at %d seconds\n\n' \
      $((s / 60)) $((s % 60)) $(((s + 4) / 60)) $(((s + 4) % 60)) "$s"
  done
} > "$OUT/webvtt/subs.vtt"
cat > "$OUT/webvtt/subs.m3u8" <<EOF
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:$DUR
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:$DUR.0,
subs.vtt
#EXT-X-ENDLIST
EOF
cat > "$OUT/webvtt/master.m3u8" <<'EOF'
#EXTM3U
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,URI="subs.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2",SUBTITLES="subs"
av.m3u8
EOF

echo "Streams ready in spikes/sony-test/$OUT"
```

`spikes/sony-test/start-live.sh` (then `chmod +x`):

```bash
#!/usr/bin/env bash
# Writes a 10-minute live-growing EVENT playlist in real time into spikes/sony-test/streams/live/
# (Sony test 7). Throwaway. Leave it running while testing; Ctrl-C to stop.
set -euo pipefail
cd "$(dirname "$0")"
OUT=streams/live
rm -rf "$OUT"
mkdir -p "$OUT"
echo "Writing $OUT/index.m3u8 in real time for 10 minutes…"
exec ffmpeg -hide_banner -loglevel error \
  -re -f lavfi -i "testsrc=size=1920x1080:rate=30:duration=600" \
  -re -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=600" \
  -c:v libx264 -preset veryfast -pix_fmt yuv420p -g 60 -c:a aac -b:a 128k -ac 2 \
  -f hls -hls_time 6 -hls_playlist_type event -hls_segment_type fmp4 \
  -hls_flags independent_segments+temp_file \
  -hls_segment_filename "$OUT/seg_%05d.m4s" "$OUT/index.m3u8"
```

- [ ] **Step 4: Build the streams and check them on the Mac first**

Run: `spikes/sony-test/make-streams.sh && ls spikes/sony-test/streams && grep -c TYPE=SUBTITLES spikes/sony-test/streams/webvtt/master.m3u8`
Expected: `Streams ready in spikes/sony-test/streams`, the folders `ac3 baseline eac3 hdr10 hevc webvtt`, and `1`.

Then confirm each stream loads before involving the TV:
1. Start `python3 scripts/serve-hls.py spikes/sony-test/streams --bind 0.0.0.0 --port 8642` in a background terminal.
2. Run `spikes/sony-test/build/SonyTest.app/Contents/MacOS/SonyTest "http://$(ipconfig getifaddr en0):8642"`.
3. Load streams 1–6 one at a time.

Expected for each stream: `Item: ready`, `Time` advancing and `Error: none`. Nothing appears on screen, because the spike has no video view. That's normal.

- [ ] **Step 5: Write the results sheet**

`docs/sony-test-results.md`:

```markdown
# Sony Test Results (Milestone 0)

Answers the open questions in the design spec (§4.1 output profile, §8 Milestone 0, §10 risks) before
any product playback code is written.

**Date:**
**TV model:**
**macOS version:**
**Mac's LAN IP during the test:**   **TV's LAN IP (from the server log):**

## How to run

1. `spikes/sony-test/make-streams.sh` (once; the 4K HDR stream takes a few minutes).
2. Terminal A: `python3 scripts/serve-hls.py spikes/sony-test/streams --bind 0.0.0.0 --port 8642 --verbose`
3. Terminal B: `spikes/sony-test/start-live.sh` (start it about 2 minutes before test 7).
4. Terminal C: `spikes/sony-test/build.sh && spikes/sony-test/build/SonyTest.app/Contents/MacOS/SonyTest "http://$(ipconfig getifaddr en0):8642"`
5. Allow any macOS prompts (incoming connections for python3, local network for SonyTest).
6. Click the AirPlay button in the Sony Test window and pick the Sony, then work through the table.
   Terminal A logs every request with the requester's IP.

## Results

| # | Stream / check | What to look for | Result |
|---|---|---|---|
| 0 | Who fetches the stream | While stream 1 plays on the TV, do the segment requests in Terminal A come from the TV's IP or the Mac's? | |
| 1 | Baseline H.264 + AAC | Plays smoothly with sound; −30 s / +30 s seeks work | |
| 2 | HEVC + AAC | Plays | |
| 3 | H.264 + AC3 5.1 | Plays with sound. Does the TV (or soundbar) show Dolby Digital / 5.1, or plain stereo? | |
| 4 | H.264 + E-AC3 5.1 | Same as 3 (Dolby Digital Plus) | |
| 5 | WebVTT subtitles | "Subtitle at N seconds" text appears on the TV; Subtitles on/off toggles it | |
| 6 | HDR10 HEVC (4K) | Plays; the TV shows its HDR indicator; colours look normal | |
| 7a | Live: start position | Load stream 7 about 2 min after starting `start-live.sh`. Does playback begin at 0 s or near the live edge? | |
| 7b | Live: seek to start | Does "Seek to start" go back to 0 s? | |
| 7c | Live: seeking within | Do −30 s / +30 s work inside the produced part? | |
| 7d | Live: growth | Does playback carry on smoothly as new segments appear? | |
| 8 | TV selected before play | With nothing loaded, pick the Sony in the AirPlay menu. Does "On TV" switch to YES before you press Load? | |
| 9 | Reconnect without picker | Quit Sony Test, relaunch, press Load without touching the AirPlay menu. Does it play on the TV? | |

## Decisions

Filled in by Plan 1 Task 9 from the results above.

- `OutputProfile.default.surround`:
- `OutputProfile.default.hdr`:
- Subtitle approach for Plan 3 (WebVTT track or always burn in):
- Live-playlist start (for Plan 2: rely on AVPlayer, seek to 0 after load, or write our own playlist with `#EXT-X-START`):
- Stream server binding (for Plan 2: LAN address required, or localhost enough):
- TV selection UX (for Plan 2):
```

- [ ] **Step 6: Run the test with the owner at the TV**

1. Ask the owner to be at the Sony with this Mac on the same Wi-Fi.
2. Start the three terminals from "How to run" in the results sheet (server, live stream, app). Use `--verbose` on the server.
3. Go through rows 0–9 with the owner. They report what the TV shows; you read the server log for row 0 and the app's status lines.
4. Record each answer in the Results column in plain words, for example `Plays; TV shows "Dolby Digital 5.1"`. Fill in the header fields (date, TV model, macOS version, IPs).
5. Leave the Decisions section for Task 9.

- [ ] **Step 7: Commit**

```bash
git add spikes/sony-test/main.swift spikes/sony-test/Info.plist spikes/sony-test/build.sh spikes/sony-test/make-streams.sh spikes/sony-test/start-live.sh docs/sony-test-results.md
git commit -m "spike: Sony AirPlay test app, test streams and results" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: `MediaInfo` and the ffprobe parser

**Files:**
- Create: `core/Sources/PaperPlaneCore/Media/MediaInfo.swift`, `core/Sources/PaperPlaneCore/Media/FFprobeParser.swift`
- Test: `core/Tests/PaperPlaneCoreTests/FFprobeParserTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `TrackRef(input: Int = 0, index: Int)`, which is `Hashable`, with `mapSpecifier: String` (`"input:index"`).
  - `VideoCodecName` (`.h264`, `.hevc`, `.other(String)`), which is `Hashable`, with `init(ffprobeName:)`.
  - `AudioCodecName` (`.aac`, `.ac3`, `.eac3`, `.other(String)`) with `init(ffprobeName:)`. Not called `AudioCodec`, which clashes with Apple's AudioToolbox.
  - `HDRFormat` (`.pq`, `.hlg`) with `init?(colorTransfer:)`.
  - `SubtitleKind` (`.text`, `.picture`, `.unsupported`) with `init(ffprobeName:)`.
  - `VideoTrack { ref, codec: VideoCodecName, width, height, pixelFormat: String?, hdr: HDRFormat? }`.
  - `AudioTrack { ref, codec: AudioCodecName, channels, language: String?, title: String?, isDefault }`.
  - `SubtitleTrack { ref, codecName, kind, language, title, isDefault, isForced }`.
  - `MediaInfo { duration: Double?, video, audio, subtitles }` with `static func merging(_:) -> MediaInfo`.
  - `public enum MediaProbeError: Error, Equatable { case noInputs, unreadableOutput, ffprobeFailed(status: Int32, message: String) }`.
  - `enum FFprobeParser { static func parse(_ data: Data, input: Int = 0) throws -> MediaInfo }`.

- [ ] **Step 1: Write the failing tests**

`core/Tests/PaperPlaneCoreTests/FFprobeParserTests.swift`:

```swift
import Foundation
import Testing
@testable import PaperPlaneCore

struct FFprobeParserTests {
    /// Trimmed real-world shape: cover art first, two audio tracks, text + picture subtitles, a font attachment.
    static let movieJSON = """
    {
      "streams": [
        {"index": 0, "codec_name": "png", "codec_type": "video", "width": 300, "height": 300, "pix_fmt": "rgb24",
         "disposition": {"default": 0, "forced": 0, "attached_pic": 1}},
        {"index": 1, "codec_name": "h264", "codec_type": "video", "width": 1920, "height": 1080, "pix_fmt": "yuv420p",
         "color_transfer": "bt709", "disposition": {"default": 1, "forced": 0, "attached_pic": 0}},
        {"index": 2, "codec_name": "ac3", "codec_type": "audio", "channels": 6,
         "disposition": {"default": 0, "forced": 0, "attached_pic": 0}, "tags": {"language": "eng", "title": "Surround"}},
        {"index": 3, "codec_name": "aac", "codec_type": "audio", "channels": 2,
         "disposition": {"default": 1, "forced": 0, "attached_pic": 0}, "tags": {"language": "jpn"}},
        {"index": 4, "codec_name": "subrip", "codec_type": "subtitle",
         "disposition": {"default": 0, "forced": 1, "attached_pic": 0}, "tags": {"language": "und"}},
        {"index": 5, "codec_name": "hdmv_pgs_subtitle", "codec_type": "subtitle",
         "disposition": {"default": 0, "forced": 0, "attached_pic": 0}, "tags": {"LANGUAGE": "fre"}},
        {"index": 6, "codec_name": "ttf", "codec_type": "attachment", "tags": {"filename": "font.ttf"}}
      ],
      "format": {"filename": "movie.mkv", "duration": "5423.104000"}
    }
    """

    @Test func parsesTracksAndSkipsCoverArt() throws {
        let info = try FFprobeParser.parse(Data(Self.movieJSON.utf8))
        #expect(info.duration == 5423.104)
        #expect(info.video == [
            VideoTrack(ref: TrackRef(index: 1), codec: .h264, width: 1920, height: 1080, pixelFormat: "yuv420p", hdr: nil),
        ])
        #expect(info.audio == [
            AudioTrack(ref: TrackRef(index: 2), codec: .ac3, channels: 6, language: "eng", title: "Surround", isDefault: false),
            AudioTrack(ref: TrackRef(index: 3), codec: .aac, channels: 2, language: "jpn", title: nil, isDefault: true),
        ])
        #expect(info.subtitles == [
            SubtitleTrack(ref: TrackRef(index: 4), codecName: "subrip", kind: .text, language: nil, title: nil,
                          isDefault: false, isForced: true),
            SubtitleTrack(ref: TrackRef(index: 5), codecName: "hdmv_pgs_subtitle", kind: .picture, language: "fre",
                          title: nil, isDefault: false, isForced: false),
        ])
    }

    @Test func recordsInputPositionInRefs() throws {
        let info = try FFprobeParser.parse(Data(Self.movieJSON.utf8), input: 1)
        #expect(info.video.first?.ref == TrackRef(input: 1, index: 1))
        #expect(info.video.first?.ref.mapSpecifier == "1:1")
    }

    @Test func detectsHDR() throws {
        let json = """
        {"streams": [
          {"index": 0, "codec_name": "hevc", "codec_type": "video", "width": 3840, "height": 2160,
           "pix_fmt": "yuv420p10le", "color_transfer": "smpte2084"},
          {"index": 1, "codec_name": "hevc", "codec_type": "video", "width": 3840, "height": 2160,
           "pix_fmt": "yuv420p10le", "color_transfer": "arib-std-b67"}
        ], "format": {"duration": "60.0"}}
        """
        let info = try FFprobeParser.parse(Data(json.utf8))
        #expect(info.video.map(\.hdr) == [.pq, .hlg])
        #expect(info.video.first?.codec == .hevc)
    }

    @Test func missingOrInvalidDurationIsNil() throws {
        let live = try FFprobeParser.parse(Data(#"{"streams": [], "format": {"duration": "N/A"}}"#.utf8))
        #expect(live.duration == nil)
        let none = try FFprobeParser.parse(Data(#"{"streams": []}"#.utf8))
        #expect(none.duration == nil)
    }

    @Test func unknownCodecsAreKeptAsOther() throws {
        let json = """
        {"streams": [
          {"index": 0, "codec_name": "vp9", "codec_type": "video", "width": 1280, "height": 720},
          {"index": 1, "codec_name": "dts", "codec_type": "audio", "channels": 6},
          {"index": 2, "codec_name": "eia_608", "codec_type": "subtitle"}
        ]}
        """
        let info = try FFprobeParser.parse(Data(json.utf8))
        #expect(info.video.first?.codec == .other("vp9"))
        #expect(info.audio.first?.codec == .other("dts"))
        #expect(info.subtitles.first?.kind == .unsupported)
    }

    @Test func garbageThrowsUnreadableOutput() {
        #expect(throws: MediaProbeError.unreadableOutput) {
            try FFprobeParser.parse(Data("not json".utf8))
        }
    }

    @Test func mergingCombinesInputsAndTakesFirstKnownDuration() {
        let video = MediaInfo(duration: nil, video: [
            VideoTrack(ref: TrackRef(input: 0, index: 0), codec: .h264, width: 1920, height: 1080,
                       pixelFormat: "yuv420p", hdr: nil),
        ], audio: [], subtitles: [])
        let audio = MediaInfo(duration: 212.5, video: [], audio: [
            AudioTrack(ref: TrackRef(input: 1, index: 0), codec: .aac, channels: 2, language: nil, title: nil,
                       isDefault: true),
        ], subtitles: [])
        let merged = MediaInfo.merging([video, audio])
        #expect(merged.duration == 212.5)
        #expect(merged.video == video.video)
        #expect(merged.audio == audio.audio)
    }
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `scripts/test-core.sh --filter FFprobeParserTests`
Expected: the build fails with `cannot find 'FFprobeParser' in scope` (and similar for `VideoTrack`, `MediaInfo`).

- [ ] **Step 3: Implement the model**

`core/Sources/PaperPlaneCore/Media/MediaInfo.swift`:

```swift
import Foundation

/// Points at one stream: which ffmpeg input it's in, and ffprobe's index within that input.
public struct TrackRef: Hashable, Sendable {
    /// Position of the ffmpeg input (0 unless a web video has separate audio).
    public var input: Int = 0
    /// ffprobe's stream index within that input.
    public var index: Int

    /// The value for ffmpeg's `-map`.
    public var mapSpecifier: String { "\(input):\(index)" }
}

public enum VideoCodecName: Hashable, Sendable {
    case h264
    case hevc
    case other(String)

    public init(ffprobeName: String) {
        switch ffprobeName {
        case "h264": self = .h264
        case "hevc": self = .hevc
        default: self = .other(ffprobeName)
        }
    }
}

public enum HDRFormat: Equatable, Sendable {
    /// HDR10 / Dolby Vision base layer (SMPTE ST 2084).
    case pq
    /// Hybrid Log-Gamma.
    case hlg

    public init?(colorTransfer: String?) {
        switch colorTransfer ?? "" {
        case "smpte2084": self = .pq
        case "arib-std-b67": self = .hlg
        default: return nil
        }
    }
}

public enum AudioCodecName: Equatable, Sendable {
    case aac
    case ac3
    case eac3
    case other(String)

    public init(ffprobeName: String) {
        switch ffprobeName {
        case "aac": self = .aac
        case "ac3": self = .ac3
        case "eac3": self = .eac3
        default: self = .other(ffprobeName)
        }
    }
}

public enum SubtitleKind: Equatable, Sendable {
    case text
    case picture
    case unsupported

    public init(ffprobeName: String) {
        switch ffprobeName {
        case "subrip", "srt", "ass", "ssa", "mov_text", "webvtt", "text": self = .text
        case "hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "xsub": self = .picture
        default: self = .unsupported
        }
    }
}

public struct VideoTrack: Equatable, Sendable {
    public var ref: TrackRef
    public var codec: VideoCodecName
    public var width: Int
    public var height: Int
    /// ffprobe's `pix_fmt`, e.g. `yuv420p` or `yuv420p10le`.
    public var pixelFormat: String?
    public var hdr: HDRFormat?
}

public struct AudioTrack: Equatable, Sendable {
    public var ref: TrackRef
    public var codec: AudioCodecName
    public var channels: Int
    public var language: String?
    public var title: String?
    public var isDefault: Bool
}

public struct SubtitleTrack: Equatable, Sendable {
    public var ref: TrackRef
    public var codecName: String
    public var kind: SubtitleKind
    public var language: String?
    public var title: String?
    public var isDefault: Bool
    public var isForced: Bool
}

/// What Paper Plane knows about a video after probing it.
public struct MediaInfo: Equatable, Sendable {
    /// Seconds, or nil when unknown (live streams).
    public var duration: Double?
    /// Real video tracks only. Cover art (attached pictures) is left out.
    public var video: [VideoTrack]
    public var audio: [AudioTrack]
    public var subtitles: [SubtitleTrack]

    /// Combines probes of several inputs (for example separate web video and audio streams).
    static func merging(_ parts: [MediaInfo]) -> MediaInfo {
        MediaInfo(
            duration: parts.lazy.compactMap(\.duration).first,
            video: parts.flatMap(\.video),
            audio: parts.flatMap(\.audio),
            subtitles: parts.flatMap(\.subtitles))
    }
}
```

- [ ] **Step 4: Implement the parser**

`core/Sources/PaperPlaneCore/Media/FFprobeParser.swift`:

```swift
import Foundation

public enum MediaProbeError: Error, Equatable {
    /// A ResolvedInput with no inputs was probed.
    case noInputs
    /// ffprobe's output wasn't the JSON we asked for.
    case unreadableOutput
    /// ffprobe exited with an error. `message` is redacted (no URL queries).
    case ffprobeFailed(status: Int32, message: String)
}

/// Turns `ffprobe -print_format json -show_format -show_streams` output into a MediaInfo.
enum FFprobeParser {
    private struct Output: Decodable {
        struct Stream: Decodable {
            var index: Int
            var codecType: String?
            var codecName: String?
            var width: Int?
            var height: Int?
            var pixFmt: String?
            var channels: Int?
            var colorTransfer: String?
            var disposition: [String: Int]?
            var tags: [String: String]?

            enum CodingKeys: String, CodingKey {
                case index, width, height, channels, disposition, tags
                case codecType = "codec_type"
                case codecName = "codec_name"
                case pixFmt = "pix_fmt"
                case colorTransfer = "color_transfer"
            }

            /// Tag lookup that ignores case (MKV files sometimes use `LANGUAGE`).
            func tag(_ name: String) -> String? {
                tags?.first(where: { $0.key.lowercased() == name })?.value
            }

            func flag(_ name: String) -> Bool { disposition?[name] == 1 }
        }

        struct Format: Decodable {
            var duration: String?
        }

        var streams: [Stream]?
        var format: Format?
    }

    /// `input` is the ffmpeg input position, recorded in each track's ref.
    static func parse(_ data: Data, input: Int = 0) throws -> MediaInfo {
        let output: Output
        do {
            output = try JSONDecoder().decode(Output.self, from: data)
        } catch {
            throw MediaProbeError.unreadableOutput
        }

        var info = MediaInfo(duration: duration(output.format?.duration), video: [], audio: [], subtitles: [])
        for stream in output.streams ?? [] {
            let ref = TrackRef(input: input, index: stream.index)
            let codec = stream.codecName ?? "unknown"
            switch stream.codecType ?? "" {
            case "video" where !stream.flag("attached_pic"):
                info.video.append(VideoTrack(
                    ref: ref,
                    codec: VideoCodecName(ffprobeName: codec),
                    width: stream.width ?? 0,
                    height: stream.height ?? 0,
                    pixelFormat: stream.pixFmt,
                    hdr: HDRFormat(colorTransfer: stream.colorTransfer)))
            case "audio":
                info.audio.append(AudioTrack(
                    ref: ref,
                    codec: AudioCodecName(ffprobeName: codec),
                    channels: stream.channels ?? 2,
                    language: language(stream.tag("language")),
                    title: stream.tag("title"),
                    isDefault: stream.flag("default")))
            case "subtitle":
                info.subtitles.append(SubtitleTrack(
                    ref: ref,
                    codecName: codec,
                    kind: SubtitleKind(ffprobeName: codec),
                    language: language(stream.tag("language")),
                    title: stream.tag("title"),
                    isDefault: stream.flag("default"),
                    isForced: stream.flag("forced")))
            default:
                continue
            }
        }
        return info
    }

    private static func duration(_ text: String?) -> Double? {
        guard let text, let value = Double(text), value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func language(_ code: String?) -> String? {
        guard let code, !code.isEmpty, code != "und" else { return nil }
        return code
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `scripts/test-core.sh --filter FFprobeParserTests`
Expected: `✔ Test run with 7 tests in 1 suite passed`

- [ ] **Step 6: Commit**

```bash
git add core/Sources/PaperPlaneCore/Media/MediaInfo.swift core/Sources/PaperPlaneCore/Media/FFprobeParser.swift core/Tests/PaperPlaneCoreTests/FFprobeParserTests.swift
git commit -m "feat(core): media model and ffprobe JSON parser" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Running ffprobe: `ToolPaths`, `ProcessRunner`, `Redaction`, `MediaProbe`

**Files:**
- Create: `core/Sources/PaperPlaneCore/Support/ToolPaths.swift`, `core/Sources/PaperPlaneCore/Support/ProcessRunner.swift`, `core/Sources/PaperPlaneCore/Support/Redaction.swift`, `core/Sources/PaperPlaneCore/Media/MediaProbe.swift`
- Test: `core/Tests/PaperPlaneCoreTests/TestSupport.swift`, `ToolPathsTests.swift`, `ProcessRunnerTests.swift`, `RedactionTests.swift`, `MediaProbeTests.swift` (all in `core/Tests/PaperPlaneCoreTests/`)

**Interfaces:**
- Consumes: `ResolvedInput.Input.ffmpegOptions` / `.ffmpegLocation` (Task 1); `FFprobeParser.parse(_:input:)`, `MediaInfo.merging(_:)` and `MediaProbeError` (Task 4).
- Produces:
  - `public struct ToolPaths { ffmpeg: URL, ffprobe: URL }` with `static func locate(environment: = ProcessInfo…environment, fallbackDirectories: = ["/opt/homebrew/bin", "/usr/local/bin"]) -> ToolPaths?`.
  - `struct ProcessResult { status: Int32, stdout: Data, stderr: Data }`.
  - `enum ProcessRunner { static func run(_ executable: URL, arguments: [String]) async throws -> ProcessResult }`.
  - `enum Redaction { static func redactQueries(_:) -> String; static func summary(of stderr: Data) -> String }`.
  - `public struct MediaProbe { init(tools:); func probe(_ input: ResolvedInput) async throws -> MediaInfo }`.
  - Test helpers in `TestSupport`: `repoRoot`, `tools`, `media(_:)`, `hasMedia`, `makeTemporaryDirectory()` and `ffmpegHasFilter(_:)`.

- [ ] **Step 1: Write the test helpers**

`core/Tests/PaperPlaneCoreTests/TestSupport.swift`:

```swift
import Foundation
@testable import PaperPlaneCore

enum TestSupport {
    /// The repository root. This file lives at core/Tests/PaperPlaneCoreTests/TestSupport.swift.
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let mediaDirectory = repoRoot.appendingPathComponent("testdata/media")

    static let tools = ToolPaths.locate()

    static func media(_ name: String) -> URL {
        mediaDirectory.appendingPathComponent(name)
    }

    /// True when ffmpeg is installed and scripts/make-test-media.sh has been run.
    static var hasMedia: Bool {
        tools != nil && FileManager.default.fileExists(atPath: media("h264_aac.mp4").path)
    }

    static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("paperplane-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Whether the installed ffmpeg has a filter, e.g. `zscale` (needed for HDR → SDR tone mapping).
    static func ffmpegHasFilter(_ name: String) -> Bool {
        filterList.split(separator: "\n").contains { line in
            line.split(separator: " ").dropFirst().first == Substring(name)
        }
    }

    private static let filterList: String = {
        guard let tools else { return "" }
        let process = Process()
        process.executableURL = tools.ffmpeg
        process.arguments = ["-hide_banner", "-filters"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }()
}
```

- [ ] **Step 2: Write the failing tests**

`core/Tests/PaperPlaneCoreTests/ToolPathsTests.swift`:

```swift
import Foundation
import Testing
@testable import PaperPlaneCore

struct ToolPathsTests {
    @Test func prefersEnvironmentOverrides() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ffmpeg = try makeExecutable(named: "my-ffmpeg", in: directory)
        let ffprobe = try makeExecutable(named: "my-ffprobe", in: directory)

        let tools = ToolPaths.locate(
            environment: ["PAPERPLANE_FFMPEG": ffmpeg.path, "PAPERPLANE_FFPROBE": ffprobe.path],
            fallbackDirectories: [])

        #expect(tools?.ffmpeg.path == ffmpeg.path)
        #expect(tools?.ffprobe.path == ffprobe.path)
    }

    @Test func searchesPathDirectoriesInOrder() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ffmpeg = try makeExecutable(named: "ffmpeg", in: directory)
        let ffprobe = try makeExecutable(named: "ffprobe", in: directory)

        let tools = ToolPaths.locate(environment: ["PATH": "/nonexistent:\(directory.path)"], fallbackDirectories: [])

        #expect(tools?.ffmpeg.path == ffmpeg.path)
        #expect(tools?.ffprobe.path == ffprobe.path)
    }

    @Test func returnsNilWhenEitherToolIsMissing() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try makeExecutable(named: "ffmpeg", in: directory)

        #expect(ToolPaths.locate(environment: ["PATH": directory.path], fallbackDirectories: []) == nil)
    }

    private func makeExecutable(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
```

`core/Tests/PaperPlaneCoreTests/ProcessRunnerTests.swift`:

```swift
import Foundation
import Testing
@testable import PaperPlaneCore

struct ProcessRunnerTests {
    @Test func capturesStdoutAndStatus() async throws {
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/echo"), arguments: ["hello"])
        #expect(result.status == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "hello\n")
    }

    @Test func reportsNonZeroExitAndStderr() async throws {
        let result = try await ProcessRunner.run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo oops >&2; exit 3"])
        #expect(result.status == 3)
        #expect(String(decoding: result.stderr, as: UTF8.self) == "oops\n")
    }

    @Test func handlesOutputLargerThanThePipeBuffer() async throws {
        let result = try await ProcessRunner.run(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "head -c 1000000 /dev/zero; head -c 300000 /dev/zero >&2"])
        #expect(result.stdout.count == 1_000_000)
        #expect(result.stderr.count == 300_000)
    }

    @Test func missingExecutableThrows() async {
        await #expect(throws: (any Error).self) {
            try await ProcessRunner.run(URL(fileURLWithPath: "/nonexistent/tool"), arguments: [])
        }
    }
}
```

`core/Tests/PaperPlaneCoreTests/RedactionTests.swift`:

```swift
import Foundation
import Testing
@testable import PaperPlaneCore

struct RedactionTests {
    @Test func removesQueryStrings() {
        let text = "https://cdn.example.com/v/seg1.ts?token=SECRET&exp=99: Server returned 403 Forbidden"
        #expect(Redaction.redactQueries(text) == "https://cdn.example.com/v/seg1.ts?… Server returned 403 Forbidden")
    }

    @Test func summaryKeepsLastTwentyLinesRedacted() {
        let text = (1...30).map { "line \($0) https://x.test/a?k=\($0)" }.joined(separator: "\n")
        let summary = Redaction.summary(of: Data(text.utf8))
        let lines = summary.split(separator: "\n")
        #expect(lines.count == 20)
        #expect(lines.first == "line 11 https://x.test/a?…")
        #expect(!summary.contains("k="))
    }
}
```

`core/Tests/PaperPlaneCoreTests/MediaProbeTests.swift`:

```swift
import Foundation
import Testing
@testable import PaperPlaneCore

struct MediaProbeTests {
    @Test func emptyInputThrowsNoInputs() async {
        let unused = URL(fileURLWithPath: "/nonexistent")
        let probe = MediaProbe(tools: ToolPaths(ffmpeg: unused, ffprobe: unused))
        await #expect(throws: MediaProbeError.noInputs) {
            try await probe.probe(ResolvedInput(inputs: [], title: "nothing"))
        }
    }
}

@Suite(.enabled(if: TestSupport.hasMedia, "Needs ffmpeg (brew install ffmpeg) and scripts/make-test-media.sh"))
struct MediaProbeMediaTests {
    private func probe(_ name: String) async throws -> MediaInfo {
        try await MediaProbe(tools: TestSupport.tools!).probe(.file(TestSupport.media(name)))
    }

    @Test func probesMKVWithSurroundAndSubtitles() async throws {
        let info = try await probe("h264_ac3_51.mkv")
        #expect(info.video.map(\.codec) == [.h264])
        #expect(info.video.first?.width == 1280)
        #expect(info.video.first?.height == 720)
        #expect(info.audio.map(\.codec) == [.ac3])
        #expect(info.audio.first?.channels == 6)
        #expect(info.subtitles.map(\.kind) == [.text])
        let duration = try #require(info.duration)
        #expect(abs(duration - 10) < 0.5)
    }

    @Test func skipsEmbeddedCoverArt() async throws {
        let info = try await probe("h264_coverart.mkv")
        #expect(info.video.map(\.codec) == [.h264])
    }

    @Test func handlesAwkwardFileNames() async throws {
        let info = try await probe("Movie: Part 1 (Director's Cut) é.mp4")
        #expect(info.video.map(\.codec) == [.h264])
    }

    @Test func audioOnlyFileHasNoVideo() async throws {
        let info = try await probe("audio_only.m4a")
        #expect(info.video.isEmpty)
        #expect(info.audio.map(\.codec) == [.aac])
    }

    @Test func corruptFileThrowsFFprobeFailed() async throws {
        let error = await #expect(throws: MediaProbeError.self) {
            try await probe("corrupt.mkv")
        }
        guard case .ffprobeFailed(let status, _) = error else {
            Issue.record("Expected ffprobeFailed, got \(String(describing: error))")
            return
        }
        #expect(status != 0)
    }
}
```

- [ ] **Step 3: Run them and watch them fail**

Run: `scripts/test-core.sh --filter 'ToolPathsTests|ProcessRunnerTests|RedactionTests|MediaProbe'`
Expected: the build fails with `cannot find 'ToolPaths' in scope` (and similar for `ProcessRunner`, `Redaction`, `MediaProbe`).

- [ ] **Step 4: Implement the four units**

`core/Sources/PaperPlaneCore/Support/ToolPaths.swift`:

```swift
import Foundation

/// Where the ffmpeg and ffprobe executables are.
public struct ToolPaths: Equatable, Sendable {
    public var ffmpeg: URL
    public var ffprobe: URL

    public init(ffmpeg: URL, ffprobe: URL) {
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
    }

    /// Looks in `PAPERPLANE_FFMPEG` / `PAPERPLANE_FFPROBE` first, then each `PATH` directory,
    /// then `fallbackDirectories` (Homebrew's default locations).
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fallbackDirectories: [String] = ["/opt/homebrew/bin", "/usr/local/bin"]
    ) -> ToolPaths? {
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + fallbackDirectories
        guard let ffmpeg = find("ffmpeg", override: environment["PAPERPLANE_FFMPEG"], in: directories),
              let ffprobe = find("ffprobe", override: environment["PAPERPLANE_FFPROBE"], in: directories)
        else { return nil }
        return ToolPaths(ffmpeg: ffmpeg, ffprobe: ffprobe)
    }

    private static func find(_ name: String, override: String?, in directories: [String]) -> URL? {
        let files = FileManager.default
        if let override, files.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        for directory in directories {
            let path = (directory as NSString).appendingPathComponent(name)
            if files.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
}
```

`core/Sources/PaperPlaneCore/Support/ProcessRunner.swift`:

```swift
import Foundation

struct ProcessResult: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: Data
}

/// Runs a command to completion and captures its output.
enum ProcessRunner {
    static func run(_ executable: URL, arguments: [String]) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice
        try process.run()

        // Drain both pipes at the same time so a full pipe buffer can't stall the child.
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        async let stdout = readToEnd(stdoutHandle)
        async let stderr = readToEnd(stderrHandle)
        let (out, err) = await (stdout, stderr)
        process.waitUntilExit()
        return ProcessResult(status: process.terminationStatus, stdout: out, stderr: err)
    }

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: handle.readDataToEndOfFile())
            }
        }
    }
}
```

`core/Sources/PaperPlaneCore/Support/Redaction.swift`:

```swift
import Foundation

/// Keeps secrets out of error messages and logs.
enum Redaction {
    /// Replaces URL query strings, which often carry access tokens, with `?…`.
    static func redactQueries(_ text: String) -> String {
        text.replacing(/\?[^\s'"]+/, with: "?…")
    }

    /// The last 20 non-empty lines of a tool's stderr, redacted, for error messages.
    static func summary(of stderr: Data) -> String {
        let lines = String(decoding: stderr, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        return redactQueries(lines.suffix(20).joined(separator: "\n"))
    }
}
```

`core/Sources/PaperPlaneCore/Media/MediaProbe.swift`:

```swift
import Foundation

/// Reads a video's tracks, codecs and duration with ffprobe.
public struct MediaProbe: Sendable {
    public var tools: ToolPaths

    public init(tools: ToolPaths) {
        self.tools = tools
    }

    /// Probes every input and merges the results.
    public func probe(_ input: ResolvedInput) async throws -> MediaInfo {
        guard !input.inputs.isEmpty else { throw MediaProbeError.noInputs }
        var parts: [MediaInfo] = []
        for (position, item) in input.inputs.enumerated() {
            let arguments = ["-v", "error", "-print_format", "json", "-show_format", "-show_streams"]
                + item.ffmpegOptions + [item.ffmpegLocation]
            let result = try await ProcessRunner.run(tools.ffprobe, arguments: arguments)
            guard result.status == 0 else {
                throw MediaProbeError.ffprobeFailed(status: result.status, message: Redaction.summary(of: result.stderr))
            }
            parts.append(try FFprobeParser.parse(result.stdout, input: position))
        }
        return MediaInfo.merging(parts)
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `scripts/test-core.sh --filter 'ToolPathsTests|ProcessRunnerTests|RedactionTests|MediaProbe'`
Expected: all pass, with no "skipped" lines. The media tests run because Task 2 generated the clips. If you see `Suite MediaProbeMediaTests skipped`, run `scripts/make-test-media.sh` and retry.

- [ ] **Step 6: Commit**

```bash
git add core/Sources/PaperPlaneCore/Support core/Sources/PaperPlaneCore/Media/MediaProbe.swift core/Tests/PaperPlaneCoreTests
git commit -m "feat(core): locate tools, run processes safely, probe media with ffprobe" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: `ConversionPlanner`

**Files:**
- Create: `core/Sources/PaperPlaneCore/Conversion/ConversionPlan.swift`, `core/Sources/PaperPlaneCore/Conversion/ConversionPlanner.swift`
- Test: `core/Tests/PaperPlaneCoreTests/ConversionPlannerTests.swift`

**Interfaces:**
- Consumes: `MediaInfo`, `VideoTrack`, `AudioTrack`, `TrackRef`, `VideoCodecName` (must be `Hashable`), `AudioCodecName` and `HDRFormat` (Task 4).
- Produces:
  - `OutputProfile(surround:hdr:)` with `static let default` (`surround: true, hdr: true`, until Task 9).
  - `TrackChoice(audio: TrackRef? = nil)`.
  - `VideoEncoder` (`.h264`, `.hevc`).
  - `VideoEncode { encoder, keepHDR: HDRFormat?, toneMapToSDR: Bool, bitrate: Int }`.
  - `VideoAction` (`.copy(VideoCodecName)`, `.encode(VideoEncode)`).
  - `AudioAction` (`.copy`, `.eac3Surround`, `.aacStereo`).
  - `ConversionPlan { video: TrackRef, videoAction, audio: TrackRef?, audioAction: AudioAction? }`.
  - `PlanError` (`.noVideoTrack`, `.noSuchAudioTrack(TrackRef)`).
  - `ConversionPlanner.plan(_ media: MediaInfo, choice: TrackChoice = TrackChoice(), profile: OutputProfile = .default) throws -> ConversionPlan`.
  - Also internal `videoAction(for:profile:)`, `audioAction(for:profile:)` and `bitrate(height:encoder:)`.

Subtitle decisions are deliberately not here. They depend on Sony test row 5 and arrive in Plan 3, together with their ffmpeg arguments.

- [ ] **Step 1: Write the failing tests**

`core/Tests/PaperPlaneCoreTests/ConversionPlannerTests.swift`:

```swift
import Foundation
import Testing
@testable import PaperPlaneCore

struct ConversionPlannerTests {
    // MARK: - Builders

    static func video(_ codec: VideoCodecName, height: Int = 1080, pixelFormat: String = "yuv420p",
                      hdr: HDRFormat? = nil, index: Int = 0) -> VideoTrack {
        VideoTrack(ref: TrackRef(index: index), codec: codec, width: height * 16 / 9, height: height,
                   pixelFormat: pixelFormat, hdr: hdr)
    }

    static func audio(_ codec: AudioCodecName, channels: Int = 2, isDefault: Bool = false, index: Int = 1) -> AudioTrack {
        AudioTrack(ref: TrackRef(index: index), codec: codec, channels: channels, language: nil, title: nil,
                   isDefault: isDefault)
    }

    static func media(_ video: [VideoTrack], _ audio: [AudioTrack]) -> MediaInfo {
        MediaInfo(duration: 60, video: video, audio: audio, subtitles: [])
    }

    static let noSurroundNoHDR = OutputProfile(surround: false, hdr: false)

    // MARK: - Video

    @Test func copiesH264AndHEVC() throws {
        #expect(ConversionPlanner.videoAction(for: Self.video(.h264), profile: .default) == .copy(.h264))
        #expect(ConversionPlanner.videoAction(for: Self.video(.hevc, height: 2160), profile: .default) == .copy(.hevc))
    }

    @Test func copiesHDRWhenTheTVAcceptsIt() {
        let track = Self.video(.hevc, height: 2160, pixelFormat: "yuv420p10le", hdr: .pq)
        #expect(ConversionPlanner.videoAction(for: track, profile: .default) == .copy(.hevc))
    }

    @Test func reencodesOtherCodecsToH264UpTo1080p() {
        for codec in [VideoCodecName.other("vp9"), .other("av1"), .other("mpeg2video"), .other("vc1")] {
            let action = ConversionPlanner.videoAction(for: Self.video(codec, height: 1080), profile: .default)
            #expect(action == .encode(VideoEncode(encoder: .h264, keepHDR: nil, toneMapToSDR: false,
                                                  bitrate: 8_000_000)))
        }
    }

    @Test func reencodesLargeSourcesToHEVC() {
        let action = ConversionPlanner.videoAction(for: Self.video(.other("vp9"), height: 2160), profile: .default)
        #expect(action == .encode(VideoEncode(encoder: .hevc, keepHDR: nil, toneMapToSDR: false,
                                              bitrate: 16_000_000)))
    }

    @Test func reencodesTenBitH264BecauseAppleCannotDecodeIt() {
        let track = Self.video(.h264, height: 720, pixelFormat: "yuv420p10le")
        #expect(ConversionPlanner.videoAction(for: track, profile: .default)
            == .encode(VideoEncode(encoder: .h264, keepHDR: nil, toneMapToSDR: false, bitrate: 5_000_000)))
    }

    @Test func reencodesHDRNonHEVCKeepingHDR() {
        let track = Self.video(.other("av1"), height: 2160, pixelFormat: "yuv420p10le", hdr: .hlg)
        #expect(ConversionPlanner.videoAction(for: track, profile: .default)
            == .encode(VideoEncode(encoder: .hevc, keepHDR: .hlg, toneMapToSDR: false, bitrate: 16_000_000)))
    }

    @Test func toneMapsHDRWhenTheTVRejectsIt() {
        let track = Self.video(.hevc, height: 1080, pixelFormat: "yuv420p10le", hdr: .pq)
        #expect(ConversionPlanner.videoAction(for: track, profile: Self.noSurroundNoHDR)
            == .encode(VideoEncode(encoder: .h264, keepHDR: nil, toneMapToSDR: true, bitrate: 8_000_000)))
    }

    @Test func noVideoTrackThrows() {
        #expect(throws: PlanError.noVideoTrack) {
            try ConversionPlanner.plan(Self.media([], [Self.audio(.aac)]))
        }
    }

    // MARK: - Audio

    @Test(arguments: [
        (AudioCodecName.aac, 2, AudioAction.copy),
        (.aac, 6, .copy),
        (.ac3, 6, .copy),
        (.eac3, 6, .copy),
        (.other("dts"), 6, .eac3Surround),
        (.other("truehd"), 8, .eac3Surround),
        (.other("flac"), 8, .eac3Surround),
        (.other("opus"), 2, .aacStereo),
        (.other("mp3"), 1, .aacStereo),
    ])
    func audioWithSurroundTV(codec: AudioCodecName, channels: Int, expected: AudioAction) {
        let action = ConversionPlanner.audioAction(for: Self.audio(codec, channels: channels), profile: .default)
        #expect(action == expected)
    }

    @Test(arguments: [
        (AudioCodecName.aac, 2, AudioAction.copy),
        (.aac, 6, .aacStereo),
        (.ac3, 6, .aacStereo),
        (.eac3, 2, .aacStereo),
        (.other("dts"), 6, .aacStereo),
    ])
    func audioWithStereoOnlyTV(codec: AudioCodecName, channels: Int, expected: AudioAction) {
        let action = ConversionPlanner.audioAction(for: Self.audio(codec, channels: channels),
                                                   profile: Self.noSurroundNoHDR)
        #expect(action == expected)
    }

    @Test func picksTheDefaultAudioTrackThenTheFirst() throws {
        let english = Self.audio(.aac, index: 1)
        let japanese = Self.audio(.ac3, channels: 6, isDefault: true, index: 2)
        let flagged = try ConversionPlanner.plan(Self.media([Self.video(.h264)], [english, japanese]))
        #expect(flagged.audio == japanese.ref)
        #expect(flagged.audioAction == .copy)

        var unflagged = japanese
        unflagged.isDefault = false
        let first = try ConversionPlanner.plan(Self.media([Self.video(.h264)], [english, unflagged]))
        #expect(first.audio == english.ref)
    }

    @Test func honoursAnExplicitAudioChoice() throws {
        let english = Self.audio(.aac, index: 1)
        let japanese = Self.audio(.ac3, channels: 6, isDefault: true, index: 2)
        let plan = try ConversionPlanner.plan(Self.media([Self.video(.h264)], [english, japanese]),
                                              choice: TrackChoice(audio: english.ref))
        #expect(plan.audio == english.ref)
    }

    @Test func unknownAudioChoiceThrows() {
        let missing = TrackRef(index: 9)
        #expect(throws: PlanError.noSuchAudioTrack(missing)) {
            try ConversionPlanner.plan(Self.media([Self.video(.h264)], [Self.audio(.aac)]),
                                       choice: TrackChoice(audio: missing))
        }
    }

    @Test func videoWithoutAudioHasNoAudioPlan() throws {
        let plan = try ConversionPlanner.plan(Self.media([Self.video(.h264)], []))
        #expect(plan.audio == nil)
        #expect(plan.audioAction == nil)
    }
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `scripts/test-core.sh --filter ConversionPlannerTests`
Expected: the build fails with `cannot find 'ConversionPlanner' in scope` (and similar for `OutputProfile`, `VideoEncode`).

- [ ] **Step 3: Implement the plan types**

`core/Sources/PaperPlaneCore/Conversion/ConversionPlan.swift`:

```swift
import Foundation

/// What the TV accepts over AirPlay. Receivers can't be queried, so this comes from
/// testing (the Sony test sets the default) plus user overrides in Settings.
public struct OutputProfile: Equatable, Sendable {
    /// Accepts AC3 / E-AC3 surround. When false, everything becomes stereo AAC.
    public var surround: Bool
    /// Accepts HDR10 / HLG HEVC. When false, HDR video is tone-mapped to SDR.
    public var hdr: Bool

    public init(surround: Bool, hdr: Bool) {
        self.surround = surround
        self.hdr = hdr
    }

    public static let `default` = OutputProfile(surround: true, hdr: true)
}

/// The user's track picks. nil means "use the default".
public struct TrackChoice: Equatable, Sendable {
    public var audio: TrackRef?

    public init(audio: TrackRef? = nil) {
        self.audio = audio
    }
}

public enum VideoEncoder: Equatable, Sendable {
    case h264
    case hevc
}

public struct VideoEncode: Equatable, Sendable {
    public var encoder: VideoEncoder
    /// Non-nil keeps HDR: 10-bit HEVC tagged with this transfer function.
    public var keepHDR: HDRFormat?
    public var toneMapToSDR: Bool
    /// Target bitrate in bits per second.
    public var bitrate: Int
}

public enum VideoAction: Equatable, Sendable {
    case copy(VideoCodecName)
    case encode(VideoEncode)
}

public enum AudioAction: Equatable, Sendable {
    case copy
    /// E-AC3 5.1 at 640 kb/s (7.1 sources are downmixed).
    case eac3Surround
    /// AAC stereo at 192 kb/s.
    case aacStereo
}

/// Exactly what to do with each stream for one playback.
public struct ConversionPlan: Equatable, Sendable {
    public var video: TrackRef
    public var videoAction: VideoAction
    /// nil when the source has no audio.
    public var audio: TrackRef?
    public var audioAction: AudioAction?
}

public enum PlanError: Error, Equatable {
    /// Nothing to show: the file has no video (or only cover art).
    case noVideoTrack
    /// The chosen audio track doesn't exist in this media.
    case noSuchAudioTrack(TrackRef)
}
```

- [ ] **Step 4: Implement the planner**

`core/Sources/PaperPlaneCore/Conversion/ConversionPlanner.swift`:

```swift
import Foundation

/// Decides what to copy and what to convert so the TV can play the media (spec §4.1).
public enum ConversionPlanner {
    public static func plan(
        _ media: MediaInfo,
        choice: TrackChoice = TrackChoice(),
        profile: OutputProfile = .default
    ) throws -> ConversionPlan {
        guard let video = media.video.first else { throw PlanError.noVideoTrack }
        let audio = try pickAudio(media.audio, choice: choice.audio)
        return ConversionPlan(
            video: video.ref,
            videoAction: videoAction(for: video, profile: profile),
            audio: audio?.ref,
            audioAction: audio.map { audioAction(for: $0, profile: profile) })
    }

    // MARK: - Video

    /// Pixel formats Apple's decoders handle for each codec we copy. 10-bit H.264 ("Hi10P") isn't one.
    private static let copyablePixelFormats: [VideoCodecName: Set<String>] = [
        .h264: ["yuv420p", "yuvj420p"],
        .hevc: ["yuv420p", "yuvj420p", "yuv420p10le"],
    ]

    static func videoAction(for track: VideoTrack, profile: OutputProfile) -> VideoAction {
        let needsToneMap = track.hdr != nil && !profile.hdr
        if let formats = copyablePixelFormats[track.codec],
           formats.contains(track.pixelFormat ?? "yuv420p"),
           !needsToneMap {
            return .copy(track.codec)
        }
        let keepHDR = profile.hdr ? track.hdr : nil
        let encoder: VideoEncoder = (track.height > 1080 || keepHDR != nil) ? .hevc : .h264
        return .encode(VideoEncode(
            encoder: encoder,
            keepHDR: keepHDR,
            toneMapToSDR: needsToneMap,
            bitrate: bitrate(height: track.height, encoder: encoder)))
    }

    static func bitrate(height: Int, encoder: VideoEncoder) -> Int {
        switch (encoder, height) {
        case (.h264, ...720): return 5_000_000
        case (.h264, ...1080): return 8_000_000
        case (.h264, _): return 20_000_000
        case (.hevc, ...720): return 4_000_000
        case (.hevc, ...1080): return 6_000_000
        case (.hevc, _): return 16_000_000
        }
    }

    // MARK: - Audio

    private static func pickAudio(_ tracks: [AudioTrack], choice: TrackRef?) throws -> AudioTrack? {
        if let choice {
            guard let chosen = tracks.first(where: { $0.ref == choice }) else {
                throw PlanError.noSuchAudioTrack(choice)
            }
            return chosen
        }
        return tracks.first(where: \.isDefault) ?? tracks.first
    }

    static func audioAction(for track: AudioTrack, profile: OutputProfile) -> AudioAction {
        if profile.surround {
            switch track.codec {
            case .aac, .ac3, .eac3: return .copy
            case .other: return track.channels > 2 ? .eac3Surround : .aacStereo
            }
        }
        return track.codec == .aac && track.channels <= 2 ? .copy : .aacStereo
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `scripts/test-core.sh --filter ConversionPlannerTests`
Expected: all pass, including `audioWithSurroundTV(codec:channels:expected:) with 9 test cases passed` and `audioWithStereoOnlyTV(codec:channels:expected:) with 5 test cases passed`.

- [ ] **Step 6: Commit**

```bash
git add core/Sources/PaperPlaneCore/Conversion core/Tests/PaperPlaneCoreTests/ConversionPlannerTests.swift
git commit -m "feat(core): conversion planner for video and audio (spec 4.1)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: ffmpeg command line for a plan

**Files:**
- Create: `core/Sources/PaperPlaneCore/Conversion/FFmpegArguments.swift`
- Test: `core/Tests/PaperPlaneCoreTests/FFmpegArgumentsTests.swift`

**Interfaces:**
- Consumes: `ConversionPlan`, `VideoAction`, `VideoEncode`, `AudioAction` (Task 6); `ResolvedInput.Input.ffmpegOptions` / `.ffmpegLocation` (Task 1); `TrackRef.mapSpecifier` (Task 4).
- Produces:
  - `extension ConversionPlan { static let segmentSeconds = 6; static let toneMapFilter: String; func ffmpegArguments(input: ResolvedInput, start: Double, output: URL) -> [String] }`.
  - The output folder receives `index.m3u8`, `init.mp4` and `seg_%05d.m4s`.
  - Note: the spec's sketch said `ffmpegArguments(start:output:)`. It takes the input too, because the plan alone doesn't know which file or URL to read.

- [ ] **Step 1: Write the failing tests**

`core/Tests/PaperPlaneCoreTests/FFmpegArgumentsTests.swift`:

```swift
import Foundation
import Testing
@testable import PaperPlaneCore

struct FFmpegArgumentsTests {
    static let output = URL(fileURLWithPath: "/tmp/session")
    static let movie = ResolvedInput.file(URL(fileURLWithPath: "/Movies/Movie: Part 1 (Director's Cut) é.mkv"))

    static let hlsTail = [
        "-max_muxing_queue_size", "4096",
        "-f", "hls", "-hls_time", "6", "-hls_playlist_type", "event", "-hls_segment_type", "fmp4",
        "-hls_fmp4_init_filename", "init.mp4", "-hls_segment_filename", "/tmp/session/seg_%05d.m4s",
        "-hls_flags", "independent_segments+temp_file", "-start_number", "0", "/tmp/session/index.m3u8",
    ]

    static func plan(_ video: VideoAction, audio: AudioAction? = .copy) -> ConversionPlan {
        ConversionPlan(video: TrackRef(index: 0), videoAction: video,
                       audio: audio == nil ? nil : TrackRef(index: 2), audioAction: audio)
    }

    @Test func copyPlanFromTheStart() {
        let args = Self.plan(.copy(.h264)).ffmpegArguments(input: Self.movie, start: 0, output: Self.output)
        #expect(args == [
            "-hide_banner", "-nostdin", "-nostats", "-loglevel", "error",
            "-i", "/Movies/Movie: Part 1 (Director's Cut) é.mkv",
            "-map", "0:0", "-map", "0:2", "-map_chapters", "-1",
            "-c:v", "copy", "-c:a", "copy",
        ] + Self.hlsTail)
    }

    @Test func startOffsetGoesBeforeEachInput() {
        let input = ResolvedInput(inputs: [
            .init(url: URL(string: "https://cdn.example.com/video.mp4")!, headers: ["Cookie": "a=1"]),
            .init(url: URL(string: "https://cdn.example.com/audio.m4a")!, headers: ["Cookie": "a=1"]),
        ], title: "Clip")
        let plan = ConversionPlan(video: TrackRef(input: 0, index: 0), videoAction: .copy(.h264),
                                  audio: TrackRef(input: 1, index: 0), audioAction: .copy)
        let args = plan.ffmpegArguments(input: input, start: 754.25, output: Self.output)
        #expect(Array(args.prefix(20)) == [
            "-hide_banner", "-nostdin", "-nostats", "-loglevel", "error",
            "-headers", "Cookie: a=1\r\n", "-ss", "754.250", "-i", "https://cdn.example.com/video.mp4",
            "-headers", "Cookie: a=1\r\n", "-ss", "754.250", "-i", "https://cdn.example.com/audio.m4a",
            "-map", "0:0", "-map",
        ])
        #expect(args[20] == "1:0")
    }

    @Test func hevcCopyIsTaggedForApple() {
        let args = Self.plan(.copy(.hevc)).ffmpegArguments(input: Self.movie, start: 0, output: Self.output)
        #expect(args.contains(subsequence: ["-c:v", "copy", "-tag:v", "hvc1"]))
    }

    @Test func h264EncodeUsesVideoToolboxWithSegmentAlignedKeyframes() {
        let encode = VideoEncode(encoder: .h264, keepHDR: nil, toneMapToSDR: false, bitrate: 8_000_000)
        let args = Self.plan(.encode(encode)).ffmpegArguments(input: Self.movie, start: 0, output: Self.output)
        #expect(args.contains(subsequence: [
            "-c:v", "h264_videotoolbox", "-profile:v", "high", "-pix_fmt", "yuv420p",
            "-allow_sw", "1", "-b:v", "8000000", "-force_key_frames", "expr:gte(t,n_forced*6)",
        ]))
        #expect(!args.contains("-vf"))
    }

    @Test func hdrEncodeKeepsTenBitAndColorTags() {
        let encode = VideoEncode(encoder: .hevc, keepHDR: .pq, toneMapToSDR: false, bitrate: 16_000_000)
        let args = Self.plan(.encode(encode)).ffmpegArguments(input: Self.movie, start: 0, output: Self.output)
        #expect(args.contains(subsequence: [
            "-c:v", "hevc_videotoolbox", "-tag:v", "hvc1", "-profile:v", "main10", "-pix_fmt", "p010le",
            "-color_primaries", "bt2020", "-colorspace", "bt2020nc", "-color_trc", "smpte2084",
        ]))
    }

    @Test func toneMappingAddsTheFilterChain() {
        let encode = VideoEncode(encoder: .h264, keepHDR: nil, toneMapToSDR: true, bitrate: 8_000_000)
        let args = Self.plan(.encode(encode)).ffmpegArguments(input: Self.movie, start: 0, output: Self.output)
        #expect(args.contains(subsequence: ["-vf", ConversionPlan.toneMapFilter]))
    }

    @Test func audioConversions() {
        let surround = Self.plan(.copy(.h264), audio: .eac3Surround)
            .ffmpegArguments(input: Self.movie, start: 0, output: Self.output)
        #expect(surround.contains(subsequence: ["-c:a", "eac3", "-b:a", "640k", "-ac", "6"]))

        let stereo = Self.plan(.copy(.h264), audio: .aacStereo)
            .ffmpegArguments(input: Self.movie, start: 0, output: Self.output)
        #expect(stereo.contains(subsequence: ["-c:a", "aac", "-b:a", "192k", "-ac", "2"]))
    }

    @Test func noAudioDisablesAudio() {
        let args = Self.plan(.copy(.h264), audio: nil).ffmpegArguments(input: Self.movie, start: 0, output: Self.output)
        #expect(args.contains("-an"))
        #expect(!args.contains("-c:a"))
        #expect(args.filter { $0 == "-map" }.count == 1)
    }
}

extension Array where Element: Equatable {
    /// True if `subsequence` appears contiguously in this array.
    func contains(subsequence: [Element]) -> Bool {
        guard !subsequence.isEmpty, subsequence.count <= count else { return subsequence.isEmpty }
        return (0...(count - subsequence.count)).contains { start in
            Array(self[start..<(start + subsequence.count)]) == subsequence
        }
    }
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `scripts/test-core.sh --filter FFmpegArgumentsTests`
Expected: the build fails with `value of type 'ConversionPlan' has no member 'ffmpegArguments'`.

- [ ] **Step 3: Implement the arguments**

`core/Sources/PaperPlaneCore/Conversion/FFmpegArguments.swift`:

```swift
import Foundation

extension ConversionPlan {
    /// HLS segment length target, in seconds.
    public static let segmentSeconds = 6

    /// HDR → SDR tone mapping chain. Needs an ffmpeg built with zimg (`zscale`).
    static let toneMapFilter =
        "zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,"
        + "zscale=t=bt709:m=bt709:r=tv,format=yuv420p"

    /// The ffmpeg command line (without the executable) that writes this plan as an HLS
    /// event playlist (`index.m3u8`, `init.mp4`, `seg_00000.m4s`, …) into `output`,
    /// starting `start` seconds into the media.
    public func ffmpegArguments(input: ResolvedInput, start: Double, output: URL) -> [String] {
        var args = ["-hide_banner", "-nostdin", "-nostats", "-loglevel", "error"]
        for item in input.inputs {
            args += item.ffmpegOptions
            if start > 0 {
                args += ["-ss", String(format: "%.3f", start)]
            }
            args += ["-i", item.ffmpegLocation]
        }

        args += ["-map", video.mapSpecifier]
        if let audio {
            args += ["-map", audio.mapSpecifier]
        } else {
            args += ["-an"]
        }
        args += ["-map_chapters", "-1"]
        args += videoArguments()
        args += audioArguments()
        args += ["-max_muxing_queue_size", "4096"]
        args += [
            "-f", "hls",
            "-hls_time", String(Self.segmentSeconds),
            "-hls_playlist_type", "event",
            "-hls_segment_type", "fmp4",
            "-hls_fmp4_init_filename", "init.mp4",
            "-hls_segment_filename", output.appendingPathComponent("seg_%05d.m4s").path,
            "-hls_flags", "independent_segments+temp_file",
            "-start_number", "0",
            output.appendingPathComponent("index.m3u8").path,
        ]
        return args
    }

    private func videoArguments() -> [String] {
        switch videoAction {
        case .copy(.hevc):
            return ["-c:v", "copy", "-tag:v", "hvc1"]
        case .copy:
            return ["-c:v", "copy"]
        case .encode(let encode):
            var args: [String]
            switch (encode.encoder, encode.keepHDR) {
            case (.h264, _):
                args = ["-c:v", "h264_videotoolbox", "-profile:v", "high", "-pix_fmt", "yuv420p"]
            case (.hevc, nil):
                args = ["-c:v", "hevc_videotoolbox", "-tag:v", "hvc1", "-profile:v", "main", "-pix_fmt", "yuv420p"]
            case (.hevc, let hdr?):
                args = ["-c:v", "hevc_videotoolbox", "-tag:v", "hvc1", "-profile:v", "main10", "-pix_fmt", "p010le",
                        "-color_primaries", "bt2020", "-colorspace", "bt2020nc",
                        "-color_trc", hdr == .pq ? "smpte2084" : "arib-std-b67"]
            }
            args += [
                "-allow_sw", "1",
                "-b:v", String(encode.bitrate),
                "-force_key_frames", "expr:gte(t,n_forced*\(Self.segmentSeconds))",
            ]
            if encode.toneMapToSDR {
                args += ["-vf", Self.toneMapFilter]
            }
            return args
        }
    }

    private func audioArguments() -> [String] {
        switch audioAction {
        case nil: return []
        case .copy: return ["-c:a", "copy"]
        case .eac3Surround: return ["-c:a", "eac3", "-b:a", "640k", "-ac", "6"]
        case .aacStereo: return ["-c:a", "aac", "-b:a", "192k", "-ac", "2"]
        }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test-core.sh --filter FFmpegArgumentsTests`
Expected: `✔ Test run with 8 tests in 1 suite passed`

- [ ] **Step 5: Commit**

```bash
git add core/Sources/PaperPlaneCore/Conversion/FFmpegArguments.swift core/Tests/PaperPlaneCoreTests/FFmpegArgumentsTests.swift
git commit -m "feat(core): ffmpeg HLS command line for a conversion plan" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: End-to-end pipeline test

**Files:**
- Test: `core/Tests/PaperPlaneCoreTests/PipelineTests.swift`

**Interfaces:**
- Consumes: `MediaProbe` and `ProcessRunner` (Task 5); `ConversionPlanner` (Task 6); `ffmpegArguments(input:start:output:)` (Task 7); `scripts/serve-hls.py` and the test media (Task 2); `TestSupport` (Task 5).
- Produces: `HLSServer` (test helper: `init(directory:) async throws`, `url(_:)`, `stop()`). No product code: this task proves the pieces work together. Apple's player has to accept every converted clip, which the spec's testing section requires.

- [ ] **Step 1: Write the pipeline test**

`core/Tests/PaperPlaneCoreTests/PipelineTests.swift`:

```swift
import AVFoundation
import Foundation
import Testing
@testable import PaperPlaneCore

/// End to end: probe → plan → ffmpeg → HLS served over HTTP → Apple's player says it's playable.
@Suite(.enabled(if: TestSupport.hasMedia, "Needs ffmpeg (brew install ffmpeg) and scripts/make-test-media.sh"))
struct PipelineTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var file: String
        var profile = OutputProfile.default
        var video: VideoCodecName
        var audio: AudioCodecName?
        var channels: Int?
        var hdr: HDRFormat?
        var testDescription: String { file }
    }

    static let cases: [Case] = [
        Case(file: "h264_aac.mp4", video: .h264, audio: .aac, channels: 2),
        Case(file: "h264_ac3_51.mkv", video: .h264, audio: .ac3, channels: 6),
        Case(file: "hevc_eac3_51.mkv", video: .hevc, audio: .eac3, channels: 6),
        Case(file: "hevc_hdr10_aac.mkv", video: .hevc, audio: .aac, channels: 2, hdr: .pq),
        Case(file: "vp9_opus.webm", video: .h264, audio: .aac, channels: 2),
        Case(file: "av1_flac_51.mkv", video: .h264, audio: .eac3, channels: 6),
        Case(file: "mpeg2_dts_51.mkv", video: .h264, audio: .eac3, channels: 6),
        Case(file: "h264_flac_71.mkv", video: .h264, audio: .eac3, channels: 6),
        Case(file: "h264_10bit_aac.mkv", video: .h264, audio: .aac, channels: 2),
        Case(file: "h264_noaudio.mkv", video: .h264, audio: nil),
        Case(file: "h264_coverart.mkv", video: .h264, audio: .aac, channels: 2),
        Case(file: "h264_multiaudio.mkv", video: .h264, audio: .ac3, channels: 6),
        Case(file: "Movie: Part 1 (Director's Cut) é.mp4", video: .h264, audio: .aac, channels: 2),
        Case(file: "h264_ac3_51.mkv", profile: OutputProfile(surround: false, hdr: true),
             video: .h264, audio: .aac, channels: 2),
    ]

    @Test(arguments: cases)
    func convertsToPlayableHLS(_ testCase: Case) async throws {
        let output = try await convert(testCase.file, profile: testCase.profile, start: 0)
        defer { try? FileManager.default.removeItem(at: output.work) }

        #expect(abs(output.duration - 10) < 1.5)
        #expect(output.converted.video.first?.codec == testCase.video)
        #expect(output.converted.audio.first?.codec == testCase.audio)
        #expect(output.converted.audio.first?.channels == testCase.channels)
        #expect(output.converted.video.first?.hdr == testCase.hdr)
        if testCase.file == "h264_10bit_aac.mkv" {
            #expect(output.converted.video.first?.pixelFormat == "yuv420p")
        }
    }

    @Test func startsPartWayThrough() async throws {
        let output = try await convert("h264_aac.mp4", profile: .default, start: 4)
        defer { try? FileManager.default.removeItem(at: output.work) }
        #expect(abs(output.duration - 6) < 1.5)
    }

    @Test(.enabled(if: TestSupport.ffmpegHasFilter("zscale"), "Needs an ffmpeg built with zimg (zscale)"))
    func toneMapsHDRForAnSDRTV() async throws {
        let output = try await convert("hevc_hdr10_aac.mkv", profile: OutputProfile(surround: true, hdr: false), start: 0)
        defer { try? FileManager.default.removeItem(at: output.work) }
        #expect(output.converted.video.first?.codec == .h264)
        #expect(output.converted.video.first?.hdr == nil)
    }

    @Test func audioOnlyFileIsRejectedBeforeConverting() async throws {
        let media = try await MediaProbe(tools: TestSupport.tools!).probe(.file(TestSupport.media("audio_only.m4a")))
        #expect(throws: PlanError.noVideoTrack) {
            try ConversionPlanner.plan(media)
        }
    }

    // MARK: - Helpers

    struct Output {
        var work: URL
        var duration: Double
        var converted: MediaInfo
    }

    private func convert(_ file: String, profile: OutputProfile, start: Double) async throws -> Output {
        let tools = try #require(TestSupport.tools)
        let work = try TestSupport.makeTemporaryDirectory()
        let session = work.appendingPathComponent("session")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)

        let input = ResolvedInput.file(TestSupport.media(file))
        let media = try await MediaProbe(tools: tools).probe(input)
        let plan = try ConversionPlanner.plan(media, profile: profile)
        let result = try await ProcessRunner.run(
            tools.ffmpeg, arguments: plan.ffmpegArguments(input: input, start: start, output: session))
        try #require(result.status == 0, "ffmpeg failed: \(String(decoding: result.stderr, as: UTF8.self))")

        let playlist = try String(contentsOf: session.appendingPathComponent("index.m3u8"), encoding: .utf8)
        #expect(playlist.contains("#EXT-X-ENDLIST"))

        let server = try await HLSServer(directory: work)
        defer { server.stop() }
        let url = server.url("session/index.m3u8")
        let asset = AVURLAsset(url: url)
        #expect(try await asset.load(.isPlayable))
        let duration = try await asset.load(.duration).seconds
        let converted = try await MediaProbe(tools: tools).probe(ResolvedInput(inputs: [.init(url: url)], title: file))
        return Output(work: work, duration: duration, converted: converted)
    }
}

/// Runs scripts/serve-hls.py on a random local port for the duration of a test.
final class HLSServer {
    private let process = Process()
    let port: Int

    init(directory: URL) async throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", TestSupport.repoRoot.appendingPathComponent("scripts/serve-hls.py").path,
                             directory.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()

        var found: Int?
        for try await line in stdout.fileHandleForReading.bytes.lines {
            if line.hasPrefix("PORT "), let port = Int(line.dropFirst(5)) {
                found = port
                break
            }
        }
        port = try #require(found, "serve-hls.py didn't report a port")
    }

    func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)/\(path)")!
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
    }
}
```

- [ ] **Step 2: Run it**

Run: `scripts/test-core.sh --filter PipelineTests`

Expected:
- `convertsToPlayableHLS(_:) with 14 test cases passed`.
- `startsPartWayThrough()` and `audioOnlyFileIsRejectedBeforeConverting()` pass.
- `toneMapsHDRForAnSDRTV()` is skipped with "Needs an ffmpeg built with zimg (zscale)". Homebrew's ffmpeg lacks zimg, and the bundled build in Plan 2 will include it.

If a case fails, the test output includes ffmpeg's stderr. Fix the cause in the unit that owns it (planner rule or arguments), add a unit test in that unit's test file that reproduces it, and rerun. Don't loosen the pipeline expectations.

- [ ] **Step 3: Run the whole suite**

Run: `scripts/test-core.sh`
Expected: `✔ Test run with … tests in 10 suites passed`, with only `toneMapsHDRForAnSDRTV()` skipped.

- [ ] **Step 4: Commit**

```bash
git add core/Tests/PaperPlaneCoreTests/PipelineTests.swift
git commit -m "test(core): end-to-end probe → plan → ffmpeg → AVFoundation pipeline test" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Apply the Sony results

Needs Task 3 (completed results sheet) and Task 6 (`OutputProfile`).

**Files:**
- Modify: `core/Sources/PaperPlaneCore/Conversion/ConversionPlan.swift` (`OutputProfile.default`)
- Modify: `core/Tests/PaperPlaneCoreTests/ConversionPlannerTests.swift` (add one test)
- Modify: `docs/sony-test-results.md` (Decisions section), `docs/superpowers/specs/2026-10-15-paper-plane-design.md` (§4.1 profile sentence, §10 risk rows)

**Interfaces:**
- Consumes: the Results table from Task 3; `OutputProfile` (Task 6).
- Produces: `OutputProfile.default` matching the Sony, and recorded decisions that Plan 2 and Plan 3 build on.

**Decision rules** (apply them exactly to the Results column):
- `surround` is `true` if rows 3 **and** 4 both played with sound, even if the TV showed stereo. It's `false` if either was silent or failed.
- `hdr` is `true` if row 6 played and the TV showed its HDR indicator. Otherwise it's `false`.
- **Subtitles:** "WebVTT track" if row 5 showed the subtitle text on the TV; otherwise "always burn in".
- **Live start:**
  - "rely on AVPlayer" if row 7a started at 0 s.
  - Otherwise "seek to 0 after load" if row 7b worked.
  - Otherwise "write our own playlist with `#EXT-X-START:TIME-OFFSET=0`".
- **Server binding:** "LAN address required" if row 0's segment requests came from the TV's IP. If they came from the Mac's IP, record "Mac fetches the stream itself; localhost may suffice — Plan 2 to confirm".
- **TV selection:**
  - Row 8 YES → "detect the TV via `isExternalPlaybackActive` before starting"; NO → "start paused, then check `isExternalPlaybackActive`".
  - Row 9 YES → "macOS remembers the TV"; NO → "remote opens with the picker each time".

- [ ] **Step 1: Write the test that pins the default**

Add this to `ConversionPlannerTests`, with the two literals set by the decision rules above:

```swift
    @Test func defaultProfileMatchesTheSonyResults() {
        // docs/sony-test-results.md rows 3, 4 (surround) and 6 (HDR).
        #expect(OutputProfile.default == OutputProfile(surround: true, hdr: true))
    }
```

For example, if row 6 showed no HDR indicator, the expectation is `OutputProfile(surround: true, hdr: false)`.

- [ ] **Step 2: Run it**

Run: `scripts/test-core.sh --filter defaultProfileMatchesTheSonyResults`
Expected:
- It fails if the results differ from the current default (`surround: true, hdr: true`).
- If both rules came out `true`, it passes straight away. That's correct: the test still pins the decision.

- [ ] **Step 3: Update the default**

In `ConversionPlan.swift`, set `public static let \`default\` = OutputProfile(surround: …, hdr: …)` to the same two values. Then replace the doc comment above `OutputProfile` with:

```swift
/// What the TV accepts over AirPlay. Receivers can't be queried, so the default comes from
/// the Sony test (docs/sony-test-results.md) and users can override it in Settings.
```

- [ ] **Step 4: Run the whole suite**

Run: `scripts/test-core.sh`
Expected: everything passes. A test that assumed the old default may now fail. If so, give it an explicit `OutputProfile(surround: true, hdr: true)` argument instead of relying on `.default`, because those tests are about the rules, not the default.

- [ ] **Step 5: Record the decisions**

Fill in the six Decisions lines in `docs/sony-test-results.md` using the decision rules.

In the spec:
- Replace the §4.1 sentence beginning "v1 ships one default profile" with: "v1's default profile, from the Sony test, is surround **on/off** and HDR **on/off** (docs/sony-test-results.md), with user overrides in Settings."
- In §10, end the first two risk rows' mitigation cells with "**Resolved:**" followed by the matching lines from the Decisions section. For example: "**Resolved:** surround and HDR pass through; subtitles burned in."

- [ ] **Step 6: Commit**

```bash
git add core/Sources/PaperPlaneCore/Conversion/ConversionPlan.swift core/Tests/PaperPlaneCoreTests/ConversionPlannerTests.swift docs/sony-test-results.md docs/superpowers/specs/2026-10-15-paper-plane-design.md
git commit -m "feat(core): default output profile from the Sony test; record decisions" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Done when

- `scripts/test-core.sh` passes, with only `toneMapsHDRForAnSDRTV()` skipped.
- `python3 -I scripts/check-test-media.py` prints `ok` for every clip.
- `docs/sony-test-results.md` has every Results cell and every Decisions line filled.
- `OutputProfile.default` matches the Sony results.
- The owner has installed Xcode, so Plan 2 can be written and started.
