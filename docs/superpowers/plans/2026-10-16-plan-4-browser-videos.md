# Plan 4: Videos from Chrome and Brave (Milestone 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Click the paper plane in Chrome or Brave and the video playing in that tab plays on the TV through Paper Plane, from where the browser was, live streams included; the browser's video pauses once Paper Plane has it.

**Architecture:** A Manifest V3 extension ranks each tab's streams (pure TypeScript, tested with Vitest) and sends the chosen one, with the site's cookies, as the spec's v1 message to a native messaging helper, `paperplane-host`. The helper relays it over a Unix-domain socket (0600) to the app. The app checks it, plays it through the existing pipeline with the headers, and answers once the video is ready for the TV. The bridge, the relay and the manifest installer live in `PaperPlaneCore`; the helper is a thin command-line target in the app bundle.

**Tech Stack:** Swift 6 (strict concurrency), Swift Testing, Network.framework (the socket), POSIX sockets (the helper), AVFoundation; TypeScript 6, esbuild 0.28, Vitest 5, Chrome's MV3 APIs (webRequest, nativeMessaging, storage.session, scripting, tabs, action).

**Spec:** `docs/superpowers/specs/2026-10-15-paper-plane-design.md` (§5, §5.1–5.4, §6, Milestone 3), with the decisions in `docs/superpowers/specs/2026-10-16-milestone-3-decisions.md` (Task 1).

## Global Constraints

- macOS 14+, Apple Silicon only; Swift 6 language mode; no new Swift package dependencies.
- Native messaging host name `dev.paperplane.host`. The manifest goes in Chrome's and Brave's `NativeMessagingHosts` folders and allows only `chrome-extension://napcmmglefncoieikecpjmdopmagllcg/` (spec §5.2).
- Socket `~/Library/Application Support/Paper Plane/bridge.sock`, mode 0600, in a 0700 folder (spec §5.2).
- Message v1: `{"type":"play","v":1,"source":{"kind":"stream","url","format":"hls|dash|progressive","headers"}|{"kind":"page","url"},"pageUrl","title","startAt"}`. Reply `{"ok":true}` or `{"ok":false,"error":"…"}` (spec §5.2).
- Headers passed on: `Cookie`, `Referer`, `Origin`, `User-Agent` only. Cookies live in memory for one playback and never in logs (spec §5.4).
- The helper starts the app if it isn't running and retries for up to 10 s, then says "Couldn't start Paper Plane." (spec §6).
- HTTP 401/403/410 or an expired link: "The site stopped the stream — click Paper Plane in your browser again" (spec §6).
- Live streams: no seek bar, a "Live" label (spec §5.3).
- Extension dev tools pinned to releases at least two weeks old, installed with `npm ci --ignore-scripts`.
- Every commit uses the repo-local identity and ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Nothing is pushed.
- Test commands: `scripts/test-core.sh` (Swift); `cd extension && npm test && npm run typecheck` (TypeScript).

## Review Focus

These are the inputs the spec implies that no task's happy path covers and that a person would hit first. Each is pinned by the tests named.

1. **A request the app shouldn't act on.** This covers a `file:` URL, an unknown version, a huge length, a connection that says nothing, and a `-1` start. Each is refused without asking the player:
   - `PlayRequestTests.refusesWhatItCantSafelyPlay` (Task 2);
   - `BridgeServerTests.refusesWhatItCantReadWithoutAskingThePlayer`, `refusesOversizedRequests`, `dropsASilentConnection` (Task 3).
2. **The app not running, or not answering.** The helper starts it, or gives up with a message:
   - `HostRelayTests.startsTheAppWhenNothingListens`, `givesUpWhenTheAppDoesntStart`, `givesUpWhenTheAppDoesntAnswer` (Task 3);
   - `scripts/check-bridge.sh` (Task 8).
3. **A site that refuses the stream** (an expired link, a missing cookie). The message names the site:
   - `WebInputTests.recognisesASiteRefusingTheStream` (Task 5);
   - `BrowserPlaybackTests.aSiteThatRefusesTheStreamIsNamed` (Task 7).
4. **Most sites' HLS**, MPEG-TS segments with ADTS AAC, and a site's playlist naming local files:
   - `WebInputTests.convertsAnHLSStreamOfMPEGTSSegments`, `aWebPlaylistCantReadLocalFiles`;
   - `FFmpegArgumentsTests.copiedAACIsMadeFitForMP4`, `ResolvedInputTests.webInputsReachOnlyTheWeb` (Task 5).
5. **Live streams.** No duration, nothing to seek, ffmpeg never rested:
   - `WebInputTests.aLivePlaylistHasNoDuration` (Task 5), `SegmentWindowTests.aWindowThatDoesntPauseStillDeletesWhatIsBehind` (Task 6);
   - `BrowserPlaybackTests.aLiveStreamPlaysLive` (Task 7).
6. **Pages with more than one video** (an ad, a background loop, two players, master and variants). The right one is sent, or the user is asked:
   - `detector.test.ts` against the fixtures in `fixtures.ts` (Task 9).
7. **Clicking again, or in another tab, while one request is under way, and YouTube before Plan 5.** The newer one wins and the older is told why; a page leaves what's playing alone:
   - `BrowserPlaybackTests.aNewerVideoTakesOverAnUnansweredRequest`, `aPageLeavesWhatIsPlayingAlone` (Task 7).

---

### Task 1: Record the Milestone 3 decisions

**Files:**
- Create: `docs/superpowers/specs/2026-10-16-milestone-3-decisions.md`

**Interfaces:**
- Produces: the decisions every later task follows (socket and framing, validation, the helper, manifests, detection and ranking, live and web-stream rules).

- [ ] **Step 1: Write the addendum**

```markdown
# Paper Plane — Milestone 3 decisions (addendum to the design spec)

**Date:** 2026-10-16 (overnight run; the owner pre-approved Plans 3–5 and is asleep)
**Status:** Decisions taken without the owner, inside the approved spec (§5, §5.1–5.4, §6). Each says what it costs if wrong. Decisions 18–32 were taken while building Plan 4.

Milestone 3 is "Extension (detection, ranking, popup, pause), `paperplane-host`, manifest installation for Chrome and Brave, `BrowserBridge`. A browser HLS site and an MP4 site play on the Sony". YouTube and Paste a link are Milestone 4 (Plan 5).

## The bridge

1. **One Unix-domain socket** at `~/Library/Application Support/Paper Plane/bridge.sock`, served by Network.framework (tried in scratch). The folder is created 0700 and the socket chmodded to 0600 once bound, so only the same user can connect (spec §5.2). A stale socket file from a crash is removed before binding. Paths too long for a socket address (104 bytes) are refused rather than cut short.
2. **Messages** are the spec's v1 JSON (§5.2): `{"type":"play","v":1,"source":{…},"pageUrl","title","startAt"}`, a reply `{"ok":true}` or `{"ok":false,"error":"…"}`. Over the socket each message is length-prefixed exactly like native messaging (4-byte little-endian length, then UTF-8 JSON), so the helper only relays bytes. Messages of 1 MB or more are refused before being read (Chrome's limit to the host is 4 GB, but nothing legitimate here is more than a few KB). A connection that sends nothing within 10 s is closed.
3. **Validation in the app:**
   - `url` and `pageUrl` must be `http` or `https`.
   - Headers keep only `Cookie`, `Referer`, `Origin` and `User-Agent`, with line breaks stripped (Plan 1's `ResolvedInput` already does).
   - `startAt` must be finite and ≥ 0.
   - An unknown `type`, `v`, `kind` or `format` gets `{"ok":false}`, with a short reason that says nothing secret.

   *Cost if wrong:* a site with an unusual required header won't play.
4. **`kind: "page"`** (YouTube) is accepted by the format but answered "YouTube comes in a later version of Paper Plane." until Plan 5 adds yt-dlp. It leaves whatever is playing alone.

## The helper

5. **`paperplane-host`** is a small Swift command-line tool in the app bundle (`Contents/Helpers/paperplane-host`), built by an Xcode target of its own.
   - It reads one message from stdin, connects to the socket, relays the message and the reply, and exits.
   - If nothing is listening, it opens the app it lives in, in the background (`open -g`), and retries for up to 10 s, then replies "Couldn't start Paper Plane." (spec §5.2, §6). It waits up to 2 minutes for the reply, then says "Paper Plane didn't answer."
   - The relay and framing are in `PaperPlaneCore` and tested; the tool is a thin `main`. It uses blocking POSIX sockets, which suit a tool that does nothing else.
   - *Ruling:* it opens the enclosing app by path rather than by bundle ID, so a development build's helper starts that build. Cost if wrong: none.
6. **Manifest installation** (spec §5.2): on every launch the app writes `dev.paperplane.host.json` into Chrome's and Brave's `NativeMessagingHosts` folders.
   - It writes only when that browser's support folder exists, points at the bundled helper, and allows only the Paper Plane extension's ID.
   - It rewrites the file only if it differs.
   - A launch argument `-PaperPlaneInstallsBrowserHosts NO` skips it, for automated checks that shouldn't touch real browser profiles; every check script passes it.

   *Cost if wrong:* none, since the file is inert without the extension.
7. **The extension's ID is pinned** by a public `key` in `manifest.json` (spec §5.2). The key pair was generated once with OpenSSL. Only the public key is committed, and the private key was discarded: it's only needed to publish, which goes through the Chrome Web Store's own key. A test derives the ID from the committed key and checks it against the ID the app allows.

## The extension

8. **Layout:** `extension/`, with TypeScript, esbuild and Vitest (spec §9).
   - Dev tools are pinned to releases at least two weeks old and installed with `--ignore-scripts`.
   - The pure logic lives in plain modules tested by Vitest: request classification, ranking (`StreamDetector`), tab state, message building, the button and popup view, and checking content-script reports.
   - The service worker, content script and popup are thin wiring around them.
9. **Detection** follows §5.1.
   - `webRequest.onSendHeaders` with `extraHeaders` captures each request's `Cookie`, `Referer`, `Origin` and `User-Agent`. They are held in memory by request ID only until the response arrives, and kept only for a stream.
   - `onHeadersReceived` classifies HLS, DASH and video files by content type and extension.
   - Segments count as activity for the stream whose playlist's folder holds them.
   - Candidates are kept per tab in `chrome.storage.session`, at most 20 per tab, and cleared when the tab loads a new page.
10. **DASH** streams are detected and ranked but sent as `format: "dash"`; ffmpeg reads DASH manifests directly. *Cost if wrong:* some DASH sites need per-segment headers ffmpeg doesn't repeat.
11. **Button states** (§5.1):
    - Grey with no candidates, and its popup explains what to do.
    - Coloured with one confident candidate: a click sends it.
    - A count badge and a popup chooser when the choice is ambiguous.
    - "…" while sending, and "!" with the reason in the popup after a failure.

    "Confident" means the top score beats the next by at least one criterion. The weights (16, 8, 4, 2, 1) make each criterion outweigh all those after it together.
12. **The browser's video pauses once the app replies ok** (§5.1); every frame's videos pause.
13. **Icons** are drawn by `scripts/make-icon.swift --extension`, from the same drawing as the app icon: full-bleed for the toolbar, colour, and grey for "nothing found". *Ruling:* not `sips` from the app icon, whose margin would leave a tiny glyph at 16 px.

## The app

14. **Web playback** goes through the same pipeline with `ResolvedInput` carrying the headers (§5.3). Subtitles from web streams aren't converted (Plan 3 rule: local files only). The remote shows the page's title. Web streams get no thumbnail, so nothing more is fetched from the site than playing needs.
15. **Live streams** (§5.3): a web stream with no duration from ffprobe (an HLS playlist without `#EXT-X-ENDLIST`) is live.
    - A "Live" label with a red dot replaces the scrubber, and the skips are off.
    - Now Playing marks it live.
    - It starts at the live edge, ignoring `startAt`.
16. **The window for web streams:** ffmpeg is not paused (`SIGSTOP`) for web inputs, because the site may drop the idle connection (spec §4.2 says stop instead). v1 lets it run and still deletes what's behind; restarting a stopped web session from the converted edge comes later.
    - When disk space is low, the notice says "a long video may stop part-way through", since the window can't keep less ahead.
    - *Cost if wrong:* disk use grows with what's downloaded ahead, bounded by deletion behind.
