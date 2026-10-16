# Paper Plane — Plan 2: Local Files on the TV

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish Milestone 1. Dropping a copy-mode MKV on Paper Plane plays it on the Sony over AirPlay, using a bundled ffmpeg, with CI on the owner's GitHub.

**Architecture:**
- `PaperPlaneCore` gains the streaming half, all testable without the app:
  - `Transcoder` runs ffmpeg into a session folder and reports segments. It writes a master playlist that makes the TV start at 0 and tells it what the stream is.
  - `StreamServer` serves that folder on the Mac's LAN address behind a random token (Network.framework).
  - `StreamPipeline` chains probe → plan → transcode → serve.
- A new Xcode app in `app/` is a menu bar icon plus a small remote window. Its `PlaybackController` hands the served URL to `AVPlayer`, holds it paused until the user picks the TV in `AVRoutePickerView`, then plays.
- `scripts/build-ffmpeg.sh` builds the static ffmpeg the app ships.

**Tech Stack:**
- Swift 6 with Swift Testing, Network.framework, AVFoundation / AVKit, SwiftUI `MenuBarExtra`.
- Xcode 27.1 locally. CI uses the default Xcode on GitHub's `macos-26` runners (26.6, Swift 6.2).
- ffmpeg 9.0.2 built from source with dav1d, zimg, libass, freetype, fribidi and harfbuzz.
- Homebrew (meson, ninja, autotools) to build it. Homebrew's ffmpeg makes test media.
- GitHub Actions.

**Spec:** [docs/superpowers/specs/2026-10-15-paper-plane-design.md](../specs/2026-10-15-paper-plane-design.md). The Decisions section of [docs/sony-test-results.md](../../sony-test-results.md) binds this plan too.

**How this plan was checked:** every code block below was compiled and tested in a scratch copy of the repo before the plan was saved.
- 116 tests pass with Homebrew's ffmpeg (one skipped: it needs zimg) and all 116 with the bundled build.
- `scripts/build-ffmpeg.sh` builds in about 2 minutes on the owner's Mac, and `scripts/check-ffmpeg.sh` passes.
- The app builds with Xcode 27.1 without warnings. Opened with a test MKV, it served a master playlist on the LAN address. Quitting mid-conversion stopped ffmpeg and deleted the session folder.
- Only the TV steps (Tasks 9 and 11) are unverified.

## Where this plan fits

| Plan | Covers | Status |
|---|---|---|
| 1 | Repo scaffold, test media, the Sony test (Milestone 0), core probe → plan → ffmpeg-arguments logic | Done |
| **2 (this)** | Rest of Milestone 1: the bundled ffmpeg, `Transcoder`, `StreamServer`, the Xcode app (menu bar, remote window, route picker), basic `PlaybackController`: a dropped file plays on the Sony. Plan 1's review leftovers. CI on the owner's GitHub | Now |
| 3 | Milestone 2: `SegmentWindow` (uses `TranscodeSession.pause()`/`resume()` from this plan), restart-on-seek (uses `Transcoder.start(from:)` and `TranscodeSession.offset`), the remote's seek bar, ±10 s and volume, audio switching, subtitles, Now Playing and media keys, sleep assertion, error handling (including the first-launch explainer and saving redacted ffmpeg logs), Settings overrides, dropping files on the menu bar icon | After Plan 2 |
| 4 | Milestone 3: Chrome/Brave extension, `paperplane-host`, `BrowserBridge` | After Plan 3 |
| 5 | Milestones 4–5: yt-dlp, Paste a link, first release | After Plan 4 |

**Dropping a file on the menu bar icon is deferred to Plan 3.** SwiftUI's `MenuBarExtra` gives no access to its status item, so it can't take drops without reaching into AppKit internals, and that couldn't be verified headlessly. In Plan 2, files arrive by dropping them on the remote window, through **Open Video…** in the menu, or through Finder's **Open With**. That's enough for Milestone 1's "done when".

## Global Constraints

- **Platform:** macOS 14+, Apple Silicon (arm64) only. Use no API newer than macOS 14 without an availability check.
- **Language and tests:**
  - Swift 6 language mode (`swift-tools-version: 6.0`; the app target uses `SWIFT_VERSION = 6.0`).
  - Tests use Swift Testing, run with `scripts/test-core.sh`. Arguments pass through, e.g. `--filter TranscoderTests`.
  - Code must also build with Swift 6.2, the CI default.
- **Branch:** work on `plan-2-local-playback`, created from `main`.
- **Ownership:** this is the owner's personal project.
  - Commits use the repo-local personal identity set in Plan 1 (`git config user.email` prints the personal address).
  - Nothing in the repo names the owner's employer.
  - The GitHub repo lives on the owner's personal account.
- **Commit trailer:** every commit message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **License:** GPL-3.0. The bundled ffmpeg is built with `--enable-gpl --enable-version3` and without x264/x265, which VideoToolbox replaces.
- **ffmpeg:**
  - Tests use whatever `ToolPaths.locate()` finds: `PAPERPLANE_FFMPEG` / `PAPERPLANE_FFPROBE` first, then `PATH`, then Homebrew.
  - The app uses the bundled build in `Contents/Helpers/`, falling back to `locate()` in Debug builds made without `vendor/ffmpeg`.
  - Homebrew's ffmpeg 9.0.2 has no libass or zimg. Its `-color_*` output options override frames that carry no color tags, so tag frames with `setparams` instead (as `scripts/make-test-media.sh` does).
- **HLS output:**
  - ffmpeg writes fMP4 segments, 6 s target, as an EVENT playlist: `index.m3u8`, `init.mp4`, `seg_%05d.m4s`.
  - Paper Plane adds `master.m3u8` with `#EXT-X-START:TIME-OFFSET=0`, `CODECS`, `RESOLUTION`, `FRAME-RATE` and `VIDEO-RANGE`.
  - The player always opens the master playlist.
  - AVFoundation refuses a `VIDEO-RANGE=PQ` variant without `FRAME-RATE`, and refuses HDR video declared as SDR. This was found while verifying this plan.
- **Sony decisions (docs/sony-test-results.md), binding:**
  - The stream server binds to the Mac's LAN address.
  - Playback is held paused until `isExternalPlaybackActive`. Paper Plane never plays on the Mac.
  - The remote window opens with the route picker each time something is opened.
  - Growing playlists start at their beginning (`EXT-X-START`, plus a seek to 0 unless the Task 9 re-test makes it unnecessary).
  - Never wait for AVPlayer's seek `finished` flag during AirPlay.
  - The default profile is surround off, HDR on.
- **Sessions:** each playback writes into `~/Library/Caches/Paper Plane/sessions/<uuid>/`. The folder is deleted when the session stops, and all of `sessions/` is wiped at launch.
- **ffmpeg never outlives its owner:** cancelling a start, stopping a session or quitting the app terminates the child (SIGTERM, then SIGKILL after 5 s). Like `ProcessRunner`, exits are learned from `terminationHandler`, never `waitUntilExit()`.
- **Privacy (spec §5.4):**
  - Error messages and saved logs go through `Redaction.redact`, which removes `Cookie` / `Set-Cookie` / `(Proxy-)Authorization` values, URL user info and query strings.
  - The stream server answers only `/<128-bit token>/<plain file name>`.
  - Stream URLs are logged as private.
- **Identifiers:** the `dev.paperplane` prefix. The app's bundle ID is `dev.paperplane.app`.
- **Spikes:** `spikes/` stays throwaway and is never imported by product code.

## Review Focus

These are inputs or conditions the spec implies but no feature description covers. Each is pinned by tests in the task named.

1. **HDR files.** The Mac's `AVPlayer` reads the playlist before AirPlay hands it to the TV, so a master playlist it refuses means nothing ever reaches the TV. HDR variants need `VIDEO-RANGE=PQ` (or `HLG`) and `FRAME-RATE`. Pinned in Task 4 (`readsFrameRates`, `videoRangeFollowsWhatTheTVGets`), Task 5 (`describesTheStreamAndStartsAtTheBeginning`) and Task 6 (`applesPlayerAcceptsTheMasterPlaylist` with `hevc_hdr10_aac.mkv`, which fails without `FRAME-RATE`).
2. **Replacing or quitting mid-conversion.** A new drop, Stop or Quit while ffmpeg is still converting (or paused) must leave no ffmpeg running and no session folder behind. Pinned in Task 6 (`cancellingTheStartStopsFFmpegAndDeletesTheFolder`, `stopEndsAPausedSessionAndDeletesTheFolder`), Task 8 (`cancellingTheStartLeavesNothingBehind`) and Task 10's quit check.
3. **Network trouble.** The Mac is offline, on a VPN, has only a self-assigned 169.254 address, or its IP changes between lookup and binding. Paper Plane must pick an address the TV can reach, or fail at once with a clear message, never hang. Pinned in Task 7 (`prefersEn0AndSkipsAddressesATVCannotReach`, `refusesAnAddressThisMacDoesNotHave`; the second hung before `.waiting` was treated as failure) and Task 10's offline message.
4. **Things that aren't videos.** Folders, subtitles, audio, images and half-downloaded `.mkv.part` files dropped on the remote or opened with the app. They must be refused with a message, not sent to ffprobe. Pinned in Task 8 (`rejectsEverythingElse`, `rejectsFoldersAndWebURLs`) and Task 10 (`play(_:)`).
5. **Very short videos.** A clip shorter than two segments must still start, not wait forever for a second segment. Pinned in Task 6 (`shortVideoIsReadyWithOneSegment`); every test clip is 10 s, so `masterPlaylistDescribesTheOutput` also exercises it.

## File Map

| File | Responsibility | Task |
|---|---|---|
| `core/Tests/PaperPlaneCoreTests/TestSupport.swift`, `PipelineTests.swift` | Plan 1 leftovers: async filter check, default-profile cases; AVPlayer acceptance helper | 1, 6 |
| `core/Sources/PaperPlaneCore/Support/Redaction.swift` | Strips cookies, auth headers, URL user info and queries | 2 |
| `scripts/build-ffmpeg.sh`, `scripts/check-ffmpeg.sh` | Builds and checks the bundled static ffmpeg | 3 |
| `.gitignore`, `README.md` | Ignore `vendor/` and `build/`; development steps | 3, 10 |
| `core/Sources/PaperPlaneCore/Media/MediaInfo.swift`, `FFprobeParser.swift` | Video frame rate | 4 |
| `core/Sources/PaperPlaneCore/Conversion/ConversionPlan.swift`, `ConversionPlanner.swift` | `VideoRange` and frame rate of the output | 4 |
| `core/Sources/PaperPlaneCore/Streaming/MediaPlaylist.swift` | Reads ffmpeg's `index.m3u8` | 5 |
| `core/Sources/PaperPlaneCore/Streaming/InitSegment.swift` | Codec strings and size from `init.mp4` | 5 |
| `core/Sources/PaperPlaneCore/Streaming/MasterPlaylist.swift` | Writes `master.m3u8` | 5 |
| `core/Sources/PaperPlaneCore/Streaming/SessionFolders.swift` | `~/Library/Caches/Paper Plane/sessions/` | 6 |
| `core/Sources/PaperPlaneCore/Support/BackgroundProcess.swift` | A long-running child: await exit, signals, stderr tail | 6 |
| `core/Sources/PaperPlaneCore/Streaming/Transcoder.swift` | `Transcoder`, `TranscodeSession`, events, session offset | 6 |
| `core/Sources/PaperPlaneCore/Serving/FileResponder.swift` | HTTP request → response for one session folder | 7 |
| `core/Sources/PaperPlaneCore/Serving/StreamServer.swift` | Network.framework listener | 7 |
| `core/Sources/PaperPlaneCore/Serving/LANAddress.swift` | The Mac's LAN IPv4 address | 7 |
| `core/Sources/PaperPlaneCore/Playback/StreamPipeline.swift` | Probe → plan → transcode → serve; `ServedStream` | 8 |
| `core/Sources/PaperPlaneCore/Playback/VideoFiles.swift` | Which files to accept | 8 |
| `core/Sources/PaperPlaneCore/Support/ToolPaths.swift` | `inBundle(at:)` | 8 |
| `core/Tests/PaperPlaneCoreTests/*` | One test file per area, named after it | 1–8 |
| `spikes/sony-test/make-retest-playlists.sh`, `spikes/sony-test/main.swift` | Re-test streams R1–R4 | 9 |
| `docs/sony-test-results.md` | Re-test and first-playback results | 9, 11 |
| `app/PaperPlane.xcodeproj/…`, `app/PaperPlane-Info.plist`, `scripts/embed-ffmpeg.sh` | Xcode project, Info.plist, ffmpeg embedding | 10 |
| `app/PaperPlane/*.swift` | App, menu, remote window, route picker, `PlaybackController` | 10 |
| `docs/superpowers/specs/2026-10-15-paper-plane-design.md` | §4 step 5, §9 and §10 brought up to date | 5, 9, 10 |
| `.github/workflows/ci.yml` | CI | 12 |

---

### Task 1: Plan 1's test leftovers

Plan 1's final review left two test gaps. `TestSupport` still detects ffmpeg filters with `waitUntilExit()`, which can deadlock on the main thread (see `ProcessRunner`). And no pipeline case covers the default profile's surround downmix.

