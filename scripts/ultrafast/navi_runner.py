"""Navi ⇄ jev-ultrafast bridge.

Runs one browser task with the vendored jev-ultrafast Agent and streams
JSON lines to stdout for Navi's panel:

  {"event":"ready","elements":N,"url":…,"title":…}
  {"event":"decision","operation":"CLICK","target":"7","confidence":0.91,"latency_ms":118,"probabilities":{…}}
  {"event":"step","step":3,"action":"button Search","kind":"click","text":null,"page_changed":true,"url":…,"elapsed_ms":…}
  {"event":"screenshot","jpeg_base64":…}            (only with --screenshots)
  {"event":"status","message":…}
  {"event":"done","status":"done"|"blocked","elapsed_ms":…,"steps":N,"summary":…}
  {"event":"error","message":…}

Navi passes keys through the environment (never argv):
  TYPESAFE_API_KEY            — Jev direct, or
  AI_GATEWAY_API_KEY          — Jev via Vercel AI Gateway (NAVI_JEV_TRANSPORT=vercel)
  ANTHROPIC_API_KEY           — text helper (Claude Haiku) unless TEXT_MODEL_API_KEY is set
  TEXT_MODEL_API_KEY/BASE_URL/TEXT_MODEL — optional OpenAI-compatible helper, as upstream

The vendored library is not modified; the adaptations below are
monkeypatches so `vendor/jev-ultrafast` stays byte-identical to upstream.

Speed adaptations (measured on a Boston → us-west-2 path):
  3. Start observing at `document.readyState == "interactive"` instead of
     "complete" — the DOM snapshot is identical, 0.3–1.3 s earlier.
  4. Warm the TLS connections to TypeSafe and Anthropic while Chrome is still
     navigating, so the first Jev call is ~150 ms instead of ~400 ms.
  5. Speculative TYPE_TEXT: when a page has one obvious text field, ask the
     text helper for its value *while* Jev is deciding, so a TYPE_TEXT step
     costs one round trip instead of two.

Reliability adaptations (from failed runs, see git log):
  7. Click where the element actually is: upstream clicks the centre of the
     bounding box and refuses if that point hit-tests to something else. An
     inline link that wraps (every Google result: site name line + title line)
     has its bounding-box centre in the gap between the lines, so the click was
     rejected every time. Try each line box first, then the centre, then the
     corners.
  8. A rejected click is not silent: upstream swallows the rejection and asks
     Jev again from the identical page — 57 times in one run. After two
     rejections the element becomes a failed step Jev can see and is dropped
     from the table for that document; three failed steps reach the coach.
  9. <canvas> is a click target: games and drawing apps had nothing in the
     table, so "play" could only flail on the nav links. A canvas click's
     effect is not visible in the DOM, so it is recorded as page_changed=null
     rather than a no-change failure.
 10. Let a page settle before Jev sees it: after a navigation (or when the
     table is empty) the observation is repeated until readyState is
     "complete" and two consecutive snapshots agree, up to ~3 s. A click on
     "Directions" landed on a blank, still-rendering Google Maps document
     that Jev — correctly — called BLOCKED, which ended the run.
 11. BLOCKED is a verdict, not a reflex: a low-confidence BLOCKED (or one
     where WAIT is a close runner-up) is first answered with a short wait and
     a fresh observation; only a repeat on the same page counts.
 12. Coaching is per document, not per run: after Claude's guidance takes
     Jev to a different page, the guidance (which names element indexes of
     the old page) is marked stale and Claude may be consulted again there,
     up to a small budget. Failing again on the same page still ends the run.
 13. The tab is the deliverable: the runner used to close its tab on exit,
     so "make a new Google Doc" ended with the doc closing in front of the
     user. Now the tab stays open whenever anything happened on it
     (NAVI_TAB_POLICY: keep | reveal | close), and "reveal" brings it to the
     front on completion — the ending of a background run that made something.
 14. Web-app playbooks: Jev decides from labels alone and knows nothing about
     Drive, Docs or Gmail. Navi hands the runner its web skills
     (NAVI_PLAYBOOKS_JSON: how the app works, recipes for goals like this
     one, what "done" looks like, wrong moves); the one matching the current
     page's host is added to Jev's state and instructions, like coaching.
 15. The Google Docs page is a text target: the document body is a canvas
     editor whose contenteditable lives in a hidden iframe, so it was never in
     the table and "type the score into the doc" could only re-type the
     title. The editor container is offered as a textbox; filling it clicks
     the page, moves the caret to the end of the document (⌘↓) and inserts
     the text — never select-all, which would replace the document.
 17. List rows and item cards are click targets: Google Drive's files are
     `role="gridcell"` cards holding a "More actions" button (upstream skips
     any gridcell with a button) and list views / Gmail use `role="row"`
     elements the snapshot never enumerated — Jev saw a results page with
     nothing on it and gave up. Interactive rows and cards (aria-selected /
     tabindex / data-id / data-selectable) are offered by their label, plus
     an "Open (double-click): …" action executed as a real double click.
 16. A text helper that has no value is a failed step, not the end: upstream
     raises out of `act` when the helper answers {"text": null}, which ended
     whole runs ("Text helper returned no valid field value"). The step is
     now recorded as a no-change failure, the field is no longer offered for
     TYPE_TEXT on that document, and Jev decides again from the same page.
"""

import argparse
import json
import math
import os
import signal
import sys
import threading
import time
from concurrent.futures import Future

import httpx

from browser_harness.helpers import cdp

from jev_ultrafast import Agent, model as jev_model
from jev_ultrafast import browser as browser_module
from jev_ultrafast.browser import Browser, StalePage
from jev_ultrafast.model import field_context
from jev_ultrafast.questions import TEXT_VALUE


def emit(event, **fields):
    sys.stdout.write(json.dumps({"event": event, **fields}) + "\n")
    sys.stdout.flush()


# --- Adaptation 1: Jev via Vercel AI Gateway --------------------------------

VERCEL_URL = "https://ai-gateway.vercel.sh/v4/ai/evaluation-model"


def derived_confidence(probabilities):
    values = sorted(probabilities.values(), reverse=True)
    if not values:
        return 0.0
    second = values[1] if len(values) > 1 else 0.0
    return max(0.0, min(1.0, values[0] - second))


