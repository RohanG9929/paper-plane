# Sony Test Results (Milestone 0)

Answers the open questions in the design spec (§4.1 output profile, §8 Milestone 0, §10 risks) before
any product playback code is written.

**Date:** 2026-10-15
**TV model:** Sony XBR-55X950G (AirPlay 2)
**macOS version:** 27.0.1
**Mac's LAN IP during the test:** 192.168.0.13   **TV's LAN IP (from the server log):** 192.168.0.20

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
| 0 | Who fetches the stream | While stream 1 plays on the TV, do the segment requests in Terminal A come from the TV's IP or the Mac's? | **The TV.** The Mac fetched the playlist once; the TV fetched the playlist, `init.mp4` and every segment, and re-fetched segments after seeks. |
| 1 | Baseline H.264 + AAC | Plays smoothly with sound; −30 s / +30 s seeks work | **Works.** Plays on the TV; −30 s, +30 s and Seek to start all work. |
| 2 | HEVC + AAC | Plays | **Works.** |
| 3 | H.264 + AC3 5.1 | Plays with sound. Does the TV (or soundbar) show Dolby Digital / 5.1, or plain stereo? | **Fails.** The TV fetches the first segment, then drops back to its AirPlay home screen ("Choose This Device"). |
| 4 | H.264 + E-AC3 5.1 | Same as 3 (Dolby Digital Plus) | **Fails**, same way as 3. |
| 3b | H.264 + AC3 5.1, MPEG-TS segments (added during the test) | Same as 3, in the older segment format | **Fails**, same way as 3. |
| 4b | H.264 + E-AC3 5.1, MPEG-TS segments (added during the test) | Same as 4, in the older segment format | **Fails**, same way as 3. |
| 5 | WebVTT subtitles | "Subtitle at N seconds" text appears on the TV; Subtitles on/off toggles it | **Works.** Text shows on the TV; toggling off and on works. |
| 6 | HDR10 HEVC (4K) | Plays; the TV shows its HDR indicator; colours look normal | **Plays, but no HDR indicator** appeared (owner unsure whether this model shows one during AirPlay). |
| 7a | Live: start position | Load stream 7 about 2 min after starting `start-live.sh`. Does playback begin at 0 s or near the live edge? | **Near the live edge.** Loaded with ~33 segments available; the TV started at segment 28 (and at 62 of ~66 on the second try). |
| 7b | Live: seek to start | Does "Seek to start" go back to 0 s? | **Works.** The TV jumps to the start (fetches segment 0). AVPlayer's seek completion still reported `finished: false`. |
| 7c | Live: seeking within | Do −30 s / +30 s work inside the produced part? | **Works.** |
| 7d | Live: growth | Does playback carry on smoothly as new segments appear? | **Works.** The TV fetches each new segment as it appears. |
| 8 | TV selected before play | With nothing loaded, pick the Sony in the AirPlay menu. Does "On TV" switch to YES before you press Load? | **No.** Picking the Sony showed a PIN prompt (the TV displayed the PIN); "On TV" stayed no until something was loaded. |
| 9 | Reconnect without picker | Quit Sony Test, relaunch, press Load without touching the AirPlay menu. Does it play on the TV? | **No.** It played locally on the Mac (the Mac fetched the segments); the TV took over only after re-picking it in the AirPlay menu. |

## Decisions

Filled in by Plan 1 Task 9 from the results above.