**Files:**
- Modify: `core/Tests/PaperPlaneCoreTests/TestSupport.swift` (replace `ffmpegHasFilter` and `filterList`)
- Modify: `core/Tests/PaperPlaneCoreTests/PipelineTests.swift` (two cases; the tone-map test's trait)

**Interfaces:**
- Consumes: `ProcessRunner.run(_:arguments:)` (Plan 1).
- Produces: `TestSupport.ffmpegHasFilter(_ name: String) async -> Bool`, for use in an async `.enabled` trait.

- [ ] **Step 1: Start the branch and check the identity**

```bash
git switch main
git switch -c plan-2-local-playback
git config user.email
```

Expected: the last command prints the owner's personal address, not a work address. If it prints anything else, stop and ask the owner.

- [ ] **Step 2: Run the pipeline tests as they are**

Run: `scripts/test-core.sh --filter PaperPlaneCoreTests.PipelineTests`
Expected: `✔ Test run with 4 tests in 1 suite passed`. With Homebrew's ffmpeg, `toneMapsHDRForAnSDRTV()` is skipped with "Needs an ffmpeg built with zimg (zscale)".

- [ ] **Step 3: Check filters with `ProcessRunner`**

In `TestSupport.swift`, replace everything from `/// Whether the installed ffmpeg has a filter` to the end of the `filterList` property with:

```swift
    /// Whether the ffmpeg under test has a filter, e.g. `zscale` (needed for HDR → SDR tone mapping).
    static func ffmpegHasFilter(_ name: String) async -> Bool {
        guard let tools,
              let result = try? await ProcessRunner.run(tools.ffmpeg, arguments: ["-hide_banner", "-filters"])
        else { return false }
        return String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").contains { line in
            line.split(separator: " ").dropFirst().first == Substring(name)
        }
    }
```

In `PipelineTests.swift`, the condition is now async, so change the tone-map test's trait to the closure form:

```swift
    @Test(.enabled("Needs an ffmpeg built with zimg (zscale)") { await TestSupport.ffmpegHasFilter("zscale") })
    func toneMapsHDRForAnSDRTV() async throws {
```

- [ ] **Step 4: Add the default-profile cases**

In `PipelineTests.cases`, after the `hevc_hdr10_aac.mkv` case that uses `profile: .default`, add:

```swift
        // With the default profile (surround off), 7.1 lossless audio and DTS both become stereo AAC.
        Case(file: "h264_flac_71.mkv", profile: .default, video: .h264, audio: .aac, channels: 2),
        Case(file: "mpeg2_dts_51.mkv", profile: .default, video: .h264, audio: .aac, channels: 2),
```

- [ ] **Step 5: Run the pipeline tests again**

Run: `scripts/test-core.sh --filter PaperPlaneCoreTests.PipelineTests`
Expected:
- `convertsToPlayableHLS(_:) with 17 test cases passed`.
- `toneMapsHDRForAnSDRTV()` is still skipped with Homebrew's ffmpeg.

The new cases pass straight away. That's expected: they pin behaviour Plan 1 left untested. If the skip message is missing and the test fails instead, the async trait isn't being awaited; check Step 3.

- [ ] **Step 6: Commit**

```bash
git add core/Tests/PaperPlaneCoreTests/TestSupport.swift core/Tests/PaperPlaneCoreTests/PipelineTests.swift
git commit -m "test(core): check ffmpeg filters with ProcessRunner; default-profile surround cases" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Redaction for saved logs

Plan 3 saves ffmpeg's log for bug reports (spec §6). Before any log is saved or shown, the redaction must cover more than query strings. At higher log levels, ffmpeg prints request headers and the `-headers` option value. URLs can also carry a user name and password.

**Files:**
- Modify: `core/Sources/PaperPlaneCore/Support/Redaction.swift`
- Test: `core/Tests/PaperPlaneCoreTests/RedactionTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Redaction.redact(_ text: String) -> String`. `Redaction.summary(of:)` now applies it. `Redaction.redactQueries(_:)` is unchanged.

- [ ] **Step 1: Write the failing tests**

Replace `core/Tests/PaperPlaneCoreTests/RedactionTests.swift` with:

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

    /// What ffmpeg prints at higher log levels for a web stream with `-headers`.
    static let webLog = """
        Reading option '-headers' ... matched as AVOption 'headers' with argument 'Cookie: sid=SECRET1; theme=dark
        Referer: https://example.com/watch
        '.
        [https @ 0x1] request: GET /v/master.m3u8 HTTP/1.1
        authorization: Bearer SECRET2
        Proxy-Authorization: Basic SECRET3
        [https @ 0x1] header: Set-Cookie: edge=SECRET4; Path=/; HttpOnly
        """

    @Test func removesCookieAndAuthorizationValues() {
        let redacted = Redaction.redact(Self.webLog)
        for secret in ["SECRET1", "SECRET2", "SECRET3", "SECRET4"] {
            #expect(!redacted.contains(secret), "\(secret) leaked")
        }
        #expect(redacted.contains("argument 'Cookie: …"))
        #expect(redacted.contains("authorization: …"))
        #expect(redacted.contains("Proxy-Authorization: …"))
        #expect(redacted.contains("header: Set-Cookie: …"))
        #expect(redacted.contains("Referer: https://example.com/watch"))
    }

    @Test func removesUserNamesAndPasswordsFromURLs() {
        #expect(Redaction.redact("Opening 'https://alice:hunter2@cdn.example.com/v.m3u8' for reading")
            == "Opening 'https://…@cdn.example.com/v.m3u8' for reading")
        #expect(Redaction.redact("rtmp://user@live.example.com/app") == "rtmp://…@live.example.com/app")
    }

    @Test func leavesOrdinaryTextAlone() {
        let text = "[h264 @ 0x2] Invalid NAL unit size (1234 > 567)\nError while decoding stream #0:0"
        #expect(Redaction.redact(text) == text)
    }

    @Test func summaryRedactsHeaders() {
        let summary = Redaction.summary(of: Data(Self.webLog.utf8))
        #expect(!summary.contains("SECRET"))
    }
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `scripts/test-core.sh --filter RedactionTests`
Expected: the build fails with `type 'Redaction' has no member 'redact'`.

- [ ] **Step 3: Implement `redact`**

Replace `core/Sources/PaperPlaneCore/Support/Redaction.swift` with:

```swift
import Foundation

/// Keeps secrets out of error messages and logs.
enum Redaction {
    /// Replaces URL query strings, which often carry access tokens, with `?…`.
    static func redactQueries(_ text: String) -> String {
        text.replacing(/\?[^\s'"]+/, with: "?…")
    }

    /// Everything that must go before ffmpeg output is shown or saved: the values of cookie and
    /// authorization headers, user names and passwords in URLs, and URL query strings.
    static func redact(_ text: String) -> String {
        let headers = text.replacing(/(?i)\b(set-cookie|cookie|proxy-authorization|authorization)\s*:[^\r\n]*/) {
            "\($0.1): …"
        }
        let userInfo = headers.replacing(#/([A-Za-z][A-Za-z0-9+.\-]*://)[^/\s@'"]+@/#) { "\($0.1)…@" }
        return redactQueries(userInfo)
    }

    /// The last 20 non-empty lines of a tool's stderr, redacted, for error messages.
    static func summary(of stderr: Data) -> String {
        let lines = String(decoding: stderr, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        return redact(lines.suffix(20).joined(separator: "\n"))
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test-core.sh --filter RedactionTests`
Expected: `✔ Test run with 6 tests in 1 suite passed`.

- [ ] **Step 5: Commit**

```bash
git add core/Sources/PaperPlaneCore/Support/Redaction.swift core/Tests/PaperPlaneCoreTests/RedactionTests.swift
git commit -m "feat(core): redact cookie and authorization headers and URL user info" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: The bundled ffmpeg

The app ships its own static ffmpeg and ffprobe (spec §9), so it works on any Mac and has what Homebrew's build lacks: libass for subtitle burn-in, and zimg for "Convert HDR to SDR".

**Files:**
- Create: `scripts/check-ffmpeg.sh` (the test for this task), `scripts/build-ffmpeg.sh`
- Modify: `.gitignore`, `README.md`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `vendor/ffmpeg/bin/ffmpeg`, `vendor/ffmpeg/bin/ffprobe` and `vendor/ffmpeg/BUILDINFO` (git-ignored). Task 10 embeds them in the app; Task 12 builds them in CI.
  - `scripts/check-ffmpeg.sh [bin dir]`, which exits non-zero naming each failed check.

What the build needs to get right, all checked by the script:
- **Only system libraries.** Homebrew's pkg-config would otherwise pull in Homebrew dylibs. So `PKG_CONFIG_LIBDIR` points only at the static libraries built here, and `--disable-autodetect` turns off everything not asked for.
- **Apple's libtool.** On the owner's Mac, an Anaconda `libtool` comes first on `PATH`, so the script puts `/usr/bin` first.
- **No HVF.** freetype 2.15 links `/usr/lib/libhvf.dylib` when it finds it, and macOS 14 may not have it, so `-Dhvf=disabled`. The first verification build caught this.
- **Re-signing.** `strip` removes the linker's ad-hoc signature, and arm64 refuses to run unsigned code, so the binaries are signed again.

- [ ] **Step 1: Install the build tools**

```bash
brew install meson ninja autoconf automake libtool pkgconf
```

- [ ] **Step 2: Write the checker**

`scripts/check-ffmpeg.sh` (then `chmod +x scripts/check-ffmpeg.sh`):

```bash
#!/usr/bin/env bash
# Checks the ffmpeg and ffprobe that Paper Plane bundles (scripts/build-ffmpeg.sh): arm64,
# macOS 14+, only system libraries linked, and every feature the app relies on present.
# Usage: scripts/check-ffmpeg.sh [bin directory, default vendor/ffmpeg/bin]
set -uo pipefail
BIN="${1:-$(dirname "$0")/../vendor/ffmpeg/bin}"
FAILURES=0

check() { # check <description> <command...>: runs the command, prints ok/FAIL
  local description=$1
  shift
  if "$@" >/dev/null 2>&1; then
    echo "ok      $description"
  else
    echo "FAIL    $description"
    FAILURES=$((FAILURES + 1))
  fi
}

# Libraries every Mac since macOS 14 has. Anything else (Homebrew, @rpath, newer system
# libraries) would make the app fail to launch somewhere.
ALLOWED_LIBS='^(/System/Library/Frameworks/[A-Za-z]+\.framework/|/usr/lib/lib(System\.B|z\.1|iconv\.2|bz2\.1\.0|c\+\+\.1)\.dylib$)'

# Outputs are captured first: grep -q exiting early would SIGPIPE the tool and, with
# pipefail, turn a match into a failure.
only_system_libraries() {
  local libs
  libs="$(otool -L "$1" | sed 1d | awk '{print $1}')" || return 1
  ! grep -Ev "$ALLOWED_LIBS" <<<"$libs"
}
minimum_macos_14() {
  local commands
  commands="$(otool -l "$1")" || return 1
  [[ "$(awk '/LC_BUILD_VERSION/{found=1} found && /minos/{print $2; exit}' <<<"$commands")" == 14.0 ]]
}
ENCODERS="$("$BIN/ffmpeg" -hide_banner -encoders 2>/dev/null)"
DECODERS="$("$BIN/ffmpeg" -hide_banner -decoders 2>/dev/null)"
FILTERS="$("$BIN/ffmpeg" -hide_banner -filters 2>/dev/null)"
PROTOCOLS="$("$BIN/ffmpeg" -hide_banner -protocols 2>/dev/null)"
BUILDCONF="$("$BIN/ffmpeg" -hide_banner -buildconf 2>/dev/null)"
codec() { grep -Eq "^ [A-Z.]{6} $2 " <<<"$1"; }
filter() { grep -Eq "^ [A-Z.]{2,3} $1 " <<<"$FILTERS"; }
protocol() { grep -Eqx "  $1" <<<"$PROTOCOLS"; }
not() { ! "$@"; }
configured() { grep -Eq -- "$1\$" <<<"$BUILDCONF"; }

for tool in ffmpeg ffprobe; do
  check "$tool exists" test -x "$BIN/$tool"
  check "$tool is arm64 only" test "$(lipo -archs "$BIN/$tool" 2>/dev/null)" = arm64
  check "$tool runs on macOS 14" minimum_macos_14 "$BIN/$tool"
  check "$tool links only system libraries" only_system_libraries "$BIN/$tool"
  check "$tool is signed" codesign --verify "$BIN/$tool"
done
check "GPL v3 build" configured "--enable-version3"
check "H.264 VideoToolbox encoder" codec "$ENCODERS" h264_videotoolbox
check "HEVC VideoToolbox encoder" codec "$ENCODERS" hevc_videotoolbox
check "AAC encoder" codec "$ENCODERS" aac
check "E-AC3 encoder" codec "$ENCODERS" eac3
check "no libx264" not codec "$ENCODERS" libx264
check "no libx265" not codec "$ENCODERS" libx265
check "dav1d AV1 decoder" codec "$DECODERS" libdav1d
check "PGS subtitle decoder" codec "$DECODERS" pgssub
check "subtitles filter (libass)" filter subtitles
check "zscale filter (zimg)" filter zscale
check "tonemap filter" filter tonemap
check "https protocol" protocol https

if ((FAILURES)); then
  echo "$FAILURES check(s) failed" >&2
  exit 1
fi
echo "All checks passed for $BIN"
```

- [ ] **Step 3: Run it and watch it fail**

Run: `scripts/check-ffmpeg.sh; scripts/check-ffmpeg.sh /opt/homebrew/bin | grep FAIL`
Expected:
- The first command fails: `FAIL    ffmpeg exists`, along with every check that needs the binary, because nothing has been built yet.
- The second shows the checker catching a wrong build. Homebrew's ffmpeg fails "runs on macOS 14", "links only system libraries", "no libx264", "no libx265", "subtitles filter (libass)" and "zscale filter (zimg)".

- [ ] **Step 4: Write the build script**

`scripts/build-ffmpeg.sh` (then `chmod +x scripts/build-ffmpeg.sh`):

```bash
#!/usr/bin/env bash
# Builds the ffmpeg and ffprobe that ship inside Paper Plane: static, arm64, macOS 14+.
#
# Enabled: VideoToolbox and AudioToolbox, libass (with freetype, fribidi and harfbuzz) for
# subtitle burn-in, libdav1d for AV1, zimg for zscale (HDR → SDR), Secure Transport for https.
# No x264/x265: Paper Plane encodes with VideoToolbox. Licensed GPL-3.0 (--enable-gpl
# --enable-version3), matching the app.
#
# Needs: brew install meson ninja autoconf automake libtool pkgconf
# Output: vendor/ffmpeg/bin/{ffmpeg,ffprobe} and vendor/ffmpeg/BUILDINFO
# Work files (downloads, build trees) go to vendor/ffmpeg-build/; delete it to start clean.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/vendor/ffmpeg-build"
DEPS="$WORK/deps"
OUT="$ROOT/vendor/ffmpeg"
JOBS="$(sysctl -n hw.ncpu)"

# name version url sha256
SOURCES=(
  "ffmpeg 9.0.2 https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz 8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"
  "dav1d 1.5.4 https://downloads.videolan.org/pub/videolan/dav1d/1.5.4/dav1d-1.5.4.tar.xz 686616b7c69eb88d44459391ab25cac13b6647a3b288835c5784e71c1514a5c5"
  "zimg 3.0.6 https://github.com/sekrit-twc/zimg/archive/refs/tags/release-3.0.6.tar.gz be89390f13a5c9b2388ce0f44a5e89364a20c1c57ce46d382b1fcc3967057577"
  "freetype 2.15.0 https://download.savannah.gnu.org/releases/freetype/freetype-2.15.0.tar.xz 93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5"
  "fribidi 1.0.17 https://github.com/fribidi/fribidi/releases/download/v1.0.17/fribidi-1.0.17.tar.xz 6949dcde27d41cebad1fd741fcafc36d55a1020d2d872d4a6eb3914caabbada2"
  "harfbuzz 14.6.0 https://github.com/harfbuzz/harfbuzz/releases/download/14.6.0/harfbuzz-14.6.0.tar.xz d07a007327277708a2a73ae437887cdbaf282937f6d03ca5467723e9099af586"
  "libass 0.17.5 https://github.com/libass/libass/releases/download/0.17.5/libass-0.17.5.tar.xz 2dca25c0e0c837ddf00b52011b3f82cac1e4ddd3ad018227806b0c2288864acc"
)

for tool in meson ninja autoreconf glibtoolize pkg-config; do
  command -v "$tool" >/dev/null || { echo "Missing $tool. Run: brew install meson ninja autoconf automake libtool pkgconf" >&2; exit 1; }
done

# A clean environment: Apple's clang and libtool first, Homebrew only for build tools, and
# pkg-config limited to the static libraries built here, so nothing from Homebrew is linked.
BREW_BIN="$(dirname "$(command -v meson)")"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$BREW_BIN"
export LIBTOOLIZE=glibtoolize
export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig"
export PKG_CONFIG_PATH=""
export MACOSX_DEPLOYMENT_TARGET=14.0
export CC=clang CXX=clang++
export CFLAGS="-arch arm64 -mmacosx-version-min=14.0 -O2"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-arch arm64 -mmacosx-version-min=14.0"
unset CPATH LIBRARY_PATH

mkdir -p "$WORK/downloads" "$WORK/src" "$DEPS"

source_dir() { # source_dir <name> → prints the unpacked source directory, downloading if needed
  local entry name version url sha file dir
  for entry in "${SOURCES[@]}"; do
    read -r name version url sha <<<"$entry"
    [[ $name == "$1" ]] || continue
    file="$WORK/downloads/$name-$version.tar.${url##*.}"
    if [[ ! -f $file ]]; then
      echo "== downloading $name $version" >&2
      curl -fsSL --retry 3 -o "$file.part" "$url"
      mv "$file.part" "$file"
    fi
    if ! echo "$sha  $file" | shasum -a 256 -c --status; then
      echo "Checksum mismatch for $file" >&2
      exit 1
    fi
    dir="$WORK/src/$name-$version"
    if [[ ! -d $dir ]]; then
      mkdir -p "$dir"
      tar -xf "$file" -C "$dir" --strip-components 1
    fi
    echo "$dir"
    return
  done
  echo "Unknown source $1" >&2
  exit 1
}

meson_build() { # meson_build <name> <meson options...>
  local name=$1 dir
  shift
  dir="$(source_dir "$name")"
  echo "== building $name" >&2
  rm -rf "$dir/build"
  meson setup "$dir/build" "$dir" --prefix="$DEPS" --libdir=lib --buildtype=release \
    -Ddefault_library=static "$@" >"$dir/build.log" 2>&1 || { tail -40 "$dir/build.log" >&2; exit 1; }
  ninja -C "$dir/build" install >>"$dir/build.log" 2>&1 || { tail -40 "$dir/build.log" >&2; exit 1; }
}

meson_build dav1d -Denable_tools=false -Denable_tests=false -Denable_examples=false -Denable_docs=false
meson_build freetype -Dzlib=system -Dbzip2=disabled -Dpng=disabled -Dharfbuzz=disabled -Dbrotli=disabled -Dhvf=disabled \
  -Dtests=disabled
meson_build fribidi -Ddocs=false -Dbin=false -Dtests=false
meson_build harfbuzz -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled -Dchafa=disabled \
  -Dpng=disabled -Dzlib=disabled -Dicu=disabled -Draster=disabled -Dvector=disabled -Dgpu=disabled \
  -Dsubset=disabled -Dtests=disabled -Dintrospection=disabled -Ddocs=disabled -Dutilities=disabled
meson_build libass -Dfontconfig=disabled -Dcoretext=enabled -Ddirectwrite=disabled -Dlibunibreak=disabled \
  -Dtest=disabled -Dcompare=disabled -Dprofile=disabled -Dfuzz=disabled -Dcheckasm=disabled

ZIMG="$(source_dir zimg)"
echo "== building zimg" >&2
(
  cd "$ZIMG"
  { ./autogen.sh && ./configure --prefix="$DEPS" --disable-shared --enable-static && make -j"$JOBS" install; } \
    >build.log 2>&1 || { tail -40 build.log >&2; exit 1; }
)

FFMPEG="$(source_dir ffmpeg)"
echo "== building ffmpeg" >&2
FFMPEG_CONFIGURE=(
  --prefix="$WORK/ffmpeg-install"
  --arch=arm64 --target-os=darwin --cc=clang --cxx=clang++
  --enable-gpl --enable-version3
  --disable-shared --enable-static --pkg-config-flags=--static
  --disable-autodetect --enable-pthreads --enable-zlib --enable-bzlib --enable-iconv
  --enable-videotoolbox --enable-audiotoolbox --enable-securetransport
  --enable-libass --enable-libdav1d --enable-libzimg
  --disable-ffplay --disable-doc --disable-debug
  --extra-cflags="-mmacosx-version-min=14.0" --extra-ldflags="-mmacosx-version-min=14.0" --extra-libs=-lc++
)
(
  cd "$FFMPEG"
  { make distclean >/dev/null 2>&1 || true; } # stale state from an earlier run
  { ./configure "${FFMPEG_CONFIGURE[@]}" && make -j"$JOBS" && make install; } \
    >build.log 2>&1 || { tail -40 ffbuild/config.log build.log >&2; exit 1; }
)

rm -rf "$OUT"
mkdir -p "$OUT/bin"
for tool in ffmpeg ffprobe; do
  cp "$WORK/ffmpeg-install/bin/$tool" "$OUT/bin/$tool"
  strip -x "$OUT/bin/$tool"
  codesign --force --sign - "$OUT/bin/$tool" # strip removes the linker's ad-hoc signature
done
{
  echo "Built $(date -u +%Y-%m-%dT%H:%M:%SZ) by scripts/build-ffmpeg.sh"
  printf '%s\n' "${SOURCES[@]}" | awk '{print $1, $2, $3}'
  echo "configure ${FFMPEG_CONFIGURE[*]}"
} >"$OUT/BUILDINFO"
echo "Built $OUT/bin/ffmpeg and $OUT/bin/ffprobe"
```

- [ ] **Step 5: Ignore the build output**

Replace `.gitignore` with:

```gitignore
.DS_Store
xcuserdata/
DerivedData/

# Swift package and app build output
/core/.build/
/core/.swiftpm/
/build/

# Bundled ffmpeg (scripts/build-ffmpeg.sh)
/vendor/

# Generated test clips (scripts/make-test-media.sh)
/testdata/media/

# Sony test spike output
/spikes/sony-test/build/
/spikes/sony-test/streams/

# Browser extension (later plans)
/extension/node_modules/
/extension/dist/
```

- [ ] **Step 6: Build and check**

```bash
scripts/build-ffmpeg.sh
scripts/check-ffmpeg.sh
```

Expected:
- The build prints `== building dav1d` … `== building ffmpeg`, then `Built …/vendor/ffmpeg/bin/ffmpeg and …/ffprobe`. It takes about 2 minutes on 18 cores, and up to 15 on a CI runner.
- The checker ends with `All checks passed for …`.
- If a step fails, the script prints the last 40 lines of that step's log. The full log is in `vendor/ffmpeg-build/src/<name>-<version>/build.log` (ffmpeg's configure log is `ffbuild/config.log` there).

- [ ] **Step 7: Run the core tests against the bundled build**

```bash
PAPERPLANE_FFMPEG="$PWD/vendor/ffmpeg/bin/ffmpeg" PAPERPLANE_FFPROBE="$PWD/vendor/ffmpeg/bin/ffprobe" scripts/test-core.sh
```

Expected: everything passes, and this time nothing is skipped. `toneMapsHDRForAnSDRTV()` runs because the bundled build has zimg.

- [ ] **Step 8: Document it**

In `README.md`, replace the `## Development` section with:

````markdown
## Development

You need macOS 14 or later on Apple Silicon, Swift 6 and Homebrew.

```bash
brew install ffmpeg            # development and tests only
scripts/make-test-media.sh     # generates test clips into testdata/media/
scripts/test-core.sh           # runs the PaperPlaneCore tests

brew install meson ninja autoconf automake libtool pkgconf
scripts/build-ffmpeg.sh        # builds the ffmpeg the app ships into vendor/ffmpeg/ (a few minutes)
scripts/check-ffmpeg.sh        # checks that build
```
````

- [ ] **Step 9: Commit**

```bash
git add scripts/build-ffmpeg.sh scripts/check-ffmpeg.sh .gitignore README.md
git commit -m "build: static arm64 ffmpeg with VideoToolbox, libass, dav1d and zimg" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: The plan knows the output's video range and frame rate

The master playlist in Task 5 must say whether the video is SDR, PQ (HDR10) or HLG, and give its frame rate. While this plan was being verified, AVFoundation refused every HDR master playlist without `FRAME-RATE`, and every HDR stream declared as SDR. The planner already knows the first; ffprobe knows the second.

**Files:**
- Modify: `core/Sources/PaperPlaneCore/Media/MediaInfo.swift`, `core/Sources/PaperPlaneCore/Media/FFprobeParser.swift`
- Modify: `core/Sources/PaperPlaneCore/Conversion/ConversionPlan.swift`, `core/Sources/PaperPlaneCore/Conversion/ConversionPlanner.swift`
- Test: `core/Tests/PaperPlaneCoreTests/FFprobeParserTests.swift`, `core/Tests/PaperPlaneCoreTests/ConversionPlannerTests.swift`

**Interfaces:**
- Consumes: `VideoTrack`, `HDRFormat`, `VideoAction`, `VideoEncode.keepHDR` (Plan 1).
- Produces:
  - `VideoTrack.frameRate: Double?` (default `nil`, so existing initializers still compile).
  - `public enum VideoRange: String { case sdr = "SDR", pq = "PQ", hlg = "HLG" }` with an internal `init(_ hdr: HDRFormat?)`.
  - `ConversionPlan.videoRange: VideoRange` (default `.sdr`) and `ConversionPlan.frameRate: Double?` (default `nil`), set by `ConversionPlanner.plan`.

- [ ] **Step 1: Write the failing tests**

In `FFprobeParserTests`, add before `parsesTracksAndSkipsCoverArt()`:

```swift
    @Test func readsFrameRates() throws {
        let json = """
            {"streams": [
              {"index": 0, "codec_type": "video", "codec_name": "h264", "avg_frame_rate": "24000/1001", "r_frame_rate": "24/1"},
              {"index": 1, "codec_type": "video", "codec_name": "h264", "avg_frame_rate": "0/0", "r_frame_rate": "25/1"},
              {"index": 2, "codec_type": "video", "codec_name": "h264", "avg_frame_rate": "0/0", "r_frame_rate": "0/0"}
            ]}
            """
        let rates = try FFprobeParser.parse(Data(json.utf8)).video.map(\.frameRate)
        #expect(rates == [24000.0 / 1001, 25, nil])
    }
```

In `ConversionPlannerTests`, add before `noVideoTrackThrows()`:

```swift
    @Test func videoRangeFollowsWhatTheTVGets() throws {
        let hdr10 = Self.video(.hevc, height: 2160, pixelFormat: "yuv420p10le", hdr: .pq)
        let hlg = Self.video(.other("av1"), height: 2160, pixelFormat: "yuv420p10le", hdr: .hlg)
        #expect(try ConversionPlanner.plan(Self.media([hdr10], []), profile: Self.surroundAndHDR).videoRange == .pq)
        #expect(try ConversionPlanner.plan(Self.media([hlg], []), profile: Self.surroundAndHDR).videoRange == .hlg)
        #expect(try ConversionPlanner.plan(Self.media([hdr10], []), profile: Self.noSurroundNoHDR).videoRange == .sdr)
        #expect(try ConversionPlanner.plan(Self.media([Self.video(.h264)], [])).videoRange == .sdr)
    }

    @Test func keepsTheFrameRateForTheMasterPlaylist() throws {
        var track = Self.video(.other("vp9"))
        track.frameRate = 50
        #expect(try ConversionPlanner.plan(Self.media([track], [])).frameRate == 50)
    }
```

- [ ] **Step 2: Run them and watch them fail**

Run: `scripts/test-core.sh --filter 'FFprobeParserTests|ConversionPlannerTests'`
Expected: the build fails with `value of type 'VideoTrack' has no member 'frameRate'` and `value of type 'ConversionPlan' has no member 'videoRange'`.

- [ ] **Step 3: Read the frame rate**

In `MediaInfo.swift`, add a last property to `VideoTrack`:

```swift
    /// Frames per second, from ffprobe's `avg_frame_rate` (or `r_frame_rate`). nil when unknown.
    public var frameRate: Double? = nil
```

In `FFprobeParser.swift`, make three changes:

1. In `Output.Stream`, add these properties after `colorTransfer`:

```swift
            var avgFrameRate: String?
            var rFrameRate: String?
```

2. In its `CodingKeys`, add these after `case colorTransfer = "color_transfer"`:

```swift
                case avgFrameRate = "avg_frame_rate"
                case rFrameRate = "r_frame_rate"
```

3. In `parse`, the `VideoTrack(…)` call ends with `hdr: HDRFormat(colorTransfer: stream.colorTransfer)))`. Replace that last line with:

```swift
                    hdr: HDRFormat(colorTransfer: stream.colorTransfer),
                    frameRate: frameRate(stream.avgFrameRate) ?? frameRate(stream.rFrameRate)))
```

Then add this helper before `language(_:)`:

```swift
    /// ffprobe writes rates as fractions: `24000/1001`, or `0/0` when it doesn't know.
    private static func frameRate(_ fraction: String?) -> Double? {
        guard let parts = fraction?.split(separator: "/"), parts.count == 2,
              let numerator = Double(parts[0]), let denominator = Double(parts[1]),
              numerator > 0, denominator > 0
        else { return nil }
        return numerator / denominator
    }
```

- [ ] **Step 4: Carry range and rate in the plan**

In `ConversionPlan.swift`, add this before `ConversionPlan`:

```swift
/// The brightness range of the output video, for the HLS master playlist's `VIDEO-RANGE`.
public enum VideoRange: String, Equatable, Sendable {
    case sdr = "SDR"
    case pq = "PQ"
    case hlg = "HLG"

    init(_ hdr: HDRFormat?) {
        switch hdr {
        case .pq: self = .pq
        case .hlg: self = .hlg
        case nil: self = .sdr
        }
    }
}
```

Then add two last properties to `ConversionPlan`:

```swift
    /// What the converted video is: HDR stays HDR unless it's tone-mapped.
    public var videoRange: VideoRange = .sdr
    /// The video's frames per second, which conversion keeps. nil when unknown.
    public var frameRate: Double? = nil
```

In `ConversionPlanner.swift`, replace the `return ConversionPlan(…)` statement in `plan(_:choice:profile:)` with:

```swift
        let action = videoAction(for: video, profile: profile)
        return ConversionPlan(
            video: video.ref,
            videoAction: action,
            audio: audio?.ref,
            audioAction: audio.map { audioAction(for: $0, profile: profile) },
            videoRange: videoRange(of: video, after: action),
            frameRate: video.frameRate)
```

Then add this before `bitrate(height:encoder:)`:

```swift
    static func videoRange(of track: VideoTrack, after action: VideoAction) -> VideoRange {
        switch action {
        case .copy: VideoRange(track.hdr)
        case .encode(let encode): VideoRange(encode.keepHDR)
        }
    }
```

- [ ] **Step 5: Run the tests**

Run: `scripts/test-core.sh --filter 'FFprobeParserTests|ConversionPlannerTests'`
Expected: `✔ Test run with 25 tests in 2 suites passed`.

Then run `scripts/test-core.sh`. Expected: everything passes, with only `toneMapsHDRForAnSDRTV()` skipped (Homebrew's ffmpeg).

- [ ] **Step 6: Commit**

```bash
git add core/Sources/PaperPlaneCore/Media core/Sources/PaperPlaneCore/Conversion core/Tests/PaperPlaneCoreTests/FFprobeParserTests.swift core/Tests/PaperPlaneCoreTests/ConversionPlannerTests.swift
git commit -m "feat(core): plans carry the output's video range and frame rate" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Reading and writing HLS playlists

Three small, pure pieces for Task 6:
- **`MediaPlaylist`** reads ffmpeg's growing `index.m3u8`, to know which segments exist.
- **`InitSegment`** reads `init.mp4` for the codec strings (`avc1.640028`, `hvc1.2.4.L150.90`, `mp4a.40.2`, `ac-3`, `ec-3`) and the video size. ffmpeg's own master playlist leaves `CODECS` out for HEVC, so it can't be reused.
- **`MasterPlaylist`** writes `master.m3u8`, which carries:
  - `#EXT-X-START:TIME-OFFSET=0`. Sony row 7a showed growing playlists start at the live edge. On the Mac, AVPlayer started at 0 with this tag in a master playlist, and near the live edge without it.
  - `CODECS`, `RESOLUTION`, `FRAME-RATE` and `VIDEO-RANGE`.

**Files:**
- Create: `core/Sources/PaperPlaneCore/Streaming/MediaPlaylist.swift`, `core/Sources/PaperPlaneCore/Streaming/InitSegment.swift`, `core/Sources/PaperPlaneCore/Streaming/MasterPlaylist.swift`
- Test: `core/Tests/PaperPlaneCoreTests/HLSFilesTests.swift`
- Modify: `docs/superpowers/specs/2026-10-15-paper-plane-design.md` (§4 step 5)

**Interfaces:**
- Consumes: `VideoRange` (Task 4).
- Produces (all internal to `PaperPlaneCore`):
  - `struct MediaPlaylist { var segments: [Segment]; var isComplete: Bool; init(parsing: String) }` with `struct Segment { var uri: String; var duration: Double }`.
  - `struct InitSegment { var codecs: [String]?; var width: Int?; var height: Int?; init(_ data: Data) }`. `codecs` is nil if any track's codec is unknown.
  - `enum MasterPlaylist` with:
    - `fileName = "master.m3u8"` and `mediaPlaylistName = "index.m3u8"`.
    - `text(bandwidth: Int, initSegment: InitSegment, frameRate: Double?, videoRange: VideoRange) -> String`.
    - `bandwidth(segmentSizes: [(bytes: Int, duration: Double)]) -> Int`.

- [ ] **Step 1: Write the failing tests**

`core/Tests/PaperPlaneCoreTests/HLSFilesTests.swift`. The `MP4` helper at the end builds just enough of an init segment by hand. The real ffmpeg output is checked against the same strings in Task 6.

```swift
import Foundation
import Testing
@testable import PaperPlaneCore

struct MediaPlaylistTests {
    @Test func readsSegmentsOfAGrowingPlaylist() {
        let text = """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-TARGETDURATION:6
            #EXT-X-MEDIA-SEQUENCE:0
            #EXT-X-PLAYLIST-TYPE:EVENT
            #EXT-X-INDEPENDENT-SEGMENTS
            #EXT-X-MAP:URI="init.mp4"
            #EXTINF:6.006000,
            seg_00000.m4s
            #EXTINF:5.338667,
            seg_00001.m4s

            """
        #expect(MediaPlaylist(parsing: text) == MediaPlaylist(segments: [
            .init(uri: "seg_00000.m4s", duration: 6.006),
            .init(uri: "seg_00001.m4s", duration: 5.338667),
        ], isComplete: false))
    }

    @Test func endListMeansComplete() {
        let text = "#EXTM3U\r\n#EXTINF:4.0,\r\nseg_00000.m4s\r\n#EXT-X-ENDLIST\r\n"
        let playlist = MediaPlaylist(parsing: text)
        #expect(playlist.isComplete)
        #expect(playlist.segments == [.init(uri: "seg_00000.m4s", duration: 4)])
    }

    @Test func ignoresURIsWithoutDurations() {
        #expect(MediaPlaylist(parsing: "#EXTM3U\nstray.m4s\n").segments.isEmpty)
        #expect(MediaPlaylist(parsing: "").segments.isEmpty)
    }
}

struct InitSegmentTests {
    @Test func h264AndAAC() {
        let data = MP4.initSegment([
            MP4.visualEntry("avc1", width: 1920, height: 1080, config: MP4.box("avcC", [1, 0x64, 0x00, 0x28, 0xFF])),
            MP4.audioEntry("mp4a", config: MP4.esds(audioSpecificConfig: [0x12, 0x10])),
        ])
        #expect(InitSegment(data) == InitSegment(codecs: ["avc1.640028", "mp4a.40.2"], width: 1920, height: 1080))
    }

    @Test func hdr10HEVC() {
        // Main 10 (profile 2), main tier, level 5.0, progressive and frame-only.
        let hvcC = MP4.box("hvcC", [1, 0x02, 0x20, 0, 0, 0, 0x90, 0, 0, 0, 0, 0, 150] + [UInt8](repeating: 0, count: 10))
        let data = MP4.initSegment([MP4.visualEntry("hvc1", width: 3840, height: 2160, config: hvcC)])
        #expect(InitSegment(data).codecs == ["hvc1.2.4.L150.90"])
    }

    @Test func highTierHEVCKeepsEveryConstraintByteUpToTheLastNonZero() {
        let hvcC = MP4.box("hvcC", [1, 0x21, 0x60, 0, 0, 0, 0xB0, 0, 0x01, 0, 0, 0, 153])
        let data = MP4.initSegment([MP4.visualEntry("hvc1", width: 1920, height: 1080, config: hvcC)])
        #expect(InitSegment(data).codecs == ["hvc1.1.6.H153.B0.0.1"])
    }

    @Test func dolbyAudioAndHEAAC() {
        let data = MP4.initSegment([
            MP4.visualEntry("avc1", width: 1280, height: 720, config: MP4.box("avcC", [1, 0x4D, 0x40, 0x1F])),
            MP4.audioEntry("ec-3"),
            MP4.audioEntry("ac-3"),
            MP4.audioEntry("mp4a", config: MP4.esds(audioSpecificConfig: [0x2B, 0x92, 0x08, 0x00])),
        ])
        #expect(InitSegment(data).codecs == ["avc1.4d401f", "ec-3", "ac-3", "mp4a.40.5"])
    }

    @Test func unknownCodecDropsTheWholeList() {
        let data = MP4.initSegment([
            MP4.visualEntry("avc1", width: 1280, height: 720, config: MP4.box("avcC", [1, 0x64, 0x00, 0x1F])),
            MP4.audioEntry("Opus"),
        ])
        #expect(InitSegment(data) == InitSegment(codecs: nil, width: 1280, height: 720))
    }

    @Test func garbageHasNothing() {
        #expect(InitSegment(Data("not an mp4 file at all".utf8)) == InitSegment(codecs: nil, width: nil, height: nil))
        #expect(InitSegment(Data()) == InitSegment(codecs: nil, width: nil, height: nil))
        // A box claiming to be bigger than the file.
        #expect(InitSegment(Data([0xFF, 0xFF, 0xFF, 0xFF] + Array("moov".utf8))).codecs == nil)
    }
}

struct MasterPlaylistTests {
    @Test func describesTheStreamAndStartsAtTheBeginning() {
        let text = MasterPlaylist.text(
            bandwidth: 25_000_000,
            initSegment: InitSegment(codecs: ["hvc1.2.4.L150.90", "mp4a.40.2"], width: 3840, height: 2160),
            frameRate: 24000.0 / 1001,
            videoRange: .pq)
        #expect(text == """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-INDEPENDENT-SEGMENTS
            #EXT-X-START:TIME-OFFSET=0
            #EXT-X-STREAM-INF:BANDWIDTH=25000000,CODECS="hvc1.2.4.L150.90,mp4a.40.2",RESOLUTION=3840x2160,FRAME-RATE=23.976,VIDEO-RANGE=PQ
            index.m3u8

            """)
    }

    @Test func leavesOutWhatIsUnknown() {
        let text = MasterPlaylist.text(bandwidth: 800_000, initSegment: InitSegment(codecs: nil, width: nil, height: nil),
                                       frameRate: nil, videoRange: .sdr)
        #expect(text.contains("#EXT-X-STREAM-INF:BANDWIDTH=800000,VIDEO-RANGE=SDR\nindex.m3u8\n"))
    }

    @Test func bandwidthIsThePeakSegmentRateWithHeadroom() {
        // 6 s of 3 MB is 4 Mb/s; 2 s of 2 MB is 8 Mb/s, the peak.
        #expect(MasterPlaylist.bandwidth(segmentSizes: [(3_000_000, 6), (2_000_000, 2)]) == 8_800_000)
        #expect(MasterPlaylist.bandwidth(segmentSizes: []) == 100_000)
        #expect(MasterPlaylist.bandwidth(segmentSizes: [(500, 0)]) == 100_000)
    }
}

/// Builds just enough of an fMP4 init segment to exercise InitSegment.
enum MP4 {
    static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        be32(8 + payload.count) + Array(type.utf8) + payload
    }

    static func initSegment(_ sampleEntries: [[UInt8]]) -> Data {
        let tracks = sampleEntries.flatMap { entry in
            let stsd = box("stsd", [0, 0, 0, 0] + be32(1) + entry)
            return box("trak", box("mdia", box("minf", box("stbl", stsd))))
        }
        return Data(box("ftyp", Array("iso5".utf8) + [0, 0, 2, 0]) + box("moov", tracks))
    }

    static func visualEntry(_ type: String, width: Int, height: Int, config: [UInt8]) -> [UInt8] {
        box(type, [UInt8](repeating: 0, count: 24) + be16(width) + be16(height) + [UInt8](repeating: 0, count: 50) + config)
    }

    static func audioEntry(_ type: String, config: [UInt8] = []) -> [UInt8] {
        box(type, [UInt8](repeating: 0, count: 28) + config)
    }

    /// An esds box for AAC (object type 0x40) with the given AudioSpecificConfig.
    static func esds(audioSpecificConfig: [UInt8]) -> [UInt8] {
        let specific = [0x05, UInt8(audioSpecificConfig.count)] + audioSpecificConfig
        let decoderConfig = [0x04, UInt8(13 + specific.count), 0x40, 0x15] + [UInt8](repeating: 0, count: 11) + specific
        let elementary = [0x03, UInt8(3 + decoderConfig.count), 0x00, 0x01, 0x00] + decoderConfig
        return box("esds", [0, 0, 0, 0] + elementary)
    }

    static func be16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
    static func be32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8(value >> (24 - 8 * $0) & 0xFF) } }
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `scripts/test-core.sh --filter 'MediaPlaylistTests|InitSegmentTests|MasterPlaylistTests'`
Expected: the build fails with `cannot find 'MediaPlaylist' in scope` (and the same for `InitSegment` and `MasterPlaylist`).

- [ ] **Step 3: Implement `MediaPlaylist`**

`core/Sources/PaperPlaneCore/Streaming/MediaPlaylist.swift`:

```swift
import Foundation

/// The parts of ffmpeg's HLS media playlist (`index.m3u8`) that Paper Plane reads back.
struct MediaPlaylist: Equatable, Sendable {
    struct Segment: Equatable, Sendable {
        var uri: String
        /// Seconds, from `#EXTINF`.
        var duration: Double
    }

    var segments: [Segment]
    /// True once `#EXT-X-ENDLIST` is there: ffmpeg has written the whole stream.
    var isComplete: Bool

    init(segments: [Segment], isComplete: Bool) {
        self.segments = segments
        self.isComplete = isComplete
    }

    init(parsing text: String) {
        var segments: [Segment] = []
        var pendingDuration: Double?
        var isComplete = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF:") {
                pendingDuration = Double(line.dropFirst("#EXTINF:".count).prefix { $0 != "," })
            } else if line == "#EXT-X-ENDLIST" {
                isComplete = true
            } else if !line.isEmpty, !line.hasPrefix("#"), let duration = pendingDuration {
                segments.append(Segment(uri: line, duration: duration))
                pendingDuration = nil
            }
        }
        self.init(segments: segments, isComplete: isComplete)
    }
}
```

- [ ] **Step 4: Implement `InitSegment`**

`core/Sources/PaperPlaneCore/Streaming/InitSegment.swift`. It walks the boxes rather than searching for byte patterns, and stops at the first malformed box, so a damaged file gives "unknown", never a crash.

```swift
import Foundation

