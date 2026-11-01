"""Adaptations 39–40 and the judge fixes from the 2026-11-01 overnight bench.

    cd vendor/jev-ultrafast && PYTHONPATH=. ~/Navi/vendor/jev-ultrafast/.venv/bin/python \
        ../../scripts/ultrafast/test_takeover_safety.py

- schoolwork-027 (Desmos): an unsure DONE let Jev wander into the sign-up dialog, where the text
  helper typed the user's real email and first name; the takeover's last word ("The sinc function
  is now correctly plotted…") had no Done: prefix, so nobody checked it and the run went on 30 s.
- errand-030 (DoorDash): the judge said "partial" with the item in the cart, the takeover went to
  checkout, Jev pressed "Continue with Google" 3×, and the sign-in question was never asked.
- errand-027 (Kayak): the takeover ticked "Compare vs. KAYAK Booking.com"; "Document is navigating"
  then ended the run as an error (edge-006 too).
- errand-021: the judge's reply was cut off ("Unterminated string") or had no JSON.
- errand-031: a question offered "December 5, 2025" — a past date.
"""
import datetime as dt
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
for k in ("AI_GATEWAY_API_KEY", "TEXT_MODEL_API_KEY", "ANTHROPIC_BASE_URL", "NAVI_JEV_TRANSPORT",
          "NAVI_CLOUD_URL", "NAVI_CLOUD_TOKEN", "NAVI_PLAYBOOKS_JSON", "NAVI_USER_CONTEXT_JSON",
          "NAVI_USER_MOVES_JSON", "NAVI_USER_ROUTE_JSON", "NAVI_USER_SAID_JSON", "NAVI_TAKEOVER", "NAVI_JUDGE",
          "NAVI_USER_PROFILE_JSON"):
    os.environ.pop(k, None)
os.environ.update(TYPESAFE_API_KEY="ts-test", ANTHROPIC_API_KEY="sk-test", NAVI_TAB_POLICY="keep")
import navi_runner as nr  # noqa: E402


def act(i, kind, label, role="button"):
    return {"id": f"e{i}", "node": i, "kind": kind, "label": label, "role": role}


def ids(page):
    return [a["id"] for a in page["actions"]]


# --- Adaptation 39: never the user's sign-in / sign-up -----------------------------------
plot = "graph y = sin(x)/x on desmos from -10 to 10"
desmos_1 = {"url": "https://www.desmos.com/calculator", "text": "Sign Up\nContinue with Google", "actions": [
    act(1, "click", "Close Dialog"), act(2, "click", "Continue with Google"), act(3, "click", "Continue with Apple"),
    act(4, "fill", "Continue with email:", "textbox"), act(5, "click", "Privacy Policy", "link"), act(6, "click", "Terms", "link")]}
kept = nr.drop_account_controls(desmos_1, plot)
assert ids(kept) == ["e1", "e5", "e6"] and kept["account_gate"], ids(kept)
desmos_2 = {"url": "https://www.desmos.com/calculator", "text": "", "actions": [
    act(1, "click", "Close Dialog"), act(2, "click", "Back"), act(3, "fill", "First Name", "textbox"),
    act(4, "fill", "Last Name   (optional)", "textbox"), act(5, "click", "Show Password"),
    act(6, "click", "I'm a student", "option"), act(10, "click", "Sign Up")]}
kept = nr.drop_account_controls(desmos_2, plot)
assert ids(kept) == ["e1", "e2", "e5", "e6"] and kept["account_gate"], ids(kept)
checkout = {"url": "https://www.doordash.com/consumer/checkout/", "text": "", "actions": [
    act(1, "click", "Back to Store", "link"), act(4, "click", "Add more items", "link"), act(8, "click", "Sign In", "radio"),
    act(9, "click", "Sign Up", "radio"), act(10, "click", "Continue with Google"), act(11, "click", "Continue with Facebook"),
    act(13, "fill", "Email", "textbox"), act(14, "click", "Continue to Sign In"), act(15, "click", "Terms", "link")]}
kept = nr.drop_account_controls(checkout, "order me dinner on doordash")
assert ids(kept) == ["e1", "e4", "e15"] and kept["account_gate"], ids(kept)
# A store page: the header's sign-in links go, the delivery address and search stay; no account form.
store = {"url": "https://www.doordash.com/store/ihop", "text": "", "actions": [
    act(18, "click", "Sign up or Login"), act(24, "click", "1 items, open Order Cart"), act(25, "click", "Sign In", "link"),
    act(26, "click", "Sign Up", "link"), act(27, "fill", "Item Search", "searchbox"), act(28, "fill", "Delivery address", "textbox")]}
