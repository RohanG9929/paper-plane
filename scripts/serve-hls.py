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

    def admit(self):
        """Test hooks that act like a site: /status/<code>/… answers with that status,
        /cookie/<name>=<value>/… serves the rest of the path only with that cookie, and
        /redirect/<host:port>/… redirects to the rest of the path on that host."""
        if self.server.log:
            with open(self.server.log, "a") as log:
                log.write(f"{self.headers.get('Host')} {self.path} cookie={self.headers.get('Cookie')}\n")
        parts = self.path.split("/", 3)  # "", hook, argument, rest
        if len(parts) >= 3 and parts[1] == "redirect":
            self.send_response(302)
            self.send_header("Location", f"http://{parts[2]}/" + (parts[3] if len(parts) > 3 else ""))
            self.end_headers()
            return False
        if len(parts) >= 3 and parts[1] == "status":
            self.send_error(int(parts[2]))
            return False
        if len(parts) >= 3 and parts[1] == "cookie":
            cookies = [cookie.strip() for cookie in self.headers.get("Cookie", "").split(";")]
            if parts[2] not in cookies:
                self.send_error(403)
                return False
            self.path = "/" + (parts[3] if len(parts) > 3 else "")
        return True

    def do_GET(self):
        if self.admit():
            super().do_GET()

    def do_HEAD(self):
        if self.admit():
            super().do_HEAD()

    def log_message(self, format, *args):
        if self.server.verbose:
            super().log_message(format, *args)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory")
    parser.add_argument("--bind", default="127.0.0.1", help="use 0.0.0.0 so a TV can connect")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--verbose", action="store_true", help="log every request")
    parser.add_argument("--log", help="append each request's host, path and cookie to this file")
    options = parser.parse_args()

    handler = functools.partial(Handler, directory=options.directory)
    server = http.server.ThreadingHTTPServer((options.bind, options.port), handler)
    server.verbose = options.verbose
    server.log = options.log
    print(f"PORT {server.server_address[1]}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