/// What the HLS master playlist needs from an fMP4 init segment (`init.mp4`): the RFC 6381
/// codec string of each track (`avc1.640028`, `hvc1.2.4.L150.90`, `mp4a.40.2`, `ac-3`, `ec-3`)
/// and the video's size.
struct InitSegment: Equatable, Sendable {
    /// nil when a track's codec isn't one Paper Plane writes. The master playlist then leaves
    /// CODECS out: a partial list would make players skip tracks.
    var codecs: [String]?
    var width: Int?
    var height: Int?

    init(codecs: [String]?, width: Int?, height: Int?) {
        self.codecs = codecs
        self.width = width
        self.height = height
    }

    init(_ data: Data) {
        let bytes = [UInt8](data)
        var codecs: [String] = []
        var allKnown = true
        var width: Int?
        var height: Int?
        for entry in Self.sampleEntries(in: bytes) {
            var codec: String?
            switch entry.type {
            case "avc1", "avc3", "hvc1", "hev1":
                // VisualSampleEntry: 24 bytes of fields, width and height, then 50 more bytes.
                guard entry.payload.count >= 78 else { break }
                width = Self.uint16(bytes, entry.payload.lowerBound + 24)
                height = Self.uint16(bytes, entry.payload.lowerBound + 26)
                let children = Self.boxes(in: bytes, (entry.payload.lowerBound + 78)..<entry.payload.upperBound)
                if entry.type.hasPrefix("avc") {
                    codec = children.first { $0.type == "avcC" }.flatMap { Self.avcCodec(entry.type, bytes, $0.payload) }
                } else {
                    codec = children.first { $0.type == "hvcC" }.flatMap { Self.hevcCodec(entry.type, bytes, $0.payload) }
                }
            case "mp4a":
                // AudioSampleEntry: 28 bytes of fields before the child boxes.
                guard entry.payload.count >= 28 else { break }
                let children = Self.boxes(in: bytes, (entry.payload.lowerBound + 28)..<entry.payload.upperBound)
                codec = children.first { $0.type == "esds" }.flatMap { Self.aacCodec(bytes, $0.payload) }
            case "ac-3", "ec-3":
                codec = entry.type
            default:
                codec = nil
            }
            if let codec {
                codecs.append(codec)
            } else {
                allKnown = false
            }
        }
        self.init(codecs: allKnown && !codecs.isEmpty ? codecs : nil, width: width, height: height)
    }

    // MARK: - Boxes

    private struct Box {
        var type: String
        var payload: Range<Int>
    }

    /// The boxes directly inside `range`. Stops at the first malformed one.
    private static func boxes(in bytes: [UInt8], _ range: Range<Int>) -> [Box] {
        var result: [Box] = []
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            var size = Int(uint32(bytes, offset))
            var header = 8
            if size == 1 {
                guard offset + 16 <= range.upperBound else { break }
                size = Int(clamping: uint64(bytes, offset + 8))
                header = 16
            } else if size == 0 {
                size = range.upperBound - offset
            }
            guard size >= header, size <= range.upperBound - offset else { break }
            let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
            result.append(Box(type: type, payload: (offset + header)..<(offset + size)))
            offset += size
        }
        return result
    }

    /// moov → trak → mdia → minf → stbl → stsd → sample entries, for every track.
    private static func sampleEntries(in bytes: [UInt8]) -> [Box] {
        var level = boxes(in: bytes, 0..<bytes.count)
        for container in ["moov", "trak", "mdia", "minf", "stbl"] {
            level = level.filter { $0.type == container }.flatMap { boxes(in: bytes, $0.payload) }
        }
        return level.filter { $0.type == "stsd" }.flatMap { stsd in
            // stsd: version and flags (4 bytes), entry count (4 bytes), then the entries.
            stsd.payload.count >= 8 ? boxes(in: bytes, (stsd.payload.lowerBound + 8)..<stsd.payload.upperBound) : []
        }
    }

    // MARK: - Codec strings

    /// `avc1.PPCCLL`: profile, constraint flags and level from the avcC box.
    private static func avcCodec(_ type: String, _ bytes: [UInt8], _ avcC: Range<Int>) -> String? {
        guard avcC.count >= 4 else { return nil }
        let start = avcC.lowerBound
        return String(format: "%@.%02x%02x%02x", type, bytes[start + 1], bytes[start + 2], bytes[start + 3])
    }

    /// `hvc1.<space><profile>.<compatibility, bit-reversed>.<tier><level>[.<constraint bytes>]`
    /// from the hvcC box (ISO/IEC 14496-15 Annex E).
    private static func hevcCodec(_ type: String, _ bytes: [UInt8], _ hvcC: Range<Int>) -> String? {
        guard hvcC.count >= 13 else { return nil }
        let start = hvcC.lowerBound
        let space = ["", "A", "B", "C"][Int(bytes[start + 1] >> 6)]
        let tier = (bytes[start + 1] >> 5) & 1 == 1 ? "H" : "L"
        let profile = bytes[start + 1] & 0x1F
        let compatibility = uint32(bytes, start + 2)
        var reversed: UInt32 = 0
        for bit in 0..<32 where compatibility & (1 << bit) != 0 {
            reversed |= 1 << (31 - bit)
        }
        var constraints = Array(bytes[(start + 6)..<(start + 12)])
        while constraints.last == 0 {
            constraints.removeLast()
        }
        let level = bytes[start + 12]
        return "\(type).\(space)\(profile).\(String(reversed, radix: 16, uppercase: true)).\(tier)\(level)"
            + constraints.map { "." + String($0, radix: 16, uppercase: true) }.joined()
    }

    /// `mp4a.40.<audio object type>` from the esds box's AudioSpecificConfig.
    private static func aacCodec(_ bytes: [UInt8], _ esds: Range<Int>) -> String? {
        var offset = esds.lowerBound + 4 // version and flags
        func descriptor(_ tag: UInt8) -> Range<Int>? {
            guard offset < esds.upperBound, bytes[offset] == tag else { return nil }
            offset += 1
            var length = 0
            for _ in 0..<4 {
                guard offset < esds.upperBound else { return nil }
                let byte = bytes[offset]
                offset += 1
                length = length << 7 | Int(byte & 0x7F)
                if byte & 0x80 == 0 { break }
            }
            guard length <= esds.upperBound - offset else { return nil }
            return offset..<(offset + length)
        }
        guard let elementary = descriptor(0x03), elementary.count >= 3 else { return nil }
        let flags = bytes[elementary.lowerBound + 2]
        offset = elementary.lowerBound + 3
        if flags & 0x80 != 0 { offset += 2 } // stream dependence
        if flags & 0x40 != 0, offset < elementary.upperBound { offset += 1 + Int(bytes[offset]) } // URL
        if flags & 0x20 != 0 { offset += 2 } // OCR stream
        guard let config = descriptor(0x04), config.count >= 13 else { return nil }
        let objectType = bytes[config.lowerBound]
        offset = config.lowerBound + 13
        guard let specific = descriptor(0x05), specific.count >= 1 else {
            return String(format: "mp4a.%02x", objectType)
        }
        var audioObjectType = Int(bytes[specific.lowerBound] >> 3)
        if audioObjectType == 31, specific.count >= 2 {
            audioObjectType = 32 + Int((bytes[specific.lowerBound] & 0x07) << 3 | bytes[specific.lowerBound + 1] >> 5)
        }
        return String(format: "mp4a.%02x.%d", objectType, audioObjectType)
    }

    // MARK: - Integers

    private static func uint16(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
    }

    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 << 8 | UInt32(bytes[offset + $1]) }
    }

    private static func uint64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        (0..<8).reduce(0) { $0 << 8 | UInt64(bytes[offset + $1]) }
    }
}
```

- [ ] **Step 5: Implement `MasterPlaylist`**

`core/Sources/PaperPlaneCore/Streaming/MasterPlaylist.swift`:

```swift
import Foundation

/// The master playlist Paper Plane hands to the player (`master.m3u8`). It points at ffmpeg's
/// `index.m3u8` and adds what ffmpeg can't:
/// - `EXT-X-START:TIME-OFFSET=0`, so a still-growing playlist starts at its beginning instead of
///   its live edge (docs/sony-test-results.md, row 7a).
/// - `CODECS`, `RESOLUTION`, `FRAME-RATE` and `VIDEO-RANGE`, which Apple's HLS authoring spec
///   asks for and which tell the TV up front that a stream is HDR. AVFoundation refuses a
///   `VIDEO-RANGE=PQ` variant that has no `FRAME-RATE`, and refuses HDR video declared as SDR.
enum MasterPlaylist {
    static let fileName = "master.m3u8"
    static let mediaPlaylistName = "index.m3u8"

    static func text(bandwidth: Int, initSegment: InitSegment, frameRate: Double?, videoRange: VideoRange) -> String {
        var attributes = ["BANDWIDTH=\(bandwidth)"]
        if let codecs = initSegment.codecs {
            attributes.append("CODECS=\"\(codecs.joined(separator: ","))\"")
        }
        if let width = initSegment.width, let height = initSegment.height, width > 0, height > 0 {
            attributes.append("RESOLUTION=\(width)x\(height)")
        }
        if let frameRate, frameRate > 0 {
            attributes.append(String(format: "FRAME-RATE=%.3f", frameRate))
        }
        attributes.append("VIDEO-RANGE=\(videoRange.rawValue)")
        return [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-START:TIME-OFFSET=0",
            "#EXT-X-STREAM-INF:" + attributes.joined(separator: ","),
            mediaPlaylistName,
            "",
        ].joined(separator: "\n")
    }

    /// Peak bits per second over the segments so far, with 10% headroom.
    static func bandwidth(segmentSizes: [(bytes: Int, duration: Double)]) -> Int {
        let peak = segmentSizes
            .filter { $0.duration > 0 }
            .map { Double($0.bytes) * 8 / $0.duration }
            .max() ?? 0
        return max(Int((peak * 1.1).rounded(.up)), 100_000)
    }
}
```

- [ ] **Step 6: Run the tests**

Run: `scripts/test-core.sh --filter 'MediaPlaylistTests|InitSegmentTests|MasterPlaylistTests'`
Expected: `✔ Test run with 12 tests in 3 suites passed`.

- [ ] **Step 7: Update the spec**

In the spec, replace step 5 of §4 ("Once the first 2 segments exist, …") with:

```markdown
5. Once the first 2 segments exist, Paper Plane writes a master playlist (`master.m3u8`) next to ffmpeg's `index.m3u8`. It carries `#EXT-X-START:TIME-OFFSET=0`, so the TV starts at the beginning rather than the live edge, and `CODECS`, `RESOLUTION`, `FRAME-RATE` and `VIDEO-RANGE`. `StreamServer` publishes the folder and `AVPlayer` opens the master playlist, held paused until a TV is chosen. AirPlay hands that URL to the TV.
```

- [ ] **Step 8: Commit**

```bash
git add core/Sources/PaperPlaneCore/Streaming core/Tests/PaperPlaneCoreTests/HLSFilesTests.swift docs/superpowers/specs/2026-10-15-paper-plane-design.md
git commit -m "feat(core): read ffmpeg's playlist and init segment; write the master playlist" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: `Transcoder`

