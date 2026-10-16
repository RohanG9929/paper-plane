# YouTube and Play Copied Link Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Play a YouTube video from the browser, and any copied link, on the TV, with a bundled yt-dlp that keeps itself up to date (Milestone 4), plus the release preparation that doesn't need the owner.

**Architecture:**
- **Resolving:** a page goes to yt-dlp (`-J`), and its answer becomes the one or two ffmpeg inputs Paper Plane already knows how to play: separate video and audio, through the web proxy.
- **Updating:** yt-dlp is chosen from the bundled copy and the updated copy by version. The updater checks GitHub at most once a day, verifies the file's SHA-256, and swaps it in atomically.
- **Playing:** the playback controller takes pages from the bridge (YouTube only) and links from the clipboard or a drop.

**Tech Stack:** Swift 6 (PaperPlaneCore, PaperPlaneUI, Swift Testing), the app target, shell scripts, the official `yt-dlp_macos` build.

**Spec:** `docs/superpowers/specs/2026-10-15-paper-plane-design.md` (§3.1 `YtDlp`, §5.1, §5.3, §5.4, §6, §8 row 4). Decisions taken overnight: `docs/superpowers/specs/2026-10-16-milestone-4-decisions.md` (1–14 while planning and building, 15–27 from the reviews).

**How this plan was run:** natively and test-first, each test watched failing before its code. It was written as files, interfaces and named tests rather than code; the code is in each task's commit, listed under **Built**. Each task's mutation checks are in the ledger (`.superpowers/sdd/2026-10-16-plan-5-youtube-and-links/progress.md`).

## Global Constraints

- **Platform:** macOS 14+, Apple Silicon. Swift 6 strict concurrency. Xcode 26 or later; builds pass with `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`.
- **Cookies:** cookies and auth headers live only in memory for one playback. They never go on a command line or into a file (§5.4).
- **Logs:** logs redact `Cookie`, `Authorization` and URL query strings (§5.4).
- **yt-dlp updates:** downloaded only from `github.com/yt-dlp/yt-dlp` releases and verified against `SHA2-256SUMS`. They're stored in `~/Library/Application Support/Paper Plane/bin/`, never inside the bundle, with checks at most once a day and right after a failed extraction (§5.3).
- **Failures:** a failed yt-dlp extraction triggers an update and one retry, then the error (§6).
- **Preferred formats** are those that can be copied: H.264/HEVC with AAC, up to 1080p. Separate video and audio are mapped together (§5.3).
- **Copy:** plain words in user-facing text. Never name the owner's employer.
- **Commits** use the repo-local identity and end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Nothing reaches the network in a test.** The real yt-dlp is never downloaded or run by this plan (decision 1).

## Review Focus

1. **YouTube refuses a video** (sign-in, private, region, age). The remote and the extension say YouTube's reason; the browser keeps playing. Pinned by `aPageThatCantBeResolvedSaysWhy` (Task 7).
2. **Stop, or another video, while yt-dlp is still working.** yt-dlp is stopped, the reply is "Stopped in Paper Plane." or "Another video took its place.", and no yt-dlp is left running. Pinned by `stoppingWhileResolvingStopsYtDlp` (Task 3) and `stoppingWhileAPageResolvesAnswersStopped` (Task 7).
3. **A hostile cookie value** (quotes, `#`, newlines, an option such as `--plugin-dirs`). It can't add a yt-dlp option. Pinned by `hostileCookiesStayOneArgument` (Task 2).
4. **An update cut short, oversized or with a wrong hash.** The working copy stays and no partial file is left. Pinned by `aMismatchedDownloadLeavesTheOldCopy` and `aFailedDownloadLeavesNothingBehind` (Task 5).
5. **A clipboard with no link, only spaces, or a `file:` or `javascript:` link.** A notice appears and what's playing carries on. Pinned by `copiedTextThatIsntALinkLeavesPlaybackAlone` (Task 7).

---

### Task 1: Decisions and plan

**Files:**
- Create: `docs/superpowers/specs/2026-10-16-milestone-4-decisions.md`
- Create: `docs/superpowers/plans/2026-10-16-plan-5-youtube-and-links.md`

- [ ] **Step 1: Commit both**

```bash
git add docs/superpowers/specs/2026-10-16-milestone-4-decisions.md docs/superpowers/plans/2026-10-16-plan-5-youtube-and-links.md
git commit -m "docs: plan 5 (YouTube and Play Copied Link) and the Milestone 4 decisions"
```

