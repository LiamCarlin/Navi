#!/usr/bin/env python3
"""Tiny Navi Cloud mock (docs/LAUNCH_ROADMAP.md §3.1) for running the app without the real backend.

    python3 scripts/dev/mock-cloud.py [--port 8787] [--quota 3] [--reject-first-token] [--tier free]
    defaults write com.liamcarlin.navi cloudBaseURL http://127.0.0.1:8787
    open "navi://auth/callback?code=test"          # simulate the browser round trip
    log stream --predicate 'subsystem == "com.liamcarlin.navi"' --level debug

Implements: GET /auth/start, GET /auth/callback, POST /auth/exchange, POST /auth/refresh,
GET /v1/me (free tier by default), POST /v1/jev (canned answers), POST /v1/claude (canned
message, SSE when stream:true; 402 after --quota calls), POST /v1/digest (403 on free/pro),
POST /billing/checkout + GET /checkout (a page whose "Complete" link opens
navi://billing/success and upgrades the mock user), POST /billing/portal, HEAD /.
stdlib only. Every request is logged to stdout with its feature/run headers.
"""
import argparse
import json
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

STATE = {
    "tier": "free",
    "access": None,          # current valid access token
    "refresh": None,
    "first_access": None,    # with --reject-first-token this one always 401s
    "claude_calls": 0,
    "runs": set(),           # (feature, run) pairs seen — usage counts once per run
    "answers_today": 0,
    "tasks_today": 0,
    "tasks_month": 0,
}
OPTS = None

TIERS = {
    "free": {"entitlements": {"answers": True, "tasks": True, "voice": False, "recall": False},
             "quotas": {"answersPerDay": 20, "tasksPerDay": 5}},
    "pro": {"entitlements": {"answers": True, "tasks": True, "voice": True, "recall": False},
            "quotas": {"tasksPerMonth": 300}},
    "pro_recall": {"entitlements": {"answers": True, "tasks": True, "voice": True, "recall": True},
                   "quotas": {"tasksPerMonth": 300}},
}


