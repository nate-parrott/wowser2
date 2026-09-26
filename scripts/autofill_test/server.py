#!/usr/bin/env python3
"""Autofill playground server (stdlib only).

    python3 scripts/autofill_test/server.py [--port 8765]

Serves the static scenario pages in this directory on 127.0.0.1.

  GET  <any static file>   -> the file (no caching, so edits show up on reload)
  POST /api/login          -> JSON {"ok": true, "user": ...} after ~300 ms.
                              Password "wrong" -> 401 {"ok": false} (to test "don't save failed logins").
  POST /api/<anything else>-> JSON {"ok": true} after ~300 ms.
  POST <any other path>    -> an HTML "Submitted" page echoing the decoded fields
                              (password-ish fields masked, with a reveal toggle).

Two hostnames for the same server: http://localhost:PORT and http://127.0.0.1:PORT
are different origins/hosts to a browser, so you can test credential matching across
hosts (see cross-host.html). "localhost" usually resolves to 127.0.0.1 as well as ::1;
browsers fall back to 127.0.0.1 when ::1 refuses.
"""

import argparse
import html
import json
import os
import time
import urllib.parse
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.abspath(__file__))


def is_secret(name: str) -> bool:
    n = name.lower()
    return "pass" in n or "pw" in n


def parse_body(content_type: str, body: bytes):
    """Return a list of (name, value) pairs."""
    ct = (content_type or "").split(";")[0].strip().lower()
    text = body.decode("utf-8", errors="replace")
    if ct == "application/json":
        try:
            data = json.loads(text or "{}")
        except json.JSONDecodeError:
            return [("(invalid json)", text)]
        if isinstance(data, dict):
            return [(str(k), v if isinstance(v, str) else json.dumps(v)) for k, v in data.items()]
        return [("(json)", json.dumps(data))]
    if ct in ("", "application/x-www-form-urlencoded", "text/plain"):
        if ct == "text/plain":
            return [tuple(line.split("=", 1)) if "=" in line else (line, "") for line in text.splitlines() if line]
        return urllib.parse.parse_qsl(text, keep_blank_values=True)
    # multipart and anything else: show raw (cgi was removed from the stdlib).
    return [("(raw " + ct + ")", text)]


SUBMITTED_TEMPLATE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Submitted — Autofill Playground</title>
<link rel="stylesheet" href="/playground.css">
<style>
  table.fields {{ border-collapse: collapse; margin: 12px 0; }}
  table.fields th, table.fields td {{ border: 1px solid #ccc; padding: 4px 10px; text-align: left; font: 13px ui-monospace, Menlo, monospace; }}
  table.fields th {{ background: #f4f4f6; }}
  .secret .real {{ display: none; }}
  body.reveal .secret .real {{ display: inline; }}
  body.reveal .secret .masked {{ display: none; }}
</style></head>
<body>
<main>
<p class="crumb"><a href="/index.html">← Playground</a></p>
<h1>Submitted</h1>
<p>The browser POSTed <b>{count}</b> field(s) to <code>{path}</code> from <code>{referer}</code>.</p>
<p class="expected"><b>Expected:</b> if this was a login / sign-up / change-password form, the browser
should now offer to save (or update) the credentials. Nothing on this page should be autofilled.</p>
<table class="fields"><tr><th>name</th><th>value</th></tr>{rows}</table>
<p><button type="button" onclick="document.body.classList.toggle('reveal')">Reveal / hide secret values</button></p>
<p><a href="{back}">← Back to the form</a> · <a href="/index.html">Playground index</a></p>
<h3>Raw body</h3>
<pre class="secret"><span class="masked">(hidden — click reveal)</span><span class="real">{raw}</span></pre>
</main>
</body></html>
"""


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, fmt, *args):
        print("%s %s" % (self.address_string(), fmt % args), flush=True)

    def _send(self, status, ctype, body: bytes):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        path = urllib.parse.urlsplit(self.path).path
        fields = parse_body(self.headers.get("Content-Type", ""), body)

        if path.startswith("/api/"):
            time.sleep(0.3)
            data = dict(fields)
            if path == "/api/login":
                pw = next((v for k, v in fields if is_secret(k)), "")
                user = next((v for k, v in fields if not is_secret(k)), "")
                if pw == "wrong":
                    self._send(401, "application/json", json.dumps({"ok": False, "error": "bad password"}).encode())
                    return
                self._send(200, "application/json", json.dumps({"ok": True, "user": user}).encode())
                return
            self._send(200, "application/json", json.dumps({"ok": True, "received": list(data.keys())}).encode())
            return

        rows = []
        for name, value in fields:
            if is_secret(name):
                cell = ('<span class="secret"><span class="masked">•••••• (%d chars)</span>'
                        '<span class="real">%s</span></span>') % (len(value), html.escape(value))
            else:
                cell = html.escape(value) if value != "" else '<i class="note">(empty)</i>'
            rows.append("<tr><td>%s</td><td>%s</td></tr>" % (html.escape(name), cell))
        referer = self.headers.get("Referer") or ""
        back = referer or "/index.html"
        page = SUBMITTED_TEMPLATE.format(
            count=len(fields),
            path=html.escape(self.path),
            referer=html.escape(referer or "(no referer)"),
            rows="".join(rows) or '<tr><td colspan="2"><i>(no fields)</i></td></tr>',
            back=html.escape(back, quote=True),
            raw=html.escape(body.decode("utf-8", errors="replace")),
        )
        self._send(200, "text/html; charset=utf-8", page.encode("utf-8"))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--bind", default="127.0.0.1")
    args = ap.parse_args()
    server = ThreadingHTTPServer((args.bind, args.port), Handler)
    print("Autofill playground:")
    print("  http://localhost:%d/        (host A)" % args.port)
    print("  http://127.0.0.1:%d/        (host B — a different host/origin to the browser)" % args.port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
