"""Adaptation 20: the runner on Navi Cloud — no vendor key, bearer + run headers.

    vendor/jev-ultrafast/.venv/bin/python scripts/ultrafast/test_navi_cloud.py
    (or any interpreter with the runtime's deps, e.g. build/runtime/aarch64/python/bin/python3.12)
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
for k in ("ANTHROPIC_API_KEY", "TYPESAFE_API_KEY", "AI_GATEWAY_API_KEY", "TEXT_MODEL_API_KEY", "ANTHROPIC_BASE_URL"):
    os.environ.pop(k, None)
os.environ.update({
    "NAVI_JEV_TRANSPORT": "navi",
    "NAVI_CLOUD_URL": "http://cloud.test/",
    "NAVI_CLOUD_TOKEN": "tok-abc",
    "NAVI_CLOUD_FEATURE": "voice",
    "NAVI_CLOUD_RUN": "run-123",
})
import navi_runner as nr  # noqa: E402
from jev_ultrafast import model as jev_model  # noqa: E402


class FakeResp:
    def __init__(self, status, body):
        self.status_code = status
        self._b = body

    @property
    def is_error(self):
        return self.status_code >= 400

    def json(self):
        if isinstance(self._b, Exception):
            raise self._b
        return self._b


calls = []
script = []      # queued responses; empty → a canned success for the URL


def fake_post(url, json=None, headers=None, **kw):
    calls.append({"url": url, "json": json, "headers": dict(headers or {})})
    if script:
        return script.pop(0)
    if url.endswith("/v1/jev"):
        return FakeResp(200, {"model": "jev-latest", "answers": {
            "operation": {"choice": "CLICK", "probabilities": {"CLICK": 0.9, "DONE": 0.1}, "confidence": 0.8}}})
    if url.endswith("/v1/claude"):
        return FakeResp(200, {"content": [{"type": "text", "text": "{\"text\": \"Zurich\"}"}], "usage": {}})
    raise AssertionError(url)


jev_model.CLIENT.post = fake_post
nr.time.sleep = lambda s: None          # retries without waiting

# --- endpoint selection --------------------------------------------------------------
base, headers = nr.navi_cloud()
assert base == "http://cloud.test", base
assert headers == {"Authorization": "Bearer tok-abc", "X-Navi-Feature": "voice", "X-Navi-Run": "run-123"}, headers
url, h = nr.claude_endpoint()
assert url == "http://cloud.test/v1/claude" and "x-api-key" not in h and h["anthropic-version"] == "2023-06-01"

nr.install_adaptations()
assert jev_model.post_json is nr.post_json_navi
assert os.environ["TYPESAFE_API_KEY"] == "via-navi-cloud"     # placeholder for upstream; never sent

# --- Jev through /v1/jev ---------------------------------------------------------------
body = {"model": "jev-latest", "state": {"page": {}}, "questions": {"operation": {"type": "choice"}}}
r = jev_model.post_json("https://api.typesafe.ai/v1/systemone", "via-navi-cloud", body)
assert calls[-1]["url"] == "http://cloud.test/v1/jev", calls[-1]["url"]
assert calls[-1]["json"] == body                     # the exact TypeSafe body
assert calls[-1]["headers"]["Authorization"] == "Bearer tok-abc"
assert calls[-1]["headers"]["X-Navi-Feature"] == "voice" and calls[-1]["headers"]["X-Navi-Run"] == "run-123"
assert r["answers"]["operation"]["choice"] == "CLICK"

# --- the text helper through /v1/claude ------------------------------------------------
import jev_ultrafast.agent as agent_module  # noqa: E402
assert agent_module.field_text.inner is nr.field_text_claude      # no ANTHROPIC_API_KEY, still Claude
text, helper = jev_model.field_text({"goal": "g", "field": {"label": "From"}, "page": {"title": "t", "text": ""}, "recent_actions": []})
assert text == "Zurich"
c = calls[-1]
assert c["url"] == "http://cloud.test/v1/claude" and c["headers"]["Authorization"] == "Bearer tok-abc"
assert "x-api-key" not in c["headers"] and c["json"]["model"] == "claude-haiku-4-5"

# --- refusals are typed and never retried ------------------------------------------------
def refused(status, payload):
    n = len(calls)
    script.append(FakeResp(status, payload))
    try:
        jev_model.post_json("https://api.typesafe.ai/v1/systemone", "x", body)
    except nr.CloudError as e:
        assert len(calls) == n + 1, "a refusal must not be retried"
        return e
    raise AssertionError("expected CloudError")

e = refused(402, {"error": "quota_exceeded", "feature": "task", "tier": "free", "resetsAt": "2026-10-02T00:00:00Z"})
assert e.fields == {"code": "quota_exceeded", "status": 402, "feature": "task", "tier": "free", "resetsAt": "2026-10-02T00:00:00Z"}, e.fields
e = refused(403, {"error": "not_entitled", "feature": "voice", "tier": "free"})
assert e.fields["code"] == "not_entitled" and e.fields["tier"] == "free"
e = refused(401, {"error": "unauthenticated"})
assert e.fields["code"] == "signed_out" and "Sign in" in str(e)
e = refused(503, {"error": "upstream_unconfigured"})
assert e.fields["code"] == "upstream_unconfigured"

# rate limiting is retried, then reported
n = len(calls)
script.extend([FakeResp(429, {"error": "rate_limited", "retryAfterSeconds": 2})] * 3)
try:
    jev_model.post_json("https://api.typesafe.ai/v1/systemone", "x", body)
    raise AssertionError("expected CloudError")
except nr.CloudError as e:
    assert e.fields["code"] == "rate_limited" and len(calls) == n + 3
# a vendor 529 passed through by the proxy is retried and then succeeds
n = len(calls)
script.append(FakeResp(529, {"type": "error"}))
jev_model.post_json("https://api.typesafe.ai/v1/systemone", "x", body)
assert len(calls) == n + 2
# the text helper surfaces a quota refusal instead of "nothing typed"
script.append(FakeResp(402, {"error": "quota_exceeded", "feature": "task", "tier": "free"}))
try:
    nr.field_text_claude({"goal": "g2", "field": {"label": "To"}, "page": {}, "recent_actions": []})
    raise AssertionError("expected CloudError")
except nr.CloudError as e:
    assert e.fields["code"] == "quota_exceeded"

# --- signed out: transport says navi but there is no token -------------------------------
os.environ["NAVI_CLOUD_TOKEN"] = ""
assert nr.navi_cloud() is None and nr.claude_endpoint() is None
try:
    nr.install_adaptations()
    raise AssertionError("expected CloudError")
except nr.CloudError as e:
    assert e.fields["code"] == "signed_out"

# --- developer mode keeps the vendor endpoints -------------------------------------------
os.environ["NAVI_JEV_TRANSPORT"] = ""
os.environ["ANTHROPIC_API_KEY"] = "sk-dev"
url, h = nr.claude_endpoint()
assert url == "https://api.anthropic.com/v1/messages" and h["x-api-key"] == "sk-dev" and "Authorization" not in h

print("navi cloud transport: OK")