def post_json_vercel(url, key, body):
    """Translate a TypeSafe /v1/systemone body to the Gateway's evaluation-model call."""
    if "typesafe.ai" not in url:
        return _upstream_post_json(url, key, body)
    gateway_key = os.environ["AI_GATEWAY_API_KEY"]
    model = os.environ.get("TYPESAFE_MODEL", "jev-latest")
    gateway_model = model if "/" in model else "typesafe-ai/jev"
    questions = {}
    for name, q in body["questions"].items():
        q = dict(q)
        if q.get("type") == "noul":
            q["type"] = "boolean"
        questions[name] = q
    headers = {
        "Authorization": f"Bearer {gateway_key}",
        "ai-model-id": gateway_model,
        "ai-evaluation-model-specification-version": "4",
        "ai-gateway-protocol-version": "0.0.1",
        "ai-gateway-auth-method": "api-key",
    }
    for attempt in range(3):
        try:
            response = jev_model.CLIENT.post(
                VERCEL_URL, json={"state": body["state"], "questions": questions}, headers=headers
            )
        except httpx.HTTPError:
            raise RuntimeError("Model connection failed; no action executed.") from None
        if response.status_code in {429, 529, 503} and attempt < 2:
            time.sleep(0.5 * 2**attempt)
            continue
        if response.is_error:
            raise RuntimeError(f"Vercel AI Gateway returned HTTP {response.status_code}; no action executed.")
        data = response.json()
        break
    else:
        raise RuntimeError("Model unavailable")
    meta = (data.get("providerMetadata") or {}).get("typesafe") or {}
    confidences = meta.get("confidence") if isinstance(meta.get("confidence"), dict) else {}
    answers = {}
    for name, a in (data.get("answers") or {}).items():
        a = dict(a)
        if a.get("type") == "boolean":
            a = {"type": "noul", "noul": a.get("probability", 0.0)}
        elif a.get("type") in {"choice", "score"} and "confidence" not in a:
            c = confidences.get(name)
            a["confidence"] = c if isinstance(c, (int, float)) and math.isfinite(c) else derived_confidence(
                a.get("probabilities") or {}
            )
        answers[name] = a
    usage = data.get("usage") or {}
    return {
        "model": gateway_model,
        "answers": answers,
        "usage": {"input_tokens": usage.get("inputTokens", 0), "output_tokens": usage.get("outputTokens", 0)},
    }


_upstream_post_json = jev_model.post_json


# --- Adaptation 2: text helper on Claude Haiku ------------------------------

FIELD_HINTS = {"playbook": None}   # set by main(); the helper adds the page's field hints


def field_text_claude(context):
    """Same contract as upstream field_text, using the Anthropic Messages API."""
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        raise ValueError("TYPE_TEXT needs ANTHROPIC_API_KEY or TEXT_MODEL_API_KEY; nothing typed.")
    model = os.environ.get("NAVI_TEXT_MODEL", "claude-haiku-4-5")
    base = os.environ.get("ANTHROPIC_BASE_URL", "https://api.anthropic.com").rstrip("/")
    playbook = FIELD_HINTS.get("playbook")
    if playbook is not None and isinstance(context, dict):
        hints = playbook.field_hints_for((context.get("page") or {}).get("url") or playbook.current_url)
        if hints:
            context = {**context, "field_hints": hints}
    started = time.perf_counter()
    for attempt in range(3):
        try:
            response = jev_model.CLIENT.post(
                base + "/v1/messages",
                headers={"x-api-key": key, "anthropic-version": "2023-06-01"},
                json={
                    "model": model,
                    "max_tokens": 512,
                    "system": TEXT_VALUE + " Output only the JSON object.",
                    "messages": [{"role": "user", "content": json.dumps(context)}],
                },
            )
        except httpx.HTTPError:
            raise RuntimeError("Text helper connection failed; nothing typed.") from None
        if response.status_code in {429, 529, 503} and attempt < 2:
            time.sleep(0.5 * 2**attempt)
            continue
        if response.is_error:
            raise RuntimeError(f"Text helper returned HTTP {response.status_code}; nothing typed.")
        result = response.json()
        break
    else:
        raise RuntimeError("Text helper unavailable")
    try:
        content = "".join(b.get("text", "") for b in result.get("content", []) if b.get("type") == "text").strip()
        if content.startswith("```"):
            content = content.strip("`")
            content = content[content.find("{"):content.rfind("}") + 1]
        output = json.loads(content)
        value = output["text"]
        if set(output) != {"text"} or not isinstance(value, str) or not value.strip() or len(value) > 2000:
            raise ValueError()
    except (ValueError, KeyError, TypeError):
        raise ValueError("Text helper returned no valid field value; nothing typed.") from None
    usage = result.get("usage", {})
    return value, {
        "model": model,
        "latency_ms": round((time.perf_counter() - started) * 1000),
        "usage": {"prompt_tokens": usage.get("input_tokens", 0), "completion_tokens": usage.get("output_tokens", 0)},
    }


# --- Adaptation 3: observe at "interactive" ---------------------------------

class FastBrowser(Browser):
    """Upstream `Browser.__init__` waits for readyState "complete" (every image
    and script). The snapshot reads the DOM, which is final at "interactive";
    on Google search / Flights that is 0.9–1.3 s earlier for an identical
    element table. Stale-page guards already cover anything that lands later."""

    READY = {"interactive", "complete"}

    def __init__(self, url):
        from browser_harness.admin import ensure_daemon
        from browser_harness.helpers import cdp

        ensure_daemon()
        # "Look up Matt Armstrong" right after "go to YouTube" continues on the
        # YouTube tab that is open (NAVI_ATTACH_URL): attach to it rather than
        # opening a second tab with a Google search. The user's tab is never closed.
        self.attached = False
        attach_url = os.environ.get("NAVI_ATTACH_URL", "").strip()
        existing = find_open_tab(attach_url) if attach_url else None
        if existing:
            self.target = existing
            self.attached = True
        else:
            self.target = cdp("Target.createTarget", url="about:blank", background=True)["targetId"]
        self.session = cdp("Target.attachToTarget", targetId=self.target, flatten=True)["sessionId"]
        # No `Emulation.setDeviceMetricsOverride` (upstream forces 1120×780): the page
        # then rendered in a fraction of the Chrome window the user was watching.
        # Jev reads the DOM, which is fine at whatever size the window has.
        self.call("Emulation.setFocusEmulationEnabled", enabled=True)
        # Show the work: the user asked Navi to do this, so the tab is brought to the
        # front instead of running invisibly in the background.
        if not os.environ.get("NAVI_BACKGROUND_TAB"):
            try:
                cdp("Target.activateTarget", targetId=self.target)
            except Exception:  # noqa: BLE001 — cosmetic
                pass
        if not self.attached:
            self.call("Page.navigate", url=url)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            try:
                if self.evaluate("document.readyState") in self.READY:
                    break
            except Exception:  # noqa: BLE001 — document swapped mid-evaluate
                pass
            time.sleep(0.02)

    def close(self):
        # The tab was the user's before the run: leave it exactly where it is.
        if self.attached:
            self.target = None
            return
        super().close()


def same_page(a, b):
    """Two URLs naming the same page: scheme-insensitive, ignoring the fragment,
    a trailing slash and a leading www."""
    def norm(u):
        u = (u or "").strip().split("#", 1)[0]
        for prefix in ("https://", "http://"):
            if u.startswith(prefix):
                u = u[len(prefix):]
        if u.startswith("www."):
            u = u[4:]
        return u.rstrip("/").lower()
    return bool(norm(a)) and norm(a) == norm(b)


def find_open_tab(url, targets=None):
    """The id of an open Chrome tab showing `url`, or None."""
    if targets is None:
        try:
            from browser_harness.helpers import cdp
            targets = cdp("Target.getTargets").get("targetInfos", [])
        except Exception:  # noqa: BLE001 — no daemon yet: open our own tab
            return None
    for t in targets:
        if t.get("type") == "page" and same_page(t.get("url"), url):
            return t.get("targetId")
    return None


# --- Adaptation 4: warm the model connections during navigation -------------

