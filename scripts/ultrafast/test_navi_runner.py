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

# --- rejected clicks (adaptation 8) ---
def fake_state(node_ids, status="ready", url="https://a.example/"):
    return {"status": status, "started_at": None, "decisions": [], "history": [],
            "page": {"url": url, "page_key": [1234.5, url], "actions":
                     [{"id": f"e{n}", "node": n, "kind": "click", "label": f"Link {n}"} for n in node_ids]}}
rc = nr.RejectedClicks()
st = fake_state([1, 2, 3])
def rejected_tick(st, choice):
    """What upstream's tick leaves behind when act() raised StalePage: one more decision, no step."""
    d0, h0 = len(st["decisions"]), len(st["history"])
    st["decisions"].append({"choice": choice, "operation": "CLICK", "target": choice[1:], "fingerprint": "f"})
    return rc.after_tick(st, d0, h0)
assert rejected_tick(st, "e2") is None                     # first rejection: just counted
assert rc.filter(st["page"]) is st["page"]                 # nothing hidden yet
assert rejected_tick(st, "e2") == "Link 2"                 # second: failed step + hidden
assert st["history"][-1]["page_changed"] is False and "could not be clicked" in st["history"][-1]["note"]
assert [a["id"] for a in rc.filter(st["page"])["actions"]] == ["e1", "e3"]
assert st["status"] == "ready"
# A real step (history grew) is never a rejection.
d0, h0 = len(st["decisions"]), len(st["history"])
st["decisions"].append({"choice": "e1", "operation": "CLICK", "target": "1", "fingerprint": "f"})
st["history"].append({"step": 2, "action": "Link 1", "kind": "click", "page_changed": True})
assert rc.after_tick(st, d0, h0) is None
# DONE/BLOCKED re-asked after a stale page is not a rejection either.
d0, h0 = len(st["decisions"]), len(st["history"])
st["decisions"].append({"choice": "DONE", "operation": "DONE", "target": None, "fingerprint": "f"})
assert rc.after_tick(st, d0, h0) is None
# Three failed steps in a row → upstream's stuck rule fires (→ coach).
st["history"][-1]["page_changed"] = False
rejected_tick(st, "e3"); assert rejected_tick(st, "e3") == "Link 3"
assert st["status"] == "blocked"
# A new document (different page_key[0]) starts clean: node 2 there is a different element.
other = {"url": "https://b.example/", "page_key": [999.0, "https://b.example/"],
         "actions": [{"id": "e2", "node": 2, "kind": "click", "label": "Other 2"}]}
assert rc.filter(other) is other
print("rejected clicks OK")

# --- canvas (adaptation 9) ---
js = nr.patched_snapshot_js()
assert "summary,canvas," in js and "if (e.tagName==='CANVAS') return 'button';" in js and "Game canvas " in js
assert "r.width<120 || r.height<120" in js
cs = {"status": "blocked", "history": [
    {"step": 1, "action": "Game canvas 800×600 (click to interact / play)", "kind": "click", "choice": "e1", "page_changed": False},
    {"step": 2, "action": "Game canvas 800×600 (click to interact / play)", "kind": "click", "choice": "e1", "page_changed": False},
    {"step": 3, "action": "Game canvas 800×600 (click to interact / play)", "kind": "click", "choice": "e1", "page_changed": False}],
    "page": {"actions": [{"id": "e1", "node": 1, "kind": "click", "canvas": True, "label": "Game canvas 800×600 (click to interact / play)"}]}}
nr.soften_canvas_step(cs, 2)
assert cs["history"][-1]["page_changed"] is None and cs["status"] == "ready"
assert nr.Coach.flailing(cs["history"]) and "3 times in a row" in nr.Coach.flailing(cs["history"])  # repetition still reaches the coach
# An ordinary link that changed nothing is left alone.
ls = {"status": "ready", "history": [{"step": 1, "action": "Link", "kind": "click", "choice": "e9", "page_changed": False}],
      "page": {"actions": [{"id": "e9", "node": 9, "kind": "click", "label": "Link"}]}}
nr.soften_canvas_step(ls, 0)
assert ls["history"][-1]["page_changed"] is False
print("canvas OK")

# --- click point (adaptation 7) ---
assert nr.browser_module.browser_operation is nr.browser_operation_navi
assert "getClientRects" in nr.CLICK_POINT_JS and "if (n===e) return {x,y}" in nr.CLICK_POINT_JS
print("click point OK")

# --- Google Docs body (adaptation 15) ---
assert ".kix-appview-editor,[contenteditable" in js and "docs_body:docsBody" in js and "return 'textbox';" in js
assert "Document body — the page itself" in js
calls = []
real_cdp = nr.cdp
def fake_cdp(method, **params):
    calls.append((method, params))
    if method == "Runtime.evaluate":
        return {"result": {"value": {"x": 400, "y": 300}}}
    return {}
nr.cdp = fake_cdp
try:
    nr.browser_operation_navi({"operation": "act", "session": "s", "text": "Patriots 20, Steelers 3",
                               "action": {"id": "e5", "node": 5, "kind": "fill", "docs_body": True, "label": "Document body"}})
    kinds = [m for m, _ in calls]
    assert kinds == ["Runtime.evaluate", "Input.dispatchMouseEvent", "Input.dispatchMouseEvent",
                     "Input.dispatchKeyEvent", "Input.dispatchKeyEvent", "Input.insertText"], kinds
    assert all("commands" not in p for m, p in calls if m == "Input.dispatchKeyEvent")   # no select-all in a document
    assert calls[3][1]["key"] in {"ArrowDown", "End"} and calls[-1][1]["text"] == "Patriots 20, Steelers 3"
    calls.clear()
    nr.browser_operation_navi({"operation": "act", "session": "s", "text": "Q3 report",
                               "action": {"id": "e2", "node": 2, "kind": "fill", "label": "Rename"}})
    assert [p.get("commands") for m, p in calls if m == "Input.dispatchKeyEvent"] == [["selectAll"], None]   # ordinary fields still replace
finally:
    nr.cdp = real_cdp
print("docs body OK")

# --- page settle (adaptation 10) ---
class FakeBrowser:
    """Observations scripted as (readyState, page) pairs."""
    def __init__(self, script): self.script = list(script); self.observed = 0
    def evaluate(self, expr): return self.script[0][0] if self.script else "complete"
    def observe(self, screenshot=False):
        self.observed += 1
        ready, page = self.script.pop(0) if len(self.script) > 1 else self.script[0]
        return page
class FakeAgent:
    screenshots = False
    def __init__(self, page, browser): self.state = {"page": page, "browser": browser, "started_at": time.perf_counter()}
def pg(fp, n, url="https://maps.example/dir"):
    return {"url": url, "fingerprint": fp, "actions": [{"id": f"e{i}", "node": i, "kind": "click", "label": f"L{i}"} for i in range(n)]}