### Task 2: yt-dlp's command and its answer

**Files:**
- Create: `core/Sources/PaperPlaneCore/Pages/YtDlpCommand.swift`, `core/Sources/PaperPlaneCore/Pages/YtDlpOutput.swift`
- Create: `core/Tests/PaperPlaneCoreTests/YtDlpCommandTests.swift`, `core/Tests/PaperPlaneCoreTests/YtDlpOutputTests.swift`
- Create: `core/Tests/PaperPlaneCoreTests/Fixtures/yt-dlp/*.json`

**Interfaces:**
- **Produces:**
  - `YtDlpCommand.arguments(page: URL, cacheFolder: URL) -> [String]`
  - `YtDlpCommand.configuration(cookie: String?) -> String`
  - `YtDlpCommand.environment(base: [String: String]) -> [String: String]`
  - `YtDlpCommand.formats: String`
  - `ResolvedPage { input: ResolvedInput; startTime: Double? }`
  - `YtDlpOutput.page(from: Data, page: URL, fallbackTitle: String) throws -> ResolvedPage`
  - `YtDlpFailure: Error, Equatable` (`.unsupported`, `.failed(reason: String?)`, `.missing`, `.timedOut`)
  - `YtDlpFailure.reason(fromStderr:) -> String?`
- **Consumes:** `ResolvedInput`, `ResolvedInput.Input` (Plan 4), and a new `ResolvedInput.page: URL?`.

**Built:** 3cf49d1.

**Tests:**
- **The command:**
  - `argumentsEndWithThePageAfterADoubleDash`
  - `argumentsReadConfigurationOnlyFromStandardInput`
  - `formatsPreferH264AndAACUpTo1080pAndNeverDASH`
  - `noCookieMeansAnEmptyConfiguration`
  - `hostileCookiesStayOneArgument` (Python `shlex` round trip, run only when `/usr/bin/python3` exists)
  - `pathFindsHomebrewTools`
- **The answer:**
  - `twoFormatsBecomeTwoInputs`
  - `oneFormatBecomesOneInput`
  - `liveStreamIsHLS`
  - `aPlaylistGivesItsFirstEntry`
  - `anEmptyPlaylistIsUnsupported`
  - `dashAndOtherProtocolsAreRefused`
  - `onlyWebAddressesAreTaken`
  - `formatHeadersTravelWithTheirInput`
  - `titleAndStartTimeComeFromTheAnswer`
  - `theTabsTitleIsKeptWhenTheAnswerHasNone`
  - `reasonIsTheFirstSentenceOfTheLastError`
  - `unsupportedURLIsNamedAsSuch`

### Task 3: Running yt-dlp

**Files:**
- Modify: `core/Sources/PaperPlaneCore/Support/ProcessRunner.swift` (standard input, environment)
- Create: `core/Sources/PaperPlaneCore/Pages/YtDlp.swift`
- Test: `core/Tests/PaperPlaneCoreTests/YtDlpTests.swift` (a fake yt-dlp script)

**Interfaces:**
- **Produces:**
  - `ProcessRunner.run(_:arguments:input:environment:qualityOfService:)`
  - `YtDlp.resolve(page: URL, cookie: String?, executable: URL, cacheFolder: URL, timeLimit: Duration = .seconds(60)) async throws -> ResolvedPage`

**Built:** 055bc24.

**Tests:**
- `processRunnerFeedsStandardInput`
- `processRunnerSetsTheEnvironment`
- `resolvesThroughTheExecutable` (checks that the arguments and the configuration on stdin arrived)
- `aFailureCarriesYtDlpsReason`
- `aSilentYtDlpIsStoppedAtTheTimeLimit`
- `stoppingWhileResolvingStopsYtDlp`
- `theCookieIsNeverOnTheCommandLine`

### Task 4: Which yt-dlp runs

**Files:**
- Create: `core/Sources/PaperPlaneCore/Pages/YtDlpCopies.swift`
- Test: `core/Tests/PaperPlaneCoreTests/YtDlpCopiesTests.swift`

**Interfaces:**
- **Produces:**
  - `YtDlpVersion: Comparable` (`init?(_ text: String)`)
  - `YtDlpCopies(bundle: URL, support: URL, fallsBackToInstalled: Bool, environment:)`
  - `YtDlpCopies.current() -> (executable: URL, version: YtDlpVersion?)?`
  - `YtDlpCopies.updatedFolder: URL`

**Built:** 7bf61b0.