def warm_connections():
    """TCP+TLS to the model hosts costs ~250–350 ms each from the East Coast.
    Do it on a thread while Chrome loads the start page. GET /v1/models is
    free on both APIs; any response (even 4xx) leaves the pooled connection
    open in `jev_model.CLIENT`."""

    def warm(url, headers):
        try:
            jev_model.CLIENT.get(url, headers=headers, timeout=5)
        except Exception:  # noqa: BLE001 — best effort only
            pass

    targets = []
    if os.environ.get("NAVI_JEV_TRANSPORT") == "vercel":
        targets.append(("https://ai-gateway.vercel.sh/", {}))
    elif os.environ.get("TYPESAFE_API_KEY"):
        targets.append(("https://api.typesafe.ai/v1/models", {"Authorization": f"Bearer {os.environ['TYPESAFE_API_KEY']}"}))
    if os.environ.get("ANTHROPIC_API_KEY") and not os.environ.get("TEXT_MODEL_API_KEY"):
        base = os.environ.get("ANTHROPIC_BASE_URL", "https://api.anthropic.com").rstrip("/")
        targets.append((base + "/v1/models", {"x-api-key": os.environ["ANTHROPIC_API_KEY"], "anthropic-version": "2023-06-01"}))
    for url, headers in targets:
        threading.Thread(target=warm, args=(url, headers), daemon=True).start()


# --- Adaptation 5: speculative text helper ----------------------------------

class SpeculativeText:
    """Runs the text helper in parallel with Jev's decision.

    Right before `choose` (which receives the page the agent will act on), if
    that page has one obvious TYPE_TEXT candidate (the field the last action
    clicked, else the only empty text field) that nothing has been typed into
    yet, the helper starts on a thread with exactly the `field_context` the
    agent would build. If Jev then picks that field, `field_text` returns
    the in-flight result (usually already done); otherwise the value is simply
    never typed. Keyed by the full context, so a mismatch can never leak text
    into the wrong field."""

    def __init__(self, inner):
        self.inner = inner
        self.lock = threading.Lock()
        self.futures = {}
        self.stats = {"started": 0, "hits": 0}

    @staticmethod
    def key(context):
        return json.dumps(context, sort_keys=True)

    @staticmethod
    def candidate(page, history):
        fills = [a for a in page.get("actions", []) if a.get("kind") == "fill"]
        if not fills:
            return None
        typed = {h.get("action") for h in history if h.get("kind") == "fill"}
        # Only fields that are still empty: a pre-filled search box is not about to be typed into.
        fresh = [a for a in fills if a["label"] not in typed and not (a.get("value") or "").strip()]
        if not fresh:
            return None
        # The field the previous action clicked ("Where from?" / "Open Where from?").
        last = history[-1] if history else None
        if last and last.get("kind") == "click":
            label = last.get("action") or ""
            clicked = [a for a in fresh if a["label"] == label or "Open " + a["label"] == label]
            if len(clicked) == 1:
                return clicked[0]
        return fresh[0] if len(fresh) == 1 else None

    def speculate(self, goal, page, history):
        action = self.candidate(page, history)
        if action is None:
            return
        context = field_context(goal, action, page, history)
        k = self.key(context)
        with self.lock:
            if k in self.futures:
                return
            fut = Future()
            self.futures[k] = fut
            if len(self.futures) > 32:
                self.futures.pop(next(iter(self.futures)))
        self.stats["started"] += 1

        def run():
            try:
                fut.set_result(self.inner(context))
            except Exception as exc:  # noqa: BLE001 — surfaced when/if consumed
                fut.set_exception(exc)

        threading.Thread(target=run, daemon=True).start()

    def __call__(self, context):
        with self.lock:
            fut = self.futures.pop(self.key(context), None)
        if fut is None:
            return self.inner(context)
        self.stats["hits"] += 1
        text, helper = fut.result()
        return text, {**helper, "speculative": True}


# --- Adaptation 6: Claude coaches Jev once when it keeps failing -------------

COACH_SYSTEM = """You are the supervisor of a fast, non-generative decision model ("Jev") that drives a web page by choosing ONE operation per step from an indexed element table: CLICK an element index, TYPE_TEXT into an element index, SELECT an option, SCROLL_UP/DOWN, WAIT, DONE, BLOCKED. Jev cannot see pixels, cannot read instructions that are not in its state, and picks the most plausible element from labels and roles.

Jev is failing at the current goal. You see the goal, the page (screenshot when attached), the element table Jev sees (with indexes), the site's playbook when Navi has one (`playbook`: how the app works, recipes — prefer its steps in your guidance), and the recent actions with whether each one changed the page. Work out WHY it is failing — e.g. clicking a label or a search box instead of the right control, the control it needs is not in the table (needs scrolling, a different page, or a different search), an autocomplete or overlay is in the way, it keeps re-clicking the same thing, the goal is already satisfied, or the goal cannot be done on this page.

Reply ONLY with JSON:
{"diagnosis": "one or two sentences on what is going wrong",
 "guidance": "2-5 short imperative lines Jev should follow from now on, naming element indexes and exact labels from the table when relevant, and what to stop doing"}
Never invent element indexes that are not in the table. Never include credentials or payment details."""

FAILURES_BEFORE_COACHING = 3
MAX_COACHINGS = 3


