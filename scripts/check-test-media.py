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
    "h264_aac_longgop.mp4": [("video", "h264", None), ("audio", "aac", 2)],
    "h264_aac_editlist.mp4": [("video", "h264", None), ("audio", "aac", 2)],
}

# file -> the video keyframes (presentation seconds, edit lists applied) it must have
KEYFRAMES = {
    "h264_aac_longgop.mp4": [0.0, 5.0, 10.0, 15.0],
    # -2.5 is the hidden lead-in the edit list skips.
    "h264_aac_editlist.mp4": [-2.5, 2.5, 7.5, 12.5],
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
    if name in KEYFRAMES:
        keyframes = video_keyframes(path)
        if keyframes != KEYFRAMES[name]:
            problems.append(f"video keyframes are {keyframes}, expected {KEYFRAMES[name]}")
    return problems


def video_keyframes(path):
    result = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "packet=pts_time,flags",
         "-of", "csv=p=0", str(path)],
        capture_output=True, text=True)
    return [round(float(pts), 3) for pts, flags, *_ in (line.split(",") for line in result.stdout.splitlines())
            if "K" in flags]


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