nr.SETTLE_POLL_S = 0.001
nr.GROWTH_CHECK_S = 0.001
# A blank document (0 interactive elements) is re-observed until it renders and holds still.
blank = pg("f0", 0)
fb = FakeBrowser([("loading", pg("f1", 3)), ("complete", pg("f2", 12)), ("complete", pg("f2", 12))])
ag = FakeAgent(blank, fb)
assert nr.settle_page(ag) == 3 and ag.state["page"]["fingerprint"] == "f2"
# A page that already has controls and did not just navigate (same document) is not touched.
fb2 = FakeBrowser([("complete", pg("x", 5))]); ag2 = FakeAgent(pg("f9", 5), fb2)
assert nr.settle_page(ag2, previous_url="https://maps.example/dir?z=1") == 0 and fb2.observed == 0
# The start page gets one growth check: a shell whose table is still filling in (Drive's
# sidebar before its file grid) keeps settling until it holds still; a stable one costs one look.
fb5 = FakeBrowser([("complete", pg("s1", 12)), ("complete", pg("s2", 30)), ("complete", pg("s2", 30))]); ag5 = FakeAgent(pg("s0", 5), fb5)
assert nr.settle_page(ag5) == 3 and ag5.state["page"]["fingerprint"] == "s2" and len(ag5.state["page"]["actions"]) == 30
fb6 = FakeBrowser([("complete", pg("t1", 6))]); ag6 = FakeAgent(pg("t0", 5), fb6)
assert nr.settle_page(ag6) == 1 and fb6.observed == 1 and ag6.state["page"]["fingerprint"] == "t1"
# A navigation (URL changed) is settled even if the first frame has a few controls.
fb3 = FakeBrowser([("complete", pg("g1", 4)), ("complete", pg("g1", 4))]); ag3 = FakeAgent(pg("g0", 2), fb3)
assert nr.settle_page(ag3, previous_url="https://www.google.com/search?q=x") == 2
assert nr.looks_unsettled(pg("a", 3, "https://a.example/p?x=1"), previous_url="https://a.example/p?x=2") is False  # same document
# The deadline bounds a page that never settles.
fb4 = FakeBrowser([("loading", pg("h", 0))]); ag4 = FakeAgent(pg("h", 0), fb4)
t0 = time.monotonic(); nr.settle_page(ag4, max_s=0.02); assert time.monotonic() - t0 < 0.5
print("settle OK")

# --- tentative BLOCKED (adaptation 11) ---
assert nr.blocked_is_tentative({"operation": "BLOCKED", "confidence": 0.31, "operation_probabilities": {"BLOCKED": 0.54, "WAIT": 0.38}})
assert nr.blocked_is_tentative({"operation": "BLOCKED", "confidence": 0.9, "operation_probabilities": {"BLOCKED": 0.6, "WAIT": 0.3}})  # WAIT close
assert not nr.blocked_is_tentative({"operation": "BLOCKED", "confidence": 0.9, "operation_probabilities": {"BLOCKED": 0.95, "WAIT": 0.02}})
assert not nr.blocked_is_tentative({"operation": "CLICK", "confidence": 0.2, "operation_probabilities": {"CLICK": 0.5}})
assert not nr.blocked_is_tentative(None)
class TickAgent:
    """Scripted decisions; records what the loop did with them."""
    screenshots = False
    def __init__(self, decisions):
        self.decisions = list(decisions); self.acted = []
        self.state = {"page": pg("p1", 3), "browser": FakeBrowser([("complete", pg("p2", 3))]), "decision": None,
                      "status": "ready", "started_at": time.perf_counter(), "elapsed_ms": 0}
    def command(self, name, body=None):
        if name == "predict":
            self.state["decision"] = self.decisions.pop(0); self.state["status"] = "predicted"
        elif name == "act":
            self.acted.append(self.state["decision"]); self.state["decision"] = None
            self.state["status"] = "blocked" if self.acted[-1]["operation"] == "BLOCKED" else "ready"
nr.TENTATIVE_BLOCKED_WAIT_S = 0.001
weak = {"operation": "BLOCKED", "confidence": 0.31, "operation_probabilities": {"BLOCKED": 0.54, "WAIT": 0.38}}
click = {"operation": "CLICK", "confidence": 0.9, "operation_probabilities": {"CLICK": 0.9}}
ta = TickAgent([weak, click]); retried = set()
assert nr.tick(ta, retried) == "retried" and ta.acted == [] and ta.state["status"] == "ready" and retried == {"p1"}
assert ta.state["page"]["fingerprint"] == "p2"          # re-observed before deciding again
assert nr.tick(ta, retried) == "acted" and ta.acted == [click]
# The same weak BLOCKED again on an already-retried page is final.
tb = TickAgent([weak, weak]); r2 = set()
assert nr.tick(tb, r2) == "retried"
tb.state["page"] = pg("p1", 3)                            # page did not change after the wait
assert nr.tick(tb, r2) == "acted" and tb.state["status"] == "blocked"
# A confident BLOCKED is acted on immediately.
sure = {"operation": "BLOCKED", "confidence": 0.9, "operation_probabilities": {"BLOCKED": 0.95, "WAIT": 0.02}}
tc = TickAgent([sure]); assert nr.tick(tc, set()) == "acted" and tc.state["status"] == "blocked"
print("tentative BLOCKED OK")

# --- coaching per document (adaptation 12) ---
c = nr.Coach()
assert c.may_ask("https://www.google.com/search?q=a")
c.used = True; c.count = 1; c.url = "https://www.google.com/search?q=a"; c.current_url = c.url
c.guidance = "Click 'Directions' (index 26)."
assert not c.may_ask("https://www.google.com/search?q=b")          # same document (query ignored)
assert c.may_ask("https://www.google.com/maps/dir/Olin/Northeastern")  # Jev moved on: Claude may look again
c.count = nr.MAX_COACHINGS
assert not c.may_ask("https://elsewhere.example/")                  # budget
c.count = 1
assert c.guidance_for(c.url) == c.guidance
stale = c.guidance_for("https://www.google.com/maps/dir/x")
assert stale.startswith("(Written on the previous page") and c.guidance in stale
seen = {}
jev_model.post_json = lambda url, key, body: seen.update(body=body) or {"answers": {}}
c.install()
c.current_url = "https://www.google.com/maps/dir/x"
jev_model.post_json("https://api.typesafe.ai/v1/systemone", "k", {"model": "jev-latest", "state": {"page": {}},
    "questions": {"operation": {"type": "choice", "criteria": {"CLICK": "c"}, "instructions": {"goal": "g"}}}})
assert seen["body"]["state"]["guidance"].startswith("(Written on the previous page")
print("coach per document OK")

# --- web-app playbooks (adaptation 14) ---
skills = [
    {"app": "Google Drive", "hosts": ["drive.google.com"],
     "how_it_works": ["Left sidebar: My Drive, Shared with me."],
     "recipes": [{"goal": "find a file shared by someone", "keywords": ["shared", "find", "by"], "steps": ["Open shared-with-me", "Read the rows"]},
                 {"goal": "create a doc", "keywords": ["create", "new"], "steps": ["CLICK '+ New'"]}],
     "done_when": ["the file is open"], "avoid": ["Do not click Shared with me again."], "field_hints": ["Search takes words only."]},
    {"app": "Google Search", "hosts": ["google.com", "www.google.com"], "how_it_works": ["Results are links."], "recipes": []},
    {"app": "Google Maps", "hosts": ["google.com/maps"], "how_it_works": ["Directions view."], "recipes": []},
]
pb = nr.Playbook(skills=skills, goal="Find the report shared with me by Heesung")
assert pb.skill_for("https://drive.google.com/drive/shared-with-me")["app"] == "Google Drive"
assert pb.skill_for("https://www.google.com/search?q=x")["app"] == "Google Search"
assert pb.skill_for("https://www.google.com/maps/dir/a/b")["app"] == "Google Maps"     # path-scoped host wins
assert pb.skill_for("https://example.com/") is None and pb.skill_for(None) is None
book = pb.playbook_for("https://drive.google.com/drive/my-drive")
assert book["app"] == "Google Drive" and book["done_when"] == ["the file is open"] and book["avoid"]
assert [r["goal"] for r in book["recipes"]] == ["find a file shared by someone"]      # only the matching recipe
assert "how_it_works" in book and "field_hints" not in book                            # hints go to the text helper, not Jev
assert pb.field_hints_for("https://drive.google.com/x") == ["Search takes words only."]
assert nr.Playbook(skills=skills, goal="do something").playbook_for("https://drive.google.com/").get("recipes") is None
seen = {}
jev_model.post_json = lambda url, key, body: seen.update(body=body) or {"answers": {}}
pb.install()
jev_model.post_json("https://api.typesafe.ai/v1/systemone", "k", {"model": "jev-latest",
    "state": {"page": {"url": "https://drive.google.com/drive/shared-with-me"}},
    "questions": {"operation": {"type": "choice", "criteria": {"CLICK": "c"}, "instructions": {"goal": "g"}},
                  "click_target": {"type": "choice", "criteria": {"1": {}}, "instructions": {"goal": "g"}}}})