Runs ffmpeg for a plan into a session folder and reports each segment as it lands. It writes `master.m3u8` once the first two segments exist, and can pause, resume and stop ffmpeg. Cancelling a start kills the child, as `ProcessRunner` does.

**Where a session starts.** Copying video can only start on a keyframe. With `-ss 12` on a file with keyframes every 5 s, ffmpeg starts at 10, not 12, so the remote's clock would be 2 s off. Plan 1's final review suggested taking the offset from the first segment. But ffmpeg rebases the segments' timestamps to 0, so the first segment no longer says where it came from. Keeping the source times would mean `-copyts`, which changes what the TV receives, and the Sony hasn't been tested with that. Instead, `Transcoder` asks ffmpeg itself: a one-packet run with the same input options and the same `-ss` prints the first video packet's time (`-f framecrc`). Verified: −2.000 s for `-ss 12`, so the offset is 10. Re-encoded video starts exactly at the requested time, so it needs no probe.

**Files:**
- Create: `core/Sources/PaperPlaneCore/Streaming/SessionFolders.swift`, `core/Sources/PaperPlaneCore/Support/BackgroundProcess.swift`, `core/Sources/PaperPlaneCore/Streaming/Transcoder.swift`
- Test: `core/Tests/PaperPlaneCoreTests/TranscoderTests.swift`
- Modify: `core/Tests/PaperPlaneCoreTests/TestSupport.swift` (add `playerItemStatus`)

**Interfaces:**
- Consumes: `ConversionPlan.ffmpegArguments(input:start:output:)`, `ProcessRunner`, `ToolPaths`, `ResolvedInput` (Plan 1); `Redaction.summary(of:)` (Task 2); `VideoRange`, `ConversionPlan.frameRate` (Task 4); `MediaPlaylist`, `InitSegment`, `MasterPlaylist` (Task 5); the test helper `HLSServer` (Plan 1, `PipelineTests.swift`).
- Produces:
  - `public struct SessionFolders`:
    - `root: URL` and `init(root:)`.
    - `static var standard` (`~/Library/Caches/Paper Plane/sessions`).
    - `create() throws -> URL` and `removeAll() throws`.
  - `public struct Transcoder`:
    - `init(tools: ToolPaths, segmentsBeforeReady: Int = 2)`.
    - `start(_ plan: ConversionPlan, input: ResolvedInput, from start: Double = 0, in folder: URL) async throws -> TranscodeSession`. It returns once ready. It throws `TranscodeError` or `CancellationError`, and deletes the folder on failure.
  - `public final class TranscodeSession: Sendable`:
    - Properties: `folder`, `requestedStart`, `offset` (movie time = offset + player time) and `events: AsyncStream<TranscodeEvent>`.
    - Methods: `pause()`, `resume()` and `stop() async`. `stop()` deletes the folder and is safe to call twice.
  - `public enum TranscodeEvent: Equatable { case segment(index: Int, end: Double), finished, failed(String) }`.
  - `public enum TranscodeError: Error, Equatable { case ffmpegFailed(status: Int32, message: String), cannotWriteMasterPlaylist }`.
  - Test helper: `TestSupport.playerItemStatus(_ url: URL) async -> AVPlayerItem.Status` (`@MainActor`).

- [ ] **Step 1: Add the player check to `TestSupport`**

Add `import AVFoundation` at the top of `TestSupport.swift`, and add this method before `ffmpegHasFilter`:

```swift
    /// Waits up to 10 s for Apple's player to accept `url`, as the app's AVPlayer must before
    /// AirPlay can hand the stream to the TV.
    @MainActor
    static func playerItemStatus(_ url: URL) async -> AVPlayerItem.Status {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        for _ in 0..<100 where item.status == .unknown {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return item.status
    }
```

- [ ] **Step 2: Write the failing tests**

`core/Tests/PaperPlaneCoreTests/TranscoderTests.swift`. `TranscoderTests` drive a shell script standing in for ffmpeg (`FakeFFmpeg`), so readiness, failures, cancellation and pausing are exact and fast. `TranscoderMediaTests` use the real ffmpeg and the test clips. They check the session offset, the master playlist against real `init.mp4` files, and that Apple's player accepts SDR, HDR and re-encoded output.

```swift
import AVFoundation
import Foundation
import Testing
@testable import PaperPlaneCore

/// Transcoder behaviour with a scripted stand-in for ffmpeg, so timing and failures are exact.
struct TranscoderTests {
    static let plan = ConversionPlan(video: TrackRef(index: 0), videoAction: .copy(.h264),
                                     audio: TrackRef(index: 1), audioAction: .copy)
    static let input = ResolvedInput.file(URL(fileURLWithPath: "/Movies/movie.mkv"))

    @Test func returnsOnceTwoSegmentsAndTheMasterPlaylistExist() async throws {
        let fake = try FakeFFmpeg(segments: 5, interval: 0.1)
        defer { fake.remove() }
        let session = try await Transcoder(tools: fake.tools).start(Self.plan, input: Self.input, in: fake.output)

        let playlist = MediaPlaylist(parsing: try String(contentsOf: fake.output.appendingPathComponent("index.m3u8"),
                                                         encoding: .utf8))
        #expect(playlist.segments.count >= 2)
        let master = try String(contentsOf: fake.output.appendingPathComponent("master.m3u8"), encoding: .utf8)
        #expect(master.contains("#EXT-X-START:TIME-OFFSET=0"))
        #expect(master.contains("VIDEO-RANGE=SDR"))
        #expect(session.offset == 0)
        await session.stop()
    }

    @Test func reportsEverySegmentThenFinished() async throws {
        let fake = try FakeFFmpeg(segments: 4, interval: 0.05)
        defer { fake.remove() }
        let session = try await Transcoder(tools: fake.tools).start(Self.plan, input: Self.input, in: fake.output)
        var events: [TranscodeEvent] = []
        for await event in session.events {
            events.append(event)
        }
        #expect(events == [
            .segment(index: 0, end: 6), .segment(index: 1, end: 12), .segment(index: 2, end: 18),
            .segment(index: 3, end: 24), .finished,
        ])
        await session.stop()
    }

    @Test func shortVideoIsReadyWithOneSegment() async throws {
        let fake = try FakeFFmpeg(segments: 1, interval: 0.05)
        defer { fake.remove() }
        let session = try await Transcoder(tools: fake.tools).start(Self.plan, input: Self.input, in: fake.output)
        #expect(FileManager.default.fileExists(atPath: fake.output.appendingPathComponent("master.m3u8").path))
        await session.stop()
    }

    @Test func failureBeforeReadyThrowsARedactedErrorAndDeletesTheFolder() async throws {
        let fake = try FakeFFmpeg(segments: 0, interval: 0, exitStatus: 1,
                                  stderr: "Cookie: sid=SECRET\nhttps://cdn.test/v.m3u8?token=SECRET: Invalid data")
        defer { fake.remove() }
        await #expect(throws: TranscodeError.ffmpegFailed(
            status: 1, message: "Cookie: …\nhttps://cdn.test/v.m3u8?… Invalid data")) {
            try await Transcoder(tools: fake.tools).start(Self.plan, input: Self.input, in: fake.output)
        }
        #expect(!FileManager.default.fileExists(atPath: fake.output.path))
    }

    @Test func failureAfterReadyIsAnEvent() async throws {
        let fake = try FakeFFmpeg(segments: 3, interval: 0.05, exitStatus: 1, stderr: "Error while decoding stream #0:0")
        defer { fake.remove() }
        let session = try await Transcoder(tools: fake.tools).start(Self.plan, input: Self.input, in: fake.output)
        var last: TranscodeEvent?
        for await event in session.events {
            last = event
        }
        #expect(last == .failed("Error while decoding stream #0:0"))
        await session.stop()
    }

    @Test func cancellingTheStartStopsFFmpegAndDeletesTheFolder() async throws {
        let fake = try FakeFFmpeg(segments: 1, interval: 30)
        defer { fake.remove() }
        let start = Task {
            try await Transcoder(tools: fake.tools).start(Self.plan, input: Self.input, in: fake.output)
        }
        try await Task.sleep(for: .milliseconds(300))
        let cancelledAt = ContinuousClock.now
        start.cancel()
        await #expect(throws: CancellationError.self) {
            try await start.value
        }
        #expect(ContinuousClock.now - cancelledAt < .seconds(3))
        #expect(!FileManager.default.fileExists(atPath: fake.output.path))
    }

    @Test func pauseHoldsFFmpegUntilResume() async throws {
        let fake = try FakeFFmpeg(segments: 100, interval: 0.1)
        defer { fake.remove() }
        let session = try await Transcoder(tools: fake.tools).start(Self.plan, input: Self.input, in: fake.output)
        session.pause()
        try await Task.sleep(for: .milliseconds(300)) // let a write in progress land
        let paused = try fake.segmentCount()
        try await Task.sleep(for: .milliseconds(800))
        #expect(try fake.segmentCount() == paused)

        session.resume()
        try await Task.sleep(for: .milliseconds(800))
        #expect(try fake.segmentCount() > paused)
        await session.stop()
    }

    @Test func stopEndsAPausedSessionAndDeletesTheFolder() async throws {
        let fake = try FakeFFmpeg(segments: 100, interval: 0.1)
        defer { fake.remove() }
        let session = try await Transcoder(tools: fake.tools).start(Self.plan, input: Self.input, in: fake.output)
        session.pause()
        let stoppedAt = ContinuousClock.now
        await session.stop()
        #expect(ContinuousClock.now - stoppedAt < .seconds(3))
        #expect(!FileManager.default.fileExists(atPath: fake.output.path))
        await session.stop() // a second stop is harmless
    }

    @Test func readsTheFirstPacketTimeFromFramecrc() {
        let output = """
            #extradata 0:       45, 0x23bb0eb7
            #tb 0: 1/15360
            #media_type 0: video
            0,      -8704,      -7680,      512,     7977, 0xf707803e
            """
        #expect(Transcoder.firstPacketTime(framecrc: output) == -0.5)
        #expect(Transcoder.firstPacketTime(framecrc: "#tb 0: 1/1000\n") == nil)
        #expect(Transcoder.firstPacketTime(framecrc: "0, 1, 2, 3, 4\n") == nil)
    }
}

/// Converting real test media with the real ffmpeg.
@Suite(.enabled(if: TestSupport.hasMedia, "Needs ffmpeg (brew install ffmpeg) and scripts/make-test-media.sh"))
struct TranscoderMediaTests {
    /// The Sony's profile, spelled out so these tests don't move if the default changes.
    static let stereoHDR = OutputProfile(surround: false, hdr: true)

    private func start(_ file: String, from start: Double = 0, profile: OutputProfile = stereoHDR) async throws
        -> (session: TranscodeSession, master: String) {
        let tools = try #require(TestSupport.tools)
        let input = ResolvedInput.file(TestSupport.media(file))
        let plan = try ConversionPlanner.plan(try await MediaProbe(tools: tools).probe(input), profile: profile)
        let folder = try SessionFolders(root: TestSupport.makeTemporaryDirectory()).create()
        let session = try await Transcoder(tools: tools).start(plan, input: input, from: start, in: folder)
        let master = try String(contentsOf: folder.appendingPathComponent("master.m3u8"), encoding: .utf8)
        return (session, master)
    }

    @Test func copiedVideoStartsAtTheKeyframeBeforeTheRequestedTime() async throws {
        // The test clips have a keyframe every second.
        let (session, _) = try await start("h264_aac.mp4", from: 4.5)
        #expect(session.requestedStart == 4.5)
        #expect(abs(session.offset - 4.0) < 0.05)
        await session.stop()
    }

    @Test func reencodedVideoStartsExactlyAtTheRequestedTime() async throws {
        let (session, _) = try await start("vp9_opus.webm", from: 4.5)
        #expect(session.offset == 4.5)
        await session.stop()
    }

    @Test(arguments: [
        ("h264_aac.mp4", #"CODECS="avc1.64001f,mp4a.40.2",RESOLUTION=1280x720,FRAME-RATE=30.000,VIDEO-RANGE=SDR"#),
        ("hevc_hdr10_aac.mkv", #"CODECS="hvc1.2.4.L93.90,mp4a.40.2",RESOLUTION=1280x720,FRAME-RATE=30.000,VIDEO-RANGE=PQ"#),
        ("h264_ac3_51.mkv", #"CODECS="avc1.64001f,mp4a.40.2",RESOLUTION=1280x720,FRAME-RATE=30.000,VIDEO-RANGE=SDR"#),
    ])
    func masterPlaylistDescribesTheOutput(file: String, attributes: String) async throws {
        let (session, master) = try await start(file)
        #expect(master.contains(attributes), "\(master)")
        await session.stop()
    }

    @Test func surroundTVGetsDolbyCodecs() async throws {
        let (session, master) = try await start("hevc_eac3_51.mkv", profile: OutputProfile(surround: true, hdr: true))
        #expect(master.contains(#"CODECS="hvc1.1.6.L93.90,ec-3""#), "\(master)")
        await session.stop()
    }

    /// AVFoundation is stricter about master playlists than media playlists: an HDR variant
    /// without FRAME-RATE fails, so check the player really accepts SDR and HDR output.
    @Test(arguments: ["h264_aac.mp4", "hevc_hdr10_aac.mkv", "vp9_opus.webm"])
    func applesPlayerAcceptsTheMasterPlaylist(_ file: String) async throws {
        let (session, _) = try await start(file)
        _ = await session.events.first { $0 == .finished }
        let server = try await HLSServer(directory: session.folder)
        let status = await TestSupport.playerItemStatus(server.url("master.m3u8"))
        let duration = try await AVURLAsset(url: server.url("master.m3u8")).load(.duration).seconds
        server.stop()
        await session.stop()
        #expect(status == .readyToPlay)
        #expect(abs(duration - 10) < 1.5)
    }
}

struct SessionFoldersTests {
    @Test func createsFreshFoldersAndRemovesThemAll() throws {
        let root = try TestSupport.makeTemporaryDirectory().appendingPathComponent("sessions")
        let folders = SessionFolders(root: root)
        let first = try folders.create()
        let second = try folders.create()
        #expect(first != second)
        #expect(first.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
        try folders.removeAll()
        #expect(!FileManager.default.fileExists(atPath: root.path))
        try folders.removeAll() // nothing there: no error
    }

    @Test func standardFolderIsInCaches() {
        #expect(SessionFolders.standard.root.path.hasSuffix("/Library/Caches/Paper Plane/sessions"))
    }
}

/// A shell script that behaves like ffmpeg writing HLS: it writes `segments` segments into the
/// folder given as its last argument, one every `interval` seconds, then exits with `exitStatus`.
/// For the keyframe probe (last argument `-`) it prints a framecrc line.
struct FakeFFmpeg {
    let directory: URL
    let output: URL
    let tools: ToolPaths

    init(segments: Int, interval: Double, exitStatus: Int32 = 0, stderr: String = "") throws {
        directory = try TestSupport.makeTemporaryDirectory()
        output = directory.appendingPathComponent("session")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let script = """
            #!/bin/sh
            for last; do :; done
            if [ "$last" = "-" ]; then printf '#tb 0: 1/1000\\n0, -567, -500, 33, 6681, 0x0\\n'; exit 0; fi
            dir=$(dirname "$last")
            printf 'not really an mp4' > "$dir/init.mp4"
            list='#EXTM3U\\n#EXT-X-MAP:URI="init.mp4"\\n'
            i=0
            while [ $i -lt \(segments) ]; do
              sleep \(interval)
              name=$(printf 'seg_%05d.m4s' $i)
              printf 'segment' > "$dir/$name"
              list="$list#EXTINF:6.000000,\\n$name\\n"
              printf "$list" > "$dir/index.tmp" && mv "$dir/index.tmp" "$last"
              i=$((i + 1))
            done
            [ \(segments) -gt 0 ] && printf "$list#EXT-X-ENDLIST\\n" > "$dir/index.tmp" && mv "$dir/index.tmp" "$last"
            printf '%s\\n' '\(stderr)' >&2
            exit \(exitStatus)
            """
        let ffmpeg = directory.appendingPathComponent("ffmpeg")
        try Data(script.utf8).write(to: ffmpeg)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ffmpeg.path)
        tools = ToolPaths(ffmpeg: ffmpeg, ffprobe: URL(fileURLWithPath: "/usr/bin/false"))
    }

    func segmentCount() throws -> Int {
        let text = try String(contentsOf: output.appendingPathComponent("index.m3u8"), encoding: .utf8)
        return MediaPlaylist(parsing: text).segments.count
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
```

- [ ] **Step 3: Run them and watch them fail**

Run: `scripts/test-core.sh --filter 'TranscoderTests|TranscoderMediaTests|SessionFoldersTests'`
Expected: the build fails with `cannot find 'Transcoder' in scope` and `cannot find 'SessionFolders' in scope`.

- [ ] **Step 4: Implement `SessionFolders`**

`core/Sources/PaperPlaneCore/Streaming/SessionFolders.swift`:

```swift
import Foundation

/// Where each playback's HLS files go: `~/Library/Caches/Paper Plane/sessions/<id>/` (spec §4).
public struct SessionFolders: Sendable {
    public var root: URL

    public init(root: URL) {
        self.root = root
    }

    public static var standard: SessionFolders {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return SessionFolders(root: caches.appendingPathComponent("Paper Plane/sessions", isDirectory: true))
    }

    /// A new, empty folder for one session.
    public func create() throws -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Deletes every session folder. The app calls this at launch, so nothing a crash left
    /// behind piles up (spec §4.2).
    public func removeAll() throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try FileManager.default.removeItem(at: root)
    }
}
```

- [ ] **Step 5: Implement `BackgroundProcess`**

`core/Sources/PaperPlaneCore/Support/BackgroundProcess.swift`. Unlike `ProcessRunner`, which runs a command to completion, this keeps a child running. Any number of tasks can await its exit, and signals are only sent while it's alive, so a recycled process ID never gets one.

```swift
import Foundation
import os

/// A long-running child process (ffmpeg converting a video). Its exit can be awaited from any
/// number of tasks, it can be paused and stopped with signals, and the end of its stderr is
/// kept for error messages.
final class BackgroundProcess: @unchecked Sendable {
    private struct State {
        var exitStatus: Int32?
        var exitWaiters: [CheckedContinuation<Int32, Never>] = []
        var stderrTail = Data()
    }

    private static let stderrLimit = 64 * 1024
    private let process = Process()
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(_ executable: URL, arguments: [String]) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        let state = state
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            state.withLock { state in
                state.stderrTail.append(chunk)
                if state.stderrTail.count > Self.stderrLimit {
                    state.stderrTail.removeFirst(state.stderrTail.count - Self.stderrLimit)
                }
            }
        }
        // Like ProcessRunner, learn the exit from the termination handler: waitUntilExit()
        // deadlocks on the main thread.
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            let waiters = state.withLock { state in
                state.exitStatus = status
                defer { state.exitWaiters = [] }
                return state.exitWaiters
            }
            waiters.forEach { $0.resume(returning: status) }
        }
        try process.run()
    }

    /// nil while the process is running.
    var exitStatus: Int32? {
        state.withLock { $0.exitStatus }
    }

    /// The last 64 KB the process wrote to stderr.
    var stderr: Data {
        state.withLock { $0.stderrTail }
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            let status = state.withLock { state in
                if state.exitStatus == nil {
                    state.exitWaiters.append(continuation)
                }
                return state.exitStatus
            }
            if let status {
                continuation.resume(returning: status)
            }
        }
    }

    /// Sends `signal` (SIGSTOP, SIGCONT, SIGTERM, SIGKILL) unless the process has exited, so a
    /// recycled process ID never gets it.
    func send(_ signal: Int32) {
        state.withLock { state in
            if state.exitStatus == nil {
                kill(process.processIdentifier, signal)
            }
        }
    }
}
```

- [ ] **Step 6: Implement `Transcoder` and `TranscodeSession`**

`core/Sources/PaperPlaneCore/Streaming/Transcoder.swift`. Notes:
- The watcher polls `index.m3u8` every 200 ms. With `-hls_flags temp_file`, ffmpeg replaces the playlist and segments atomically, so a listed segment is always complete.
- The watcher reads the exit status before the playlist, so segments written just before exit are never missed.
- `stop()` sends SIGTERM and then SIGCONT, because a paused (SIGSTOP) ffmpeg only acts on SIGTERM once it runs again. If ffmpeg hasn't exited after 5 s, it sends SIGKILL.