**Tests:**
- `versionsCompareAsNumbers`
- `versionsRejectAnythingElse`
- `theNewerCopyRuns`
- `theUpdatedCopyRunsWhenTheBundleHasNone`
- `onlyADevelopmentBuildFallsBackToAnInstalledYtDlp`
- `aCopyWithoutItsVersionLosesToOneWithIt`

### Task 5: The updater

**Files:**
- Create: `core/Sources/PaperPlaneCore/Pages/YtDlpUpdater.swift`
- Test: `core/Tests/PaperPlaneCoreTests/YtDlpUpdaterTests.swift`

**Interfaces:**
- **Produces:**
  - `ReleaseFetching` (`latestTag() async throws -> String`, `data(URL) async throws -> Data`, `download(URL, limit:) async throws -> URL`)
  - `YtDlpUpdater(copies:fetching:defaults:now:)`
  - `updateIfDue() async -> Bool` (once a day)
  - `update() async throws -> Bool` (now)
  - `YtDlpUpdater.releaseBase`
  - `GitHubReleases: ReleaseFetching` (the live one)
  - `SHA256Sums.digest(for: String, in: String) -> String?`

**Built:** fccd988.

**Tests:**
- `aNewerReleaseIsInstalled`
- `theSameVersionIsLeftAlone`
- `aMismatchedDownloadLeavesTheOldCopy`
- `aFailedDownloadLeavesNothingBehind`
- `aTagThatIsntAVersionIsRefused`
- `filesComeOnlyFromTheReleaseFolder`
- `checksAtMostOnceADay`
- `aFailedCheckIsTriedAgainNextLaunch`
- `theInstalledCopyIsExecutableInAPrivateFolder`
- `sumsLinesAreReadExactly`

### Task 6: A page's address decides about the local network

**Files:**
- Modify: `core/Sources/PaperPlaneCore/Media/ResolvedInput.swift` (`page: URL?`)
- Modify: `core/Sources/PaperPlaneCore/Serving/WebProxy.swift`
- Test: `core/Tests/PaperPlaneCoreTests/WebProxyTests.swift`

**Built:** 3af903f.

**Tests:**
- `aPublicPageCantReachTheLocalNetwork`
- `aLocalPageStillPlaysFromTheLocalNetwork`

### Task 7: Pages and links in the playback controller

**Files:**
- Modify: `core/Sources/PaperPlaneUI/PlaybackController.swift` (Environment `resolvePage` and `updateYtDlp`; `play(_ request:)`, `playLink(_:)`, `play(_ urls:)`)
- Create: `core/Sources/PaperPlaneCore/Pages/Links.swift` (`Links.webLink(in:)`, `Links.direct(_:)`, `Links.isYouTubePage(_:)`)
- Test: `core/Tests/PaperPlaneUITests/PagePlaybackTests.swift`, `core/Tests/PaperPlaneCoreTests/LinksTests.swift`

**Built:** c5abde1. What changed from the plan:
- `PlaybackError.message(for:fromTheWeb:)` became `message(for:origin:)`, with a `VideoOrigin` (file, browser, link), so a copied link's messages say "choose Play Copied Link again".
- `Links` also has `placeholderTitle(for:)`.
- `YtDlpFailure.failed` carries yt-dlp's redacted stderr for the failure log.

**Tests:**
- `aYouTubePagePlaysWhatYtDlpFinds`
- `onlyYouTubePagesAreTakenFromTheBrowser`
- `aPageThatCantBeResolvedSaysWhy`
- `aFailedResolveUpdatesAndTriesOnceMore`
- `aMissingYtDlpIsInstalledThenUsed`
- `aTimedOutResolveIsntRetried`
- `stoppingWhileAPageResolvesAnswersStopped`
- `aNewerPageReplacesOneStillResolving`
- `theAnswersTitleReplacesTheTabs`
- `aLinksOwnStartTimeIsUsed`
- `aCopiedLinkToAPagePlays`
- `aCopiedLinkToAPlaylistFilePlaysDirectly`
- `copiedTextThatIsntALinkLeavesPlaybackAlone`
- `aDroppedWebLinkPlays`
- `ytDlpFailuresAreLoggedRedacted`

### Task 8: Menu, remote and app