def iso(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def tokens():
    STATE["access"] = "acc-" + uuid.uuid4().hex[:8]
    STATE["refresh"] = "ref-" + uuid.uuid4().hex[:8]
    if STATE["first_access"] is None:
        STATE["first_access"] = STATE["access"]
    return {"accessToken": STATE["access"], "refreshToken": STATE["refresh"],
            "expiresAt": iso(datetime.now(timezone.utc) + timedelta(hours=1))}


def me():
    t = TIERS[STATE["tier"]]
    tomorrow = (datetime.now(timezone.utc) + timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
    body = {
        "user": {"id": "u_mock", "email": "liam@example.com"},
        "tier": STATE["tier"],
        "entitlements": t["entitlements"],
        "quotas": t["quotas"],
        "usage": {"answersToday": STATE["answers_today"], "tasksToday": STATE["tasks_today"],
                  "tasksThisMonth": STATE["tasks_month"], "resetsAt": iso(tomorrow)},
    }
    if STATE["tier"] != "free":
        body["trialEndsAt"] = iso(datetime.now(timezone.utc) + timedelta(days=7))
    return body


def jev_answers(questions):
    """Answer every question by type; `intent` routes to askQuestion so the panel offers Ask Navi."""
    out = {}
    for name, q in (questions or {}).items():
        kind = q.get("type")
        if kind == "choice":
            keys = list((q.get("criteria") or {}).keys()) or ["a"]
            pick = "askQuestion" if name == "intent" and "askQuestion" in keys else keys[0]
            probs = {k: (0.9 if k == pick else round(0.1 / max(1, len(keys) - 1), 3)) for k in keys}
            out[name] = {"type": "choice", "choice": pick, "probabilities": probs, "confidence": 0.85}
        elif kind == "score":
            crit = q.get("criteria") or []
            out[name] = {"type": "score", "score": 1.0, "legend": {str(i): str(c) for i, c in enumerate(crit)}, "confidence": 0.7}
        else:
            out[name] = {"type": "noul", "noul": 0.08}
    return {"model": "jev-latest", "answers": out, "usage": {"input_tokens": 120, "output_tokens": 8}}


CANNED_ANSWER = "The sky is blue because air scatters short (blue) wavelengths of sunlight more than long ones — Rayleigh scattering."


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    # -- helpers -------------------------------------------------------------

    def log_message(self, fmt, *args):  # quieter default log
        pass

    def _log(self, status, note=""):
        feat = self.headers.get("X-Navi-Feature", "-")
        run = self.headers.get("X-Navi-Run", "-")
        auth = self.headers.get("Authorization", "")
        tok = auth.replace("Bearer ", "")[:12] if auth else "-"
        print(f"{time.strftime('%H:%M:%S')} {self.command} {self.path} -> {status}  feature={feat} run={run[:8]} bearer={tok} {note}", flush=True)

    def _json(self, status, obj):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        self._log(status)

    def _html(self, status, html, location=None):
        data = html.encode()
        self.send_response(status)
        if location:
            self.send_header("Location", location)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        self._log(status, f"-> {location}" if location else "")

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        try:
            return json.loads(raw or b"{}")
        except Exception:
            return {}

    def _authed(self):
        auth = self.headers.get("Authorization", "")
        tok = auth.replace("Bearer ", "", 1)
        if not tok or tok != STATE["access"]:
            self._json(401, {"error": "unauthenticated"})
            return False
        if OPTS.reject_first_token and tok == STATE["first_access"]:
            self._json(401, {"error": "token_expired"})
            return False
        return True

    def _count_run(self, feature):
        run = self.headers.get("X-Navi-Run") or uuid.uuid4().hex
        key = (feature, run)
        if key in STATE["runs"]:
            return
        STATE["runs"].add(key)
        if feature in ("answer", "route"):
            STATE["answers_today"] += 1
        elif feature in ("task", "voice"):
            STATE["tasks_today"] += 1
            STATE["tasks_month"] += 1

    # -- routes --------------------------------------------------------------

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()
        self._log(200)

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if u.path in ("/auth/start", "/auth/callback"):
            code = "test-" + uuid.uuid4().hex[:6]
            link = f"navi://auth/callback?code={code}"
            return self._html(200, f"""<!doctype html><meta charset=utf-8><title>Navi mock sign-in</title>
<body style="font:16px -apple-system;padding:40px"><h2>Navi (mock) — sign in</h2>
<p>Pretend you signed in as <b>liam@example.com</b>.</p>
<p><a href="{link}" style="font-size:20px">Continue to Navi →</a></p>
<script>setTimeout(function(){{ location.href = {json.dumps(link)}; }}, 400);</script>""")
        if u.path == "/v1/me":
            if not self._authed():
                return
            return self._json(200, me())
        if u.path == "/checkout":
            plan = (q.get("plan") or ["pro"])[0]
            interval = (q.get("interval") or ["month"])[0]
            done = f"http://127.0.0.1:{OPTS.port}/checkout/complete?plan={plan}"
            return self._html(200, f"""<!doctype html><meta charset=utf-8><title>Mock checkout</title>
<body style="font:16px -apple-system;padding:40px"><h2>Mock Stripe Checkout</h2>
<p>Plan: <b>{plan}</b> · {interval}</p><p><a href="{done}" style="font-size:20px">Complete purchase →</a></p>
<p><a href="navi://billing/cancel">Cancel</a></p>""")
        if u.path == "/checkout/complete":
            plan = (q.get("plan") or ["pro"])[0]
            if plan in TIERS:
                STATE["tier"] = plan
            STATE["claude_calls"] = 0
            return self._html(302, "<a href='navi://billing/success'>Back to Navi</a>", location="navi://billing/success")
        if u.path == "/portal":
            return self._html(200, """<!doctype html><meta charset=utf-8><body style="font:16px -apple-system;padding:40px">
<h2>Mock billing portal</h2><p>Nothing to manage in the mock.</p><p><a href="navi://billing/success">Back to Navi</a></p>""")
        self._json(404, {"error": "not_found"})

    def do_POST(self):
        u = urlparse(self.path)
        body = self._body()
        if u.path == "/auth/exchange":
            if not body.get("code"):
                return self._json(400, {"error": "missing_code"})
            STATE["first_access"] = None
            return self._json(200, tokens())
        if u.path == "/auth/refresh":
            if body.get("refreshToken") != STATE["refresh"]:
                return self._json(401, {"error": "invalid_grant"})
            return self._json(200, tokens())
        if u.path == "/waitlist":
            return self._json(201, {"ok": True})
        if not self._authed():
            return
        feature = self.headers.get("X-Navi-Feature", "")
        t = TIERS[STATE["tier"]]
        if u.path == "/v1/jev":
            self._count_run(feature)
            return self._json(200, jev_answers(body.get("questions")))
        if u.path == "/v1/digest":
            if not t["entitlements"]["recall"]:
                return self._json(403, {"error": "not_entitled", "feature": feature or "recall_digest", "tier": STATE["tier"]})
            return self._json(200, {"id": "msg_mock", "type": "message", "role": "assistant", "stop_reason": "end_turn",
                                    "content": [{"type": "text", "text": json.dumps({"title": "Mock session", "summary": "Worked on Navi.", "tags": ["navi"]})}],
                                    "usage": {"input_tokens": 10, "output_tokens": 10}})
        if u.path == "/v1/claude":
            STATE["claude_calls"] += 1
            if STATE["claude_calls"] > OPTS.quota:
                tomorrow = (datetime.now(timezone.utc) + timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
                return self._json(402, {"error": "quota_exceeded", "feature": feature or "answer", "tier": STATE["tier"], "resetsAt": iso(tomorrow)})
            self._count_run(feature or "answer")
            if body.get("stream"):
                return self._sse(CANNED_ANSWER)
            return self._json(200, {"id": "msg_mock", "type": "message", "role": "assistant", "model": body.get("model", "claude-sonnet-5"),
                                    "stop_reason": "end_turn", "content": [{"type": "text", "text": CANNED_ANSWER}],
                                    "usage": {"input_tokens": 40, "output_tokens": 30}})
        if u.path == "/billing/checkout":
            plan = body.get("plan", "pro")
            interval = body.get("interval", "month")
            return self._json(200, {"url": f"http://127.0.0.1:{OPTS.port}/checkout?plan={plan}&interval={interval}"})
        if u.path == "/billing/portal":
            return self._json(200, {"url": f"http://127.0.0.1:{OPTS.port}/portal"})
        self._json(404, {"error": "not_found"})

    def _sse(self, text):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        def chunk(s):
            data = s.encode()
            self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n")
            self.wfile.flush()

        def event(name, obj):
            chunk(f"event: {name}\ndata: {json.dumps(obj)}\n\n")

        event("message_start", {"type": "message_start", "message": {"id": "msg_mock", "usage": {"input_tokens": 40}}})
        event("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
        for word in text.split(" "):
            event("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": word + " "}})
            time.sleep(0.03)
        event("content_block_stop", {"type": "content_block_stop", "index": 0})
        event("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 30}})
        event("message_stop", {"type": "message_stop"})
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()
        self._log(200, "(sse)")


def main():
    global OPTS
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--quota", type=int, default=3, help="/v1/claude calls before 402")
    ap.add_argument("--tier", choices=list(TIERS), default="free")
    ap.add_argument("--reject-first-token", action="store_true", help="the first access token always 401s (exercises refresh)")
    OPTS = ap.parse_args()
    STATE["tier"] = OPTS.tier
    srv = ThreadingHTTPServer(("127.0.0.1", OPTS.port), Handler)
    print(f"mock-cloud on http://127.0.0.1:{OPTS.port}  tier={OPTS.tier} quota={OPTS.quota} reject_first_token={OPTS.reject_first_token}", flush=True)
    print(f"  defaults write com.liamcarlin.navi cloudBaseURL http://127.0.0.1:{OPTS.port}", flush=True)
    print('  open "navi://auth/callback?code=test"', flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