```swift
import Foundation
import os

public enum TranscodeEvent: Equatable, Sendable {
    /// Segment `index` (counting from 0) is complete. The stream now runs to `end` seconds.
    case segment(index: Int, end: Double)
    /// ffmpeg converted everything and exited.
    case finished
    /// ffmpeg failed part-way through. The message is redacted.
    case failed(String)
}

public enum TranscodeError: Error, Equatable {
    /// ffmpeg stopped before the stream was ready. `message` is its redacted stderr.
    case ffmpegFailed(status: Int32, message: String)
    /// The master playlist couldn't be written into the session folder.
    case cannotWriteMasterPlaylist
}

/// Runs ffmpeg for a conversion plan (spec §3.1).
public struct Transcoder: Sendable {
    public var tools: ToolPaths
    /// How many segments must exist before a session counts as started (spec §4: the first 2).
    public var segmentsBeforeReady: Int

    public init(tools: ToolPaths, segmentsBeforeReady: Int = 2) {
        self.tools = tools
        self.segmentsBeforeReady = segmentsBeforeReady
    }

    /// Starts converting `input` from `start` seconds into `folder` (an empty folder from
    /// `SessionFolders`), and returns once the first segments and `master.m3u8` are ready.
    ///
    /// Cancelling the calling task stops ffmpeg and throws `CancellationError`. If ffmpeg fails
    /// first, this throws `TranscodeError.ffmpegFailed`. Either way the folder is deleted.
    public func start(_ plan: ConversionPlan, input: ResolvedInput, from start: Double = 0,
                      in folder: URL) async throws -> TranscodeSession {
        let session: TranscodeSession
        do {
            let offset = try await sessionOffset(plan, input: input, start: start)
            let process = try BackgroundProcess(
                tools.ffmpeg, arguments: plan.ffmpegArguments(input: input, start: start, output: folder))
            session = TranscodeSession(
                folder: folder, requestedStart: start, offset: offset, process: process,
                segmentsBeforeReady: segmentsBeforeReady, frameRate: plan.frameRate, videoRange: plan.videoRange)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        do {
            try await withTaskCancellationHandler {
                try await session.waitUntilReady()
            } onCancel: {
                session.cancelStart()
            }
            return session
        } catch {
            await session.stop()
            throw error
        }
    }

    /// The movie time at which the session's stream begins. Copying video can only start on a
    /// keyframe, so ffmpeg goes back to the keyframe before `start`; a one-packet run with the
    /// same seek reports where that is. Re-encoded video starts exactly at `start`.
    func sessionOffset(_ plan: ConversionPlan, input: ResolvedInput, start: Double) async throws -> Double {
        guard start > 0, case .copy = plan.videoAction, input.inputs.indices.contains(plan.video.input) else {
            return start
        }
        let video = input.inputs[plan.video.input]
        let arguments = ["-hide_banner", "-nostdin", "-loglevel", "error"] + video.ffmpegOptions + [
            "-ss", String(format: "%.3f", start), "-i", video.ffmpegLocation,
            "-map", "0:\(plan.video.index)", "-c", "copy", "-frames:v", "1", "-f", "framecrc", "-",
        ]
        let result = try await ProcessRunner.run(tools.ffmpeg, arguments: arguments)
        guard result.status == 0,
              let firstPacket = Self.firstPacketTime(framecrc: String(decoding: result.stdout, as: UTF8.self))
        else { return start }
        return max(0, start + firstPacket)
    }

    /// The first packet's presentation time, in seconds relative to the seek point, from
    /// ffmpeg's framecrc output (`#tb 0: 1/1000`, then `0, dts, pts, duration, size, crc`).
    static func firstPacketTime(framecrc: String) -> Double? {
        var timeBase: Double?
        for line in framecrc.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("#tb 0:") {
                let parts = line.dropFirst("#tb 0:".count).split(separator: "/")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, let numerator = Double(parts[0]), let denominator = Double(parts[1]),
                   denominator != 0 {
                    timeBase = numerator / denominator
                }
            } else if !line.hasPrefix("#") {
                let fields = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard let timeBase, fields.count >= 3, let pts = Double(fields[2]) else { return nil }
                return pts * timeBase
            }
        }
        return nil
    }
}

/// One ffmpeg run writing HLS into a session folder (a "session", spec §4.2).
public final class TranscodeSession: Sendable {
    public let folder: URL
    /// Where the user asked to start, in seconds of movie time.
    public let requestedStart: Double
    /// The movie time at the start of this session's stream: movie time = offset + player time.
    /// Earlier than `requestedStart` when copied video had to start at a keyframe.
    public let offset: Double
    /// Segment progress, then `.finished` or `.failed`. One consumer at a time.
    public let events: AsyncStream<TranscodeEvent>

    private struct State {
        var isReady = false
        var startFailure: (any Error)?
        var readyWaiter: CheckedContinuation<Void, any Error>?
        var isStopping = false
    }

    private let process: BackgroundProcess
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let monitor: Task<Void, Never>

    init(folder: URL, requestedStart: Double, offset: Double, process: BackgroundProcess,
         segmentsBeforeReady: Int, frameRate: Double?, videoRange: VideoRange) {
        self.folder = folder
        self.requestedStart = requestedStart
        self.offset = offset
        self.process = process
        let (events, continuation) = AsyncStream.makeStream(of: TranscodeEvent.self)
        self.events = events
        let state = state
        monitor = Task.detached {
            await Self.watch(folder: folder, process: process, state: state, continuation: continuation,
                             segmentsBeforeReady: segmentsBeforeReady, frameRate: frameRate, videoRange: videoRange)
        }
    }

    /// Pauses ffmpeg (SIGSTOP), for when it is far enough ahead of the player (spec §4.2).
    public func pause() {
        process.send(SIGSTOP)
    }

    /// Resumes a paused ffmpeg (SIGCONT).
    public func resume() {
        process.send(SIGCONT)
    }

    /// Stops ffmpeg, waits for it to exit and deletes the session folder. Safe to call twice.
    public func stop() async {
        let alreadyStopping = state.withLock { state in
            defer { state.isStopping = true }
            return state.isStopping
        }
        if !alreadyStopping {
            process.send(SIGTERM)
            process.send(SIGCONT) // a paused ffmpeg only acts on SIGTERM once it runs again
        }
        let process = process
        let escalation = Task {
            try await Task.sleep(for: .seconds(5))
            process.send(SIGKILL)
        }
        _ = await process.waitForExit()
        escalation.cancel()
        await monitor.value
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Start

    func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let result: Result<Void, any Error>? = state.withLock { state in
                if state.isReady { return .success(()) }
                if let failure = state.startFailure { return .failure(failure) }
                state.readyWaiter = continuation
                return nil
            }
            if let result {
                continuation.resume(with: result)
            }
        }
    }

    /// Called when the task starting this session is cancelled.
    func cancelStart() {
        Self.finishStart(state, with: .failure(CancellationError()))
        process.send(SIGTERM)
    }

    private static func finishStart(_ state: OSAllocatedUnfairLock<State>, with result: Result<Void, any Error>) {
        let waiter = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            guard !state.isReady, state.startFailure == nil else { return nil }
            switch result {
            case .success: state.isReady = true
            case .failure(let error): state.startFailure = error
            }
            defer { state.readyWaiter = nil }
            return state.readyWaiter
        }
        waiter?.resume(with: result)
    }

    // MARK: - Watching ffmpeg

    /// Polls ffmpeg's playlist until ffmpeg exits, reporting each new segment, and writes the
    /// master playlist once enough segments exist.
    private static func watch(folder: URL, process: BackgroundProcess, state: OSAllocatedUnfairLock<State>,
                              continuation: AsyncStream<TranscodeEvent>.Continuation,
                              segmentsBeforeReady: Int, frameRate: Double?, videoRange: VideoRange) async {
        let playlistURL = folder.appendingPathComponent(MasterPlaylist.mediaPlaylistName)
        var reported = 0
        var end = 0.0
        var sizes: [(bytes: Int, duration: Double)] = []
        var isReady = false
        while true {
            // Read the exit status before the playlist, so the last segments are never missed.
            let exitStatus = process.exitStatus
            let playlist = MediaPlaylist(parsing: (try? String(contentsOf: playlistURL, encoding: .utf8)) ?? "")
            for segment in playlist.segments.dropFirst(reported) {
                end += segment.duration
                sizes.append((fileSize(folder.appendingPathComponent(segment.uri)), segment.duration))
                continuation.yield(.segment(index: reported, end: end))
                reported += 1
            }

            if !isReady, reported >= segmentsBeforeReady || (exitStatus == 0 && reported > 0) {
                isReady = true
                let master = MasterPlaylist.text(
                    bandwidth: MasterPlaylist.bandwidth(segmentSizes: sizes),
                    initSegment: InitSegment((try? Data(contentsOf: folder.appendingPathComponent("init.mp4"))) ?? Data()),
                    frameRate: frameRate,
                    videoRange: videoRange)
                do {
                    try master.write(to: folder.appendingPathComponent(MasterPlaylist.fileName),
                                     atomically: true, encoding: .utf8)
                    finishStart(state, with: .success(()))
                } catch {
                    finishStart(state, with: .failure(TranscodeError.cannotWriteMasterPlaylist))
                }
            }

            if let exitStatus {
                let stopping = state.withLock { $0.isStopping }
                if exitStatus == 0 && reported > 0 {
                    continuation.yield(.finished)
                } else if !stopping {
                    let message = Redaction.summary(of: process.stderr)
                    if isReady {
                        continuation.yield(.failed(message))
                    } else {
                        finishStart(state, with: .failure(TranscodeError.ffmpegFailed(status: exitStatus, message: message)))
                    }
                }
                finishStart(state, with: .failure(CancellationError())) // no-op unless stopped before ready
                break
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        continuation.finish()
    }

    private static func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
    }
}
```

- [ ] **Step 7: Run the tests**

Run: `scripts/test-core.sh --filter 'TranscoderTests|TranscoderMediaTests|SessionFoldersTests'`
Expected: `✔ Test run with 16 tests in 3 suites passed`. `pauseHoldsFFmpegUntilResume()` takes about 2 s by design.

If `applesPlayerAcceptsTheMasterPlaylist` fails for `hevc_hdr10_aac.mkv`, look at `FRAME-RATE` in its master playlist first.

Run it three times. The fake-ffmpeg tests depend on timing, and they must never be flaky:

```bash
for i in 1 2 3; do scripts/test-core.sh --filter 'TranscoderTests|TranscoderMediaTests|SessionFoldersTests' 2>&1 | tail -1; done
```

Then run `scripts/test-core.sh`. Expected: everything passes, with only `toneMapsHDRForAnSDRTV()` skipped.

- [ ] **Step 8: Commit**

```bash
git add core/Sources/PaperPlaneCore/Streaming core/Sources/PaperPlaneCore/Support/BackgroundProcess.swift core/Tests/PaperPlaneCoreTests/TranscoderTests.swift core/Tests/PaperPlaneCoreTests/TestSupport.swift
git commit -m "feat(core): Transcoder runs ffmpeg into a session folder with segment events" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: `StreamServer`

Serves one session folder over HTTP with Network.framework:
- It binds to the Mac's LAN address, because the TV fetches every segment itself (Sony row 0).
- It listens on a random port, and only answers under a random 128-bit token path.
- It reads each file when it's requested, so a playlist ffmpeg is still rewriting, and segments that appear later, are always served as they are now.
- It answers one request per connection and closes it.

**Files:**
- Create: `core/Sources/PaperPlaneCore/Serving/FileResponder.swift`, `core/Sources/PaperPlaneCore/Serving/StreamServer.swift`, `core/Sources/PaperPlaneCore/Serving/LANAddress.swift`
- Test: `core/Tests/PaperPlaneCoreTests/StreamServerTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `public final class StreamServer: Sendable`:
    - `static func start(serving folder: URL, on host: String) async throws -> StreamServer`. It throws at once if the address isn't this Mac's.
    - `baseURL` (`http://<host>:<port>/<token>/`), `url(for file: String) -> URL` and `stop()`.
  - `public enum LANAddress` with `static func current() -> String?`. Internally: `struct Interface`, `pick(from:)` and `interfaces()`.
  - `struct FileResponder { var folder: URL; var token: String; func response(to head: String) -> Data }`, plus `static func byteRange(_:size:) -> ByteRange` and `static let contentTypes`.

- [ ] **Step 1: Write the failing tests**

`core/Tests/PaperPlaneCoreTests/StreamServerTests.swift`:
- `FileResponderTests` are pure. They cover tokens, path tricks, content types, HEAD and byte ranges.
- `StreamServerTests` run the real server on `127.0.0.1`. Loopback keeps the macOS firewall out of it. The LAN path is exercised by Task 10's smoke test and on the Sony.

```swift
import Foundation
import Testing
@testable import PaperPlaneCore

struct FileResponderTests {
    static let token = "0123456789abcdef0123456789abcdef"

    private func respond(_ head: String, files: [String: String] = ["index.m3u8": "#EXTM3U\n"]) throws -> String {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        for (name, text) in files {
            try Data(text.utf8).write(to: folder.appendingPathComponent(name))
        }
        let data = FileResponder(folder: folder, token: Self.token).response(to: head)
        return String(decoding: data, as: UTF8.self)
    }

    @Test(arguments: [
        "GET /wrongtoken/index.m3u8 HTTP/1.1",
        "GET /index.m3u8 HTTP/1.1",
        "GET /\(token)/ HTTP/1.1",
        "GET /\(token)/../index.m3u8 HTTP/1.1",
        "GET /\(token)/sub/index.m3u8 HTTP/1.1",
        "GET /\(token)/%2e%2e%2fsecret HTTP/1.1",
        "GET /\(token)/.hidden HTTP/1.1",
        "GET /\(token)/missing.m4s HTTP/1.1",
    ])
    func refusesAnythingButAFileUnderTheToken(_ requestLine: String) throws {
        let response = try respond(requestLine + "\r\nHost: x", files: ["index.m3u8": "#EXTM3U\n", ".hidden": "x"])
        #expect(response.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
    }

    @Test func servesAFileWithItsHLSContentType() throws {
        let response = try respond("GET /\(Self.token)/index.m3u8?t=1 HTTP/1.1\r\nHost: x")
        #expect(response == [
            "HTTP/1.1 200 OK", "Content-Type: application/vnd.apple.mpegurl", "Accept-Ranges: bytes",
            "Cache-Control: no-cache", "Content-Length: 8", "Connection: close", "", "#EXTM3U\n",
        ].joined(separator: "\r\n"))
    }

    @Test func headSendsHeadersOnly() throws {
        let response = try respond("HEAD /\(Self.token)/index.m3u8 HTTP/1.1")
        #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(response.contains("Content-Length: 8\r\n"))
        #expect(response.hasSuffix("\r\n\r\n"))
    }

    @Test func servesOneByteRange() throws {
        let response = try respond("GET /\(Self.token)/seg_00000.m4s HTTP/1.1\r\nrange: bytes=2-5",
                                   files: ["seg_00000.m4s": "0123456789"])
        #expect(response.hasPrefix("HTTP/1.1 206 Partial Content\r\n"))
        #expect(response.contains("Content-Type: video/iso.segment\r\n"))
        #expect(response.contains("Content-Range: bytes 2-5/10\r\n"))
        #expect(response.hasSuffix("\r\n\r\n2345"))
    }

    @Test func refusesOtherMethodsAndGarbage() throws {
        #expect(try respond("POST /\(Self.token)/index.m3u8 HTTP/1.1").hasPrefix("HTTP/1.1 405 Method Not Allowed\r\n"))
        #expect(try respond("hello").hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
        #expect(try respond("").hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
    }

    @Test(arguments: [
        (nil, FileResponder.ByteRange.whole),
        ("bytes=0-99", .partial(0..<10)),
        ("bytes=3-", .partial(3..<10)),
        ("bytes=-4", .partial(6..<10)),
        ("bytes=-40", .partial(0..<10)),
        ("bytes=10-12", .unsatisfiable),
        ("bytes=-0", .unsatisfiable),
        ("bytes=5-2", .whole),
        ("bytes=0-1,4-5", .whole),
        ("items=0-1", .whole),
        ("bytes=x-y", .whole),
    ] as [(String?, FileResponder.ByteRange)])
    func byteRanges(header: String?, expected: FileResponder.ByteRange) {
        #expect(FileResponder.byteRange(header, size: 10) == expected)
    }

    @Test func contentTypesForEveryHLSFile() {
        #expect(FileResponder.contentTypes == [
            "m3u8": "application/vnd.apple.mpegurl", "m4s": "video/iso.segment", "mp4": "video/mp4",
            "ts": "video/mp2t", "vtt": "text/vtt",
        ])
    }
}

/// The real server on the loopback address.
struct StreamServerTests {
    private func get(_ url: URL, method: String = "GET") async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, try #require(response as? HTTPURLResponse))
    }

    @Test func servesTheFolderUnderARandomTokenOnly() async throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("#EXTM3U\n".utf8).write(to: folder.appendingPathComponent("master.m3u8"))
        let server = try await StreamServer.start(serving: folder, on: "127.0.0.1")
        defer { server.stop() }

        #expect(server.baseURL.absoluteString.wholeMatch(of: /http:\/\/127\.0\.0\.1:\d+\/[0-9a-f]{32}\//) != nil)
        let (data, response) = try await get(server.url(for: "master.m3u8"))
        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "application/vnd.apple.mpegurl")
        #expect(data == Data("#EXTM3U\n".utf8))

        let port = try #require(server.baseURL.port)
        let (_, noToken) = try await get(URL(string: "http://127.0.0.1:\(port)/master.m3u8")!)
        #expect(noToken.statusCode == 404)
        let (_, wrongToken) = try await get(URL(string: "http://127.0.0.1:\(port)/\(String(repeating: "0", count: 32))/master.m3u8")!)
        #expect(wrongToken.statusCode == 404)
    }

    @Test func everyServerHasItsOwnToken() async throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try await StreamServer.start(serving: folder, on: "127.0.0.1")
        let second = try await StreamServer.start(serving: folder, on: "127.0.0.1")
        defer { first.stop(); second.stop() }
        #expect(first.baseURL.lastPathComponent != second.baseURL.lastPathComponent)
    }

    @Test func servesFilesThatAreStillGrowing() async throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let playlist = folder.appendingPathComponent("index.m3u8")
        try Data("#EXTM3U\n#EXTINF:6.0,\nseg_00000.m4s\n".utf8).write(to: playlist)
        let server = try await StreamServer.start(serving: folder, on: "127.0.0.1")
        defer { server.stop() }

        let (before, _) = try await get(server.url(for: "index.m3u8"))
        let (_, missing) = try await get(server.url(for: "seg_00001.m4s"))
        #expect(missing.statusCode == 404)

        let handle = try FileHandle(forWritingTo: playlist)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("#EXTINF:6.0,\nseg_00001.m4s\n".utf8))
        try handle.close()
        try Data(repeating: 7, count: 3_000_000).write(to: folder.appendingPathComponent("seg_00001.m4s"))

        let (after, _) = try await get(server.url(for: "index.m3u8"))
        #expect(after.count > before.count)
        let (segment, response) = try await get(server.url(for: "seg_00001.m4s"))
        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "video/iso.segment")
        #expect(segment.count == 3_000_000)
    }

    @Test func handlesManyRequestsAtOnce() async throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(repeating: 1, count: 500_000).write(to: folder.appendingPathComponent("seg_00000.m4s"))
        let server = try await StreamServer.start(serving: folder, on: "127.0.0.1")
        defer { server.stop() }
        let sizes = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<20 {
                group.addTask { try await get(server.url(for: "seg_00000.m4s")).0.count }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(sizes == Array(repeating: 500_000, count: 20))
    }

    @Test func stopClosesThePort() async throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("x".utf8).write(to: folder.appendingPathComponent("a.m4s"))
        let server = try await StreamServer.start(serving: folder, on: "127.0.0.1")
        server.stop()
        try await Task.sleep(for: .milliseconds(200))
        await #expect(throws: URLError.self) {
            try await get(server.url(for: "a.m4s"))
        }
    }

    @Test func refusesAnAddressThisMacDoesNotHave() async throws {
        await #expect(throws: (any Error).self) {
            try await StreamServer.start(serving: URL(fileURLWithPath: "/tmp"), on: "203.0.113.7")
        }
    }
}

struct LANAddressTests {
    typealias Interface = LANAddress.Interface

    @Test func prefersEn0AndSkipsAddressesATVCannotReach() {
        let interfaces = [
            Interface(name: "lo0", address: "127.0.0.1", isUp: true, isLoopback: true),
            Interface(name: "utun3", address: "10.8.0.2", isUp: true, isLoopback: false),
            Interface(name: "bridge0", address: "192.168.2.1", isUp: true, isLoopback: false),
            Interface(name: "en5", address: "169.254.10.20", isUp: true, isLoopback: false),
            Interface(name: "en1", address: "192.168.0.21", isUp: true, isLoopback: false),
            Interface(name: "en0", address: "192.168.0.13", isUp: true, isLoopback: false),
        ]
        #expect(LANAddress.pick(from: interfaces) == "192.168.0.13")
    }

    @Test func fallsBackToTheNextEthernetOrWiFiInterface() {
        let interfaces = [
            Interface(name: "en0", address: "192.168.0.13", isUp: false, isLoopback: false),
            Interface(name: "en10", address: "10.0.0.9", isUp: true, isLoopback: false),
            Interface(name: "en7", address: "172.20.10.3", isUp: true, isLoopback: false),
        ]
        #expect(LANAddress.pick(from: interfaces) == "172.20.10.3")
    }

    @Test func offlineHasNoAddress() {
        #expect(LANAddress.pick(from: [Interface(name: "lo0", address: "127.0.0.1", isUp: true, isLoopback: true)]) == nil)
    }

    @Test func readsThisMacsInterfaces() {
        #expect(LANAddress.interfaces().contains { $0.name == "lo0" && $0.address == "127.0.0.1" && $0.isLoopback })
    }
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `scripts/test-core.sh --filter 'FileResponderTests|StreamServerTests|LANAddressTests'`
Expected: the build fails with `cannot find 'FileResponder' in scope` (and the same for `StreamServer` and `LANAddress`).

- [ ] **Step 3: Implement `FileResponder`**

`core/Sources/PaperPlaneCore/Serving/FileResponder.swift`:

```swift
import Foundation

/// Answers one HTTP request for a file in a session folder. Only `/<token>/<file name>` is
/// served; everything else is 404. Files are read when asked for, so a playlist ffmpeg is still
/// rewriting and segments that appear later are always current.
struct FileResponder: Sendable {
    var folder: URL
    var token: String

    static let contentTypes = [
        "m3u8": "application/vnd.apple.mpegurl",
        "m4s": "video/iso.segment",
        "mp4": "video/mp4",
        "ts": "video/mp2t",
        "vtt": "text/vtt",
    ]

    /// `head` is the request line and headers, without the blank line that ends them.
    func response(to head: String) -> Data {
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
            return Self.message(400, "Bad Request")
        }
        let method = requestLine[0]
        guard method == "GET" || method == "HEAD" else {
            return Self.message(405, "Method Not Allowed", extraHeaders: ["Allow: GET, HEAD"])
        }
        let path = requestLine[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty, parts[1] == token, Self.isPlainFileName(parts[2]),
              let data = try? Data(contentsOf: folder.appendingPathComponent(String(parts[2])), options: .mappedIfSafe)
        else {
            return Self.message(404, "Not Found")
        }

        let contentType = Self.contentTypes[(String(parts[2]) as NSString).pathExtension.lowercased()]
            ?? "application/octet-stream"
        var status = "200 OK"
        var headers = ["Content-Type: \(contentType)", "Accept-Ranges: bytes", "Cache-Control: no-cache"]
        var body = data
        switch Self.byteRange(header(named: "range", in: lines), size: data.count) {
        case .whole:
            break
        case .partial(let range):
            status = "206 Partial Content"
            headers.append("Content-Range: bytes \(range.lowerBound)-\(range.upperBound - 1)/\(data.count)")
            body = data.subdata(in: range)
        case .unsatisfiable:
            return Self.message(416, "Range Not Satisfiable", extraHeaders: ["Content-Range: bytes */\(data.count)"])
        }
        headers.append("Content-Length: \(body.count)")
        return Self.head(status, headers) + (method == "HEAD" ? Data() : body)
    }

