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
assert "getClientRects" in nr.CLICK_POINT_JS and "e.contains(t)" in nr.CLICK_POINT_JS
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