assert seen["body"]["state"]["playbook"]["app"] == "Google Drive"
assert seen["body"]["questions"]["operation"]["instructions"]["playbook"] == nr.PLAYBOOK_RULE
assert "playbook" not in seen["body"]["questions"]["click_target"]["instructions"]
jev_model.post_json("https://api.typesafe.ai/v1/systemone", "k", {"model": "jev-latest",
    "state": {"page": {"url": "https://example.com/"}}, "questions": {"operation": {"type": "choice", "criteria": {}, "instructions": {}}}})
assert "playbook" not in seen["body"]["state"]                                         # unknown site: untouched
os.environ["NAVI_PLAYBOOKS_JSON"] = json.dumps(skills)
assert len(nr.Playbook.from_env()) == 3
os.environ["NAVI_PLAYBOOKS_JSON"] = "not json"
assert nr.Playbook.from_env() == []
print("web playbooks OK")

# --- the user's own context rides in Jev's state (adaptation 19) ---
ctx = {"note": "n", "things": [{"name": "Mikey Ku", "type": "person", "talks_with_them_in": ["Messages (55)"]}]}
os.environ["NAVI_USER_CONTEXT_JSON"] = json.dumps(ctx)
assert nr.Playbook.user_context_from_env() == ctx
seen = {}
jev_model.post_json = lambda url, key, body: seen.update(body=body) or {"answers": {}}
nr.Playbook(skills=[], goal="message mikey").install()
jev_model.post_json("https://api.typesafe.ai/v1/systemone", "k", {"model": "jev-latest",
    "state": {"page": {"url": "https://example.com/"}}, "questions": {"operation": {"type": "choice", "criteria": {}, "instructions": {}}}})
assert seen["body"]["state"]["user_context"] == ctx and "playbook" not in seen["body"]["state"]
for bad in ("not json", json.dumps({"things": []}), json.dumps([1])):
    os.environ["NAVI_USER_CONTEXT_JSON"] = bad
    assert nr.Playbook.user_context_from_env() is None
# How the user did it before (UserMoves procedures) rides along even with no named things.
ways = {"note": "n", "things": [], "how_this_user_works": {"did_before": ["submit hw (Chrome) → Courses › MTH3199 › Assignments"]}}
os.environ["NAVI_USER_CONTEXT_JSON"] = json.dumps(ways)
assert nr.Playbook.user_context_from_env() == ways
os.environ.pop("NAVI_USER_CONTEXT_JSON")
print("user context OK")

# --- the user's own clicks mark the page (adaptation 21) ---
moves = {"sites": {"canvas.olin.edu": {
    "clicks": [{"label": "Assignments", "role": "link", "count": 9}, {"label": "Grades", "role": "link", "count": 1},
               {"label": "MTH3199 Calculus, Fall 2026", "role": "row", "count": 4}],
    "next": {"mth3199 calculus, fall 2026": {"assignments": 4}}}}}
os.environ["NAVI_USER_MOVES_JSON"] = json.dumps(moves)
um = nr.UserMoves()
assert set(um.sites) == {"canvas.olin.edu"}
assert nr.UserMoves.site_key("https://www.docs.google.com/document/d/1/edit") == "docs.google.com/document"
assert nr.UserMoves.site_key("https://canvas.olin.edu/courses/1") == "canvas.olin.edu"
assert nr.UserMoves.norm("Drafts (3)") == "drafts" and nr.UserMoves.norm("Assignment 2") == "assignment 2"
assert nr.UserMoves.norm("New Email\u2026") == "new email"
elements = [{"index": "1", "label": "Assignments"}, {"index": "2", "label": "Grades"}, {"index": "3", "label": "Assignments Help"},
            {"index": "4", "label": "MTH3199 Calculus, Spring section"}]
body = {"model": "jev-latest", "state": {"page": {"url": "https://canvas.olin.edu/courses/1"}, "elements": elements},
        "questions": {"operation": {"type": "choice", "criteria": {}, "instructions": {"rules": "x"}},
                      "click_target": {"type": "choice", "criteria": {e["index"]: {"element": f"[{e['index']}] {e['label']}"} for e in elements},
                                       "instructions": {"goal": "g", "rules": ["a", "b"]}}}}
marked = um.annotate(body)
els = {e["index"]: e for e in marked["state"]["elements"]}
assert els["1"]["this_user"] == "this user clicks this here (9\u00d7)"
assert "this_user" not in els["2"] and "this_user" not in els["3"]          # one click is chance; "Assignments Help" is another control
assert els["4"]["this_user"] == "this user clicks this here (4\u00d7)"       # a row matches on its name
assert marked["questions"]["click_target"]["criteria"]["1"]["this_user"].startswith("this user clicks")
assert marked["questions"]["click_target"]["instructions"]["rules"][-1] == nr.USER_MOVES_RULE
assert marked["questions"]["operation"] == body["questions"]["operation"]
assert "this_user" not in body["state"]["elements"][0]                         # the original request is untouched
# After clicking the course row, Assignments is what this user clicks next.
um.observe(marked, {"answers": {"operation": {"choice": "CLICK"}, "click_target": {"choice": "4"}}})
assert um.last["canvas.olin.edu"] == "mth3199 calculus, spring section"
again = {e["index"]: e for e in um.annotate(body)["state"]["elements"]}
assert again["1"]["this_user"] == "this user clicks this here (9\u00d7) and usually clicks this next"
# Another site, no memory, or junk: untouched.
other = json.loads(json.dumps(body)); other["state"]["page"]["url"] = "https://example.com/"
assert um.annotate(other) == other
os.environ["NAVI_USER_MOVES_JSON"] = "not json"; assert nr.UserMoves.from_env() == {}
os.environ.pop("NAVI_USER_MOVES_JSON")
assert nr.UserMoves().annotate(body) is body
seen = {}
jev_model.post_json = lambda url, key, body: seen.update(body=body) or {"answers": {}}
nr.UserMoves(sites=moves["sites"]).install()
jev_model.post_json("https://api.typesafe.ai/v1/systemone", "k", body)
assert seen["body"]["state"]["elements"][0]["this_user"].startswith("this user")
print("user moves OK")

# --- the user's own way of doing this task (adaptation 22) ---
route = {"template": "View the \u2026 assignment for \u2026", "times": 1, "fills": ["phase", "2", "mechanical"],
         "steps": [{"kind": "click", "role": "link", "label": "Mechanical Design ENGR3330 Fall 2026", "fixed": "fall 2026",
                    "slot": "mechanical design engr3330", "site": "canvas.olin.edu", "human": "click link \u2018\u2026 Fall 2026\u2019"},
                   {"kind": "click", "role": "link", "label": "Assignments", "fixed": "assignments", "site": "canvas.olin.edu",
                    "human": "click link \u2018Assignments\u2019"},
                   {"kind": "click", "role": "link", "label": "Phase 1 Strategy Review", "fixed": "", "slot": "phase 1 strategy review",
                    "site": "canvas.olin.edu", "human": "click link \u2018\u2026\u2019"}]}