class Coach:
    """Once per document: when the page stops responding to Jev (upstream's
    stuck rule, or the same element acted on three times in a row), Claude
    reads the page and writes guidance that is added to Jev's state and to
    every question's instructions for the rest of the run. Failing again on
    the same document ends the run with Claude's diagnosis; on a different
    document (the guidance often *is* "go to a different page") Claude may be
    asked again, `MAX_COACHINGS` times in all."""

    def __init__(self):
        self.guidance = None
        self.diagnosis = None
        self.used = False
        self.count = 0
        self.url = None          # page the current guidance was written for
        self.current_url = None  # page Jev is on now (set by the run loop)

    @staticmethod
    def same_document(a, b):
        """Same page for coaching purposes: origin + path, ignoring query/fragment."""
        if not a or not b:
            return a == b
        return a.split("#", 1)[0].split("?", 1)[0].rstrip("/") == b.split("#", 1)[0].split("?", 1)[0].rstrip("/")

    def may_ask(self, url):
        """A first consult, or a later one on a page other than the last consult's."""
        if self.count >= MAX_COACHINGS:
            return False
        return not self.used or not self.same_document(self.url, url)

    def guidance_for(self, url):
        """The guidance as Jev should read it here: unchanged on the page it was
        written for, flagged as possibly stale elsewhere (its indexes belong to
        the old page)."""
        if not self.guidance:
            return None
        if self.same_document(self.url, url):
            return self.guidance
        return ("(Written on the previous page " + str(self.url or "") + " — element indexes there do not apply here; "
                "follow the intent only.) " + self.guidance)

    @staticmethod
    def flailing(history):
        last = history[-FAILURES_BEFORE_COACHING:]
        if len(last) < FAILURES_BEFORE_COACHING:
            return None
        if all(h.get("page_changed") is False and h.get("kind") != "wait" for h in last):
            return "the last %d actions changed nothing" % FAILURES_BEFORE_COACHING
        if len({h.get("action") for h in last}) == 1 and last[-1].get("kind") != "wait":
            return "‘%s’ was chosen %d times in a row" % (last[-1].get("action", "?")[:60], FAILURES_BEFORE_COACHING)
        return None

    playbook = None   # set by main(): the Playbook, so the coach reads the same site knowledge

    def ask(self, goal, page, history, why, screenshot_b64=None):
        key = os.environ.get("ANTHROPIC_API_KEY")
        if not key:
            raise ValueError("no Anthropic key")
        model = os.environ.get("NAVI_AGENT_MODEL", "claude-sonnet-5")
        base = os.environ.get("ANTHROPIC_BASE_URL", "https://api.anthropic.com").rstrip("/")
        from jev_ultrafast.model import action_space

        elements = action_space(page["actions"])[0]
        state = {
            "goal": goal,
            "why_asked": why,
            "page": {"url": page.get("url"), "title": page.get("title"), "text": (page.get("text") or "")[:4000]},
            "elements": elements[:150],
            "recent_actions": [{k: h.get(k) for k in ("action", "kind", "text", "page_changed")} for h in history[-8:]],
        }
        book = self.playbook.playbook_for(page.get("url")) if self.playbook else None
        if book:
            state["playbook"] = book
        content = []
        if screenshot_b64:
            content.append({"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": screenshot_b64}})
        content.append({"type": "text", "text": json.dumps(state, sort_keys=True)})
        started = time.perf_counter()
        response = jev_model.CLIENT.post(
            base + "/v1/messages",
            headers={"x-api-key": key, "anthropic-version": "2023-06-01"},
            json={"model": model, "max_tokens": 700, "system": COACH_SYSTEM, "messages": [{"role": "user", "content": content}]},
            timeout=60,
        )
        if response.is_error:
            raise RuntimeError(f"Claude returned HTTP {response.status_code}")
        text = "".join(b.get("text", "") for b in response.json().get("content", []) if b.get("type") == "text").strip()
        if text.startswith("```"):
            text = text.strip("`")
            text = text[text.find("{"):text.rfind("}") + 1]
        out = json.loads(text)
        guidance = str(out.get("guidance", "")).strip()
        if not guidance:
            raise ValueError("no guidance")
        self.guidance = guidance[:1200]
        self.diagnosis = str(out.get("diagnosis", "")).strip() or "Jev kept choosing actions that had no effect"
        self.used = True
        self.count += 1
        self.url = page.get("url")
        self.current_url = self.url
        return round((time.perf_counter() - started) * 1000)

    def install(self):
        """Adds the guidance to every Jev request (state + each question's instructions)."""
        inner = jev_model.post_json

        def post_json(url, key, body):
            guidance = self.guidance_for(self.current_url)
            if guidance and isinstance(body, dict) and "questions" in body:
                body = dict(body)
                if isinstance(body.get("state"), dict):
                    body["state"] = {**body["state"], "guidance": guidance}
                qs = {}
                for name, q in body["questions"].items():
                    q = dict(q)
                    if isinstance(q.get("instructions"), dict):
                        q["instructions"] = {**q["instructions"], "guidance": guidance}
                    qs[name] = q
                body["questions"] = qs
            return inner(url, key, body)

        jev_model.post_json = post_json


# --- Adaptation 14: web-app playbooks ride in Jev's state -------------------

PLAYBOOK_RULE = ("`playbook` describes THIS web app: follow its `recipes` for goals like this one, respect `avoid`, "
                 "and judge DONE against `done_when`.")
MAX_PLAYBOOK_RECIPES = 3


class Playbook:
    """Site knowledge from Navi's `AppSkills` (NAVI_PLAYBOOKS_JSON). Per request
    the skill whose host matches the current page is trimmed to the recipes that
    share words with the goal and added to the state (`playbook`) and to the
    operation question's instructions — the same channel the coach uses."""

    def __init__(self, skills=None, goal=""):
        self.skills = skills if skills is not None else self.from_env()
        self.goal = goal
        self.current_url = None
        self.announced = set()

    @staticmethod
    def from_env():
        raw = os.environ.get("NAVI_PLAYBOOKS_JSON")
        if not raw:
            return []
        try:
            skills = json.loads(raw)
        except ValueError:
            return []
        return [s for s in skills if isinstance(s, dict) and s.get("hosts")]

    @staticmethod
    def host_of(url):
        if not url or "://" not in url:
            return ""
        rest = url.split("://", 1)[1]
        return rest.split("/", 1)[0].split("?", 1)[0].lower()

    def skill_for(self, url):
        """Longest matching host suffix wins ("docs.google.com" over "google.com").
        A host entry may carry a path prefix ("google.com/maps")."""
        host = self.host_of(url)
        if not host:
            return None
        path = "/" + url.split("://", 1)[1].split("/", 1)[1] if "://" in url and "/" in url.split("://", 1)[1] else "/"
        best, best_len = None, -1
        for skill in self.skills:
            for h in skill.get("hosts", []):
                h = h.lower()
                h_host, _, h_path = h.partition("/")
                if not (host == h_host or host.endswith("." + h_host)):
                    continue
                if h_path and not path.startswith("/" + h_path):
                    continue
                if len(h) > best_len:
                    best, best_len = skill, len(h)
        return best

    @staticmethod
    def recipes(skill, goal):
        words = set(w for w in "".join(c if c.isalnum() else " " for c in goal.lower()).split())
        lower = goal.lower()
        scored = []
        for r in skill.get("recipes", []):
            hits = sum(1 for k in r.get("keywords", []) if (k in lower if " " in k else k in words))
            if hits:
                scored.append((hits, r))
        scored.sort(key=lambda x: -x[0])
        return [{"goal": r.get("goal"), "steps": r.get("steps", [])} for _, r in scored[:MAX_PLAYBOOK_RECIPES]]

    def playbook_for(self, url):
        skill = self.skill_for(url)
        if not skill:
            return None
        book = {"app": skill.get("app"), "how_it_works": skill.get("how_it_works", [])}
        recipes = self.recipes(skill, self.goal)
        if recipes:
            book["recipes"] = recipes
        for key in ("done_when", "avoid"):
            if skill.get(key):
                book[key] = skill[key]
        return book

    def field_hints_for(self, url):
        skill = self.skill_for(url)
        return list(skill.get("field_hints", [])) if skill else []

    def install(self):
        """Adds the page's playbook to every Jev request."""
        inner = jev_model.post_json

        def post_json(url, key, body):
            if isinstance(body, dict) and "questions" in body and isinstance(body.get("state"), dict):
                page_url = (body["state"].get("page") or {}).get("url") or self.current_url
                book = self.playbook_for(page_url)
                if book:
                    if book["app"] not in self.announced:
                        self.announced.add(book["app"])
                        emit("status", message=f"Using the {book['app']} playbook")
                    body = dict(body)
                    body["state"] = {**body["state"], "playbook": book}
                    qs = {}
                    for name, q in body["questions"].items():
                        q = dict(q)
                        if name == "operation" and isinstance(q.get("instructions"), dict):
                            q["instructions"] = {**q["instructions"], "playbook": PLAYBOOK_RULE}
                        qs[name] = q
                    body["questions"] = qs
            return inner(url, key, body)

        jev_model.post_json = post_json


# --- Adaptation 7: click where the element actually is ----------------------

