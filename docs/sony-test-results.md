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