os.environ["NAVI_USER_ROUTE_JSON"] = json.dumps(route)
ur = nr.UserRoute()
assert ur.route["template"].startswith("View")
dash = [{"index": "1", "label": "Mechanical Design ENGR3330 Fall 2026", "operations": ["CLICK"]},
        {"index": "2", "label": "Applied Mathematics MTH3180 Fall 2026", "operations": ["CLICK"]},
        {"index": "3", "label": "Inbox", "operations": ["CLICK"]}]
body = {"model": "jev-latest", "state": {"page": {"url": "https://canvas.olin.edu/"}, "elements": dash},
        "questions": {"operation": {"type": "choice", "criteria": {}, "instructions": {}},
                      "click_target": {"type": "choice", "criteria": {e["index"]: {"element": e["label"]} for e in dash},
                                       "instructions": {"goal": "g", "rules": "r"}}}}
marked = ur.annotate(body)
els = {e["index"]: e for e in marked["state"]["elements"]}
assert els["1"]["this_user"] == nr.UserRoute.MARK and "this_user" not in els["2"]     # the course the task names
assert marked["state"]["this_users_way"]["steps"][0].startswith("\u2192 ")
assert marked["questions"]["click_target"]["criteria"]["1"]["this_user"] == nr.UserRoute.MARK
assert marked["questions"]["click_target"]["instructions"]["rules"][-1] == nr.USER_ROUTE_RULE
assert "this_user" not in body["state"]["elements"][0]                                # the original request is untouched
ur.observe(marked, {"answers": {"operation": {"choice": "CLICK"}, "click_target": {"choice": "1"}}})
assert ur.done == {0}
course = [{"index": "1", "label": "Assignments", "operations": ["CLICK"]}, {"index": "2", "label": "Modules", "operations": ["CLICK"]}]
body["state"] = {"page": {"url": "https://canvas.olin.edu/courses/1083"}, "elements": course}
again = ur.annotate(body)
assert {e["index"]: e for e in again["state"]["elements"]}["1"]["this_user"] == nr.UserRoute.MARK
assert again["state"]["this_users_way"]["steps"][0].startswith("\u2713 ")
listing = [{"index": "1", "label": "Phase 1 Strategy Review", "operations": ["CLICK"]},
           {"index": "2", "label": "Phase 2 Detailed Design Review", "operations": ["CLICK"]}]
ur.done = {0, 1}
body["state"] = {"page": {"url": "https://canvas.olin.edu/courses/1083/assignments"}, "elements": listing}
third = {e["index"]: e for e in ur.annotate(body)["state"]["elements"]}
assert "this_user" in third["2"] and "this_user" not in third["1"]                    # the task's phase 2, not last time's
# Another site, no route, or junk: untouched.
other = json.loads(json.dumps(body)); other["state"]["page"]["url"] = "https://example.com/"
assert "this_user" not in json.dumps(ur.annotate(other)["state"]["elements"])
os.environ["NAVI_USER_ROUTE_JSON"] = "not json"; assert nr.UserRoute.from_env() is None
os.environ.pop("NAVI_USER_ROUTE_JSON")
assert nr.UserRoute().annotate(body) is body
print("user route OK")

# --- UserPaths: the user's path to the target (items need all their words) and patterns (any site) ---
path = {"template": "your usual way to \u2018Assignment 03\u2019", "times": 3, "fills": [], "source": "path",
        "steps": [{"kind": "click", "role": "link", "label": "Assignment 03", "fixed": "", "slot": "assignment 3", "site": "canvas.olin.edu",
                   "human": "click link \u2018Assignment 03\u2019"}]}
pr = nr.UserRoute(route=path)
listing = [{"index": "1", "label": "Assignment 02", "operations": ["CLICK"]}, {"index": "2", "label": "Assignment 03", "operations": ["CLICK"]},
           {"index": "3", "label": "Lab 3 Report", "operations": ["CLICK"]}]
assert [e["index"] for e in pr.targets(0, "canvas.olin.edu", listing)] == ["2"]            # "03" is "3"; a number with its kind word
assert not pr.label_matches(path["steps"][0], "Lab 3 Report")
pattern = {"template": "signInWithGoogle", "times": 4, "fills": [], "source": "pattern",
           "steps": [{"kind": "click", "role": "button", "label": "Sign in with Google", "fixed": "sign in with google", "site": "",
                      "intent": "signInWithGoogle", "human": "click button \u2018Sign in with Google\u2019"}]}
pt = nr.UserRoute(route=pattern)
dd = [{"index": "1", "label": "Continue with Google", "operations": ["CLICK"]}, {"index": "2", "label": "Continue with Apple", "operations": ["CLICK"]}]
assert [e["index"] for e in pt.targets(0, "doordash.com", dd)] == ["1"]
assert nr.path_intent("Add to cart") == "addToCart" and nr.path_intent("Go to Cart") == "openCart" and nr.path_intent("Inbox") is None
print("user paths OK")

# --- the tab is the deliverable (adaptation 13) ---
for var in ("NAVI_TAB_POLICY", "NAVI_KEEP_TAB"):
    os.environ.pop(var, None)
assert nr.tab_policy() == "keep"
os.environ["NAVI_TAB_POLICY"] = "reveal"; assert nr.tab_policy() == "reveal"
os.environ["NAVI_TAB_POLICY"] = "close"; assert nr.tab_policy() == "close"
os.environ["NAVI_TAB_POLICY"] = "bogus"; os.environ["NAVI_KEEP_TAB"] = "1"; assert nr.tab_policy() == "keep"
assert not nr.should_close_tab("keep", "done", 3)        # a completed effect task keeps its tab
assert not nr.should_close_tab("reveal", "done", 3)
assert nr.should_close_tab("close", "done", 3)           # a background lookup: answer is in the panel
assert not nr.should_close_tab("close", "blocked", 2)    # failures keep the tab so the user can take over
assert not nr.should_close_tab("keep", "cancelled", 1)
assert nr.should_close_tab("keep", "blocked", 0, background=True)      # nothing happened on it, nobody saw it
assert nr.should_close_tab("reveal", "error", 0, background=True)
assert not nr.should_close_tab("keep", "blocked", 0, background=False)  # the user watched it open: it stays
assert not nr.should_close_tab("keep", "cancelled", 0, background=False)
os.environ.pop("NAVI_BACKGROUND_TAB", None); assert not nr.should_close_tab("keep", "cancelled", 0)
os.environ["NAVI_BACKGROUND_TAB"] = "1"; assert nr.should_close_tab("keep", "cancelled", 0)
os.environ.pop("NAVI_BACKGROUND_TAB", None)
print("tab policy OK")

# --- continue on the tab that is open ---
assert nr.same_page("https://www.youtube.com/", "youtube.com")
assert nr.same_page("https://www.youtube.com/results?search_query=x#top", "https://youtube.com/results?search_query=x")
assert not nr.same_page("https://www.youtube.com/", "https://www.youtube.com/feed/history")
assert not nr.same_page("", "")
tabs = [{"type": "page", "targetId": "A", "url": "https://mail.google.com/mail/u/0/#inbox"},
        {"type": "background_page", "targetId": "B", "url": "https://www.youtube.com/"},
        {"type": "page", "targetId": "C", "url": "https://www.youtube.com/"}]
assert nr.find_open_tab("youtube.com", tabs) == "C"
assert nr.find_open_tab("https://mail.google.com/mail/u/0/", tabs) == "A"
assert nr.find_open_tab("https://example.com", tabs) is None
print("attach OK")

