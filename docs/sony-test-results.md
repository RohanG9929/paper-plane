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