17. **Errors** (§6): ffmpeg or ffprobe reporting HTTP 401, 403, 404 or another 4xx (410 Gone among them) becomes "The site stopped the stream — click Paper Plane in your browser again". This applies at the start or part-way through. Logs redact cookies, authorization and query strings (Plan 1's `Redaction`).

## Taken while building

18. **The reply waits until the video is ready for the TV:** probed, and its first segments served. The browser pauses only when Paper Plane really has the video, and a failure is the remote's own message. A start that Stop or a newer video replaces answers "Stopped in Paper Plane." or "Another video took its place." *Cost if wrong:* a slow site keeps the button on "…" for a few seconds.
19. **Copied AAC goes through `aac_adtstoasc`.** The live-stream test found that ffmpeg refuses to copy AAC from MPEG-TS (ADTS headers) into fMP4, which most sites' HLS and any local `.ts` file would hit. `AudioAction.copy` now names its codec, like `VideoAction.copy`, so the filter is added only for AAC (it passes AAC from MP4 through unchanged).
20. **Web inputs are limited to web protocols** (`-protocol_whitelist https,http,tls,tcp,crypto,data`).
    - ffmpeg already refuses `file:` under a web playlist (checked); the list also shuts out `udp:` and `rtp:`.
    - A test pins that a web playlist naming local files can't be read.
21. **A video file is a candidate only when a `<video>` element fetches it** (request type `media`). A player's own fetches of `.mp4` pieces are segments of a stream (fMP4 HLS and DASH).
22. **Variant playlists** are HLS playlists fetched within 10 s of a master, from its frame and host. They're credited to the master and not offered separately. *Cost if wrong:* two different videos started within 10 s on one host show as one.
23. **Only a real page load clears a tab.** A single-page site changing its address keeps its candidates, and ranking prefers whichever is active.
24. **A worker's requests** (no frame) count towards whichever frame has a playing video.
25. **A YouTube page's cookie and user agent** come from its page load and are kept only for YouTube video pages, ready for Plan 5.
26. **The remote comes forward for a stream** sent from the browser, to choose the TV, and not for a page it can't play yet.
27. **Ranking fixtures are synthetic.** They are shaped like real sites: an ad before a story, a background loop beside a film, master and variants, DASH, two players. Recording real sites' requests needs the owner's browser session (Sony checklist B4, B5).
28. **End-to-end checks without a TV:**
    - `scripts/check-bridge.sh`: the helper and the app.
    - `scripts/check-extension.sh`: a headless Chrome with a throwaway profile, loading the extension through DevTools, since branded Chrome no longer takes `--load-extension`, then the helper and the app.
    - Neither touches the owner's browser profile.
29. **The popup is plain HTML and CSS**, in the system font with light and dark colours. Everything it shows is inserted as text, never HTML.
30. **Messages are checked on arrival:**
    - Content scripts' video reports are checked for shape and capped at 20 videos and 2,048 characters per source.
    - The popup is recognised by its address, and content scripts take orders only from the extension.
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-10-16-milestone-3-decisions.md
git commit -m "docs: Milestone 3 decisions (addendum to the spec)"
```

### Task 2: Native messaging framing and the play request

**Files:**
- Create: `core/Sources/PaperPlaneCore/Bridge/BridgeMessages.swift`
- Test: `core/Tests/PaperPlaneCoreTests/BridgeMessageTests.swift`

**Interfaces:**
- Consumes: `ResolvedInput`, `ResolvedInput.Input(url:headers:)` (Plan 1).
- Produces:
  - Framing: `NativeMessaging.frame(_:) -> Data`, `take(from: inout Data) throws -> Data?`, `announcedLength(in:) -> Int?`, `maximumLength`, `Error.tooLarge`.
  - Requests: `PlayRequest.decode(_:) throws -> PlayRequest` (`source`, `pageURL`, `title`, `startAt`, `input: ResolvedInput?`). Sources are `.stream(URL, Format, headers:)` and `.page(URL, headers:)`. `PlayRequest.Invalid(reason:)`.
  - Replies: `PlayReply.ok / .failed(String)` with `encoded() -> Data` and `decode(_:) -> PlayReply?`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import PaperPlaneCore

struct NativeMessagingTests {
    @Test func framesWithALittleEndianLength() {
        #expect(NativeMessaging.frame(Data("{}".utf8)) == Data([2, 0, 0, 0]) + Data("{}".utf8))
    }

    @Test func takesWholeMessagesFromABuffer() throws {
        var buffer = NativeMessaging.frame(Data("one".utf8)) + NativeMessaging.frame(Data("two".utf8)).prefix(5)
        #expect(try NativeMessaging.take(from: &buffer) == Data("one".utf8))
        #expect(try NativeMessaging.take(from: &buffer) == nil) // the second isn't all here yet
        buffer += NativeMessaging.frame(Data("two".utf8)).dropFirst(5)
        #expect(try NativeMessaging.take(from: &buffer) == Data("two".utf8))
        #expect(buffer.isEmpty)
    }

    @Test func refusesOversizedMessages() {
        var buffer = Data([0, 0, 0x10, 0]) // 1 MB
        #expect(throws: NativeMessaging.Error.tooLarge) { try NativeMessaging.take(from: &buffer) }
    }
}

struct PlayRequestTests {
    static func json(_ text: String) -> Data { Data(text.utf8) }

    @Test func decodesAStreamRequest() throws {
        let request = try PlayRequest.decode(Self.json("""
            {"type":"play","v":1,"source":{"kind":"stream","url":"https://cdn.example/v/master.m3u8?token=abc",
             "format":"hls","headers":{"Cookie":"session=1","Referer":"https://site.example/watch",
             "User-Agent":"Mozilla/5.0","Origin":"https://site.example","X-Other":"dropped"}},
             "pageUrl":"https://site.example/watch","title":"A film","startAt":12.5}
            """))
        #expect(request.title == "A film")
        #expect(request.startAt == 12.5)
        guard case .stream(let url, let format, let headers) = request.source else {
            Issue.record("not a stream")
            return
        }
        #expect(url.absoluteString == "https://cdn.example/v/master.m3u8?token=abc")
        #expect(format == .hls)
        #expect(headers == ["Cookie": "session=1", "Referer": "https://site.example/watch",
                            "User-Agent": "Mozilla/5.0", "Origin": "https://site.example"])
        #expect(request.input?.inputs.first?.headers.count == 4)
        #expect(request.input?.title == "A film")
    }

    /// YouTube (spec §5.1): the page, with the site's cookies for yt-dlp in a later version.
    @Test func decodesAPageRequest() throws {
        let request = try PlayRequest.decode(Self.json("""
            {"type":"play","v":1,"source":{"kind":"page","url":"https://www.youtube.com/watch?v=x",
             "headers":{"Cookie":"SID=1","Authorization":"dropped"}},"title":"Clip"}
            """))
        #expect(request.source == .page(URL(string: "https://www.youtube.com/watch?v=x")!, headers: ["Cookie": "SID=1"]))
        #expect(request.startAt == 0)
        #expect(request.input == nil) // pages need yt-dlp
    }

    @Test(arguments: [
        #"{"type":"pause","v":1,"source":{"kind":"stream","url":"https://a.example/v.mp4","format":"progressive"}}"#,
        #"{"type":"play","v":2,"source":{"kind":"stream","url":"https://a.example/v.mp4","format":"progressive"}}"#,
        #"{"type":"play","v":1,"source":{"kind":"stream","url":"file:///etc/passwd","format":"progressive"}}"#,
        #"{"type":"play","v":1,"source":{"kind":"stream","url":"ftp://a.example/v.mp4","format":"progressive"}}"#,
        #"{"type":"play","v":1,"source":{"kind":"stream","url":"https://a.example/v.mp4","format":"rtmp"}}"#,
        #"{"type":"play","v":1,"source":{"kind":"stream","url":"https://a.example/v.mp4","format":"hls"},"startAt":-1}"#,
        #"{"type":"play","v":1,"source":{"kind":"stream","url":"https://a.example/v.mp4","format":"hls"},"startAt":1e400}"#,
        #"{"type":"play","v":1,"source":{"kind":"magic","url":"https://a.example/"}}"#,
        #"{"type":"play","v":1}"#,
        #"not json"#,
    ])
    func refusesWhatItCantSafelyPlay(_ text: String) {
        #expect(throws: PlayRequest.Invalid.self) { try PlayRequest.decode(Self.json(text)) }
    }

    @Test func titlesAreTidied() throws {
        let request = try PlayRequest.decode(Self.json("""
            {"type":"play","v":1,"source":{"kind":"stream","url":"https://a.example/v.mp4","format":"progressive"},
             "title":"  Line one\\nline two  "}
            """))
        #expect(request.title == "Line one line two")
        let untitled = try PlayRequest.decode(Self.json("""
            {"type":"play","v":1,"source":{"kind":"stream","url":"https://a.example/videos/clip.mp4","format":"progressive"}}
            """))
        #expect(untitled.title == "clip")
    }

    @Test func repliesInTheSpecsShape() throws {
        #expect(String(decoding: PlayReply.ok.encoded(), as: UTF8.self) == #"{"ok":true}"#)
        #expect(String(decoding: PlayReply.failed("No TV").encoded(), as: UTF8.self) == #"{"error":"No TV","ok":false}"#)
    }
}
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `scripts/test-core.sh --filter "NativeMessagingTests|PlayRequestTests"`
Expected: FAIL — `cannot find 'NativeMessaging' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Chrome's native messaging framing (spec §5.2): a 4-byte length in native byte order
/// (little-endian on Apple Silicon), then that many bytes of UTF-8 JSON. The bridge socket
/// uses the same framing, so the helper only relays bytes.
public enum NativeMessaging {
    /// Nothing legitimate is more than a few KB; this keeps a broken or hostile sender from
    /// making the app allocate gigabytes.
    public static let maximumLength = 1 << 20

    public enum Error: Swift.Error, Equatable {
        case tooLarge
    }

    public static func frame(_ message: Data) -> Data {
        var length = UInt32(message.count).littleEndian
        return Data(bytes: &length, count: 4) + message
    }

    /// The length a frame's first 4 bytes announce, or nil if they haven't all arrived.
    static func announcedLength(in buffer: Data) -> Int? {
        guard buffer.count >= 4 else { return nil }
        let bytes = [UInt8](buffer.prefix(4))
        return Int(UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24)
    }

    /// Removes and returns the first whole message in `buffer`, or nil if it hasn't all
    /// arrived. Throws for a length of `maximumLength` or more, before reading that much.
    public static func take(from buffer: inout Data) throws -> Data? {
        guard let length = announcedLength(in: buffer) else { return nil }
        guard length < maximumLength else { throw Error.tooLarge }
        guard buffer.count >= 4 + length else { return nil }
        let start = buffer.startIndex + 4
        let message = Data(buffer[start..<(start + length)])
        buffer = Data(buffer[(start + length)...])
        return message
    }
}

/// A request from the extension to play something (spec §5.2, message v1), checked before
/// anything is done with it.
public struct PlayRequest: Equatable, Sendable {
    public enum Format: String, Sendable {
        case hls, dash, progressive
    }

    public enum Source: Equatable, Sendable {
        /// A stream the extension found, with the headers the site expects.
        case stream(URL, Format, headers: [String: String])
        /// A page for yt-dlp to resolve (YouTube), with the site's cookies.
        case page(URL, headers: [String: String])
    }

    /// The request can't be played safely. `reason` is short and says nothing secret.
    public struct Invalid: Error, Equatable {
        public var reason: String
    }

    public var source: Source
    public var pageURL: URL?
    public var title: String
    /// Where the browser's video was, in seconds.
    public var startAt: Double

    /// The only headers passed on: what sites need to hand over the video, nothing else.
    static let allowedHeaders = ["Cookie", "Referer", "Origin", "User-Agent"]

    public static func decode(_ data: Data) throws -> PlayRequest {
        guard let message = try? JSONDecoder().decode(Message.self, from: data) else {
            throw Invalid(reason: "unreadable request")
        }
        guard message.type == "play", message.v == 1 else { throw Invalid(reason: "unknown request") }
        guard let source = message.source else { throw Invalid(reason: "nothing to play") }
        let url = try webURL(source.url)
        let startAt = message.startAt ?? 0
        guard startAt.isFinite, startAt >= 0 else { throw Invalid(reason: "bad start time") }
        let headers = allowed(source.headers ?? [:])
        let decodedSource: Source
        switch source.kind {
        case "stream":
            guard let format = source.format.flatMap(Format.init(rawValue:)) else {
                throw Invalid(reason: "unknown format")
            }
            decodedSource = .stream(url, format, headers: headers)
        case "page":
            decodedSource = .page(url, headers: headers)
        default:
            throw Invalid(reason: "unknown source")
        }
        let given = (message.title ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return PlayRequest(source: decodedSource, pageURL: message.pageUrl.flatMap { try? webURL($0) },
                           title: given.isEmpty ? fallbackTitle(for: url) : given, startAt: startAt)
    }

    /// What ffmpeg reads, for a stream. nil for a page, which needs yt-dlp first.
    public var input: ResolvedInput? {
        guard case .stream(let url, _, let headers) = source else { return nil }
        return ResolvedInput(inputs: [ResolvedInput.Input(url: url, headers: headers)], title: title)
    }

    /// The allowed headers, named the usual way whatever case they came in.
    private static func allowed(_ headers: [String: String]) -> [String: String] {
        var kept: [String: String] = [:]
        for (name, value) in headers {
            if let allowed = allowedHeaders.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                kept[allowed] = value
            }
        }
        return kept
    }

    /// "clip" for …/videos/clip.mp4; "Video" when the path says nothing.
    private static func fallbackTitle(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? ""
        return name.isEmpty || name == "/" ? "Video" : name
    }

    private static func webURL(_ text: String?) throws -> URL {
        guard let text, let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host() != nil
        else { throw Invalid(reason: "not a web address") }
        return url
    }

    private struct Message: Decodable {
        struct Source: Decodable {
            var kind: String
            var url: String?
            var format: String?
            var headers: [String: String]?
        }

        var type: String
        var v: Int
        var source: Source?
        var pageUrl: String?
        var title: String?
        var startAt: Double?
    }
}

/// The app's answer to a request (spec §5.2).
public enum PlayReply: Equatable, Sendable {
    case ok
    case failed(String)

    public func encoded() -> Data {
        let object: [String: Any] = switch self {
        case .ok: ["ok": true]
        case .failed(let message): ["ok": false, "error": message]
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(#"{"ok":false}"#.utf8)
    }

    public static func decode(_ data: Data) -> PlayReply? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = object["ok"] as? Bool
        else { return nil }
        return ok ? .ok : .failed(object["error"] as? String ?? "Something went wrong.")
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test-core.sh --filter "NativeMessagingTests|PlayRequestTests"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add core/Sources/PaperPlaneCore/Bridge/BridgeMessages.swift core/Tests/PaperPlaneCoreTests/BridgeMessageTests.swift
git commit -m "feat(core): native messaging framing and the v1 play request, checked"
```

### Task 3: The app's socket and the helper's relay

**Files:**
- Create: `core/Sources/PaperPlaneCore/Bridge/BridgeServer.swift`, `core/Sources/PaperPlaneCore/Bridge/HostRelay.swift`
- Test: `core/Tests/PaperPlaneCoreTests/BridgeTests.swift`

**Interfaces:**
- Consumes: `NativeMessaging`, `PlayRequest`, `PlayReply` (Task 2).
- Produces:
  - The server: `BridgeServer.start(at: URL, requestLimit: Duration = .seconds(10), handler: @Sendable (PlayRequest) async -> PlayReply) async throws -> BridgeServer`, with `stop()`, `standardSocket` and `Failure.pathTooLong / .cannotListen`.
  - The relay: `HostRelay.readRequest(from: FileHandle) -> Data?` and `relay(_:socket:startApp:startLimit:replyLimit:) -> Data`. Also `app(containing:) -> URL?` and `open(_:)`, plus the internal `connect(to:)`, `write(_:to:)` and `readFrame(from:into:limit:)`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import os
import Testing
@testable import PaperPlaneCore

/// Requests and sockets the bridge tests share.
enum BridgeFixtures {
    /// A socket in a folder of its own under the temporary folder (short enough for sun_path).
    static func socket() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pp-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .appendingPathComponent("bridge.sock")
    }

    static let play = Data(#"""
        {"type":"play","v":1,"source":{"kind":"stream","url":"https://a.example/v.m3u8","format":"hls"},"title":"Film"}
        """#.utf8)

    /// Relays `request` from a background thread, as the helper does, so a blocking socket never
    /// holds up a Swift concurrency thread the server needs.
    static func relay(_ request: Data, socket: URL, startApp: @escaping @Sendable () -> Void = {},
                      startLimit: Double = 0.3, replyLimit: Double = 10) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: HostRelay.relay(request, socket: socket, startApp: startApp,
                                                               startLimit: startLimit, replyLimit: replyLimit))
            }
        }
    }
}

struct BridgeServerTests {
    @Test func answersAPlayRequest() async throws {
        let socket = BridgeFixtures.socket()
        let received = OSAllocatedUnfairLock<PlayRequest?>(initialState: nil)
        let server = try await BridgeServer.start(at: socket) { request in
            received.withLock { $0 = request }
            return .ok
        }
        defer { server.stop() }
        #expect(await BridgeFixtures.relay(BridgeFixtures.play, socket: socket) == PlayReply.ok.encoded())
        #expect(received.withLock { $0 }?.title == "Film")
    }

    /// Spec §5.2: only this user may connect.
    @Test func onlyThisUserCanConnect() async throws {
        let socket = BridgeFixtures.socket()
        let server = try await BridgeServer.start(at: socket) { _ in .ok }
        defer { server.stop() }
        let file = try FileManager.default.attributesOfItem(atPath: socket.path)
        let folder = try FileManager.default.attributesOfItem(atPath: socket.deletingLastPathComponent().path)
        #expect(file[.posixPermissions] as? Int == 0o600)
        #expect(folder[.posixPermissions] as? Int == 0o700)
    }

    /// A crash leaves the socket file behind; the next launch must still listen.
    @Test func replacesALeftoverSocket() async throws {
        let socket = BridgeFixtures.socket()
        try FileManager.default.createDirectory(at: socket.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: socket)
        let server = try await BridgeServer.start(at: socket) { _ in .ok }
        defer { server.stop() }
        #expect(await BridgeFixtures.relay(BridgeFixtures.play, socket: socket) == PlayReply.ok.encoded())
    }

    @Test func refusesWhatItCantReadWithoutAskingThePlayer() async throws {
        let socket = BridgeFixtures.socket()
        let asked = OSAllocatedUnfairLock(initialState: false)
        let server = try await BridgeServer.start(at: socket) { _ in
            asked.withLock { $0 = true }
            return .ok
        }
        defer { server.stop() }
        let reply = await BridgeFixtures.relay(Data(#"{"type":"play","v":1,"source":{"kind":"stream","url":"file:///etc/passwd","format":"hls"}}"#.utf8),
                                               socket: socket)
        #expect(PlayReply.decode(reply) == .failed("Paper Plane can't play this (not a web address)."))
        #expect(!asked.withLock { $0 })
    }

    /// A length over the limit is refused before anything that size is read.
    @Test func refusesOversizedRequests() async throws {
        let socket = BridgeFixtures.socket()
        let server = try await BridgeServer.start(at: socket) { _ in .ok }
        defer { server.stop() }
        let reply = try await Self.exchangeRaw(Data([0, 0, 0x20, 0]), socket: socket) // 2 MB
        #expect(PlayReply.decode(reply) == .failed("Paper Plane can't play this (request too large)."))
    }

    /// Something that connects and says nothing is let go, and the next request still works.
    @Test func dropsASilentConnection() async throws {
        let socket = BridgeFixtures.socket()
        let server = try await BridgeServer.start(at: socket, requestLimit: .milliseconds(200)) { _ in .ok }
        defer { server.stop() }
        let reply = try await Self.exchangeRaw(Data(), socket: socket)
        #expect(reply.isEmpty) // closed without an answer
        #expect(await BridgeFixtures.relay(BridgeFixtures.play, socket: socket) == PlayReply.ok.encoded())
    }

    /// One slow request (a site that takes a while to probe) doesn't hold up the next.
    @Test func answersRequestsAtTheSameTime() async throws {
        let socket = BridgeFixtures.socket()
        let secondAnswered = OSAllocatedUnfairLock(initialState: false)
        let server = try await BridgeServer.start(at: socket) { request in
            if request.title == "First" {
                for _ in 0..<100 where !secondAnswered.withLock({ $0 }) {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                return secondAnswered.withLock { $0 } ? .ok : .failed("waited in line")
            }
            return .ok
        }
        defer { server.stop() }
        let first = Data(String(decoding: BridgeFixtures.play, as: UTF8.self).replacingOccurrences(of: "Film", with: "First").utf8)
        async let firstReply = BridgeFixtures.relay(first, socket: socket)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await BridgeFixtures.relay(BridgeFixtures.play, socket: socket) == PlayReply.ok.encoded())
        secondAnswered.withLock { $0 = true }
        #expect(await firstReply == PlayReply.ok.encoded())
    }

    @Test func stoppingRemovesTheSocket() async throws {
        let socket = BridgeFixtures.socket()
        let server = try await BridgeServer.start(at: socket) { _ in .ok }
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: socket.path))
        let reply = await BridgeFixtures.relay(BridgeFixtures.play, socket: socket, startLimit: 0.2)
        #expect(PlayReply.decode(reply) == .failed("Couldn't start Paper Plane."))
    }

    /// sun_path holds 104 bytes; a longer path would be cut short silently.
    @Test func refusesAPathTooLongForASocket() async {
        let long = URL(fileURLWithPath: "/tmp/" + String(repeating: "x", count: 100) + "/bridge.sock")
        await #expect(throws: BridgeServer.Failure.pathTooLong) {
            try await BridgeServer.start(at: long) { _ in .ok }
        }
    }

    /// Sends raw bytes and reads whatever comes back until the server closes.
    static func exchangeRaw(_ bytes: Data, socket: URL) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    let descriptor = try HostRelay.connect(to: socket)
                    defer { close(descriptor) }
                    try HostRelay.write(bytes, to: descriptor)
                    var buffer = Data()
                    if let message = try? HostRelay.readFrame(from: descriptor, into: &buffer, limit: 5) {
                        continuation.resume(returning: message)
                    } else {
                        continuation.resume(returning: Data())
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

struct HostRelayTests {
    /// Spec §5.2: with nothing listening, the helper starts the app and waits for its socket.
    @Test func startsTheAppWhenNothingListens() async throws {
        let socket = BridgeFixtures.socket()
        let starts = OSAllocatedUnfairLock(initialState: 0)
        let server = OSAllocatedUnfairLock<BridgeServer?>(initialState: nil)
        let reply = await BridgeFixtures.relay(BridgeFixtures.play, socket: socket, startApp: {
            starts.withLock { $0 += 1 }
            Task { // the app takes a moment to launch
                try? await Task.sleep(for: .milliseconds(300))
                let started = try? await BridgeServer.start(at: socket) { _ in .ok }
                server.withLock { $0 = started }
            }
        }, startLimit: 5)
        defer { server.withLock { $0?.stop() } }
        #expect(reply == PlayReply.ok.encoded())
        #expect(starts.withLock { $0 } == 1)
    }

    @Test func givesUpWhenTheAppDoesntStart() async {
        let clock = ContinuousClock()
        let started = clock.now
        let reply = await BridgeFixtures.relay(BridgeFixtures.play, socket: BridgeFixtures.socket(), startLimit: 0.5)
        #expect(PlayReply.decode(reply) == .failed("Couldn't start Paper Plane."))
        #expect(clock.now - started < .seconds(3))
    }

    @Test func givesUpWhenTheAppDoesntAnswer() async throws {
        let socket = BridgeFixtures.socket()
        let server = try await BridgeServer.start(at: socket) { _ in
            try? await Task.sleep(for: .seconds(10))
            return .ok
        }
        defer { server.stop() }
        let reply = await BridgeFixtures.relay(BridgeFixtures.play, socket: socket, replyLimit: 0.3)
        #expect(PlayReply.decode(reply) == .failed("Paper Plane didn't answer."))
    }

    @Test func readsOneFramedMessage() throws {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(NativeMessaging.frame(BridgeFixtures.play))
        try pipe.fileHandleForWriting.close()
        #expect(HostRelay.readRequest(from: pipe.fileHandleForReading) == BridgeFixtures.play)
    }

    @Test(arguments: [Data([5, 0, 0, 0]) + Data("ab".utf8), Data([0, 0, 0x20, 0]), Data([1])])
    func refusesTruncatedOrOversizedInput(_ bytes: Data) throws {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(bytes)
        try pipe.fileHandleForWriting.close()
        #expect(HostRelay.readRequest(from: pipe.fileHandleForReading) == nil)
    }

    @Test func findsTheAppItLivesIn() {
        let helper = URL(fileURLWithPath: "/Applications/Paper Plane.app/Contents/Helpers/paperplane-host")
        #expect(HostRelay.app(containing: helper)?.path == "/Applications/Paper Plane.app")
        #expect(HostRelay.app(containing: URL(fileURLWithPath: "/usr/local/bin/paperplane-host")) == nil)
    }
}
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `scripts/test-core.sh --filter "BridgeServerTests|HostRelayTests"`
Expected: FAIL — `cannot find 'BridgeServer' in scope`, `cannot find 'HostRelay' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation
import Network
import os

/// The app's end of the browser bridge (spec §5.2): a Unix-domain socket only this user can
/// connect to. Each connection carries one framed play request and gets one framed reply.
public final class BridgeServer: Sendable {
    public enum Failure: Error, Equatable {
        /// Longer than a socket address holds (104 bytes, with its terminating zero).
        case pathTooLong
        case cannotListen(String)
    }

    /// Where the app listens: `~/Library/Application Support/Paper Plane/bridge.sock`.
    public static var standardSocket: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Paper Plane/bridge.sock")
    }

    public let socket: URL
    private let listener: NWListener
    private static let log = Logger(subsystem: "dev.paperplane.app", category: "bridge")

    private init(socket: URL, listener: NWListener) {
        self.socket = socket
        self.listener = listener
    }

    /// Listens at `socket`, replacing a socket file a crash left behind, and answers each request
    /// with `handler`. A connection that hasn't sent a whole request within `requestLimit` is
    /// closed.
    public static func start(at socket: URL, requestLimit: Duration = .seconds(10),
                             handler: @escaping @Sendable (PlayRequest) async -> PlayReply) async throws -> BridgeServer {
        guard socket.path.utf8.count < 104 else { throw Failure.pathTooLong }
        let folder = socket.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        unlink(socket.path)

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: socket.path)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw Failure.cannotListen(String(describing: error))
        }
        let queue = DispatchQueue(label: "dev.paperplane.bridge")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Task { await serve(connection, requestLimit: requestLimit, handler: handler) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { state in
                let result: Result<Void, any Error>? = switch state {
                case .ready: .success(())
                case .failed(let error): .failure(Failure.cannotListen(String(describing: error)))
                case .cancelled: .failure(Failure.cannotListen("cancelled"))
                default: nil
                }
                let first = resumed.withLock { (done: inout Bool) -> Bool in
                    defer { done = true }
                    return !done
                }
                guard let result, first else { return }
                continuation.resume(with: result)
            }
            listener.start(queue: queue)
        }
        // The socket is created with the umask's mode; only this user may write to it.
        chmod(socket.path, 0o600)
        return BridgeServer(socket: socket, listener: listener)
    }

    /// Stops listening and removes the socket, so the helper knows the app isn't there.
    public func stop() {
        listener.cancel()
        unlink(socket.path)
    }

    private static func serve(_ connection: NWConnection, requestLimit: Duration,
                              handler: @Sendable (PlayRequest) async -> PlayReply) async {
        let reply: PlayReply
        do {
            let message = try await receiveRequest(on: connection, within: requestLimit)
            reply = await handler(try PlayRequest.decode(message))
        } catch let invalid as PlayRequest.Invalid {
            log.error("Refused a request: \(invalid.reason, privacy: .public)")
            reply = .failed("Paper Plane can't play this (\(invalid.reason)).")
        } catch NativeMessaging.Error.tooLarge {
            log.error("Refused a request: too large")
            reply = .failed("Paper Plane can't play this (request too large).")
        } catch {
            // Closed or silent: nobody to answer.
            connection.cancel()
            return
        }
        connection.send(content: NativeMessaging.frame(reply.encoded()), contentContext: .finalMessage,
                        isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }

    private struct Silent: Error {}

    /// Reads until one whole frame has arrived. Gives up, closing the connection, after `limit`.
    private static func receiveRequest(on connection: NWConnection, within limit: Duration) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                var buffer = Data()
                while true {
                    if let message = try NativeMessaging.take(from: &buffer) {
                        return message
                    }
                    buffer += try await receive(on: connection)
                }
            }
            group.addTask {
                try await Task.sleep(for: limit)
                connection.cancel() // ends the pending receive
                throw Silent()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// The next bytes, or an error once the connection has closed.
    private static func receive(on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? Silent())
                }
            }
        }
    }
}
```

```swift
import Foundation

/// The helper's work (spec §5.2). Chrome starts `paperplane-host` for each message: it relays the
/// one request to the app's socket and the app's reply back, starting the app if nothing is
/// listening. Blocking calls throughout, for a command-line tool that does nothing else.
public enum HostRelay {
    struct SocketError: Error {
        var code: Int32
    }

    /// Reads one framed message from `input`, or nil if it's cut short or too large.
    public static func readRequest(from input: FileHandle) -> Data? {
        guard let header = read(4, from: input), let length = NativeMessaging.announcedLength(in: header),
              length < NativeMessaging.maximumLength
        else { return nil }
        return read(length, from: input)
    }

    /// Relays `request` to the app listening at `socket` and returns its reply. With nothing
    /// listening, calls `startApp` once and keeps trying for `startLimit` seconds; a reply that
    /// hasn't come within `replyLimit` seconds is given up on.
    public static func relay(_ request: Data, socket: URL, startApp: () -> Void,
                             startLimit: Double = 10, replyLimit: Double = 120) -> Data {
        guard let descriptor = connect(to: socket, startingApp: startApp, within: startLimit) else {
            return PlayReply.failed("Couldn't start Paper Plane.").encoded()
        }
        defer { close(descriptor) }
        do {
            try write(NativeMessaging.frame(request), to: descriptor)
            var buffer = Data()
            return try readFrame(from: descriptor, into: &buffer, limit: replyLimit)
        } catch {
            return PlayReply.failed("Paper Plane didn't answer.").encoded()
        }
    }

    /// The app bundle the helper is in: `…/Paper Plane.app/Contents/Helpers/paperplane-host`.
    public static func app(containing helper: URL) -> URL? {
        let app = helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }

    /// Opens `app` without bringing it to the front; it comes forward itself when asked to play.
    public static func open(_ app: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", app.path]
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
    }

    // MARK: - Sockets

    private static func connect(to socket: URL, startingApp startApp: () -> Void, within limit: Double) -> Int32? {
        if let descriptor = try? connect(to: socket) {
            return descriptor
        }
        startApp()
        let deadline = Date(timeIntervalSinceNow: limit)
        while Date() < deadline {
            usleep(100_000)
            if let descriptor = try? connect(to: socket) {
                return descriptor
            }
        }
        return nil
    }

    static func connect(to socket: URL) throws -> Int32 {
        var address = sockaddr_un()
        let path = socket.path.utf8CString
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw SocketError(code: ENAMETOOLONG) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            path.withUnsafeBytes { destination.copyMemory(from: $0) }
        }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SocketError(code: errno) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(descriptor)
            throw SocketError(code: code)
        }
        // If the app closes early, a write fails instead of killing the helper with SIGPIPE.
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return descriptor
    }

    static func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                guard written > 0 else { throw SocketError(code: errno) }
                offset += written
            }
        }
    }

    /// Reads until `buffer` holds a whole frame and returns its message. Throws when the other
    /// end closes first, the frame is too large, or `limit` seconds pass.
    static func readFrame(from descriptor: Int32, into buffer: inout Data, limit: Double) throws -> Data {
        let deadline = Date(timeIntervalSinceNow: limit)
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let message = try NativeMessaging.take(from: &buffer) {
                return message
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw SocketError(code: ETIMEDOUT) }
            var waiting = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&waiting, 1, Int32(min(remaining, 3600) * 1000))
            if ready < 0, errno == EINTR {
                continue
            }
            guard ready >= 0 else { throw SocketError(code: errno) }
            guard ready > 0 else { continue }
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            guard count > 0 else { throw SocketError(code: count == 0 ? ECONNRESET : errno) }
            buffer += chunk[0..<count]
        }
    }

    /// Exactly `count` bytes from `input`, or nil if it ends first.
    private static func read(_ count: Int, from input: FileHandle) -> Data? {
        var data = Data()
        while data.count < count {
            guard let chunk = try? input.read(upToCount: count - data.count), !chunk.isEmpty else { return nil }
            data += chunk
        }
        return data
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test-core.sh --filter "BridgeServerTests|HostRelayTests"`
Expected: PASS. Also `cd core && swift build -Xswiftc -warnings-as-errors` builds without warnings.

- [ ] **Step 5: Commit**

```bash
git add core/Sources/PaperPlaneCore/Bridge/BridgeServer.swift core/Sources/PaperPlaneCore/Bridge/HostRelay.swift core/Tests/PaperPlaneCoreTests/BridgeTests.swift
git commit -m "feat(core): the browser bridge's socket, and the helper's relay that starts the app"
```

### Task 4: The browser manifests and the extension's pinned key

**Files:**
- Create: `core/Sources/PaperPlaneCore/Bridge/BrowserHosts.swift`, `extension/static/manifest.json`
- Test: `core/Tests/PaperPlaneCoreTests/BrowserHostsTests.swift`

**Interfaces:**
- Produces: `BrowserHosts.name`, `extensionID`, `standardApplicationSupport`, `manifest(host:) -> Data`, `install(host:applicationSupport:) throws -> [URL]`; the extension's manifest with its public `key` (scratch: `extkey/make.sh` made the pair with OpenSSL and deleted the private key).

- [ ] **Step 1: Write the failing tests**

```swift
import CryptoKit
import Foundation
import Testing
@testable import PaperPlaneCore

struct BrowserHostsTests {
    static let host = URL(fileURLWithPath: "/Applications/Paper Plane.app/Contents/Helpers/paperplane-host")

    /// Spec §5.2: Chrome and Brave, each only when it's installed.
    @Test func installsForEachBrowserThatIsThere() throws {
        let support = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        try FileManager.default.createDirectory(at: support.appendingPathComponent("Google/Chrome"), withIntermediateDirectories: true)
        let written = try BrowserHosts.install(host: Self.host, applicationSupport: support)
        let chrome = support.appendingPathComponent("Google/Chrome/NativeMessagingHosts/dev.paperplane.host.json")
        #expect(written.map(\.path) == [chrome.path])
        #expect(!FileManager.default.fileExists(atPath: support.appendingPathComponent("BraveSoftware").path))

        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: chrome)) as? [String: Any]
        #expect(manifest?["name"] as? String == "dev.paperplane.host")
        #expect(manifest?["type"] as? String == "stdio")
        #expect(manifest?["path"] as? String == Self.host.path)
        #expect(manifest?["allowed_origins"] as? [String] == ["chrome-extension://napcmmglefncoieikecpjmdopmagllcg/"])
    }

    @Test func rewritesOnlyWhatChanged() throws {
        let support = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        try FileManager.default.createDirectory(at: support.appendingPathComponent("BraveSoftware/Brave-Browser"),
                                                withIntermediateDirectories: true)
        #expect(try BrowserHosts.install(host: Self.host, applicationSupport: support).count == 1)
        #expect(try BrowserHosts.install(host: Self.host, applicationSupport: support).isEmpty)
        let moved = URL(fileURLWithPath: "/Users/someone/Applications/Paper Plane.app/Contents/Helpers/paperplane-host")
        #expect(try BrowserHosts.install(host: moved, applicationSupport: support).count == 1)
    }

    /// The ID the manifests allow is the one Chrome derives from the extension's pinned key:
    /// the first 32 hex digits of the key's SHA-256, each mapped 0–f → a–p.
    @Test func allowsTheExtensionThatShipsWithIt() throws {
        let url = TestSupport.repoRoot.appendingPathComponent("extension/static/manifest.json")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let encoded = try #require(manifest?["key"] as? String)
        let key = try #require(Data(base64Encoded: encoded))
        let hex = SHA256.hash(data: key).prefix(16).map { String(format: "%02x", $0) }.joined()
        let id = String(hex.map { Character(UnicodeScalar(UInt8(Int(String($0), radix: 16)!) + 97)) })
        #expect(id == BrowserHosts.extensionID)
    }
}
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `scripts/test-core.sh --filter BrowserHostsTests`
Expected: FAIL — `cannot find 'BrowserHosts' in scope`.

- [ ] **Step 3: Write the implementation and the extension's manifest**

```swift
import Foundation

/// The native messaging manifests that let Chrome and Brave start the helper (spec §5.2).
public enum BrowserHosts {
    public static let name = "dev.paperplane.host"
    /// The extension's ID, which Chrome derives from the public key in
    /// extension/static/manifest.json. Only this extension may start the helper.
    public static let extensionID = "napcmmglefncoieikecpjmdopmagllcg"
    /// Chrome's and Brave's folders in Application Support.
    static let browsers = ["Google/Chrome", "BraveSoftware/Brave-Browser"]

    public static var standardApplicationSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    }

    /// The manifest for the helper at `host`.
    public static func manifest(host: URL) -> Data {
        let object: [String: Any] = [
            "name": name,
            "description": "Paper Plane",
            "path": host.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"],
        ]
        // Plain strings and arrays can't fail to serialize.
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            ?? Data()
    }

    /// Writes the manifest for each browser installed under `applicationSupport`, leaving files
    /// that already say the same alone, and returns the files written.
    @discardableResult
    public static func install(host: URL, applicationSupport: URL) throws -> [URL] {
        let manifest = manifest(host: host)
        var written: [URL] = []
        for browser in browsers {
            let folder = applicationSupport.appendingPathComponent(browser, isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            let hosts = folder.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
            let file = hosts.appendingPathComponent("\(name).json")
            guard (try? Data(contentsOf: file)) != manifest else { continue }
            try FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
            try manifest.write(to: file, options: .atomic)
            written.append(file)
        }
        return written
    }
}
```