# Same visibility/enabled checks as upstream's act(); differs only in which point is
# clicked: each line box (largest first), the bounding-box centre, then points just
# inside the corners. The first point whose hit-test lands inside the element wins,
# so a covered control is still refused exactly as upstream refuses it.
CLICK_POINT_JS = """(action => {
  const e=window.__jevFast?.nodes.get(action.node);
  if (!e?.isConnected || e.matches(':disabled') || e.closest('[aria-disabled="true"],[inert]') ||
      !e.checkVisibility({checkOpacity:true,checkVisibilityCSS:true})) return null;
  if (action.kind==='fill' && (e.readOnly || e.getAttribute('aria-readonly')==='true')) return null;
  const b=e.getBoundingClientRect();
  if (!b.width || !b.height) return null;
  const rects=[...e.getClientRects()].filter(r=>r.width>0 && r.height>0)
    .sort((p,q)=>q.width*q.height-p.width*p.height);
  const points=rects.map(r=>[r.x+r.width/2,r.y+r.height/2]);
  points.push([b.x+b.width/2,b.y+b.height/2]);
  const dx=Math.min(8,b.width/4), dy=Math.min(8,b.height/4);
  points.push([b.x+dx,b.y+dy],[b.right-dx,b.y+dy],[b.x+dx,b.bottom-dy],[b.right-dx,b.bottom-dy]);
  for (const [x,y] of points) {
    if (x<0 || y<0 || x>=innerWidth || y>=innerHeight) continue;
    const t=document.elementFromPoint(x,y);
    if (t && e.contains(t)) return {x,y};
  }
  return null;
})"""

_upstream_browser_operation = browser_module.browser_operation


def browser_operation_navi(request):
    """Upstream `browser_operation`, with click/fill targeting from CLICK_POINT_JS."""
    if request["operation"] != "act" or request["action"]["kind"] not in {"click", "fill"}:
        return _upstream_browser_operation(request)
    action, session = request["action"], request["session"]
    if type(action["node"]) is not int:
        raise ValueError("Invalid observed node")

    def call(method, **params):
        return cdp(method, session_id=session, **params)

    result = call("Runtime.evaluate", expression=CLICK_POINT_JS + "(" + json.dumps(action) + ")", returnByValue=True)
    if result.get("exceptionDetails"):
        raise StalePage("Document changed during evaluation")
    target = result.get("result", {}).get("value")
    if target is None:
        raise StalePage("Target changed or is covered. Observe again.")
    x, y = target["x"], target["y"]
    for event in ("mousePressed", "mouseReleased"):
        call("Input.dispatchMouseEvent", type=event, x=x, y=y, button="left", clickCount=1)
    if action.get("dblclick"):
        # "Open (double-click)" on a selectable row: the second click of a double click.
        for event in ("mousePressed", "mouseReleased"):
            call("Input.dispatchMouseEvent", type=event, x=x, y=y, button="left", clickCount=2)
    if action["kind"] == "fill":
        modifiers = 4 if sys.platform == "darwin" else 2
        if action.get("docs_body"):
            # Google Docs: the click placed the caret on the page; go to the end of
            # the document (⌘↓ on Mac, Ctrl+End elsewhere) and insert. Never select
            # all — that would replace the user's document with the text.
            key, code, vk = ("ArrowDown", "ArrowDown", 40) if sys.platform == "darwin" else ("End", "End", 35)
            call("Input.dispatchKeyEvent", type="keyDown", key=key, code=code, windowsVirtualKeyCode=vk, modifiers=modifiers)
            call("Input.dispatchKeyEvent", type="keyUp", key=key, code=code, windowsVirtualKeyCode=vk, modifiers=modifiers)
        else:
            call("Input.dispatchKeyEvent", type="keyDown", key="a", code="KeyA", modifiers=modifiers, commands=["selectAll"])
            call("Input.dispatchKeyEvent", type="keyUp", key="a", code="KeyA", modifiers=modifiers)
        call("Input.insertText", text=request["text"])
    return {"executed": action["id"]}


# --- Adaptation 8: a rejected click is a visible failure ----------------------

REJECTIONS_BEFORE_EXCLUDING = 2


class RejectedClicks:
    """Upstream's `tick` catches the StalePage a rejected click raises, re-observes
    and asks Jev again — from the same page, so Jev picks the same element again,
    indefinitely. Track rejections per (document, node): after two, append a
    failed step to the history (Jev's `recent_actions` then shows it changed
    nothing) and hide the element from every later decision on that document."""

    def __init__(self):
        self.rejections = {}
        self.excluded = set()
        self.excluded_fills = set()   # (document, node): the text helper had no value for this field

    @staticmethod
    def document(page):
        return (page.get("page_key") or [None])[0]

    def filter(self, page):
        """The page Jev decides from: without the elements it cannot click here,
        and without TYPE_TEXT on fields the helper could not fill."""
        if not self.excluded and not self.excluded_fills:
            return page
        doc = self.document(page)
        actions = [a for a in page["actions"] if (doc, a.get("node")) not in self.excluded
                   and not (a.get("kind") == "fill" and (doc, a.get("node")) in self.excluded_fills)]
        return {**page, "actions": actions} if len(actions) != len(page["actions"]) else page

    def no_text(self, state, decision):
        """The helper answered null for the chosen field: a visible failed step,
        and the field is no longer a TYPE_TEXT target on this document."""
        page = state["page"]
        action = next((a for a in page["actions"] if a["id"] == decision["choice"]), None)
        if action is None:
            return None
        self.excluded_fills.add((self.document(page), action["node"]))
        elapsed = round((time.perf_counter() - state["started_at"]) * 1000) if state.get("started_at") else 0
        state["history"].append({
            "step": len(state["history"]) + 1, "action": action["label"], "kind": "fill", "choice": action["id"],
            "text": None, "page_changed": False, "url": page["url"], "elapsed_ms": elapsed,
            "note": "the text helper had no value for this field; no longer offered for typing",
        })
        return action["label"]

    def after_tick(self, state, decisions_before, history_before):
        """Returns the label of an element just given up on, else None."""
        decisions, history = state["decisions"], state["history"]
        if len(decisions) != decisions_before + 1 or len(history) != history_before or state["status"] != "ready":
            return None
        decision = decisions[-1]
        if decision["operation"] not in {"CLICK", "TYPE_TEXT", "SELECT"}:
            return None
        page = state["page"]
        action = next((a for a in page["actions"] if a["id"] == decision["choice"]), None)
        if action is None or action.get("kind") not in {"click", "fill", "select"}:
            return None
        key = (self.document(page), action["node"])
        self.rejections[key] = self.rejections.get(key, 0) + 1
        if self.rejections[key] < REJECTIONS_BEFORE_EXCLUDING:
            return None
        self.excluded.add(key)
        elapsed = round((time.perf_counter() - state["started_at"]) * 1000) if state.get("started_at") else 0
        history.append({
            "step": len(history) + 1, "action": action["label"], "kind": action["kind"], "choice": action["id"],
            "text": None, "page_changed": False, "url": page["url"], "elapsed_ms": elapsed,
            "note": "could not be clicked (covered or off-screen); no longer offered",
        })
        # Upstream's stuck rule, re-evaluated with the failed step included.
        last = history[-3:]
        if len(last) == 3 and all(h.get("page_changed") is False and h.get("kind") != "wait" for h in last):
            state["status"] = "blocked"
        return action["label"]


# --- Adaptation 9: <canvas> is a click target --------------------------------