    // MARK: - Ranges

    enum ByteRange: Equatable {
        case whole
        case partial(Range<Int>)
        case unsatisfiable
    }

    /// One `bytes=` range (RFC 9110 §14). Anything else, including several ranges, gets the whole
    /// file, which the RFC allows.
    static func byteRange(_ value: String?, size: Int) -> ByteRange {
        guard let value, value.hasPrefix("bytes="), !value.contains(",") else { return .whole }
        let spec = value.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        guard spec.count == 2 else { return .whole }
        let first = Int(spec[0].trimmingCharacters(in: .whitespaces))
        let last = Int(spec[1].trimmingCharacters(in: .whitespaces))
        switch (first, last) {
        case (let first?, let last?) where first <= last:
            return first < size ? .partial(first..<min(last + 1, size)) : .unsatisfiable
        case (let first?, nil) where spec[1].isEmpty:
            return first < size ? .partial(first..<size) : .unsatisfiable
        case (nil, let suffix?) where spec[0].isEmpty:
            return suffix > 0 && size > 0 ? .partial(max(0, size - suffix)..<size) : .unsatisfiable
        default:
            return .whole
        }
    }

    // MARK: - Helpers

    /// Letters, digits, `.`, `_` and `-`, not starting with `.`: no paths, no hidden files.
    static func isPlainFileName(_ name: Substring) -> Bool {
        guard let first = name.first, first != "." else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    private func header(named name: String, in lines: [String]) -> String? {
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2, pair[0].lowercased() == name {
                return pair[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func head(_ status: String, _ headers: [String]) -> Data {
        Data((["HTTP/1.1 \(status)"] + headers + ["Connection: close", "", ""]).joined(separator: "\r\n").utf8)
    }

    private static func message(_ code: Int, _ reason: String, extraHeaders: [String] = []) -> Data {
        let body = Data("\(reason)\n".utf8)
        let headers = ["Content-Type: text/plain; charset=utf-8", "Content-Length: \(body.count)"] + extraHeaders
        return head("\(code) \(reason)", headers) + body
    }
}
```

- [ ] **Step 4: Implement `StreamServer`**

`core/Sources/PaperPlaneCore/Serving/StreamServer.swift`. One detail matters. When `NWListener` is asked to bind an address the Mac doesn't have, it sits in `.waiting` forever, and that happens if the Mac's IP changes between lookup and start. So `.waiting` counts as failure. Without that, `refusesAnAddressThisMacDoesNotHave` hangs, which is how it was found.

```swift
import Foundation
import Network
import os

/// Serves one session folder over HTTP, so the TV can fetch the stream itself
/// (docs/sony-test-results.md, row 0). Each server listens on a random port and a random
/// 128-bit token path: `http://<host>:<port>/<token>/master.m3u8`.
public final class StreamServer: Sendable {
    /// `http://<host>:<port>/<token>/`
    public let baseURL: URL
    private let listener: NWListener

    private init(baseURL: URL, listener: NWListener) {
        self.baseURL = baseURL
        self.listener = listener
    }

    /// Starts serving `folder` on `host`, an IPv4 address: the Mac's LAN address
    /// (`LANAddress.current()`) for the TV, or `127.0.0.1` in tests.
    public static func start(serving folder: URL, on host: String) async throws -> StreamServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: .any)
        let listener = try NWListener(using: parameters)
        let token = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
        let responder = FileResponder(folder: folder, token: token)
        let queue = DispatchQueue(label: "dev.paperplane.stream-server")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            receiveHead(on: connection, responder: responder, buffer: Data())
        }

        let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { state in
                let result: Result<NWEndpoint.Port, any Error>
                switch state {
                case .ready:
                    guard let port = listener.port else { return }
                    result = .success(port)
                case .failed(let error), .waiting(let error):
                    // .waiting means the address isn't available (say, the Mac's IP just changed),
                    // which waiting won't fix.
                    listener.cancel()
                    result = .failure(error)
                case .cancelled:
                    result = .failure(CancellationError())
                default:
                    return
                }
                let first = resumed.withLock { resumed in
                    defer { resumed = true }
                    return !resumed
                }
                if first {
                    continuation.resume(with: result)
                }
            }
            listener.start(queue: queue)
        }
        return StreamServer(baseURL: URL(string: "http://\(host):\(port.rawValue)/\(token)/")!, listener: listener)
    }

    public func url(for file: String) -> URL {
        baseURL.appendingPathComponent(file)
    }

    /// Stops accepting connections. Requests already being answered finish.
    public func stop() {
        listener.cancel()
    }

    /// Reads up to the end of the request headers (at most 16 KB), answers, and closes.
    private static func receiveHead(on connection: NWConnection, responder: FileResponder, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, isComplete, error in
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                connection.send(content: responder.response(to: head), contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { _ in connection.cancel() })
            } else if error != nil || isComplete || buffer.count > 16 * 1024 {
                connection.cancel()
            } else {
                receiveHead(on: connection, responder: responder, buffer: buffer)
            }
        }
    }
}
```

- [ ] **Step 5: Implement `LANAddress`**

`core/Sources/PaperPlaneCore/Serving/LANAddress.swift`:

```swift
import Darwin

/// The Mac's IPv4 address on the local network. The TV fetches the stream itself, so the
/// server must listen there, not on `localhost` (docs/sony-test-results.md, row 0).
public enum LANAddress {
    struct Interface: Equatable {
        var name: String
        var address: String
        var isUp: Bool
        var isLoopback: Bool
    }

    /// Wi-Fi or Ethernet, `en0` first. nil when the Mac isn't on a network.
    public static func current() -> String? {
        pick(from: interfaces())
    }

    /// Skips loopback, VPN tunnels (`utun`), bridges and self-assigned `169.254.x.x` addresses,
    /// none of which a TV on the home network can reach.
    static func pick(from interfaces: [Interface]) -> String? {
        interfaces
            .filter { $0.isUp && !$0.isLoopback && $0.name.hasPrefix("en") && !$0.address.hasPrefix("169.254.") }
            .min { (Int($0.name.dropFirst(2)) ?? .max, $0.address) < (Int($1.name.dropFirst(2)) ?? .max, $1.address) }?
            .address
    }

    static func interfaces() -> [Interface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [Interface] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }).map(\.pointee) {
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let flags = Int32(entry.ifa_flags)
            result.append(Interface(
                name: String(cString: entry.ifa_name),
                address: String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
                isUp: flags & IFF_UP != 0 && flags & IFF_RUNNING != 0,
                isLoopback: flags & IFF_LOOPBACK != 0))
        }
        return result
    }
}
```

- [ ] **Step 6: Run the tests**

Run: `scripts/test-core.sh --filter 'FileResponderTests|StreamServerTests|LANAddressTests'`
Expected: `✔ Test run with 17 tests in 3 suites passed` in well under a second. If the run hangs, a listener state isn't being handled; see Step 4.

- [ ] **Step 7: Commit**

```bash
git add core/Sources/PaperPlaneCore/Serving core/Tests/PaperPlaneCoreTests/StreamServerTests.swift
git commit -m "feat(core): StreamServer serves a session folder on the LAN behind a random token" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: `StreamPipeline`, which files to accept, and the bundled tools

Joins Tasks 6 and 7 into one call the app makes: probe → plan → transcode → serve. Also decides which dropped files are videos (Plan 1 review), and finds the ffmpeg inside the app bundle.

**Files:**
- Create: `core/Sources/PaperPlaneCore/Playback/StreamPipeline.swift`, `core/Sources/PaperPlaneCore/Playback/VideoFiles.swift`
- Modify: `core/Sources/PaperPlaneCore/Support/ToolPaths.swift` (add `inBundle(at:)`)
- Test: `core/Tests/PaperPlaneCoreTests/StreamPipelineTests.swift`, `core/Tests/PaperPlaneCoreTests/ToolPathsTests.swift`

**Interfaces:**
- Consumes: `MediaProbe`, `ConversionPlanner`, `ResolvedInput` (Plan 1); `Transcoder`, `TranscodeSession`, `SessionFolders` (Task 6); `StreamServer` (Task 7); `MasterPlaylist.fileName` (Task 5).
- Produces:
  - `public struct StreamPipeline`:
    - `init(tools:folders: = .standard, profile: = .default, host:)`.
    - `start(_ input: ResolvedInput) async throws -> ServedStream`. Cancelling it stops everything and leaves no folder.
  - `public final class ServedStream: Sendable`:
    - Properties: `title`, `media`, `plan`, `session` and `server`.
    - `url` is the master playlist; `stop() async`.
  - `public enum VideoFiles` with `isVideo(_:) -> Bool`, `videos(in:) -> [URL]` and `contentTypes: [UTType]`, the types for open panels.
  - `ToolPaths.inBundle(at bundleURL: URL) -> ToolPaths?`, which looks in `Contents/Helpers/`.

- [ ] **Step 1: Write the failing tests**

`core/Tests/PaperPlaneCoreTests/StreamPipelineTests.swift`:

```swift
import AVFoundation
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import PaperPlaneCore

@Suite(.enabled(if: TestSupport.hasMedia, "Needs ffmpeg (brew install ffmpeg) and scripts/make-test-media.sh"))
struct StreamPipelineTests {
    private func pipeline(_ root: URL) throws -> StreamPipeline {
        StreamPipeline(tools: try #require(TestSupport.tools), folders: SessionFolders(root: root), host: "127.0.0.1")
    }

    /// Milestone 1's case: an MKV whose video is copied plays from the served URL.
    @Test func servesACopyModeMKVThatApplesPlayerAccepts() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stream = try await pipeline(root).start(.file(TestSupport.media("h264_ac3_51.mkv")))

        #expect(stream.title == "h264_ac3_51")
        #expect(stream.plan.videoAction == .copy(.h264))
        #expect(stream.url.lastPathComponent == "master.m3u8")
        #expect(stream.url.host == "127.0.0.1")
        let asset = AVURLAsset(url: stream.url)
        let playable = try await asset.load(.isPlayable)
        let folder = stream.session.folder

        await stream.stop()
        #expect(playable)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        await #expect(throws: URLError.self) {
            _ = try await URLSession.shared.data(from: stream.url)
        }
    }

    @Test func unreadableFilesFailWithoutLeavingAFolder() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: MediaProbeError.self) {
            try await pipeline(root).start(.file(TestSupport.media("corrupt.mkv")))
        }
        await #expect(throws: PlanError.noVideoTrack) {
            try await pipeline(root).start(.file(TestSupport.media("audio_only.m4a")))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func cancellingTheStartLeavesNothingBehind() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = try pipeline(root)
        let start = Task { try await pipeline.start(.file(TestSupport.media("vp9_opus.webm"))) }
        start.cancel()
        _ = try? await start.value
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}

struct VideoFilesTests {
    @Test(arguments: ["Movie.mkv", "clip.MP4", "home.mov", "talk.webm", "show.m4v", "broadcast.ts", "old.avi",
                      "Movie: Part 1 (Director's Cut) é.mkv"])
    func acceptsVideo(_ name: String) {
        #expect(VideoFiles.isVideo(URL(fileURLWithPath: "/Movies/\(name)")))
    }

    @Test(arguments: ["song.mp3", "song.m4a", "Movie.srt", "cover.png", "notes.txt", "README", "Movie.mkv.part"])
    func rejectsEverythingElse(_ name: String) {
        #expect(!VideoFiles.isVideo(URL(fileURLWithPath: "/Movies/\(name)")))
    }

    @Test func rejectsFoldersAndWebURLs() {
        #expect(!VideoFiles.isVideo(URL(fileURLWithPath: "/Movies/Season 1.mkv/", isDirectory: true)))
        #expect(!VideoFiles.isVideo(URL(string: "https://example.com/video.mp4")!))
    }

    @Test func openPanelsOfferMatroskaAndOrdinaryMovies() {
        let types = VideoFiles.contentTypes
        for name in ["mkv", "webm", "mp4", "mov"] {
            let type = UTType(filenameExtension: name)!
            #expect(types.contains { type.conforms(to: $0) }, "\(name)")
        }
        #expect(!types.contains { UTType.mp3.conforms(to: $0) })
    }

    @Test func keepsOnlyVideosInOrder() {
        let urls = ["b.mkv", "a.srt", "c.mp4"].map { URL(fileURLWithPath: "/Movies/\($0)") }
        #expect(VideoFiles.videos(in: urls).map(\.lastPathComponent) == ["b.mkv", "c.mp4"])
    }
}
```

In `ToolPathsTests`, add before `makeExecutable(named:in:)`:

```swift
    @Test func findsToolsInsideTheAppBundle() throws {
        let app = try TestSupport.makeTemporaryDirectory().appendingPathComponent("Paper Plane.app")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let helpers = app.appendingPathComponent("Contents/Helpers")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        #expect(ToolPaths.inBundle(at: app) == nil)

        let ffmpeg = try makeExecutable(named: "ffmpeg", in: helpers)
        #expect(ToolPaths.inBundle(at: app) == nil)
        let ffprobe = try makeExecutable(named: "ffprobe", in: helpers)
        #expect(ToolPaths.inBundle(at: app) == ToolPaths(ffmpeg: ffmpeg, ffprobe: ffprobe))
    }
```

- [ ] **Step 2: Run them and watch them fail**

Run: `scripts/test-core.sh --filter 'StreamPipelineTests|VideoFilesTests|ToolPathsTests'`
Expected: the build fails with `cannot find 'StreamPipeline' in scope`, `cannot find 'VideoFiles' in scope` and `type 'ToolPaths' has no member 'inBundle'`.

- [ ] **Step 3: Implement `StreamPipeline`**

`core/Sources/PaperPlaneCore/Playback/StreamPipeline.swift`:

```swift
import Foundation

/// Probe → plan → transcode → serve: turns a video into a URL the TV can play
/// (spec §4, steps 2, 4 and 5).
public struct StreamPipeline: Sendable {
    public var tools: ToolPaths
    public var folders: SessionFolders
    public var profile: OutputProfile
    /// The IPv4 address the stream server listens on: `LANAddress.current()` in the app,
    /// `127.0.0.1` in tests.
    public var host: String

    public init(tools: ToolPaths, folders: SessionFolders = .standard, profile: OutputProfile = .default,
                host: String) {
        self.tools = tools
        self.folders = folders
        self.profile = profile
        self.host = host
    }

    /// Returns once the first segments are ready and served. Cancelling the calling task stops
    /// everything and deletes the session folder.
    public func start(_ input: ResolvedInput) async throws -> ServedStream {
        let media = try await MediaProbe(tools: tools).probe(input)
        let plan = try ConversionPlanner.plan(media, profile: profile)
        let session = try await Transcoder(tools: tools).start(plan, input: input, in: try folders.create())
        do {
            try Task.checkCancellation()
            let server = try await StreamServer.start(serving: session.folder, on: host)
            return ServedStream(title: input.title, media: media, plan: plan, session: session, server: server)
        } catch {
            await session.stop()
            throw error
        }
    }
}

/// A video being converted and served. Call `stop()` when playback ends.
public final class ServedStream: Sendable {
    public let title: String
    public let media: MediaInfo
    public let plan: ConversionPlan
    public let session: TranscodeSession
    public let server: StreamServer

    init(title: String, media: MediaInfo, plan: ConversionPlan, session: TranscodeSession, server: StreamServer) {
        self.title = title
        self.media = media
        self.plan = plan
        self.session = session
        self.server = server
    }

    /// What the player opens: the master playlist.
    public var url: URL {
        server.url(for: MasterPlaylist.fileName)
    }

    /// Stops serving and converting, and deletes the session folder.
    public func stop() async {
        server.stop()
        await session.stop()
    }
}
```

- [ ] **Step 4: Implement `VideoFiles`**

`core/Sources/PaperPlaneCore/Playback/VideoFiles.swift`. Some extensions are listed explicitly because macOS doesn't call `.mkv` or `.webm` a movie unless an installed app declares it. The app declares both in Task 10.

```swift
import Foundation
import UniformTypeIdentifiers

/// Which dropped or opened files Paper Plane tries to play.
public enum VideoFiles {
    /// Containers ffmpeg reads that macOS may not know as movies.
    static let knownExtensions: Set<String> = [
        "mkv", "webm", "avi", "wmv", "asf", "flv", "f4v", "ts", "m2ts", "mts", "vob", "ogv", "rmvb", "divx", "3gp",
    ]

    /// True for files whose type is a movie or video. Folders, audio, subtitles and images are
    /// left out.
    public static func isVideo(_ url: URL) -> Bool {
        guard url.isFileURL, !url.hasDirectoryPath else { return false }
        let pathExtension = url.pathExtension.lowercased()
        if knownExtensions.contains(pathExtension) {
            return true
        }
        guard !pathExtension.isEmpty, let type = UTType(filenameExtension: pathExtension) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    /// What an open panel should offer: movies and videos, plus the containers above.
    public static var contentTypes: [UTType] {
        [.movie, .video] + knownExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
    }

    /// The video files among `urls`, in order.
    public static func videos(in urls: [URL]) -> [URL] {
        urls.filter(isVideo)
    }
}
```

- [ ] **Step 5: Find the bundled tools**

In `ToolPaths.swift`, add this before `find(_:override:in:)`:

```swift
    /// The ffmpeg and ffprobe the app ships, in `Contents/Helpers/` of the bundle at `bundleURL`.
    /// nil if either is missing (a development build made without scripts/build-ffmpeg.sh).
    public static func inBundle(at bundleURL: URL) -> ToolPaths? {
        let helpers = bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        let ffmpeg = helpers.appendingPathComponent("ffmpeg")
        let ffprobe = helpers.appendingPathComponent("ffprobe")
        let files = FileManager.default
        guard files.isExecutableFile(atPath: ffmpeg.path), files.isExecutableFile(atPath: ffprobe.path) else {
            return nil
        }
        return ToolPaths(ffmpeg: ffmpeg, ffprobe: ffprobe)
    }
```

- [ ] **Step 6: Run the tests**

Run: `scripts/test-core.sh --filter 'StreamPipelineTests|VideoFilesTests|ToolPathsTests'`
Expected: `✔ Test run with 12 tests in 3 suites passed`.

Then run the whole suite with both ffmpegs:

```bash
scripts/test-core.sh
PAPERPLANE_FFMPEG="$PWD/vendor/ffmpeg/bin/ffmpeg" PAPERPLANE_FFPROBE="$PWD/vendor/ffmpeg/bin/ffprobe" scripts/test-core.sh
```

Expected:
- First run: `✔ Test run with 116 tests in 21 suites passed`, with `toneMapsHDRForAnSDRTV()` skipped.
- Second run: the same 116 tests pass, with nothing skipped.

- [ ] **Step 7: Commit**

```bash
git add core/Sources/PaperPlaneCore/Playback core/Sources/PaperPlaneCore/Support/ToolPaths.swift core/Tests/PaperPlaneCoreTests/StreamPipelineTests.swift core/Tests/PaperPlaneCoreTests/ToolPathsTests.swift
git commit -m "feat(core): StreamPipeline from file to served URL; accept only video files" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Sony re-test with master playlists (owner at the TV, optional, about 5 minutes)

Plan 1's review asked whether a master playlist changes what the Sony does. It might bring back Dolby audio (rows 3 and 4 failed), or show the HDR indicator (row 6 didn't). Paper Plane now always serves one (Task 5), so this also checks its three new tags on the real TV. All four streams already play on the Mac's AVPlayer.

If the owner can't do this now, record "not run" for each row and carry on. The defaults are the safe choice: surround stays off, and the app seeks to 0.

**Files:**
- Create: `spikes/sony-test/make-retest-playlists.sh`
- Modify: `spikes/sony-test/main.swift` (four stream entries)
- Modify: `docs/sony-test-results.md` (new section)
- Modify, only if R1 and R2 both play: `core/Sources/PaperPlaneCore/Conversion/ConversionPlan.swift`, `core/Tests/PaperPlaneCoreTests/ConversionPlannerTests.swift`, `core/Tests/PaperPlaneCoreTests/PipelineTests.swift`, the spec (§4.1 profile sentence, §10)

**Interfaces:**
- Consumes: the spike from Plan 1 (`make-streams.sh`, `start-live.sh`, `build.sh`, `scripts/serve-hls.py`).
- Produces: three decisions that Task 10 applies.
  - **Surround:** whether `OutputProfile.default.surround` becomes `true`.
  - **Live start:** `PlaybackController.seeksToStartOnTV` is `false` only if R4 started at 0.
  - **HDR:** if R3 doesn't play at all, HDR plans open `index.m3u8` instead of the master.

- [ ] **Step 1: Write the playlist script**

`spikes/sony-test/make-retest-playlists.sh` (then `chmod +x`). The codec strings were read from the init segments `make-streams.sh` writes.

```bash
#!/usr/bin/env bash
# Plan 2 re-test (optional, about 5 minutes at the TV): master playlists for streams that
# make-streams.sh and start-live.sh already build, to see whether CODECS lets the Sony play
# Dolby audio, whether VIDEO-RANGE=PQ brings up its HDR indicator, and whether
# EXT-X-START:TIME-OFFSET=0 makes it start a growing playlist at the beginning.
# Throwaway. The codec strings come from the init segments make-streams.sh writes. FRAME-RATE
# matters: AVFoundation refuses a VIDEO-RANGE=PQ variant without it.
set -euo pipefail
cd "$(dirname "$0")"
OUT=streams
for name in ac3 eac3 hdr10; do
  [[ -f "$OUT/$name/index.m3u8" ]] || { echo "Run make-streams.sh first ($OUT/$name is missing)." >&2; exit 1; }
done

master() { # master <file> <EXT-X-STREAM-INF attributes> <media playlist URI> [extra tag]
  {
    echo "#EXTM3U"
    echo "#EXT-X-VERSION:7"
    echo "#EXT-X-INDEPENDENT-SEGMENTS"
    [[ -n ${4:-} ]] && echo "$4"
    echo "#EXT-X-STREAM-INF:$2"
    echo "$3"
  } > "$1"
  echo "wrote $1"
}