```json
{
  "manifest_version": 3,
  "name": "Paper Plane",
  "version": "0.1.0",
  "description": "Sends the video you're watching to your AirPlay TV, through Paper Plane for Mac.",
  "key": "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAwUHRPS7pTfKqQ55Sfxvm4k9oBWQvNnMIMjoBWCSiPPgRm3bPDlrETLurqsinb/uMzDCcIvqolYgnWnKksvlOAmahabXFXv/qsCW06pc3ExRY4wTFYNMQO14JvQS01Bu97jIv9PV84f2kbgWxA1uLlz0QRLM+RYmS8Y0FPMa71w2ALi31X3mm8N5IyJzb9Tv/C1nv05607/voFos8uq8r+ZHz5wLzwSPih3V5f8fd7e+QqWRl0EZ9DDyL9QyX7MFyYgwd0NdQAnWVvI/v3FRWajoXAcbQ7DfisXlBReeCFsFZW/N9GZ0Wte9iaGUalm+aQmXJSJMFX2rT7CvVM50ncQIDAQAB",
  "minimum_chrome_version": "116",
  "permissions": ["webRequest", "nativeMessaging", "storage", "scripting", "tabs"],
  "host_permissions": ["<all_urls>"],
  "background": {
    "service_worker": "background.js",
    "type": "module"
  },
  "content_scripts": [
    {
      "matches": ["<all_urls>"],
      "js": ["content.js"],
      "all_frames": true,
      "match_about_blank": true,
      "run_at": "document_start"
    }
  ],
  "action": {
    "default_title": "Paper Plane: no video found yet",
    "default_icon": {
      "16": "icons/idle-16.png",
      "32": "icons/idle-32.png",
      "48": "icons/idle-48.png",
      "128": "icons/idle-128.png"
    }
  },
  "icons": {
    "16": "icons/icon-16.png",
    "32": "icons/icon-32.png",
    "48": "icons/icon-48.png",
    "128": "icons/icon-128.png"
  }
}
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test-core.sh --filter BrowserHostsTests`
Expected: PASS, including `allowsTheExtensionThatShipsWithIt`.

- [ ] **Step 5: Commit**

```bash
git add core/Sources/PaperPlaneCore/Bridge/BrowserHosts.swift core/Tests/PaperPlaneCoreTests/BrowserHostsTests.swift extension/static/manifest.json
git commit -m "feat(core): native messaging manifests for Chrome and Brave, for the extension's pinned ID"
```

### Task 5: Web streams in ffmpeg — web protocols only, copied AAC, a site's refusal

**Files:**
- Create: `core/Sources/PaperPlaneCore/Media/SiteRefusal.swift`, `core/Tests/PaperPlaneCoreTests/WebInputTests.swift`
- Modify: `core/Sources/PaperPlaneCore/Media/ResolvedInput.swift`, `core/Sources/PaperPlaneCore/Conversion/ConversionPlan.swift`, `core/Sources/PaperPlaneCore/Conversion/ConversionPlanner.swift`, `core/Sources/PaperPlaneCore/Conversion/FFmpegArguments.swift`, `scripts/serve-hls.py`
- Test: `core/Tests/PaperPlaneCoreTests/ResolvedInputTests.swift`, `FFmpegArgumentsTests.swift`, `ConversionPlannerTests.swift`, `TranscoderTests.swift`

**Interfaces:**
- Produces: `ResolvedInput.Input.webOnly` (in every web input's `ffmpegOptions`); `AudioAction.copy(AudioCodecName)`; `SiteRefusal.isRefusal(_ error:)`, `isRefusal(stderr:)`; serve-hls.py's `/status/<code>/…` and `/cookie/<name>=<value>/…` test paths.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import PaperPlaneCore

/// Streams from the browser (spec §5.3): served locally by scripts/serve-hls.py, whose
/// `/cookie/<name>=<value>/…` paths need that cookie and `/status/<code>/…` paths answer with
/// that status, as a site would.
@Suite(.enabled(if: TestSupport.hasMedia, "Needs ffmpeg (brew install ffmpeg) and scripts/make-test-media.sh"))
struct WebInputTests {
    static func web(_ url: URL, cookie: String? = nil) -> ResolvedInput {
        ResolvedInput(inputs: [.init(url: url, headers: cookie.map { ["Cookie": $0] } ?? [:])], title: "Web")
    }

    @Test func probesAndConvertsAStreamThatNeedsItsCookie() async throws {
        let tools = try #require(TestSupport.tools)
        let server = try await HLSServer(directory: TestSupport.mediaDirectory)
        defer { server.stop() }
        let input = Self.web(server.url("cookie/pp=1/h264_aac.mp4"), cookie: "pp=1")
        let pipeline = StreamPipeline(tools: tools, folders: SessionFolders(root: try TestSupport.makeTemporaryDirectory()),
                                      profile: .default, host: "127.0.0.1")
        let media = try await pipeline.probe(input)
        #expect(media.info.video.count == 1)
        let stream = try await pipeline.start(media, at: 2)
        await stream.stop()
    }

    /// Most sites' HLS is MPEG-TS segments with ADTS AAC, which is copied, not re-encoded.
    @Test func convertsAnHLSStreamOfMPEGTSSegments() async throws {
        let tools = try #require(TestSupport.tools)
        let server = try await HLSServer(directory: try await Self.makeHLS(live: false))
        defer { server.stop() }
        let pipeline = StreamPipeline(tools: tools, folders: SessionFolders(root: try TestSupport.makeTemporaryDirectory()),
                                      profile: .default, host: "127.0.0.1")
        let media = try await pipeline.probe(Self.web(server.url("index.m3u8")))
        let stream = try await pipeline.start(media, at: 0)
        #expect(stream.plan.audioAction == .copy(.aac))
        await stream.stop()
    }

    /// Spec §6: a site that refuses the stream (an expired link or a missing cookie).
    @Test(arguments: ["status/403/h264_aac.mp4", "status/410/h264_aac.mp4", "status/401/h264_aac.mp4",
                      "cookie/pp=1/h264_aac.mp4"])
    func recognisesASiteRefusingTheStream(_ path: String) async throws {
        let tools = try #require(TestSupport.tools)
        let server = try await HLSServer(directory: TestSupport.mediaDirectory)
        defer { server.stop() }
        do {
            _ = try await MediaProbe(tools: tools).probe(Self.web(server.url(path)))
            Issue.record("probed a refused stream")
        } catch {
            #expect(SiteRefusal.isRefusal(error), "\(error)")
        }
    }

    @Test func aMissingFileIsNotARefusal() {
        let error = MediaProbeError.ffprobeFailed(status: 1, message: "/Movies/a.mkv: No such file or directory")
        #expect(!SiteRefusal.isRefusal(error))
    }

    /// Spec §5.3: an HLS playlist without #EXT-X-ENDLIST is live, and has no duration.
    @Test func aLivePlaylistHasNoDuration() async throws {
        let tools = try #require(TestSupport.tools)
        let folder = try await Self.makeHLS(live: true)
        let server = try await HLSServer(directory: folder)
        defer { server.stop() }
        let info = try await MediaProbe(tools: tools).probe(Self.web(server.url("index.m3u8")))
        #expect(info.duration == nil)
        #expect(info.video.count == 1)
    }

    /// ffmpeg already refuses file: under a web playlist; the explicit list keeps it that way and
    /// shuts out udp: and rtp: too.
    @Test func aWebPlaylistCantReadLocalFiles() async throws {
        let tools = try #require(TestSupport.tools)
        let folder = try await Self.makeHLS(live: false)
        let segments = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".ts") }.sorted()
        let web = try TestSupport.makeTemporaryDirectory()
        let playlist = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:3"]
            + segments.flatMap { ["#EXTINF:2.0,", folder.appendingPathComponent($0).absoluteString] }
            + ["#EXT-X-ENDLIST"]
        try playlist.joined(separator: "\n").write(to: web.appendingPathComponent("local.m3u8"), atomically: true, encoding: .utf8)
        let server = try await HLSServer(directory: web)
        defer { server.stop() }
        await #expect(throws: MediaProbeError.self) {
            try await MediaProbe(tools: tools).probe(Self.web(server.url("local.m3u8")))
        }
    }

    /// The 10-second test clip as 2-second MPEG-TS segments; `live` leaves out #EXT-X-ENDLIST.
    static func makeHLS(live: Bool) async throws -> URL {
        let tools = try #require(TestSupport.tools)
        let folder = try TestSupport.makeTemporaryDirectory()
        let result = try await ProcessRunner.run(tools.ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-i", TestSupport.media("h264_aac.mp4").path, "-c", "copy",
            "-f", "hls", "-hls_time", "2", "-hls_list_size", "0", "-hls_segment_type", "mpegts",
            "-hls_segment_filename", folder.appendingPathComponent("seg%d.ts").path,
            folder.appendingPathComponent("index.m3u8").path,
        ])
        try #require(result.status == 0)
        if live {
            let playlist = folder.appendingPathComponent("index.m3u8")
            let text = try String(contentsOf: playlist, encoding: .utf8)
                .split(separator: "\n").filter { !$0.hasPrefix("#EXT-X-ENDLIST") && !$0.hasPrefix("#EXT-X-PLAYLIST-TYPE") }
            try text.joined(separator: "\n").write(to: playlist, atomically: true, encoding: .utf8)
        }
        return folder
    }
}
```

```diff
--- a/core/Tests/PaperPlaneCoreTests/ResolvedInputTests.swift
+++ b/core/Tests/PaperPlaneCoreTests/ResolvedInputTests.swift
@@ -17,21 +17,23 @@
             url: URL(string: "https://cdn.example.com/v/master.m3u8?token=abc")!,
             headers: ["Referer": "https://example.com/watch", "Cookie": "a=1; b=2", "user-agent": "Chrome/140"])
         #expect(input.ffmpegLocation == "https://cdn.example.com/v/master.m3u8?token=abc")
-        #expect(input.ffmpegOptions == [
+        #expect(input.ffmpegOptions == ResolvedInput.Input.webOnly + [
             "-user_agent", "Chrome/140",
             "-headers", "Cookie: a=1; b=2\r\nReferer: https://example.com/watch\r\n",
         ])
     }
 
-    @Test func webInputWithoutHeadersHasNoOptions() {
+    /// A site's playlist can name any URL; ffmpeg may follow only web ones, never file:, udp: or
+    /// rtp: (security review, Plan 4).
+    @Test func webInputsReachOnlyTheWeb() {
         let input = ResolvedInput.Input(url: URL(string: "https://example.com/v.mp4")!)
-        #expect(input.ffmpegOptions == [])
+        #expect(input.ffmpegOptions == ["-protocol_whitelist", "https,http,tls,tcp,crypto,data"])
     }
 
     @Test func headerLineBreaksAreStripped() {
         let input = ResolvedInput.Input(
             url: URL(string: "https://example.com/v.mp4")!,
             headers: ["Cookie": "a=1\r\nX-Injected: yes"])
-        #expect(input.ffmpegOptions == ["-headers", "Cookie: a=1X-Injected: yes\r\n"])
+        #expect(input.ffmpegOptions == ResolvedInput.Input.webOnly + ["-headers", "Cookie: a=1X-Injected: yes\r\n"])
     }
 }
```

```diff
--- a/core/Tests/PaperPlaneCoreTests/FFmpegArgumentsTests.swift
+++ b/core/Tests/PaperPlaneCoreTests/FFmpegArgumentsTests.swift
@@ -13,7 +13,7 @@
         "-hls_flags", "independent_segments+temp_file", "-start_number", "0", "/tmp/session/index.m3u8",
     ]
 
-    static func plan(_ video: VideoAction, audio: AudioAction? = .copy) -> ConversionPlan {
+    static func plan(_ video: VideoAction, audio: AudioAction? = .copy(.ac3)) -> ConversionPlan {
         ConversionPlan(video: TrackRef(index: 0), videoAction: video,
                        audio: audio == nil ? nil : TrackRef(index: 2), audioAction: audio)
     }
@@ -28,21 +28,29 @@
         ] + Self.hlsTail)
     }
 
+    /// AAC from MPEG-TS (most HLS sites, and .ts files) carries ADTS headers that fMP4 can't
+    /// hold; the filter rewrites them and passes other AAC through. Dolby audio needs nothing.
+    @Test func copiedAACIsMadeFitForMP4() {
+        let aac = Self.plan(.copy(.h264), audio: .copy(.aac)).ffmpegArguments(input: Self.movie, start: 0, output: Self.output)
+        #expect(aac.contains(subsequence: ["-c:a", "copy", "-bsf:a", "aac_adtstoasc"]))
+        let ac3 = Self.plan(.copy(.h264), audio: .copy(.ac3)).ffmpegArguments(input: Self.movie, start: 0, output: Self.output)
+        #expect(!ac3.contains("-bsf:a"))
+    }
+
     @Test func startOffsetGoesBeforeEachInput() {
         let input = ResolvedInput(inputs: [
             .init(url: URL(string: "https://cdn.example.com/video.mp4")!, headers: ["Cookie": "a=1"]),
             .init(url: URL(string: "https://cdn.example.com/audio.m4a")!, headers: ["Cookie": "a=1"]),
         ], title: "Clip")
         let plan = ConversionPlan(video: TrackRef(input: 0, index: 0), videoAction: .copy(.h264),
-                                  audio: TrackRef(input: 1, index: 0), audioAction: .copy)
+                                  audio: TrackRef(input: 1, index: 0), audioAction: .copy(.aac))
         let args = plan.ffmpegArguments(input: input, start: 754.25, output: Self.output)
