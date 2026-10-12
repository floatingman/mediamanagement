#!/usr/bin/env python3
"""zai-gateway — structured-output fixer for the z.ai GLM API.

z.ai's chat completions silently ignore response_format {"type":"json_schema"}
and answer in prose, which breaks every OpenAI-SDK .parse() consumer (Mealie's
AI providers validate the reply against the schema and fail with json_invalid).
This proxy rewrites those requests into what z.ai does honor — response_format
{"type":"json_object"} plus the schema spelled out in a system instruction —
and relays the upstream response untouched.

Auth forwards verbatim (same model as cline-gateway). Stdlib only (no pip).
Non-streaming and SSE streaming both pass through byte-for-byte; only the
request body is rewritten.

Env:
  ZAI_UPSTREAM  upstream base (default https://api.z.ai/api/coding/paas/v4;
                switch to .../api/paas/v4 for a pay-as-you-go key)
  PORT          listen port (default 8124)

Run: python3 zai-gateway.py   (compose: zai-gateway in utilities.yaml)
"""
import json
import os
import sys
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = os.environ.get("ZAI_UPSTREAM", "https://api.z.ai/api/coding/paas/v4").rstrip("/")

PORT = int(os.environ.get("PORT", "8124"))

HOP_HEADERS = {"connection", "keep-alive", "transfer-encoding", "te",
               "trailers", "proxy-authorization", "proxy-authenticate",
               "upgrade", "host", "content-length"}

SCHEMA_INSTRUCTION = (
    "You MUST reply with a single JSON object and nothing else — no prose, "
    "no markdown fences, no code blocks. The object must strictly conform to "
    "this JSON Schema (exact property names, nesting, and types): {schema}"
)


def rewrite_body(body):
    """Rewrite json_schema structured-output requests for z.ai. Returns
    (bytes, rewritten?) — non-chat or non-JSON bodies pass through."""
    try:
        data = json.loads(body)
    except (json.JSONDecodeError, UnicodeDecodeError, ValueError):
        return body, False
    if not isinstance(data, dict):
        return body, False

    rf = data.get("response_format")
    if not (isinstance(rf, dict) and rf.get("type") == "json_schema"):
        return body, False

    schema = (rf.get("json_schema") or {}).get("schema") or {}
    data["response_format"] = {"type": "json_object"}
    instruction = SCHEMA_INSTRUCTION.format(schema=json.dumps(schema))

    messages = data.get("messages")
    if not isinstance(messages, list) or not messages:
        return body, False

    first = messages[0]
    if first.get("role") == "system":
        content = first.get("content")
        if isinstance(content, str):
            first["content"] = instruction + "\n\n" + content
        elif isinstance(content, list):
            content.insert(0, {"type": "text", "text": instruction})
        else:
            first["content"] = instruction
    else:
        messages.insert(0, {"role": "system", "content": instruction})

    return json.dumps(data).encode(), True


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("[zai-gateway] %s %s\n" % (self.address_string(), fmt % args))

    def _proxy(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        rewritten = False
        if body and self.command == "POST" and self.path.rstrip("/").endswith("/chat/completions"):
            body, rewritten = rewrite_body(body)
        url = UPSTREAM + self.path.replace("/v1", "", 1) if self.path.startswith("/v1") else UPSTREAM + self.path

        req = urllib.request.Request(url, data=body, method=self.command)
        for k, v in self.headers.items():
            if k.lower() not in HOP_HEADERS:
                req.add_header(k, v)
        if rewritten:
            req.add_header("Content-Type", "application/json")

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
                self.wfile.write(("%x\r\n" % len(line)).encode() + line + b"\r\n")
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
            return

        raw = upstream.read()
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    do_GET = do_POST = do_DELETE = do_PUT = _proxy


if __name__ == "__main__":
    print(f"zai-gateway listening on :{PORT} -> {UPSTREAM}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