# --- a helper with no value is a failed step (adaptation 16) ---
class NoTextAgent:
    def __init__(self):
        self.screenshots = False
        self.pending_text = ("ctx", None, None)
        self.state = {"status": "ready", "decision": None, "decisions": [], "history": [], "started_at": time.perf_counter(),
                      "page": {"url": "https://drive.google.com/drive/shared-with-me", "page_key": [1.0, "u"], "fingerprint": "f1",
                               "actions": [{"id": "e2", "node": 2, "kind": "fill", "label": "Search in Drive"},
                                           {"id": "e2c", "node": 2, "kind": "click", "label": "Open Search in Drive"},
                                           {"id": "e3", "node": 3, "kind": "click", "label": "Shared with me"}]}}
    def command(self, name, body):
        if name == "predict":
            self.state["decision"] = {"operation": "TYPE_TEXT", "choice": "e2", "confidence": 0.8, "operation_probabilities": {"TYPE_TEXT": 0.8}}
            self.state["decisions"].append(self.state["decision"]); self.state["status"] = "predicted"
        elif name == "act":
            raise ValueError("Text helper returned no valid field value; nothing typed.")
import time
na = NoTextAgent(); rj = nr.RejectedClicks()
assert nr.tick(na, set(), rj) == "no_text"
assert na.state["status"] == "ready" and na.state["decision"] is None and na.pending_text is None
h = na.state["history"][-1]
assert h["kind"] == "fill" and h["page_changed"] is False and "no value" in h["note"] and h["action"] == "Search in Drive"
filtered = rj.filter(na.state["page"])
assert [a["id"] for a in filtered["actions"]] == ["e2c", "e3"]          # TYPE_TEXT on that field is gone; its click stays
# Any other ValueError still propagates.
class OtherErrorAgent(NoTextAgent):
    def command(self, name, body):
        if name == "predict": return super().command(name, body)
        raise ValueError("Stopped at the 60-action demo budget")
try:
    nr.tick(OtherErrorAgent(), set(), nr.RejectedClicks()); raise AssertionError("should raise")
except ValueError as exc:
    assert "budget" in str(exc)
print("no-text step OK")

# --- rows and item cards are targets (adaptation 17) ---
js = nr.patched_snapshot_js()
assert "const itemCell=rname==='gridcell'" in js and "rname==='row' || itemCell" in js and "'Open (double-click): '" in js
assert '[role="row"][aria-selected]' in js and "role:rname==='row' ? 'row' : 'item'" in js
calls = []
nr.cdp = fake_cdp
try:
    nr.browser_operation_navi({"operation": "act", "session": "s", "text": None,
                               "action": {"id": "e7", "node": 7, "kind": "click", "dblclick": True, "label": "Open (double-click): Report"}})
    mouse = [(p["type"], p["clickCount"]) for m, p in calls if m == "Input.dispatchMouseEvent"]
    assert mouse == [("mousePressed", 1), ("mouseReleased", 1), ("mousePressed", 2), ("mouseReleased", 2)], mouse
    calls.clear()
    nr.browser_operation_navi({"operation": "act", "session": "s", "text": None, "action": {"id": "e7", "node": 7, "kind": "click", "label": "Report"}})
    assert [(p["type"], p["clickCount"]) for m, p in calls if m == "Input.dispatchMouseEvent"] == [("mousePressed", 1), ("mouseReleased", 1)]
finally:
    nr.cdp = real_cdp
print("rows and items OK")

# --- Adaptation 18: recipient fields pick the contact -------------------------
assert nr.is_recipient_label("To recipients") and nr.is_recipient_label("To") and nr.is_recipient_label("Add guests")
assert not nr.is_recipient_label("Subject") and not nr.is_recipient_label("Search mail") and not nr.is_recipient_label("Message Body")
opts = [
    {"label": "Mike Grandinetti, mike.g@babson.edu", "selected": True, "y": 100},
    {"label": "Mikey, Bhar, Zach, Kilan, +14257800416", "selected": False, "y": 140},
    {"label": "Mikey Ku, mikey.ku@olin.edu", "selected": False, "y": 180},
]
assert nr.choose_suggestion("Mikey", opts)["label"].startswith("Mikey Ku")
assert nr.choose_suggestion("mikey ku", opts)["label"].startswith("Mikey Ku")
# Outlook Web / Gmail suggest the directory name for a nickname.
assert nr.choose_suggestion("mikey ku", [{"label": "Michael Ku Jr, mkujr@olin.edu", "selected": False, "y": 90}])["label"].startswith("Michael")
assert nr.choose_suggestion("mikey smith", [{"label": "Mikey Ku, mikey.ku@olin.edu", "selected": True, "y": 90}]) is None
assert nr.is_group("Mikey, Bhar, Zach, Kilan, +14257800416") and not nr.is_group("Mikey Ku, mikey.ku@olin.edu")
assert nr.looks_like_address("mikey.ku@olin.edu") and not nr.looks_like_address("Mikey")

class FakeCall:
    """Options appear after the second poll; records the click."""
    def __init__(self, options): self.polls = 0; self.options = options; self.clicks = []
    def __call__(self, method, **params):
        if method == "Runtime.evaluate":
            self.polls += 1
            return {"result": {"value": {"value": "mikey", "options": self.options if self.polls > 1 else []}}}
        if method == "Input.dispatchMouseEvent":
            self.clicks.append((params["type"], params["x"], params["y"]))
        return {}

saved = (nr.RECIPIENT_FIRST_LOOK_S, nr.RECIPIENT_POLL_S)
nr.RECIPIENT_FIRST_LOOK_S, nr.RECIPIENT_POLL_S = 0, 0.001
fc = FakeCall([dict(o, x=50, y=o["y"]) for o in opts])
note = nr.pick_recipient(fc, 7, "Mikey")
assert "Mikey Ku" in note and "recipient set" in note, note
assert fc.clicks and fc.clicks[0][2] == 180, fc.clicks
fc = FakeCall([])
note = nr.pick_recipient(fc, 7, "Zxqvwt")
assert "NOT set" in note and not fc.clicks, note
nr.RECIPIENT_FIRST_LOOK_S, nr.RECIPIENT_POLL_S = saved
print("recipient picking ok")

# Adaptation 23: a modal in front is all Jev can click; app-install detours are dropped.
js = nr.patched_snapshot_js()
assert "const modals=" in js and "modals.some(m=>within(m,e))" in js
mcd = {"actions": [{"id": "e1", "kind": "click", "label": "Close"},
                   {"id": "e2", "kind": "click", "label": "Order Pickup Scan the code, download the McD’s app & start earning points.*"},
                   {"id": "e3", "kind": "click", "label": "Order Delivery"},
                   {"id": "e4", "kind": "click", "label": "Open in App Store"},
                   {"id": "e5", "kind": "fill", "label": "Search the app store"}]}
kept = [a["id"] for a in nr.drop_app_detours(mcd, "go to mcdonalds and order me a burger")["actions"]]
assert kept == ["e1", "e3", "e5"], kept
assert nr.drop_app_detours(mcd, "download the mcdonalds app") is mcd
print("app detours ok")