-        #expect(Array(args.prefix(20)) == [
-            "-hide_banner", "-nostdin", "-nostats", "-loglevel", "error",
-            "-headers", "Cookie: a=1\r\n", "-ss", "754.250", "-i", "https://cdn.example.com/video.mp4",
-            "-headers", "Cookie: a=1\r\n", "-ss", "754.250", "-i", "https://cdn.example.com/audio.m4a",
-            "-map", "0:0", "-map",
-        ])
-        #expect(args[20] == "1:0")
+        let web = ResolvedInput.Input.webOnly
+        #expect(Array(args.prefix(24)) == ["-hide_banner", "-nostdin", "-nostats", "-loglevel", "error"]
+            + web + ["-headers", "Cookie: a=1\r\n", "-ss", "754.250", "-i", "https://cdn.example.com/video.mp4"]
+            + web + ["-headers", "Cookie: a=1\r\n", "-ss", "754.250", "-i", "https://cdn.example.com/audio.m4a",
+                     "-map", "0:0", "-map"])
+        #expect(args[24] == "1:0")
     }
 
     @Test func hevcCopyIsTaggedForApple() {
```

```diff
--- a/core/Tests/PaperPlaneCoreTests/ConversionPlannerTests.swift
+++ b/core/Tests/PaperPlaneCoreTests/ConversionPlannerTests.swift
@@ -97,10 +97,10 @@
     // MARK: - Audio
 
     @Test(arguments: [
-        (AudioCodecName.aac, 2, AudioAction.copy),
-        (.aac, 6, .copy),
-        (.ac3, 6, .copy),
-        (.eac3, 6, .copy),
+        (AudioCodecName.aac, 2, AudioAction.copy(.aac)),
+        (.aac, 6, .copy(.aac)),
+        (.ac3, 6, .copy(.ac3)),
+        (.eac3, 6, .copy(.eac3)),
         (.other("dts"), 6, .eac3Surround),
         (.other("truehd"), 8, .eac3Surround),
         (.other("flac"), 8, .eac3Surround),
@@ -113,7 +113,7 @@
     }
 
     @Test(arguments: [
-        (AudioCodecName.aac, 2, AudioAction.copy),
+        (AudioCodecName.aac, 2, AudioAction.copy(.aac)),
         (.aac, 6, .aacStereo),
         (.ac3, 6, .aacStereo),
         (.eac3, 2, .aacStereo),
@@ -131,7 +131,7 @@
         let flagged = try ConversionPlanner.plan(Self.media([Self.video(.h264)], [english, japanese]),
                                                  profile: Self.surroundAndHDR)
         #expect(flagged.audio == japanese.ref)
-        #expect(flagged.audioAction == .copy)
+        #expect(flagged.audioAction == .copy(.ac3))
 
         var unflagged = japanese
         unflagged.isDefault = false
```

```diff
--- a/core/Tests/PaperPlaneCoreTests/TranscoderTests.swift
+++ b/core/Tests/PaperPlaneCoreTests/TranscoderTests.swift
@@ -6,7 +6,7 @@
 /// Transcoder behaviour with a scripted stand-in for ffmpeg, so timing and failures are exact.
 struct TranscoderTests {
     static let plan = ConversionPlan(video: TrackRef(index: 0), videoAction: .copy(.h264),
-                                     audio: TrackRef(index: 1), audioAction: .copy)
+                                     audio: TrackRef(index: 1), audioAction: .copy(.aac))
     static let input = ResolvedInput.file(URL(fileURLWithPath: "/Movies/movie.mkv"))
 
     @Test func returnsOnceTwoSegmentsAndTheMasterPlaylistExist() async throws {
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `scripts/test-core.sh --filter "WebInputTests|ResolvedInputTests|FFmpegArgumentsTests|ConversionPlannerTests|TranscoderTests"`
Expected: FAIL — `type 'AudioAction' has no member 'copy(_:)'`, `cannot find 'SiteRefusal' in scope`. Without the filter, the live and MPEG-TS cases fail on ffmpeg's "Malformed AAC bitstream detected: use the audio bitstream filter 'aac_adtstoasc'".

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// A site refusing a web stream (spec §6): a link that has expired, or cookies it no longer
/// accepts. Clicking Paper Plane in the browser again sends a fresh link.
public enum SiteRefusal {
    /// How ffmpeg reports HTTP 401, 403, 404 and the other 4xx answers (410 Gone among them).
    static let signs = ["Server returned 401", "Server returned 403", "Server returned 404", "Server returned 4XX"]

    public static func isRefusal(_ error: any Error) -> Bool {
        switch error {
        case MediaProbeError.ffprobeFailed(_, let message), TranscodeError.ffmpegFailed(_, let message):
            isRefusal(stderr: message)
        default:
            false
        }
    }

    public static func isRefusal(stderr: String) -> Bool {
        signs.contains { stderr.contains($0) }
    }
}
```

```diff
--- a/core/Sources/PaperPlaneCore/Media/ResolvedInput.swift
+++ b/core/Sources/PaperPlaneCore/Media/ResolvedInput.swift
@@ -18,13 +18,17 @@
             url.isFileURL ? url.path : url.absoluteString
         }
 
+        /// What a web input, and every playlist or segment it names, may be read over: never
+        /// file:, udp: or rtp:, whatever a site's playlist says.
+        static let webOnly = ["-protocol_whitelist", "https,http,tls,tcp,crypto,data"]
+
         /// Options that must come right before this input's `-i` (ffmpeg) or the input (ffprobe).
         public var ffmpegOptions: [String] {
             guard !url.isFileURL else { return [] }
             var remaining = Dictionary(
                 headers.map { (Self.stripLineBreaks($0.key), Self.stripLineBreaks($0.value)) },
                 uniquingKeysWith: { first, _ in first })
-            var options: [String] = []
+            var options = Self.webOnly
             if let key = remaining.keys.first(where: { $0.lowercased() == "user-agent" }),
                let agent = remaining.removeValue(forKey: key) {
                 options += ["-user_agent", agent]
```

```diff
--- a/core/Sources/PaperPlaneCore/Conversion/ConversionPlan.swift
+++ b/core/Sources/PaperPlaneCore/Conversion/ConversionPlan.swift
@@ -57,7 +57,8 @@
 }
 
 public enum AudioAction: Equatable, Sendable {
-    case copy
+    /// Copied as it is (AAC, AC3 or E-AC3).
+    case copy(AudioCodecName)
     /// E-AC3 5.1 at 640 kb/s (7.1 sources are downmixed).
     case eac3Surround
     /// AAC stereo at 192 kb/s.
```

```diff
--- a/core/Sources/PaperPlaneCore/Conversion/ConversionPlanner.swift
+++ b/core/Sources/PaperPlaneCore/Conversion/ConversionPlanner.swift
@@ -79,10 +79,10 @@
     static func audioAction(for track: AudioTrack, profile: OutputProfile) -> AudioAction {
         if profile.surround {
             switch track.codec {
-            case .aac, .ac3, .eac3: return .copy
+            case .aac, .ac3, .eac3: return .copy(track.codec)
             case .other: return track.channels > 2 ? .eac3Surround : .aacStereo
             }
         }
-        return track.codec == .aac && track.channels <= 2 ? .copy : .aacStereo
+        return track.codec == .aac && track.channels <= 2 ? .copy(.aac) : .aacStereo
     }
 }
```

```diff
--- a/core/Sources/PaperPlaneCore/Conversion/FFmpegArguments.swift
+++ b/core/Sources/PaperPlaneCore/Conversion/FFmpegArguments.swift
@@ -121,6 +121,8 @@
     private func audioArguments() -> [String] {
         switch audioAction {
         case nil: return []
+        // AAC from MPEG-TS has ADTS headers fMP4 can't hold; the filter passes other AAC through.
+        case .copy(.aac): return ["-c:a", "copy", "-bsf:a", "aac_adtstoasc"]
         case .copy: return ["-c:a", "copy"]
         case .eac3Surround: return ["-c:a", "eac3", "-b:a", "640k", "-ac", "6"]
         case .aacStereo: return ["-c:a", "aac", "-b:a", "192k", "-ac", "2"]
```

```diff
--- a/scripts/serve-hls.py
+++ b/scripts/serve-hls.py
@@ -19,6 +19,29 @@
 
 class Handler(http.server.SimpleHTTPRequestHandler):
     extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map, **HLS_TYPES}
+
+    def admit(self):
+        """Test hooks that act like a site: /status/<code>/… answers with that status, and
+        /cookie/<name>=<value>/… serves the rest of the path only with that cookie."""
+        parts = self.path.split("/", 3)  # "", hook, argument, rest
+        if len(parts) >= 3 and parts[1] == "status":
+            self.send_error(int(parts[2]))
+            return False
+        if len(parts) >= 3 and parts[1] == "cookie":
+            cookies = [cookie.strip() for cookie in self.headers.get("Cookie", "").split(";")]
+            if parts[2] not in cookies:
+                self.send_error(403)
+                return False
+            self.path = "/" + (parts[3] if len(parts) > 3 else "")
+        return True
+
+    def do_GET(self):
+        if self.admit():
+            super().do_GET()
+
+    def do_HEAD(self):
+        if self.admit():
+            super().do_HEAD()
 
     def log_message(self, format, *args):
         if self.server.verbose:
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test-core.sh --filter "WebInputTests|ResolvedInputTests|FFmpegArgumentsTests|ConversionPlannerTests|TranscoderTests|PipelineTests"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add core/Sources/PaperPlaneCore/Media/SiteRefusal.swift core/Sources/PaperPlaneCore/Media/ResolvedInput.swift core/Sources/PaperPlaneCore/Conversion scripts/serve-hls.py core/Tests/PaperPlaneCoreTests/WebInputTests.swift core/Tests/PaperPlaneCoreTests/ResolvedInputTests.swift core/Tests/PaperPlaneCoreTests/FFmpegArgumentsTests.swift core/Tests/PaperPlaneCoreTests/ConversionPlannerTests.swift core/Tests/PaperPlaneCoreTests/TranscoderTests.swift
git commit -m "feat(core): web streams read only the web, copied AAC fits fMP4, and a site's refusal is recognised"
```

### Task 6: A window that never rests a web stream's ffmpeg

**Files:**
- Modify: `core/Sources/PaperPlaneCore/Streaming/SegmentWindow.swift`
- Test: `core/Tests/PaperPlaneCoreTests/SegmentWindowTests.swift`

**Interfaces:**
- Produces: `SegmentWindow.pausesConversion` (default true).

- [ ] **Step 1: Write the failing test**

```diff
--- a/core/Tests/PaperPlaneCoreTests/SegmentWindowTests.swift
+++ b/core/Tests/PaperPlaneCoreTests/SegmentWindowTests.swift
@@ -9,6 +9,15 @@
     }
 
     let window = SegmentWindow()
+
+    /// A web stream's ffmpeg is never paused: the site may drop an idle connection (addendum
+    /// M3-16). What's behind is still deleted.
+    @Test func aWindowThatDoesntPauseStillDeletesWhatIsBehind() {
+        var web = SegmentWindow.forFreeSpace(1_000_000_000)
+        web.pausesConversion = false
+        #expect(web.actions(playhead: 400, segments: Self.segments(200), conversionPaused: false,
+                            conversionFinished: false) == [.delete(Self.segments(16))])
+    }
 
     @Test func keepsConvertingWhileLessThanTwentyMinutesAhead() {
         #expect(window.actions(playhead: 0, segments: Self.segments(10), conversionPaused: false,
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `scripts/test-core.sh --filter SegmentWindowTests`
Expected: FAIL — `value of type 'SegmentWindow' has no member 'pausesConversion'`.

- [ ] **Step 3: Write the implementation**

```diff
--- a/core/Sources/PaperPlaneCore/Streaming/SegmentWindow.swift
+++ b/core/Sources/PaperPlaneCore/Streaming/SegmentWindow.swift
@@ -35,6 +35,9 @@
     public var pauseAhead: Double
     /// …and resumes once it is less than this far ahead.
     public var resumeAhead: Double
+    /// False for web streams: the site may drop a connection ffmpeg leaves idle, so their
+    /// conversion runs on and only what's behind is deleted (addendum M3-16).
+    public var pausesConversion = true
 
     public init(keepBehind: Double = 300, pauseAhead: Double = 1200, resumeAhead: Double = 600) {
         self.keepBehind = keepBehind
@@ -52,7 +55,7 @@
                         conversionFinished: Bool) -> [Action] {
         var actions: [Action] = []
         let ahead = (segments.last?.end ?? 0) - playhead
-        if !conversionFinished {
+        if pausesConversion && !conversionFinished {
             if !conversionPaused && ahead >= pauseAhead {
                 actions.append(.pauseConversion)
             } else if conversionPaused && ahead < resumeAhead {
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test-core.sh --filter SegmentWindowTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add core/Sources/PaperPlaneCore/Streaming/SegmentWindow.swift core/Tests/PaperPlaneCoreTests/SegmentWindowTests.swift
git commit -m "feat(core): a window that deletes behind without resting ffmpeg, for web streams"
```

### Task 7: Playing a browser request, live streams, and the reply

**Files:**
- Modify: `core/Sources/PaperPlaneUI/PlaybackController.swift`, `PlaybackController+Sessions.swift`, `RemoteState.swift`, `RemoteView.swift`, `NowPlaying.swift`
- Create: `core/Tests/PaperPlaneUITests/BrowserPlaybackTests.swift`
- Test: `core/Tests/PaperPlaneUITests/RemoteStateTests.swift`, `NowPlayingTests.swift`, `RemoteSnapshotTests.swift`

**Interfaces:**
- Consumes: `PlayRequest`, `PlayReply` (Task 2), `SiteRefusal` (Task 5), `SegmentWindow.pausesConversion` (Task 6).
- Produces:
  - `PlaybackController.play(_ request: PlayRequest) async -> PlayReply`, `isLive`; `PlaybackError.isSiteRefusal(_:)`.
  - `RemoteState.isLive` and `canSeek`; `NowPlaying.Published.isLive`; the `LiveIndicator` view.
  - Renders `docs/design/remote-live-{light,dark}.png`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import os
@testable import PaperPlaneCore
import Testing
@testable import PaperPlaneUI

/// Videos sent from the browser (spec §5.3), from scripts/serve-hls.py acting as a site: its
/// `/cookie/<name>=<value>/…` paths need that cookie and `/status/<code>/…` paths refuse.
@MainActor
@Suite(.enabled(if: UITestMedia.available, "Needs ffmpeg and scripts/make-test-media.sh"))
struct BrowserPlaybackTests {
    static let refused = "The site stopped the stream — click Paper Plane in your browser again."

    static func request(_ url: URL, kind: String = "stream", format: String = "progressive", cookie: String? = nil,
                        startAt: Double = 0, title: String = "A film") throws -> PlayRequest {
        var source: [String: Any] = ["kind": kind, "url": url.absoluteString]
        if kind == "stream" {
            source["format"] = format
        }
        if let cookie {
            source["headers"] = ["Cookie": cookie]
        }
        let message: [String: Any] = ["type": "play", "v": 1, "source": source, "title": title, "startAt": startAt]
        return try PlayRequest.decode(JSONSerialization.data(withJSONObject: message))
    }

    static func controller(_ environment: PlaybackController.Environment) -> PlaybackController {
        let controller = PlaybackController(environment: environment, showsWelcome: true, welcomeSeen: {})
        controller.player.isMuted = true
        return controller
    }

    /// The reply waits until the video is ready for the TV, so the browser pauses only once
    /// Paper Plane has it (spec §5.1).
    @Test func aBrowserStreamIsAnsweredOnceItIsReadyForTheTV() async throws {
        let server = try await UITestServer(directory: UITestMedia.file(""))
        defer { server.stop() }
        let thumbnails = OSAllocatedUnfairLock(initialState: 0)
        var environment = try PlaybackControllerMediaTests.environment()
        environment.thumbnail = { _, _, _ in
            thumbnails.withLock { $0 += 1 }
            return nil
        }
        let controller = Self.controller(environment)
        let reply = await controller.play(try Self.request(server.url("cookie/pp=1/h264_aac.mp4"), cookie: "pp=1", startAt: 4))
        #expect(reply == .ok)
        #expect(controller.phase == .waitingForTV)
        #expect(controller.title == "A film")
        #expect(!controller.showsWelcome)
        #expect(abs((controller.stream?.session.offset ?? 0) - 4) < 0.05) // where the browser had got to
        #expect(!controller.remoteState.isLive)
        #expect(thumbnails.withLock { $0 } == 0) // nothing more is fetched from the site than playing needs
        await controller.shutDown()
    }

    @Test func aSiteThatRefusesTheStreamIsNamed() async throws {
        let server = try await UITestServer(directory: UITestMedia.file(""))
        defer { server.stop() }
        let controller = Self.controller(try PlaybackControllerMediaTests.environment())
        let reply = await controller.play(try Self.request(server.url("status/403/h264_aac.mp4")))
        #expect(reply == .failed(Self.refused))
        #expect(controller.phase == .failed(Self.refused))
        await controller.shutDown()
    }

    /// YouTube needs yt-dlp, which comes in Milestone 4 (addendum M3-4); until then a page asks
    /// nothing of what's playing.
    @Test func aPageLeavesWhatIsPlayingAlone() async throws {
        let controller = Self.controller(try PlaybackControllerMediaTests.environment())
        controller.play([UITestMedia.file("h264_aac.mp4")])
        await PlaybackControllerTests.eventually { controller.phase == .waitingForTV }
        let reply = await controller.play(try Self.request(URL(string: "https://www.youtube.com/watch?v=x")!, kind: "page"))
        #expect(reply == .failed("YouTube comes in a later version of Paper Plane."))
        #expect(controller.phase == .waitingForTV)
        #expect(controller.title == "h264_aac")
        await controller.shutDown()
    }

    @Test func aNewerVideoTakesOverAnUnansweredRequest() async throws {
        let server = try await UITestServer(directory: UITestMedia.file(""))
        defer { server.stop() }
        var environment = try PlaybackControllerMediaTests.environment()
        environment.probe = { pipeline, input in
            try await Task.sleep(for: .seconds(2))
            return try await pipeline.probe(input)
        }
        let controller = Self.controller(environment)
        let request = try Self.request(server.url("h264_aac.mp4"))
        let first = Task { await controller.play(request) }
        try await Task.sleep(for: .milliseconds(200))
        controller.play([UITestMedia.file("h264_aac.mp4")])
        #expect(await first.value == .failed("Another video took its place."))
        await controller.shutDown()
    }

    /// Spec §5.3: a live stream starts at its live edge, can't be sought, and its conversion is
    /// never rested (addendum M3-15, M3-16).
    @Test func aLiveStreamPlaysLive() async throws {
        let folder = try await UITestServer.liveHLS()
        let server = try await UITestServer(directory: folder)
        defer { server.stop() }
        let failure = OSAllocatedUnfairLock(initialState: "")
        let controller = Self.controller(try PlaybackControllerMediaTests.environment(freeSpace: { 1_500_000_000 },
                                                                                       saveLog: { _, error in
            failure.withLock { $0 = "\(error)" }
            return nil
        }))
        let reply = await controller.play(try Self.request(server.url("index.m3u8"), format: "hls", startAt: 30))
        #expect(reply == .ok, "\(failure.withLock { $0 })")
        #expect(controller.remoteState.isLive)
        #expect(controller.stream?.session.offset == 0)

        controller.externalPlaybackChanged(active: true)
        controller.seek(toMovieTime: 5)
        #expect(controller.loading == nil) // nothing to seek in
        controller.segments = (0..<300).map { SegmentWindow.Segment(index: $0, start: Double($0) * 6, end: Double($0 + 1) * 6) }
        controller.movieTime = 400
        controller.manageWindow()
        #expect(!controller.conversionPaused)
        #expect(controller.segments.first?.index == 16) // what ended over 5 minutes ago is deleted
        // Low on space, it can't keep less ahead, and doesn't claim to.
        #expect(controller.notice == "Your Mac is low on disk space, so a long video may stop part-way through.")
        await controller.shutDown()
    }
}

/// Runs scripts/serve-hls.py on a random local port for the duration of a test.
final class UITestServer {
    private let process = Process()
    let port: Int

    init(directory: URL) async throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", UITestMedia.repoRoot.appendingPathComponent("scripts/serve-hls.py").path,
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
    }

    /// The test clip three times over as a live HLS playlist (no #EXT-X-ENDLIST) of 10-second
    /// segments: ffmpeg starts 3 segments from a live playlist's end, so it gets all 30 s.
    static func liveHLS() async throws -> URL {
        let tools = try #require(ToolPaths.locate())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pp-live-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let playlist = folder.appendingPathComponent("index.m3u8")
        let result = try await ProcessRunner.run(tools.ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-stream_loop", "2", "-i", UITestMedia.file("h264_aac.mp4").path,
            "-c", "copy", "-f", "hls", "-hls_time", "10", "-hls_list_size", "0", "-hls_segment_type", "mpegts",
            "-hls_segment_filename", folder.appendingPathComponent("seg%d.ts").path, playlist.path,
        ])
        try #require(result.status == 0)
        let lines = try String(contentsOf: playlist, encoding: .utf8).split(separator: "\n")
            .filter { !$0.hasPrefix("#EXT-X-ENDLIST") && !$0.hasPrefix("#EXT-X-PLAYLIST-TYPE") }
        try lines.joined(separator: "\n").write(to: playlist, atomically: true, encoding: .utf8)
        return folder
    }
}
```

```diff
--- a/core/Tests/PaperPlaneUITests/RemoteStateTests.swift
+++ b/core/Tests/PaperPlaneUITests/RemoteStateTests.swift
@@ -38,6 +38,17 @@
 struct RemoteStateTests {
     static func state(_ phase: RemoteState.Phase) -> RemoteState {
         RemoteState(phase: phase, title: "Movie", detail: "1080p", elapsed: 10, duration: 100, converted: 40)
+    }
+
+    /// Spec §5.3: a live stream has nothing to seek in, but plays and pauses.
+    @Test func aLiveStreamCantBeSought() {
+        var live = Self.state(.playing)
+        live.duration = nil
+        live.isLive = true
+        #expect(!live.canSeek)
+        #expect(live.canControlPlayback)
+        #expect(Self.state(.playing).canSeek)
+        #expect(!Self.state(.preparing).canSeek)
     }
 
     @Test func onlyAPlayingOrPausedVideoTakesTransportCommands() {
```

```diff
--- a/core/Tests/PaperPlaneUITests/NowPlayingTests.swift
+++ b/core/Tests/PaperPlaneUITests/NowPlayingTests.swift
@@ -10,6 +10,14 @@
     static func state(elapsed: Double = 10, playing: Bool = true, at seconds: Double = 0) -> NowPlaying.Published {
         NowPlaying.Published(title: "Movie", duration: 100, elapsed: elapsed, isPlaying: playing, hasArtwork: false,
                              at: Date(timeIntervalSince1970: seconds))
+    }
+
+    @Test func aLiveStreamIsLiveInControlCenter() {
+        var live = Self.state()
+        live.duration = nil
+        live.isLive = true
+        #expect(NowPlaying.info(live, artwork: nil)[MPNowPlayingInfoPropertyIsLiveStream] as? Bool == true)
+        #expect(NowPlaying.info(Self.state(), artwork: nil)[MPNowPlayingInfoPropertyIsLiveStream] == nil)
     }
 
     @Test func describesTheVideoForControlCenter() {
```

```diff
--- a/core/Tests/PaperPlaneUITests/RemoteSnapshotTests.swift
+++ b/core/Tests/PaperPlaneUITests/RemoteSnapshotTests.swift
@@ -42,6 +42,12 @@
         failedWithLog.canShowLog = true
         var choosingAgain = choosing
         choosingAgain.showsTVHelp = false
+        var live = movie
+        live.title = "Evening news"
+        live.detail = "1080p"
+        live.duration = nil
+        live.converted = nil
+        live.isLive = true
         return [
             ("welcome", RemoteState(showsWelcome: true)),
             ("idle", RemoteState()),
@@ -57,6 +63,7 @@
             ("moving", moving),
             ("failed-with-log", failedWithLog),
             ("choosing-tv-again", choosingAgain),
+            ("live", live),
         ]
     }()
 
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `scripts/test-core.sh --filter "BrowserPlaybackTests|RemoteStateTests|NowPlayingTests"`
Expected: FAIL — `value of type 'PlaybackController' has no member 'play'` (for a request), `value of type 'RemoteState' has no member 'isLive'`.

- [ ] **Step 3: Write the implementation**

```diff
--- a/core/Sources/PaperPlaneUI/PlaybackController.swift
+++ b/core/Sources/PaperPlaneUI/PlaybackController.swift
@@ -118,6 +118,10 @@
     }
     public internal(set) var movieTime = 0.0
     public private(set) var duration: Double?
+    /// A web stream with no end (spec §5.3): nothing to seek in.
+    public private(set) var isLive = false
+    /// From the browser rather than a file: its conversion is never rested (addendum M3-16).
+    @ObservationIgnored var isWeb = false
     /// How far the conversion has got, in movie time.
     public internal(set) var convertedEnd: Double?
     public private(set) var artwork: NSImage?
@@ -157,7 +161,7 @@
     /// The text subtitles as WebVTT, once converted.
     @ObservationIgnored var subtitleFiles: SubtitleFiles?
     @ObservationIgnored var extracting: Task<SubtitleFiles?, Never>?
-    @ObservationIgnored private var starting: Task<Void, Never>?
+    @ObservationIgnored private var starting: Task<PlayReply, Never>?
     /// A new session for a seek or a track change. Work for a playback or session that has
     /// been replaced finds its task cancelled.
     @ObservationIgnored var restarting: Task<Void, Never>?
@@ -239,11 +243,33 @@
             }
             return
         }
+        begin(.file(url), at: 0)
+    }
+
+    /// Plays a video sent from the browser (spec §5.3), `startAt` seconds in, and answers once
+    /// it's ready for the TV or with why it can't play, so the browser pauses only when Paper
+    /// Plane has it. A page (YouTube) needs yt-dlp, which comes later: it leaves what's playing
+    /// alone.
+    public func play(_ request: PlayRequest) async -> PlayReply {
+        guard let input = request.input else {
+            return .failed("YouTube comes in a later version of Paper Plane.")
+        }
+        return await begin(input, at: request.startAt).value
+    }
+
+    /// Replaces whatever is playing with `input`.
+    @discardableResult
+    private func begin(_ input: ResolvedInput, at startAt: Double) -> Task<PlayReply, Never> {
+        if showsWelcome {
+            dismissWelcome()
+        }
         dismissNotice()
         stop()
-        title = ResolvedInput.file(url).title
+        title = input.title
         phase = .preparing
-        starting = Task { await start(url) }
+        let task = Task { await start(input, at: startAt) }
+        starting = task
+        return task
     }
 
     public func togglePause() {
@@ -268,7 +294,7 @@
             afterwards {
                 await withTaskGroup(of: Void.self) { group in
                     group.addTask { await stream?.stop() }
-                    group.addTask { await starting?.value }
+                    group.addTask { _ = await starting?.value }
                     group.addTask { await restarting?.value }
                     group.addTask { await extracting?.value?.remove() }
                 }
@@ -291,6 +317,8 @@
         phase = .idle
         movieTime = 0
         duration = nil
+        isLive = false
+        isWeb = false
         convertedEnd = nil
         tvWentAway = false
         userPaused = false
@@ -349,13 +377,17 @@
 
     // MARK: - Starting
 
-    private func start(_ url: URL) async {
+    /// Probes `input` and starts its first session `startAt` seconds in (at the live edge for a
+    /// live stream). Returns the browser's answer: ok once the video waits for the TV.
+    private func start(_ input: ResolvedInput, at startAt: Double) async -> PlayReply {
         do {
             let pipeline = try self.pipeline()
-            let media = try await environment.probe(pipeline, .file(url))
+            let media = try await environment.probe(pipeline, input)
             try Task.checkCancellation()
             self.media = media
             duration = media.info.duration
+            isWeb = input.inputs.contains { !$0.url.isFileURL }
+            isLive = isWeb && media.info.duration == nil
             detail = Self.detail(for: media.info)
             audioTracks = media.info.audio
             subtitleOptions = media.subtitles
@@ -367,25 +399,37 @@
             startExtractingSubtitles(media, with: pipeline)
             // Subtitles are off unless the file marks a track as forced (spec §4, step 2).
             subtitle = media.subtitles.first(where: \.isForced)?.id
-            let stream = try await environment.startStream(pipeline, media, try await request(at: 0))
+            // Not past the last second, where conversion would find nothing.
+            let start = isLive ? 0 : max(0, duration.map { min(startAt, max($0 - 1, 0)) } ?? startAt)
+            let stream = try await environment.startStream(pipeline, media, try await request(at: start))
             guard !Task.isCancelled else {
                 await stream.stop()
-                return
+                return replaced
             }
             adopt(stream)
             phase = .waitingForTV
             externalPlaybackChanged()
             networkChanged() // in case the address changed while this started
-            if let jpeg = await environment.thumbnail(pipeline.tools, url, duration), self.stream === stream {
+            // A web stream's artwork would mean fetching more from the site than playing needs.
+            if !isWeb, let url = input.inputs.first?.url,
+               let jpeg = await environment.thumbnail(pipeline.tools, url, duration), self.stream === stream {
                 artwork = NSImage(data: jpeg)
             }
+            return .ok
         } catch {
             // stop() or a newer play() took over: whatever this start ran into, it is no longer
             // this controller's business, and acting on it would stop the newer video.
-            guard !Task.isCancelled, !(error is CancellationError) else { return }
-            log.error("Couldn't play \(url.lastPathComponent, privacy: .private): \(String(describing: error), privacy: .private)")
-            fail(PlaybackError.message(for: error), error: error)
-        }
+            guard !Task.isCancelled, !(error is CancellationError) else { return replaced }
+            log.error("Couldn't play \(input.title, privacy: .private): \(String(describing: error), privacy: .private)")
+            let message = PlaybackError.message(for: error)
+            fail(message, error: error)
+            return .failed(message)
+        }
+    }
+
+    /// The answer for a start that stop() or a newer video cancelled.
+    private var replaced: PlayReply {
+        .failed(phase == .idle ? "Stopped in Paper Plane." : "Another video took its place.")
     }
 
     /// A pipeline with the current tools, address and settings.
@@ -455,7 +499,8 @@
                 convertedEnd = duration ?? convertedEnd
             case .failed(let message):
                 log.error("ffmpeg failed: \(message, privacy: .private)")
-                fail("Converting the video stopped part-way through.", error: ConversionStopped(message: message))
+                let stopped = ConversionStopped(message: message)
+                fail(PlaybackError.message(for: stopped), error: stopped)
             }
         }
     }
@@ -559,6 +604,8 @@
     /// A plain-language message for the remote.
     static func message(for error: any Error) -> String {
         switch error {
+        case _ where isSiteRefusal(error): "The site stopped the stream — click Paper Plane in your browser again."
+        case is ConversionStopped: "Converting the video stopped part-way through."
         case PlaybackError.noFFmpeg: "Paper Plane's video converter is missing. Reinstall Paper Plane."
         case PlaybackError.offline: "Your Mac isn't on a network, so the TV can't reach it. Connect to your network and try again."
         case PlanError.noVideoTrack: "This file has no video."
@@ -567,4 +614,12 @@
         default: "Something went wrong. Try again, or choose another video." // the details are in Show Log
         }
     }
+
+    /// A site refusing a web stream (spec §6), before it started or part-way through.
+    static func isSiteRefusal(_ error: any Error) -> Bool {
+        if let stopped = error as? ConversionStopped {
+            return SiteRefusal.isRefusal(stderr: stopped.message)
+        }
+        return SiteRefusal.isRefusal(error)
+    }
 }
```

```diff
--- a/core/Sources/PaperPlaneUI/PlaybackController+Sessions.swift
+++ b/core/Sources/PaperPlaneUI/PlaybackController+Sessions.swift
@@ -23,7 +23,7 @@
             audioChoices: audioChoices, audio: audio?.id, subtitleChoices: subtitleChoices, subtitle: subtitle,
             loading: loading, canShowLog: failureLog != nil, showsTVHelp: showsTVHelp,
             // From the oldest segment still on disk, as seeking measures it.
-            convertedFrom: stream.map { $0.session.offset + (segments.first?.start ?? 0) })
+            convertedFrom: stream.map { $0.session.offset + (segments.first?.start ?? 0) }, isLive: isLive)
     }
 
     // MARK: - Seeking
@@ -38,7 +38,7 @@
     /// AirPlay reports it finished (docs/sony-test-results.md, row 7b), so there is nothing to
     /// wait for.
     public func seek(toMovieTime time: Double) {
-        guard phase == .onTV, stream != nil else { return }
+        guard phase == .onTV, stream != nil, !isLive else { return }
         // Not past the last second: the end of a file is where conversion would find nothing.
         let target = max(0, duration.map { min(time, max($0 - 1, 0)) } ?? time)
         if let sessionTime = sessionTime(forMovieTime: target) {
@@ -203,12 +203,14 @@
 
     /// Keeps converting ahead of the player, rests ffmpeg when it's far enough ahead, and deletes
     /// what the player has left behind (spec §4.2). With little disk space, keeps less ahead and
-    /// says so once.
+    /// says so once. A web stream's conversion is never rested (addendum M3-16).
     func manageWindow() {
         // During a seek the old session still plays on the TV: its segments aren't behind.
         guard let stream, seekTarget == nil else { return }
         let free = freeSpace()
-        let window = SegmentWindow.forFreeSpace(free)
+        let standard = SegmentWindow.forFreeSpace(free)
+        var window = standard
+        window.pausesConversion = !isWeb
         let actions = window.actions(playhead: movieTime - stream.session.offset, segments: segments,
                                      conversionPaused: conversionPaused, conversionFinished: conversionFinished)
         for action in actions {
@@ -224,9 +226,10 @@
                 segments.removeFirst(old.count)
             }
         }
-        if window != SegmentWindow(), !warnedAboutSpace { // keeping less ahead than usual
+        if standard != SegmentWindow(), !warnedAboutSpace { // low enough to keep less ahead
             warnedAboutSpace = true
-            show(notice: "Your Mac is low on disk space, so Paper Plane converts only a few minutes ahead.")
+            show(notice: isWeb ? "Your Mac is low on disk space, so a long video may stop part-way through."
+                : "Your Mac is low on disk space, so Paper Plane converts only a few minutes ahead.")
         }
     }
 
```

```diff
--- a/core/Sources/PaperPlaneUI/RemoteState.swift
+++ b/core/Sources/PaperPlaneUI/RemoteState.swift
@@ -58,12 +58,15 @@
     /// Where the current session starts, in movie time: converted video runs from here to
     /// `converted`. nil or 0 when it starts at the beginning.
     public var convertedFrom: Double?
+    /// A live web stream (spec §5.3): "Live" in place of the scrubber, and no skipping.
+    public var isLive: Bool
 
     public init(phase: Phase = .idle, title: String = "", detail: String = "", elapsed: Double = 0,
                 duration: Double? = nil, converted: Double? = nil, volume: Double = 1, showsWelcome: Bool = false,
                 notice: String? = nil, audioChoices: [Choice] = [], audio: String? = nil,
                 subtitleChoices: [Choice] = [], subtitle: String? = nil, loading: String? = nil,
-                canShowLog: Bool = false, showsTVHelp: Bool = true, convertedFrom: Double? = nil) {
+                canShowLog: Bool = false, showsTVHelp: Bool = true, convertedFrom: Double? = nil, isLive: Bool = false) {
+        self.isLive = isLive
         self.phase = phase
         self.title = title
         self.detail = detail
@@ -88,6 +91,11 @@
         phase == .playing || phase == .paused
     }
 
+    /// Skips and the scrubber: not for a live stream.
+    public var canSeek: Bool {
+        canControlPlayback && !isLive
+    }
+
     /// Volume only reaches anything once the TV is playing.
     public var canAdjustVolume: Bool {
         canControlPlayback
```

```diff
--- a/core/Sources/PaperPlaneUI/NowPlaying.swift
+++ b/core/Sources/PaperPlaneUI/NowPlaying.swift
@@ -26,6 +26,7 @@
         var isPlaying: Bool
         var hasArtwork: Bool
         var at: Date
+        var isLive = false
 
         func differs(from next: Published) -> Bool {
             let expected = elapsed + (isPlaying ? next.at.timeIntervalSince(at) : 0)
@@ -114,7 +115,7 @@
         }
         let next = Published(title: title, duration: controller.duration, elapsed: controller.movieTime,
                              isPlaying: controller.phase == .onTV && !controller.isPaused,
-                             hasArtwork: controller.artwork != nil, at: .now)
+                             hasArtwork: controller.artwork != nil, at: .now, isLive: controller.isLive)
         guard published.map({ $0.differs(from: next) }) ?? true else { return }
         published = next
         center.nowPlayingInfo = Self.info(next, artwork: controller.artwork)
@@ -131,6 +132,9 @@
         if let duration = state.duration {
             info[MPMediaItemPropertyPlaybackDuration] = duration
         }
+        if state.isLive {
+            info[MPNowPlayingInfoPropertyIsLiveStream] = true
+        }
         if let artwork {
             info[MPMediaItemPropertyArtwork] = Self.artwork(artwork)
         }
```

```diff
--- a/core/Sources/PaperPlaneUI/RemoteView.swift
+++ b/core/Sources/PaperPlaneUI/RemoteView.swift
@@ -244,8 +244,12 @@
                 if case .choosingTV = state.phase, state.showsTVHelp {
                     chooseTVCallout
                 }
-                Scrubber(state: state, seek: actions.seek, skip: actions.skip)
-                    .disabled(!state.canControlPlayback)
+                if state.isLive {
+                    LiveIndicator()
+                } else {
+                    Scrubber(state: state, seek: actions.seek, skip: actions.skip)
+                        .disabled(!state.canControlPlayback)
+                }
                 transport
                 volume
             }
@@ -318,14 +322,14 @@
         }
         .overlay {
             HStack(spacing: 20) {
-                TransportButton(symbol: "gobackward.10", label: "Back 10 seconds", enabled: state.canControlPlayback) {
+                TransportButton(symbol: "gobackward.10", label: "Back 10 seconds", enabled: state.canSeek) {
                     actions.skip(-10)
                 }
                 .keyboardShortcut(.leftArrow, modifiers: [])
                 PlayButton(isPlaying: state.phase == .playing, label: state.playButtonLabel,
                            enabled: state.canControlPlayback, action: actions.togglePlay)
                     .keyboardShortcut(.space, modifiers: [])
-                TransportButton(symbol: "goforward.10", label: "Forward 10 seconds", enabled: state.canControlPlayback) {
+                TransportButton(symbol: "goforward.10", label: "Forward 10 seconds", enabled: state.canSeek) {
                     actions.skip(10)
                 }
                 .keyboardShortcut(.rightArrow, modifiers: [])
@@ -574,6 +578,25 @@
 }
 
 // MARK: - Scrubber
+
+/// In place of the scrubber for a live stream, which has nothing to seek in (spec §5.3). As tall
+/// as the scrubber, so the controls below stay put.
+struct LiveIndicator: View {
+    var body: some View {
+        HStack(spacing: 6) {
+            Circle()
+                .fill(.red)
+                .frame(width: 8, height: 8)
+            Text("Live")
+                .font(.caption.weight(.semibold))
+                .foregroundStyle(.secondary)
+            Spacer(minLength: 0)
+        }
+        .frame(height: 34)
+        .accessibilityElement(children: .ignore)
+        .accessibilityLabel("Live stream")
+    }
+}
 
 /// Elapsed time, a track showing what's been played and what's ready, and the time left.
 /// Drag or click to seek; VoiceOver adjusts it in 10-second steps.
```

- [ ] **Step 4: Run the tests and draw the renders**

Run: `scripts/test-core.sh`
Expected: PASS, every suite.
Run: `scripts/render-ui.sh`
Expected: "Rendered 30 images into docs/design/", including `remote-live-light.png` and `remote-live-dark.png`.

- [ ] **Step 5: Commit**

```bash
git add core/Sources/PaperPlaneUI core/Tests/PaperPlaneUITests docs/design/remote-live-*.png
git commit -m "feat(ui): play a browser's video and answer once it's ready for the TV; live streams"
```

### Task 8: The helper in the app bundle, and the app listening

**Files:**
- Create: `app/PaperPlaneHost/main.swift`, `scripts/check-bridge.sh`
- Modify: `app/PaperPlane.xcodeproj/project.pbxproj`, `app/PaperPlane/PaperPlaneApp.swift`, `scripts/embed-ffmpeg.sh`, `scripts/check-quit-cleanup.sh`

**Interfaces:**
- Consumes: `BridgeServer`, `HostRelay`, `BrowserHosts` (Tasks 3–4), `PlaybackController.play(_:)` (Task 7).
- Produces:
  - The `paperplane-host` target, embedded at `Paper Plane.app/Contents/Helpers/paperplane-host`.
  - The app installs the browser manifests unless launched with `-PaperPlaneInstallsBrowserHosts NO`, listens on the standard socket, and stops listening on quit.

- [ ] **Step 1: Write the helper**

```swift
import Foundation
import PaperPlaneCore

// Chrome and Brave start this for each message from the extension (spec §5.2): one framed
// request on stdin, relayed to the app's socket, and the app's framed reply on stdout. Only the
// Paper Plane extension may start it (its manifest's allowed_origins), and only this user can
// reach the socket.
let reply: Data
if let request = HostRelay.readRequest(from: .standardInput) {
    let helper = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    reply = HostRelay.relay(request, socket: BridgeServer.standardSocket, startApp: {
        if let app = HostRelay.app(containing: helper.resolvingSymlinksInPath()) {
            HostRelay.open(app)
        }
    })
} else {
    reply = PlayReply.failed("Paper Plane couldn't read the request.").encoded()
}
FileHandle.standardOutput.write(NativeMessaging.frame(reply))
```

- [ ] **Step 2: Add its target to the project, embedded by a Copy Files phase (Wrapper, `Contents/Helpers`, code sign on copy) that the app target depends on**

```diff
--- a/app/PaperPlane.xcodeproj/project.pbxproj
+++ b/app/PaperPlane.xcodeproj/project.pbxproj
@@ -9,11 +9,38 @@
 /* Begin PBXBuildFile section */
 		5050504C0000000000000101 /* PaperPlaneCore in Frameworks */ = {isa = PBXBuildFile; productRef = 5050504C0000000000000102 /* PaperPlaneCore */; };
 		5050504C0000000000000104 /* PaperPlaneUI in Frameworks */ = {isa = PBXBuildFile; productRef = 5050504C0000000000000105 /* PaperPlaneUI */; };
+		5050504C0000000000000205 /* PaperPlaneCore in Frameworks */ = {isa = PBXBuildFile; productRef = 5050504C0000000000000206 /* PaperPlaneCore */; };
+		5050504C000000000000020D /* paperplane-host in Embed Helper */ = {isa = PBXBuildFile; fileRef = 5050504C0000000000000200 /* paperplane-host */; settings = {ATTRIBUTES = (CodeSignOnCopy, ); }; };
 /* End PBXBuildFile section */
+
+/* Begin PBXContainerItemProxy section */
+		5050504C000000000000020A /* PBXContainerItemProxy */ = {
+			isa = PBXContainerItemProxy;
+			containerPortal = 5050504C0000000000000000 /* Project object */;
+			proxyType = 1;
+			remoteGlobalIDString = 5050504C0000000000000202;
+			remoteInfo = "paperplane-host";
+		};
+/* End PBXContainerItemProxy section */
+
+/* Begin PBXCopyFilesBuildPhase section */
+		5050504C000000000000020C /* Embed Helper */ = {
+			isa = PBXCopyFilesBuildPhase;
+			buildActionMask = 2147483647;
+			dstPath = Contents/Helpers;
+			dstSubfolderSpec = 1;
+			files = (
+				5050504C000000000000020D /* paperplane-host in Embed Helper */,
+			);
+			name = "Embed Helper";
+			runOnlyForDeploymentPostprocessing = 0;
+		};
+/* End PBXCopyFilesBuildPhase section */
 
 /* Begin PBXFileReference section */
 		5050504C0000000000000002 /* Paper Plane.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "Paper Plane.app"; sourceTree = BUILT_PRODUCTS_DIR; };
 		5050504C0000000000000004 /* PaperPlane-Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "PaperPlane-Info.plist"; sourceTree = "<group>"; };
+		5050504C0000000000000200 /* paperplane-host */ = {isa = PBXFileReference; explicitFileType = "compiled.mach-o.executable"; includeInIndex = 0; path = "paperplane-host"; sourceTree = BUILT_PRODUCTS_DIR; };
 /* End PBXFileReference section */
 
 /* Begin PBXFileSystemSynchronizedRootGroup section */
@@ -22,6 +49,11 @@
 			path = PaperPlane;
 			sourceTree = "<group>";
 		};
+		5050504C0000000000000201 /* PaperPlaneHost */ = {
+			isa = PBXFileSystemSynchronizedRootGroup;
+			path = PaperPlaneHost;
+			sourceTree = "<group>";
+		};
 /* End PBXFileSystemSynchronizedRootGroup section */
 
 /* Begin PBXFrameworksBuildPhase section */
@@ -31,6 +63,14 @@
 			files = (
 				5050504C0000000000000101 /* PaperPlaneCore in Frameworks */,
 				5050504C0000000000000104 /* PaperPlaneUI in Frameworks */,
+			);
+			runOnlyForDeploymentPostprocessing = 0;
+		};
+		5050504C0000000000000204 /* Frameworks */ = {
+			isa = PBXFrameworksBuildPhase;
+			buildActionMask = 2147483647;
+			files = (
+				5050504C0000000000000205 /* PaperPlaneCore in Frameworks */,
 			);
 			runOnlyForDeploymentPostprocessing = 0;
 		};
@@ -41,6 +81,7 @@
 			isa = PBXGroup;
 			children = (
 				5050504C0000000000000003 /* PaperPlane */,
+				5050504C0000000000000201 /* PaperPlaneHost */,
 				5050504C0000000000000004 /* PaperPlane-Info.plist */,
 				5050504C0000000000000005 /* Products */,
 			);
@@ -50,6 +91,7 @@
 			isa = PBXGroup;
 			children = (
 				5050504C0000000000000002 /* Paper Plane.app */,
+				5050504C0000000000000200 /* paperplane-host */,
 			);
 			name = Products;
 			sourceTree = "<group>";
@@ -64,11 +106,13 @@
 				5050504C0000000000000011 /* Sources */,
 				5050504C0000000000000012 /* Frameworks */,
 				5050504C0000000000000013 /* Resources */,
+				5050504C000000000000020C /* Embed Helper */,
 				5050504C0000000000000014 /* Embed ffmpeg */,
 			);
 			buildRules = (
 			);
 			dependencies = (
+				5050504C000000000000020B /* PBXTargetDependency */,
 			);
 			fileSystemSynchronizedGroups = (
 				5050504C0000000000000003 /* PaperPlane */,
@@ -81,6 +125,28 @@
 			productName = PaperPlane;
 			productReference = 5050504C0000000000000002 /* Paper Plane.app */;
 			productType = "com.apple.product-type.application";
+		};
+		5050504C0000000000000202 /* paperplane-host */ = {
+			isa = PBXNativeTarget;
+			buildConfigurationList = 5050504C0000000000000207 /* Build configuration list for PBXNativeTarget "paperplane-host" */;
+			buildPhases = (
+				5050504C0000000000000203 /* Sources */,
+				5050504C0000000000000204 /* Frameworks */,
+			);
+			buildRules = (
+			);
+			dependencies = (
+			);
+			fileSystemSynchronizedGroups = (
+				5050504C0000000000000201 /* PaperPlaneHost */,
+			);
+			name = "paperplane-host";
+			packageProductDependencies = (
+				5050504C0000000000000206 /* PaperPlaneCore */,
+			);
+			productName = "paperplane-host";
+			productReference = 5050504C0000000000000200 /* paperplane-host */;
+			productType = "com.apple.product-type.tool";
 		};
 /* End PBXNativeTarget section */
 
@@ -110,6 +176,7 @@
 			projectRoot = "";
 			targets = (
 				5050504C0000000000000010 /* PaperPlane */,
+				5050504C0000000000000202 /* paperplane-host */,
 			);
 		};
 /* End PBXProject section */
@@ -154,7 +221,22 @@
 			);
 			runOnlyForDeploymentPostprocessing = 0;
 		};
+		5050504C0000000000000203 /* Sources */ = {
+			isa = PBXSourcesBuildPhase;
+			buildActionMask = 2147483647;
+			files = (
+			);
+			runOnlyForDeploymentPostprocessing = 0;
+		};
 /* End PBXSourcesBuildPhase section */
+
+/* Begin PBXTargetDependency section */
+		5050504C000000000000020B /* PBXTargetDependency */ = {
+			isa = PBXTargetDependency;
+			target = 5050504C0000000000000202 /* paperplane-host */;
+			targetProxy = 5050504C000000000000020A /* PBXContainerItemProxy */;
+		};
+/* End PBXTargetDependency section */
 
 /* Begin XCBuildConfiguration section */
 		5050504C0000000000000021 /* Debug */ = {
@@ -229,6 +311,26 @@
 			};
 			name = Release;
 		};
+		5050504C0000000000000208 /* Debug */ = {
+			isa = XCBuildConfiguration;
+			buildSettings = {
+				CODE_SIGN_IDENTITY = "-";
+				CODE_SIGN_STYLE = Manual;
+				PRODUCT_NAME = "paperplane-host";
+				SKIP_INSTALL = YES;
+			};
+			name = Debug;
+		};
+		5050504C0000000000000209 /* Release */ = {
+			isa = XCBuildConfiguration;
+			buildSettings = {
+				CODE_SIGN_IDENTITY = "-";
+				CODE_SIGN_STYLE = Manual;
+				PRODUCT_NAME = "paperplane-host";
+				SKIP_INSTALL = YES;
+			};
+			name = Release;
+		};
 /* End XCBuildConfiguration section */
 
 /* Begin XCConfigurationList section */
@@ -250,6 +352,15 @@
 			defaultConfigurationIsVisible = 0;
 			defaultConfigurationName = Release;
 		};
+		5050504C0000000000000207 /* Build configuration list for PBXNativeTarget "paperplane-host" */ = {
+			isa = XCConfigurationList;
+			buildConfigurations = (
+				5050504C0000000000000208 /* Debug */,
+				5050504C0000000000000209 /* Release */,
+			);
+			defaultConfigurationIsVisible = 0;
+			defaultConfigurationName = Release;
+		};
 /* End XCConfigurationList section */
 
 /* Begin XCLocalSwiftPackageReference section */
@@ -268,6 +379,10 @@
 			isa = XCSwiftPackageProductDependency;
 			productName = PaperPlaneUI;
 		};
+		5050504C0000000000000206 /* PaperPlaneCore */ = {
+			isa = XCSwiftPackageProductDependency;
+			productName = PaperPlaneCore;
+		};
 /* End XCSwiftPackageProductDependency section */
 	};
 	rootObject = 5050504C0000000000000000 /* Project object */;
```

- [ ] **Step 3: Keep the helper when Debug builds have no bundled ffmpeg**

```diff
--- a/scripts/embed-ffmpeg.sh
+++ b/scripts/embed-ffmpeg.sh
@@ -11,7 +11,7 @@
     exit 1
   fi
   echo "warning: vendor/ffmpeg/bin is missing, so this build uses Homebrew's ffmpeg. Run scripts/build-ffmpeg.sh."
-  rm -rf "$DEST"
+  rm -f "$DEST/ffmpeg" "$DEST/ffprobe" # the browser helper lives there too
   exit 0
 fi
 mkdir -p "$DEST"
```

- [ ] **Step 4: The app installs the manifests and listens**

```diff
--- a/app/PaperPlane/PaperPlaneApp.swift
+++ b/app/PaperPlane/PaperPlaneApp.swift
@@ -1,5 +1,6 @@
 import AppKit
 import Network
+import os
 import PaperPlaneCore
 import PaperPlaneUI
 import UniformTypeIdentifiers
@@ -19,6 +20,9 @@
     private enum Key {
         static let welcomeShown = "didShowWelcome"
         static let tvChosen = "didChooseTV"
+        /// Automated checks launch with `-PaperPlaneInstallsBrowserHosts NO`, leaving the
+        /// browsers' folders alone.
+        static let installsBrowserHosts = "PaperPlaneInstallsBrowserHosts"
     }
 
     #if DEBUG
@@ -43,6 +47,8 @@
     private var statusItem: StatusItem?
     private var nowPlaying: NowPlaying?
     private let network = NWPathMonitor()
+    private var bridge: BridgeServer?
+    private let log = Logger(subsystem: "dev.paperplane.app", category: "app")
 
     func applicationDidFinishLaunching(_ notification: Notification) {
         // Whatever a crash left behind (spec §4.2).
@@ -59,7 +65,47 @@
             Task { @MainActor in self?.controller.networkChanged() }
         }
         network.start(queue: .main)
+        installBrowserHosts()
+        startBridge()
         remote.show()
+    }
+
+    // MARK: - The browser
+
+    /// Lets Chrome and Brave start the helper (spec §5.2), on every launch in case the app moved.
+    private func installBrowserHosts() {
+        let defaults = UserDefaults.standard
+        guard defaults.object(forKey: Key.installsBrowserHosts) == nil || defaults.bool(forKey: Key.installsBrowserHosts)
+        else { return }
+        let host = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/paperplane-host")
+        guard FileManager.default.isExecutableFile(atPath: host.path) else { return }
+        do {
+            try BrowserHosts.install(host: host, applicationSupport: BrowserHosts.standardApplicationSupport)
+        } catch {
+            log.error("Couldn't install the browser helper: \(String(describing: error), privacy: .public)")
+        }
+    }
+
+    /// Listens for videos sent from the extension through the helper.
+    private func startBridge() {
+        Task { [weak self] in
+            do {
+                let bridge = try await BridgeServer.start(at: BridgeServer.standardSocket) { [weak self] request in
+                    await self?.play(request) ?? .failed("Paper Plane is quitting.")
+                }
+                self?.bridge = bridge
+            } catch {
+                self?.log.error("Couldn't listen for the browser: \(String(describing: error), privacy: .public)")
+            }
+        }
+    }
+
+    /// A video from the browser: the remote comes forward to choose the TV, as for a file.
+    private func play(_ request: PlayRequest) async -> PlayReply {
+        if request.input != nil {
+            remote.show()
+        }
+        return await controller.play(request)
     }
 
     /// Finder's Open With, and files dropped on the app's icon.
@@ -68,8 +114,9 @@
     }
 
     func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
-        // ffmpeg must not outlive the app.
+        // ffmpeg must not outlive the app, and the helper must find no socket.
         network.cancel()
+        bridge?.stop()
         Task {
             await controller.shutDown()
             sender.reply(toApplicationShouldTerminate: true)
```

- [ ] **Step 5: Automated checks leave the browsers' folders alone, and check the bridge end to end**

```diff
--- a/scripts/check-quit-cleanup.sh
+++ b/scripts/check-quit-cleanup.sh
@@ -18,7 +18,7 @@
 
 leftovers=0
 launch() {
-  open "$APP"
+  open "$APP" --args -PaperPlaneInstallsBrowserHosts NO # leave Chrome's and Brave's folders alone
   until pgrep -f "Paper Plane.app/Contents/MacOS" >/dev/null; do sleep 0.1; done
   sleep 1
 }
```

```bash
#!/bin/bash
# Checks the browser bridge end to end, without a browser or a TV: it sends play requests through
# the app's own paperplane-host, as Chrome would, and checks the replies.
#   1. With the app running: a stream that plays, and one the site refuses.
#   2. With the app quit: the helper starts it, then relays the request.
#   3. After quitting: no socket, no ffmpeg and no session folder left behind.
# The app shows its window while this runs. It leaves Chrome's and Brave's folders alone.
# Usage: scripts/check-bridge.sh [path to Paper Plane.app]
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
APP="${1:-$PWD/build/DerivedData/Build/Products/Debug/Paper Plane.app}"
HOST="$APP/Contents/Helpers/paperplane-host"
SOCKET="$HOME/Library/Application Support/Paper Plane/bridge.sock"
SESSIONS="$HOME/Library/Caches/Paper Plane/sessions"
[[ -x "$HOST" ]] || { echo "No helper at $HOST. Build the app first (see README)." >&2; exit 2; }

# The helper starts the app without arguments, so the setting goes in its defaults for the run.
had_setting="$(defaults read dev.paperplane.app PaperPlaneInstallsBrowserHosts 2>/dev/null || true)"
defaults write dev.paperplane.app PaperPlaneInstallsBrowserHosts -bool NO
restore() {
  if [[ -z "$had_setting" ]]; then
    defaults delete dev.paperplane.app PaperPlaneInstallsBrowserHosts 2>/dev/null
  else
    defaults write dev.paperplane.app PaperPlaneInstallsBrowserHosts -bool "$had_setting"
  fi
  [[ -n "${server:-}" ]] && kill "$server" 2>/dev/null
  rm -f "$portfile"
}
trap restore EXIT

# A local "site": testdata/media over HTTP (see serve-hls.py for its /cookie/ and /status/ paths).
portfile="$(mktemp "${TMPDIR%/}/paperplane-bridge-check.XXXXXX")"
python3 scripts/serve-hls.py testdata/media > "$portfile" &
server=$!
disown "$server" # stopped at the end without a "Terminated" line
until [[ -s "$portfile" ]]; do sleep 0.1; done
port="$(cut -d ' ' -f 2 "$portfile")"

# Sends one request through the helper and prints the reply's JSON.
send() {
  python3 - "$HOST" "$1" <<'PY'
import json, struct, subprocess, sys
host, url = sys.argv[1], sys.argv[2]
message = json.dumps({"type": "play", "v": 1, "title": "Bridge check", "startAt": 2,
                      "source": {"kind": "stream", "url": url, "format": "progressive",
                                 "headers": {"Cookie": "pp=1"}}}).encode()
out = subprocess.run([host, "chrome-extension://napcmmglefncoieikecpjmdopmagllcg/"],
                     input=struct.pack("<I", len(message)) + message, capture_output=True, timeout=60).stdout
length = struct.unpack("<I", out[:4])[0] if len(out) >= 4 else 0
print(out[4:4 + length].decode() or "(no reply)")
PY
}
quit_app() {
  osascript -e 'tell application id "dev.paperplane.app" to quit' >/dev/null 2>&1
  while pgrep -f "Paper Plane.app/Contents/MacOS" >/dev/null; do sleep 0.1; done
}

failures=0
expect() { # name, expected, actual
  if [[ "$3" == "$2" ]]; then echo "ok: $1"; else echo "FAIL: $1 — expected $2, got $3"; failures=1; fi
}

quit_app
open "$APP" --args -PaperPlaneInstallsBrowserHosts NO
until [[ -S "$SOCKET" ]]; do sleep 0.1; done
expect "a stream plays" '{"ok":true}' "$(send "http://127.0.0.1:$port/cookie/pp=1/h264_aac.mp4")"
expect "a refused stream says so" \
  '{"error":"The site stopped the stream — click Paper Plane in your browser again.","ok":false}' \
  "$(send "http://127.0.0.1:$port/status/403/h264_aac.mp4")"

quit_app
expect "quitting removes the socket" "gone" "$([[ -e "$SOCKET" ]] && echo there || echo gone)"
expect "the helper starts the app" '{"ok":true}' "$(send "http://127.0.0.1:$port/cookie/pp=1/h264_aac.mp4")"

quit_app
sleep 0.5
expect "no ffmpeg left" "0" "$(pgrep -f 'Helpers/ffmpeg' | wc -l | tr -d ' ')"
expect "no session folder left" "0" "$(find "$SESSIONS" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
exit $failures
```

- [ ] **Step 6: Build and check**

Run: `xcodebuild -project app/PaperPlane.xcodeproj -scheme PaperPlane -configuration Debug -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES build`
Expected: BUILD SUCCEEDED; `build/DerivedData/Build/Products/Debug/Paper Plane.app/Contents/Helpers/` holds `ffmpeg`, `ffprobe` and `paperplane-host`.
Run: `scripts/check-bridge.sh`
Expected: six "ok:" lines (a stream plays; a refused stream says so; quitting removes the socket; the helper starts the app; no ffmpeg left; no session folder left).

- [ ] **Step 7: Commit**

```bash
git add app/PaperPlaneHost app/PaperPlane.xcodeproj/project.pbxproj app/PaperPlane/PaperPlaneApp.swift scripts/embed-ffmpeg.sh scripts/check-quit-cleanup.sh scripts/check-bridge.sh
git commit -m "feat(app): paperplane-host in the bundle, browser manifests, and the app listening for the browser"
```

### Task 9: The extension's logic — classifying, ranking, tab state, messages, the button

**Files:**
- Create: `extension/package.json`, `extension/package-lock.json` (by npm), `extension/tsconfig.json`, `extension/src/classify.ts`, `detector.ts`, `tabs.ts`, `message.ts`, `view.ts`, `videos.ts`
- Test: `extension/test/fixtures.ts`, `classify.test.ts`, `detector.test.ts`, `tabs.test.ts`, `message.test.ts`, `view.test.ts`, `videos.test.ts`

**Interfaces:**
- Produces:
  - Classifying: `classify(url, contentType, requestType) -> "hls" | "dash" | "progressive" | "segment" | undefined`.
  - Ranking: `Candidate`, `FrameVideo`, `weights`, `score`, `rank`, `choose -> {none} | {one} | {several}`.
  - Tab state: `TabState`, `newTab`, `pickHeaders`, `navigated`, `withVideos`, `observe`, `maximumCandidates`.
  - Messages: `hostName`, `streamMessage`, `pageMessage`, `isYouTubeVideo`, `startTime`, `tidyTitle`, `failureText`.
  - The button: `plan -> {none} | {send} | {choose}`, `button -> ButtonView`, `rows -> Row[]`, `PopupState`, `clock`.
  - Videos: `describeVideo`, `videosFrom`.

- [ ] **Step 1: The project and its pinned dev tools**

```json
{
  "name": "paper-plane-extension",
  "version": "0.1.0",
  "private": true,
  "description": "Finds the video in a Chrome or Brave tab and sends it to Paper Plane for Mac.",
  "license": "GPL-3.0-or-later",
  "type": "module",
  "scripts": {
    "build": "node build.mjs",
    "test": "vitest run",
    "typecheck": "tsc --noEmit"
  },
  "devDependencies": {
    "@types/chrome": "0.3.4",
    "esbuild": "0.28.2",
    "typescript": "6.0.3",
    "vitest": "5.0.3"
  }
}
```

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "lib": ["ES2022", "DOM"],
    "types": ["chrome"],
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "noImplicitOverride": true,
    "noFallthroughCasesInSwitch": true,
    "isolatedModules": true,
    "skipLibCheck": true,
    "noEmit": true
  },
  "include": ["src", "test"]
}
```

Run: `cd extension && npm install --ignore-scripts --no-audit --no-fund`
Expected: "added 43 packages"; writes `package-lock.json`.

- [ ] **Step 2: Write the failing tests and their fixtures**

```typescript
// Request sequences shaped like real sites' (spec §7): what webRequest reports as a page plays,
// and what the content scripts report about each frame's videos.
import type { FrameVideo } from "../src/detector";
import { newTab, observe, withVideos, type Response, type TabState } from "../src/tabs";

/** A response webRequest reported at `at` milliseconds. */
export function seen(url: string, at: number, options: Partial<Response> = {}): Response {
  return { url, frameId: 0, type: "xmlhttprequest", timeStamp: at, statusCode: 200, headers: {}, ...options };
}

/** `count` segments named `<prefix>1.ts`, `<prefix>2.ts`, … two seconds apart from `from`. */
export function segments(prefix: string, from: number, count: number, options: Partial<Response> = {}): Response[] {
  return Array.from({ length: count }, (_, index) =>
    seen(`${prefix}${index + 1}.ts`, from + index * 2000, { contentType: "video/mp2t", ...options }));
}

export type Videos = Record<number, Omit<FrameVideo, "frameId">[]>;

export function replay(responses: Response[], videos: Videos = {}): TabState {
  let tab = responses.reduce(observe, newTab());
  for (const [frame, list] of Object.entries(videos)) {
    tab = withVideos(tab, Number(frame), list);
  }
  return tab;
}

/** A news article: a 15-second preroll ad as a file in an ad frame, then the story's video as
 *  HLS (a master, two variants, segments) in the player's frame. */
export const newsSiteWithAnAd = {
  responses: [
    seen("https://ads.example/creative/preroll-15s.mp4", 1000, { type: "media", frameId: 7, contentType: "video/mp4" }),
    seen("https://ads.example/creative/preroll-15s.mp4", 1500, { type: "media", frameId: 7, contentType: "video/mp4", statusCode: 206 }),
    seen("https://video.news.example/hls/story/master.m3u8", 17000, { frameId: 3, contentType: "application/vnd.apple.mpegurl" }),
    seen("https://video.news.example/hls/story/720p/index.m3u8", 17200, { frameId: 3 }),
    seen("https://video.news.example/hls/story/360p/index.m3u8", 17250, { frameId: 3 }),
    ...segments("https://video.news.example/hls/story/720p/seg", 17500, 20, { frameId: 3 }),
  ],
  videos: {
    7: [{ src: "https://ads.example/creative/preroll-15s.mp4", playing: false, currentTime: 15, duration: 15 }],
    3: [{ src: "blob:https://www.news.example/1f2e", playing: true, currentTime: 40, duration: 184 }],
  } satisfies Videos,
  now: 60000,
};

/** A landing page: a muted 8-second background loop as a file in the top frame, and the main
 *  video as HLS in an embedded player, both playing. */
export const backgroundLoopAndAFilm = {
  responses: [
    seen("https://www.studio.example/media/hero-loop.mp4", 500, { type: "media", contentType: "video/mp4" }),
    seen("https://www.studio.example/media/hero-loop.mp4", 8500, { type: "media", contentType: "video/mp4", statusCode: 206 }),
    seen("https://player.example/v/9876/hls.m3u8", 20000, { frameId: 2 }),
    ...segments("https://player.example/v/9876/s", 20500, 10, { frameId: 2 }),
    seen("https://www.studio.example/media/hero-loop.mp4", 39000, { type: "media", contentType: "video/mp4", statusCode: 206 }),
  ],
  videos: {
    0: [{ src: "https://www.studio.example/media/hero-loop.mp4", playing: true, currentTime: 3, duration: 8 }],
    2: [{ src: "blob:https://player.example/77", playing: true, currentTime: 18, duration: 5400 }],
  } satisfies Videos,
  now: 40000,
};

/** A plain video file the page's own <video> plays, fetched in ranges. */
export const aVideoFile = {
  responses: [
    seen("https://media.example/talks/keynote.mp4", 1000, { type: "media", contentType: "video/mp4", statusCode: 206 }),
    seen("https://media.example/talks/keynote.mp4", 9000, { type: "media", contentType: "video/mp4", statusCode: 206 }),
  ],
  videos: { 0: [{ src: "https://media.example/talks/keynote.mp4", playing: true, currentTime: 61.5, duration: 3600 }] } satisfies Videos,
  now: 10000,
};

/** DASH: a manifest, then audio and video segments. */
export const aDashSite = {
  responses: [
    seen("https://dash.example/content/abc/manifest.mpd", 1000, { contentType: "application/dash+xml" }),
    seen("https://dash.example/content/abc/video/init.mp4", 1200, { contentType: "video/mp4" }),
    seen("https://dash.example/content/abc/video/seg-1.m4s", 1400),
    seen("https://dash.example/content/abc/audio/seg-1.m4s", 1450),
  ],
  videos: { 0: [{ src: "blob:https://dash.example/12", playing: true, currentTime: 2, duration: 1200 }] } satisfies Videos,
  now: 5000,
};

/** Two players on one page, both playing: Paper Plane can't know which one is meant. */
export const twoPlayers = {
  responses: [
    seen("https://a.example/one/index.m3u8", 1000, { frameId: 1 }),
    ...segments("https://a.example/one/s", 1500, 3, { frameId: 1 }),
    seen("https://b.example/two/index.m3u8", 1200, { frameId: 2 }),
    ...segments("https://b.example/two/s", 1700, 3, { frameId: 2 }),
  ],
  videos: {
    1: [{ src: "blob:https://a.example/1", playing: true, currentTime: 5, duration: 600 }],
    2: [{ src: "blob:https://b.example/2", playing: true, currentTime: 5, duration: 600 }],
  } satisfies Videos,
  now: 8000,
};
```

```typescript
import { describe, expect, it } from "vitest";
import { classify } from "../src/classify";

describe("classify", () => {
  it.each([
    ["https://cdn.example/v/master.m3u8?token=1", undefined, "xmlhttprequest", "hls"],
    ["https://cdn.example/v/playlist", "application/vnd.apple.mpegURL", "xmlhttprequest", "hls"],
    ["https://cdn.example/v/playlist", "application/x-mpegurl; charset=utf-8", "xmlhttprequest", "hls"],
    ["https://cdn.example/v/index.m3u8", "text/plain", "media", "hls"],
    ["https://cdn.example/v/manifest.mpd", undefined, "xmlhttprequest", "dash"],
    ["https://cdn.example/v/manifest", "application/dash+xml", "other", "dash"],
    ["https://media.example/film.mp4", "video/mp4", "media", "progressive"],
    ["https://media.example/film.webm", undefined, "media", "progressive"],
    ["https://media.example/clip.MOV", "application/octet-stream", "media", "progressive"],
    ["https://cdn.example/v/seg-001.ts", "video/mp2t", "xmlhttprequest", "segment"],
    ["https://cdn.example/v/chunk-5.m4s", undefined, "xmlhttprequest", "segment"],
    // A player fetching pieces of a video itself: a segment, not a video to send.
    ["https://cdn.example/v/video-720p-12.mp4", "video/mp4", "xmlhttprequest", "segment"],
    ["https://example.com/api/next", "application/json", "xmlhttprequest", undefined],
    ["https://example.com/logo.png", "image/png", "other", undefined],
    ["https://example.com/watch?file=film.mp4", "text/html", "xmlhttprequest", undefined],
  ] as const)("%s (%s, %s) is %s", (url, type, request, kind) => {
    expect(classify(url, type, request)).toBe(kind);
  });
});
```

```typescript
import { describe, expect, it } from "vitest";
import { choose, rank, score, weights } from "../src/detector";
import { aDashSite, aVideoFile, backgroundLoopAndAFilm, newsSiteWithAnAd, replay, seen, segments, twoPlayers } from "./fixtures";

function chosen(fixture: { responses: Parameters<typeof replay>[0]; videos: Parameters<typeof replay>[1]; now: number }) {
  const tab = replay(fixture.responses, fixture.videos);
  return choose(tab.candidates, tab.videos, fixture.now);
}

describe("StreamDetector", () => {
  it("prefers the story's stream over the ad that played before it", () => {
    const choice = chosen(newsSiteWithAnAd);
    expect(choice.kind).toBe("one");
    expect(choice.kind === "one" && choice.candidate.url).toBe("https://video.news.example/hls/story/master.m3u8");
  });

  it("offers the master playlist, not its variants", () => {
    const tab = replay(newsSiteWithAnAd.responses, newsSiteWithAnAd.videos);
    expect(rank(tab.candidates, tab.videos, newsSiteWithAnAd.now).map((c) => c.url)).toEqual([
      "https://video.news.example/hls/story/master.m3u8",
      "https://ads.example/creative/preroll-15s.mp4",
    ]);
  });

  it("prefers the film over a short background loop", () => {
    const choice = chosen(backgroundLoopAndAFilm);
    expect(choice.kind === "one" && choice.candidate.url).toBe("https://player.example/v/9876/hls.m3u8");
  });

  it("finds a plain video file", () => {
    const choice = chosen(aVideoFile);
    expect(choice.kind === "one" && choice.candidate.format).toBe("progressive");
  });

  it("finds DASH, with its segments counting as activity", () => {
    const choice = chosen(aDashSite);
    expect(choice.kind === "one" && choice.candidate.format).toBe("dash");
    const tab = replay(aDashSite.responses, aDashSite.videos);
    expect(tab.candidates).toHaveLength(1);
  });

  it("asks when two players are equally likely", () => {
    const choice = chosen(twoPlayers);
    expect(choice.kind).toBe("several");
    expect(choice.kind === "several" && choice.ranked).toHaveLength(2);
  });

  it("finds nothing among API calls, images and refused requests", () => {
    const tab = replay([
      seen("https://example.com/api/feed", 100, { contentType: "application/json" }),
      seen("https://example.com/img/logo.png", 120, { type: "other", contentType: "image/png" }),
      seen("https://cdn.example/v/master.m3u8", 140, { statusCode: 403 }),
    ]);
    expect(choose(tab.candidates, tab.videos, 1000)).toEqual({ kind: "none" });
  });

  it("weighs the criteria in the spec's order, each above all those after it", () => {
    const ordered = [weights.playing, weights.activity, weights.master, weights.videoSrc, weights.long];
    ordered.forEach((weight, index) => {
      const rest = ordered.slice(index + 1).reduce((sum, next) => sum + next, 0);
      expect(weight).toBeGreaterThan(rest);
    });
  });

  it("stops counting activity that has gone quiet", () => {
    const tab = replay([seen("https://cdn.example/v/index.m3u8", 0), ...segments("https://cdn.example/v/s", 500, 2)]);
    const candidate = tab.candidates[0]!;
    expect(score(candidate, [], 3000)).toBe(weights.activity + weights.master);
    expect(score(candidate, [], 60000)).toBe(weights.master);
  });

  it("credits a worker's requests (no frame) to whichever frame is playing", () => {
    const tab = replay([seen("https://cdn.example/v/index.m3u8", 0, { frameId: -1 })],
      { 4: [{ src: "blob:https://site.example/1", playing: true, currentTime: 1, duration: 90 }] });
    expect(score(tab.candidates[0]!, tab.videos, 1000)).toBe(weights.playing + weights.master + weights.long);
  });
});
```

```typescript
import { describe, expect, it } from "vitest";
import { maximumCandidates, navigated, newTab, observe, pickHeaders, withVideos } from "../src/tabs";
import { replay, seen } from "./fixtures";

describe("tab state", () => {
  it("keeps only the headers a site needs to hand over the video", () => {
    expect(pickHeaders([
      { name: "cookie", value: "session=1" },
      { name: "Referer", value: "https://site.example/watch" },
      { name: "Origin", value: "https://site.example" },
      { name: "User-Agent", value: "Mozilla/5.0" },
      { name: "Authorization", value: "Bearer secret" },
      { name: "X-Client-Data", value: "abc" },
      { name: "Accept" },
    ])).toEqual({ Cookie: "session=1", Referer: "https://site.example/watch", Origin: "https://site.example", "User-Agent": "Mozilla/5.0" });
  });

  it("follows a playlist whose link changes, keeping the newest link and headers", () => {
    const tab = replay([
      seen("https://cdn.example/v/index.m3u8?token=old", 0, { headers: { Cookie: "a=1" } }),
      seen("https://cdn.example/v/index.m3u8?token=new", 6000, { headers: { Cookie: "a=2" } }),
    ]);
    expect(tab.candidates).toHaveLength(1);
    expect(tab.candidates[0]).toMatchObject({ url: "https://cdn.example/v/index.m3u8?token=new", headers: { Cookie: "a=2" }, lastActivity: 6000 });
  });

  it("keeps a candidate's headers, and nothing from requests that aren't video", () => {
    const tab = replay([
      seen("https://example.com/api/me", 0, { contentType: "application/json", headers: { Cookie: "secret=1" } }),
      seen("https://cdn.example/v/index.m3u8", 10, { headers: { Cookie: "cdn=1" } }),
    ]);
    expect(JSON.stringify(tab)).not.toContain("secret=1");
    expect(tab.candidates[0]?.headers).toEqual({ Cookie: "cdn=1" });
  });

  it("keeps the newest candidates when there are too many", () => {
    const tab = replay(Array.from({ length: maximumCandidates + 5 }, (_, index) =>
      seen(`https://cdn${index}.example/v.mp4`, index * 1000, { type: "media", contentType: "video/mp4" })));
    expect(tab.candidates).toHaveLength(maximumCandidates);
    expect(tab.candidates.some((c) => c.url === "https://cdn0.example/v.mp4")).toBe(false);
  });

  it("replaces one frame's videos and leaves the others", () => {
    let tab = withVideos(newTab(), 1, [{ src: "a", playing: true, currentTime: 1, duration: 10 }]);
    tab = withVideos(tab, 2, [{ src: "b", playing: false, currentTime: 0, duration: 20 }]);
    tab = withVideos(tab, 1, []);
    expect(tab.videos).toEqual([{ frameId: 2, src: "b", playing: false, currentTime: 0, duration: 20 }]);
  });

  it("forgets everything on a new page, and keeps a YouTube page's cookie for later", () => {
    const youtube = navigated("https://www.youtube.com/watch?v=abc", { Cookie: "SID=1", Referer: "https://google.com/", "User-Agent": "UA" });
    expect(youtube).toEqual({ candidates: [], videos: [], pageHeaders: { Cookie: "SID=1", "User-Agent": "UA" } });
    expect(navigated("https://news.example/story", { Cookie: "x=1" })).toEqual({ candidates: [], videos: [] });
  });

  it("ignores links it can't read", () => {
    expect(observe(newTab(), seen("not a url.m3u8", 0))).toEqual(newTab());
  });
});
```

```typescript
import { describe, expect, it } from "vitest";
import type { Candidate } from "../src/detector";
import { failureText, isYouTubeVideo, pageMessage, startTime, streamMessage, tidyTitle } from "../src/message";

const candidate: Candidate = {
  key: "https://cdn.example/v/master.m3u8", url: "https://cdn.example/v/master.m3u8?token=abc", format: "hls", frameId: 3,
  headers: { Cookie: "a=1", Referer: "https://site.example/watch" }, firstSeen: 0, lastSeen: 0, isMaster: true,
};

describe("messages to Paper Plane", () => {
  it("are the spec's v1 play request for a stream", () => {
    expect(streamMessage(candidate, { url: "https://site.example/watch", title: "A film" }, 12.5)).toEqual({
      type: "play", v: 1,
      source: { kind: "stream", url: "https://cdn.example/v/master.m3u8?token=abc", format: "hls",
                headers: { Cookie: "a=1", Referer: "https://site.example/watch" } },
      pageUrl: "https://site.example/watch", title: "A film", startAt: 12.5,
    });
  });

  it("send a YouTube page as the page, with its cookie", () => {
    expect(pageMessage({ url: "https://www.youtube.com/watch?v=x", title: "Clip - YouTube" }, { Cookie: "SID=1" }, 3)).toEqual({
      type: "play", v: 1, source: { kind: "page", url: "https://www.youtube.com/watch?v=x", headers: { Cookie: "SID=1" } },
      pageUrl: "https://www.youtube.com/watch?v=x", title: "Clip", startAt: 3,
    });
  });

  it.each([
    ["https://www.youtube.com/watch?v=dQw4w9WgXcQ", true],
    ["https://m.youtube.com/watch?v=dQw4w9WgXcQ&t=10", true],
    ["https://music.youtube.com/watch?v=abc", true],
    ["https://youtu.be/dQw4w9WgXcQ", true],
    ["https://www.youtube.com/shorts/abc123", true],
    ["https://www.youtube.com/live/abc123", true],
    ["https://www.youtube.com/", false],
    ["https://www.youtube.com/feed/subscriptions", false],
    ["https://www.youtube.com/watch", false],
    ["https://youtube.com.evil.example/watch?v=abc", false],
    ["https://notyoutube.com/watch?v=abc", false],
    ["not a url", false],
  ])("know %s is a YouTube video: %s", (url, expected) => {
    expect(isYouTubeVideo(url)).toBe(expected);
  });

  it("start where the browser's video is", () => {
    const videos = [
      { frameId: 3, src: "blob:x", playing: false, currentTime: 2, duration: 90 },
      { frameId: 3, src: "blob:y", playing: true, currentTime: 41.25, duration: 5400 },
      { frameId: 5, src: "blob:z", playing: true, currentTime: 900, duration: 5400 },
    ];
    expect(startTime(videos, 3)).toBe(41.25);
    expect(startTime(videos, -1)).toBe(41.25); // a worker's stream: the first playing video
    expect(startTime([{ frameId: 0, src: "", playing: true, currentTime: Number.NaN, duration: 0 }], 0)).toBe(0);
    expect(startTime([], 0)).toBe(0);
  });

  it("tidy titles", () => {
    expect(tidyTitle("  Clip\n name - YouTube ")).toBe("Clip name");
    expect(tidyTitle(undefined)).toBe("");
  });

  it("explain failures in plain words", () => {
    expect(failureText(new Error("Specified native messaging host not found.")))
      .toBe("Paper Plane isn't set up for this browser yet. Open Paper Plane once, then try again.");
    expect(failureText(new Error("Error when communicating with the native messaging host.")))
      .toBe("Couldn't reach Paper Plane. Try again.");
    expect(failureText({ ok: false, error: "The site stopped the stream — click Paper Plane in your browser again." }))
      .toBe("The site stopped the stream — click Paper Plane in your browser again.");
    expect(failureText(undefined)).toBe("Couldn't reach Paper Plane. Try again.");
  });
});
```

```typescript
import { describe, expect, it } from "vitest";
import { newTab } from "../src/tabs";
import { button, plan, rows } from "../src/view";
import { newsSiteWithAnAd, replay, twoPlayers } from "./fixtures";

describe("the toolbar button", () => {
  it("is grey with nothing found, and its popup says what to do", () => {
    const empty = plan(newTab(), "https://news.example/", 0);
    expect(empty).toEqual({ kind: "none" });
    expect(button(newTab(), empty, false)).toEqual({ icon: "idle", badge: "", popup: true, title: "Paper Plane: no video found yet" });
  });

  it("sends at a click when one video is the clear choice", () => {
    const tab = replay(newsSiteWithAnAd.responses, newsSiteWithAnAd.videos);
    const sure = plan(tab, "https://www.news.example/story", newsSiteWithAnAd.now);
    expect(sure.kind).toBe("send");
    expect(button(tab, sure, false)).toEqual({ icon: "ready", badge: "", popup: false, title: "Send this video to your TV with Paper Plane" });
  });

  it("counts the choices and offers them in the popup when unsure", () => {
    const tab = replay(twoPlayers.responses, twoPlayers.videos);
    const unsure = plan(tab, "https://two.example/", twoPlayers.now);
    expect(unsure.kind).toBe("choose");
    expect(button(tab, unsure, false)).toEqual({ icon: "ready", badge: "2", popup: true, title: "Paper Plane: choose a video" });
  });

  it("sends a YouTube video's page even before anything else is found", () => {
    expect(plan(newTab(), "https://www.youtube.com/watch?v=abc", 0)).toEqual({ kind: "send", target: { kind: "page" } });
  });

  it("shows sending, and a failure until the next try", () => {
    const tab = replay(newsSiteWithAnAd.responses, newsSiteWithAnAd.videos);
    const sure = plan(tab, "https://www.news.example/story", newsSiteWithAnAd.now);
    expect(button(tab, sure, true)).toMatchObject({ badge: "…", popup: false });
    expect(button({ ...tab, error: "Couldn't reach Paper Plane. Try again." }, sure, false))
      .toEqual({ icon: "ready", badge: "!", popup: true, title: "Paper Plane: Couldn't reach Paper Plane. Try again." });
  });
});

describe("the popup's choices", () => {
  it("say what each one is and where it comes from", () => {
    const tab = replay(newsSiteWithAnAd.responses, newsSiteWithAnAd.videos);
    const ranked = plan(tab, "https://www.news.example/story", newsSiteWithAnAd.now);
    expect(ranked.kind).toBe("send");
    expect(rows(tab.candidates.filter((c) => !c.variantOf), tab.videos)).toEqual([
      { key: "https://ads.example/creative/preroll-15s.mp4", label: "Video file · ads.example", detail: "0:15" },
      { key: "https://video.news.example/hls/story/master.m3u8", label: "HLS stream · video.news.example", detail: "Playing · 3:04" },
    ]);
  });
});
```

```typescript
import { describe, expect, it } from "vitest";
import { describeVideo, videosFrom } from "../src/videos";

describe("videos", () => {
  it("are described by their source, whether they play, and their times", () => {
    expect(describeVideo({ currentSrc: "blob:https://site.example/1", src: "", paused: false, ended: false, currentTime: 12.5, duration: Number.POSITIVE_INFINITY }))
      .toEqual({ src: "blob:https://site.example/1", playing: true, currentTime: 12.5, duration: 0 });
    expect(describeVideo({ currentSrc: "", src: "https://media.example/a.mp4", paused: true, ended: false, currentTime: Number.NaN, duration: 30 }))
      .toEqual({ src: "https://media.example/a.mp4", playing: false, currentTime: 0, duration: 30 });
  });

  it("from a content script are checked, never trusted beyond their shape", () => {
    const good = { src: "https://media.example/a.mp4", playing: true, currentTime: 3, duration: 30 };
    expect(videosFrom([good, { src: 1 }, null, "x", { ...good, currentTime: -5, duration: "long" }])).toEqual([
      good,
      { src: "https://media.example/a.mp4", playing: true, currentTime: 0, duration: 0 },
    ]);
    expect(videosFrom("nonsense")).toEqual([]);
    expect(videosFrom(Array.from({ length: 50 }, () => good))).toHaveLength(20);
    expect(videosFrom([{ ...good, src: "x".repeat(5000) }])[0]?.src).toHaveLength(2048);
  });
});
```

- [ ] **Step 3: Run them to make sure they fail**

Run: `cd extension && npm test`
Expected: FAIL — `Failed to resolve import "../src/classify"` (and the others).

- [ ] **Step 4: Write the implementation**

```typescript
// What a request is to Paper Plane (spec §5.1): a stream to offer, a piece of one, or nothing.

export type Format = "hls" | "dash" | "progressive";
export type Kind = Format | "segment";

const manifestTypes: Record<string, Format> = {
  "application/vnd.apple.mpegurl": "hls",
  "application/x-mpegurl": "hls",
  "audio/mpegurl": "hls",
  "audio/x-mpegurl": "hls",
  "application/dash+xml": "dash",
};
const manifestExtensions: Record<string, Format> = { m3u8: "hls", mpd: "dash" };
const segmentTypes = new Set(["video/mp2t", "video/iso.segment", "audio/mp4", "audio/aac", "audio/mpeg", "audio/webm"]);
const segmentExtensions = new Set(["ts", "m4s", "m4a", "aac", "cmfv", "cmfa"]);
const fileTypes = new Set(["video/mp4", "video/webm", "video/quicktime", "video/x-m4v"]);
const fileExtensions = new Set(["mp4", "m4v", "webm", "mov"]);

/** The lower-case extension of the URL's last path component, if it has one. */
export function extensionOf(url: string): string {
  let path = url;
  try {
    path = new URL(url).pathname;
  } catch {
    path = url.split(/[?#]/)[0] ?? "";
  }
  const name = path.slice(path.lastIndexOf("/") + 1);
  const dot = name.lastIndexOf(".");
  return dot > 0 ? name.slice(dot + 1).toLowerCase() : "";
}

/**
 * Classifies a response by its content type and URL. `requestType` is Chrome's: "media" for a
 * <video> element's own requests, "xmlhttprequest" or "other" for a player's fetches. A video
 * file a player fetches piece by piece is a segment of a stream, not a video to send.
 */
export function classify(url: string, contentType: string | undefined, requestType: string): Kind | undefined {
  const type = (contentType ?? "").split(";")[0]!.trim().toLowerCase();
  const extension = extensionOf(url);
  const manifest = manifestTypes[type] ?? manifestExtensions[extension];
  if (manifest) {
    return manifest;
  }
  if (segmentTypes.has(type) || segmentExtensions.has(extension)) {
    return "segment";
  }
  if (fileTypes.has(type) || fileExtensions.has(extension)) {
    return requestType === "media" ? "progressive" : "segment";
  }
  return undefined;
}
```

```typescript
// StreamDetector (spec §5.1): ranks a tab's streams to find the one the user is watching.
import type { Format } from "./classify";

/** A stream found in a tab. */
export interface Candidate {
  /** Origin and path: the same stream when its link's token changes. */
  key: string;
  /** The newest link to it. */
  url: string;
  format: Format;
  /** The frame that fetched it; -1 for a worker's request. */
  frameId: number;
  /** Cookie, Referer, Origin and User-Agent from its request, for Paper Plane to send too. */
  headers: Record<string, string>;
  firstSeen: number;
  lastSeen: number;
  /** When a segment, or a repeat of its own request, last showed it playing. */
  lastActivity?: number;
  /** The first HLS playlist of its burst: the master that lists the others. */
  isMaster: boolean;
  /** A variant playlist's master, which is offered in its place. */
  variantOf?: string;
}

/** A <video> element, as the content script reports it. */
export interface FrameVideo {
  frameId: number;
  /** Its src: http(s) for a file, blob: for a player's stream. */
  src: string;
  playing: boolean;
  currentTime: number;
  /** Seconds; 0 when unknown. */
  duration: number;
}

/** The ranking criteria in the spec's order, each outweighing all those after it together. */
export const weights = { playing: 16, activity: 8, master: 4, videoSrc: 2, long: 1 } as const;
/** Segments within this long count as ongoing activity. */
export const activityWindow = 15_000;
/** Shorter videos are more likely ads. */
export const longVideo = 60;

export function keyOf(url: string): string {
  const parsed = new URL(url);
  return parsed.origin + parsed.pathname;
}

function isPlayedBy(candidate: Candidate, video: FrameVideo): boolean {
  if (!video.src.startsWith("http")) {
    return false;
  }
  try {
    return keyOf(video.src) === candidate.key;
  } catch {
    return false;
  }
}

/** The videos that are the candidate's: the one playing its file, else those of its frame. */
function videosOf(candidate: Candidate, videos: FrameVideo[]): FrameVideo[] {
  const playing = videos.filter((video) => isPlayedBy(candidate, video));
  if (playing.length > 0) {
    return playing;
  }
  return videos.filter((video) => candidate.frameId < 0 || video.frameId === candidate.frameId);
}

export function score(candidate: Candidate, videos: FrameVideo[], now: number): number {
  const inFrame = videos.filter((video) => candidate.frameId < 0 || video.frameId === candidate.frameId);
  let total = 0;
  if (inFrame.some((video) => video.playing)) {
    total += weights.playing;
  }
  if (candidate.lastActivity !== undefined && now - candidate.lastActivity <= activityWindow) {
    total += weights.activity;
  }
  if (candidate.isMaster) {
    total += weights.master;
  }
  if (videos.some((video) => isPlayedBy(candidate, video))) {
    total += weights.videoSrc;
  }
  if (videosOf(candidate, videos).some((video) => video.duration >= longVideo)) {
    total += weights.long;
  }
  return total;
}

/** The streams worth offering, best first; the most recently seen first among equals. */
export function rank(candidates: Candidate[], videos: FrameVideo[], now: number): Candidate[] {
  return candidates
    .filter((candidate) => candidate.variantOf === undefined)
    .map((candidate) => ({ candidate, score: score(candidate, videos, now) }))
    .sort((a, b) => b.score - a.score || b.candidate.lastSeen - a.candidate.lastSeen)
    .map(({ candidate }) => candidate);
}

export type Choice =
  | { kind: "none" }
  | { kind: "one"; candidate: Candidate }
  | { kind: "several"; ranked: Candidate[] };

/** One stream when the best beats the next by at least one criterion; otherwise the user picks. */
export function choose(candidates: Candidate[], videos: FrameVideo[], now: number): Choice {
  const ranked = rank(candidates, videos, now);
  const [best, next] = ranked;
  if (!best) {
    return { kind: "none" };
  }
  if (!next || score(best, videos, now) > score(next, videos, now)) {
    return { kind: "one", candidate: best };
  }
  return { kind: "several", ranked };
}
```

```typescript
// What the extension knows about a tab (spec §5.1), as pure functions of what Chrome reports.
// The service worker keeps it in chrome.storage.session, so it survives the worker being
// suspended, and starts afresh when the tab loads a new page.
import { classify } from "./classify";
import { isYouTubeVideo } from "./message";
import { keyOf, type Candidate, type FrameVideo } from "./detector";

export interface TabState {
  candidates: Candidate[];
  videos: FrameVideo[];
  /** A YouTube page's cookie and user agent, for yt-dlp (spec §5.1). */
  pageHeaders?: Record<string, string>;
  /** Why the last send failed, until the next try. */
  error?: string;
}

/** A response, with the headers of its request if they were captured. */
export interface Response {
  url: string;
  frameId: number;
  /** Chrome's request type: "media", "xmlhttprequest", "other"… */
  type: string;
  timeStamp: number;
  statusCode: number;
  contentType?: string;
  headers: Record<string, string>;
}

export const maximumCandidates = 20;
/** HLS playlists fetched this soon after a master, from its frame and host, are its variants. */
export const burstWindow = 10_000;

const headerNames: Record<string, string> = {
  cookie: "Cookie",
  referer: "Referer",
  origin: "Origin",
  "user-agent": "User-Agent",
};

export function newTab(): TabState {
  return { candidates: [], videos: [] };
}

/** The headers a site needs to hand over its video, and nothing else (spec §5.1). */
export function pickHeaders(raw: { name: string; value?: string }[] | undefined): Record<string, string> {
  const kept: Record<string, string> = {};
  for (const header of raw ?? []) {
    const name = headerNames[header.name.toLowerCase()];
    if (name && header.value !== undefined) {
      kept[name] = header.value;
    }
  }
  return kept;
}

/** A new page in the tab: nothing found yet. A YouTube video page keeps its cookie. */
export function navigated(url: string, headers: Record<string, string>): TabState {
  if (!isYouTubeVideo(url)) {
    return newTab();
  }
  const pageHeaders: Record<string, string> = {};
  for (const name of ["Cookie", "User-Agent"]) {
    if (headers[name] !== undefined) {
      pageHeaders[name] = headers[name];
    }
  }
  return { ...newTab(), pageHeaders };
}

export function withVideos(tab: TabState, frameId: number, videos: Omit<FrameVideo, "frameId">[]): TabState {
  return {
    ...tab,
    videos: [...tab.videos.filter((video) => video.frameId !== frameId), ...videos.map((video) => ({ frameId, ...video }))],
  };
}

/** Takes a response into account: a new stream, a repeat of one, or a segment of one. */
export function observe(tab: TabState, response: Response): TabState {
  if (response.statusCode < 200 || response.statusCode >= 300) {
    return tab;
  }
  const kind = classify(response.url, response.contentType, response.type);
  let key: string;
  try {
    key = keyOf(response.url);
  } catch {
    return tab;
  }
  if (!kind) {
    return tab;
  }
  const candidates = tab.candidates.map((candidate) => ({ ...candidate }));
  const now = response.timeStamp;
  if (kind === "segment") {
    credit(candidates, response.url, now);
    return { ...tab, candidates };
  }
  const known = candidates.find((candidate) => candidate.key === key);
  if (known) {
    // A live playlist reloading, or a video fetching its next range: still playing.
    known.url = response.url;
    known.lastSeen = now;
    known.lastActivity = now;
    if (Object.keys(response.headers).length > 0) {
      known.headers = response.headers;
    }
    const master = candidates.find((candidate) => candidate.key === known.variantOf);
    if (master) {
      master.lastActivity = now;
    }
    return { ...tab, candidates };
  }
  const host = new URL(response.url).host;
  const master = kind === "hls"
    ? candidates.find((candidate) => candidate.format === "hls" && candidate.variantOf === undefined
        && candidate.frameId === response.frameId && new URL(candidate.url).host === host
        && now - candidate.firstSeen <= burstWindow)
    : undefined;
  candidates.push({
    key, url: response.url, format: kind, frameId: response.frameId, headers: response.headers,
    firstSeen: now, lastSeen: now, isMaster: kind === "hls" && master === undefined,
    ...(master ? { variantOf: master.key } : {}),
  });
  candidates.sort((a, b) => a.lastSeen - b.lastSeen);
  return { ...tab, candidates: candidates.slice(-maximumCandidates) };
}

/** Marks the stream a segment belongs to as active: the one on the same host whose playlist's
 *  folder holds the segment, the deepest such folder winning; a variant's master with it. */
function credit(candidates: Candidate[], url: string, now: number): void {
  const segment = new URL(url);
  let owner: Candidate | undefined;
  let depth = -1;
  for (const candidate of candidates) {
    const playlist = new URL(candidate.url);
    const folder = playlist.pathname.slice(0, playlist.pathname.lastIndexOf("/") + 1);
    if (playlist.host === segment.host && segment.pathname.startsWith(folder) && folder.length > depth) {
      owner = candidate;
      depth = folder.length;
    }
  }
  if (!owner) {
    return;
  }
  owner.lastActivity = now;
  const master = candidates.find((candidate) => candidate.key === owner.variantOf);
  if (master) {
    master.lastActivity = now;
  }
}
```

```typescript
// The play request sent to Paper Plane through its helper (spec §5.2, message v1).
import type { Candidate, FrameVideo } from "./detector";
import type { Format } from "./classify";

/** The native messaging host the app installs for Chrome and Brave. */
export const hostName = "dev.paperplane.host";

export interface PlayMessage {
  type: "play";
  v: 1;
  source:
    | { kind: "stream"; url: string; format: Format; headers: Record<string, string> }
    | { kind: "page"; url: string; headers: Record<string, string> };
  pageUrl: string;
  title: string;
  startAt: number;
}

export interface Page {
  url: string;
  title: string;
}

export function streamMessage(candidate: Candidate, page: Page, startAt: number): PlayMessage {
  return {
    type: "play", v: 1,
    source: { kind: "stream", url: candidate.url, format: candidate.format, headers: candidate.headers },
    pageUrl: page.url, title: tidyTitle(page.title), startAt,
  };
}

/** YouTube: the page itself, for yt-dlp in the app, with the site's cookie (spec §5.1). */
export function pageMessage(page: Page, headers: Record<string, string>, startAt: number): PlayMessage {
  return {
    type: "play", v: 1,
    source: { kind: "page", url: page.url, headers },
    pageUrl: page.url, title: tidyTitle(page.title), startAt,
  };
}

/** A YouTube video's page: a watch, Shorts or live page, or a youtu.be link. */
export function isYouTubeVideo(url: string): boolean {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return false;
  }
  const host = parsed.hostname;
  if (host === "youtu.be") {
    return parsed.pathname.length > 1;
  }
  if (host !== "youtube.com" && !host.endsWith(".youtube.com")) {
    return false;
  }
  return (parsed.pathname === "/watch" && parsed.searchParams.has("v"))
    || /^\/(shorts|live)\/[^/]+/.test(parsed.pathname);
}

/** Where the browser's video is: the playing one in `frameId` (any frame for -1), else its
 *  first video, in seconds. */
export function startTime(videos: FrameVideo[], frameId: number): number {
  const inFrame = videos.filter((video) => frameId < 0 || video.frameId === frameId);
  const video = inFrame.find((candidate) => candidate.playing) ?? inFrame[0];
  const time = video?.currentTime ?? 0;
  return Number.isFinite(time) && time > 0 ? time : 0;
}

/** One line, without YouTube's " - YouTube". */
export function tidyTitle(title: string | undefined): string {
  return (title ?? "").replace(/\s+/g, " ").trim().replace(/ - YouTube$/, "");
}

/** What to tell the user when sending failed: the app's own words, or plain ones for Chrome's. */
export function failureText(failure: unknown): string {
  if (typeof failure === "object" && failure !== null && "error" in failure && typeof failure.error === "string") {
    return failure.error;
  }
  const message = failure instanceof Error ? failure.message : "";
  if (/native messaging host not found|forbidden/i.test(message)) {
    return "Paper Plane isn't set up for this browser yet. Open Paper Plane once, then try again.";
  }
  return "Couldn't reach Paper Plane. Try again.";
}
```

```typescript
// What the toolbar button and its popup show (spec §5.1): grey with nothing found, a click to
// send when one video is the clear choice, a count and a chooser when it isn't.
import { choose, type Candidate, type FrameVideo } from "./detector";
import { isYouTubeVideo } from "./message";
import type { TabState } from "./tabs";

export type Target = { kind: "page" } | { kind: "stream"; candidate: Candidate };

export type Plan =
  | { kind: "none" }
  | { kind: "send"; target: Target }
  | { kind: "choose"; ranked: Candidate[] };

export interface ButtonView {
  icon: "idle" | "ready";
  badge: string;
  /** Whether a click opens the popup; otherwise it sends. */
  popup: boolean;
  title: string;
}

export interface Row {
  key: string;
  label: string;
  detail: string;
}

/** What the popup asks the service worker for when it opens. */
export interface PopupState {
  plan: Plan["kind"];
  /** A YouTube page, sent as the page. */
  youtube: boolean;
  error?: string;
  rows: Row[];
}

export function plan(tab: TabState, pageUrl: string | undefined, now: number): Plan {
  if (pageUrl && isYouTubeVideo(pageUrl)) {
    return { kind: "send", target: { kind: "page" } };
  }
  const choice = choose(tab.candidates, tab.videos, now);
  switch (choice.kind) {
    case "none": return { kind: "none" };
    case "one": return { kind: "send", target: { kind: "stream", candidate: choice.candidate } };
    case "several": return { kind: "choose", ranked: choice.ranked };
  }
}

export function button(tab: TabState, plan: Plan, sending: boolean): ButtonView {
  const icon = plan.kind === "none" ? "idle" : "ready";
  if (sending) {
    return { icon, badge: "…", popup: false, title: "Sending to Paper Plane…" };
  }
  if (tab.error) {
    return { icon, badge: "!", popup: true, title: `Paper Plane: ${tab.error}` };
  }
  switch (plan.kind) {
    case "none": return { icon, badge: "", popup: true, title: "Paper Plane: no video found yet" };
    case "send": return { icon, badge: "", popup: false, title: "Send this video to your TV with Paper Plane" };
    case "choose": return { icon, badge: String(plan.ranked.length), popup: true, title: "Paper Plane: choose a video" };
  }
}

const formatNames = { hls: "HLS stream", dash: "DASH stream", progressive: "Video file" } as const;

/** The popup's choices: what each is, where it's from, and whether it's playing and how long. */
export function rows(candidates: Candidate[], videos: FrameVideo[]): Row[] {
  return candidates.map((candidate) => {
    const own = videos.filter((video) => video.src.startsWith("http") && video.src.split(/[?#]/)[0] === candidate.key);
    const related = own.length > 0 ? own : videos.filter((video) => candidate.frameId < 0 || video.frameId === candidate.frameId);
    const parts: string[] = [];
    if (related.some((video) => video.playing)) {
      parts.push("Playing");
    }
    const duration = Math.max(0, ...related.map((video) => video.duration));
    if (duration > 0) {
      parts.push(clock(duration));
    }
    return {
      key: candidate.key,
      label: `${formatNames[candidate.format]} · ${new URL(candidate.url).hostname}`,
      detail: parts.join(" · ") || "Found on this page",
    };
  });
}

/** "0:15", "3:04", "1:52:10". */
export function clock(seconds: number): string {
  const total = Math.floor(seconds);
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor(total / 60) % 60;
  const secs = String(total % 60).padStart(2, "0");
  return hours > 0 ? `${hours}:${String(minutes).padStart(2, "0")}:${secs}` : `${minutes}:${secs}`;
}
```

```typescript
// A frame's <video> elements, as the content script reports them to the service worker.
import type { FrameVideo } from "./detector";

export type Video = Omit<FrameVideo, "frameId">;

/** The parts of an HTMLVideoElement the report needs. */
export interface VideoElement {
  currentSrc: string;
  src: string;
  paused: boolean;
  ended: boolean;
  currentTime: number;
  duration: number;
}

const maximumVideos = 20;
const maximumSource = 2048;

function seconds(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) && value > 0 ? value : 0;
}

export function describeVideo(video: VideoElement): Video {
  return {
    src: (video.currentSrc || video.src).slice(0, maximumSource),
    playing: !video.paused && !video.ended,
    currentTime: seconds(video.currentTime),
    duration: seconds(video.duration),
  };
}

/** What a content script sent, kept only if it has the right shape, within limits. */
export function videosFrom(raw: unknown): Video[] {
  if (!Array.isArray(raw)) {
    return [];
  }
  return raw
    .filter((item): item is Record<string, unknown> =>
      typeof item === "object" && item !== null && typeof item.src === "string" && typeof item.playing === "boolean")
    .slice(0, maximumVideos)
    .map((item) => ({
      src: (item.src as string).slice(0, maximumSource),
      playing: item.playing as boolean,
      currentTime: seconds(item.currentTime),
      duration: seconds(item.duration),
    }));
}
```

- [ ] **Step 5: Run the tests and the type checker**

Run: `cd extension && npm test && npm run typecheck`
Expected: PASS, 57 tests in 6 files; no type errors.

- [ ] **Step 6: Commit**

```bash
git add extension/package.json extension/package-lock.json extension/tsconfig.json extension/src extension/test
git commit -m "feat(extension): find, rank and describe a tab's streams, and build the play request"
```

### Task 10: The extension's service worker, content script, popup and icons

**Files:**
- Create: `extension/src/background.ts`, `extension/src/content.ts`, `extension/src/popup.ts`, `extension/static/popup.html`, `extension/static/popup.css`, `extension/build.mjs`, `extension/static/icons/*.png` (by script), `extension/check-in-chrome.mjs`, `scripts/check-extension.sh`
- Modify: `scripts/make-icon.swift`, `.gitignore`, `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: everything in Task 9; the helper and app (Task 8).
- Produces:
  - The built extension in `extension/dist/` (`npm run build`).
  - Toolbar icons: `icons/icon-N.png` and `icons/idle-N.png` for N = 16, 32, 48, 128.
  - The popup's messages to the worker: `{type: "state", tabId}` → `PopupState`, and `{type: "send", tabId, key?}` → `{ok: true} | {error}`. The content script's messages: `{type: "videos"}` to the worker, and `{type: "pause"}` / `{type: "time"}` from it.

- [ ] **Step 1: The wiring**

```typescript
// The service worker (spec §5.1): watches each tab's requests for streams, keeps what it finds in
// chrome.storage.session, sets the toolbar button, and sends the chosen video to Paper Plane.
import { classify } from "./classify";
import { failureText, hostName, pageMessage, startTime, streamMessage } from "./message";
import { navigated, newTab, observe, pickHeaders, withVideos, type TabState } from "./tabs";
import { videosFrom } from "./videos";
import { button, plan, rows, type PopupState, type Target } from "./view";

const filter: chrome.webRequest.RequestFilter = {
  urls: ["<all_urls>"],
  types: ["main_frame", "xmlhttprequest", "media", "other"],
};

/** Each request's kept headers, by request ID, only until its response shows whether it's video. */
const pending = new Map<string, Record<string, string>>();
const maximumPending = 500;
/** Tabs with a send under way. */
const sending = new Set<number>();

// MARK: - Tab state, one change at a time per tab

const changes = new Map<number, Promise<unknown>>();

function storageKey(tabId: number): string {
  return `tab:${tabId}`;
}

async function load(tabId: number): Promise<TabState> {
  const stored = await chrome.storage.session.get(storageKey(tabId));
  return (stored[storageKey(tabId)] as TabState | undefined) ?? newTab();
}

function update(tabId: number, change: (tab: TabState) => TabState): Promise<TabState> {
  const next = (changes.get(tabId) ?? Promise.resolve()).then(async () => {
    const tab = change(await load(tabId));
    await chrome.storage.session.set({ [storageKey(tabId)]: tab });
    return tab;
  });
  changes.set(tabId, next.catch(() => undefined));
  return next;
}

function icons(kind: "idle" | "ready"): Record<number, string> {
  const name = kind === "idle" ? "idle" : "icon";
  return Object.fromEntries([16, 32, 48, 128].map((size) => [size, `icons/${name}-${size}.png`]));
}

/** Sets the tab's button from what's known about it. */
async function refresh(tabId: number, known?: TabState): Promise<void> {
  const page = await chrome.tabs.get(tabId).catch(() => undefined);
  if (!page) {
    return; // closed meanwhile
  }
  const tab = known ?? await load(tabId);
  const view = button(tab, plan(tab, page.url, Date.now()), sending.has(tabId));
  await Promise.all([
    chrome.action.setIcon({ tabId, path: icons(view.icon) }),
    chrome.action.setBadgeText({ tabId, text: view.badge }),
    chrome.action.setPopup({ tabId, popup: view.popup ? "popup.html" : "" }),
    chrome.action.setTitle({ tabId, title: view.title }),
  ]).catch(() => undefined);
}

// MARK: - Watching requests

chrome.webRequest.onSendHeaders.addListener((details) => {
  if (details.tabId < 0) {
    return;
  }
  const headers = pickHeaders(details.requestHeaders);
  if (details.type === "main_frame") {
    void update(details.tabId, () => navigated(details.url, headers)).then((tab) => refresh(details.tabId, tab));
    return;
  }
  if (pending.size >= maximumPending) {
    pending.delete(pending.keys().next().value!);
  }
  pending.set(details.requestId, headers);
}, filter, ["requestHeaders", "extraHeaders"]);

chrome.webRequest.onHeadersReceived.addListener((details) => {
  const headers = pending.get(details.requestId) ?? {};
  pending.delete(details.requestId);
  if (details.tabId < 0 || details.type === "main_frame") {
    return;
  }
  const contentType = details.responseHeaders?.find((header) => header.name.toLowerCase() === "content-type")?.value;
  if (!classify(details.url, contentType, details.type)) {
    return; // most requests: nothing to keep
  }
  const response = {
    url: details.url, frameId: details.frameId, type: details.type, timeStamp: details.timeStamp,
    statusCode: details.statusCode, contentType, headers,
  };
  void update(details.tabId, (tab) => observe(tab, response)).then((tab) => refresh(details.tabId, tab));
}, filter, ["responseHeaders"]);

chrome.webRequest.onErrorOccurred.addListener((details) => {
  pending.delete(details.requestId);
}, filter);

chrome.tabs.onRemoved.addListener((tabId) => {
  changes.delete(tabId);
  void chrome.storage.session.remove(storageKey(tabId));
});

// MARK: - Sending

/** Where the video is now: asked of its frame, else the last report. */
async function currentTime(tabId: number, frameId: number, tab: TabState): Promise<number> {
  if (frameId >= 0) {
    const reported: unknown = await chrome.tabs.sendMessage(tabId, { type: "time" }, { frameId }).catch(() => undefined);
    if (typeof reported === "number" && Number.isFinite(reported) && reported >= 0) {
      return reported;
    }
  }
  return startTime(tab.videos, frameId);
}

/** Sends `target` to Paper Plane; once it has the video, pauses the tab's videos (spec §5.1). */
async function send(tabId: number, target: Target): Promise<{ ok: true } | { error: string }> {
  if (sending.has(tabId)) {
    return { error: "Already sending this tab's video." };
  }
  sending.add(tabId);
  await update(tabId, ({ error: _, ...tab }) => tab);
  await refresh(tabId);
  let result: { ok: true } | { error: string };
  try {
    const [tab, page] = await Promise.all([load(tabId), chrome.tabs.get(tabId)]);
    const info = { url: page.url ?? "", title: page.title ?? "" };
    const frameId = target.kind === "stream" ? target.candidate.frameId : 0;
    const startAt = await currentTime(tabId, frameId, tab);
    const message = target.kind === "stream"
      ? streamMessage(target.candidate, info, startAt)
      : pageMessage(info, tab.pageHeaders ?? {}, startAt);
    const reply: unknown = await chrome.runtime.sendNativeMessage(hostName, message);
    if (typeof reply === "object" && reply !== null && "ok" in reply && reply.ok === true) {
      await chrome.tabs.sendMessage(tabId, { type: "pause" }).catch(() => undefined);
      result = { ok: true };
    } else {
      result = { error: failureText(reply) };
    }
  } catch (failure) {
    result = { error: failureText(failure) };
  }
  if ("error" in result) {
    const error = result.error;
    await update(tabId, (tab) => ({ ...tab, error }));
  }
  sending.delete(tabId);
  await refresh(tabId);
  return result;
}

chrome.action.onClicked.addListener(async (page) => {
  if (page.id === undefined) {
    return;
  }
  const tab = await load(page.id);
  const current = plan(tab, page.url, Date.now());
  if (current.kind === "send") {
    await send(page.id, current.target);
    return;
  }
  // What was found changed since the button was set: show the choices instead.
  await refresh(page.id, tab);
  await chrome.action.openPopup().catch(() => undefined);
});

// MARK: - Messages from content scripts and the popup

async function answerPopup(message: Record<string, unknown>): Promise<unknown> {
  const tabId = message.tabId;
  if (typeof tabId !== "number") {
    return undefined;
  }
  const [tab, page] = await Promise.all([load(tabId), chrome.tabs.get(tabId)]);
  const current = plan(tab, page.url, Date.now());
  if (message.type === "state") {
    const offered = current.kind === "choose" ? current.ranked
      : current.kind === "send" && current.target.kind === "stream" ? [current.target.candidate] : [];
    const state: PopupState = {
      plan: current.kind,
      youtube: current.kind === "send" && current.target.kind === "page",
      rows: rows(offered, tab.videos),
      ...(tab.error ? { error: tab.error } : {}),
    };
    return state;
  }
  if (message.type === "send") {
    const candidate = typeof message.key === "string"
      ? tab.candidates.find((found) => found.key === message.key && found.variantOf === undefined)
      : undefined;
    const target: Target | undefined = candidate ? { kind: "stream", candidate }
      : current.kind === "send" ? current.target : undefined;
    return target ? send(tabId, target) : { error: "That video isn't on this page any more." };
  }
  return undefined;
}

chrome.runtime.onMessage.addListener((message: unknown, sender, reply) => {
  if (sender.id !== chrome.runtime.id || typeof message !== "object" || message === null) {
    return false;
  }
  const request = message as Record<string, unknown>;
  // The popup is known by its address; a content script's is the page's own.
  if (sender.url?.startsWith(chrome.runtime.getURL("popup.html"))) {
    answerPopup(request).then(reply, () => reply(undefined));
    return true; // answers later
  }
  const tabId = sender.tab?.id;
  if (tabId !== undefined && sender.frameId !== undefined && request.type === "videos") {
    const frameId = sender.frameId;
    void update(tabId, (tab) => withVideos(tab, frameId, videosFrom(request.videos))).then((tab) => refresh(tabId, tab));
  }
  return false;
});

// Pages open before the extension was installed or updated get the content script too.
chrome.runtime.onInstalled.addListener(async () => {
  const tabs = await chrome.tabs.query({ url: ["http://*/*", "https://*/*"] });
  for (const tab of tabs) {
    if (tab.id !== undefined) {
      chrome.scripting.executeScript({ target: { tabId: tab.id, allFrames: true }, files: ["content.js"] })
        .catch(() => undefined);
    }
  }
});
```

```typescript
// Runs in every frame (spec §5.1): reports the frame's <video> elements to the service worker, and
// pauses them once Paper Plane has the video. It takes orders only from the extension, never from
// the page.
import { describeVideo } from "./videos";

declare global {
  var paperPlaneReporting: boolean | undefined;
}

// Installing the extension adds this script to open tabs, where it may already be running.
if (!globalThis.paperPlaneReporting) {
  globalThis.paperPlaneReporting = true;

  const videos = () => Array.from(document.querySelectorAll("video"), describeVideo);
  let pending: ReturnType<typeof setTimeout> | undefined;
  const report = () => {
    clearTimeout(pending);
    pending = setTimeout(() => {
      chrome.runtime.sendMessage({ type: "videos", videos: videos() }).catch(() => undefined);
    }, 300);
  };
  // Media events don't bubble, but they do pass through the document on the way down, so frames
  // without a video never report at all.
  for (const event of ["play", "playing", "pause", "ended", "loadedmetadata", "durationchange", "emptied"]) {
    document.addEventListener(event, report, true);
  }
  if (document.querySelector("video")) {
    report();
  }

  chrome.runtime.onMessage.addListener((message: unknown, sender, reply) => {
    if (sender.id !== chrome.runtime.id || typeof message !== "object" || message === null || !("type" in message)) {
      return false;
    }
    if (message.type === "pause") {
      for (const video of document.querySelectorAll("video")) {
        video.pause();
      }
      reply(true);
    } else if (message.type === "time") {
      const list = videos();
      reply((list.find((video) => video.playing) ?? list[0])?.currentTime);
    }
    return false;
  });
}
```

```typescript
// The toolbar popup (spec §5.1): what was found when there's a choice to make, why nothing was,
// or why sending failed. Everything it shows goes in as text, never as HTML.
import type { PopupState, Row } from "./view";

const main = document.querySelector("main")!;

function element<K extends keyof HTMLElementTagNameMap>(tag: K, className: string, text?: string): HTMLElementTagNameMap[K] {
  const made = document.createElement(tag);
  made.className = className;
  if (text !== undefined) {
    made.textContent = text;
  }
  return made;
}

function choice(row: Row, onPick: () => void): HTMLButtonElement {
  const button = element("button", "row");
  button.type = "button";
  button.append(element("span", "label", row.label), element("span", "detail", row.detail));
  button.addEventListener("click", onPick);
  return button;
}

function render(tabId: number, state: PopupState | undefined): void {
  main.replaceChildren();
  if (state?.error) {
    main.append(element("p", "note", state.error));
  }
  if (!state || state.plan === "none") {
    main.append(element("h1", "heading", "No video found yet"),
      element("p", "hint", "Start the video on this page, then click Paper Plane again."));
    return;
  }
  const rows = state.youtube
    ? [{ key: "", label: "This YouTube video", detail: "Sent as its page" }]
    : state.rows;
  main.append(element("h1", "heading", state.plan === "choose" ? "Which video?" : "Send to your TV"));
  const list = element("div", "rows");
  for (const row of rows) {
    list.append(choice(row, () => void send(tabId, row.key || undefined)));
  }
  main.append(list);
  list.querySelector("button")?.focus();
}

async function send(tabId: number, key: string | undefined): Promise<void> {
  main.replaceChildren(element("p", "status", "Sending to Paper Plane…"));
  const result = await chrome.runtime.sendMessage({ type: "send", tabId, key }) as { ok: true } | { error: string } | undefined;
  if (result && "ok" in result) {
    main.replaceChildren(element("h1", "heading", "Sent"), element("p", "hint", "Choose your TV in Paper Plane."));
    setTimeout(() => window.close(), 1500);
  } else {
    render(tabId, await state(tabId));
  }
}

function state(tabId: number): Promise<PopupState | undefined> {
  return chrome.runtime.sendMessage({ type: "state", tabId });
}

const [active] = await chrome.tabs.query({ active: true, currentWindow: true });
if (active?.id !== undefined) {
  render(active.id, await state(active.id));
}
```

```html
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="color-scheme" content="light dark">
  <title>Paper Plane</title>
  <link rel="stylesheet" href="popup.css">
</head>
<body>
  <header>
    <img src="icons/icon-32.png" alt="" width="18" height="18">
    <span>Paper Plane</span>
  </header>
  <main aria-live="polite"></main>
  <script type="module" src="popup.js"></script>
</body>
</html>
```

```css
/* The toolbar popup, in the system's look: light and dark, quiet, one accent. */
:root {
  color-scheme: light dark;
  --text: #1d1d1f;
  --secondary: #6e6e73;
  --background: #ffffff;
  --row: #f2f2f5;
  --row-hover: #e8e8ed;
  --accent: #0a6cff;
  --note-background: #fff4e5;
  --note-text: #7a4100;
  font: 13px/1.4 system-ui, -apple-system, "Segoe UI", sans-serif;
}

@media (prefers-color-scheme: dark) {
  :root {
    --text: #f5f5f7;
    --secondary: #a1a1a6;
    --background: #1c1c1e;
    --row: #2c2c2e;
    --row-hover: #3a3a3c;
    --accent: #4c9dff;
    --note-background: #3a2a12;
    --note-text: #ffcf8a;
  }
}

body {
  margin: 0;
  width: 300px;
  background: var(--background);
  color: var(--text);
}

header {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 14px 16px 0;
  font-weight: 600;
}

main {
  padding: 10px 16px 16px;
}

.heading {
  margin: 0 0 4px;
  font-size: 13px;
  font-weight: 600;
}

.hint,
.status {
  margin: 0;
  color: var(--secondary);
}

.note {
  margin: 0 0 12px;
  padding: 8px 10px;
  border-radius: 8px;
  background: var(--note-background);
  color: var(--note-text);
}

.rows {
  display: flex;
  flex-direction: column;
  gap: 6px;
  margin-top: 8px;
}

.row {
  display: block;
  width: 100%;
  padding: 8px 10px;
  border: 0;
  border-radius: 8px;
  background: var(--row);
  color: inherit;
  font: inherit;
  text-align: left;
  cursor: pointer;
}

.row:hover {
  background: var(--row-hover);
}

.row:focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 1px;
}

.label {
  display: block;
  font-weight: 500;
  overflow-wrap: anywhere;
}

.detail {
  display: block;
  color: var(--secondary);
  font-size: 12px;
}
```

```javascript
// Builds the extension into dist/, the folder Chrome and Brave load
// (chrome://extensions → Developer mode → Load unpacked).
import { build } from "esbuild";
import { cp, rm } from "node:fs/promises";

await rm("dist", { recursive: true, force: true });
const common = { bundle: true, target: "chrome116", outdir: "dist", logLevel: "warning", legalComments: "none" };
// The service worker and the popup are modules; a content script can't be one.
await build({ ...common, entryPoints: ["src/background.ts", "src/popup.ts"], format: "esm" });
await build({ ...common, entryPoints: ["src/content.ts"], format: "iife" });
await cp("static", "dist", { recursive: true });
```

- [ ] **Step 2: The icons, drawn like the app's**

```diff
--- a/scripts/make-icon.swift
+++ b/scripts/make-icon.swift
@@ -79,13 +79,30 @@
     context.restoreGState()
 }
 
-func writePNG(size: Int, to url: URL) throws {
+/// `toolbar` draws the tile filling the whole image, as browser toolbar icons are; `grey` drains
+/// its colour and fades it, for the extension's "nothing found" state.
+func writePNG(size: Int, to url: URL, toolbar: Bool = false, grey: Bool = false) throws {
     let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
     guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
     else { throw CocoaError(.fileWriteUnknown) }
     context.interpolationQuality = .high
+    if toolbar {
+        // The 824-point tile (from 100 to 924 on the 1024 grid) scaled to the full image.
+        let scale = 1024.0 / 824.0
+        context.translateBy(x: -100 * CGFloat(size) / 824, y: -100 * CGFloat(size) / 824)
+        context.scaleBy(x: scale, y: scale)
+    }
     drawIcon(in: context, size: CGFloat(size))
+    if grey, let pixels = context.data?.assumingMemoryBound(to: UInt8.self) {
+        for offset in stride(from: 0, to: context.bytesPerRow * size, by: 4) {
+            let luminance = 0.299 * Double(pixels[offset]) + 0.587 * Double(pixels[offset + 1]) + 0.114 * Double(pixels[offset + 2])
+            for channel in 0..<4 { // still premultiplied after fading every channel alike
+                let value = channel == 3 ? Double(pixels[offset + 3]) : luminance
+                pixels[offset + channel] = UInt8(min(255, value * 0.55))
+            }
+        }
+    }
     guard let image = context.makeImage(),
           let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
     else { throw CocoaError(.fileWriteUnknown) }
@@ -93,8 +110,21 @@
     guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
 }
 
+if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--extension" {
+    // The extension's icons: icon-N.png in colour, idle-N.png grey.
+    let folder = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
+    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
+    for size in [16, 32, 48, 128] {
+        try writePNG(size: size, to: folder.appendingPathComponent("icon-\(size).png"), toolbar: true)
+        try writePNG(size: size, to: folder.appendingPathComponent("idle-\(size).png"), toolbar: true, grey: true)
+    }
+    print("Wrote 8 extension icons to \(folder.path)")
+    exit(0)
+}
+
 guard CommandLine.arguments.count == 2 else {
     print("usage: swift scripts/make-icon.swift <AppIcon.appiconset folder>")
+    print("       swift scripts/make-icon.swift --extension <icons folder>")
     exit(2)
 }
 let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
```

Run: `swift scripts/make-icon.swift --extension extension/static/icons`
Expected: "Wrote 8 extension icons".

- [ ] **Step 3: Build, type-check and test**

Run: `cd extension && npm run typecheck && npm test && npm run build`
Expected: no type errors; 57 tests pass; `dist/` holds `manifest.json`, `background.js`, `content.js`, `popup.{html,css,js}` and `icons/`.

- [ ] **Step 4: Check it in a real Chrome, end to end**

```javascript
// Drives the built extension in a headless Chrome with a throwaway profile, over the DevTools
// pipe: loads it, opens a page whose <video> plays, and sends that video to Paper Plane the way
// the popup does. Run by scripts/check-extension.sh, which sets up the page, the profile and the app.
// Usage: node check-in-chrome.mjs <chrome binary> <profile folder> <page URL>
import { spawn } from "node:child_process";
import { resolve } from "node:path";

const [chromePath, profile, pageURL] = process.argv.slice(2);
const expectedID = "napcmmglefncoieikecpjmdopmagllcg";

const chrome = spawn(chromePath, [
  "--headless=new", "--remote-debugging-pipe", "--enable-unsafe-extension-debugging",
  `--user-data-dir=${profile}`, "--use-mock-keychain", "--no-first-run", "--no-default-browser-check",
  "--disable-component-update", "--disable-background-networking", "--autoplay-policy=no-user-gesture-required",
  "about:blank",
], { stdio: ["ignore", "ignore", "ignore", "pipe", "pipe"] });

let nextID = 0;
let buffer = "";
const waiting = new Map();
chrome.stdio[4].setEncoding("utf8");
chrome.stdio[4].on("data", (chunk) => {
  buffer += chunk;
  for (let end = buffer.indexOf("\0"); end >= 0; end = buffer.indexOf("\0")) {
    const message = JSON.parse(buffer.slice(0, end));
    buffer = buffer.slice(end + 1);
    const pending = waiting.get(message.id);
    if (pending) {
      waiting.delete(message.id);
      message.error ? pending.reject(new Error(JSON.stringify(message.error))) : pending.resolve(message.result);
    }
  }
});

function call(method, params = {}, sessionId) {
  const id = ++nextID;
  chrome.stdio[3].write(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }) + "\0");
  return new Promise((resolve, reject) => waiting.set(id, { resolve, reject }));
}

async function evaluate(targetId, expression) {
  const { sessionId } = await call("Target.attachToTarget", { targetId, flatten: true });
  const { result, exceptionDetails } = await call("Runtime.evaluate",
    { expression, awaitPromise: true, returnByValue: true }, sessionId);
  if (exceptionDetails) {
    throw new Error(JSON.stringify(exceptionDetails));
  }
  return result.value;
}

const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
let failures = 0;
function expect(name, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  console.log(`${ok ? "ok" : "FAIL"}: ${name}${ok ? "" : ` — expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`}`);
  failures += ok ? 0 : 1;
}

try {
  const { id } = await call("Extensions.loadUnpacked", { path: resolve("dist") });
  expect("the extension's ID is the pinned one", id, expectedID);
  // A page loaded before the new worker has its listeners would go unseen.
  for (let tries = 0; tries < 50; tries += 1) {
    const { targetInfos } = await call("Target.getTargets");
    if (targetInfos.some((target) => target.type === "service_worker" && target.url.startsWith(`chrome-extension://${id}/`))) {
      break;
    }
    await sleep(100);
  }

  const { targetId: page } = await call("Target.createTarget", { url: pageURL });
  await sleep(4000); // the video loads and plays; its requests and reports reach the worker

  const { targetId: popup } = await call("Target.createTarget", { url: `chrome-extension://${id}/popup.html` });
  await sleep(500);
  const result = await evaluate(popup, `(async () => {
    const [tab] = await chrome.tabs.query({ url: "http://127.0.0.1/*" });
    const state = await chrome.runtime.sendMessage({ type: "state", tabId: tab.id });
    const sent = await chrome.runtime.sendMessage({ type: "send", tabId: tab.id });
    return { plan: state?.plan, label: state?.rows?.[0]?.label, sent };
  })()`);
  expect("one video is found", [result.plan, result.label], ["send", "Video file · 127.0.0.1"]);
  expect("Paper Plane takes it", result.sent, { ok: true });
  await sleep(500);
  expect("the page's video is paused", await evaluate(page, `document.querySelector("video").paused`), true);
} catch (error) {
  console.log(`FAIL: ${error.message}`);
  failures += 1;
} finally {
  chrome.kill();
}
process.exit(failures === 0 ? 0 : 1);
```

```bash
#!/bin/bash
# Checks the extension end to end without a TV: a headless Chrome with a throwaway profile loads
# extension/dist, opens a local page whose <video> plays, and sends it through paperplane-host to
# the app, which must take it, and the page's video must pause. Your own Chrome profile and its
# folders are left alone: the throwaway profile holds its own copy of the helper's manifest.
# Needs Google Chrome, the built app (see README) and the built extension (npm run build).
# Usage: scripts/check-extension.sh [path to Paper Plane.app]
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
APP="${1:-$PWD/build/DerivedData/Build/Products/Debug/Paper Plane.app}"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
HOST="$APP/Contents/Helpers/paperplane-host"
SOCKET="$HOME/Library/Application Support/Paper Plane/bridge.sock"
[[ -x "$HOST" ]] || { echo "No helper at $HOST. Build the app first (see README)." >&2; exit 2; }
[[ -x "$CHROME" ]] || { echo "No Chrome at $CHROME (set CHROME to another one)." >&2; exit 2; }
[[ -f extension/dist/manifest.json ]] || { echo "Build the extension first: cd extension && npm run build" >&2; exit 2; }

work="$(mktemp -d "${TMPDIR%/}/paperplane-extension-check.XXXXXX")"
mkdir -p "$work/profile/NativeMessagingHosts" "$work/site"
cat > "$work/profile/NativeMessagingHosts/dev.paperplane.host.json" <<JSON
{"name": "dev.paperplane.host", "description": "Paper Plane", "path": "$HOST", "type": "stdio",
 "allowed_origins": ["chrome-extension://napcmmglefncoieikecpjmdopmagllcg/"]}
JSON
cp testdata/media/h264_aac.mp4 "$work/site/film.mp4"
cat > "$work/site/player.html" <<HTML
<!doctype html><title>A film</title><video src="film.mp4" autoplay muted playsinline loop></video>
HTML

python3 scripts/serve-hls.py "$work/site" > "$work/port" &
server=$!
disown "$server" # stopped at the end without a "Terminated" line
until [[ -s "$work/port" ]]; do sleep 0.1; done
port="$(cut -d ' ' -f 2 "$work/port")"
cleanup() {
  kill "$server" 2>/dev/null
  osascript -e 'tell application id "dev.paperplane.app" to quit' >/dev/null 2>&1
  while pgrep -f "Paper Plane.app/Contents/MacOS" >/dev/null; do sleep 0.1; done
  rm -rf "$work"
}
trap cleanup EXIT

open "$APP" --args -PaperPlaneInstallsBrowserHosts NO
until [[ -S "$SOCKET" ]]; do sleep 0.1; done
cd extension && node check-in-chrome.mjs "$CHROME" "$work/profile" "http://127.0.0.1:$port/player.html"
```

Run: `scripts/check-extension.sh` (with the app built in Task 8)
Expected: four "ok:" lines (the extension's ID is the pinned one; one video is found; Paper Plane takes it; the page's video is paused).

- [ ] **Step 5: CI and ignores**

```diff
--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -48,6 +48,14 @@
           export PAPERPLANE_FFPROBE="$PWD/vendor/ffmpeg/bin/ffprobe"
           scripts/test-core.sh
 
+      - name: Extension tests, types and build
+        working-directory: extension
+        run: |
+          npm ci --ignore-scripts
+          npm test
+          npm run typecheck
+          npm run build
+
       - name: Build the app (warnings are errors)
         run: >
           xcodebuild -project app/PaperPlane.xcodeproj -scheme PaperPlane -configuration Release
```

```diff
--- a/.gitignore
+++ b/.gitignore
@@ -17,6 +17,6 @@
 /spikes/sony-test/build/
 /spikes/sony-test/streams/
 
-# Browser extension (later plans)
+# Browser extension: its dev tools (npm ci) and its build (npm run build)
 /extension/node_modules/
 /extension/dist/
```

- [ ] **Step 6: Commit**

```bash
git add extension/src extension/static extension/build.mjs extension/check-in-chrome.mjs scripts/make-icon.swift scripts/check-extension.sh .gitignore .github/workflows/ci.yml
git commit -m "feat(extension): the toolbar button, popup and service worker, checked end to end in Chrome"
```

### Task 11: How to use it, and the Sony checklist

**Files:**
- Modify: `README.md`, `docs/sony-test-results.md`

- [ ] **Step 1: README**

````diff
--- a/README.md
+++ b/README.md
@@ -17,6 +17,16 @@
 - If something goes wrong, Show Log reveals a log in `~/Library/Logs/Paper Plane/` for a bug report. It leaves out cookies, passwords and your home folder's path.
 - Your Mac stays awake while the TV plays, but closing a laptop's lid still puts it to sleep and stops the video.
 
+### Videos in Chrome or Brave
+
+1. Build the extension: `cd extension && npm ci --ignore-scripts && npm run build`.
+2. In Chrome or Brave, open `chrome://extensions`, turn on Developer mode, click Load unpacked and choose `extension/dist`.
+3. Open Paper Plane once, so the browser can reach it.
+
+Then play a video on a site and click the paper plane in the toolbar. It's grey until it finds a video; when it's sure which one you're watching, a click sends it, and when it isn't, it shows a count and lets you choose. Paper Plane comes forward to choose your TV, starts where the browser was, and the browser's video pauses. Live streams play live. YouTube comes in a later version.
+
+The extension passes the site's cookies for the video along to Paper Plane, which uses them only to fetch that video and never saves them.
+
 ## Development
 
 You need macOS 14 or later on Apple Silicon, Xcode 26 or later, and Homebrew.
@@ -32,7 +42,15 @@
 
 open app/PaperPlane.xcodeproj  # the app; run the PaperPlane scheme
 scripts/check-quit-cleanup.sh  # checks quitting never leaves ffmpeg or session files behind
+scripts/check-bridge.sh        # sends requests through the browser helper to the app
+
+cd extension && npm ci --ignore-scripts
+npm test && npm run typecheck  # the extension's tests
+npm run build && cd ..
+scripts/check-extension.sh     # the extension in a headless Chrome with a throwaway profile, through to the app
 ```
+
+The app installs the browser helper's manifest for Chrome and Brave each time it starts. Pass `-PaperPlaneInstallsBrowserHosts NO` when launching it to leave the browsers' folders alone; the check scripts do.
 
 Debug builds made before `scripts/build-ffmpeg.sh` use Homebrew's ffmpeg. Release builds need the bundled one. The subtitle burn-in tests run only with the bundled ffmpeg, since Homebrew's has no libass:
 
````

- [ ] **Step 2: The Milestone 3 checklist**

```diff
--- a/docs/sony-test-results.md
+++ b/docs/sony-test-results.md
@@ -130,3 +130,27 @@
 | M17 | An HDR film with burned-in subtitles (M7 or M8) | Note whether the subtitle text looks uncomfortably bright on the TV | Needs the owner at the TV |
 | M18 | Watching past 6:00, press back on the Sony's own remote to 0:30 | Note whether the TV plays from there or shows an error: Paper Plane deletes what's more than 5 minutes behind, and a seek made on the TV itself can't start a new session | Needs the owner at the TV |
 | M19 | With Full Keyboard Access on (System Settings → Keyboard), Tab through the remote | Each button (stop, skips, play, captions, AirPlay) shows a blue ring when it has focus | Needs the owner at the Mac |
+
+## Plan 4: videos from Chrome and Brave on the Sony
+
+Set up first: build and load the extension as the README says (Chrome's extensions page should show the ID `napcmmglefncoieikecpjmdopmagllcg`), then open Paper Plane once.
+
+Everything short of the TV and a real browser profile was checked on this Mac on 2026-10-16:
+- `scripts/check-bridge.sh` sends requests through the real helper to the app: a stream plays, a refused one names the site, and the helper starts a quit app.
+- `scripts/check-extension.sh` loads the extension into a headless Chrome with a throwaway profile. It finds a playing `<video>`, sends it through the helper to the app, which takes it, and the page's video pauses.
+- The ranking is tested against request sequences shaped like real sites. Recording real sites' requests needs a browser session, so B4 and B5 are where real sites are first seen.
+
+These rows need the owner at the TV or in their own browser.
+
+| # | Check | Expected | Result |
+|---|---|---|---|
+| B1 | In Chrome, play an HLS video (for example one of the streams on Apple's HLS examples page, developer.apple.com/streaming/examples) and click the paper plane in the toolbar | The button is blue once the video plays. Paper Plane comes forward; choose the Sony; the video plays on the TV from about where the browser was, and the browser's video pauses | Needs the owner at the TV |
+| B2 | A plain .mp4 video in a tab (any direct link to an .mp4 file) | As B1 | Needs the owner at the TV |
+| B3 | Seek far ahead and back in a B1 video from the remote | "Moving to…", then the TV plays from there (the site's link is fetched again with its cookies) | Needs the owner at the TV |
+| B4 | A news site with an ad before its video: wait for the article's video, then click | The article's video goes to the TV, not the ad | Needs the owner in their browser |
+| B5 | A page with two playing videos | The button shows "2"; the popup lists both, and either can be sent | Needs the owner in their browser |
+| B6 | A live stream (a news channel's live HLS) | The remote shows "Live" instead of the scrubber; the TV plays it live; the skip buttons are off | Needs the owner at the TV |
+| B7 | A YouTube video page: click the paper plane | A "!" on the button; the popup says "YouTube comes in a later version of Paper Plane." Whatever was playing carries on | Needs the owner in their browser |
+| B8 | Quit Paper Plane, then click the paper plane on a playing video | Paper Plane starts within a few seconds and takes the video | Needs the owner in their browser |
+| B9 | In Brave, repeat B1 | As B1 (the app installs the helper for Brave once Brave has been opened) | Needs the owner at the TV |
+| B10 | Leave a site's video for an hour or more, then send it | Either it plays, or the remote says "The site stopped the stream — click Paper Plane in your browser again" (its link expired) | Needs the owner at the TV |
```

- [ ] **Step 3: Commit**

```bash
git add README.md docs/sony-test-results.md
git commit -m "docs: sending videos from Chrome and Brave, and the Milestone 3 checklist for the Sony"
```
