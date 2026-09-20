import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ["AI_GATEWAY_API_KEY"] = "vck_test"
os.environ["ANTHROPIC_API_KEY"] = "sk-test"
os.environ["NAVI_JEV_TRANSPORT"] = "vercel"
import navi_runner as nr
from jev_ultrafast import model as jev_model

class FakeResp:
    def __init__(self, status, body): self.status_code=status; self._b=body
    @property
    def is_error(self): return self.status_code >= 400
    def json(self): return self._b

captured = {}
def fake_post(url, json=None, headers=None):
    captured["url"]=url; captured["json"]=json; captured["headers"]=headers
    if "vercel" in url:
        return FakeResp(200, {"answers":{"operation":{"type":"choice","choice":"CLICK","probabilities":{"CLICK":0.9,"DONE":0.1}},
                                          "click_target":{"type":"choice","choice":"2","probabilities":{"1":0.2,"2":0.8}},
                                          "flag":{"type":"boolean","probability":0.97}},
                               "usage":{"inputTokens":300,"outputTokens":20},
                               "providerMetadata":{"typesafe":{"confidence":{"operation":0.66}}}})
    if "/v1/messages" in url:
        return FakeResp(200, {"content":[{"type":"text","text":"```json\n{\"text\": \"Zurich\"}\n```"}],"usage":{"input_tokens":50,"output_tokens":5}})
    raise AssertionError(url)
jev_model.CLIENT.post = fake_post

nr.install_adaptations()
body = {"model":"jev-latest","state":{"page":{}},"questions":{
    "operation":{"type":"choice","criteria":{"CLICK":"c","DONE":"d"},"instructions":"x"},
    "click_target":{"type":"choice","criteria":{"1":{},"2":{}},"instructions":"y"},
    "flag":{"type":"noul","instructions":"z"}}}
r = jev_model.post_json("https://api.typesafe.ai/v1/systemone", "unused", body)
assert captured["url"] == nr.VERCEL_URL, captured["url"]
assert captured["headers"]["ai-model-id"] == "typesafe-ai/jev"
assert captured["headers"]["Authorization"] == "Bearer vck_test"
assert captured["json"]["questions"]["flag"]["type"] == "boolean"
assert "model" not in captured["json"]
assert r["answers"]["operation"]["confidence"] == 0.66          # from providerMetadata
assert abs(r["answers"]["click_target"]["confidence"] - 0.6) < 1e-9  # derived 0.8-0.2
assert r["answers"]["flag"] == {"type":"noul","noul":0.97}
assert r["usage"]["input_tokens"] == 300
# validate_choice accepts the translated answers
jev_model.validate_choice(r["answers"]["operation"], {"CLICK","DONE"})
# text helper
import jev_ultrafast.agent as agent_module
assert isinstance(agent_module.field_text, nr.SpeculativeText)
assert agent_module.field_text.inner is nr.field_text_claude
assert agent_module.Browser is nr.FastBrowser and issubclass(nr.FastBrowser, nr.Browser)
assert agent_module.choose is not jev_model.choose   # speculation hook wraps the decision call
text, helper = jev_model.field_text({"goal":"g","field":{"label":"Where from?"},"page":{"title":"t","text":""},"recent_actions":[]})
assert text == "Zurich" and helper["model"] == "claude-haiku-4-5" and "speculative" not in helper
assert captured["headers"]["x-api-key"] == "sk-test"

# --- speculative text helper ---
import threading, time
calls = []
gate = threading.Event()
def slow_helper(context):
    calls.append(context); gate.wait(2); return "Boston", {"model": "fake", "latency_ms": 1}
spec = nr.SpeculativeText(slow_helper)
page = {"title": "Flights", "text": "Where from? Where to?", "actions": [
    {"id": "1", "node": 1, "kind": "fill", "label": "Where from?", "value": "", "role": "combobox"},
    {"id": "2", "node": 1, "kind": "click", "label": "Open Where from?", "value": ""},
    {"id": "3", "node": 2, "kind": "fill", "label": "Where to?", "value": "", "role": "combobox"},
    {"id": "4", "node": 3, "kind": "click", "label": "Search"},
]}
# Two empty fields, nothing clicked → no obvious candidate, nothing started.
spec.speculate("fly to Boston", page, [])
assert calls == [] and spec.stats["started"] == 0
# The last action clicked "Open Where from?" → that field is the candidate.
history = [{"step": 1, "action": "Open Where from?", "kind": "click"}]
spec.speculate("fly to Boston", page, history)
time.sleep(0.05)
assert len(calls) == 1 and calls[0]["field"]["label"] == "Where from?"
spec.speculate("fly to Boston", page, history)   # same context → no second call
assert len(calls) == 1
# The agent asks for exactly the context the runner would build → served from the future.
from jev_ultrafast.model import field_context
ctx = field_context("fly to Boston", page["actions"][0], page, history)
gate.set()
text, helper = spec(ctx)
assert text == "Boston" and helper["speculative"] is True and spec.stats["hits"] == 1
# A different context (other field) is computed directly, not from the cache.
ctx2 = field_context("fly to Boston", page["actions"][2], page, history)
text, helper = spec(ctx2)
assert text == "Boston" and "speculative" not in helper and len(calls) == 2
# Once "Where from?" has been typed into, it is no longer a candidate; the only empty field left is "Where to?".
history2 = history + [{"step": 2, "action": "Where from?", "kind": "fill", "text": "Boston"}]
assert nr.SpeculativeText.candidate(page, history2)["label"] == "Where to?"
# A clicked field that already holds text (Google's pre-filled search box) is not a candidate.
filled = {"title": "Google", "text": "", "actions": [
    {"id": "1", "node": 1, "kind": "fill", "label": "Search", "value": "weather in boston", "role": "combobox"},
    {"id": "2", "node": 1, "kind": "click", "label": "Open Search", "value": "weather in boston"},
]}
assert nr.SpeculativeText.candidate(filled, [{"step": 1, "action": "Open Search", "kind": "click"}]) is None
print("runner adaptations OK")

# --- coach ---
h = [{"step": i, "action": "Open Search", "kind": "click", "page_changed": True} for i in range(1, 4)]
assert "3 times in a row" in nr.Coach.flailing(h)
h2 = [{"step": 1, "action": "A", "kind": "click", "page_changed": False}, {"step": 2, "action": "B", "kind": "click", "page_changed": False},
      {"step": 3, "action": "C", "kind": "click", "page_changed": False}]
assert "changed nothing" in nr.Coach.flailing(h2)
assert nr.Coach.flailing(h2[:2]) is None
assert nr.Coach.flailing([{"step": 1, "action": "Wait", "kind": "wait", "page_changed": False}] * 3) is None
coach = nr.Coach()
coach.guidance = "Click [7] Search button, stop clicking the search box."
seen = {}
def fake_inner(url, key, body):
    seen["body"] = body; return {"answers": {}}
jev_model.post_json = fake_inner
coach.install()
jev_model.post_json("https://api.typesafe.ai/v1/systemone", "k", {"model": "jev-latest", "state": {"page": {}},
    "questions": {"operation": {"type": "choice", "criteria": {"CLICK": "c"}, "instructions": {"goal": "g", "rules": "r"}}}})
assert seen["body"]["state"]["guidance"] == coach.guidance
assert seen["body"]["questions"]["operation"]["instructions"]["guidance"] == coach.guidance
assert seen["body"]["questions"]["operation"]["instructions"]["goal"] == "g"
print("coach OK")
