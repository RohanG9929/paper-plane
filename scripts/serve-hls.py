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