master "$OUT/ac3/master.m3u8" 'BANDWIDTH=6000000,CODECS="avc1.640028,ac-3",RESOLUTION=1920x1080,FRAME-RATE=30.000,VIDEO-RANGE=SDR' index.m3u8
master "$OUT/eac3/master.m3u8" 'BANDWIDTH=6000000,CODECS="avc1.640028,ec-3",RESOLUTION=1920x1080,FRAME-RATE=30.000,VIDEO-RANGE=SDR' index.m3u8
master "$OUT/hdr10/master.m3u8" 'BANDWIDTH=20000000,CODECS="hvc1.2.4.L150.90,mp4a.40.2",RESOLUTION=3840x2160,FRAME-RATE=30.000,VIDEO-RANGE=PQ' index.m3u8
# start-live.sh deletes streams/live/ when it starts, so this one lives next to it.
mkdir -p "$OUT/livestart"
master "$OUT/livestart/master.m3u8" 'BANDWIDTH=6000000,CODECS="avc1.640028,mp4a.40.2",RESOLUTION=1920x1080,FRAME-RATE=30.000,VIDEO-RANGE=SDR' \
  ../live/index.m3u8 '#EXT-X-START:TIME-OFFSET=0'
```

- [ ] **Step 2: Add the streams to the spike app**

In `spikes/sony-test/main.swift`, add these entries at the end of the `streams` array, after the `7 Live` entry:

```swift
    // Plan 2 re-test: master playlists from make-retest-playlists.sh.
    ("R1 AC3 5.1 + master playlist with CODECS", "ac3/master.m3u8"),
    ("R2 E-AC3 5.1 + master playlist with CODECS", "eac3/master.m3u8"),
    ("R3 HDR10 + VIDEO-RANGE=PQ", "hdr10/master.m3u8"),
    ("R4 Live + EXT-X-START:TIME-OFFSET=0", "livestart/master.m3u8"),
```

- [ ] **Step 3: Build and check on the Mac**

```bash
spikes/sony-test/make-streams.sh          # only if spikes/sony-test/streams/ is missing (a few minutes)
spikes/sony-test/make-retest-playlists.sh
spikes/sony-test/build.sh
```

Expected: four `wrote streams/…/master.m3u8` lines, then `Built build/SonyTest.app`.

- [ ] **Step 4: Add the results sheet**

Append to `docs/sony-test-results.md`:

```markdown
## Plan 2 re-test: master playlists

Optional, about 5 minutes. Run `spikes/sony-test/make-retest-playlists.sh` once, then follow "How to run" above and load the R streams. Start `start-live.sh` about 2 minutes before R4.

| # | Stream / check | What to look for | Result |
|---|---|---|---|
| R1 | H.264 + AC3 5.1 behind a master playlist with `CODECS="avc1.640028,ac-3"` | Plays with sound? Or drops to the AirPlay home screen like row 3? | |
| R2 | H.264 + E-AC3 5.1 behind a master playlist with `CODECS="avc1.640028,ec-3"` | Same as R1 | |
| R3 | HDR10 HEVC (4K) behind a master playlist with `VIDEO-RANGE=PQ` and `FRAME-RATE` | Plays? Does the TV show its HDR indicator now? | |
| R4 | Live, master playlist with `#EXT-X-START:TIME-OFFSET=0` | Load about 2 min after starting `start-live.sh`. Does Terminal A show the TV fetching segment 0 first (start at 0 s), or a late segment (live edge)? | |

### Re-test decisions

Filled in by Plan 2 Task 9 from the results above.

- Surround: 
- HDR: 
- Live start: 
```

- [ ] **Step 5: Run the re-test with the owner at the TV**

Ask the owner to run the four rows (the same setup as Plan 1 Task 3) and tell you the results. Fill in the Result column in their words.

- [ ] **Step 6: Apply the decision rules**

Fill in the three Decisions lines exactly by these rules. Write "not run; defaults kept" for any row that wasn't run.

- **Surround:** if R1 **and** R2 both played with sound, write "on: master playlists with CODECS make the Sony play AC3 and E-AC3", and make these changes:
  - In `ConversionPlan.swift`, set `OutputProfile.default` to `OutputProfile(surround: true, hdr: true)`.
  - In `ConversionPlannerTests.defaultProfileMatchesTheSonyResults`, expect `OutputProfile(surround: true, hdr: true)`, and change its comment to cite rows R1 and R2.
  - In `PipelineTests.cases`, change the two cases from Task 1 to `audio: .eac3, channels: 6`, and their comment to "With the default profile (surround on), 7.1 lossless audio and DTS both become E-AC3 5.1." The `h264_ac3_51.mkv` case keeps its explicit `OutputProfile(surround: false, hdr: true)`.
  - In the spec, change §4.1's "surround **off**" to "surround **on**". In §10, end the first row with "Plan 2 re-test: AC3/E-AC3 play behind a master playlist with CODECS, so surround is on."
  
  Otherwise, write "off: unchanged" and change nothing.
- **HDR:** write whether R3 played and whether the HDR indicator appeared. If R3 did **not** play, write "HDR plans open index.m3u8"; Task 10 Step 3 applies it.
- **Live start:** if R4 started at 0 s, write "EXT-X-START works on the Sony: no seek to 0 needed". Otherwise write "keep the seek to 0 after the TV takes over".

- [ ] **Step 7: Run the tests if the default changed**

Run: `scripts/test-core.sh`
Expected: everything passes, with only `toneMapsHDRForAnSDRTV()` skipped. (Nothing changes if surround stayed off.)

- [ ] **Step 8: Commit**

```bash
git add spikes/sony-test/make-retest-playlists.sh spikes/sony-test/main.swift docs/sony-test-results.md
git add -u core docs   # the surround changes, if any
git commit -m "spike: Sony re-test with master playlists; record decisions" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: The app: menu bar, remote window and playback

The Xcode project and the whole app:
- A `MenuBarExtra` with **Open Video…**, **Show Remote**, **Stop** and **Quit**.
- A remote window with the title, the status, the AirPlay button (`AVRoutePickerView` with its `player` set), Play/Pause, Stop and the movie time. Video files can be dropped on it.
- The basic `PlaybackController`, which turns a file into a served stream and plays it only once a TV has taken over.

The project uses Xcode's synchronized folders (`objectVersion = 77`, Xcode 16 or later), so every Swift file in `app/PaperPlane/` is compiled without being listed. `Info.plist` lives outside that folder so it isn't copied as a resource.

How `PlaybackController` follows the Sony decisions:
- After probe → plan → transcode → serve (`StreamPipeline`), it loads the master playlist into `AVPlayer` but doesn't play. Its phase is `.waitingForTV`, and the remote highlights the AirPlay button.
- When `isExternalPlaybackActive` turns true, it plays, then seeks to 0 without waiting for the seek's completion handler. That seek is a safety net for row 7a; the Task 9 re-test may remove it.
- If the TV goes away, it pauses and asks for the TV again. It never plays on the Mac.
- Each open brings the remote forward, because the TV has to be picked every time (row 9).
- Quitting waits for ffmpeg to stop (`applicationShouldTerminate` returns `.terminateLater`).

**Files:**
- Create: `scripts/embed-ffmpeg.sh`, `app/PaperPlane-Info.plist`
- Create: `app/PaperPlane.xcodeproj/project.pbxproj`, `app/PaperPlane.xcodeproj/xcshareddata/xcschemes/PaperPlane.xcscheme`
- Create: `app/PaperPlane/PaperPlaneApp.swift`, `app/PaperPlane/MenuContent.swift`, `app/PaperPlane/RoutePicker.swift`, `app/PaperPlane/RemoteWindow.swift`, `app/PaperPlane/PlaybackController.swift`
- Modify: `README.md`, `docs/superpowers/specs/2026-10-15-paper-plane-design.md` (§9)

**Interfaces:**
- Consumes: from the `PaperPlaneCore` package (local package reference `../core`):
  - `StreamPipeline`, `ServedStream`, `TranscodeSession.events` / `.offset`, `TranscodeEvent` (Tasks 6 and 8).
  - `LANAddress.current()` (Task 7).
  - `VideoFiles` and `ToolPaths.inBundle(at:)` (Task 8), plus `ToolPaths.locate()` (Plan 1).
  - `SessionFolders.standard` (Task 6), `PlanError`, `MediaProbeError` and `TranscodeError`.
  - From Task 3: `vendor/ffmpeg/bin/*`. From Task 9: the re-test decisions.
- Produces: `Paper Plane.app` (bundle ID `dev.paperplane.app`, `LSUIElement`), with ffmpeg and ffprobe in `Contents/Helpers/`. The shared scheme `PaperPlane` is what CI builds.

- [ ] **Step 1: Check Xcode**

Run: `xcode-select -p && xcodebuild -version`
Expected: a path inside `Xcode.app` (not `CommandLineTools`) and Xcode 26 or later. If it points at the Command Line Tools, ask the owner to run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.

- [ ] **Step 2: Write the embedding script**

`scripts/embed-ffmpeg.sh` (then `chmod +x scripts/embed-ffmpeg.sh`). The project's "Embed ffmpeg" build phase runs it. Debug builds without `vendor/ffmpeg` warn and fall back to Homebrew's ffmpeg. Release builds fail, so a shipped app always carries its own.

```bash
#!/bin/sh
# Xcode build phase for the app: copies the bundled ffmpeg and ffprobe (scripts/build-ffmpeg.sh)
# into Paper Plane.app/Contents/Helpers/. Debug builds without them fall back to Homebrew's
# ffmpeg; Release builds refuse, so a shipped app always carries its own.
set -eu
SOURCE="$SRCROOT/../vendor/ffmpeg/bin"
DEST="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
if [ ! -x "$SOURCE/ffmpeg" ] || [ ! -x "$SOURCE/ffprobe" ]; then
  if [ "$CONFIGURATION" = Release ]; then
    echo "error: vendor/ffmpeg/bin is missing. Run scripts/build-ffmpeg.sh first."
    exit 1
  fi
  echo "warning: vendor/ffmpeg/bin is missing, so this build uses Homebrew's ffmpeg. Run scripts/build-ffmpeg.sh."
  rm -rf "$DEST"
  exit 0
fi
mkdir -p "$DEST"
for tool in ffmpeg ffprobe; do
  cp -f "$SOURCE/$tool" "$DEST/$tool"
  codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$DEST/$tool"
done
```

- [ ] **Step 3: Write the app**

`app/PaperPlane/PaperPlaneApp.swift`, the entry point and app delegate:

```swift
import AppKit
import PaperPlaneCore
import SwiftUI

@main
struct PaperPlaneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Paper Plane", systemImage: "paperplane") {
            MenuContent(app: appDelegate, controller: appDelegate.controller)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = PlaybackController()
    private lazy var remote = RemoteWindow(controller: controller, open: { [weak self] urls in self?.open(urls) })

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Whatever a crash left behind (spec §4.2).
        try? SessionFolders.standard.removeAll()
        remote.show()
    }

    /// Finder's Open With, and files dropped on the app.
    func application(_ application: NSApplication, open urls: [URL]) {
        open(urls)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // ffmpeg must not outlive the app.
        Task {
            await controller.shutDown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Plays the first video among `urls`. The remote opens each time, because the TV has to be
    /// picked again for every playback (docs/sony-test-results.md, row 9).
    func open(_ urls: [URL]) {
        remote.show()
        controller.play(urls)
    }

    func showRemote() {
        remote.show()
    }
}
```

`app/PaperPlane/MenuContent.swift`:

```swift
import AppKit
import PaperPlaneCore
import SwiftUI
import UniformTypeIdentifiers

/// The menu bar icon's menu.
struct MenuContent: View {
    let app: AppDelegate
    let controller: PlaybackController

    var body: some View {
        Button("Open Video…") { chooseVideo() }
            .keyboardShortcut("o")
        Button("Show Remote") { app.showRemote() }
        if controller.isActive {
            Button("Stop") { controller.stop() }
        }
        Divider()
        Button("Quit Paper Plane") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func chooseVideo() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = VideoFiles.contentTypes
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            app.open([url])
        }
    }
}
```

`app/PaperPlane/RoutePicker.swift`:

```swift
import AVKit
import SwiftUI

/// The AirPlay button. Setting `player` is what makes macOS list video AirPlay devices such as
/// TVs, not only speakers (spec §2).
struct RoutePicker: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.player = player
        picker.isRoutePickerButtonBordered = false
        return picker
    }

    func updateNSView(_ picker: AVRoutePickerView, context: Context) {
        picker.player = player
    }
}
```

`app/PaperPlane/RemoteWindow.swift`:

```swift
import AppKit
import PaperPlaneCore
import SwiftUI

/// The small "now playing" window (spec §1). Plain AppKit, so it can be shown from anywhere,
/// including Finder's Open With.
@MainActor
final class RemoteWindow {
    private let window: NSWindow

    init(controller: PlaybackController, open: @escaping ([URL]) -> Void) {
        window = NSWindow(contentViewController: NSHostingController(rootView: RemoteView(controller: controller, open: open)))
        window.title = "Paper Plane"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

struct RemoteView: View {
    let controller: PlaybackController
    let open: ([URL]) -> Void
    @State private var isDropTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(controller.title ?? "Nothing playing")
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(controller.status)
                        .foregroundStyle(controller.needsTV ? Color.accentColor : .secondary)
                }
                Spacer()
                RoutePicker(player: controller.player)
                    .frame(width: 32, height: 26)
                    .padding(4)
                    .background(controller.needsTV ? Color.accentColor.opacity(0.25) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .help("Choose your TV")
            }
            HStack(spacing: 10) {
                Button(controller.isPaused ? "Play" : "Pause", systemImage: controller.isPaused ? "play.fill" : "pause.fill") {
                    controller.togglePause()
                }
                .disabled(!controller.isOnTV)
                Button("Stop", systemImage: "stop.fill") {
                    controller.stop()
                }
                .disabled(!controller.isActive)
                Spacer()
                Text(controller.timeText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 440)
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 3).padding(3)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !VideoFiles.videos(in: urls).isEmpty else { return false }
            open(urls)
            return true
        } isTargeted: { isDropTarget = $0 }
    }
}
```

`app/PaperPlane/PlaybackController.swift`:

```swift
import AVFoundation
import Observation
import os
import PaperPlaneCore

/// Plays one video at a time on the TV: probe → plan → transcode → serve → AVPlayer → AirPlay
/// (spec §4). Basic for now; seeking, track changes and recovery come with Milestone 2.
@MainActor @Observable
final class PlaybackController {
    enum Phase: Equatable {
        case idle
        case preparing
        /// Loaded but held paused until a TV is chosen. With no TV, AVPlayer would play on the
        /// Mac (docs/sony-test-results.md, rows 8 and 9).
        case waitingForTV
        case onTV
        case failed(String)
    }

    /// Whether to seek to the start once the TV takes over, in case it began at a growing
    /// playlist's live edge (docs/sony-test-results.md, row 7a and the Plan 2 re-test).
    static let seeksToStartOnTV = true

    let player = AVPlayer()
    private(set) var phase = Phase.idle
    private(set) var title: String?
    private(set) var isPaused = true
    private(set) var movieTime = 0.0
    private(set) var duration: Double?

    @ObservationIgnored private var stream: ServedStream?
    @ObservationIgnored private var starting: Task<Void, Never>?
    @ObservationIgnored private var watchingEvents: Task<Void, Never>?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private let log = Logger(subsystem: "dev.paperplane.app", category: "playback")

    init() {
        player.allowsExternalPlayback = true
        observations = [
            player.observe(\.isExternalPlaybackActive) { [weak self] _, _ in
                Task { @MainActor in self?.externalPlaybackChanged() }
            },
            player.observe(\.timeControlStatus) { [weak self] player, _ in
                let paused = player.timeControlStatus == .paused
                Task { @MainActor in self?.isPaused = paused }
            },
        ]
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 2), queue: .main) {
            [weak self] time in
            MainActor.assumeIsolated { self?.timeChanged(time) }
        }
    }

    // MARK: - State for the UI

    var isActive: Bool {
        switch phase {
        case .preparing, .waitingForTV, .onTV: true
        case .idle, .failed: false
        }
    }

    var isOnTV: Bool { phase == .onTV }
    var needsTV: Bool { phase == .waitingForTV }

    var status: String {
        switch phase {
        case .idle: "Drop a video here, or use Open Video… in the menu bar."
        case .preparing: "Getting the video ready…"
        case .waitingForTV: "Choose your TV with the AirPlay button."
        case .onTV: isPaused ? "Paused on the TV" : "Playing on the TV"
        case .failed(let message): message
        }
    }

    var timeText: String {
        guard isActive else { return "" }
        let elapsed = Self.clock(movieTime)
        return duration.map { "\(elapsed) / \(Self.clock($0))" } ?? elapsed
    }

    // MARK: - Commands

    /// Plays the first video among `urls`, replacing whatever is playing.
    func play(_ urls: [URL]) {
        guard let url = VideoFiles.videos(in: urls).first else {
            if let first = urls.first {
                stop()
                phase = .failed("“\(first.lastPathComponent)” isn't a video file.")
            }
            return
        }
        stop()
        title = url.deletingPathExtension().lastPathComponent
        phase = .preparing
        starting = Task { await start(url) }
    }

    func togglePause() {
        guard phase == .onTV else { return }
        if isPaused {
            player.play()
        } else {
            player.pause()
        }
    }

    func stop() {
        starting?.cancel()
        starting = nil
        watchingEvents?.cancel()
        watchingEvents = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let stream {
            Task { await stream.stop() }
        }
        stream = nil
        title = nil
        phase = .idle
        movieTime = 0
        duration = nil
    }

    /// Stops ffmpeg and waits for it, before the app quits.
    func shutDown() async {
        let stream = stream
        stop()
        await stream?.stop()
    }

    // MARK: - Starting

    private func start(_ url: URL) async {
        do {
            guard let tools = ToolPaths.inBundle(at: Bundle.main.bundleURL) ?? ToolPaths.locate() else {
                throw PlaybackError.noFFmpeg
            }
            guard let host = LANAddress.current() else { throw PlaybackError.offline }
            let stream = try await StreamPipeline(tools: tools, host: host).start(.file(url))
            guard !Task.isCancelled else {
                await stream.stop()
                return
            }
            log.info("Serving \(stream.title, privacy: .public) at \(stream.url.absoluteString, privacy: .private)")
            self.stream = stream
            duration = stream.media.duration
            watchingEvents = Task { await watch(stream.session) }
            player.replaceCurrentItem(with: AVPlayerItem(url: stream.url))
            phase = .waitingForTV
            externalPlaybackChanged()
        } catch is CancellationError {
            // stop() or a newer play() took over.
        } catch {
            log.error("Couldn't play \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            stop()
            phase = .failed(PlaybackError.message(for: error))
        }
    }

    private func watch(_ session: TranscodeSession) async {
        for await event in session.events {
            if case .failed(let message) = event {
                log.error("ffmpeg failed: \(message, privacy: .public)")
                stop()
                phase = .failed("Converting the video stopped part-way through.")
            }
        }
    }

    // MARK: - Player

    private func externalPlaybackChanged() {
        log.info("External playback active: \(self.player.isExternalPlaybackActive), phase: \(String(describing: self.phase), privacy: .public)")
        if player.isExternalPlaybackActive {
            guard phase == .waitingForTV else { return }
            phase = .onTV
            player.play()
            if Self.seeksToStartOnTV {
                // Don't wait for the completion handler: over AirPlay it reports finished == false
                // even when the TV did seek (docs/sony-test-results.md, row 7b).
                player.seek(to: .zero)
            }
        } else if phase == .onTV {
            // The TV went away. Never carry on playing on the Mac.
            player.pause()
            phase = .waitingForTV
        }
    }

    private func timeChanged(_ time: CMTime) {
        guard let stream, time.isNumeric else { return }
        movieTime = stream.session.offset + time.seconds
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

enum PlaybackError: Error {
    case noFFmpeg
    case offline

    /// A plain-language message for the remote. Full error handling is Milestone 2.
    static func message(for error: any Error) -> String {
        switch error {
        case PlaybackError.noFFmpeg: "ffmpeg is missing. Run scripts/build-ffmpeg.sh, or brew install ffmpeg."
        case PlaybackError.offline: "Your Mac isn't on a network, so the TV can't reach it."
        case PlanError.noVideoTrack: "This file has no video."
        case is MediaProbeError: "Paper Plane couldn't read this file."
        case is TranscodeError: "Converting the video failed."
        default: "Something went wrong: \(error.localizedDescription)"
        }
    }
}
```

Now apply the Task 9 decisions recorded in `docs/sony-test-results.md`:
- If "Live start" says "EXT-X-START works on the Sony", set `seeksToStartOnTV = false`. Otherwise leave it `true`, including when the re-test wasn't run.
- If "HDR" says "HDR plans open index.m3u8", replace `player.replaceCurrentItem(with: AVPlayerItem(url: stream.url))` in `start(_:)` with the lines below, and leave `seeksToStartOnTV` `true`, since the media playlist has no `EXT-X-START`:

```swift
            // docs/sony-test-results.md, R3: the Sony refuses HDR behind a master playlist.
            let url = stream.plan.videoRange == .sdr ? stream.url : stream.server.url(for: "index.m3u8")
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
```

- [ ] **Step 4: Write `Info.plist`**

`app/PaperPlane-Info.plist`:
- `LSUIElement` makes Paper Plane a menu bar app with no Dock icon.
- The document types put it in Finder's Open With menu for movies.
- The imported types tell macOS that `.mkv` and `.webm` files are movies.
- `NSLocalNetworkUsageDescription` explains macOS's Local Network prompt.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>Paper Plane</string>
	<key>CFBundleExecutable</key>
	<string>$(EXECUTABLE_NAME)</string>
	<key>CFBundleIdentifier</key>
	<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$(PRODUCT_NAME)</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$(MARKETING_VERSION)</string>
	<key>CFBundleVersion</key>
	<string>$(CURRENT_PROJECT_VERSION)</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.video</string>
	<key>LSMinimumSystemVersion</key>
	<string>$(MACOSX_DEPLOYMENT_TARGET)</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>GPL-3.0</string>
	<key>NSLocalNetworkUsageDescription</key>
	<string>Paper Plane streams video from this Mac to your TV over your local network.</string>
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsLocalNetworking</key>
		<true/>
	</dict>
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key>
			<string>Video</string>
			<key>CFBundleTypeRole</key>
			<string>Viewer</string>
			<key>LSHandlerRank</key>
			<string>Alternate</string>
			<key>LSItemContentTypes</key>
			<array>
				<string>public.movie</string>
				<string>public.video</string>
				<string>org.matroska.mkv</string>
				<string>org.webmproject.webm</string>
			</array>
		</dict>
	</array>
	<key>UTImportedTypeDeclarations</key>
	<array>
		<dict>
			<key>UTTypeIdentifier</key>
			<string>org.matroska.mkv</string>
			<key>UTTypeDescription</key>
			<string>Matroska video</string>
			<key>UTTypeConformsTo</key>
			<array>
				<string>public.movie</string>
			</array>
			<key>UTTypeTagSpecification</key>
			<dict>
				<key>public.filename-extension</key>
				<array>
					<string>mkv</string>
				</array>
				<key>public.mime-type</key>
				<array>
					<string>video/x-matroska</string>
				</array>
			</dict>
		</dict>
		<dict>
			<key>UTTypeIdentifier</key>
			<string>org.webmproject.webm</string>
			<key>UTTypeDescription</key>
			<string>WebM video</string>
			<key>UTTypeConformsTo</key>
			<array>
				<string>public.movie</string>
			</array>
			<key>UTTypeTagSpecification</key>
			<dict>
				<key>public.filename-extension</key>
				<array>
					<string>webm</string>
				</array>
				<key>public.mime-type</key>
				<array>
					<string>video/webm</string>
				</array>
			</dict>
		</dict>
	</array>