# Adaptation 24: the user's card reaches the text helper for a personal field only.
os.environ["NAVI_USER_PROFILE_JSON"] = json.dumps({"address": "1000 Olin Way, Needham, MA 02492", "zip": "02492", "phone": " "})
assert nr.user_profile() == {"address": "1000 Olin Way, Needham, MA 02492", "zip": "02492"}
ctx = {"goal": "order me a burger", "field": {"label": "Zip or City & State", "role": "textbox"}}
assert nr.with_user_details(ctx)["about_the_user"]["zip"] == "02492"
assert "about_the_user" not in nr.with_user_details({"goal": "x", "field": {"label": "Search menu", "role": "searchbox"}})
captured.clear()
nr.field_text_claude({"goal": "order me a burger", "field": {"label": "Delivery address", "role": "textbox"}, "page": {"url": "https://mcdonalds.order.online"}})
sent = json.loads(captured["json"]["messages"][0]["content"])
assert sent["about_the_user"]["address"].startswith("1000 Olin Way") and "about_the_user" in captured["json"]["system"]
del os.environ["NAVI_USER_PROFILE_JSON"]
assert nr.with_user_details(ctx) is ctx
print("user details ok")

# Nothing done on the page yet: Claude's coaching notes and waits are not actions.
assert not nr.acted_on_page([{"kind": "coach"}, {"kind": "wait"}])
assert nr.acted_on_page([{"kind": "coach"}, {"kind": "click"}])
print("early block ok")

# Adaptation 26/27 and circling.
assert "e.tagName!=='SELECT'" in nr.SELECT_JS and "elementFromPoint" not in nr.SELECT_JS
amz = {"actions": [{"id": "e1", "kind": "click", "label": "Add to Cart"}, {"id": "e2", "kind": "click", "label": "Buy Now"},
                   {"id": "e3", "kind": "click", "label": "Place your order"}, {"id": "e4", "kind": "click", "label": "Proceed to checkout"},
                   {"id": "e5", "kind": "select", "label": "Sort by: → Price: Low to High"}]}
assert [a["id"] for a in nr.drop_payments(amz)["actions"]] == ["e1", "e4", "e5"]
assert nr.purchase_note("buy a roll of toilet paper from amazon", "done").startswith("Ready for you to place the order")
assert nr.purchase_note("open my amazon orders", "done") == ""
loop = [{"kind": "click", "action": a, "page_changed": True} for a in ["Order Now", "Order Delivery", "Yes, Continue"] * 2]
assert "going in circles" in nr.Coach.flailing(loop), nr.Coach.flailing(loop)
assert nr.Coach.flailing([{"kind": "click", "action": a, "page_changed": True} for a in ["Search", "Item A", "Add", "Back", "Item B", "Add"]]) is None
print("payments, selects and circles ok")

# Adaptations 28/29: reachable targets, names for unnamed controls, pointer-cursor cards.
js = nr.patched_snapshot_js()
for needle in ["if (covered(e,r)) continue;", "fallbackName(e,rname)", "sameLabel[a.label]>1", "cursor==='pointer'", "pointer:true"]:
    assert needle in js, needle
print("snapshot structure ok")

# Adaptation 30: DONE needs evidence; adaptation 31: dates.
import datetime as _dt
st = {"goal": "order me a random chipotle bowl", "page": {"text": "BUILD YOUR BURRITO BOWL\nADD TO BAG", "url": "https://www.chipotle.com/order/build/burrito-bowl", "actions": []}, "history": []}
assert nr.done_doubt(st, {"operation": "CLICK", "confidence": 0.9}) is None and st["navi_cart_start"] is None
assert "cart or bag" in nr.done_doubt(st, {"operation": "DONE", "confidence": 0.9})
st["page"] = {"text": "Big Mac added to cart", "url": "https://x.test/store", "actions": []}
assert nr.done_doubt(st, {"operation": "DONE", "confidence": 0.9}) is None
st2 = {"goal": "go to mcdonalds and order me a burger", "page": {"text": "", "url": "https://x.test", "actions": [{"label": "0 items, open Order Cart"}]}, "history": []}
nr.done_doubt(st2, None)
st2["page"] = {"text": "", "url": "https://x.test", "actions": [{"label": "1 items, open Order Cart"}]}
assert nr.done_doubt(st2, {"operation": "DONE", "confidence": 0.8}) is None
assert nr.cart_count({"text": "6 items in cart", "actions": []}) == 6 and nr.cart_count({"text": "Bag (2)", "actions": []}) == 2
st3 = {"goal": "track my amazon order", "page": {"text": "", "url": "https://x.test", "actions": []}, "history": []}
assert nr.done_doubt(st3, {"operation": "DONE", "confidence": 0.9}) is None
assert "unsure" in nr.done_doubt(st3, {"operation": "DONE", "confidence": 0.3})
fri = _dt.date(2026, 10, 30)   # a Friday
f = nr.date_facts("find flights from boston to new york next friday", fri)
assert f["today"] == "Friday, October 30, 2026" and f["dates_in_goal"]["next friday"] == "Friday, November 6, 2026", f
assert nr.date_facts("dinner on sunday", fri)["dates_in_goal"]["on sunday"] == "Sunday, November 1, 2026"
assert nr.date_facts("book it tomorrow", fri)["dates_in_goal"]["tomorrow"] == "Saturday, October 31, 2026"
assert "dates_in_goal" not in nr.date_facts("open youtube", fri)
print("done evidence and dates ok")

# Adaptation 32: typed outcomes, the takeover, and the Broken-pipe diagnosis.
import httpx as _httpx
# The false "completed" answers from the 2026-10-29/30 logs all say they were not done.
for t in ["I couldn't open DoorDash from here - the screen is still showing your Amazon cart",
          "I cannot complete the \"add to cart\" action as I can only view and report on visible text",
          "The song playing isn't confirmed as the newest one",
          "I don't see a playlist named Focus in your library",
          "The note titled Student Spark hasn't been created yet."]:
    assert nr.says_could_not(t), t
for t in ["Big Mac is in your bag — ready for you to place the order.", "Music is playing now: Ain't In LA by Adéla.",
          "The note Student Spark now says hello class."]:
    assert not nr.says_could_not(t), t
v = nr.normalize_verdict({"verdict": "achieved", "answer": "I couldn't add it to the bag."})
assert v["verdict"] == "partial", v
assert nr.normalize_verdict({"verdict": "Not achieved", "answer": "x"})["verdict"] == "not_achieved"
assert nr.normalize_verdict({"verdict": "banana"})["verdict"] == "not_achieved"
assert nr.normalize_verdict({"verdict": "needs-user", "answer": "Pick your Google account."})["verdict"] == "needs_user"
assert nr.json_object('```json\n{"verdict": "achieved"}\n```') == {"verdict": "achieved"}
# Escalation: met → done; impossible / needs the user → end; else Claude takes over while it may.
assert nr.escalation({"verdict": "achieved"}, True) == "done"
assert nr.escalation({"verdict": "needs_user"}, True) == "end"
assert nr.escalation({"verdict": "impossible"}, True) == "end"
assert nr.escalation({"verdict": "partial"}, True) == "takeover"
assert nr.escalation({"verdict": "not_achieved"}, False) == "end"
assert nr.escalation(None, True) == "takeover"              # the judge was unreachable: drive anyway
assert nr.escalation(None, False) == "coach"
assert nr.escalation({"verdict": "not_achieved"}, True, acted_since_last_takeover=False) == "end"
assert nr.outcome_status({"verdict": "achieved"}) == "done" and nr.outcome_status({"verdict": "partial"}) == "blocked"
assert nr.takeover_result("Done: Big Mac in the bag", 3) == "done"
assert nr.takeover_result("Stopped: pick your Google account", 1) == "stopped"
assert nr.takeover_result("Did: opened the menu", 2) == "handback" and nr.takeover_result("", 0) == "no_progress"
os.environ.pop("NAVI_JUDGE", None)
assert nr.should_judge_done(0.63) and not nr.should_judge_done(0.95)
os.environ["NAVI_JUDGE"] = "0"; assert not nr.should_judge_done(0.1); os.environ.pop("NAVI_JUDGE")
# Keys, the gate, Navi never pays.
assert nr.parse_key("Return")[:4] == ("Enter", "Enter", 13, "\r")
k = nr.parse_key("cmd+a"); assert k[4] == 4 and (k[5] == ["selectAll"] or sys.platform != "darwin") and k[3] is None
assert nr.parse_key("shift+Tab")[4] == 8 and nr.parse_key("a")[3] == "a"
try:
    nr.parse_key("hyper+q"); raise AssertionError("bad modifier accepted")