SNAPSHOT_PATCHES = [
    # Observe canvases along with the interactive elements.
    ("const selector='a[href],button,input,textarea,select,summary,[contenteditable=\"true\"],'",
     "const selector='a[href],button,input,textarea,select,summary,canvas,[contenteditable=\"true\"],'"),
    # A canvas has no ARIA role; treat it as a button so it gets the CLICK operation.
    ("if (roles.includes(explicit)) return explicit;",
     "if (roles.includes(explicit)) return explicit;\n    if (e.tagName==='CANVAS') return 'button';"),
    # Skip decorative canvases (sparklines, icons); label the rest by size and purpose.
    ("const base={node:identity(e),role:rname,label:name(e)||rname,",
     "if (e.tagName==='CANVAS' && (r.width<120 || r.height<120)) continue;\n"
     "    const base={node:identity(e),role:rname,canvas:e.tagName==='CANVAS',"
     "label:e.tagName==='CANVAS' ? (e.getAttribute('aria-label')||'Game canvas '+Math.round(r.width)+'×'+Math.round(r.height)+' (click to interact / play)') : name(e)||rname,"),
    # Adaptation 15 — the Google Docs editor container is a textbox (its own
    # contenteditable sits in a hidden iframe the snapshot cannot reach).
    ("const selector='a[href],button,input,textarea,select,summary,canvas,[contenteditable=\"true\"],'",
     "const selector='a[href],button,input,textarea,select,summary,canvas,.kix-appview-editor,[contenteditable=\"true\"],'"),
    ("if (e.tagName==='CANVAS') return 'button';",
     "if (e.tagName==='CANVAS') return 'button';\n    if (e.classList?.contains('kix-appview-editor')) return 'textbox';"),
    ("const base={node:identity(e),role:rname,canvas:e.tagName==='CANVAS',",
     "const docsBody=e.classList?.contains('kix-appview-editor');\n"
     "    const base={node:identity(e),role:rname,canvas:e.tagName==='CANVAS',docs_body:docsBody,"),
    ("label:e.tagName==='CANVAS' ? (",
     "label:docsBody ? 'Document body — the page itself; type the document text here (not the title)' : e.tagName==='CANVAS' ? ("),
    ("e.isContentEditable || rname==='combobox' ? e.innerText.trim() : '';",
     "e.isContentEditable || rname==='combobox' || e.classList?.contains('kix-appview-editor') ? e.innerText.trim().slice(0,300) : '';"),
    # Adaptation 17 — interactive list rows (Drive files, Gmail messages) are targets.
    (".kix-appview-editor,[contenteditable=\"true\"],'",
     ".kix-appview-editor,[contenteditable=\"true\"],[role=\"row\"][aria-selected],[role=\"row\"][tabindex],[role=\"row\"][data-id],'"),
    ("if (e.classList?.contains('kix-appview-editor')) return 'textbox';",
     "if (e.classList?.contains('kix-appview-editor')) return 'textbox';\n"
     "    if (explicit==='row' && (e.hasAttribute('aria-selected') || e.hasAttribute('tabindex') || e.hasAttribute('data-id'))"
     " && !e.closest('thead') && !e.querySelector('a[href],input,textarea,select,[contenteditable=\"true\"]')) return 'row';"),
    # A gridcell that is itself an item (Drive's file cards: data-id / tabindex / data-selectable)
    # is kept even though it holds a "More actions" button.
    ("if (rname==='gridcell' && e.querySelector('button,[role=\"button\"]')) continue;",
     "const itemCell=rname==='gridcell' && (e.hasAttribute('data-id') || e.hasAttribute('data-selectable') || e.hasAttribute('aria-selected') || e.hasAttribute('tabindex'));\n"
     "    if (rname==='gridcell' && !itemCell && e.querySelector('button,[role=\"button\"]')) continue;"),
    ("const docsBody=e.classList?.contains('kix-appview-editor');",
     "const docsBody=e.classList?.contains('kix-appview-editor');\n"
     "    if (rname==='row' || itemCell) {\n"
     "      const clean=t=>String(t||'').replace(/\\b(More (info|actions)|Show more)\\b.*$/i,'').replace(/\\s+/g,' ').trim().slice(0,100);\n"
     "      const rowText=clean(e.getAttribute('aria-label'))||clean(e.innerText);\n"
     "      if (!rowText) continue;\n"
     "      const rowBase={node:identity(e),role:rname==='row' ? 'row' : 'item',label:rowText,rect:{x:r.x,y:r.y,w:r.width,h:r.height}};\n"
     "      if (e.getAttribute('aria-selected')!==null) rowBase.selected=e.getAttribute('aria-selected');\n"
     "      actions.push({...rowBase,kind:'click',value:''});\n"
     "      if (itemCell || e.hasAttribute('aria-selected')) actions.push({...rowBase,kind:'click',dblclick:true,value:'',label:'Open (double-click): '+rowText});\n"
     "      continue;\n"
     "    }"),
]


_upstream_snapshot_js = browser_module.READ_STATE


def patched_snapshot_js():
    js = _upstream_snapshot_js
    for old, new in SNAPSHOT_PATCHES:
        if old not in js:
            raise RuntimeError("upstream snapshot.js changed; the canvas patch in navi_runner.py needs updating")
        js = js.replace(old, new)
    return js


def is_canvas_action(page, entry):
    action = next((a for a in page.get("actions", []) if a["id"] == entry.get("choice")), None)
    if action is not None:
        return bool(action.get("canvas"))
    return str(entry.get("action", "")).startswith("Game canvas ")


def soften_canvas_step(state, history_before):
    """A click on a canvas changes pixels, not the DOM. Upstream would count it
    as a no-change action and stop after three; record the effect as unknown
    (null) instead so the run can keep playing until Jev says DONE or the
    coach is consulted for repeating itself."""
    history = state["history"]
    if len(history) != history_before + 1:
        return
    entry = history[-1]
    if entry.get("kind") != "click" or entry.get("page_changed") is not False or not is_canvas_action(state["page"], entry):
        return
    entry["page_changed"] = None
    entry["note"] = "canvas: effect is not visible in the DOM"
    if state["status"] == "blocked":
        last = history[-3:]
        if not (len(last) == 3 and all(h.get("page_changed") is False and h.get("kind") != "wait" for h in last)):
            state["status"] = "ready"


# --- Adaptation 10: let the page settle before Jev sees it -----------------

SETTLE_MAX_S = 3.0
SETTLE_POLL_S = 0.12

INTERACTIVE = {"click", "fill", "select"}


def interactive_count(page):
    return sum(1 for a in page.get("actions", []) if a.get("kind") in INTERACTIVE)


def looks_unsettled(page, previous_url=None):
    """True when the observed page is probably still loading: nothing to act on,
    or a document that just replaced a different one (a click that navigated)."""
    if interactive_count(page) == 0:
        return True
    return previous_url is not None and not Coach.same_document(previous_url, page.get("url"))


GROWTH_CHECK_S = 0.3
GROWTH_MIN_ACTIONS = 2


