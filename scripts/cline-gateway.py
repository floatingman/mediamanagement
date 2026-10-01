#!/usr/bin/env python3
"""cline-gateway — OpenAI-shape fixer for the Cline API.

Cline (api.cline.bot/api/v1) wraps every chat completion in a non-standard
{"data": {"choices": [...]}} envelope, which litellm/cognee cannot parse.
This proxy forwards requests to Cline verbatim and unwraps that envelope on
the way back, presenting a standard OpenAI-compatible /v1/chat/completions.

Stdlib only (no pip). Non-streaming responses are JSON-unwrapped; SSE
streaming responses have each "data: {...}" line rewritten the same way.

Env:
  CLINE_UPSTREAM  upstream base (default https://api.cline.bot/api/v1)
  PORT            listen port (default 8123)

Run: python3 cline-gateway.py   (compose: cline-gateway in utilities.yaml)
"""
import json
import os
import sys
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = os.environ.get("CLINE_UPSTREAM", "https://api.cline.bot/api/v1").rstrip("/")

PORT = int(os.environ.get("PORT", "8123"))

HOP_HEADERS = {"connection", "keep-alive", "transfer-encoding", "te",
               "trailers", "proxy-authorization", "proxy-authenticate",
               "upgrade", "host", "content-length"}


def unwrap(obj):
    """Strip Cline's {"data": ..., "success": ...} envelope when present.
    Only fires when the response lacks a top-level 'choices'/'error' and
    carries a dict under 'data' — standard OpenAI bodies pass through."""
    if (isinstance(obj, dict) and "choices" not in obj and "error" not in obj
            and isinstance(obj.get("data"), dict)):
        return obj["data"]
    return obj


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("[cline-gateway] %s %s\n" % (self.address_string(), fmt % args))

    def _proxy(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        url = UPSTREAM + self.path.replace("/v1", "", 1) if self.path.startswith("/v1") else UPSTREAM + self.path

        req = urllib.request.Request(url, data=body, method=self.command)
        for k, v in self.headers.items():
            if k.lower() not in HOP_HEADERS:
                req.add_header(k, v)

        try:
            upstream = urllib.request.urlopen(req, timeout=600)
        except urllib.error.HTTPError as e:
            upstream = e  # 4xx/5xx bodies still matter to the client
        except Exception as e:
            self.send_response(502)
            self.send_header("Content-Type", "application/json")
            msg = json.dumps({"error": {"message": f"gateway upstream failure: {e}"}}).encode()
            self.send_header("Content-Length", str(len(msg)))
            self.end_headers()
            self.wfile.write(msg)
            return

        status = upstream.getcode()
        is_sse = "text/event-stream" in (upstream.headers.get("Content-Type") or "")

        self.send_response(status)
        for k, v in upstream.headers.items():
            if k.lower() not in HOP_HEADERS and k.lower() != "content-length":
                self.send_header(k, v)

        if is_sse or self.command == "GET":
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for line in upstream:
                out = line
                if line.startswith(b"data: ") and line.strip() != b"data: [DONE]":
                    try:
                        out = b"data: " + json.dumps(unwrap(json.loads(line[6:]))).encode() + b"\n\n"
                    except json.JSONDecodeError:
                        pass
                self.wfile.write(("%x\r\n" % len(out)).encode() + out + b"\r\n")
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
            return

        raw = upstream.read()
        try:
            fixed = json.dumps(unwrap(json.loads(raw))).encode()
        except (json.JSONDecodeError, UnicodeDecodeError):
            fixed = raw  # not JSON (auth pages etc.) — pass through untouched
        self.send_header("Content-Length", str(len(fixed)))
        self.end_headers()
        self.wfile.write(fixed)

    do_GET = do_POST = do_DELETE = do_PUT = _proxy


if __name__ == "__main__":
    print(f"cline-gateway listening on :{PORT} -> {UPSTREAM}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