except ValueError:
    pass
assert nr.gate_stops("order me a burger", 0.1, 0.9) and "credentials" in nr.gate_stops("x", 0, 0.9)
assert nr.gate_stops("open the sign in dialog", 0.8, 0.1, mode="askForRisky")
assert nr.gate_stops("send mom a text saying hi", 0.8, 0.1, mode="askForRisky") is None
assert nr.gate_stops("send mom a text saying hi", 0.8, 0.1, mode="alwaysAsk")
assert nr.gate_stops("open the sign in dialog", 0.8, 0.1, mode="autonomous") is None
assert nr.pays_refusal("Place Order · $11.59") and nr.pays_refusal("Add to cart") is None
# Older screenshots are pruned from the takeover's conversation.
msgs = [{"role": "user", "content": [{"type": "image", "source": {}}]}] + [
    {"role": "user", "content": [{"type": "tool_result", "content": [{"type": "image", "source": {}}]}]} for _ in range(4)]
nr.prune_images(msgs, keep=3)
imgs = sum(1 for m in msgs for b in m["content"] for p in (b.get("content") if b.get("type") == "tool_result" else [b]) if p.get("type") == "image")
assert imgs == 3 and msgs[0]["content"][0]["type"] == "text"

# JPEG size from the SOF marker (screenshots are scaled to ≤ 1280 px; clicks map back by the ratio).
JPEG = b"\xff\xd8\xff\xe0\x00\x04ab\xff\xc0\x00\x11\x08\x03\x20\x05\x00" + b"\x00" * 64
assert nr.jpeg_size(JPEG) == (1280, 800), nr.jpeg_size(JPEG)
import base64 as _b64


class FakeTab:
    def __init__(self):
        self.calls = []; self.url = "https://www.doordash.com/"; self.fp = "a"; self.secret = False

    def evaluate(self, js):
        if js.startswith("[innerWidth"):
            return [1280, 800, 0, 120, 2]
        if js.startswith(nr.AT_POINT_JS):
            x = float(js[len(nr.AT_POINT_JS) + 1:].split(",")[0])
            return {"label": "Place Order" if x > 1000 else "Continue with Google", "tag": "BUTTON", "frame": False}
        if js == nr.SECRET_FIELD_JS:
            return self.secret
        return None

    def call(self, method, **kw):
        self.calls.append((method, kw))
        if method == "Page.captureScreenshot":
            return {"data": _b64.b64encode(JPEG).decode()}
        return {}

    def observe(self, screenshot=False):
        return {"url": self.url, "fingerprint": self.fp, "title": "DoorDash"}


tab = FakeTab()
shot, ratio = nr.viewport_shot(tab)
cap = [kw for m, kw in tab.calls if m == "Page.captureScreenshot"][0]
assert cap["clip"]["scale"] == 0.5 and cap["clip"]["y"] == 120 and ratio == 1.0, (cap, ratio)


class FakeAgent:
    def __init__(self, tab):
        self.state = {"browser": tab, "page": {"url": tab.url, "fingerprint": "a", "title": "DoorDash"}, "history": []}


replies = []


def fake_claude(body, timeout=90, what="Claude"):
    return replies.pop(0)


real_claude_post, real_gate = nr.claude_post, nr.gate_verdict
nr.claude_post = fake_claude
nr.gate_verdict = lambda goal, says, proposed, recent: (0.1, 0.0)
emitted = []
real_emit = nr.emit
nr.emit = lambda event, **f: emitted.append((event, f))
try:
    steps = []
    replies[:] = [
        {"stop_reason": "tool_use", "content": [{"type": "text", "text": "The sign-in dialog is open."},
                                                 {"type": "tool_use", "id": "t1", "name": "left_click", "toolset_name": "computer", "input": {"coordinate": [640, 400]}},
                                                 {"type": "tool_use", "id": "t2", "name": "left_click", "toolset_name": "computer", "input": {"coordinate": [1100, 400]}}]},
        {"stop_reason": "end_turn", "content": [{"type": "text", "text": "Stopped: pick your Google account in the window that opened."}]},
    ]
    t = nr.Takeover()
    res = t.run(FakeAgent(tab), "Sign into DoorDash with my Google account", "going in circles", None, steps.append)
    assert res["result"] == "stopped" and res["actions"] == 1, res
    assert steps[0]["action"] == "Claude: click ‘Continue with Google’" and steps[0]["kind"] == "takeover", steps
    presses = [kw for m, kw in tab.calls if m == "Input.dispatchMouseEvent" and kw["type"] == "mousePressed"]
    assert len(presses) == 1 and presses[0]["x"] == 640.0, presses           # the Place Order click never happened
    assert any("Navi never pays" in f.get("message", "") for e, f in emitted)
    assert t.available() and t.count == 1
    # Navi never types into a password / code / card field.
    tab.secret = True
    replies[:] = [{"stop_reason": "tool_use", "content": [{"type": "tool_use", "id": "t3", "name": "type", "toolset_name": "computer", "input": {"text": "hunter2"}}]},
                  {"stop_reason": "end_turn", "content": [{"type": "text", "text": "Stopped: the password is yours to type."}]}]
    res = t.run(FakeAgent(tab), "Sign into DoorDash", "stuck", None, steps.append)
    assert res["result"] == "stopped" and not any(m == "Input.insertText" for m, kw in tab.calls)
    # The gate stops an irreversible turn the goal did not ask for.
    nr.gate_verdict = lambda goal, says, proposed, recent: (0.9, 0.0)
    tab.secret = False
    replies[:] = [{"stop_reason": "tool_use", "content": [{"type": "tool_use", "id": "t4", "name": "key", "toolset_name": "computer", "input": {"text": "Return"}}]}]
    res = t.run(FakeAgent(tab), "find the dinner menu", "stuck", None, steps.append)
    assert res["result"] == "stopped" and "yours" in res["summary"] and not t.available(), res   # 3 takeovers used
    # A first takeover hands back to Jev as soon as the page moved to a new document.
    nr.gate_verdict = lambda goal, says, proposed, recent: (0.1, 0.0)
    t2 = nr.Takeover()
    tab2 = FakeTab()
    agent2 = FakeAgent(tab2)
    replies[:] = [{"stop_reason": "tool_use", "content": [{"type": "tool_use", "id": "t5", "name": "left_click", "toolset_name": "computer", "input": {"coordinate": [100, 100]}}]}]
    real_observe = tab2.observe
    tab2.observe = lambda screenshot=False: {"url": "https://www.doordash.com/store/7th-street-burger", "fingerprint": "b", "title": "7th Street Burger"}
    res = t2.run(agent2, "order me a burger", "going in circles", None, steps.append)
    assert res["result"] == "handback" and res["actions"] == 1 and replies == [], res
    # Custom tool results carry no toolset_name; computer ones do.
    assert "toolset_name" not in nr.Takeover.result({"id": "x", "name": "go_back"})
    assert nr.Takeover.result({"id": "x", "name": "left_click", "toolset_name": "computer"})["toolset_name"] == "computer"