def settle_page(agent, previous_url=None, max_s=SETTLE_MAX_S):
    """Re-observes until `document.readyState` is "complete" and two consecutive
    snapshots agree (same fingerprint), or `max_s` elapses. Returns the number of
    extra observations. Jev then decides from the page the user would see —
    not from the blank frame an SPA shows for its first few hundred ms.

    A page that already has controls may still be filling in: Drive shows its
    sidebar well before its file grid, and Jev called that shell BLOCKED. On the
    start page and after a navigation, one extra look `GROWTH_CHECK_S` later
    catches a table that is still growing and keeps settling until it stops."""
    page = agent.state["page"]
    browser = agent.state["browser"]
    observations = 0
    if not looks_unsettled(page, previous_url):
        if previous_url is not None and Coach.same_document(previous_url, page.get("url")):
            return 0
        time.sleep(GROWTH_CHECK_S)
        try:
            probe = browser.observe(screenshot=agent.screenshots)
        except Exception:  # noqa: BLE001 — still navigating; the loop below handles it
            return 0
        observations = 1
        grew = len(probe.get("actions", [])) >= len(page.get("actions", [])) + GROWTH_MIN_ACTIONS
        agent.state["page"] = page = probe
        if not grew:
            return observations
    deadline = time.monotonic() + max_s
    stable = page["fingerprint"]
    while time.monotonic() < deadline:
        time.sleep(SETTLE_POLL_S)
        try:
            ready = browser.evaluate("document.readyState")
        except Exception:  # noqa: BLE001 — document swapped mid-evaluate; observe below
            ready = None
        try:
            page = browser.observe(screenshot=agent.screenshots)
        except Exception:  # noqa: BLE001 — still navigating
            continue
        observations += 1
        agent.state["page"] = page
        if ready == "complete" and page["fingerprint"] == stable and interactive_count(page) > 0:
            break
        stable = page["fingerprint"]
    return observations


# --- Adaptation 11: BLOCKED is a verdict, not a reflex ----------------------

TENTATIVE_BLOCKED_CONFIDENCE = 0.6
TENTATIVE_BLOCKED_WAIT_S = 0.7
MAX_BLOCKED_RETRIES = 4


def blocked_is_tentative(decision):
    """A BLOCKED Jev is not sure about, or where WAIT is a close second: the page
    may simply not be ready yet. Answer it with a short wait, not the end."""
    if not decision or decision.get("operation") != "BLOCKED":
        return False
    probabilities = decision.get("operation_probabilities") or {}
    if decision.get("confidence", 1.0) < TENTATIVE_BLOCKED_CONFIDENCE:
        return True
    return probabilities.get("WAIT", 0.0) >= 0.25


NO_TEXT_MESSAGE = "Text helper returned no valid field value"


def tick(agent, retried, rejected=None):
    """Upstream `Agent.command("tick")` (predict → act, StalePage re-observes),
    with two differences: a tentative BLOCKED on a page not yet retried is
    discarded — the page gets a short wait and a fresh observation, and Jev
    decides again (`retried` is the set of fingerprints already given that
    second chance, so the same BLOCKED twice on the same page is final) — and
    a text helper with no value for the chosen field is a failed step
    (`RejectedClicks.no_text`), not the end of the run."""
    state = agent.state
    try:
        agent.command("predict", {})
        decision = state["decision"]
        fingerprint = state["page"]["fingerprint"]
        if blocked_is_tentative(decision) and fingerprint not in retried and len(retried) < MAX_BLOCKED_RETRIES:
            retried.add(fingerprint)
            state["decision"] = None
            state["status"] = "ready"
            time.sleep(TENTATIVE_BLOCKED_WAIT_S)
            state["page"] = state["browser"].observe(screenshot=agent.screenshots)
            settle_page(agent)
            state["elapsed_ms"] = round((time.perf_counter() - state["started_at"]) * 1000)
            return "retried"
        try:
            agent.command("act", {"fingerprint": fingerprint})
        except ValueError as exc:
            if NO_TEXT_MESSAGE not in str(exc) or decision is None:
                raise
            label = rejected.no_text(state, decision) if rejected else None
            emit("status", message=f"No text for ‘{label or decision.get('choice')}’ — telling Jev and moving on")
            state["decision"] = None
            state["status"] = "ready"
            agent.pending_text = None
            state["elapsed_ms"] = round((time.perf_counter() - state["started_at"]) * 1000)
            return "no_text"
        return "acted"
    except StalePage:
        state["decision"] = None
        state["status"] = "ready"
        state["page"] = state["browser"].observe(screenshot=agent.screenshots)
        state["elapsed_ms"] = round((time.perf_counter() - state["started_at"]) * 1000)
        return "stale"


def install_adaptations():
    if os.environ.get("NAVI_JEV_TRANSPORT") == "vercel":
        jev_model.post_json = post_json_vercel
        # Upstream reads TYPESAFE_API_KEY unconditionally; give it a placeholder.
        os.environ.setdefault("TYPESAFE_API_KEY", "via-vercel-gateway")
    import jev_ultrafast.agent as agent_module

    helper = field_text_claude if (not os.environ.get("TEXT_MODEL_API_KEY") and os.environ.get("ANTHROPIC_API_KEY")) else jev_model.field_text
    speculative = SpeculativeText(helper)
    jev_model.field_text = speculative
    # agent.py imported the names directly; patch it there too.
    agent_module.field_text = speculative
    agent_module.Browser = FastBrowser
    browser_module.browser_operation = browser_operation_navi
    js = patched_snapshot_js()
    browser_module.READ_STATE = js
    browser_module.MARKER = f"(() => {{ const state={js}; return state?.marker ?? null; }})()"
    rejected = RejectedClicks()
    original_choose = agent_module.choose

    def choose(page, goal, history):
        page = rejected.filter(page)
        speculative.speculate(goal, page, history)
        return original_choose(page, goal, history)

    agent_module.choose = choose
    return speculative, rejected


# --- Run --------------------------------------------------------------------

def summarize(history, status):
    if not history:
        return "No actions were taken." if status == "blocked" else "Nothing to do."
    parts = []
    for h in history[-6:]:
        if h["kind"] == "fill" and h.get("text"):
            parts.append(f"typed “{h['text'][:40]}” into {h['action'].split(' → ')[0]}")
        elif h["kind"] == "wait":
            parts.append("waited")
        else:
            parts.append(f"{h['kind']} {h['action'].split(' → ')[0]}")
    verb = "Done: " if status == "done" else "Stopped: "
    return verb + "; ".join(parts) + "."


# --- Adaptation 13: the tab is the deliverable ------------------------------

def tab_policy():
    """keep (default): leave the tab unless nothing happened on it; reveal: keep and
    bring it to the front when the task completes; close: close it on completion
    (a background lookup whose answer Navi shows itself), keep it otherwise."""
    policy = os.environ.get("NAVI_TAB_POLICY", "").strip().lower()
    if policy in {"keep", "reveal", "close"}:
        return policy
    if os.environ.get("NAVI_KEEP_TAB"):
        return "keep"
    return "keep"


def should_close_tab(policy, status, steps, background=None):
    """Close only what would be left over: a completed background lookup, or a
    background tab nothing was done on. Failures and cancellations keep the tab
    so the user can take over where the run stopped. A tab opened in front of
    the user is theirs the moment they see it — "go to YouTube" followed by
    "stop listening" cancelled the run at 0 steps and closed YouTube."""
    if background is None:
        background = bool(os.environ.get("NAVI_BACKGROUND_TAB"))
    if status == "done":
        return policy == "close"
    return steps == 0 and background