kept = nr.drop_account_controls(store, "order me dinner on doordash")
assert ids(kept) == ["e24", "e27", "e28"] and not kept["account_gate"], ids(kept)
# A goal about signing in keeps everything; a page with no sign-in controls is returned as is.
for g in ("sign into doordash with my google account", "log in to canvas", "create an account on desmos", "sign up for spotify"):
    assert nr.drop_account_controls(checkout, g) is checkout, g
plain = {"actions": [act(1, "click", "Add to cart"), act(2, "fill", "Email me when it's back", "textbox")]}
assert nr.drop_account_controls(plain, "buy a lamp") is plain
for label in ["Continue with Google", "Sign in with Apple", "Log in", "Sign up or Login", "Continue to Sign In", "Create account",
              "Sign In", "LOGIN", "Register"]:
    assert nr.is_auth_control(label), label
for label in ["Add to cart", "Checkout", "Sign in to see more recommendations from people you follow on this site", "Logo",
              "Signal strength", "Design"]:
    assert not nr.is_auth_control(label), label
# The note rides in Jev's state while the page it describes is offered.
seen = {}
post = nr.with_page_notes(lambda url, key, body: seen.update(body=body) or {})
nr.PAGE_NOTES.clear()
nr.PAGE_NOTES["account_form"] = nr.ACCOUNT_NOTE
post("u", "k", {"state": {"elements": [], "page": {}}, "questions": {"operation": {}}})
assert seen["body"]["state"]["account_form"].startswith("This page asks the user to sign in")
post("u", "k", {"state": "[TASK] gate", "questions": {"is_irreversible": {}}})       # the gate's plain nouls are untouched
assert seen["body"]["state"] == "[TASK] gate"
nr.PAGE_NOTES.clear()
post("u", "k", {"state": {"elements": [], "page": {}}, "questions": {}})
assert "account_form" not in seen["body"]["state"]
print("account controls ok")

# about_the_user never fills a sign-up / sign-in form's fields (the Desmos email + first name).
profile = {"email": "user@example.com", "first_name": "Liam", "zip": "02492", "address": "1000 Olin Way"}
sign_up_page = {"title": "Desmos | Graphing Calculator", "text": "Sign Up\nContinue with Google\nContinue with Apple"}
ctx = {"goal": plot, "field": {"label": "Continue with email:", "role": "textbox"}, "page": sign_up_page}
assert "about_the_user" not in nr.with_user_details(ctx, profile)
ctx = {"goal": plot, "field": {"label": "First Name", "role": "textbox"}, "page": {"title": "Desmos", "text": "Show Password\nSign Up"}}
assert "about_the_user" not in nr.with_user_details(ctx, profile)
ctx = {"goal": "create an account on desmos", "field": {"label": "First Name", "role": "textbox"}, "page": sign_up_page}
assert nr.with_user_details(ctx, profile)["about_the_user"] == profile
# The errand's delivery address still gets the card, even with "Sign Up" in the page's header.
ctx = {"goal": "order me a burger", "field": {"label": "Delivery address", "role": "textbox"},
       "page": {"title": "DoorDash", "text": "Sign In\nSign Up\nEnter your address"}}
assert nr.with_user_details(ctx, profile)["about_the_user"]["zip"] == "02492"
ctx = {"goal": "book a table for two", "field": {"label": "Phone", "role": "textbox"}, "page": {"title": "OpenTable", "text": "Sign in"}}
assert "about_the_user" in nr.with_user_details(ctx, profile)
print("user details on account forms ok")

# Partner-compare toggles (Kayak's "Compare vs. KAYAK Booking.com") are not offered in an errand.
kayak = {"actions": [act(1, "click", "Compare vs. KAYAK Booking.com", "checkbox"), act(2, "click", "Search"),
                     act(3, "click", "Open results in a new window", "switch"), act(4, "click", "Compare with similar items"),
                     act(5, "click", "Free cancellation", "checkbox")]}
assert ids(nr.drop_partner_detours(kayak, "find a hotel in nyc nov 20-22 under $250 on kayak")) == ["e2", "e4", "e5"]
assert nr.drop_partner_detours(kayak, "compare kayak and booking.com prices") is kayak
print("partner detours ok")