- `OutputProfile.default.surround`: **false**. Rows 3, 4, 3b and 4b all fail; surround tracks become stereo AAC.
- `OutputProfile.default.hdr`: **true**. Row 6 shows HDR10 HEVC plays when copied; the missing HDR indicator is unconfirmed either way. Tone-mapping by default would make every HDR file fail (Homebrew's ffmpeg has no zimg) and cost a full 4K re-encode. "Convert HDR to SDR" stays as a Settings override. Revisit with a master playlist carrying `VIDEO-RANGE=PQ` (final review recommendation).
- Subtitle approach for Plan 3: **WebVTT track** (row 5 works). Only picture-based subtitles get burned in.
- Live-playlist start for Plan 2: **seek to 0 after load** (7a starts near the live edge; 7b works). Don't trust AVPlayer's seek completion `finished` flag during AirPlay: it reported false although the TV seeked.
- Stream server binding for Plan 2: **LAN address required** (row 0: the TV fetches every segment itself).
- TV selection UX for Plan 2: **start paused, then check `isExternalPlaybackActive`** (row 8), and **the remote opens with the picker each time** (row 9). With no TV active, AVPlayer plays on the Mac, so Paper Plane must not start playback until a TV is active. The first pairing shows a PIN on the TV.

## Plan 2 re-test: master playlists

Optional, about 5 minutes. Run `spikes/sony-test/make-retest-playlists.sh` once, then follow "How to run" above and load the R streams. Start `start-live.sh` about 2 minutes before R4.

All four streams already play on the Mac's own AVPlayer (checked 2026-10-15). Only the TV's behaviour is unknown.

| # | Stream / check | What to look for | Result |
|---|---|---|---|
| R1 | H.264 + AC3 5.1 behind a master playlist with `CODECS="avc1.640028,ac-3"` | Plays with sound? Or drops to the AirPlay home screen like row 3? | Needs the owner at the TV |
| R2 | H.264 + E-AC3 5.1 behind a master playlist with `CODECS="avc1.640028,ec-3"` | Same as R1 | Needs the owner at the TV |
| R3 | HDR10 HEVC (4K) behind a master playlist with `VIDEO-RANGE=PQ` and `FRAME-RATE` | Plays? Does the TV show its HDR indicator now? | Needs the owner at the TV |
| R4 | Live, master playlist with `#EXT-X-START:TIME-OFFSET=0` | Load about 2 min after starting `start-live.sh`. Does Terminal A show the TV fetching segment 0 first (start at 0 s), or a late segment (live edge)? | Needs the owner at the TV |

### Re-test decisions

Filled in by Plan 2 Task 9 from the results above.

- Surround: not run; defaults kept (off). If R1 and R2 both play with sound, apply Plan 2 Task 9 Step 6's surround changes.
- HDR: not run; defaults kept (HDR plans open the master playlist). If R3 doesn't play, apply Plan 2 Task 10 Step 3's HDR fallback.
- Live start: not run; defaults kept (the app seeks to 0 after the TV takes over). If R4 starts at 0 s, `PlaybackController.seeksToStartOnTV` can become `false`.

## Plan 2: first playback through Paper Plane

Build and run the app (`open app/PaperPlane.xcodeproj`, PaperPlane scheme, ⌘R). To watch what it does: `log stream --info --predicate 'subsystem == "dev.paperplane.app"'`. For a five-minute copy-mode MKV (H.264 copied, AC3 5.1 converted to stereo AAC):

```bash
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=1920x1080:rate=24:duration=300" -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=300" -c:v libx264 -preset veryfast -pix_fmt yuv420p -g 48 -c:a ac3 -b:a 448k -ac 6 ~/Desktop/paperplane-five-minutes.mkv
```

Everything up to the TV was checked on the Mac on 2026-10-15: Open With reaches the app, the stream is served on the LAN address behind the token, and quitting at any moment leaves no ffmpeg or session files (`scripts/check-quit-cleanup.sh`). These rows need the owner at the TV.

| # | Check | Expected | Result |
|---|---|---|---|
| P1 | Launch | Paper plane icon in the menu bar; the remote opens with "Welcome to Paper Plane" (first launch only), then "Drop a video here". Note any Local Network prompt (answer Allow) | Needs the owner at the TV |
| P2 | Drop the five-minute MKV on the remote | "Getting your video ready…", then "Choose your TV to start" with the AirPlay button ringed in blue. Nothing plays on the Mac | Needs the owner at the TV |
| P3 | Pick the Sony with the remote's AirPlay button | Plays on the TV within a few seconds, from the start. The remote says "Playing on your TV", the artwork shows a frame of the video, and the clock counts up | Needs the owner at the TV |
| P4 | Pause and Play on the remote (or Space); then pause with the TV's own remote | The TV follows. The remote's button follows the TV | Needs the owner at the TV |
| P5 | Skip back and forward 10 s (or ← →); drag the scrubber within the lighter "converted" part | The TV jumps there. (Seeking past what's converted comes with Milestone 2) | Needs the owner at the TV |
| P6 | Move the volume slider | Note whether the TV's volume follows (AirPlay may leave volume to the TV) | Needs the owner at the TV |
| P7 | Stop (■ or ⌘.) | The TV leaves the video. The remote says "Drop a video here" | Needs the owner at the TV |
| P8 | Drop `testdata/media/hevc_hdr10_aac.mkv`, pick the Sony | Plays (10 s). Note whether the HDR indicator shows | Needs the owner at the TV |
| P9 | Drop `testdata/media/vp9_opus.webm`, pick the Sony | Plays (re-encoded with VideoToolbox) | Needs the owner at the TV |
| P10 | In Finder, Open With → Paper Plane on the five-minute MKV | The remote comes forward; then as P2 and P3 | Needs the owner at the TV |
| P11 | During playback, turn the TV off, or end AirPlay from Control Center | The remote says "Your TV disconnected. Choose it again to continue". The Mac stays silent. Picking the TV again resumes where it was | Needs the owner at the TV |
| P12 | Quit from the menu during playback | `pgrep -fl ffmpeg` prints nothing; `ls ~/Library/Caches/Paper\ Plane/sessions/` is empty | Checked on the Mac (no TV needed): clean |

## Plan 3: seeking, tracks and subtitles on the Sony

For these, a 30-minute film with two audio tracks (English 440 Hz, French 660 Hz), an English subtitle track, and a sidecar `.srt` with a line every 30 seconds:

```bash
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=1920x1080:rate=24:duration=1800" -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=1800" -f lavfi -i "sine=frequency=660:sample_rate=48000:duration=1800" -i testdata/media/sample.srt -map 0:v -map 1:a -map 2:a -map 3:s -c:v libx264 -preset veryfast -pix_fmt yuv420p -g 48 -c:a aac -b:a 128k -ac 2 -c:s srt -metadata:s:a:0 language=eng -metadata:s:a:1 language=fra -metadata:s:s:0 language=eng ~/Desktop/paperplane-thirty-minutes.mkv
```

```bash
python3 -c 'for i in range(60): s = i * 30; print(f"{i + 1}\n00:{s // 60:02}:{s % 60:02},000 --> 00:{s // 60:02}:{s % 60 + 20:02},000\nLine {i + 1}, at {s // 60}:{s % 60:02}\n")' > ~/Desktop/paperplane-thirty-minutes.en.srt
```

Everything up to the TV was checked on the Mac on 2026-10-16 (the controller's tests play each case through the real pipeline on this Mac). These rows need the owner at the TV.

| # | Check | Expected | Result |
|---|---|---|---|
| M1 | Play the 30-minute film on the Sony; drag the scrubber to about 20:00 | The status says "Moving to 20:00…", and within about 3 s the TV plays from there | Needs the owner at the TV |
| M2 | Then drag back to 0:30 | "Moving to 0:30…", and the TV plays from there | Needs the owner at the TV |
| M3 | Skip back and forward 10 s a few times | Instant jumps, no "Moving to" | Needs the owner at the TV |
| M4 | Captions menu (speech bubble beside AirPlay) → Audio → French | "Switching to French (Stereo)…"; the tone goes higher, at the same place in the film | Needs the owner at the TV |
| M5 | Captions menu → Subtitles → English, then Off | "Paper Plane test subtitle one/two" show at 0:01–0:08 (seek back to 0:00 to see them); Off removes them without "Moving to" | Needs the owner at the TV |
| M6 | With the sidecar `.srt` beside the film, play it again; choose "English — paperplane-thirty-minutes.en.srt" | "Line N, at m:ss" shows on the TV at the matching time, also after a far seek | Needs the owner at the TV |
| M7 | Settings… → Always draw subtitles into the picture; choose English subtitles | "Adding subtitles…"; the text is part of the picture (the TV's own subtitle setting can't hide it). Turn the setting off afterwards | Needs the owner at the TV |
| M8 | A film of your own with Blu-ray (PGS) subtitles: choose them | "Adding subtitles…"; the subtitles are burned in. (No PGS test file can be generated, so this is the only check) | Needs the owner at the TV |
| M9 | Media keys and Control Center | The play/pause key pauses the TV; Control Center shows the title and artwork and its scrubber seeks | Needs the owner at the TV |
| M10 | Leave the Mac idle past its sleep time while the TV plays; then pause and wait again | Keeps playing (`pmset -g assertions` lists "Paper Plane is playing a video on your TV"); once paused the Mac may sleep | Needs the owner at the TV |
| M11 | During playback turn Wi-Fi off and on (or switch networks, with the TV on the same one) | "Reconnecting…", then the TV plays on from where it was | Needs the owner at the TV |
| M12 | Drag the film onto the paper plane in the menu bar | The remote opens and prepares it | Needs the owner at the Mac |
| M13 | The menu bar menu during playback | The film's name, Pause, Stop, Audio and Subtitles submenus that switch tracks; Settings… opens Settings | Needs the owner at the Mac |
| M14 | Drop `testdata/media/corrupt.mkv` | "Paper Plane couldn't read this file…" with Show Log; Show Log reveals a log in `~/Library/Logs/Paper Plane/` without your home folder's path in it | Needs the owner at the Mac |
| M15 | After the first time the Sony was chosen, play another film | "Choose your TV to start" and the ringed AirPlay button, without the blue explanation box | Needs the owner at the TV |
| M16 | A 4K film of your own with Blu-ray (PGS) subtitles: choose them | Burned in at the bottom of the full picture, not a quarter-size corner (the subtitles are scaled to the video). Seek into the middle of a line: it may be missing until the next one, which is expected | Needs the owner at the TV |
| M17 | An HDR film with burned-in subtitles (M7 or M8) | Note whether the subtitle text looks uncomfortably bright on the TV | Needs the owner at the TV |
| M18 | Watching past 6:00, press back on the Sony's own remote to 0:30 | Note whether the TV plays from there or shows an error: Paper Plane deletes what's more than 5 minutes behind, and a seek made on the TV itself can't start a new session | Needs the owner at the TV |
| M19 | With Full Keyboard Access on (System Settings → Keyboard), Tab through the remote | Each button (stop, skips, play, captions, AirPlay) shows a blue ring when it has focus | Needs the owner at the Mac |

## Plan 4: videos from Chrome and Brave on the Sony

Set up first: build and load the extension as the README says (Chrome's extensions page should show the ID `napcmmglefncoieikecpjmdopmagllcg`), then open Paper Plane once.

Everything short of the TV and a real browser profile was checked on this Mac on 2026-10-16:
- `scripts/check-bridge.sh` sends requests through the real helper to the app: a stream plays, a refused one names the site, and the helper starts a quit app.
- `scripts/check-extension.sh` loads the extension into a headless Chrome with a throwaway profile. It finds a playing `<video>`, sends it through the helper to the app, which takes it, and the page's video pauses.
- The ranking is tested against request sequences shaped like real sites. Recording real sites' requests needs a browser session, so B4 and B5 are where real sites are first seen.

These rows need the owner at the TV or in their own browser.

| # | Check | Expected | Result |
|---|---|---|---|
| B1 | In Chrome, play an HLS video (for example one of the streams on Apple's HLS examples page, developer.apple.com/streaming/examples) and click the paper plane in the toolbar | The button is blue once the video plays. Paper Plane comes forward; choose the Sony; the video plays on the TV from about where the browser was, and the browser's video pauses | Needs the owner at the TV |
| B2 | A plain .mp4 video in a tab (any direct link to an .mp4 file) | As B1 | Needs the owner at the TV |
| B3 | Seek far ahead and back in a B1 video from the remote | "Moving to…", then the TV plays from there (the site's link is fetched again with its cookies) | Needs the owner at the TV |
| B4 | A news site with an ad before its video: wait for the article's video, then click | The article's video goes to the TV, not the ad | Needs the owner in their browser |
| B5 | A page with two playing videos | The button shows "2"; the popup lists both, and either can be sent | Needs the owner in their browser |
| B6 | A live stream (a news channel's live HLS) | The remote shows "Live" instead of the scrubber; the TV plays it live; the skip buttons are off | Needs the owner at the TV |
| B7 | A YouTube video page: click the paper plane | A "!" on the button; the popup says "YouTube comes in a later version of Paper Plane." Whatever was playing carries on | Needs the owner in their browser |
| B8 | Quit Paper Plane, then click the paper plane on a playing video | Paper Plane starts within a few seconds and takes the video | Needs the owner in their browser |
| B9 | In Brave, repeat B1 | As B1 (the app installs the helper for Brave once Brave has been opened) | Needs the owner at the TV |
| B10 | Leave a site's video for an hour or more, then send it | Either it plays, or the remote says "The site stopped the stream — reload the page, then click Paper Plane again" (its link expired) | Needs the owner at the TV |
| B11 | Note any site whose video the button never finds, and any that fails | Worth a bug report each: Paper Plane doesn't offer DASH-only sites yet, and players that hide their `<video>` (in a shadow root) don't pause or start where they were | Needs the owner in their browser |