def reveal_tab(agent):
    """Front the runner's tab (and Chrome) once an effect task is done."""
    browser = agent.state.get("browser")
    target = getattr(browser, "target", None)
    if not target:
        return
    try:
        cdp("Target.activateTarget", targetId=target)
    except Exception:  # noqa: BLE001 — cosmetic
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--goal", required=True)
    parser.add_argument("--screenshots", action="store_true")
    parser.add_argument("--max-steps", type=int, default=0)
    args = parser.parse_args()

    speculative, rejected = install_adaptations()
    playbook = Playbook(goal=args.goal)
    playbook.install()
    FIELD_HINTS["playbook"] = playbook
    coach = Coach()
    coach.playbook = playbook
    coach.install()
    warm_connections()
    if args.max_steps > 0:
        import jev_ultrafast.questions as q

        q.MAX_STEPS = args.max_steps
        import jev_ultrafast.agent as a

        a.MAX_STEPS = args.max_steps

    emit("status", message="Connecting to Chrome…")
    try:
        agent = Agent(args.url, args.goal, screenshots=args.screenshots)
    except Exception as exc:  # noqa: BLE001
        emit("error", message=f"Could not open the browser tab: {exc}")
        return 2

    # Navi terminates the runner when a run is cancelled or the app quits; close
    # our tab instead of leaving it orphaned in the user's Chrome.
    def on_term(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, on_term)
    policy = tab_policy()
    final_status, final_steps = "error", 0
    try:
        # An SPA start page (Google Maps, Flights, …) is often blank at "interactive".
        settled = settle_page(agent)
        page = agent.state["page"]
        emit("ready", elements=len(agent.snapshot()["elements"]), url=page["url"], title=page["title"],
             settle_observations=settled)
        coach.current_url = page["url"]
        playbook.current_url = page["url"]
        if args.screenshots and page.get("screenshot"):
            emit("screenshot", jpeg_base64=page["screenshot"])
        seen_steps = 0
        seen_decisions = 0
        stop = None            # ("done"|"blocked", summary) once the run must end

        def coach_or_stop(state, why):
            """Claude coaches once per document; failing again on that page ends the run."""
            if not coach.may_ask(state["page"].get("url")):
                return ("blocked", f"Still failing after Claude's guidance ({why}). Claude's diagnosis: {coach.diagnosis}")
            emit("status", message=f"Jev is struggling ({why}) — asking Claude to diagnose")
            shot = None
            try:
                # `state` is a snapshot (no browser in it); the live agent has the tab.
                shot = agent.state["browser"].observe(screenshot=True).get("screenshot")
            except Exception:  # noqa: BLE001 — coaching works without the picture
                pass
            try:
                ms = coach.ask(state["goal"], state["page"], state["history"], why, shot)
            except Exception as exc:  # noqa: BLE001
                return ("blocked", f"Jev keeps failing ({why}) and Claude's diagnosis was unavailable: {exc}")
            emit("status", message=f"Claude · {ms} ms · {coach.diagnosis}")
            emit("guidance", text=coach.guidance)
            # A coaching entry breaks the no-change window so the stuck rule restarts.
            state["history"].append({"step": len(state["history"]) + 1, "action": "Claude guidance: " + coach.guidance[:200],
                                     "kind": "coach", "text": None, "page_changed": True, "url": state["page"]["url"]})
            # The snapshot's status is a copy: reset the live one too, or a
            # BLOCKED-triggered coaching ends `run_until_stop` with no "done" event.
            state["status"] = agent.state["status"] = "ready"
            return None

        retried_blocked = set()

        def run_until_stop():
            while agent.state["status"] not in {"done", "blocked"}:
                decisions_before, history_before = len(agent.state["decisions"]), len(agent.state["history"])
                url_before = agent.state["page"].get("url")
                result = tick(agent, retried_blocked, rejected)
                if result == "retried":
                    emit("status", message="Jev leaned BLOCKED but wasn't sure — waited for the page and asked again")
                soften_canvas_step(agent.state, history_before)
                given_up = rejected.after_tick(agent.state, decisions_before, history_before)
                if given_up:
                    emit("status", message=f"‘{given_up[:60]}’ can't be clicked here — telling Jev and moving on")
                # A click that navigated: give the new document time to render before Jev decides.
                if agent.state["status"] == "ready" and len(agent.state["history"]) > history_before:
                    n = settle_page(agent, previous_url=url_before)
                    if n:
                        emit("status", message=f"Page changed — settled after {n} observation{'s' if n != 1 else ''}")
                coach.current_url = agent.state["page"].get("url")
                playbook.current_url = coach.current_url
                yield agent.snapshot()

        for state in run_until_stop():
            for d in state["decisions"][seen_decisions:]:
                emit(
                    "decision",
                    operation=d["operation"],
                    target=d["target"],
                    confidence=d["confidence"],
                    latency_ms=d["latency_ms"],
                    operation_probabilities=d["operation_probabilities"],
                    target_confidence=d.get("target_confidence"),
                    usage=d.get("usage", {}),
                    # The table Jev chose from (index → role + label), so a wrong pick can be read
                    # back from ultrafast-last-run.jsonl without re-running the task.
                    elements=[f"[{i}] {e.get('role', '')} {e.get('label', '')}"[:90]
                              for i, e in enumerate(((d.get("request") or {}).get("state") or {}).get("elements") or [], 1)][:80],
                )
            seen_decisions = len(state["decisions"])
            for h in state["history"][seen_steps:]:
                emit(
                    "step",
                    step=h["step"],
                    action=h["action"],
                    kind=h["kind"],
                    text=h.get("text"),
                    page_changed=h.get("page_changed"),
                    url=h.get("url"),
                    elapsed_ms=h.get("elapsed_ms"),
                    text_helper=h.get("text_helper"),
                    text_latency_ms=h.get("text_latency_ms"),
                    note=h.get("note"),
                )
            seen_steps = len(state["history"])
            if args.screenshots and state["page"].get("screenshot"):
                emit("screenshot", jpeg_base64=state["page"]["screenshot"])
            # Only actions since the last coaching count towards a new failure streak.
            recent = state["history"]
            for i in range(len(recent) - 1, -1, -1):
                if recent[i].get("kind") == "coach":
                    recent = recent[i + 1:]
                    break
            why = None
            if state["status"] == "blocked":
                why = Coach.flailing(recent) or "Jev answered BLOCKED"
            elif state["status"] == "ready":
                why = Coach.flailing(recent)
            if why:
                stop = coach_or_stop(state, why)
                if stop is None:
                    continue
            if state["status"] in {"done", "blocked"} or stop:
                status = stop[0] if stop else state["status"]
                final_status, final_steps = status, len(state["history"])
                if status == "done" and policy == "reveal":
                    reveal_tab(agent)
                emit(
                    "done",
                    status=status,
                    elapsed_ms=state["elapsed_ms"],
                    steps=len(state["history"]),
                    summary=stop[1] if stop else summarize(state["history"], state["status"]),
                    url=state["page"]["url"],
                    title=state["page"].get("title", ""),
                    page_text=(state["page"].get("text") or "")[:6000],
                    speculative_text=speculative.stats,
                    coached=coach.used,
                    coachings=coach.count,
                )
                break
        return 0
    except KeyboardInterrupt:
        final_status, final_steps = "cancelled", len(agent.state["history"])
        emit("done", status="cancelled", elapsed_ms=agent.state.get("elapsed_ms", 0),
             steps=final_steps, summary="Cancelled.")
        return 130
    except Exception as exc:  # noqa: BLE001
        final_steps = len(agent.state.get("history", []))
        emit("error", message=str(exc))
        return 1
    finally:
        # The tab is what the user asked for ("make a Google Doc"): it stays open
        # unless nothing happened on it, or a background lookup completed.
        if should_close_tab(policy, final_status, final_steps):
            try:
                agent.close()
            except Exception:  # noqa: BLE001
                pass


if __name__ == "__main__":
    sys.exit(main())