# The takeover: what it may not press, and where it may not go.
burger = "order me a burger on doordash"
assert "Navi never pays" in nr.takeover_refusal(burger, {"label": "Place Order · $11.59"})
assert "checkout" in nr.takeover_refusal(burger, {"label": "Proceed to checkout"})
assert "sign the user in" in nr.takeover_refusal(burger, {"label": "Continue with Google"})
assert nr.takeover_refusal("sign into doordash with google", {"label": "Continue with Google"}) is None
assert "another site" in nr.takeover_refusal("find a hotel on kayak", {"label": "Compare vs. KAYAK Booking.com", "kind": "checkbox"})
assert nr.takeover_refusal("find a hotel on kayak", {"label": "Compare vs. KAYAK Booking.com", "kind": "button"}) is None
assert nr.takeover_refusal(burger, {"label": "Add to cart"}) is None and nr.takeover_refusal(burger, {}) is None
assert "Continue with Google" in nr.TAKEOVER_SYSTEM and "never go to checkout" in nr.TAKEOVER_SYSTEM
assert "You may press" not in nr.TAKEOVER_SYSTEM
assert "kind:" in nr.AT_POINT_JS and "input[type=password]" in nr.ACCOUNT_FIELD_JS


class Tab:
    def __init__(self, url):
        self.url, self.js = url, []

    def evaluate(self, js):
        self.js.append(js)
        return self.url if js == "location.href" else None


t = nr.Takeover()
t.goal = burger
real_emit, real_sleep = nr.emit, nr.time.sleep
emitted = []
nr.emit = lambda event, **f: emitted.append((event, f))
nr.time.sleep = lambda s: None
try:
    tab = Tab("https://www.doordash.com/consumer/checkout/?order_cart_id=1")
    d = t.detour(tab, "https://www.doordash.com/store/ihop-1/")
    assert d["result"] == "done" and "history.back()" in tab.js and d["summary"].startswith("Done:"), d
    assert nr.takeover_result(d["summary"], 1) == "done"
    tab = Tab("https://identity.doordash.com/auth/google/oneTap?intl=en-US")
    d = t.detour(tab, "https://www.doordash.com/store/ihop-1/")
    assert d["result"] == "stopped" and "history.back()" not in tab.js, d
    assert t.detour(Tab("https://www.doordash.com/store/ihop-1/?cursor=2"), "https://www.doordash.com/store/ihop-1/") is None
    assert t.detour(Tab("https://www.doordash.com/consumer/checkout/"), "https://www.doordash.com/consumer/checkout/") is None
    t.goal = "sign into doordash"
    assert t.detour(Tab("https://identity.doordash.com/auth"), "https://www.doordash.com/") is None
finally:
    nr.emit, nr.time.sleep = real_emit, real_sleep
print("takeover guards ok")

# --- the judge: purchases end in the cart; cut-off replies are salvaged; no past dates ----
dinner = "order me dinner on doordash"
answer = ("Sirloin Steak Tips dinner ($23.75) has been added to your DoorDash cart from IHOP, bringing the total to $27.31 "
          "before taxes. The item is in the cart but checkout hasn't been completed yet.")
assert nr.cart_is_the_end(dinner, answer)
assert nr.normalize_verdict({"verdict": "partial", "answer": answer}, goal=dinner)["verdict"] == "achieved"
assert nr.normalize_verdict({"verdict": "partial", "answer": answer})["verdict"] == "partial"        # no goal, no change
v = nr.normalize_verdict({"verdict": "needs_user", "answer": "The Sirloin Steak Tips are in your cart, but checkout needs you to sign in.",
                          "question": "Sign in to DoorDash in this tab.", "question_kind": "do_it"}, goal=dinner)
assert v["verdict"] == "achieved" and "question" not in v, v
assert nr.normalize_verdict({"verdict": "achieved", "answer": "The item is in the cart but checkout hasn't been completed."},
                            goal=dinner)["verdict"] == "achieved"
for a in ["Milk is in the cart, eggs not yet.", "The item hasn't been added to the cart yet.",
          "The bowl is in the bag but still needs a drink.", "Nothing is in the cart."]:
    assert not nr.cart_is_the_end("buy milk and eggs on instacart", a), a
assert not nr.cart_is_the_end("find the dinner menu", answer)
print("the cart is the end ok")

