"""Adaptation 38: a failed Jev call is a stop to judge, not the end of the run.

    cd vendor/jev-ultrafast && PYTHONPATH=. ~/Navi/vendor/jev-ultrafast/.venv/bin/python \
        ../../scripts/ultrafast/test_model_errors.py

Replays the live Uber Eats failure (2026-10-31): right after "Add 1 to order" Jev answered
HTTP 400 {"detail": {"error_type": "max_tokens_exceeded"}} and the run ended as a raw error.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
for k in ("AI_GATEWAY_API_KEY", "TEXT_MODEL_API_KEY", "ANTHROPIC_BASE_URL", "NAVI_JEV_TRANSPORT",
          "NAVI_CLOUD_URL", "NAVI_CLOUD_TOKEN", "NAVI_PLAYBOOKS_JSON", "NAVI_USER_CONTEXT_JSON",
          "NAVI_USER_MOVES_JSON", "NAVI_USER_ROUTE_JSON", "NAVI_USER_SAID_JSON", "NAVI_TAKEOVER", "NAVI_JUDGE"):
    os.environ.pop(k, None)
os.environ.update(TYPESAFE_API_KEY="ts-test", ANTHROPIC_API_KEY="sk-test", NAVI_TAB_POLICY="keep")
import navi_runner as nr  # noqa: E402
from jev_ultrafast import model as jev_model  # noqa: E402
import jev_ultrafast.agent as agent_module  # noqa: E402

TOO_BIG = {"detail": {"error_type": "max_tokens_exceeded"}}


class FakeResp:
    def __init__(self, status, body):
        self.status_code = status
        self._b = body

    @property
    def is_error(self):
        return self.status_code >= 400

    def json(self):
        return self._b


events = []
nr.emit = lambda event, **fields: events.append({"event": event, **fields})

jev_sent = []          # every Jev body that reached the wire
jev_script = []        # queued (status, body); empty → the size rule below
JEV_LIMIT_CHARS = int(nr.JEV_TOKEN_BUDGET * nr.CHARS_PER_TOKEN)   # this fake Jev refuses what the guard calls too big


def jev_ok(body):
    q = body["questions"]
    ops = list(q["operation"]["criteria"])
    answers = {"operation": {"type": "choice", "choice": ops[0], "confidence": 0.9,
                             "probabilities": {o: (1.0 if i == 0 else 0.0) for i, o in enumerate(ops)}}}
    for name, question in q.items():
        if name.endswith("_target"):
            ids = list(question["criteria"])
            answers[name] = {"type": "choice", "choice": ids[0], "confidence": 0.9,
                             "probabilities": {t: (1.0 if i == 0 else 0.0) for i, t in enumerate(ids)}}
    return {"model": "jev-test", "answers": answers, "usage": {"input_tokens": 1}}


def fake_jev_post(url, json=None, headers=None):
    assert "typesafe.ai" in url, url
    jev_sent.append(json)
    if jev_script:
        status, body = jev_script.pop(0)
        return FakeResp(status, body)
    if len(globals()["json"].dumps(json, ensure_ascii=False)) > JEV_LIMIT_CHARS:
        return FakeResp(400, TOO_BIG)
    return FakeResp(200, jev_ok(json))


jev_model.CLIENT.post = fake_jev_post
jev_model.CLIENT.get = lambda *a, **k: None      # warm_connections stays offline

nr.install_adaptations()
assert nr.RAW_JEV_POST[0] is nr.post_json_typesafe


def card(i, words):
    return f"Item {i} $18.75 • 100% (5) " + " ".join(["juicy beef patty, cheddar, pickles, house sauce"] * words) + " Quick Add"


def store_page(n=120, words=12):
    """An Uber Eats store page whose Quick Add links are named by their whole card."""
    actions = [{"id": f"a{i}", "node": i, "kind": "click", "role": "link", "label": card(i, words), "value": ""}
               for i in range(1, n + 1)]
    return {"url": "https://www.ubereats.com/store/wingstop/x", "title": "Wingstop", "text": "Menu " * 1500,
            "actions": actions, "fingerprint": "fp-store"}


# --- the request is measured and cut before it leaves ---
page = store_page()
del jev_sent[:], events[:]
decision = agent_module.choose(page, "Order Wingstop food under $20", [])
assert decision["operation"] == "CLICK" and decision["choice"] == "a1", decision["operation"]
assert len(jev_sent) == 1, len(jev_sent)
sent = jev_sent[0]
assert not nr.too_large(sent), nr.request_shape(sent)
assert all(len(e["label"]) <= 160 for e in sent["state"]["elements"])
assert set(sent["questions"]["click_target"]["criteria"]) == {str(i) for i in range(1, 121)}   # ids intact
assert sent["questions"]["operation"]["instructions"]["rules"] == jev_model.NEXT_ACTION       # rules whole
assert any(e["event"] == "status" and "shorter version" in e["message"] for e in events)
assert not any(e["event"] == "model_error" for e in events)
# the uncut request really was over the budget
uncut = decision["request"]
assert nr.too_large(uncut) and nr.request_shape(uncut)["longest_label"] > 500

# a small request is sent exactly as built (no cutting on ordinary pages)
small = {"actions": page["actions"][:5], **{k: page[k] for k in ("url", "title", "fingerprint")}, "text": "Menu"}
del jev_sent[:], events[:]
d = agent_module.choose(small, "Order Wingstop food under $20", [])
assert jev_sent[0] == d["request"] and not events
print("request budget ok")

# --- 400 max_tokens_exceeded: logged with its body, retried shorter, then fine ---
budget = nr.JEV_TOKEN_BUDGET
nr.JEV_TOKEN_BUDGET = 10**9                 # the estimate missed (dense text): Jev says no first
limit, JEV_LIMIT_CHARS = JEV_LIMIT_CHARS, 10**9   # … and takes the first shorter version
jev_script[:] = [(400, TOO_BIG)]
del jev_sent[:], events[:]
decision = agent_module.choose(page, "Order Wingstop food under $20", [])
nr.JEV_TOKEN_BUDGET, JEV_LIMIT_CHARS = budget, limit
assert decision["operation"] == "CLICK"
assert len(jev_sent) == 2, len(jev_sent)
errors = [e for e in events if e["event"] == "model_error"]
assert len(errors) == 1, errors
err = errors[0]
assert err["status"] == 400 and err["detail"] == {"error_type": "max_tokens_exceeded"}, err
assert err["attempt"] == 1 and err["request"]["elements"] == 120 and err["request"]["choices"]["click_target"] == 120
assert "Menu" not in json.dumps(err) and "juicy" not in json.dumps(err)     # sizes only, never page words
assert len(json.dumps(jev_sent[1])) < len(json.dumps(jev_sent[0]))
print("400 → logged, retried shorter ok")

# --- refused even at the hardest cut: Jev sees the controls likeliest for the goal ---
crowded = store_page(n=250, words=12)
crowded["actions"][240]["label"] = "Wingstop 10 Wings Combo $17.99 Quick Add"
crowded["actions"].insert(0, {"id": "q", "node": 999, "kind": "fill", "role": "searchbox", "label": "Search Uber Eats", "value": ""})
del jev_sent[:], events[:]
decision = agent_module.choose(crowded, "Order Wingstop wings under $20", [])
statuses = [e["message"] for e in events if e["event"] == "status"]
assert any("likeliest controls" in m for m in statuses), statuses
last = jev_sent[-1]
assert len(last["state"]["elements"]) == nr.TRIMMED_ACTIONS, len(last["state"]["elements"])
labels = [e["label"] for e in last["state"]["elements"]]
assert labels[0] == "Search Uber Eats" and any(l.startswith("Wingstop 10 Wings") for l in labels)
assert decision["choice"] in {a["id"] for a in crowded["actions"]}    # acts on the real page
few = nr.fewer_actions(crowded, "Order Wingstop wings under $20")
assert [a["id"] for a in few["actions"]][:3] == ["q", "a1", "a2"]   # page order kept
assert nr.fewer_actions(small, "x") is small
print("fewer controls when still too large ok")

# --- a 422 echoes the request back: the body is redacted ---
detail = nr.error_detail(FakeResp(422, {"detail": [{"type": "too_long", "loc": ["body", "questions", "click_target"],
                                                     "msg": "Dictionary should have at most 255 items", "input": "{\"1\": \"Bella Chen 617…\"}",
                                                     "ctx": {"max_length": 255}}]}))
assert detail == [{"type": "too_long", "loc": ["body", "questions", "click_target"],
                   "msg": "Dictionary should have at most 255 items"}], detail
assert nr.error_detail(FakeResp(400, {"detail": {"error_type": "x", "input": "secret page text"}})) == {"error_type": "x"}

# --- a failure that persists: one retry, then JevUnavailable (never an endless loop) ---
del jev_sent[:], events[:]
jev_script[:] = [(500, {"error": "boom"}), (500, {"error": "boom"})]
try:
    agent_module.choose(small, "Order Wingstop food under $20", [])
    raise AssertionError("expected JevUnavailable")
except nr.JevUnavailable as exc:
    assert "HTTP 500" in str(exc), str(exc)
assert len(jev_sent) == 2 and [e["attempt"] for e in events if e["event"] == "model_error"] == [1, 2]
# a refusal by Navi Cloud is never retried or swallowed
calls = []


def refusing(url, key, body):
    calls.append(1)
    raise nr.CloudError("signed out", code="signed_out")


try:
    nr.guarded_jev(refusing)("https://api.typesafe.ai/v1/systemone", "k", {"questions": {}, "state": {}})
    raise AssertionError("expected CloudError")
except nr.CloudError:
    assert calls == [1]
print("retry once, then give up ok")


# --- the run: a 400 mid-run goes to the judge, and a filled cart ends achieved ---

class FakeBrowser:
    pages = []

    def __init__(self, url):
        self.target = "tab-1"
        self.page = dict(FakeBrowser.pages[0])

    def observe(self, screenshot=True):
        return dict(self.page)

    def fresh(self, page):
        return page.get("fingerprint") == self.page.get("fingerprint")

    def evaluate(self, expression):
        return "complete"

    def call(self, method, **params):
        raise RuntimeError("no CDP in tests")

    def act(self, action, page, text=None):
        raise AssertionError("no action may run after a failed decision")

    def close(self):
        pass


nr.FastBrowser = FakeBrowser
nr.JUDGE_SETTLE_S = 0
nr.GROWTH_CHECK_S = 0
judged = []


def fake_claude(url, headers=None, json=None, timeout=None):
    judged.append(json)
    verdict = {"verdict": "achieved", "answer": "10 Wings ($17.99) are in your cart.", "next_step": ""}
    return FakeResp(200, {"content": [{"type": "text", "text": globals()["json"].dumps(verdict)}]})


nr.CLAUDE_CLIENT.post = fake_claude


def run_main(goal):
    del events[:], jev_sent[:], judged[:]
    sys.argv = ["navi_runner.py", "--url", "https://www.ubereats.com/store/wingstop/x", "--goal", goal]
    return nr.main()


cart = store_page()
cart["text"] = "Your cart · 10 Wings $17.99 · Checkout"
FakeBrowser.pages = [cart]
jev_script[:] = [(400, TOO_BIG)]       # refused at the hardest cut, with no controls left to drop
code = run_main("Order Wingstop food under $20")
assert code == 0, (code, events)
assert not any(e["event"] == "error" for e in events), [e for e in events if e["event"] == "error"]
errors = [e for e in events if e["event"] == "model_error"]
assert [(e["status"], e["compacted"]) for e in errors] == [(400, 2)] and not jev_script, errors
assert len(judged) == 1
why = json.loads(judged[0]["messages"][0]["content"][-1]["text"])["why_asked"]
assert why == "Jev couldn't decide on this page (HTTP 400: max_tokens_exceeded)", why
done = [e for e in events if e["event"] == "done"]
assert len(done) == 1 and done[0]["status"] == "done" and done[0]["outcome"] == "achieved", done
assert "10 Wings" in done[0]["summary"] and done[0]["summary"].startswith("Ready for you to place the order")
print("400 mid-run → judged achieved ok")

# --- without Claude, the same failure is an honest stop, not a raw error ---
os.environ.pop("ANTHROPIC_API_KEY")
jev_script[:] = [(400, TOO_BIG)]
code = run_main("Order Wingstop food under $20")
assert code == 0 and not judged
assert not any(e["event"] == "error" for e in events), [e for e in events if e["event"] == "error"]
done = [e for e in events if e["event"] == "done"]
assert len(done) == 1 and done[0]["status"] == "blocked" and done[0]["outcome"] == "not_achieved", done
print("400 mid-run without Claude → honest stop ok")
print("model errors (adaptation 38): OK")