finally:
    nr.claude_post, nr.gate_verdict, nr.emit = real_claude_post, real_gate, real_emit

# The Broken pipe: a transport error is retried on a fresh connection instead of ending the diagnosis.
attempts = []


def flaky_post(url, headers=None, json=None, timeout=None):
    attempts.append(url)
    if len(attempts) == 1:
        raise _httpx.WriteError("[Errno 32] Broken pipe")
    return FakeResp(200, {"content": [{"type": "text", "text": '{"verdict": "achieved", "answer": "Signed in.", "next_step": ""}'}]})


real_client_post = nr.CLAUDE_CLIENT.post
nr.CLAUDE_CLIENT.post = flaky_post
try:
    v = nr.judge("sign in", {"url": "https://x.test", "title": "t", "text": ""}, [], "check")
    assert v["verdict"] == "achieved" and len(attempts) == 2, (v, attempts)
    c = nr.Coach()
    attempts.clear()

    def coach_post(url, headers=None, json=None, timeout=None):
        attempts.append(url)
        if len(attempts) == 1:
            raise _httpx.WriteError("[Errno 32] Broken pipe")
        return FakeResp(200, {"content": [{"type": "text", "text": '{"diagnosis": "d", "guidance": "Click [2]."}'}]})

    nr.CLAUDE_CLIENT.post = coach_post
    c.ask("g", {"url": "https://x.test", "title": "t", "text": "", "actions": []}, [], "circling")
    assert c.guidance == "Click [2]." and len(attempts) == 2
finally:
    nr.CLAUDE_CLIENT.post = real_client_post
print("takeover, typed outcomes and broken pipe ok")
# Adaptations 33–36 (pure parts; scripts/ultrafast/test_perception_chrome.py runs the fixtures in Chrome).
js = nr.patched_snapshot_js()
for needle in ["deepAll(selector)", "deepHit(px,py)", "within(e,t)", "overlayLayer()", "cache.modals=modals",
               "STYLE|SCRIPT|NOSCRIPT|TEMPLATE", "frame_candidates:", "dialog:modals.length", "modalPass"]:
    assert needle in js, needle
assert nr.scrub_label("Build Your Pizza - $11.39 .prism-size-msf7vl > * { --prism-inline-children-spacing: var(--x); }") == "Build Your Pizza - $11.39"
assert nr.scrub_label("#2 Most Liked .prism-size-msf7vl > * { --prism-inline-children-spacing: var(--") == "#2 Most Liked"
assert nr.scrub_label("Sizes {S, M, L}") == "Sizes {S, M, L}"          # braces without CSS stay
top = {"url": "https://www.doordash.com/home", "w": 1120, "h": 780, "text": "Home\nDeals", "dialog": "Sign in or Sign up",
       "guards": {"1": ["g"]}, "actions": [{"id": "e1", "node": 1, "kind": "click", "label": "Close Sign in or Sign up", "role": "button",
                                            "rect": {"x": 300, "y": 110, "w": 20, "h": 20}},
                                           {"id": "wait", "kind": "wait", "label": "Wait for the page to update"}]}
frame = {"id": "F1", "parent": "TOP", "session": "s", "url": "https://identity.doordash.com/auth"}
ref = {"x": 280.0, "y": 164.0, "clip": (280.0, 164.0, 840.0, 729.0), "modal": True, "reachable": True}
snap = {"url": "https://identity.doordash.com/auth", "text": "Sign in or Sign up\nContinue with Google", "page_key": ["pk"],
        "guards": {"1000001": ["g1"], "1000002": ["g2"]},
        "actions": [{"id": "e1", "node": 1000001, "kind": "click", "label": "Continue with Google", "role": "button", "rect": {"x": 20, "y": 80, "w": 200, "h": 40}},
                    {"id": "e2", "node": 1000002, "kind": "click", "label": "Hidden behind", "role": "button", "rect": {"x": 20, "y": 200, "w": 200, "h": 40}},
                    {"id": "wait", "kind": "wait", "label": "Wait"}]}
page = nr.merge_frames(json.loads(json.dumps(top)), [{"frame": frame, "ref": ref, "info": {"title": "Login/Signup"}, "snapshot": snap, "hits": [True, False]}])
assert [(a["id"], a["label"]) for a in page["actions"]] == [("e1", "Close Sign in or Sign up"), ("e2", "Continue with Google"), ("wait", "Wait for the page to update")]
g = page["actions"][1]
assert g["frame"] == "F1" and g["rect"]["x"] == 300 and g["rect"]["y"] == 244 and page["guards"]["1000001"] == ["g1"]
assert page["text"].startswith("Sign in or Sign up\nContinue with Google\nHome") and page["frames"]["F1"]["page_key"] == ["pk"]
assert nr.perception_gap(page) is None
# Behind the page's dialog: nothing from the frame.
assert len(nr.merge_frames(json.loads(json.dumps(top)), [{"frame": frame, "ref": dict(ref, modal=False), "info": {}, "snapshot": snap, "hits": [True, True]}])["actions"]) == 2
# Before the fix: the dialog offered only Close → a gap, named.
gap = nr.perception_gap(json.loads(json.dumps(top)))
assert gap["reason"] == "empty_dialog" and "Sign in or Sign up" in gap["detail"], gap
# A big frame with nothing in it, and a captcha.
empty = nr.merge_frames(json.loads(json.dumps(top)), [{"frame": frame, "ref": ref, "info": {}, "snapshot": {"actions": [], "text": ""}, "hits": []}])
assert nr.perception_gap(empty)["reason"] == "unreadable_frame"
cap = dict(frame, url="https://www.google.com/recaptcha/api2/anchor?k=1&size=normal")
capped = nr.merge_frames(json.loads(json.dumps(top)), [{"frame": cap, "ref": ref, "info": {}, "snapshot": dict(snap, url=cap["url"]), "hits": [True, True]}])
assert len(capped["actions"]) == 2 and nr.perception_gap(capped)["reason"] == "captcha"
badge = dict(frame, url="https://www.google.com/recaptcha/enterprise/anchor?k=1&size=invisible")
assert "unread_frames" not in nr.merge_frames(json.loads(json.dumps(top)), [{"frame": badge, "ref": ref, "info": {}, "snapshot": None, "hits": []}])
# A click that changed pixels but not the DOM.
before = {"fingerprint": "f", "url": "u"}
after = {"fingerprint": "f", "url": "u", "actions": [{"kind": "click", "label": "Play"}]}
assert nr.perception_gap(after, before, {"kind": "click", "label": "Play"}, 0.4)["reason"] == "unseen_change"
assert nr.perception_gap(after, before, {"kind": "click", "label": "Play", "canvas": True}, 0.4) is None
assert nr.perception_gap(after, before, {"kind": "click", "label": "Play"}, 0.02) is None
assert nr.visual_change([0] * 10, [0] * 8 + [200, 200]) == 0.2 and nr.visual_change(None, [1]) is None
# Unnamed controls: many are clutter, one gets a place.
pins = {"w": 1000, "h": 600, "actions": [{"id": f"e{i}", "node": i, "kind": "click", "role": "button", "label": "button",
                                          "rect": {"x": 10 * i, "y": 300, "w": 10, "h": 10}} for i in range(1, 8)]
        + [{"id": "e9", "node": 9, "kind": "click", "role": "link", "label": "link", "rect": {"x": 950, "y": 10, "w": 30, "h": 30}}]}
assert [a["label"] for a in nr.tidy_unnamed(pins)["actions"]] == ["link with no label at the top right"] and pins["omitted_unnamed"] == 7
print("frames, labels, unnamed controls and perception gaps ok")