# A sign-in the user must do is a question, even on a purchase whose checkout needs it.
q = nr.user_question({"verdict": "needs_user", "answer": "Adding to the cart needs a DoorDash account; checkout too.",
                      "question": "Sign in to DoorDash in this tab.", "question_kind": "do_it"}, dinner, "blocked")
assert q and q["question_kind"] == "do_it", q
q = nr.user_question({"verdict": "needs_user", "answer": "Stopped: Sign in in this tab — signing in is yours to do.", "next_step": ""},
                     dinner, "blocked")
assert q and q["question"].startswith("Stopped: Sign in"), q
assert nr.user_question({"verdict": "needs_user", "answer": "Enter your card number to check out."}, dinner, "blocked") is None
assert nr.user_question({"verdict": "needs_user", "answer": "x", "question": "Sign in and pay for the order?",
                         "question_kind": "do_it"}, dinner, "blocked") is None
print("sign-in questions ok")

# Cut-off and fenced replies.
assert nr.salvage_json('{"verdict": "achieved", "answer": "Big Mac is in the bag."}')["verdict"] == "achieved"
cut = '{"verdict": "partial", "answer": "The Pad Thai modal is open, but the spice level opt'
assert nr.salvage_json(cut) == {"verdict": "partial", "answer": "The Pad Thai modal is open, but the spice level opt"}
cut = '```json\n{"verdict": "not_achieved", "answer": "Not yet.", "next_step": "Click Add", "question_choices": ["Mild", "Spi'
out = nr.salvage_json(cut)
assert out["verdict"] == "not_achieved" and out["next_step"] == "Click Add" and out["question_choices"] == ["Mild", "Spi"], out
assert nr.salvage_json('{"verdict": "partial", "answer": "a \\"quoted\\" wo')["answer"] == 'a "quoted" wo'
assert nr.salvage_json('{"verdict": "needs_user", "answer": "x", "question_kind"')["verdict"] == "needs_user"
for bad in ("", "I can't tell from this screenshot.", "[1, 2]"):
    try:
        nr.salvage_json(bad)
        raise AssertionError(f"salvaged {bad!r}")
    except ValueError:
        pass
replies, bodies = [], []


def judge_post(body, timeout=90, what="Claude"):
    bodies.append(body)
    return {"content": [{"type": "text", "text": replies.pop(0)}]}


real_post = nr.claude_post
nr.claude_post = judge_post
try:
    replies[:] = ['{"verdict": "partial", "answer": "Sirloin Steak Tips are in your cart; checkout is not done yet", "next_st']
    v = nr.judge(dinner, {"url": "https://x.test", "title": "t", "text": ""}, [], "check")
    assert v["verdict"] == "achieved" and len(bodies) == 1, v           # salvaged, then the cart is the end
    state = json.loads(bodies[0]["messages"][0]["content"][-1]["text"])
    assert state["facts"]["today"] and bodies[0]["max_tokens"] >= 1200, state
    bodies.clear()
    replies[:] = ["The page shows the cart.", '{"verdict": "not_achieved", "answer": "Not yet.", "next_step": "Add it"}']
    v = nr.judge("find the dinner menu", {"url": "https://x.test", "title": "t", "text": ""}, [], "check")
    assert v["verdict"] == "not_achieved" and len(bodies) == 2 and bodies[1]["messages"][-1]["role"] == "user", v
    replies[:] = ["no", "still no"]
    try:
        nr.judge("x", {"url": "https://x.test", "title": "t", "text": ""}, [], "check")
        raise AssertionError("a judge with no JSON twice must raise")
    except ValueError:
        pass
finally:
    nr.claude_post = real_post
assert "compact JSON" in nr.JUDGE_SYSTEM and "facts.today" in nr.JUDGE_SYSTEM
print("judge parsing ok")