**Files:**
- Modify: `core/Sources/PaperPlaneUI/StatusMenu.swift`, `RemoteView.swift` (`RemoteActions.playCopiedLink`, DropZone button)
- Modify: `app/PaperPlane/PaperPlaneApp.swift`, `StatusItem.swift`, `RemoteWindow.swift`
- Modify: `scripts/embed-ffmpeg.sh` → `scripts/embed-tools.sh`, `app/PaperPlane.xcodeproj/project.pbxproj`
- Tests: `StatusMenuTests`, `RemoteSnapshotTests` (renders)

**Built:** 251e63c.

**Tests:**
- `menuOffersPlayCopiedLink`
- the idle and welcome renders, light and dark

### Task 9: Scripts and release

**Built:** 5bde80e. `scripts/check-fetch-yt-dlp.sh` checks five things against a stand-in release; `embed-ffmpeg.sh` became `embed-tools.sh`.

**Files:**
- Create: `scripts/fetch-yt-dlp.sh`, `scripts/make-release.sh`
- Modify: `scripts/check-quit-cleanup.sh`, `scripts/check-bridge.sh`, `extension/check-in-chrome.mjs` (pass `-PaperPlaneUpdatesYtDlp NO`)
- Create: `scripts/check-fetch-yt-dlp.sh` (against a local stand-in release; no network)

### Task 10: Docs

**Built:** faf68de.

**Files:**
- Modify: `README.md`, `docs/sony-test-results.md` (rows Y1–Y8), `extension/src/view.ts` (wording)
- Modify: this plan, so it matches what was built

### Task 11: Review fixes

What the reviews (Opus whole-branch, code review at xhigh, security review, simplify) found and what changed; decisions 15–27 say why.

**Security:**
- yt-dlp starts as its own responsible process, in the temporary folder (`Support/DisclaimedSpawn.swift`, `ProcessRunner.run(…, disclaimsResponsibility:)`).
- Local fetches need every address of a host to be local (`LocalAddresses.isWhollyLocal`, `decide(_:all:)`).

**Correctness:**
- YouTube pages go to yt-dlp as www.youtube.com (`Links.forYtDlp`), and it gets the app's ffmpeg.
- `-S res:1080` replaces the height caps, and only readable protocols can be chosen (`YtDlpCommand.readable`).
- Offline is said before yt-dlp runs. `.unreachable` and `.needsJavaScriptRuntime` get their own words and aren't retried; nor is `.unsupported`.
- Failure-time update checks happen at most hourly (`YtDlpUpdater.updateAfterFailure`).
- A release tag is kept exactly as released.
- A stalled site's first answer stops being awaited on cancel.
- Leftover downloads go; nested playlists and `multi_video` give their first video.
- `make-release.sh` creates `build/` first.

**Simplify:**
- One `begin(title:from:_:)` and one `failedToStart` in the controller.
- `PlaybackController.refusal(of:)`, used by the app as well.
- `ToolPaths.find`, `homebrewFolders` and `helpers(inBundle:)` are reused.
- `PlayRequest.tidyTitle` and `fallbackTitle(for:otherwise:)` are shared.
- `Links.webLink` backs the bridge, links and yt-dlp's answers.
- `VideoFiles.isVideo(extension:)` decides direct links.
- One `receive` loop in the downloader, and an explicit `UpstreamFetch.RedirectPolicy`.
- The page's locality is judged once.
- ⌘V belongs to the remote's window.
- The build re-copies a tool only when it changed.

**Tests added:**
- `youTubePagesGoToYtDlpAsWwwYouTube`, `aYouTubePageReachesYtDlpAsWwwYouTube`, `argumentsNameTheAppsFFmpeg`
- `formatsPreferH264AndAACUpTo1080pAndOnlyWhatFFmpegReads`
- `nestedPlaylistsAndMultiVideosGiveTheirFirstVideo`, `unreachableSitesAreNamedAsSuch`, `aMissingJavaScriptRuntimeIsNamed`, `anHTTPErrorKeepsItsWordsOnly`
- `aFailureChecksAgainOnlyAfterAnHour`, `leftoverDownloadsAreRemoved`, `aSilentSiteIsGivenUpOnWhenCancelled`
- `aDisclaimedChildRunsLikeAnyOther`, `cancellingADisclaimedChildStopsIt`, `ytDlpIsItsOwnResponsibleProcess`
- `anyLocalAddressRefusesButAllAreNeededToAllow`
- `offlineSaysSoBeforeAskingYtDlp`, `failuresAnUpdateCantHelpArentRetried`, `anUnsupportedLinkIsntRetried`, `aReleaseWithoutYtDlpSaysItsMissing`
- the version-tag case in `versionsCompareAsNumbers`