</dict>
</plist>
```

- [ ] **Step 5: Write the Xcode project**

`app/PaperPlane.xcodeproj/project.pbxproj`. The object IDs are fixed 24-digit hex strings. Xcode keeps them, and may tidy the file the first time it opens it; commit whatever it writes. Code signing is ad hoc ("Sign to Run Locally"). The owner's Developer ID comes with the first release (spec §10).

```text
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 77;
	objects = {

/* Begin PBXBuildFile section */
		5050504C0000000000000101 /* PaperPlaneCore in Frameworks */ = {isa = PBXBuildFile; productRef = 5050504C0000000000000102 /* PaperPlaneCore */; };
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		5050504C0000000000000002 /* Paper Plane.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "Paper Plane.app"; sourceTree = BUILT_PRODUCTS_DIR; };
		5050504C0000000000000004 /* PaperPlane-Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "PaperPlane-Info.plist"; sourceTree = "<group>"; };
/* End PBXFileReference section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
		5050504C0000000000000003 /* PaperPlane */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = PaperPlane;
			sourceTree = "<group>";
		};
/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXFrameworksBuildPhase section */
		5050504C0000000000000012 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				5050504C0000000000000101 /* PaperPlaneCore in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		5050504C0000000000000001 = {
			isa = PBXGroup;
			children = (
				5050504C0000000000000003 /* PaperPlane */,
				5050504C0000000000000004 /* PaperPlane-Info.plist */,
				5050504C0000000000000005 /* Products */,
			);
			sourceTree = "<group>";
		};
		5050504C0000000000000005 /* Products */ = {
			isa = PBXGroup;
			children = (
				5050504C0000000000000002 /* Paper Plane.app */,
			);
			name = Products;
			sourceTree = "<group>";
		};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		5050504C0000000000000010 /* PaperPlane */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = 5050504C0000000000000030 /* Build configuration list for PBXNativeTarget "PaperPlane" */;
			buildPhases = (
				5050504C0000000000000011 /* Sources */,
				5050504C0000000000000012 /* Frameworks */,
				5050504C0000000000000013 /* Resources */,
				5050504C0000000000000014 /* Embed ffmpeg */,
			);
			buildRules = (
			);
			dependencies = (
			);
			fileSystemSynchronizedGroups = (
				5050504C0000000000000003 /* PaperPlane */,
			);
			name = PaperPlane;
			packageProductDependencies = (
				5050504C0000000000000102 /* PaperPlaneCore */,
			);
			productName = PaperPlane;
			productReference = 5050504C0000000000000002 /* Paper Plane.app */;
			productType = "com.apple.product-type.application";
		};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		5050504C0000000000000000 /* Project object */ = {
			isa = PBXProject;
			attributes = {
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 2710;
				LastUpgradeCheck = 2710;
			};
			buildConfigurationList = 5050504C0000000000000020 /* Build configuration list for PBXProject "PaperPlane" */;
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = 5050504C0000000000000001;
			minimizedProjectReferenceProxies = 1;
			packageReferences = (
				5050504C0000000000000103 /* XCLocalSwiftPackageReference "../core" */,
			);
			preferredProjectObjectVersion = 77;
			productRefGroup = 5050504C0000000000000005 /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				5050504C0000000000000010 /* PaperPlane */,
			);
		};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		5050504C0000000000000013 /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXResourcesBuildPhase section */

/* Begin PBXShellScriptBuildPhase section */
		5050504C0000000000000014 /* Embed ffmpeg */ = {
			isa = PBXShellScriptBuildPhase;
			alwaysOutOfDate = 1;
			buildActionMask = 2147483647;
			files = (
			);
			inputFileListPaths = (
			);
			inputPaths = (
			);
			name = "Embed ffmpeg";
			outputFileListPaths = (
			);
			outputPaths = (
			);
			runOnlyForDeploymentPostprocessing = 0;
			shellPath = /bin/sh;
			shellScript = "\"$SRCROOT/../scripts/embed-ffmpeg.sh\"\n";
		};
/* End PBXShellScriptBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		5050504C0000000000000011 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		5050504C0000000000000021 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				ARCHS = arm64;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_TESTABILITY = YES;
				ENABLE_USER_SCRIPT_SANDBOXING = NO;
				GCC_OPTIMIZATION_LEVEL = 0;
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = macosx;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
				SWIFT_VERSION = 6.0;
			};
			name = Debug;
		};
		5050504C0000000000000022 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				ARCHS = arm64;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_USER_SCRIPT_SANDBOXING = NO;
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				SDKROOT = macosx;
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_VERSION = 6.0;
			};
			name = Release;
		};
		5050504C0000000000000031 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_IDENTITY = "-";
				CODE_SIGN_STYLE = Manual;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				INFOPLIST_FILE = "PaperPlane-Info.plist";
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
				);
				MARKETING_VERSION = 0.1.0;
				PRODUCT_BUNDLE_IDENTIFIER = dev.paperplane.app;
				PRODUCT_NAME = "Paper Plane";
			};
			name = Debug;
		};
		5050504C0000000000000032 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_IDENTITY = "-";
				CODE_SIGN_STYLE = Manual;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				INFOPLIST_FILE = "PaperPlane-Info.plist";
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
				);
				MARKETING_VERSION = 0.1.0;
				PRODUCT_BUNDLE_IDENTIFIER = dev.paperplane.app;
				PRODUCT_NAME = "Paper Plane";
			};
			name = Release;
		};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		5050504C0000000000000020 /* Build configuration list for PBXProject "PaperPlane" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				5050504C0000000000000021 /* Debug */,
				5050504C0000000000000022 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
		5050504C0000000000000030 /* Build configuration list for PBXNativeTarget "PaperPlane" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				5050504C0000000000000031 /* Debug */,
				5050504C0000000000000032 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
/* End XCConfigurationList section */

/* Begin XCLocalSwiftPackageReference section */
		5050504C0000000000000103 /* XCLocalSwiftPackageReference "../core" */ = {
			isa = XCLocalSwiftPackageReference;
			relativePath = ../core;
		};
/* End XCLocalSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
		5050504C0000000000000102 /* PaperPlaneCore */ = {
			isa = XCSwiftPackageProductDependency;
			productName = PaperPlaneCore;
		};
/* End XCSwiftPackageProductDependency section */
	};
	rootObject = 5050504C0000000000000000 /* Project object */;
}
```

`app/PaperPlane.xcodeproj/xcshareddata/xcschemes/PaperPlane.xcscheme`, so `xcodebuild -scheme PaperPlane` works on a fresh checkout and in CI:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2710"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "5050504C0000000000000010"
               BuildableName = "Paper Plane.app"
               BlueprintName = "PaperPlane"
               ReferencedContainer = "container:PaperPlane.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "5050504C0000000000000010"
            BuildableName = "Paper Plane.app"
            BlueprintName = "PaperPlane"
            ReferencedContainer = "container:PaperPlane.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
```

- [ ] **Step 6: Build**

Run: `xcodebuild -list -project app/PaperPlane.xcodeproj`
Expected: target `PaperPlane`, configurations `Debug` and `Release`, schemes `PaperPlane` and `PaperPlaneCore`.

Then:

```bash
xcodebuild -project app/PaperPlane.xcodeproj -scheme PaperPlane -configuration Debug -derivedDataPath build/DerivedData build 2>&1 | grep -E '^/.*: (error|warning):|\*\* BUILD'
```

Expected: `** BUILD SUCCEEDED **` and no `error:` or `warning:` lines.

- [ ] **Step 7: Check the bundle**

```bash
APP="$PWD/build/DerivedData/Build/Products/Debug/Paper Plane.app"
ls "$APP/Contents/Helpers"
codesign --verify --deep --strict "$APP" && echo "signature ok"
plutil -p "$APP/Contents/Info.plist" | grep -E 'LSUIElement|CFBundleIdentifier|LSMinimumSystemVersion'
```

Expected: `ffmpeg` and `ffprobe`; `signature ok`; `LSUIElement => true`, `dev.paperplane.app` and `14.0`.

- [ ] **Step 8: Smoke test without a TV**

This shows the remote window on screen for about 20 seconds, and macOS may ask about Local Network access (allow it). It checks that Open With reaches `PlaybackController`, that the stream is served on the LAN address, and that quitting mid-conversion leaves nothing behind.

```bash
APP="$PWD/build/DerivedData/Build/Products/Debug/Paper Plane.app"
open "$APP"
sleep 3
open -a "$APP" "$PWD/testdata/media/h264_ac3_51.mkv"
sleep 4
ls ~/Library/Caches/Paper\ Plane/sessions/*/
cat ~/Library/Caches/Paper\ Plane/sessions/*/master.m3u8
lsof -nP -iTCP -sTCP:LISTEN -a -c Paper
PORT=$(lsof -nP -iTCP -sTCP:LISTEN -a -c Paper | awk 'NR==2 {sub(/.*:/, "", $9); print $9}')
curl -s -o /dev/null -w '%{http_code}\n' "http://$(ipconfig getifaddr en0):$PORT/master.m3u8"
```

Expected:
- The session folder lists `index.m3u8`, `init.mp4`, `master.m3u8`, `seg_00000.m4s` and `seg_00001.m4s`.
- The master playlist has `#EXT-X-START:TIME-OFFSET=0` and `CODECS="avc1.64001f,mp4a.40.2",RESOLUTION=1280x720,FRAME-RATE=30.000,VIDEO-RANGE=SDR`.
- `lsof` shows one `LISTEN` on the Mac's LAN address (the one `ipconfig getifaddr en0` prints) with a random port.
- `curl` prints `404`: no token, no file.

Now quit while ffmpeg is still converting:

```bash
LONG="${TMPDIR%/}/paperplane-long.mkv"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=1920x1080:rate=30:duration=600" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=600" -c:v mpeg2video -q:v 8 -c:a mp2 "$LONG"
open -a "$APP" "$LONG"
sleep 6
pgrep -fl "Helpers/ffmpeg"
osascript -e 'tell application id "dev.paperplane.app" to quit'
sleep 3
pgrep -fl "Helpers/ffmpeg" || echo "no ffmpeg left"
ls ~/Library/Caches/Paper\ Plane/sessions/
rm -f "$LONG"
```

Expected:
- The first `pgrep` shows ffmpeg running. The MPEG-2 file needs re-encoding, which takes a while.
- After quitting: `no ffmpeg left`, and the `sessions` folder is empty.

- [ ] **Step 9: Check Release and a missing ffmpeg**

```bash
xcodebuild -project app/PaperPlane.xcodeproj -scheme PaperPlane -configuration Release -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E '\*\* BUILD'
mv vendor/ffmpeg vendor/ffmpeg.off
xcodebuild -project app/PaperPlane.xcodeproj -scheme PaperPlane -configuration Debug -derivedDataPath build/DerivedData build 2>&1 | grep -E 'vendor/ffmpeg|\*\* BUILD' | sort -u
xcodebuild -project app/PaperPlane.xcodeproj -scheme PaperPlane -configuration Release -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E 'vendor/ffmpeg|\*\* BUILD' | sort -u
mv vendor/ffmpeg.off vendor/ffmpeg
```

Expected:
- The first Release build succeeds.
- Without `vendor/ffmpeg`, Debug succeeds with `warning: vendor/ffmpeg/bin is missing, so this build uses Homebrew's ffmpeg…`.
- Without it, Release fails with `error: vendor/ffmpeg/bin is missing. Run scripts/build-ffmpeg.sh first.`

- [ ] **Step 10: Update the docs**

In `README.md`, replace the `## Development` section with:

````markdown
## Development

You need macOS 14 or later on Apple Silicon, Xcode 26 or later, and Homebrew.

```bash
brew install ffmpeg            # development and tests only
scripts/make-test-media.sh     # generates test clips into testdata/media/
scripts/test-core.sh           # runs the PaperPlaneCore tests

brew install meson ninja autoconf automake libtool pkgconf
scripts/build-ffmpeg.sh        # builds the ffmpeg the app ships into vendor/ffmpeg/ (a few minutes)
scripts/check-ffmpeg.sh        # checks that build

open app/PaperPlane.xcodeproj  # the app; run the PaperPlane scheme
```

Debug builds made before `scripts/build-ffmpeg.sh` use Homebrew's ffmpeg. Release builds need the bundled one.
````

In the spec's §9, replace the **App** bullet with:

```markdown
- **App:** Swift 6, SwiftUI, AVFoundation/AVKit, Network.framework, MediaPlayer. Built with Xcode 26 or later (`app/PaperPlane.xcodeproj`, which uses synchronized folders). Milestone 0 built with `swiftc` from the Command Line Tools.
```

- [ ] **Step 11: Commit**

```bash
git add scripts/embed-ffmpeg.sh app README.md docs/superpowers/specs/2026-10-15-paper-plane-design.md
git commit -m "feat(app): menu bar app with a remote window that plays a dropped file over AirPlay" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: First playback on the Sony (owner at the TV)

Milestone 1 is done when dropping a copy-mode MKV plays on the Sony (spec §8). This is the first time the TV fetches Paper Plane's own server and playlists, so it also checks the paused-until-TV flow on real AirPlay.

**Files:**
- Modify: `docs/sony-test-results.md` (new section)

**Interfaces:**
- Consumes: the app from Task 10; the test clips.
- Produces: the recorded result that closes Milestone 1.

- [ ] **Step 1: Make a five-minute copy-mode MKV**

H.264 video, which is copied, with AC3 5.1 audio, which becomes stereo AAC under the default profile. The owner can use a real MKV of their own instead.

```bash
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=1920x1080:rate=24:duration=300" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=300" \
  -c:v libx264 -preset veryfast -pix_fmt yuv420p -g 48 -c:a ac3 -b:a 448k -ac 6 \
  "${TMPDIR%/}/paperplane-five-minutes.mkv"
open -R "${TMPDIR%/}/paperplane-five-minutes.mkv"
```

- [ ] **Step 2: Add the results sheet**

Append to `docs/sony-test-results.md`:

```markdown
## Plan 2: first playback through Paper Plane

Build and run the app (Xcode, PaperPlane scheme). To watch what it does: `log stream --info --predicate 'subsystem == "dev.paperplane.app"'`.

| # | Check | Expected | Result |
|---|---|---|---|
| P1 | Launch | Paper plane icon in the menu bar; the remote window opens with "Drop a video here…". Note any Local Network prompt (answer Allow) | |
| P2 | Drop the five-minute MKV on the remote | "Getting the video ready…", then "Choose your TV with the AirPlay button" with the button highlighted. Nothing plays on the Mac | |
| P3 | Pick the Sony with the remote's AirPlay button | Plays on the TV within a few seconds, from the start (the test picture's counter starts at 0). The remote says "Playing on the TV" and its clock counts up to 5:00 | |
| P4 | Pause and Play on the remote; then pause with the TV's remote | The TV follows. The remote's button follows the TV | |
| P5 | Stop | The TV leaves the video. The remote says "Drop a video here…" | |
| P6 | Drop `testdata/media/hevc_hdr10_aac.mkv`, pick the Sony | Plays (10 s). Note whether the HDR indicator shows | |
| P7 | Drop `testdata/media/vp9_opus.webm`, pick the Sony | Plays (re-encoded with VideoToolbox) | |
| P8 | In Finder, Open With → Paper Plane on the five-minute MKV | The remote comes forward; then as P2 and P3 | |
| P9 | During playback, turn the TV off, or end AirPlay from Control Center | The remote asks for the TV again. The Mac stays silent | |
| P10 | Quit from the menu during playback | `pgrep -fl ffmpeg` prints nothing; `ls ~/Library/Caches/Paper\ Plane/sessions/` is empty | |
```

- [ ] **Step 3: Run it with the owner**

Ask the owner to work through P1–P10 and tell you what happened. Fill in the Result column in their words.

If P3 fails because the remote stays on "Choose your TV" after the Sony is picked, use superpowers:systematic-debugging. The `External playback active:` log lines show whether `isExternalPlaybackActive` changed while the item was paused. Fix it in `PlaybackController`, add a note under the table saying what the TV needed, and repeat P2–P3.

- [ ] **Step 4: Commit**

```bash
git add docs/sony-test-results.md app
git commit -m "docs: first playback through Paper Plane on the Sony" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: CI on GitHub Actions and the owner's GitHub repo

One job on GitHub's Apple Silicon runner (`macos-26`):
- Builds the bundled ffmpeg, cached by the build script's hash, and checks it.
- Makes the test media with Homebrew's ffmpeg.
- Runs the core tests twice: with Homebrew's ffmpeg, and with the bundled build.
- Builds the app in Release.

No TV is needed (spec §7).

**Files:**
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `scripts/build-ffmpeg.sh`, `scripts/check-ffmpeg.sh` (Task 3); `scripts/make-test-media.sh`, `scripts/check-test-media.py`, `scripts/test-core.sh` (Plan 1); the `PaperPlane` scheme (Task 10).
- Produces: a green CI run on the owner's personal GitHub repository.

- [ ] **Step 1: Write the workflow**

`.github/workflows/ci.yml`:

```yaml
# Unit and integration tests, the bundled ffmpeg and the app build, on GitHub's Apple Silicon
# runners (spec §7). No TV needed.
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  test-and-build:
    runs-on: macos-26
    timeout-minutes: 60
    steps:
      - uses: actions/checkout@v7

      - name: Show the toolchain
        run: xcodebuild -version && swift --version

      - name: Restore the bundled ffmpeg
        id: ffmpeg-cache
        uses: actions/cache@v6
        with:
          path: vendor/ffmpeg
          key: ffmpeg-${{ runner.os }}-${{ runner.arch }}-${{ hashFiles('scripts/build-ffmpeg.sh') }}

      - name: Build the bundled ffmpeg
        if: steps.ffmpeg-cache.outputs.cache-hit != 'true'
        run: |
          brew install meson ninja autoconf automake libtool pkgconf
          scripts/build-ffmpeg.sh

      - name: Check the bundled ffmpeg
        run: scripts/check-ffmpeg.sh

      - name: Make test media (with Homebrew's ffmpeg, which has the encoders it needs)
        run: |
          brew install ffmpeg
          scripts/make-test-media.sh
          python3 -I scripts/check-test-media.py

      - name: Core tests with Homebrew's ffmpeg
        run: scripts/test-core.sh

      - name: Core tests with the bundled ffmpeg
        run: |
          export PAPERPLANE_FFMPEG="$PWD/vendor/ffmpeg/bin/ffmpeg"
          export PAPERPLANE_FFPROBE="$PWD/vendor/ffmpeg/bin/ffprobe"
          scripts/test-core.sh

      - name: Build the app
        run: >
          xcodebuild -project app/PaperPlane.xcodeproj -scheme PaperPlane -configuration Release
          -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

- [ ] **Step 2: Lint it**

```bash
brew install actionlint
actionlint .github/workflows/ci.yml && echo "actionlint ok"
```

Expected: `actionlint ok`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: test the core with both ffmpegs and build the app on macos-26" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 4: Check that nothing personal or work-related would be published**

```bash
git log --all --format='%an <%ae>%n%cn <%ce>' | sort -u
WORK_DOMAIN="$(git config --global user.email | cut -d@ -f2)"
git grep -n -i -e "$WORK_DOMAIN" -e "${WORK_DOMAIN%%.*}" $(git rev-list --all) -- . | head
git log --all -i --grep="${WORK_DOMAIN%%.*}" --oneline | head
```

Expected:
- The first command lists only the owner's personal identity and nothing else.
- The other two print nothing. They search every commit for the global (work) address's domain without the repo ever naming it.

If anything shows up, stop and show the owner.

- [ ] **Step 5: The owner creates the repository**

Ask the owner to create an empty repository on their **personal** GitHub account: no README, license or .gitignore, since the repo has them. They choose the name (suggested: `paper-plane`) and whether it is public yet. Then ask which remote URL to use.

`gh auth status` may be logged in to a different account. Don't create the repository with `gh` unless the owner confirms it shows their personal account and asks you to.

- [ ] **Step 6: Push, with the owner's explicit go-ahead**

Pushing publishes the code, so ask first. With a yes:

```bash
git remote add origin <URL the owner gave>
git push -u origin main
git push -u origin plan-2-local-playback
```

Then open a pull request from `plan-2-local-playback` into `main`, on GitHub or with `gh pr create --base main` from the personal account. The workflow runs on pull requests and on pushes to `main`.

- [ ] **Step 7: Watch the first run**

Expected: green.
- The first run builds ffmpeg (10–15 minutes on the runner) and installs Homebrew's ffmpeg, so allow about 30 minutes.
- Later runs restore ffmpeg from the cache.

If it fails:
- First check the "Show the toolchain" step. CI's default Xcode is 26.6 (Swift 6.2), older than the owner's 27.1.
- Fix the code so it builds with both. Don't pin CI to a newer Xcode.
- Commit each fix and push again with the owner's OK.

---

## Done when

- `scripts/test-core.sh` passes, with only `toneMapsHDRForAnSDRTV()` skipped under Homebrew's ffmpeg. With `PAPERPLANE_FFMPEG`/`PAPERPLANE_FFPROBE` pointing at `vendor/ffmpeg/bin`, it passes with nothing skipped.
- `scripts/check-ffmpeg.sh` prints `All checks passed`.
- The app builds in Debug and Release with no warnings, and Task 10's smoke test passes.
- `docs/sony-test-results.md` has the re-test (or "not run") and rows P1–P10 filled in. P2 and P3 pass: a dropped copy-mode MKV plays on the Sony.
- CI is green on the owner's personal GitHub repository.