# Past dates are never offered as answers (facts.today is 2026-11-01 on the bench).
today = dt.date(2026, 11, 1)
assert nr.dates_named("December 5, 2025") == [dt.date(2025, 12, 5)]
assert nr.dates_named("Fri, Dec 5th 2026") == [dt.date(2026, 12, 5)]
assert nr.dates_named("5 December 2025") == [dt.date(2025, 12, 5)]
assert nr.dates_named("2025-12-05 vs Lakers") == [dt.date(2025, 12, 5)]
assert nr.dates_named("12/05/2025") == [dt.date(2025, 12, 5)]
assert nr.dates_named("October 2026") == [dt.date(2026, 10, 31)]
assert nr.dates_named("Let me check a different date") == [] and nr.dates_named("Large") == []
assert nr.names_past_date("December 5, 2025", today) and not nr.names_past_date("December 5, 2026", today)
assert not nr.names_past_date("November 1, 2026", today) and nr.names_past_date("October 2026", today)
v = nr.normalize_verdict({"verdict": "needs_user", "answer": "No Celtics game is listed on December 5, 2026.",
                          "question": "Which date did you mean?", "question_kind": "choice",
                          "question_choices": ["December 5, 2025", "December 5, 2026", "Let me check a different date"]}, today=today)
assert v["question_choices"] == ["December 5, 2026", "Let me check a different date"], v
print("past dates ok")

# --- the run controller: unclear takeover endings and unsure DONEs go to the judge ----------
assert nr.takeover_result("The sinc function y = sin(x)/x is now correctly plotted.", 7) == "unclear"
assert nr.takeover_result("Did: typed y", 2) == "handback" and nr.takeover_result("", 3) == "handback"
assert nr.takeover_result("The plot is there.", 0) == "no_progress"
st = {"goal": plot, "page": {"text": "", "url": "https://www.desmos.com/calculator", "actions": []}, "history": []}
assert "unsure" in nr.done_doubt(st, {"operation": "DONE", "confidence": 0.15})
assert nr.done_doubt(st, {"operation": "DONE", "confidence": 0.15}, judge_available=True) is None
st = {"goal": "order me a burger", "page": {"text": "BUILD YOUR BOWL", "url": "https://x.test/build", "actions": []}, "history": []}
assert "cart or bag" in nr.done_doubt(st, {"operation": "DONE", "confidence": 0.15}, judge_available=True)   # evidence still first
print("unclear endings and unsure DONEs ok")

# --- Adaptation 40: a navigating document is a stale page, never the end of the run ----------
for msg in ["Document is navigating", "Inspected target navigated or closed",
            "JavaScript evaluation failed: Cannot find context with specified id", "Execution context was destroyed."]:
    assert nr.is_transient(RuntimeError(msg)), msg
assert not nr.is_transient(RuntimeError("Text helper returned HTTP 500")) and not nr.is_transient(ValueError("Document is navigating"))


class Navigating:
    def __init__(self, fails, error="Document is navigating"):
        self.fails, self.error, self.observed = fails, error, 0

    def observe(self, screenshot=False):
        self.observed += 1
        return {"url": "https://www.booking.com/searchresults", "fingerprint": f"f{self.observed}", "actions": [], "text": ""}


class NavAgent:
    screenshots = False

    def __init__(self, browser):
        self.state = {"browser": browser, "page": {"url": "https://www.kayak.com/", "fingerprint": "k", "actions": []},
                      "history": [], "decisions": [], "status": "ready", "decision": None, "started_at": 0.0, "goal": "hotel"}

    def command(self, name, body=None):
        b = self.state["browser"]
        if b.fails:
            b.fails -= 1
            raise RuntimeError(b.error)
        raise AssertionError("not reached")


nr.emit = lambda event, **f: None
nr.time.sleep = lambda s: None
try:
    agent = NavAgent(Navigating(1))
    assert nr.tick(agent, set()) == "stale" and agent.state["status"] == "ready" and agent.state["page"]["fingerprint"] == "f1"
    agent = NavAgent(Navigating(nr.MAX_TRANSIENT + 1))
    for _ in range(nr.MAX_TRANSIENT):
        assert nr.tick(agent, set()) == "stale"
    try:
        nr.tick(agent, set())
        raise AssertionError("a tab that keeps failing must end the run")
    except RuntimeError:
        pass
    agent = NavAgent(Navigating(1, error="Text helper returned HTTP 500; nothing typed."))
    try:
        nr.tick(agent, set())
        raise AssertionError("other errors still raise")
    except RuntimeError:
        pass
    calls = []

    def flaky():
        calls.append(1)
        if len(calls) < 3:
            raise RuntimeError("Document is navigating")
        return "shot"
    assert nr.retry_transient(flaky) == "shot" and len(calls) == 3
finally:
    nr.emit, nr.time.sleep = real_emit, real_sleep
print("navigating documents ok")
print("takeover safety (adaptations 39–40): OK")
