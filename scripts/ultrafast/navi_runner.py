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

Navi passes credentials through the environment (never argv). A signed-in
user has no vendor keys — everything goes through Navi Cloud (adaptation 20):
  NAVI_JEV_TRANSPORT=navi     — Jev → <NAVI_CLOUD_URL>/v1/jev, text helper and
  NAVI_CLOUD_URL                coach → <NAVI_CLOUD_URL>/v1/claude, with
  NAVI_CLOUD_TOKEN              `Authorization: Bearer <NAVI_CLOUD_TOKEN>` (the
  NAVI_CLOUD_FEATURE            account's short-lived access token) and
  NAVI_CLOUD_RUN                X-Navi-Feature / X-Navi-Run (the task's run)
Developer mode (bring your own keys):
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
 20. Navi Cloud: with NAVI_JEV_TRANSPORT=navi the runner holds no vendor key.
     Jev and Claude requests go to the account's proxy with a bearer token and
     the task's feature/run headers, so a browser step is metered as part of
     the task that started it; the proxy's 401/402/403 become typed errors
     (`{"event":"error","code":"quota_exceeded",…}`) Navi words as its own.
 19. The user's own context rides in Jev's state: Navi's screen memory knows
     who "bella" is (Bella Chen, texted in Messages), which Google Doc "the HCI
     notes" are and who works on them. Those things (NAVI_USER_CONTEXT_JSON,
     only the ones the goal names) are added to every request as
     `user_context`, next to the playbook.
 21. The user's own clicks mark the page: Navi's screen memory records what
     this user clicks on each site (NAVI_USER_MOVES_JSON from `UserMoves`).
     Elements whose label is one of theirs get `this_user` ("clicks this here
     (12×)", "usually clicks this next") in the state and in the target
     questions' criteria, and those questions say to prefer them when the goal
     could mean several. Same matching as the native driver: badge counts and
     a trailing "…" don't matter, a row matches on its name.
 22. The user's own way of doing this task: when Navi matched the task to one
     of the user's routines (NAVI_USER_ROUTE_JSON from `UserRoutines` — the
     controls they used last time, in order, with the person or item that
     changes as a slot the task fills), the element that is their next step
     is marked `this_user` ("this user's own next step for this task"), the
     whole way rides in the state as `this_users_way` (✓ done, → next), and a
     click or fill on a step's element moves the route on. Same matching as
     the native driver's `UserRoute`.
 32. Stuck → Claude takes the wheel; outcomes are judged, not assumed. When Jev
     circles, changes nothing, answers BLOCKED, or says DONE unsure (< 85 %),
     Claude first judges the page (achieved / partial / not_achieved /
     impossible / needs_user + answer + next step). Met → done; impossible or
     needs the user → an honest stop; otherwise Claude computer use drives this
     tab (CDP screenshots + input, ≤ 8 rounds, ≤ 3 takeovers a run, Jev's
     irreversible gate per turn, never pays, never types a secret) and hands
     back to Jev once the page moved on. The done event carries `outcome` and
     `answer`. Claude calls retry a dead pooled connection (the "[Errno 32]
     Broken pipe" that killed the coach). Details at the section comment.
 33. Frames are part of the page: visible same- and out-of-process iframes are
     read too (DoorDash's sign-in dialog is an identity.doordash.com iframe);
     their controls join only where a click reaches them; actions carry
     `frame`; captcha frames are never offered.
 34. Open shadow roots are queried and hit-tested; <style>/<script> text is
     never part of a label.
 35. role=dialog/alertdialog and backdrop overlays count as the dialog in
     front; 6+ unnamed controls of one role (map pins) are dropped.
 36. A perception gap (unreadable_frame / empty_dialog / unseen_change /
     captcha) is reported in the page and as one event; the run controller
     decides what to do with it.
 37. A question, not an ending: a needs_user judgment carries `question`,
     `question_kind` (choice: 2–4 `question_choices` from the page; do_it: a
     sign-in, code or captcha only the user can do) in the done event, and
     the tab is kept (`tab` = its target id). Navi pauses on it and reruns
     the runner on that tab (NAVI_ATTACH_TARGET) with the answers so far
     (NAVI_USER_SAID_JSON) in Jev's state, the judge's and the takeover's as
     `user_said`. Navi's own purchase hand-off is never a question.
 38. A failed Jev call is a stop to judge, not the end: the request is cut to
     fit Jev's input cap (≈ 32.5k tokens; over it Jev answers HTTP 400
     max_tokens_exceeded — what killed the Uber Eats "Add 1 to order" runs),
     a failure is logged with its redacted body (`model_error` event, run log
     only) and retried once, shorter; refused even then, Jev sees the
     controls likeliest for the goal; still failing, the run judges the page
     (32) instead of ending on a raw error.
 39. Never the user's sign-in, checkout or a partner site: unless the goal is to sign in or up,
     sign-in / sign-up / "Continue with Google" controls and an account form's identity fields are
     not offered to Jev (`account_form` in its state says why), the text helper gets no
     about_the_user for them, and the takeover refuses them, never types the user's email or name
     into such a form, never enters checkout (a "Continue" that lands there is undone) and stops for
     the user on a sign-in page. A needs-user sign-in is a question even on a purchase, and a
     purchase whose item is in the cart is achieved whatever is left (checkout, signing in, paying).
     Partner-compare toggles ("Compare vs. Booking.com") are not offered or pressed in an errand.
 40. "Document is navigating" / "Inspected target navigated or closed" is the page moving under
     the step: observe again, never an error that ends the run (only a run of them does).
"""

import argparse
import json
import math
import os
import re
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
            raise JevCallFailed(f"Vercel AI Gateway returned HTTP {response.status_code}; no action executed.",
                                response.status_code, error_detail(response))
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


# --- Adaptation 20: Navi Cloud (a signed-in user has no vendor keys) --------

class CloudError(RuntimeError):
    """The proxy refused the call (signed out, over quota, not on the plan, …).
    `fields` ride on the runner's error event so Navi can word it itself."""

    def __init__(self, message, **fields):
        super().__init__(message)
        self.fields = fields


def navi_cloud():
    """(base_url, headers) when this run goes through Navi Cloud, else None."""
    if os.environ.get("NAVI_JEV_TRANSPORT") != "navi":
        return None
    base = os.environ.get("NAVI_CLOUD_URL", "").strip().rstrip("/")
    token = os.environ.get("NAVI_CLOUD_TOKEN", "").strip()
    if not base or not token:
        return None
    headers = {"Authorization": f"Bearer {token}",
               "X-Navi-Feature": os.environ.get("NAVI_CLOUD_FEATURE", "").strip() or "task"}
    run = os.environ.get("NAVI_CLOUD_RUN", "").strip()
    if run:
        headers["X-Navi-Run"] = run
    return base, headers


def cloud_error(response):
    """A CloudError for the proxy's own refusals (docs/LAUNCH_ROADMAP.md §3.1); None otherwise."""
    status = response.status_code
    try:
        body = response.json()
    except ValueError:
        body = {}
    if not isinstance(body, dict):
        body = {}
    code = body.get("error")
    extra = {k: body[k] for k in ("feature", "tier", "resetsAt", "retryAfterSeconds") if body.get(k) is not None}
    if status == 401:
        return CloudError("Your Navi session has expired. Sign in to Navi again.", code="signed_out", status=401)
    if status == 402:
        return CloudError("You've reached your plan's limit for tasks.", code="quota_exceeded", status=402, **extra)
    if status == 403:
        return CloudError("Your plan doesn't include this.", code="not_entitled", status=403, **extra)
    if status == 429 and code == "rate_limited":
        return CloudError("Navi is busy, try again in a moment.", code="rate_limited", status=429, **extra)
    if status == 503 and code in {"upstream_unconfigured", "billing_unconfigured"}:
        return CloudError("Navi isn't set up yet.", code=code, status=503)
    return None


def post_cloud(path, body, what):
    """POST to Navi Cloud with the run's headers. Busy/overloaded answers are retried
    like upstream does; a refusal (401/402/403, unconfigured) never is."""
    base, headers = navi_cloud()
    for attempt in range(3):
        try:
            response = jev_model.CLIENT.post(base + path, json=body, headers=headers)
        except httpx.HTTPError:
            raise RuntimeError(f"Could not reach Navi ({what}); no action executed.") from None
        refusal = cloud_error(response) if response.is_error else None
        if refusal is not None and refusal.fields.get("code") != "rate_limited":
            raise refusal
        if response.status_code in {429, 529, 503} and attempt < 2:
            time.sleep(0.5 * 2**attempt)
            continue
        if refusal is not None:
            raise refusal
        if response.is_error:
            raise JevCallFailed(f"Navi returned HTTP {response.status_code} ({what}); no action executed.",
                                response.status_code, error_detail(response))
        return response.json()
    raise RuntimeError(f"Navi is unavailable ({what}); no action executed.")


def post_json_navi(url, key, body):
    """Upstream's TypeSafe call, posted to <NAVI_CLOUD_URL>/v1/jev instead (same body)."""
    if "typesafe.ai" not in url:
        return _upstream_post_json(url, key, body)
    return post_cloud("/v1/jev", body, "deciding")


def claude_endpoint():
    """Where Claude Messages calls go: (url, headers), or None when nothing is configured.
    Cloud: the account's proxy with the bearer + run headers. Developer mode: the
    Anthropic API (or ANTHROPIC_BASE_URL) with ANTHROPIC_API_KEY."""
    cloud = navi_cloud()
    if cloud:
        base, headers = cloud
        return base + "/v1/claude", {**headers, "anthropic-version": "2023-06-01"}
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        return None
    base = os.environ.get("ANTHROPIC_BASE_URL", "https://api.anthropic.com").rstrip("/")
    return base + "/v1/messages", {"x-api-key": key, "anthropic-version": "2023-06-01"}


# --- Adaptation 38: a failed Jev call is a stop to judge, not the end --------
#
# Two live Uber Eats runs (2026-10-31: "Order Wingstop food under $20", "Red Bull … through Uber
# Eats") died right after a Quick Add with "Model provider returned HTTP 400; no action executed."
# Upstream never reads the body, so nobody knew why. Probed: Jev answers a malformed question with
# 422 (> 255 options, an empty choice) and a request over its input cap (≈ 32.5k tokens) with
# 400 {"detail": {"error_type": "max_tokens_exceeded"}}. The request carries every element twice
# (state + target criteria) on top of the playbook, the user's context and the page text, and labels
# are never cut: a store page is ~7k tokens, but controls named by whole cards or a drawer named by
# its contents push it past the cap. Now:
#   - the request is measured before it leaves; over JEV_TOKEN_BUDGET its long strings are cut
#     (labels, page text, any state string). Choice ids never change, so answers still validate;
#   - a failed call carries its status and a redacted body (the `model_error` event goes to the run
#     log only: type/loc/msg/error_type, never the `input` Jev echoes back) and the request's shape;
#   - it is retried once, cut shorter again after a 400/413; refused even then (250 controls with
#     60-character labels are still ~33k tokens, measured), Jev sees only the controls likeliest for
#     the goal (`fewer_actions`, in `install_adaptations`' choose: the answer validates against them);
#   - still failing → `JevUnavailable`, which `tick` turns into a stop the run judges (32): a cart
#     already filled ends achieved or partial, otherwise Claude takes over for a few steps.

JEV_TOKEN_BUDGET = 28000      # Jev rejects ≈ 32.5k input tokens
CHARS_PER_TOKEN = 2.0         # measured 2.1 (short labels: mostly JSON) to 3.8 (long prose labels)
TRIMMED_ACTIONS = 120         # controls Jev sees when the whole page is too much for one request
# (label, page text, any other string, list length) per level of cutting
COMPACT_LEVELS = {1: (160, 3000, 1500, 30), 2: (60, 1200, 400, 12)}
KEEP_WHOLE = {"goal", "rules", "operation"}   # instructions Jev must read in full


class JevCallFailed(RuntimeError):
    """A Jev request that came back as an error: the status and the redacted body ride along."""

    def __init__(self, message, status=None, detail=None):
        super().__init__(message)
        self.status = status
        self.detail = detail


class JevUnavailable(RuntimeError):
    """Jev could not be asked on this page even after a retry; the run judges where it stands."""


class JevTooLarge(JevUnavailable):
    """Refused as too large even at the hardest cut: fewer controls are the only way left."""


def error_detail(response):
    """What the provider said, without anything it echoes back from the request (page text)."""
    try:
        data = response.json()
    except Exception:  # noqa: BLE001 — not JSON: a proxy page; its head is enough
        return (getattr(response, "text", "") or "")[:200]
    detail = data.get("detail", data.get("error", data)) if isinstance(data, dict) else data
    if isinstance(detail, list):
        return [{k: d[k] for k in ("type", "loc", "msg") if k in d} for d in detail[:5] if isinstance(d, dict)]
    if isinstance(detail, dict):
        return {k: v for k, v in detail.items() if k != "input" and isinstance(v, (str, int, float, bool))}
    return str(detail)[:200]


def post_json_typesafe(url, key, body):
    """Upstream's `post_json` for api.typesafe.ai, keeping the error's status and body."""
    if "typesafe.ai" not in url:
        return _upstream_post_json(url, key, body)
    for attempt in range(3):
        try:
            response = jev_model.CLIENT.post(url, json=body, headers={"Authorization": f"Bearer {key}"})
        except httpx.HTTPError:
            raise JevCallFailed("Model connection failed; no action executed.") from None
        if response.status_code in {429, 529, 503} and attempt < 2:
            time.sleep(0.5 * 2**attempt)
            continue
        if response.is_error:
            raise JevCallFailed(f"Model provider returned HTTP {response.status_code}; no action executed.",
                                response.status_code, error_detail(response))
        return response.json()
    raise JevCallFailed("Model unavailable")


def request_chars(body):
    return len(json.dumps(body, ensure_ascii=False))


def request_shape(body):
    """Sizes only — never the page's words — so a failure says which part of the request was big."""
    state = body.get("state") if isinstance(body.get("state"), dict) else {}
    elements = state.get("elements") if isinstance(state.get("elements"), list) else []
    labels = [len(str(e.get("label", ""))) for e in elements if isinstance(e, dict)]
    chars = request_chars(body)
    return {
        "chars": chars,
        "est_tokens": round(chars / CHARS_PER_TOKEN),
        "elements": len(elements),
        "longest_label": max(labels, default=0),
        "state": {k: request_chars(v) for k, v in state.items()},
        "choices": {name: len(q.get("criteria") or {}) for name, q in (body.get("questions") or {}).items()
                    if isinstance(q, dict) and q.get("type") == "choice"},
    }


def cut(value, limit, list_limit):
    """Every string in `value` at most `limit` characters and every list at most `list_limit` long."""
    if isinstance(value, str):
        return value if len(value) <= limit else value[:limit - 1] + "…"
    if isinstance(value, list):
        return [cut(v, limit, list_limit) for v in value[:list_limit]]
    if isinstance(value, dict):
        return {k: cut(v, limit, list_limit) for k, v in value.items()}
    return value


def compact_request(body, level):
    """The same request with its long strings cut (level 1, then harder at 2). Element indices,
    criteria keys and the goal/rules stay as they are, so the answer validates against them."""
    label, text, other, lists = COMPACT_LEVELS[level]
    body = dict(body)
    state = body.get("state")
    if isinstance(state, dict):
        state = dict(state)
        for k, v in state.items():
            if k == "elements" and isinstance(v, list):
                state[k] = [{**e, **{f: cut(e[f], label, lists) for f in ("label", "value", "options") if f in e}}
                            if isinstance(e, dict) else e for e in v]
            elif k == "page" and isinstance(v, dict):
                state[k] = {**cut({p: x for p, x in v.items() if p != "text"}, other, lists),
                            **({"text": cut(v["text"], text, lists)} if "text" in v else {})}
            else:
                state[k] = cut(v, other, lists)
        body["state"] = state
    questions = {}
    for name, q in (body.get("questions") or {}).items():
        if isinstance(q, dict):
            q = dict(q)
            if isinstance(q.get("criteria"), dict):
                q["criteria"] = {key: ({f: cut(x, label if f == "element" else other, lists) for f, x in c.items()}
                                       if isinstance(c, dict) else cut(c, other, lists))
                                 for key, c in q["criteria"].items()}
            if isinstance(q.get("instructions"), dict):
                q["instructions"] = {k: v if k in KEEP_WHOLE else cut(v, other, lists)
                                     for k, v in q["instructions"].items()}
        questions[name] = q
    if questions:
        body["questions"] = questions
    return body


def too_large(body):
    return request_chars(body) / CHARS_PER_TOKEN > JEV_TOKEN_BUDGET


def guarded_jev(post):
    """Wraps the Jev transport: fit the request under Jev's cap, log a failure with its body, retry
    once, and give up as `JevUnavailable` (the run controller judges the page instead)."""

    def post_json(url, key, body):
        if not (isinstance(body, dict) and "questions" in body):
            return post(url, key, body)   # the text helper and anything else that isn't a decision
        original, level = body, 0
        if too_large(body):
            level = 1
            body = compact_request(original, 1)
            if too_large(body):
                level, body = 2, compact_request(original, 2)
            emit("status", message="This page is a lot to read — showing Jev a shorter version")
        for attempt in (1, 2):
            try:
                return post(url, key, body)
            except CloudError:
                raise             # signed out / over the plan: Navi words it (adaptation 20)
            except RuntimeError as exc:
                status, detail = getattr(exc, "status", None), getattr(exc, "detail", None)
                emit("model_error", attempt=attempt, message=str(exc), status=status, detail=detail,
                     compacted=level, request=request_shape(body))
                refused = status in {400, 413}
                if attempt == 2 or (refused and level == 2):
                    reason = f"HTTP {status}" if status else str(exc).split(";")[0]
                    if isinstance(detail, dict) and detail.get("error_type"):
                        reason += f": {detail['error_type']}"
                    raise (JevTooLarge if refused else JevUnavailable)(
                        f"Jev couldn't decide on this page ({reason})") from None
                if refused:
                    level += 1
                    body = compact_request(original, level)
                    emit("status", message="Jev couldn't read this page — trying again with a shorter version")
                else:
                    time.sleep(0.4)

    return post_json


GOAL_FILLER = {"the", "and", "for", "from", "with", "some", "order", "under", "food", "get", "find", "open", "add"}


def fewer_actions(page, goal, keep=TRIMMED_ACTIONS):
    """The page with at most `keep` controls: every field and dropdown, then the controls whose
    label shares the most words with the goal, then the first on the page. The page itself is
    unchanged when it already has few enough."""
    actions = page.get("actions") or []
    order = {}
    for a in actions:
        if a.get("kind") in INTERACTIVE and a.get("node") is not None:
            order.setdefault(a["node"], (len(order), a.get("label") or ""))
    if len(order) <= keep:
        return page
    words = {w for w in re.findall(r"[a-z0-9$]+", (goal or "").lower()) if len(w) > 2} - GOAL_FILLER
    fields = {a.get("node") for a in actions if a.get("kind") in {"fill", "select"}}

    def rank(node):
        index, label = order[node]
        shared = len(words & set(re.findall(r"[a-z0-9$]+", label.lower())))
        return (node not in fields, -shared, index)

    kept = set(sorted(order, key=rank)[:keep])
    return {**page, "actions": [a for a in actions if a.get("kind") not in INTERACTIVE or a.get("node") in kept]}


# --- Adaptation 31: today's date and the goal's dates, worked out ------------
#
# "find flights from boston to new york next friday" picked today (a Friday): Jev had no date.
# Every request carries `facts`: today, and each relative date the goal names resolved
# ("next friday" → Friday, November 6, 2026), the way the native driver's CUFacts do.

WEEKDAYS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]


def date_facts(goal, today=None):
    import datetime as _dt
    today = today or _dt.date.today()
    fmt = lambda d: f"{d:%A}, {d:%B} {d.day}, {d.year}"
    out = {"today": fmt(today)}
    g = (goal or "").lower()
    found = {}
    if re.search(r"\btoday\b|\btonight\b", g):
        found["today"] = fmt(today)
    if "tomorrow" in g:
        found["tomorrow"] = fmt(today + _dt.timedelta(days=1))
    for m in re.finditer(r"\b(next|this|on|coming)?\s*(" + "|".join(WEEKDAYS) + r")\b", g):
        which, day = m.group(1), m.group(2)
        ahead = (WEEKDAYS.index(day) - today.weekday()) % 7
        if which == "next":
            ahead = ahead + 7 if ahead == 0 else ahead
            # "next friday" said on a weekday before it in the same week still means that coming one
        elif ahead == 0 and which != "this":
            ahead = 7
        found[m.group(0).strip()] = fmt(today + _dt.timedelta(days=ahead))
    if re.search(r"\bnext week\b", g):
        found["next week"] = "the week of " + fmt(today + _dt.timedelta(days=7 - today.weekday()))
    if found:
        out["dates_in_goal"] = found
    return out


# --- Adaptation 2: text helper on Claude Haiku ------------------------------

FIELD_HINTS = {"playbook": None}   # set by main(); the helper adds the page's field hints


def field_text_claude(context):
    """Same contract as upstream field_text, using the Anthropic Messages API."""
    endpoint = claude_endpoint()
    if endpoint is None:
        raise ValueError("TYPE_TEXT needs ANTHROPIC_API_KEY or TEXT_MODEL_API_KEY; nothing typed.")
    url, headers = endpoint
    model = os.environ.get("NAVI_TEXT_MODEL", "claude-haiku-4-5")
    playbook = FIELD_HINTS.get("playbook")
    if playbook is not None and isinstance(context, dict):
        hints = playbook.field_hints_for((context.get("page") or {}).get("url") or playbook.current_url)
        if hints:
            context = {**context, "field_hints": hints}
    context = with_user_details(context)
    started = time.perf_counter()
    for attempt in range(3):
        try:
            response = jev_model.CLIENT.post(
                url,
                headers=headers,
                json={
                    "model": model,
                    "max_tokens": 512,
                    "system": TEXT_VALUE + " " + TEXT_ADDENDUM + " Output only the JSON object.",
                    "messages": [{"role": "user", "content": json.dumps(context)}],
                },
            )
        except httpx.TransportError:
            # A pooled connection the server closed while idle ([Errno 32] Broken pipe): a fresh one works.
            if attempt < 2:
                continue
            raise RuntimeError("Text helper connection failed; nothing typed.") from None
        except httpx.HTTPError:
            raise RuntimeError("Text helper connection failed; nothing typed.") from None
        refusal = cloud_error(response) if response.is_error and navi_cloud() else None
        if refusal is not None and refusal.fields.get("code") != "rate_limited":
            raise refusal
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


# --- Adaptation 25: a new tab opens here -------------------------------------
#
# McDonald's "Order Delivery" → "Yes, Continue" opened the ordering site in a new tab; the
# runner kept observing the old one and clicked "Order Now" again until the step limit. In
# the runner's own tab (never a tab of the user's it attaches to), a link to a new tab and a
# plain window.open(url) load in this tab instead, so the run follows where the click went.
# A window.open with features (an OAuth popup) is left alone.

ONE_TAB_JS = """(() => {
  if (window.__naviOneTab) return;
  window.__naviOneTab = true;
  const open = window.open;
  window.open = function (u, t, f) {
    if (u && (!t || t === '_blank' || t === '_new') && !f) { location.assign(new URL(u, location.href).href); return window; }
    return open.apply(this, arguments);
  };
  document.addEventListener('click', ev => {
    const a = ev.target && ev.target.closest && ev.target.closest('a[target]');
    if (a && a.href && /^_(blank|new)$/i.test(a.target) && !a.hasAttribute('download')) a.target = '_self';
  }, true);
})()"""


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
        # Adaptation 37: after a question the run goes on in its own tab, wherever the user left it
        # (signing in moves it to another URL) — found by its target id first, else by its URL.
        attach_target = os.environ.get("NAVI_ATTACH_TARGET", "").strip()
        existing = find_target(attach_target) if attach_target else None
        own_tab = existing is not None
        if existing is None and attach_url:
            existing = find_open_tab(attach_url)
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
        if not self.attached or own_tab:
            try:
                # The script only runs with the Page domain on (the daemon's event buffer is bounded).
                self.call("Page.enable")
                self.call("Page.addScriptToEvaluateOnNewDocument", source=ONE_TAB_JS)
            except Exception:  # noqa: BLE001 — without it a new tab is simply not followed
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
        FRAMES.pop(getattr(self, "session", None), None)
        if self.attached:
            self.target = None
            return
        super().close()

    # Adaptation 33: a frame element is fresh when its own frame's page key and guard still match.
    def fresh(self, page, action=None):
        if action is not None and action.get("frame") and action["kind"] in {"click", "select"}:
            node, fid = action["node"], action["frame"]
            if type(node) is not int:
                return False
            try:
                current = frame_reader(self.session).evaluate(
                    fid, "(() => { const c=window.__jevFast; "
                         f"return c ? [c.pageKey(),c.guard(c.nodes.get({node}))] : null; }})()")
            except StalePage:
                return False
            return current == [(page.get("frames") or {}).get(fid, {}).get("page_key"), page["guards"].get(str(node))]
        return super().fresh(page, action)

    # Adaptation 36: thumbnails around a click, and the perception gap after an observation.
    def thumbnail(self, page):
        if page.get("screenshot"):
            return thumbnail_cells(page["screenshot"])
        try:
            w, h = page.get("w"), page.get("h")
            if not w or not h:
                return None
            shot = self.call("Page.captureScreenshot", format="jpeg", quality=40,
                             clip={"x": 0, "y": 0, "width": w, "height": h, "scale": 0.1})
            return thumbnail_cells(shot.get("data"))
        except Exception:  # noqa: BLE001 — no evidence either way
            return None

    def wants_thumbnail(self, page, action):
        """A capture costs ~140 ms a click, so only where a change could hide from the DOM: a
        canvas, a page with frames, or a page whose last action changed nothing Navi reads."""
        if action.get("kind") not in {"click", "select"}:
            return False
        if page.get("screenshot"):
            return True      # free: decoded from the observation's own screenshot
        return bool(action.get("canvas") or action.get("frame") or page.get("frames") or page.get("unread_frames")
                    or getattr(self, "last_unchanged", False))

    def act(self, action, page, text=None):
        self.acted_on = (page, action)
        self.before_thumb = self.thumbnail(page) if self.wants_thumbnail(page, action) else None
        return super().act(action, page, text=text)

    def observe(self, screenshot=True):
        acted = getattr(self, "acted_on", None)
        self.acted_on = None
        page = super().observe(screenshot=screenshot)
        before, action = acted if acted else (None, None)
        changed = None
        self.last_unchanged = before is not None and before.get("fingerprint") == page.get("fingerprint")
        if self.last_unchanged and getattr(self, "before_thumb", None):
            changed = visual_change(self.before_thumb, self.thumbnail(page))
        gap = perception_gap(page, before, action, changed)
        retries = 0
        retried = self.__dict__.setdefault("gaps_retried", set())
        key = gap and (page.get("url"), gap["reason"], gap.get("detail"))
        if gap and gap["reason"] in {"unreadable_frame", "empty_dialog"} and key not in retried:
            # A dialog's frame loads after the dialog: look again (once per gap) before calling it one.
            retried.add(key)
            while gap and retries < GAP_RETRIES:
                retries += 1
                time.sleep(GAP_RETRY_S)
                page = super().observe(screenshot=screenshot)
                gap = perception_gap(page)
        if gap:
            page["perception_gap"] = gap
            reported = self.__dict__.setdefault("gaps_reported", set())
            if page.get("fingerprint") not in reported:
                reported.add(page.get("fingerprint"))
                emit("perception_gap", url=page.get("url"), elements=sum(1 for a in page.get("actions", []) if a.get("kind") in INTERACTIVE),
                     retries=retries, **gap)
        return page


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


def find_target(target_id, targets=None):
    """`target_id` when that Chrome tab is still open, else None (adaptation 37)."""
    if targets is None:
        try:
            from browser_harness.helpers import cdp
            targets = cdp("Target.getTargets").get("targetInfos", [])
        except Exception:  # noqa: BLE001 — no daemon yet: open our own tab
            return None
    return next((t["targetId"] for t in targets if t.get("type") == "page" and t.get("targetId") == target_id), None)


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
    cloud = navi_cloud()
    if cloud:
        # One host serves Jev and Claude; /healthz is unauthenticated and free.
        targets.append((cloud[0] + "/healthz", {}))
    elif os.environ.get("NAVI_JEV_TRANSPORT") == "vercel":
        targets.append(("https://ai-gateway.vercel.sh/", {}))
    elif os.environ.get("TYPESAFE_API_KEY"):
        targets.append(("https://api.typesafe.ai/v1/models", {"Authorization": f"Bearer {os.environ['TYPESAFE_API_KEY']}"}))
    if not cloud and os.environ.get("ANTHROPIC_API_KEY") and not os.environ.get("TEXT_MODEL_API_KEY"):
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
        return Coach.circling(history)

    @staticmethod
    def circling(history):
        """The same few actions over and over (Order Now → Order Delivery → Yes, Continue, 30×):
        every step changed the page, so the no-change rule never fired."""
        acts = [(h.get("kind"), (h.get("action") or "")[:80]) for h in history if h.get("kind") not in {"wait", "coach", "scroll", "check", "takeover"}]
        for period in (2, 3, 4):
            if len(acts) >= 2 * period and acts[-period:] == acts[-2 * period:-period] and len(set(acts[-period:])) == period:
                return "going in circles (%s)" % " → ".join(a[1].split("\n")[0][:30] for a in acts[-period:])
        return None

    playbook = None   # set by main(): the Playbook, so the coach reads the same site knowledge

    def ask(self, goal, page, history, why, screenshot_b64=None):
        if claude_endpoint() is None:
            raise ValueError("no Anthropic key")
        model = os.environ.get("NAVI_AGENT_MODEL", "claude-sonnet-5")
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
        result = claude_post({"model": model, "max_tokens": 700, "system": COACH_SYSTEM,
                              "messages": [{"role": "user", "content": content}]}, timeout=60, what="Claude's diagnosis")
        out = json_object(message_text(result))
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


# --- Adaptation 32: a stuck run is finished by Claude, and its outcome is judged ----
#
# Liam's policy (2026-10-30): when Jev is stuck — circling (DoorDash: Sign In ↔ Close 4×), changing
# nothing, BLOCKED on a page that should work, or an unsure "done" — Navi hands the next steps to the
# slower Claude computer-use loop on the same tab, then gives control back to Jev once the page has
# moved on. Success matters more than speed on the hard tenth of tasks.
#
# Why in the runner (screenshots + CDP input) and not the native Claude loop on Chrome's window: the
# tab may be a background tab (NAVI_BACKGROUND_TAB) that is not on screen at all; CDP captures exactly
# this tab's viewport and posts input to it in CSS coordinates, with no cursor, focus or other window
# in the way; and the runner already owns the tab, its history and the stuck rules, so Jev resumes
# from the very page Claude left, with Claude's actions in its recent_actions. A modal Jev cannot read
# (DoorDash's sign-in lives in a cross-origin iframe) is pixels like any other to Claude.
#
# Every stop is first a typed judgment (`judge`): achieved / partial / not_achieved / impossible /
# needs_user, with the answer and the one next step. "achieved" ends the run as done (Chipotle's cart
# was full while Jev re-saved a name field); impossible and needs_user end it honestly; the rest go to
# the takeover while budget remains. The done event carries `outcome`, so Navi never calls a run
# completed whose own answer says "I couldn't…". Navi still never pays (27), never types a secret,
# and Jev's irreversible gate still guards every Claude turn that would change something.
#
# The diagnosis that failed with "[Errno 32] Broken pipe": the coach posted its screenshot on the
# HTTP/2 connection warmed for the text helper at start-up; the server had closed it while idle and
# httpx raised on the write instead of reconnecting. Claude calls now go through `claude_post` on
# their own HTTP/1.1 client, which retries a transport error on a fresh connection, and screenshots
# are captured at ≤ 1280 px wide (`viewport_shot`) instead of the Retina full size.

CLAUDE_CLIENT = httpx.Client(http2=False, timeout=90)
CLAUDE_RETRY_STATUS = {429, 500, 502, 503, 529}


def claude_post(body, timeout=90, what="Claude"):
    """POST a Messages body to Claude (Navi Cloud or Anthropic). A transport error — a pooled
    connection the server closed ("[Errno 32] Broken pipe"), a reset, a timeout — is retried on a
    fresh connection; busy answers back off. Navi Cloud's refusals raise CloudError."""
    endpoint = claude_endpoint()
    if endpoint is None:
        raise ValueError("no Anthropic key")
    url, headers = endpoint
    last = None
    for attempt in range(3):
        try:
            response = CLAUDE_CLIENT.post(url, headers=headers, json=body, timeout=timeout)
        except httpx.TransportError as exc:
            last = exc
            try:
                CLAUDE_CLIENT._transport._pool.close()   # drop the dead pooled connections
            except Exception:  # noqa: BLE001 — private API; the next request reconnects anyway
                pass
            time.sleep(0.3 * (attempt + 1))
            continue
        refusal = cloud_error(response) if response.is_error and navi_cloud() else None
        if refusal is not None and refusal.fields.get("code") != "rate_limited":
            raise refusal
        if response.status_code in CLAUDE_RETRY_STATUS and attempt < 2:
            time.sleep(0.6 * 2**attempt)
            continue
        if refusal is not None:
            raise refusal
        if response.is_error:
            raise RuntimeError(f"{what} returned HTTP {response.status_code}")
        return response.json()
    raise RuntimeError(f"{what} unreachable ({last or 'busy'})")


def message_text(result):
    return "".join(b.get("text", "") for b in (result or {}).get("content", []) if b.get("type") == "text").strip()


def json_object(text):
    """The JSON object in a model's reply, fenced or not."""
    text = (text or "").strip()
    if not text.startswith("{"):
        a, b = text.find("{"), text.rfind("}")
        if a < 0 or b <= a:
            raise ValueError("no JSON object in the reply")
        text = text[a:b + 1]
    out = json.loads(text)
    if not isinstance(out, dict):
        raise ValueError("the reply is not a JSON object")
    return out


def jpeg_size(data):
    """(width, height) of a JPEG from its SOF marker, else None."""
    i = 2
    while i + 9 < len(data):
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
            return (data[i + 7] << 8 | data[i + 8], data[i + 5] << 8 | data[i + 6])
        if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
            i += 2
            continue
        i += 2 + (data[i + 2] << 8 | data[i + 3])
    return None


SHOT_MAX_WIDTH = 1280


def viewport_shot(browser, max_width=SHOT_MAX_WIDTH, region=None, quality=70):
    """The tab's viewport (or `region` = (x, y, w, h) in CSS px of it) as a JPEG at most
    `max_width` px wide. Returns (base64, css_px_per_image_px). Clip coordinates are
    document-relative, so the scroll offset is added; devicePixelRatio is divided out (the
    runner sets no device-metrics override, so a Retina tab captures at 2×)."""
    import base64
    vw, vh, sx, sy, dpr = browser.evaluate(
        "[innerWidth, innerHeight, visualViewport ? visualViewport.pageLeft : scrollX,"
        " visualViewport ? visualViewport.pageTop : scrollY, devicePixelRatio || 1]")
    x, y, w, h = region or (0, 0, vw, vh)
    w, h = max(1, min(w, vw - x)), max(1, min(h, vh - y))
    scale = max_width / (w * dpr) if w * dpr > max_width else 1.0
    data = browser.call("Page.captureScreenshot", format="jpeg", quality=quality,
                        clip={"x": sx + x, "y": sy + y, "width": w, "height": h, "scale": scale})["data"]
    head = data[:8192]
    size = jpeg_size(base64.b64decode(head[:len(head) - len(head) % 4]))
    width = size[0] if size else round(w * scale * dpr)
    return data, w / max(1, width)


# --- the typed judgment -----------------------------------------------------------

VERDICTS = ("achieved", "partial", "not_achieved", "impossible", "needs_user")

JUDGE_SYSTEM = """You check where a web task stands for Navi, an assistant that works in the user's browser. You get the user's goal, a screenshot of the browser tab now (when available), the page's URL, title and visible text, the actions taken so far, and why you were asked.

Reply ONLY with JSON: {"answer": "...", "next_step": "...", "verdict": "achieved" | "partial" | "not_achieved" | "impossible" | "needs_user", "question": "...", "question_kind": "choice" | "do_it", "question_choices": ["...", ...]}

- achieved: the screen shows every part of the goal done. For information, the information is on this screen and the answer states it. For a purchase or order, the item is in the cart/bag or checkout is reached — Navi never pays; the user places the order. For a sign-in, the account is signed in.
- partial: some parts are done, others not yet.
- not_achieved: not done yet, but doable from here or on this site.
- impossible: it cannot be done on this site at all (say why).
- needs_user: the next step is one only the user can take or decide: their password or a code, an account to pick in a sign-in window, signing in or creating an account when the task cannot go on without it (Navi never signs in or signs up for the user unless the goal asks), a payment, a choice the goal leaves open.
answer: one to three plain sentences for the user, true to the screen. Never claim something was done that the screen does not show, and never talk about what you yourself can or cannot do.
next_step: the single next move toward the goal on this screen, naming the control to use (empty when achieved or impossible). Never include credentials or payment details.
question, question_kind, question_choices — only with needs_user (else "", "", []); Navi pauses the task and puts this to the user:
- "choice" when the user must decide something the goal leaves open: question is one short question ("Which size do you want?"), question_choices 2–4 short answers — the options the page itself offers, as labelled there, the likeliest first.
- "do_it" when only the user can do the next step on screen (their password or a code, a captcha, an account to pick in a sign-in window): question says what to do in one sentence ("Sign in to DoorDash in this tab."), question_choices is [].
Never ask about paying or placing the order: an item in the cart/bag is achieved, and the order is the user's to place.
user_said, when present, holds what the user already answered in this task: follow it, and never ask the same thing again."""

COULD_NOT = re.compile(r"\b(i (could ?n[o']t|can ?n[o']t|cannot|was(n't| not) able|am unable|did ?n[o']t manage)|unable to|"
                       r"(is|was|has|have)(n't| not) (been |yet )?(confirmed|created|added|sent|found|done|completed|opened|saved)|"
                       r"i (do|did) ?n[o']t see|not (yet )?(been )?(done|complete|completed|created|added|sent|saved)|still (needs|has) to)\b", re.I)


def says_could_not(text):
    """The answer itself says the task was not done ("I couldn't open DoorDash", "isn't confirmed")."""
    return bool(COULD_NOT.search(text or ""))


def normalize_verdict(out):
    """A judge reply as {verdict, answer, next_step}: an unknown verdict reads as not_achieved, and
    an "achieved" whose own words say it was not done is not believed."""
    verdict = str(out.get("verdict") or "").strip().lower().replace(" ", "_").replace("-", "_")
    if verdict not in VERDICTS:
        verdict = "not_achieved"
    answer = str(out.get("answer") or "").strip()
    if verdict == "achieved" and says_could_not(answer):
        verdict = "partial"
    result = {"verdict": verdict, "answer": answer[:800], "next_step": str(out.get("next_step") or "").strip()[:300]}
    if verdict == "needs_user":
        # Adaptation 37: what to put to the user. An unnamed kind follows the choices it came with.
        choices = tidy_choices(out.get("question_choices"))
        kind = str(out.get("question_kind") or "").strip().lower().replace(" ", "_").replace("-", "_")
        if kind not in {"choice", "do_it"}:
            kind = "choice" if len(choices) >= 2 else "do_it"
        result.update(question=str(out.get("question") or "").strip()[:200], question_kind=kind,
                      question_choices=choices if kind == "choice" else [])
    return result


MAX_CHOICES = 4


def tidy_choices(raw):
    """Up to four distinct, short, non-empty answers (the same rule as Navi's `AgentQuestion.tidy`)."""
    out, seen = [], set()
    for c in raw if isinstance(raw, list) else []:
        t = str(c or "").strip().strip("•-– ")
        if t and len(t) <= 80 and t.lower() not in seen:
            seen.add(t.lower())
            out.append(t)
        if len(out) == MAX_CHOICES:
            break
    return out


def user_said_from_env():
    """What the user answered earlier in this task (NAVI_USER_SAID_JSON: [{question, reply}]), or []."""
    try:
        raw = json.loads(os.environ.get("NAVI_USER_SAID_JSON") or "[]")
    except ValueError:
        return []
    return [{"question": str(x.get("question") or "")[:200], "reply": str(x.get("reply") or "")[:300]}
            for x in raw if isinstance(x, dict) and x.get("reply")][-3:] if isinstance(raw, list) else []


PAYMENT_STEP = re.compile(r"\b(pay|payment|place (the |your )?order|checkout|check out|card number|billing)\b", re.I)
# Adaptation 39: "Sign in to DoorDash in this tab" is the user's to do and the task goes on after it — a
# question, even on a purchase whose checkout needs it (bench errand-030 ended failed instead).
SIGN_IN_STEP = re.compile(r"\b(sign(ed)? ?in|log(ged)? ?in|sign ?up|create (an |your )?account)\b", re.I)
PAYMENT_ONLY = re.compile(r"\b(pay|payment|place (the |your )?order|card number|billing)\b", re.I)


def user_question(verdict, goal, status):
    """What a stop puts to the user (adaptation 37), or None. Only a needs-user stop asks; Navi's own
    purchase hand-off — the order and its payment are the user's — ends as it always has."""
    if status == "done" or (verdict or {}).get("verdict") != "needs_user":
        return None
    question = (verdict.get("question") or verdict.get("answer") or "").strip()
    if not question:
        return None
    kind = verdict.get("question_kind") or "do_it"
    signing_in = kind == "do_it" and SIGN_IN_STEP.search(question) and not PAYMENT_ONLY.search(question)
    if PURCHASE_GOAL.search(goal or "") and PAYMENT_STEP.search(question + " " + (verdict.get("answer") or "")) and not signing_in:
        return None
    return {"question": question, "question_kind": kind,
            "question_choices": verdict.get("question_choices") or [] if kind == "choice" else []}


def judge(goal, page, history, why, screenshot_b64=None):
    """One typed judgment of the run as it stands (raises when Claude is unreachable)."""
    state = {
        "goal": goal,
        "why_asked": why,
        "page": {"url": page.get("url"), "title": page.get("title"), "text": (page.get("text") or "")[:5000]},
        "actions_taken": [{k: h.get(k) for k in ("action", "kind", "text", "page_changed")}
                          for h in history if h.get("kind") != "check"][-14:],
    }
    said = user_said_from_env()
    if said:
        state["user_said"] = said
    content = []
    if screenshot_b64:
        content.append({"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": screenshot_b64}})
    content.append({"type": "text", "text": json.dumps(state, sort_keys=True, ensure_ascii=False)})
    model = os.environ.get("NAVI_AGENT_MODEL", "claude-sonnet-5")
    result = claude_post({"model": model, "max_tokens": 600, "system": JUDGE_SYSTEM,
                          "messages": [{"role": "user", "content": content}]}, timeout=60, what="Claude's check")
    return normalize_verdict(json_object(message_text(result)))


JUDGE_DONE_BELOW = 0.85
JUDGE_SETTLE_S = 0.6        # a beat for a dialog that just opened before the judge looks


def should_judge_done(confidence):
    """Jev's own DONE stands when it is sure; an unsure one (KFC's 63 %) is checked by the judge."""
    if os.environ.get("NAVI_JUDGE") == "0" or claude_endpoint() is None:
        return False
    return (confidence if confidence is not None else 0.0) < JUDGE_DONE_BELOW


# --- the takeover ------------------------------------------------------------------

TAKEOVER_TURNS = 8          # Claude rounds per takeover (each may hold several actions)
MAX_TAKEOVERS = 3           # per run
TAKEOVER_MAX_S = 150        # wall clock per takeover
KEEP_SCREENSHOTS = 3

TAKEOVER_SYSTEM = """You are finishing a task in one Chrome tab for the user of Navi, a Mac assistant. A fast driver that reads the page's element list got stuck, so you take over; once you have moved the task forward it may take back over.

You see the tab through screenshots: only the web page, no address bar, tabs or other windows. Act with the computer tool (coordinates are in the latest screenshot's pixels); `go_to_url` opens an https address in this tab and `go_back` goes back. Take a screenshot again after any action that changes the page.

Rules:
- Navi never pays: never click Place order, Pay, Buy now, Confirm purchase or the like, and never go to checkout. A purchase or order is finished when the item is in the cart/bag; then stop with Done — checkout and paying are the user's.
- Never sign in, sign up or create an account for the user (unless the goal itself is to sign in or sign up): never press "Continue with Google/Apple/Facebook", "Sign in", "Log in" or "Sign up", and never type the user's email or name into such a form. When the task cannot go on without the user's account, stop with "Stopped: Sign in to <site> in this tab." — the user signs in, then you carry on.
- Never type passwords, one-time codes, card or bank numbers. When the next step needs the user's password, a code, an account choice in a sign-in window, a payment, or a choice the goal leaves open, stop.
- Never tick "Compare with <another site>" or similar boxes that open other sites' results; stay on this site.
- Do not send, post, delete or submit anything the goal does not ask for.
- Dismiss pop-ups, cookie banners and app-download prompts that are in the way, unless they are the goal.
- Be quick: a few actions per turn.

When you stop, reply with one line and no tool call, and always begin it with Done:, Stopped: or Did: — also when you find the goal already done without acting:
"Done: <what the screen now shows>" when every part of the goal is done on screen;
"Stopped: <what the user needs to do>" when only the user can continue;
"Did: <what you did>" when you made progress but are not finished."""

TAKEOVER_TOOLS = [
    {"type": "computer_toolset_20260801"},
    {"name": "go_to_url", "description": "Open an https URL in this tab.",
     "input_schema": {"type": "object", "properties": {"url": {"type": "string"}}, "required": ["url"]}},
    {"name": "go_back", "description": "Go back one page in this tab.", "input_schema": {"type": "object", "properties": {}}},
]
CUSTOM_TOOLS = {"go_to_url", "go_back"}
READ_ONLY_TOOLS = {"screenshot", "zoom", "cursor_position", "mouse_move", "wait"}

KEYS = {
    "return": ("Enter", "Enter", 13, "\r"), "enter": ("Enter", "Enter", 13, "\r"), "kp_enter": ("Enter", "NumpadEnter", 13, "\r"),
    "tab": ("Tab", "Tab", 9, None), "escape": ("Escape", "Escape", 27, None), "esc": ("Escape", "Escape", 27, None),
    "backspace": ("Backspace", "Backspace", 8, None), "delete": ("Delete", "Delete", 46, None),
    "space": (" ", "Space", 32, " "), "up": ("ArrowUp", "ArrowUp", 38, None), "down": ("ArrowDown", "ArrowDown", 40, None),
    "left": ("ArrowLeft", "ArrowLeft", 37, None), "right": ("ArrowRight", "ArrowRight", 39, None),
    "home": ("Home", "Home", 36, None), "end": ("End", "End", 35, None),
    "page_up": ("PageUp", "PageUp", 33, None), "pageup": ("PageUp", "PageUp", 33, None),
    "page_down": ("PageDown", "PageDown", 34, None), "pagedown": ("PageDown", "PageDown", 34, None),
}
MODIFIERS = {"alt": 1, "option": 1, "ctrl": 2, "control": 2, "cmd": 4, "command": 4, "meta": 4, "super": 4, "shift": 8}
EDIT_COMMANDS = {"a": "selectAll", "c": "copy", "v": "paste", "x": "cut", "z": "undo"}


def parse_key(text):
    """xdotool-style "ctrl+a" / "Return" / "shift+Tab" → (key, code, keyCode, text, modifiers, commands)."""
    parts = [p for p in re.split(r"\s*\+\s*", (text or "").strip()) if p]
    if not parts:
        raise ValueError("empty key")
    mods = 0
    for p in parts[:-1]:
        if p.lower() not in MODIFIERS:
            raise ValueError(f"unknown modifier {p}")
        mods |= MODIFIERS[p.lower()]
    name = parts[-1]
    low = name.lower()
    if low in KEYS:
        key, code, kc, txt = KEYS[low]
    elif len(name) == 1:
        key, kc = name, ord(name.upper())
        code = ("Key" + name.upper()) if name.isalpha() else ("Digit" + name) if name.isdigit() else ""
        txt = name if not mods & (2 | 4) else None
    elif re.fullmatch(r"f([1-9]|1[0-2])", low):
        key = code = name.upper()
        kc, txt = 111 + int(low[1:]), None
    else:
        raise ValueError(f"unknown key {name}")
    primary = 4 if sys.platform == "darwin" else 2
    commands = [EDIT_COMMANDS[low]] if mods & primary and low in EDIT_COMMANDS else []
    return key, code, kc, txt, mods, commands


AT_POINT_JS = """((x,y) => {
  const e=document.elementFromPoint(x,y); if (!e) return null;
  const c=e.closest('button,a,[role=button],[role=link],[role=menuitem],[role=option],input,select,textarea,label,summary,[onclick]')||e;
  const t=s=>String(s||'').replace(/\\s+/g,' ').trim();
  const kind=(c.control&&c.control.type)||(c.tagName==='INPUT'&&c.type)||c.getAttribute('role')||'';
  return {label:t(c.getAttribute('aria-label')||c.innerText||c.value||c.title||c.getAttribute('alt')).slice(0,160),
          tag:c.tagName, kind:String(kind).toLowerCase(), frame:e.tagName==='IFRAME'};
})"""

SECRET_FIELD_JS = """(() => { const e=document.activeElement; if (!e) return false;
  const a=String(e.autocomplete||'')+' '+String(e.name||'')+' '+String(e.id||'');
  return e.type==='password' || /cc-|card|cvv|cvc|one-time-code|otp|password/i.test(a); })()"""

# Adaptation 39: the focused field is an identity field (email, name, phone) of a sign-in / sign-up form.
ACCOUNT_FIELD_JS = """(() => { const e=document.activeElement; if (!e || !/^(INPUT|TEXTAREA)$/.test(e.tagName)) return false;
  const lab=(e.labels&&e.labels[0]&&e.labels[0].innerText)||'';
  const a=[e.type,e.autocomplete,e.name,e.id,e.placeholder,e.getAttribute('aria-label'),lab].map(x=>String(x||'')).join(' ');
  if (!/e-?mail|user ?name|given-name|family-name|first ?name|last ?name|full ?name|\\bname\\b|\\btel\\b|phone|mobile/i.test(a)) return false;
  const scope=e.closest('form,[role=dialog],dialog,[aria-modal=true]')||document.body;
  return !!scope.querySelector('input[type=password]') ||
    /continue with (google|apple|facebook|microsoft|email)|sign ?up|create (an |your )?account/i.test((scope.innerText||'').slice(0,4000)); })()"""


def pays_refusal(label):
    """The refusal for a click on a control that spends the user's money (adaptation 27), else None."""
    if label and PAYS.search(label):
        return (f"Refused: ‘{label[:60]}’ would spend the user's money — Navi never pays. "
                "If the item is in the cart or checkout is open, reply Done: … ; the user places the order.")
    return None


CHECKOUT = re.compile(r"\b(check ?out|proceed to (checkout|payment)|go to (checkout|payment)|continue to (checkout|payment))\b", re.I)
CHECKOUT_URL = re.compile(r"^https?://(checkout\.|pay\.|secure\.)|/(checkout|payment|pay)(/|\?|#|$)", re.I)
AUTH_URL = re.compile(r"^https?://(accounts?|identity|auth|login|signin|sso)\.|/(log-?in|sign-?in|sign-?up|signup|register|auth|oauth2?|sso)(/|\?|#|$)",
                      re.I)


def takeover_refusal(goal, hit):
    """Why the takeover may not click this control (adaptations 27 and 39), else None: it spends money,
    enters checkout, signs the user in or up, or ticks a partner site's compare box."""
    label = (hit or {}).get("label") or ""
    refusal = pays_refusal(label)
    if refusal or not label:
        return refusal
    first = label.split("\n")[0][:60]
    if CHECKOUT.search(label):
        return (f"Refused: ‘{first}’ goes to checkout — Navi never checks out or pays. If the item is in the cart/bag, "
                "reply Done: … ; the user checks out.")
    if is_auth_control(label) and not is_account_goal(goal):
        return (f"Refused: ‘{first}’ would sign the user in or create an account — that is the user's to do. "
                "If the task cannot go on without it, reply Stopped: Sign in to … in this tab.")
    if is_partner_detour(label, (hit or {}).get("kind")) and not re.search(r"\bcompar", goal or "", re.I):
        return f"Refused: ‘{first}’ opens another site's results — stay on this site."
    return None


def entered(rx, before, after):
    """Did the tab move into a URL `rx` matches (checkout, a sign-in page) that it was not on before?"""
    return bool(after) and bool(rx.search(after)) and not rx.search(before or "")


def describe_call(block):
    """A tool_use block in words, for the gate and the log."""
    name, inp = block.get("name"), block.get("input") or {}
    if name in {"left_click", "double_click", "triple_click", "right_click", "middle_click"}:
        return f"{name.replace('_', ' ')} at {inp.get('coordinate')}"
    if name == "type":
        return f"type “{str(inp.get('text', ''))[:40]}”"
    if name == "key":
        return f"press {inp.get('text')}"
    if name == "scroll":
        return f"scroll {inp.get('scroll_direction', 'down')}"
    if name == "go_to_url":
        return f"open {inp.get('url')}"
    return name or "?"


GATE_QUESTIONS = {
    "is_irreversible": {"type": "noul", "instructions": "Executing these actions would send a message/email/post, make a purchase or payment, delete or overwrite data, or otherwise be hard to undo"},
    "is_prohibited": {"type": "noul", "instructions": "These actions enter a password, 2FA code, payment card or bank details, execute a financial transaction, or change security settings"},
}

RAW_JEV_POST = [None]       # the transport-only Jev call (set by install_adaptations), for the gate


def gate_verdict(goal, claude_says, proposed, recent):
    """Jev's irreversible / prohibited nouls for a takeover turn (JevGate's questions and state).
    Jev unreachable → (0, 0): the pays and secret-field guards still hold."""
    post = RAW_JEV_POST[0] or jev_model.post_json
    state = (f"[TASK] {goal}\n[CLAUDE_SAYS] {claude_says or '(none)'}\n[PROPOSED_ACTIONS]\n"
             + "".join(f"{i + 1}. {p}\n" for i, p in enumerate(proposed))
             + "[RECENT_ACTIONS]\n" + ("".join(f"- {r}\n" for r in recent[-6:]) or "(none)\n") + "[SCREEN] browser tab")
    try:
        r = post("https://api.typesafe.ai/v1/systemone", os.environ.get("TYPESAFE_API_KEY", ""),
                 {"state": state, "model": os.environ.get("TYPESAFE_MODEL", "jev-latest"), "questions": GATE_QUESTIONS})
        a = r.get("answers") or {}
        return float((a.get("is_irreversible") or {}).get("noul", 0)), float((a.get("is_prohibited") or {}).get("noul", 0))
    except CloudError:
        raise
    except Exception:  # noqa: BLE001 — the gate never breaks the loop
        return 0.0, 0.0


GOAL_SENDS = re.compile(r"\b(send|text|message|email|e-mail|post|reply|tweet|submit|delete|remove|publish|share|comment|rsvp)\b", re.I)


def gate_stops(goal, irreversible, prohibited, mode=None):
    """Why a takeover turn must not run, or None. Prohibited never runs; an irreversible turn runs in
    autonomous mode, or in ask-for-risky mode when the goal itself asks to send/post/delete. There is no
    approval channel back to Navi mid-run, so a turn that would need one ends the run as needs_user."""
    mode = mode or os.environ.get("NAVI_APPROVAL_MODE", "askForRisky")
    if prohibited > 0.5:
        return "would enter credentials or payment details or move money"
    if irreversible > 0.5 and mode != "autonomous" and (mode == "alwaysAsk" or not GOAL_SENDS.search(goal or "")):
        return "would send, post, buy or delete something the task did not ask for"
    return None


def prune_images(messages, keep=KEEP_SCREENSHOTS):
    """Older screenshots become a placeholder, newest `keep` kept (request bodies stay small)."""
    seen = 0
    for m in reversed(messages):
        blocks = m.get("content") if isinstance(m.get("content"), list) else []
        for block in reversed(blocks):
            parts = block.get("content") if block.get("type") == "tool_result" and isinstance(block.get("content"), list) else [block]
            for part in parts:
                if part.get("type") == "image":
                    seen += 1
                    if seen > keep:
                        part.clear()
                        part.update({"type": "text", "text": "(older screenshot removed)"})


class Takeover:
    """Claude computer use on the runner's tab: a bounded number of rounds, Jev's irreversible gate
    before every turn that changes something, Navi's never-pay and no-secrets guards before every
    click and keystroke. The first takeover on a document hands back to Jev as soon as the page has
    moved to a new document; a second one on the same document runs until Done / Stopped / budget."""

    def __init__(self):
        self.count = 0
        self.last_url = None
        self.ratio = 1.0
        self.cursor = (0.0, 0.0)
        self.goal = ""

    def available(self):
        return os.environ.get("NAVI_TAKEOVER", "1") != "0" and claude_endpoint() is not None and self.count < MAX_TAKEOVERS

    def run(self, agent, goal, why, verdict, on_step):
        """Returns {"result": done|stopped|handback|no_progress, "summary": str, "actions": n}."""
        browser = agent.state["browser"]
        page = agent.state["page"]
        start_url, start_fp = page.get("url"), page.get("fingerprint")
        hand_back = not (self.last_url is not None and Coach.same_document(self.last_url, start_url))
        self.count += 1
        self.last_url = start_url
        self.goal = goal
        model = os.environ.get("NAVI_TAKEOVER_MODEL") or os.environ.get("NAVI_AGENT_MODEL", "claude-sonnet-5")
        deadline = time.monotonic() + TAKEOVER_MAX_S
        shot, self.ratio = retry_transient(lambda: viewport_shot(browser))
        recent = [h.get("action", "") for h in agent.state["history"][-8:]]
        intro = {
            "goal": goal,
            "why_the_fast_driver_stopped": why,
            "where_it_stands": (verdict or {}).get("answer") or None,
            "suggested_next_step": (verdict or {}).get("next_step") or None,
            "page": {"url": start_url, "title": page.get("title")},
            "recent_actions": recent,
        }
        said = user_said_from_env()
        if said:
            intro["user_said"] = said
        messages = [{"role": "user", "content": [
            {"type": "text", "text": json.dumps(intro, ensure_ascii=False)},
            {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": shot}},
        ]}]
        actions = 0
        summary = ""
        wrap_up_sent = False
        for _ in range(TAKEOVER_TURNS + 1):
            result = claude_post({"model": model, "max_tokens": 2048, "system": TAKEOVER_SYSTEM,
                                  "tools": TAKEOVER_TOOLS, "messages": messages}, timeout=90, what="Claude")
            content = result.get("content") or []
            messages.append({"role": "assistant", "content": content})
            text = message_text(result)
            calls = [b for b in content if b.get("type") == "tool_use"]
            if result.get("stop_reason") == "refusal":
                return {"result": "stopped", "summary": text or "Claude declined to continue.", "actions": actions}
            if not calls or wrap_up_sent:
                summary = text.splitlines()[0].strip() if text else ""
                return {"result": takeover_result(summary, actions), "summary": summary, "actions": actions}
            if text:
                emit("status", message=f"Claude: {text.splitlines()[0][:160]}")
            mutating = [c for c in calls if c.get("name") not in READ_ONLY_TOOLS]
            if mutating:
                irr, pro = gate_verdict(goal, text, [describe_call(c) for c in mutating], recent)
                blocked = gate_stops(goal, irr, pro)
                if blocked:
                    what = "; ".join(describe_call(c) for c in mutating)
                    emit("status", message=f"Stopped Claude before ‘{what[:80]}’: it {blocked}")
                    return {"result": "stopped", "actions": actions,
                            "summary": f"Stopped: the next step ({what[:80]}) {blocked} — that one is yours to do or confirm."}
            results = []
            for c in calls:
                out, did = self.execute(browser, c)
                results.append(out)
                if did:
                    actions += 1
                    recent.append("Claude: " + did)
                    on_step({"action": "Claude: " + did, "kind": "takeover", "text": None, "url": start_url})
            if actions:
                detour = self.detour(browser, start_url)
                if detour:
                    return {**detour, "actions": actions}
            rounds_left = TAKEOVER_TURNS - sum(1 for m in messages if m["role"] == "assistant")
            if rounds_left <= 0 or time.monotonic() > deadline:
                results.append({"type": "text", "text": "You have used this takeover's budget. Do not call any tool. "
                                "Reply with one line: Done: …, Stopped: … or Did: …"})
                wrap_up_sent = True
            messages.append({"role": "user", "content": results})
            prune_images(messages)
            if hand_back and actions and not wrap_up_sent:
                try:
                    now = browser.observe(screenshot=False)
                except Exception:  # noqa: BLE001 — mid-navigation; look again next round
                    now = None
                if now is not None and not Coach.same_document(start_url, now.get("url")) and now.get("fingerprint") != start_fp:
                    return {"result": "handback", "actions": actions,
                            "summary": f"Did: moved on to {now.get('title') or now.get('url')}"}
        return {"result": takeover_result(summary, actions), "summary": summary, "actions": actions}

    def detour(self, browser, start_url):
        """Adaptation 39: an action that took the tab into checkout (a generic "Continue" in a cart) is
        undone — the cart is the end of a purchase — and one that reached a sign-in page stops for the user."""
        try:
            now = browser.evaluate("location.href")
        except Exception:  # noqa: BLE001 — mid-navigation; the next round looks again
            return None
        if entered(CHECKOUT_URL, start_url, now):
            emit("status", message="Claude reached checkout — going back: checkout and paying are the user's")
            try:
                browser.evaluate("history.back()")
                time.sleep(0.8)
            except Exception:  # noqa: BLE001 — the judge reads whatever page this is
                pass
            return {"result": "done", "summary": "Done: the item is in the cart — checkout and paying are the user's."}
        if entered(AUTH_URL, start_url, now) and not is_account_goal(self.goal):
            return {"result": "stopped", "summary": "Stopped: Sign in in this tab — signing in is yours to do."}
        return None

    def point(self, coordinate):
        if not isinstance(coordinate, (list, tuple)) or len(coordinate) < 2:
            raise ValueError("coordinate [x, y] is required")
        return float(coordinate[0]) * self.ratio, float(coordinate[1]) * self.ratio

    @staticmethod
    def result(block, text=None, image=None, error=False):
        """A tool_result: computer members echo toolset_name, the custom tools must not."""
        out = {"type": "tool_result", "tool_use_id": block.get("id")}
        if block.get("name") not in CUSTOM_TOOLS:
            out["toolset_name"] = "computer"
        if image:
            out["content"] = [{"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": image}}]
        else:
            out["content"] = [{"type": "text", "text": text or "OK"}]
        if error:
            out["is_error"] = True
        return out

    def execute(self, browser, block):
        """Runs one tool call on the tab. Returns (tool_result, what-it-did or None)."""
        name, inp = block.get("name"), block.get("input") or {}

        def mouse(kind, x, y, **kw):
            browser.call("Input.dispatchMouseEvent", type=kind, x=x, y=y, **kw)

        try:
            if name == "screenshot":
                time.sleep(0.25)
                shot, self.ratio = viewport_shot(browser)
                return self.result(block, image=shot), None
            if name == "zoom":
                r = inp.get("region") or []
                if len(r) != 4 or r[2] <= r[0] or r[3] <= r[1]:
                    raise ValueError("zoom needs region [x0, y0, x1, y1]")
                (x0, y0), (x1, y1) = self.point(r[:2]), self.point(r[2:])
                shot, _ = viewport_shot(browser, region=(x0, y0, x1 - x0, y1 - y0))
                return self.result(block, image=shot), None
            if name == "cursor_position":
                return self.result(block, text=f"X={round(self.cursor[0] / self.ratio)}, Y={round(self.cursor[1] / self.ratio)}"), None
            if name == "wait":
                time.sleep(max(0.0, min(float(inp.get("duration", 1)), 5.0)))
                return self.result(block), None
            if name == "go_back":
                browser.evaluate("history.back()")
                time.sleep(0.8)
                return self.result(block), "go back"
            if name == "go_to_url":
                url = str(inp.get("url", "")).strip()
                if not re.match(r"^https?://", url):
                    raise ValueError("go_to_url needs an http(s) URL")
                browser.call("Page.navigate", url=url)
                time.sleep(1.0)
                return self.result(block), f"open {url[:80]}"
            if name == "mouse_move":
                x, y = self.point(inp.get("coordinate"))
                mouse("mouseMoved", x, y)
                self.cursor = (x, y)
                return self.result(block), None
            if name in {"left_click", "right_click", "middle_click", "double_click", "triple_click"}:
                x, y = self.point(inp.get("coordinate")) if inp.get("coordinate") else self.cursor
                hit = browser.evaluate(f"{AT_POINT_JS}({x},{y})") or {}
                refusal = takeover_refusal(self.goal, hit)
                if refusal:
                    why = "Navi never pays" if PAYS.search(hit.get("label") or "") else "not Navi's to press"
                    emit("status", message=f"Claude went for ‘{hit.get('label', '')[:50]}’ — {why}")
                    return self.result(block, text=refusal, error=True), None
                button = {"right_click": "right", "middle_click": "middle"}.get(name, "left")
                count = {"double_click": 2, "triple_click": 3}.get(name, 1)
                mouse("mouseMoved", x, y)
                for n in range(1, count + 1):
                    mouse("mousePressed", x, y, button=button, clickCount=n)
                    mouse("mouseReleased", x, y, button=button, clickCount=n)
                self.cursor = (x, y)
                time.sleep(0.35)
                label = (hit.get("label") or "").split("\n")[0][:60]
                verb = {"left_click": "click", "double_click": "double-click", "triple_click": "triple-click"}.get(name, name.replace("_", " "))
                return self.result(block), (f"{verb} ‘{label}’" if label else f"{verb} at {inp.get('coordinate')}")
            if name == "left_click_drag":
                (ax, ay), (bx, by) = self.point(inp.get("start_coordinate")), self.point(inp.get("coordinate"))
                mouse("mousePressed", ax, ay, button="left", clickCount=1)
                mouse("mouseMoved", bx, by, button="left")
                mouse("mouseReleased", bx, by, button="left", clickCount=1)
                self.cursor = (bx, by)
                return self.result(block), "drag"
            if name == "scroll":
                x, y = self.point(inp.get("coordinate")) if inp.get("coordinate") else self.cursor
                amount = max(1, min(int(inp.get("scroll_amount", 3)), 15)) * 100
                d = inp.get("scroll_direction", "down")
                dx, dy = {"up": (0, -amount), "down": (0, amount), "left": (-amount, 0), "right": (amount, 0)}.get(d, (0, amount))
                mouse("mouseWheel", x or 400, y or 400, deltaX=dx, deltaY=dy)
                time.sleep(0.3)
                return self.result(block), f"scroll {d}"
            if name == "type":
                text = str(inp.get("text", ""))
                if browser.evaluate(SECRET_FIELD_JS):
                    return self.result(block, text="Refused: the focused field takes a password, code or card number — "
                                       "Navi never types those. Reply Stopped: … so the user can.", error=True), None
                if not is_account_goal(self.goal) and browser.evaluate(ACCOUNT_FIELD_JS):
                    # Adaptation 39: the user's email or name never goes into a sign-in / sign-up form unasked.
                    return self.result(block, text="Refused: the focused field belongs to a sign-in / sign-up form — "
                                       "Navi never signs the user in or up. Close the form, or reply Stopped: Sign in to … "
                                       "in this tab.", error=True), None
                browser.call("Input.insertText", text=text)
                time.sleep(0.2)
                return self.result(block), f"type “{text[:40]}”"
            if name == "key":
                key, code, kc, txt, mods, commands = parse_key(inp.get("text"))
                for _ in range(max(1, min(int(inp.get("repeat", 1)), 20))):
                    down = {"type": "keyDown" if txt else "rawKeyDown", "key": key, "code": code,
                            "windowsVirtualKeyCode": kc, "modifiers": mods}
                    if txt:
                        down["text"] = txt
                    if commands:
                        down["commands"] = commands
                    browser.call("Input.dispatchKeyEvent", **down)
                    browser.call("Input.dispatchKeyEvent", type="keyUp", key=key, code=code, windowsVirtualKeyCode=kc, modifiers=mods)
                time.sleep(0.3)
                return self.result(block), f"press {inp.get('text')}"
            return self.result(block, text=f"Unsupported action: {name}", error=True), None
        except StalePage:
            return self.result(block, text="The page changed while acting; take a screenshot.", error=True), None
        except (ValueError, RuntimeError, KeyError, TypeError) as exc:
            return self.result(block, text=f"Error: {exc}", error=True), None


def takeover_result(summary, actions):
    """What a takeover's last word means: Done / Stopped are Claude's own verdicts (Done is still
    checked by the judge); anything else hands back when it acted, else it made no progress."""
    s = (summary or "").lstrip()
    if s.startswith("Done"):
        return "done"
    if s.startswith("Stopped"):
        return "stopped"
    return "handback" if actions else "no_progress"


# --- escalation: what a stuck or unsure stop leads to -------------------------------

def escalation(verdict, takeover_available, acted_since_last_takeover=True):
    """The next move after a typed judgment of a stop (pure; unit-tested):
    "done" — the goal is met; "end" — it cannot or must not go on (impossible / needs_user, or
    nothing more to try); "takeover" — not there yet and Claude may drive; "coach" — no takeover
    left, fall back to Claude's guidance for Jev (or the old stop)."""
    v = (verdict or {}).get("verdict")
    if v == "achieved":
        return "done"
    if v in {"impossible", "needs_user"}:
        return "end"
    if takeover_available and acted_since_last_takeover:
        return "takeover"
    return "coach" if verdict is None else "end"


def outcome_status(verdict):
    """The done event's status for a verdict: only "achieved" is done."""
    return "done" if (verdict or {}).get("verdict") == "achieved" else "blocked"


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

    @staticmethod
    def user_context_from_env():
        """The people, projects and documents the goal names, as the user's screen
        memory knows them (NAVI_USER_CONTEXT_JSON from Navi's `UserKnowledge`)."""
        raw = os.environ.get("NAVI_USER_CONTEXT_JSON")
        if not raw:
            return None
        try:
            ctx = json.loads(raw)
        except ValueError:
            return None
        return ctx if isinstance(ctx, dict) and (ctx.get("things") or ctx.get("how_this_user_works")) else None

    def install(self):
        """Adds the page's playbook (and the user's context) to every Jev request."""
        inner = jev_model.post_json

        user_context = self.user_context_from_env()

        facts = date_facts(self.goal)
        said = user_said_from_env()

        def post_json(url, key, body):
            if isinstance(body, dict) and "questions" in body and isinstance(body.get("state"), dict):
                body = dict(body)
                body["state"] = {**body["state"], "facts": facts}
                if said:
                    # Adaptation 37: the user's answers to this task's questions ("Which size?" → "Large").
                    body["state"]["user_said"] = said
            if isinstance(body, dict) and "questions" in body and isinstance(body.get("state"), dict) and user_context:
                body = dict(body)
                body["state"] = {**body["state"], "user_context": user_context}
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


# --- Adaptation 21: the user's own clicks mark the page's elements ----------

USER_MOVES_RULE = ("Elements marked `this_user` are the ones this user clicks on this site themselves (how often, or "
                   "that they usually click it next): where the goal could mean several elements, choose theirs.")


class UserMoves:
    """What this user clicks on each site, from Navi's screen memory
    (NAVI_USER_MOVES_JSON: {"sites": {site: {"clicks": [{label, role, count}],
    "next": {label: {label: count}}}}}). Mirrors Navi's `UserMoves.hints`."""

    MAX_MARKED = 8
    MIN_COUNT = 2
    SEPARATORS = (",", " \u00b7", " -", " \u2014", ":", " |", " (")
    SHARED_HOSTS = {"docs.google.com", "google.com"}

    def __init__(self, sites=None):
        self.sites = sites if sites is not None else self.from_env()
        self.last = {}   # site -> normalised label of the element clicked last

    @staticmethod
    def from_env():
        raw = os.environ.get("NAVI_USER_MOVES_JSON")
        if not raw:
            return {}
        try:
            data = json.loads(raw)
        except ValueError:
            return {}
        sites = data.get("sites") if isinstance(data, dict) else None
        return sites if isinstance(sites, dict) else {}

    @classmethod
    def site_key(cls, url):
        """Navi's `UserHabits.siteKey`: the host without www., plus the first path
        segment on hosts that hold several apps (docs.google.com/document)."""
        try:
            from urllib.parse import urlparse
            u = urlparse(url or "")
        except ValueError:
            return None
        if u.scheme not in ("http", "https") or not u.hostname:
            return None
        host = u.hostname.lower()
        if host.startswith("www."):
            host = host[4:]
        if host in cls.SHARED_HOSTS:
            seg = [p for p in u.path.split("/") if p]
            if seg:
                return host + "/" + seg[0].lower()
        return host

    @staticmethod
    def norm(s):
        t = " ".join(str(s or "").lower().split())
        while t and t[-1] in "\u2026:.":
            t = t[:-1]
        import re
        m = re.search(r"\s*\(\d{1,5}\)$", t)
        if m and m.start() > 0:
            t = t[:m.start()]
        return t.strip()[:80]

    @classmethod
    def head(cls, s):
        cut = len(s)
        for sep in cls.SEPARATORS:
            i = s.find(sep)
            if i != -1 and i < cut:
                cut = i
        return s[:cut]

    @classmethod
    def same_control(cls, a, b):
        if a == b:
            return True
        short, long_ = (a, b) if len(a) <= len(b) else (b, a)
        if len(short) < 6 or not long_.startswith(short):
            return False
        return long_[len(short):].startswith(cls.SEPARATORS)

    @classmethod
    def matches(cls, control, text):
        label = cls.norm(control.get("label", ""))
        if cls.same_control(label, text):
            return True
        if control.get("role") != "row":
            return False
        h = cls.head(label)
        return len(h) >= 4 and h == cls.head(text)

    def marks(self, site, elements):
        """{element index: {"clicks": n} and/or {"next": True}} for this page."""
        info = self.sites.get(site) or {}
        controls = [c for c in info.get("clicks", []) if isinstance(c, dict) and c.get("count", 0) >= self.MIN_COUNT]
        if not controls:
            return {}
        by_label = {self.norm(c.get("label", "")): c for c in controls}
        counted = []
        for e in elements:
            n = self.norm(e.get("label", ""))
            if not n:
                continue
            c = by_label.get(n) or next((c for c in controls if self.matches(c, n)), None)
            if c:
                counted.append((e["index"], c["count"]))
        counted.sort(key=lambda x: (-x[1], int(x[0]) if str(x[0]).isdigit() else 0))
        out = {i: {"clicks": n} for i, n in counted[:self.MAX_MARKED]}
        last = self.last.get(site)
        nexts = info.get("next") or {}
        after = nexts.get(last) if last else None
        if last and after is None:   # the row clicked last, shown with a newer preview
            after = next((v for k, v in nexts.items()
                          if self.matches(by_label.get(k) or {"label": k, "role": ""}, last)), None)
        if after:
            wanted = [k for k, v in sorted(after.items(), key=lambda kv: -kv[1]) if v >= self.MIN_COUNT][:2]
            wanted_controls = [by_label.get(k) or {"label": k, "role": ""} for k in wanted]
            for e in elements:
                n = self.norm(e.get("label", ""))
                if n and any(self.matches(c, n) for c in wanted_controls):
                    out.setdefault(e["index"], {})["next"] = True
        return out

    @staticmethod
    def describe(mark):
        parts = []
        if mark.get("clicks"):
            parts.append(f"clicks this here ({mark['clicks']}\u00d7)")
        if mark.get("next"):
            parts.append("usually clicks this next")
        return "this user " + " and ".join(parts)

    def annotate(self, body):
        """The request with this user's marks on its elements and target criteria."""
        state = body.get("state") if isinstance(body, dict) else None
        if not isinstance(state, dict) or "questions" not in body or not self.sites:
            return body
        site = self.site_key((state.get("page") or {}).get("url"))
        elements = state.get("elements")
        if not site or not isinstance(elements, list):
            return body
        marks = self.marks(site, elements)
        if not marks:
            return body
        body = dict(body)
        body["state"] = {**state, "elements": [
            {**e, "this_user": self.describe(marks[e["index"]])} if e.get("index") in marks else e for e in elements]}
        qs = {}
        for name, q in body["questions"].items():
            if name.endswith("_target") and isinstance(q.get("criteria"), dict):
                q = dict(q)
                q["criteria"] = {k: ({**v, "this_user": self.describe(marks[k.split(":")[0]])}
                                     if isinstance(v, dict) and k.split(":")[0] in marks else v)
                                 for k, v in q["criteria"].items()}
                if isinstance(q.get("instructions"), dict):
                    rules = q["instructions"].get("rules")
                    rules = list(rules) if isinstance(rules, list) else ([rules] if rules else [])
                    q["instructions"] = {**q["instructions"], "rules": rules + [USER_MOVES_RULE]}
            qs[name] = q
        body["questions"] = qs
        return body

    def observe(self, body, result):
        """Remembers the element a CLICK chose, for "usually clicks this next"."""
        try:
            answers = result.get("answers") or {}
            if (answers.get("operation") or {}).get("choice") != "CLICK":
                return
            index = (answers.get("click_target") or {}).get("choice")
            state = body["state"]
            site = self.site_key((state.get("page") or {}).get("url"))
            label = next((e.get("label") for e in state.get("elements", []) if e.get("index") == index), None)
            if site and label:
                self.last[site] = self.norm(label)
        except (AttributeError, KeyError, TypeError):
            pass

    def install(self):
        if not self.sites:
            return
        inner = jev_model.post_json

        def post_json(url, key, body):
            body = self.annotate(body)
            result = inner(url, key, body)
            if isinstance(body, dict) and isinstance(result, dict):
                self.observe(body, result)
            return result

        jev_model.post_json = post_json


# --- Adaptation 22: the user's own way of doing this task -------------------

USER_ROUTE_RULE = ("The element marked `this_user` as this user's own next step for this task is the control this user uses "
                   "next when they do this very task themselves: choose it unless the goal clearly needs another.")
USER_ROUTE_NOTE = ("How this user does this kind of task themselves, step by step, from their own clicks: \u2713 done in this run, "
                   "\u2192 their next step. A \u2026 is the part that changes (here: the task's person or item). Where it fits the "
                   "goal, do it their way. Never type this text.")


def path_intent(label):
    """Mirror of Navi's `PathIntent.of(label:)`: the kind of control a label names (UserPaths hook)."""
    import re
    w = set(re.findall(r"[^\W_]+", str(label or "").lower()))
    if len(w) > 8:
        return None
    signs = bool(w & {"sign", "signin", "log", "login", "continue"})
    if "google" in w and signs:
        return "signInWithGoogle"
    if "checkout" in w or {"check", "out"} <= w:
        return "checkout"
    cart = bool(w & {"cart", "bag", "basket"})
    if cart and "add" in w:
        return "addToCart"
    if cart:
        return "openCart"
    if {"sign", "in"} <= w or "signin" in w or {"log", "in"} <= w or "login" in w:
        return "signIn"
    if "blank" in w or ("new" in w and w & {"document", "doc", "spreadsheet", "presentation"}):
        return "newDocument"
    if "compose" in w or ("new" in w and w & {"message", "email", "mail", "chat"}):
        return "compose"
    if {"new", "note"} <= w:
        return "newNote"
    if ("new" in w or "create" in w) and "event" in w:
        return "newEvent"
    if "search" in w and len(w) <= 4:
        return "search"
    return None


class UserRoute:
    """The user's routine for this task (NAVI_USER_ROUTE_JSON: {"template", "times", "fills",
    "steps": [{kind, role, label, fixed, slot, site, shortcut, human}]}). Mirrors Navi's
    `UserRoute`: the first pending step (looking two past it) that one element on the page
    shows is marked; `observe` moves the route on when Jev clicks or fills a step's element."""

    LOOKAHEAD = 2
    MAX_FIXED_WORDS = 4
    MARK = "this user's own next step for this task"

    def __init__(self, route=None):
        self.route = route if route is not None else self.from_env()
        self.done = set()

    @staticmethod
    def from_env():
        raw = os.environ.get("NAVI_USER_ROUTE_JSON")
        if not raw:
            return None
        try:
            data = json.loads(raw)
        except ValueError:
            return None
        if not isinstance(data, dict) or not isinstance(data.get("steps"), list) or not data["steps"]:
            return None
        return data

    @property
    def steps(self):
        return [s for s in (self.route or {}).get("steps", []) if isinstance(s, dict)]

    def pending(self):
        return [i for i in range(len(self.steps)) if i not in self.done]

    @staticmethod
    def tokens(s):
        import re
        return re.findall(r"[^\W_]+", str(s or "").lower())

    def wanted(self, step):
        if not step.get("slot"):
            return []
        fills = [f for f in (self.route or {}).get("fills", []) if isinstance(f, str)]
        return fills or self.tokens(step["slot"])

    def label_matches(self, step, label):
        # UserPaths hook: a pattern step (a kind of control the user uses on other sites) matches what a
        # control does, on any page; a path's item needs every one of its words (numbers without leading zeros).
        source = (self.route or {}).get("source")
        if source == "pattern" and step.get("intent"):
            return path_intent(label) == step["intent"]
        if source == "path" and step.get("slot") is not None:
            want = [t.lstrip("0") or t for t in self.tokens(step["slot"])]
            have = {t.lstrip("0") or t for t in self.tokens(label)}
            return bool(want) and all(w in have for w in want)
        if not step.get("slot"):
            key = lambda t: "".join(ch for ch in str(t or "").lower() if ch.isalnum())
            if key(label) and key(label) == key(step.get("label")):
                return True
            return UserMoves.matches({"label": step.get("label", ""), "role": step.get("role", "")}, UserMoves.norm(label))
        have = set(self.tokens(label))
        fixed = set(self.tokens(step.get("fixed", "")))
        if len(fixed) <= self.MAX_FIXED_WORDS and not fixed <= have:
            return False
        return any(w in have for w in self.wanted(step))

    def targets(self, i, site, elements):
        step = self.steps[i]
        anywhere = (self.route or {}).get("source") == "pattern"   # UserPaths hook
        if step.get("kind") not in ("click", "type") or (step.get("site") != site and not anywhere):
            return []
        op = "TYPE_TEXT" if step["kind"] == "type" else "CLICK"
        pool = [e for e in elements if op in (e.get("operations") or [op]) and self.label_matches(step, e.get("label", ""))]
        if len(pool) > 1 and step.get("slot"):
            hits = lambda e: sum(1 for w in self.wanted(step) if w in set(self.tokens(e.get("label", ""))))
            best = max(hits(e) for e in pool)
            pool = [e for e in pool if hits(e) == best]
        return pool

    def next_on_page(self, site, elements):
        for i in self.pending()[:self.LOOKAHEAD + 1]:
            t = self.targets(i, site, elements)
            if len(t) == 1:
                return i, t[0]
        return None

    def way(self, next_index):
        lines = []
        for i, s in enumerate(self.steps):
            mark = "\u2713 " if i in self.done else ("\u2192 " if i == next_index else "")
            lines.append(mark + str(s.get("human") or s.get("label") or ""))
        out = {"note": USER_ROUTE_NOTE, "they_did": (self.route or {}).get("template", ""), "times": (self.route or {}).get("times", 1),
               "steps": lines}
        send = next((s.get("shortcut") for s in self.steps if s.get("kind") == "submit" and s.get("shortcut")), None)
        if send:
            out["they_send_with"] = send
        return out

    def annotate(self, body):
        """The request with this user's next step marked and their way in the state."""
        state = body.get("state") if isinstance(body, dict) else None
        if not self.route or not isinstance(state, dict) or "questions" not in body:
            return body
        site = UserMoves.site_key((state.get("page") or {}).get("url"))
        elements = state.get("elements")
        if not site or not isinstance(elements, list):
            return body
        found = self.next_on_page(site, elements)
        body = dict(body)
        body["state"] = {**state, "this_users_way": self.way(found[0] if found else (self.pending() or [None])[0])}
        if not found:
            return body
        index = found[1].get("index")
        def mark(d):
            prior = d.get("this_user")
            return {**d, "this_user": f"{prior}; {self.MARK}" if prior else self.MARK}
        body["state"]["elements"] = [mark(e) if e.get("index") == index else e for e in elements]
        qs = {}
        for name, q in body["questions"].items():
            if name.endswith("_target") and isinstance(q.get("criteria"), dict) and isinstance(q["criteria"].get(index), dict):
                q = dict(q)
                q["criteria"] = {**q["criteria"], index: mark(q["criteria"][index])}
                if isinstance(q.get("instructions"), dict):
                    rules = q["instructions"].get("rules")
                    rules = list(rules) if isinstance(rules, list) else ([rules] if rules else [])
                    q["instructions"] = {**q["instructions"], "rules": rules + [USER_ROUTE_RULE]}
            qs[name] = q
        body["questions"] = qs
        return body

    def observe(self, body, result):
        """A click or fill on a pending step's element moves the route past it."""
        try:
            answers = result.get("answers") or {}
            op = (answers.get("operation") or {}).get("choice")
            if op not in ("CLICK", "TYPE_TEXT"):
                return
            index = (answers.get(op.lower() + "_target") or {}).get("choice")
            state = body["state"]
            site = UserMoves.site_key((state.get("page") or {}).get("url"))
            elements = state.get("elements", [])
            for i in self.pending()[:self.LOOKAHEAD + 1]:
                if any(e.get("index") == index for e in self.targets(i, site, elements)):
                    self.done.update(range(i + 1))
                    return
        except (AttributeError, KeyError, TypeError):
            pass

    def install(self):
        if not self.route:
            return
        inner = jev_model.post_json

        def post_json(url, key, body):
            body = self.annotate(body)
            result = inner(url, key, body)
            if isinstance(body, dict) and isinstance(result, dict):
                self.observe(body, result)
            return result

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
    // Adaptation 34: the hit test descends into open shadow roots, like the snapshot's.
    let t=document.elementFromPoint(x,y);
    for (let i=0; t && t.shadowRoot && i<20; i++) { const s=t.shadowRoot.elementFromPoint(x,y); if (!s || s===t) break; t=s; }
    for (let n=t; n; n=n instanceof ShadowRoot ? n.host : n.parentNode) if (n===e) return {x,y};
  }
  return null;
})"""

_upstream_browser_operation = browser_module.browser_operation


# Adaptation 26 — a dropdown is set where it is, even under the site's own widget. Amazon's
# "Sort by" is a real <select> covered by a styled button, so upstream's hit test failed and
# raised "Dropdown execution was not confirmed", which ended the run ("buy … the cheapest one").
SELECT_JS = """(action => {
  const e=window.__jevFast?.nodes.get(action.node);
  if (!e?.isConnected || e.tagName!=='SELECT' || e.matches(':disabled') || e.closest('[aria-disabled="true"],[inert]')) return null;
  if (![...e.options].some(o=>o.value===action.value && !o.disabled && !o.closest('optgroup[disabled]'))) return null;
  e.focus();
  e.value=action.value;
  e.dispatchEvent(new Event('input',{bubbles:true}));
  e.dispatchEvent(new Event('change',{bubbles:true}));
  return e.value===action.value;
})"""


def browser_operation_navi(request):
    """Upstream `browser_operation`, with click/fill targeting from CLICK_POINT_JS and
    dropdowns set by SELECT_JS. A target that is gone is a StalePage (observe again), never
    an error that ends the run."""
    if request["operation"] == "observe":
        # Adaptations 33–35: frames, labels and unnamed controls on top of the snapshot.
        return perceive(request["session"], _upstream_browser_operation(request))
    if request["operation"] == "act" and request["action"]["kind"] == "select":
        action = request["action"]
        if type(action["node"]) is not int:
            raise ValueError("Invalid observed node")
        if action.get("frame"):
            frame_select(request["session"], action)
            return {"executed": action["id"]}
        result = cdp("Runtime.evaluate", session_id=request["session"],
                     expression=SELECT_JS + "(" + json.dumps(action) + ")", returnByValue=True)
        if result.get("exceptionDetails") or not result.get("result", {}).get("value"):
            raise StalePage("Dropdown changed or is gone. Observe again.")
        return {"executed": action["id"]}
    if request["operation"] != "act" or request["action"]["kind"] not in {"click", "fill"}:
        return _upstream_browser_operation(request)
    action, session = request["action"], request["session"]
    if type(action["node"]) is not int:
        raise ValueError("Invalid observed node")

    def call(method, **params):
        return cdp(method, session_id=session, **params)

    if action.get("frame"):
        x, y = frame_point(session, action)      # adaptation 33: resolved and hit-tested in its frame
    else:
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
        if is_recipient_label(action.get("label")) and not action.get("docs_body") and not action.get("frame"):
            RECIPIENT_NOTES.append(pick_recipient(call, action["node"], request["text"]))
    return {"executed": action["id"]}


# --- Adaptation 18: a recipient is a contact, not text ----------------------
#
# Typing a name into To / Cc / "Add guests" only starts the site's lookup; the
# contact is set when its suggestion is picked. Jev decides the next step from
# the page right after the fill — before the list is there — so the name stayed
# raw text (Gmail/Outlook turn it into an unresolvable chip). After a fill into
# such a field, wait for the options to settle and click the one for the name.
# Mirrors Navi/Agent/RecipientPicker.swift (same labels, same scoring).

RECIPIENT_LABELS = {
    "to", "cc", "bcc", "to recipients", "cc recipients", "bcc recipients", "recipients", "recipient",
    "add recipients", "send to", "invitees", "add invitees", "add guests", "guests", "attendees",
    "add people", "add members", "participants",
}
RECIPIENT_PHRASES = (
    "recipient", "add people", "add guests", "add invitees", "invite people", "add members",
    "name or email", "names or email", "name, email", "email or name", "type a name", "enter a name",
    "enter name", "search for people", "people or groups", "name, phone", "phone number or email",
    "email address or phone", "enter email", "add attendees",
)
RECIPIENT_SETTLE_S = 3.0
RECIPIENT_POLL_S = 0.1
RECIPIENT_FIRST_LOOK_S = 0.25
# Notes for the history entry of the fill that just ran (read by `tick`).
RECIPIENT_NOTES = []


def is_recipient_label(label):
    l = (label or "").lower().strip().rstrip(":…").strip()
    return bool(l) and (l in RECIPIENT_LABELS or any(p in l for p in RECIPIENT_PHRASES))


def looks_like_address(text):
    import re
    t = (text or "").strip()
    if re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", t):
        return True
    return sum(c.isdigit() for c in t) >= 7 and re.fullmatch(r"[+()\-.\s\d]+", t) is not None


def _fold(s):
    import unicodedata
    s = unicodedata.normalize("NFKD", s or "").replace("‎", "").replace("‏", "")
    return "".join(c for c in s if not unicodedata.combining(c)).lower()


def _words(s):
    import re
    return [w.strip(".'") for w in re.split(r"[^\w@.']+", _fold(s)) if w.strip(".'")]


def _parts(label):
    return [p.strip() for p in _fold(label).split(",") if p.strip()]


def suggestion_name(label):
    return (label or "").split(",", 1)[0].strip()


def has_handle(label):
    p = _parts(label)
    return len(p) >= 2 and ("@" in p[1] or sum(c.isdigit() for c in p[1]) >= 7)


def is_group(label):
    return not has_handle(label) and ("&" in (label or "") or len(_parts(label)) >= 3)


def recipient_score(typed, label, selected=False, recent=""):
    """How well a suggestion answers the typed name; None when it does not match."""
    t = _fold(typed).strip()
    if not t or not label:
        return None
    if looks_like_address(typed):
        digits = "".join(c for c in typed if c.isdigit())
        ok = t in _fold(label) or (len(digits) >= 7 and digits[-10:] in "".join(c for c in label if c.isdigit()))
        return 3 + (0.5 if selected else 0) if ok else None
    name_words, typed_words = _words(suggestion_name(label)), _words(typed)
    if not name_words or not typed_words:
        return None
    used, exact = set(), 0
    for w in typed_words:
        i = next((i for i, n in enumerate(name_words) if i not in used and n.startswith(w)), None)
        if i is None:
            return None
        used.add(i)
        exact += name_words[i] == w
    score = 1 + exact / len(typed_words)
    group = is_group(label)
    whole = len(used) == len(name_words)
    typed_exactly = whole and exact == len(name_words)
    named_group = group and typed_exactly and len(typed_words) >= 2
    if whole and (not group or named_group):
        score += 3 if typed_exactly else 1
    if has_handle(label):
        score += 1
    if group and not named_group:
        score -= 2
    if selected:
        score += 0.5
    full = _fold(suggestion_name(label))
    if recent and len(full) >= 3 and full in recent:
        score += 0.75
    return score


def compatible(typed, label):
    """Could `label` be a nickname spelling of `typed` ("mikey ku" ~ "Michael Ku Jr")?"""
    name_words, used = _words(suggestion_name(label)), set()
    typed_words = _words(typed)
    if not typed_words:
        return False
    for w in typed_words:
        i = next((i for i, n in enumerate(name_words) if i not in used and n[:1] == w[:1]), None)
        if i is None:
            return False
        used.add(i)
    return True


def choose_suggestion(typed, options, recent=""):
    """Best option by name (list order breaks ties), else the site's own pick when it
    is a person and does not contradict the name. `options`: [{label, selected, y}]."""
    best, best_score = None, None
    for o in options:
        sc = recipient_score(typed, o["label"], o.get("selected", False), recent)
        if sc is not None and (best_score is None or sc > best_score + 1e-9):
            best, best_score = o, sc
    if best is not None:
        return best
    rows = [o for o in options if compatible(typed, o["label"])]
    chosen = next((o for o in rows if o.get("selected") and not is_group(o["label"])), None)
    if chosen:
        return chosen
    top = min(rows, key=lambda o: o.get("y", 0), default=None)
    return top if top is not None and has_handle(top["label"]) else None


RECIPIENT_OPTIONS_JS = """(node => {
  const e=window.__jevFast?.nodes.get(node);
  if (!e?.isConnected) return null;
  const b=e.getBoundingClientRect();
  const shown=o=>{const r=o.getBoundingClientRect(); return r.width>2 && r.height>2 &&
    o.checkVisibility({checkOpacity:true,checkVisibilityCSS:true});};
  let scope=null;
  for (const id of (e.getAttribute('aria-controls')||e.getAttribute('aria-owns')||'').split(/\\s+/).filter(Boolean)) {
    const c=document.getElementById(id); if (c) { scope=c; break; }
  }
  let opts=[...(scope||document).querySelectorAll('[role=option],[role=listbox] [role=menuitem],[role=listbox] li')].filter(shown);
  if (!scope) opts=opts.filter(o=>{const r=o.getBoundingClientRect();
    return r.top>=b.top-4 && r.top<=b.bottom+480 && r.right>=b.left-20 && r.left<=b.right+60;});
  const active=e.getAttribute('aria-activedescendant');
  return {value:(e.value ?? e.innerText ?? '').trim(), options:opts.slice(0,25).map(o=>{
    const r=o.getBoundingClientRect();
    const text=(o.innerText||'').split('\\n').map(t=>t.trim()).filter(Boolean).join(', ');
    return {label:(text||o.getAttribute('aria-label')||'').slice(0,160),
      selected:o.getAttribute('aria-selected')==='true' || (!!active && o.id===active),
      x:r.left+r.width/2, y:r.top+r.height/2};
  })};
})"""


def pick_recipient(call, node, typed, recent=""):
    """Waits for the options a fill into a recipient field brought up and clicks the
    one for `typed`. Returns the note for the step's history entry."""
    def options():
        r = call("Runtime.evaluate", expression=f"{RECIPIENT_OPTIONS_JS}({json.dumps(node)})", returnByValue=True)
        return (r.get("result", {}).get("value") or {}).get("options") or []

    time.sleep(RECIPIENT_FIRST_LOOK_S)
    deadline = time.monotonic() + RECIPIENT_SETTLE_S
    last, stable, opts = None, 0, []
    while time.monotonic() < deadline:
        opts = options()
        key = [(o["label"], o["selected"]) for o in opts]
        stable = stable + 1 if opts and key == last else 0
        last = key
        choice = choose_suggestion(typed, opts, recent)
        if stable >= 2 and choice is not None and (not is_group(choice["label"]) or time.monotonic() > deadline - 1.0):
            break
        if stable >= 3 and choice is None:
            break
        time.sleep(RECIPIENT_POLL_S)
    choice = choose_suggestion(typed, opts, recent)
    if choice is None:
        if looks_like_address(typed):
            return "kept as typed (an address)"
        seen = [suggestion_name(o["label"]) for o in opts][:3]
        if seen:
            return f"error: no suggestion matches ‘{typed}’ (saw: {'; '.join(seen)}) — recipient NOT set"
        return f"error: no contact suggestion came up for ‘{typed}’ (recipient NOT set)"
    for event in ("mousePressed", "mouseReleased"):
        call("Input.dispatchMouseEvent", type=event, x=choice["x"], y=choice["y"], button="left", clickCount=1)
    name = suggestion_name(choice["label"])
    emit("status", message=f"Picked the contact ‘{name}’ for ‘{typed}’")
    return f"picked the contact ‘{name}’ from the suggestions (recipient set)"


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
    # Adaptation 23 — an open modal is all that can be clicked: elements behind it are left out.
    ("  const actions=[];\n",
     "  const modals=[...document.querySelectorAll('[aria-modal=\"true\"],dialog')].filter(m=>{\n"
     "    if (m.tagName==='DIALOG' && !m.matches(':modal')) return false;\n"
     "    if (!m.checkVisibility({checkOpacity:true,checkVisibilityCSS:true}) || m.closest('[aria-hidden=\"true\"],[inert]')) return false;\n"
     "    const b=m.getBoundingClientRect();\n"
     "    if (b.width*b.height < innerWidth*innerHeight*0.06) return false;\n"
     "    const cx=Math.min(innerWidth-1,Math.max(0,b.x+b.width/2)), cy=Math.min(innerHeight-1,Math.max(0,b.y+b.height/2));\n"
     "    const top=document.elementFromPoint(cx,cy);\n"
     "    return !!top && m.contains(top);\n"
     "  });\n"
     "  const actions=[];\n"),
    ("if (!rname || r.width<=0 || r.height<=0 || x<0 || y<0 || x>=innerWidth || y>=innerHeight) continue;",
     "if (!rname || r.width<=0 || r.height<=0 || x<0 || y<0 || x>=innerWidth || y>=innerHeight) continue;\n"
     "    if (modals.length && !modals.some(m=>m.contains(e))) continue;\n"
     "    if (covered(e,r)) continue;"),
    # Adaptation 28 — only what a click can reach is offered (any overlay, banner or loading
    # screen, not only aria-modal dialogs); a control without a name is named from its title,
    # icon, test id or the text around it; controls sharing a label say what they belong to.
    ("  const modals=",
     "  const reaches=(e,t)=>!!t && (e===t || e.contains(t) || t.contains(e) ||\n"
     "    (!!t.closest && !!t.closest('label') && [...(e.labels||[])].includes(t.closest('label'))));\n"
     "  const covered=(e,r)=>{\n"
     "    if (e.tagName==='CANVAS' || e.classList?.contains('kix-appview-editor')) return false;\n"
     "    for (const [fx,fy] of [[.5,.5],[.15,.5],[.85,.5],[.5,.2],[.5,.8]]) {\n"
     "      const px=Math.min(innerWidth-1,Math.max(0,r.x+r.width*fx)), py=Math.min(innerHeight-1,Math.max(0,r.y+r.height*fy));\n"
     "      if (reaches(e,document.elementFromPoint(px,py))) return false;\n"
     "    }\n"
     "    return true;\n"
     "  };\n"
     "  const human=t=>String(t||'').replace(/([a-z])([A-Z])/g,'$1 $2').replace(/[-_]+/g,' ').replace(/\\s+/g,' ').trim();\n"
     "  const nearText=(e,skip,others)=>{\n"
     "    let p=e.parentElement;\n"
     "    for (let i=0;i<6 && p && p!==document.body;i++,p=p.parentElement) {\n"
     "      const line=String(p.innerText||'').split('\\n').map(t=>t.replace(/\\s+/g,' ').trim())\n"
     "        .find(t=>t.length>1 && t!==skip && !skip.startsWith(t) && !(others && others.has(t)));\n"
     "      if (line) return line.slice(0,60);\n"
     "    }\n"
     "    return '';\n"
     "  };\n"
     "  const fallbackName=(e,rname)=>{\n"
     "    const own=e.getAttribute('title')||e.querySelector('img[alt]')?.getAttribute('alt')||e.querySelector('svg title')?.textContent||\n"
     "      e.getAttribute('data-testid')||e.getAttribute('data-test')||e.getAttribute('data-qa')||(e.id && !/\\d{3}/.test(e.id) ? e.id : '');\n"
     "    if (own && human(own)) return human(own);\n"
     "    const near=nearText(e,'');\n"
     "    return near ? rname+' by “'+near+'”' : '';\n"
     "  };\n"
     "  const modals="),
    (") : name(e)||rname,",
     ") : name(e)||fallbackName(e,rname)||rname,"),
    # Adaptation 29 — what a person sees as clickable is a target, whatever its markup: a card
    # that is a <div> with a click handler and a pointer cursor (Chipotle's fillings, many
    # menus and pickers) had no entry, so Jev clicked the "More Info" buttons on it instead.
    # The viewport is sampled; each hit's outermost pointer-cursor box that is not already a
    # control, not inside one, and not mostly one inner control, is offered as a button.
    ("  const words=[], walker=",
     "  {\n"
     "    const seen=new Set(actions.map(a=>a.node)), pointer=new Map(), found=[], labels0=new Set(actions.map(a=>a.label));\n"
     "    const isPointer=e=>{ if (!pointer.has(e)) pointer.set(e,getComputedStyle(e).cursor==='pointer'); return pointer.get(e); };\n"
     "    const area=innerWidth*innerHeight;\n"
     "    for (let y=16; y<innerHeight && found.length<80; y+=32) for (let x=20; x<innerWidth && found.length<80; x+=40) {\n"
     "      let c=document.elementFromPoint(x,y);\n"
     "      if (!c || c===document.body || c===document.documentElement || !isPointer(c)) continue;\n"
     "      while (c.parentElement && c.parentElement!==document.body && isPointer(c.parentElement)) c=c.parentElement;\n"
     "      if (found.includes(c) || c.matches(selector) || c.closest(selector) || c.closest('[aria-hidden=\"true\"],[inert]')) continue;\n"
     "      if (modals.length && !modals.some(m=>m.contains(c))) continue;\n"
     "      const b=c.getBoundingClientRect();\n"
     "      if (b.width<12 || b.height<12 || b.width*b.height>area*0.4) continue;\n"
     "      const inner=[...c.querySelectorAll(selector)].filter(visible);\n"
     "      if (inner.some(i=>{const q=i.getBoundingClientRect(); return q.width*q.height>=b.width*b.height*0.6;})) continue;\n"
     "      let own=String(c.innerText||'');\n"
     "      for (const i of inner) own=own.split(String(i.innerText||'').trim()).join(' ');\n"
     "      if (inner.length && !/[\\p{L}\\p{N}]/u.test(own)) continue;\n"
     "      const text=(c.getAttribute('aria-label')||String(c.innerText||'').split('\\n').map(t=>t.trim()).filter(Boolean).slice(0,3).join(' · ')).replace(/\\s+/g,' ').slice(0,90);\n"
     "      const label=text||nearText(c,'',labels0)||fallbackName(c,'button');\n"
     "      if (!label) continue;\n"
     "      found.push(c);\n"
     "      const id=identity(c);\n"
     "      if (seen.has(id)) continue;\n"
     "      const item={node:id,role:'button',label,rect:{x:b.x,y:b.y,w:b.width,h:b.height},kind:'click',value:'',pointer:true};\n"
     "      // Picked or not: a card that is already chosen must not be clicked again (that un-picks it).\n"
     "      const marked=[c,...c.querySelectorAll('*')].slice(0,60).find(x=>x.getAttribute && (x.getAttribute('aria-pressed')||x.getAttribute('aria-selected')||x.getAttribute('aria-checked')));\n"
     "      const flag=marked && (marked.getAttribute('aria-pressed')||marked.getAttribute('aria-selected')||marked.getAttribute('aria-checked'));\n"
     "      const cls=[c,c.parentElement,...c.querySelectorAll('[class]')].slice(0,40).map(x=>x && typeof x.className==='string' ? x.className : '').join(' ');\n"
     "      if (flag==='true' || /(^|[\\s_-])(is-?)?(selected|active|checked|chosen|picked)([\\s_-]|$)/i.test(cls)) item.selected='true';\n"
     "      else if (flag==='false') item.selected='false';\n"
     "      actions.push(item);\n"
     "    }\n"
     "  }\n"
     "  const words=[], walker="),
    ("  const text=words.join('\\n').slice(0,6000), height=document.documentElement.scrollHeight;",
     "  const sameLabel={};\n"
     "  for (const a of actions) sameLabel[a.label]=(sameLabel[a.label]||0)+1;\n"
     "  const labels=new Set(Object.keys(sameLabel).filter(l=>sameLabel[l]>1)), twins={};\n"
     "  for (const a of actions) if (sameLabel[a.label]>1) (twins[a.label]||=[]).push(cache.nodes.get(a.node));\n"
     "  const apart=(a,b)=>{ const r=a.getBoundingClientRect(), q=b.getBoundingClientRect();\n"
     "    return q.x+q.width/2<r.left || q.x+q.width/2>r.right || q.y+q.height/2<r.top || q.y+q.height/2>r.bottom; };\n"
     "  const ownBox=(e,label)=>{\n"
     "    // The largest box around e that holds none of its twins elsewhere on the page: its card.\n"
     "    let box=null;\n"
     "    for (let p=e.parentElement, i=0; p && p!==document.body && i<30; p=p.parentElement, i++) {\n"
     "      if (twins[label].some(t=>t && t!==e && p.contains(t) && apart(e,t))) break;\n"
     "      box=p;\n"
     "    }\n"
     "    return box;\n"
     "  };\n"
     "  for (const a of actions) if (sameLabel[a.label]>1 && a.kind!=='select') {\n"
     "    const node=cache.nodes.get(a.node), box=node && ownBox(node,a.label);\n"
     "    const ok=t=>t.length>2 && /[\\p{L}]{2}/u.test(t) && t!==a.label && !labels.has(t) &&\n"
     "      !/^(sponsored|ad|new|sale|best ?seller|options?)$|^#\\d|most (liked|popular|ordered)|new on amazon|limited time|^[$€£¥]|^\\d+(\\.\\d+)? ?(out of|stars?|reviews?|ratings?)/i.test(t);\n"
     "    const clean=t=>String(t||'').replace(/\\s+/g,' ').trim();\n"
     "    // The card's title (a heading or its link) first; badges like '#1 Most liked' come before it.\n"
     "    const titled=box ? [...box.querySelectorAll('h1,h2,h3,h4,h5,h6,[role=heading]'),...box.querySelectorAll('a[href]')].map(h=>clean(h.innerText).split('\\n')[0]).find(ok) : '';\n"
     "    const ctx=titled || (box ? String(box.innerText||'').split('\\n').map(clean).find(ok) : '');\n"
     "    if (ctx) a.label=a.label+' — '+ctx.slice(0,70);\n"
     "  }\n"
     "  const text=words.join('\\n').slice(0,6000), height=document.documentElement.scrollHeight;"),
    # Adaptation 34 — open shadow roots are part of the page. Controls inside web components
    # (Shopify, Salesforce, Reddit, many checkouts) were never enumerated, and a hit test that
    # lands in a shadow tree returns its host, so the reachability check dropped them anyway.
    # `roots` holds the document and every open shadow root; queries, hit tests and "inside
    # the dialog" all cross shadow boundaries.
    ("  const safe = e => !['password','file','hidden'].includes(e.type);\n",
     "  const safe = e => !['password','file','hidden'].includes(e.type);\n"
     "  const roots=[document];\n"
     "  for (let i=0; i<roots.length && roots.length<300; i++) for (const h of roots[i].querySelectorAll('*')) if (h.shadowRoot) roots.push(h.shadowRoot);\n"
     "  const deepAll=sel=>roots.length===1 ? [...document.querySelectorAll(sel)] : roots.flatMap(r=>[...r.querySelectorAll(sel)]);\n"
     "  const within=(m,e)=>{ for (let n=e; n; n=n instanceof ShadowRoot ? n.host : n.parentNode) if (n===m) return true; return false; };\n"
     "  const deepHit=(x,y)=>{ let t=document.elementFromPoint(x,y);\n"
     "    for (let i=0; t && t.shadowRoot && i<20; i++) { const s=t.shadowRoot.elementFromPoint(x,y); if (!s || s===t) break; t=s; }\n"
     "    return t; };\n"
     # Adaptation 35 — the top layer. A dialog is what a person can act on when the page
     # behind it is blocked: aria-modal / <dialog> as before, and also role=dialog/alertdialog
     # and plain fixed overlays (no ARIA at all) when a backdrop covers the rest of the viewport.
     "  const area=r=>Math.max(0,r.width)*Math.max(0,r.height), VP=()=>innerWidth*innerHeight;\n"
     "  const CONTROLS='a[href],button,input,select,textarea,[role=\"button\"],[role=\"link\"],[role=\"textbox\"]';\n"
     "  const translucent=s=>{ const c=String(s.backgroundColor||'').match(/[\\d.]+/g);\n"
     "    return (!!c && c.length===4 && +c[3]>0.05 && +c[3]<1) || (!!s.backdropFilter && s.backdropFilter!=='none'); };\n"
     "  const blocks=(t,m)=>{\n"
     "    for (let n=t, i=0; n && n.nodeType===1 && i<4; n=n.parentElement, i++) {\n"
     "      if (m && within(m,n)) return true;\n"
     "      const s=getComputedStyle(n);\n"
     "      if ((s.position==='fixed' || s.position==='absolute') && area(n.getBoundingClientRect())>=VP()*0.8 &&\n"
     "          ((m && within(n,m)) || !n.querySelector(CONTROLS))) return true;\n"
     "    }\n"
     "    return false;\n"
     "  };\n"
     "  const blocksPage=m=>{\n"
     "    const b=m.getBoundingClientRect();\n"
     "    if (area(b)>=VP()*0.9) return true;\n"
     "    let out=0, hit=0;\n"
     "    for (const [fx,fy] of [[.03,.5],[.97,.5],[.5,.03],[.5,.97],[.03,.03],[.97,.03],[.03,.97],[.97,.97],[.2,.5],[.8,.5]]) {\n"
     "      const x=innerWidth*fx, y=innerHeight*fy;\n"
     "      if (x>=b.left && x<=b.right && y>=b.top && y<=b.bottom) continue;\n"
     "      out++;\n"
     "      if (blocks(deepHit(x,y),m)) hit++;\n"
     "    }\n"
     "    return out>0 && hit>=Math.ceil(out*0.75);\n"
     "  };\n"
     "  const overlayLayer=()=>{\n"
     "    let L=null;\n"
     "    for (let n=deepHit(innerWidth/2,innerHeight/2); n && n!==document.body && n!==document.documentElement;\n"
     "         n=n.parentElement || (n.getRootNode() instanceof ShadowRoot ? n.getRootNode().host : null))\n"
     "      if (getComputedStyle(n).position==='fixed') L=n;\n"
     "    if (!L || L.closest('[aria-hidden=\"true\"],[inert]')) return [];\n"
     "    const b=L.getBoundingClientRect();\n"
     "    if (area(b)<VP()*0.06) return [];\n"
     "    if (area(b)>=VP()*0.9) return translucent(getComputedStyle(L)) ||\n"
     "      [...L.children].some(c=>area(c.getBoundingClientRect())>=VP()*0.8 && translucent(getComputedStyle(c))) ? [L] : [];\n"
     "    return blocksPage(L) ? [L] : [];\n"
     "  };\n"
     "  const dialogName=m=>{\n"
     "    const by=(m.getAttribute('aria-labelledby')||'').split(/\\s+/).map(id=>(m.getRootNode().getElementById ? m.getRootNode().getElementById(id) : null)||document.getElementById(id))\n"
     "      .filter(Boolean).map(e=>e.innerText).join(' ');\n"
     "    const h=m.querySelector('h1,h2,h3,h4,[role=\"heading\"]');\n"
     "    return String(m.getAttribute('aria-label')||by||(h && h.innerText)||String(m.innerText||'').split('\\n').find(t=>t.trim())||'dialog').replace(/\\s+/g,' ').trim().slice(0,80);\n"
     "  };\n"),
    ("for (const e of document.querySelectorAll(selector)) {", "for (const e of deepAll(selector)) {"),
    ("(e===t || e.contains(t) || t.contains(e) ||", "(e===t || within(e,t) || within(t,e) ||"),
    ("if (reaches(e,document.elementFromPoint(px,py))) return false;", "if (reaches(e,deepHit(px,py))) return false;"),
    # Adaptation 34 — <style>/<script> text is never part of a name. DoorDash's buttons embed a
    # <style> element, so labels read "Build Your Pizza - $11.39 .prism-size-msf7vl > * {…".
    ("n.nodeType===1 && n.getAttribute('aria-hidden')!=='true' ? name(n,seen) : ''",
     "n.nodeType===1 && n.getAttribute('aria-hidden')!=='true' && !/^(STYLE|SCRIPT|NOSCRIPT|TEMPLATE)$/.test(n.tagName) ? name(n,seen) : ''"),
    (".map(id=>name(document.getElementById(id),seen))",
     ".map(id=>name((e.getRootNode().getElementById ? e.getRootNode().getElementById(id) : null)||document.getElementById(id),seen))"),
    # Adaptation 35 — which layers count as the dialog in front (see the helpers above).
    ("const modals=[...document.querySelectorAll('[aria-modal=\"true\"],dialog')].filter(m=>{",
     "const modals=[...deepAll('[aria-modal=\"true\"],dialog,[role=\"dialog\"],[role=\"alertdialog\"]')].filter(m=>{"),
    ("    const top=document.elementFromPoint(cx,cy);\n    return !!top && m.contains(top);\n  });\n",
     "    const top=deepHit(cx,cy);\n"
     "    if (!top || !within(m,top)) return false;\n"
     "    return m.getAttribute('aria-modal')==='true' || m.tagName==='DIALOG' || blocksPage(m);\n"
     "  });\n"
     "  if (!modals.length) modals.push(...overlayLayer());\n"
     "  cache.modals=modals;\n"),
    ("if (modals.length && !modals.some(m=>m.contains(e))) continue;", "if (modals.length && !modals.some(m=>within(m,e))) continue;"),
    ("if (modals.length && !modals.some(m=>m.contains(c))) continue;", "if (modals.length && !modals.some(m=>within(m,c))) continue;"),
    # The dialog's own text comes first (it is what the person is reading), and text inside
    # open shadow roots is read too. Upstream walked document.body only and stopped at 6000
    # characters — usually before reaching a dialog appended at the end of the body.
    ("const words=[], walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);\n"
     "  const range=document.createRange(); let node,length=0;\n"
     "  while ((node=walker.nextNode()) && length<6000) {",
     "const words=[], textRoots=[...modals.map(m=>[m,true]), ...roots.map(r=>[r===document ? document.body : r,false])];\n"
     "  let walker=null, modalPass=false, wi=0;\n"
     "  const range=document.createRange(); let node,length=0;\n"
     "  while (length<6000) {\n"
     "    node=walker && walker.nextNode();\n"
     "    if (!node) { if (wi>=textRoots.length) break; walker=document.createTreeWalker(textRoots[wi][0],NodeFilter.SHOW_TEXT); modalPass=textRoots[wi][1]; wi++; continue; }"),
    ("if (!value || !parent || parent.closest('script,style,noscript,template') || !visible(parent)) continue;",
     "if (!value || !parent || parent.closest('script,style,noscript,template') || !visible(parent)) continue;\n"
     "    if (!modalPass && modals.length && modals.some(m=>within(m,parent))) continue;"),
    # What the page reports beyond upstream: the open dialog's name and how many visible
    # frames could hold more of the page (adaptation 33 reads them only when there are any).
    ("scroll:{y:scrollY,height},actions,marker,page_key,guards,omitted_actions};",
     "scroll:{y:scrollY,height},actions,marker,page_key,guards,omitted_actions,\n"
     "    dialog:modals.length ? dialogName(modals[modals.length-1]) : null,\n"
     "    frame_candidates:deepAll('iframe,frame').filter(f=>{ const r=f.getBoundingClientRect();\n"
     "      return r.width>=24 && r.height>=24 && r.right>0 && r.bottom>0 && r.left<innerWidth && r.top<innerHeight &&\n"
     "        f.checkVisibility({checkOpacity:true,checkVisibilityCSS:true}); }).length};"),
]


_upstream_snapshot_js = browser_module.READ_STATE


def patched_snapshot_js():
    js = _upstream_snapshot_js
    for old, new in SNAPSHOT_PATCHES:
        if old not in js:
            raise RuntimeError("upstream snapshot.js changed; the canvas patch in navi_runner.py needs updating")
        js = js.replace(old, new)
    return js


# --- Adaptation 33: what is inside a frame is on the page ---------------------
#
# The snapshot runs in the top document only, so anything in an <iframe> was invisible to
# Jev. DoorDash's "Sign In" opens an aria-modal dialog whose whole content — "Continue with
# Google", the email field — is an iframe from identity.doordash.com: the table held only the
# dialog's Close button, and Jev clicked Sign In → Close → Sign In until the coach gave up.
# Embedded checkouts, consent managers, payment and login widgets work the same way.
#
# Every visible frame is now read with the same patched snapshot in an isolated world of its
# own document — same-process frames (same-origin or same-site) through the page's session,
# out-of-process ones (cross-site) through a session attached to their target — and its
# controls join the table at their place on screen: offset by the <iframe>'s content box,
# kept only where a hit test in the parent lands on that <iframe> (nothing covers them), and
# dropped when the page has a dialog open that the frame is not inside. Clicks go to the
# top-level coordinates (Chrome routes input into frames); the element is resolved and
# hit-tested in its own frame first, exactly like a top-document click. Node ids of a frame
# start at FRAME_NODE_BASE × its number, so they never collide with the top document's.

FRAME_WORLD = "navi-perception"
FRAME_NODE_BASE = 1_000_000
MAX_FRAMES = 10
FRAME_DEPTH = 3
CAPTCHA_FRAME = re.compile(r"recaptcha|hcaptcha|challenges\.cloudflare\.com|turnstile|arkoselabs|funcaptcha|captcha", re.I)
INVISIBLE_CAPTCHA = re.compile(r"[?&]size=invisible\b", re.I)

# Runs on the <iframe> element (`this`) in its parent's world, after that world's snapshot:
# where the frame's content box is, what of it is on screen, whether it is inside the
# parent's open dialog, and which of `points` (parent coordinates) a click would reach.
FRAME_INFO_FN = """function (points) {
  const f=this, c=window.__jevFast;
  if (!f || !f.isConnected || f.closest('[aria-hidden="true"],[inert]') ||
      !f.checkVisibility({checkOpacity:true,checkVisibilityCSS:true})) return null;
  const r=f.getBoundingClientRect(), s=getComputedStyle(f), px=v=>parseFloat(v)||0;
  const x=r.x+f.clientLeft+px(s.paddingLeft), y=r.y+f.clientTop+px(s.paddingTop);
  const w=f.clientWidth-px(s.paddingLeft)-px(s.paddingRight), h=f.clientHeight-px(s.paddingTop)-px(s.paddingBottom);
  if (w<24 || h<24) return null;
  const clip=[Math.max(0,x),Math.max(0,y),Math.min(innerWidth,x+w),Math.min(innerHeight,y+h)];
  if (clip[2]-clip[0]<12 || clip[3]-clip[1]<12) return null;
  const within=(m,e)=>{ for (let n=e; n; n=n instanceof ShadowRoot ? n.host : n.parentNode) if (n===m) return true; return false; };
  const hit=(hx,hy)=>{ let t=document.elementFromPoint(hx,hy);
    for (let i=0; t && t.shadowRoot && i<20; i++) { const q=t.shadowRoot.elementFromPoint(hx,hy); if (!q || q===t) break; t=q; }
    return t===f; };
  const modals=(c && c.modals) || [];
  const reachable=[[.5,.5],[.2,.2],[.8,.2],[.2,.8],[.8,.8],[.5,.15],[.5,.85]].some(([a,b])=>
    hit(clip[0]+(clip[2]-clip[0])*a, clip[1]+(clip[3]-clip[1])*b));
  return {x,y,w,h,clip,reachable,modal:!modals.length || modals.some(m=>within(m,f)),
    title:f.title||f.name||'',hits:(points||[]).map(([hx,hy])=>hx>=clip[0] && hx<clip[2] && hy>=clip[1] && hy<clip[3] && hit(hx,hy))};
}"""


def frame_snapshot_js(number):
    """The patched snapshot, for frame `number`: its node ids start above the top document's."""
    return ("(() => { window.__jevFast ||= {ids:new WeakMap(), nodes:new Map(), next:%d}; return %s; })()"
            % (FRAME_NODE_BASE * number + 1, browser_module.READ_STATE))


class FrameReader:
    """Reads the visible frames of one tab (one page session) and routes input into them."""

    def __init__(self, session):
        self.session = session
        self.numbers = {}     # frame id → small number (node-id base)
        self.attached = {}    # out-of-process frame id → its own session
        self.last = {}        # frame id → where it was read: session, context, parent, offset

    def call(self, method, session=None, **params):
        return cdp(method, session_id=session or self.session, **params)

    def number(self, fid):
        return self.numbers.setdefault(fid, len(self.numbers) + 1)

    def tree(self):
        """The top frame's id and its descendant frames, parents first: id, parent, the session
        that holds the frame's document, url. Page.getFrameTree lists the frames in this
        renderer; out-of-process frames are iframe targets whose parentFrameId we know."""
        frames = []

        def local(node, session, depth):
            for child in node.get("childFrames") or []:
                f = child["frame"]
                frames.append({"id": f["id"], "parent": node["frame"]["id"], "session": session,
                               "url": f.get("url", "") + (f.get("urlFragment") or ""), "depth": depth})
                if depth < FRAME_DEPTH:
                    local(child, session, depth + 1)

        top = self.call("Page.getFrameTree")["frameTree"]
        local(top, self.session, 1)
        depth = {top["frame"]["id"]: 0, **{f["id"]: f["depth"] for f in frames}}
        try:
            targets = [t for t in cdp("Target.getTargets").get("targetInfos", []) if t.get("type") == "iframe"]
        except Exception:  # noqa: BLE001 — out-of-process frames are then simply not read
            targets = []
        grew = True
        while grew:
            grew = False
            for t in targets:
                tid, parent = t.get("targetId"), t.get("parentFrameId")
                if tid in depth or parent not in depth or depth[parent] >= FRAME_DEPTH:
                    continue
                session = self.attached.get(tid)
                if session is None:
                    try:
                        session = cdp("Target.attachToTarget", targetId=tid, flatten=True)["sessionId"]
                    except Exception:  # noqa: BLE001 — gone, or not attachable
                        depth[tid] = FRAME_DEPTH
                        continue
                    self.attached[tid] = session
                frames.append({"id": tid, "parent": parent, "session": session, "url": t.get("url", ""),
                               "depth": depth[parent] + 1, "oopif": True})
                depth[tid] = depth[parent] + 1
                if depth[tid] < FRAME_DEPTH:
                    try:
                        before = len(frames)
                        local(self.call("Page.getFrameTree", session=session)["frameTree"], session, depth[tid] + 1)
                        depth.update({f["id"]: f["depth"] for f in frames[before:]})
                    except Exception:  # noqa: BLE001
                        pass
                grew = True
        return top["frame"]["id"], frames

    def owner(self, fid, psession, pcontext, points=None, obj=None):
        """FRAME_INFO_FN on the <iframe> holding `fid`, in its parent's world; (object id, info)."""
        if obj is None:
            backend = self.call("DOM.getFrameOwner", session=psession, frameId=fid)["backendNodeId"]
            params = {"backendNodeId": backend, "objectGroup": FRAME_WORLD}
            if pcontext:
                params["executionContextId"] = pcontext
            obj = self.call("DOM.resolveNode", session=psession, **params)["object"]["objectId"]
        result = self.call("Runtime.callFunctionOn", session=psession, objectId=obj, functionDeclaration=FRAME_INFO_FN,
                           arguments=[{"value": points}], returnByValue=True)
        return obj, (result.get("result") or {}).get("value")

    def release(self, sessions):
        for s in sessions:
            try:
                self.call("Runtime.releaseObjectGroup", session=s, objectGroup=FRAME_WORLD)
            except Exception:  # noqa: BLE001
                pass

    def read(self, page):
        """Snapshots of the visible frames of `page` (the top document's snapshot)."""
        if not page.get("frame_candidates"):
            self.last = {}
            return []
        top, frames = self.tree()
        refs = {top: {"session": self.session, "context": None, "x": 0.0, "y": 0.0,
                      "clip": (0.0, 0.0, float(page.get("w") or 1e9), float(page.get("h") or 1e9)), "modal": True}}
        results, touched = [], {self.session}
        for f in frames:
            if len(results) >= MAX_FRAMES:
                break
            parent = refs.get(f["parent"])
            if parent is None:
                continue
            try:
                obj, info = self.owner(f["id"], parent["session"], parent["context"])
            except Exception:  # noqa: BLE001 — detached while we looked
                continue
            touched.add(parent["session"])
            if not info:
                continue
            x, y = parent["x"] + info["x"], parent["y"] + info["y"]
            c, pc = info["clip"], parent["clip"]
            clip = (max(pc[0], parent["x"] + c[0]), max(pc[1], parent["y"] + c[1]),
                    min(pc[2], parent["x"] + c[2]), min(pc[3], parent["y"] + c[3]))
            if clip[2] - clip[0] < 12 or clip[3] - clip[1] < 12:
                continue
            ref = {"session": f["session"], "context": None, "parent": f["parent"], "x": x, "y": y, "clip": clip,
                   "modal": parent["modal"] and bool(info.get("modal")), "reachable": bool(info.get("reachable")),
                   "psession": parent["session"], "pcontext": parent["context"]}
            snap = None
            try:
                ref["context"] = self.call("Page.createIsolatedWorld", session=f["session"], frameId=f["id"],
                                           worldName=FRAME_WORLD)["executionContextId"]
                r = self.call("Runtime.evaluate", session=f["session"], contextId=ref["context"],
                              expression=frame_snapshot_js(self.number(f["id"])), returnByValue=True)
                if not r.get("exceptionDetails"):
                    snap = (r.get("result") or {}).get("value")
            except Exception:  # noqa: BLE001 — navigating; reported as unread below
                snap = None
            refs[f["id"]] = ref
            result = {"frame": f, "ref": ref, "info": info, "snapshot": snap, "hits": []}
            acts = [a for a in (snap or {}).get("actions", []) if a.get("kind") in INTERACTIVE]
            if acts:
                points = [[a["rect"]["x"] + a["rect"]["w"] / 2 + info["x"], a["rect"]["y"] + a["rect"]["h"] / 2 + info["y"]]
                          for a in acts]
                try:
                    result["hits"] = (self.owner(f["id"], parent["session"], parent["context"], points, obj)[1] or {}).get("hits") or []
                except Exception:  # noqa: BLE001
                    result["hits"] = []
            results.append(result)
        self.release(touched)
        self.last = {fid: r for fid, r in refs.items() if fid != top}
        return results

    def locate(self, fid):
        """(session, context, x, y) of frame `fid` from the last observation, its offset measured again now."""
        if fid not in self.last or self.last[fid].get("context") is None:
            raise StalePage("The frame is gone. Observe again.")
        chain, f = [], fid
        while f in self.last:
            chain.append(f)
            f = self.last[f]["parent"]
        x = y = 0.0
        sessions = set()
        try:
            for f in reversed(chain):
                ref = self.last[f]
                _, info = self.owner(f, ref["psession"], ref["pcontext"])
                sessions.add(ref["psession"])
                if not info:
                    raise StalePage("The frame is hidden now. Observe again.")
                x, y = x + info["x"], y + info["y"]
        except StalePage:
            raise
        except Exception:  # noqa: BLE001
            raise StalePage("The frame changed. Observe again.") from None
        finally:
            self.release(sessions)
        ref = self.last[fid]
        return ref["session"], ref["context"], x, y

    def evaluate(self, fid, expression):
        session, context, _, _ = self.locate_fast(fid)
        r = self.call("Runtime.evaluate", session=session, contextId=context, expression=expression, returnByValue=True)
        if r.get("exceptionDetails"):
            raise StalePage("The frame changed during evaluation")
        return (r.get("result") or {}).get("value")

    def locate_fast(self, fid):
        ref = self.last.get(fid)
        if not ref or ref.get("context") is None:
            raise StalePage("The frame is gone. Observe again.")
        return ref["session"], ref["context"], ref["x"], ref["y"]


FRAMES = {}   # page session → FrameReader


def frame_reader(session):
    if session not in FRAMES:
        FRAMES[session] = FrameReader(session)
    return FRAMES[session]


def frame_unread(result, page):
    """A frame a person sees that gave Jev nothing: no snapshot, or nothing on it at all."""
    snap, ref, info = result.get("snapshot"), result["ref"], result["info"]
    clip = ref["clip"]
    visible_area = max(0.0, clip[2] - clip[0]) * max(0.0, clip[3] - clip[1])
    big = visible_area >= 0.15 * float(page.get("w") or 1) * float(page.get("h") or 1)
    if not ref.get("reachable") or not (big or (page.get("dialog") and ref.get("modal"))):
        return False
    if snap is None:
        return True
    acts = [a for a in snap.get("actions", []) if a.get("kind") in INTERACTIVE]
    return not acts and not (snap.get("text") or "").strip()


def merge_frames(page, results):
    """Folds frame snapshots (FrameReader.read) into the top document's snapshot, in place."""
    interactive = [a for a in page["actions"] if a.get("kind") in INTERACTIVE]
    controls = [a for a in page["actions"] if a.get("kind") not in INTERACTIVE]
    n = max([int(a["id"][1:]) for a in interactive if re.fullmatch(r"e\d+", str(a.get("id")))] or [0])
    first_text, last_text, added, unread = [], [], [], []
    frames = page.setdefault("frames", {})
    guards = page.setdefault("guards", {})
    for result in results:
        f, ref, snap = result["frame"], result["ref"], result.get("snapshot")
        url = (snap or {}).get("url") or f.get("url") or ""
        if not ref.get("modal"):
            continue                                   # behind the page's open dialog
        captcha = bool(CAPTCHA_FRAME.search(url)) and not INVISIBLE_CAPTCHA.search(url)
        if captcha:
            # Never offered: a challenge is the user's to answer. Reported (adaptation 36).
            if ref.get("reachable"):
                unread.append({"url": url[:200], "captcha": True, "w": round(ref["clip"][2] - ref["clip"][0]),
                               "h": round(ref["clip"][3] - ref["clip"][1])})
            continue
        if INVISIBLE_CAPTCHA.search(url):
            continue
        if frame_unread(result, page):
            unread.append({"url": url[:200], "captcha": False, "w": round(ref["clip"][2] - ref["clip"][0]),
                           "h": round(ref["clip"][3] - ref["clip"][1]), "title": (result["info"] or {}).get("title", "")})
        if not snap:
            continue
        acts = [a for a in snap.get("actions", []) if a.get("kind") in INTERACTIVE]
        hits = result.get("hits") or []
        clip = ref["clip"]
        for i, a in enumerate(acts):
            if i >= len(hits) or not hits[i]:
                continue                               # covered in the parent, or outside the frame's box
            rect = a["rect"]
            moved = {**rect, "x": rect["x"] + ref["x"], "y": rect["y"] + ref["y"]}
            cx, cy = moved["x"] + moved["w"] / 2, moved["y"] + moved["h"] / 2
            if not (clip[0] <= cx < clip[2] and clip[1] <= cy < clip[3]):
                continue
            added.append({**a, "rect": moved, "frame": f["id"]})
        for key, guard in (snap.get("guards") or {}).items():
            guards[str(key)] = guard
        frames[f["id"]] = {"page_key": snap.get("page_key"), "url": url}
        text = (snap.get("text") or "").strip()
        if text:
            (first_text if page.get("dialog") else last_text).append(text)
    room = max(0, 250 - len(interactive))
    for a in added[:room]:
        n += 1
        a["id"] = f"e{n}"
    page["actions"] = interactive + added[:room] + controls
    if first_text or last_text:
        page["text"] = "\n".join([*first_text, page.get("text") or "", *last_text]).strip()[:6000]
    if unread:
        page["unread_frames"] = unread
    return page


# --- Adaptation 34: labels are what a person reads ---------------------------
#
# Belt and braces for the <style> fix in the snapshot: a label that still carries CSS (a
# style element some framework renders as text, an aria-label built from class names) is
# cut back to its words.

SELECTOR_PART = re.compile(r"^(?:[.#@:*>+~\[]|::?)[^\s{}]*$")


def scrub_label(label):
    """`label` without CSS rule blocks (`.a > * { --x: 1 }`, cut off or not) and their selectors."""
    if not label or "{" not in label or not re.search(r"[:;]|--", label):
        return label
    out = label
    while "{" in out:
        i = out.index("{")
        j = out.find("}", i)
        tokens = out[:i].split()
        while tokens and SELECTOR_PART.match(tokens[-1]):
            tokens.pop()
        out = " ".join(tokens) + " " + (out[j + 1:] if j >= 0 else "")
    cleaned = re.sub(r"\s+", " ", out).strip(" -—")
    return cleaned or label


# --- Adaptation 35: unnamed controls -----------------------------------------
#
# A control with no name anywhere (no text, title, icon alt, test id, nothing near it) was
# offered as "button". One is a real choice ("button at top right" — an icon); a map's 30
# unlabelled pins or an icon grid are noise that splits Jev's vote, so six or more unnamed
# controls of one role are left out.

UNNAMED_CLUTTER = 6


def place_word(rect, w, h):
    if not rect or not w or not h:
        return ""
    cx, cy = rect["x"] + rect["w"] / 2, rect["y"] + rect["h"] / 2
    row = ["top", "middle", "bottom"][max(0, min(2, int(3 * cy / h)))]
    col = ["left", "center", "right"][max(0, min(2, int(3 * cx / w)))]
    return "center" if (row, col) == ("middle", "center") else f"{row} {col}" if col != "center" else row


def tidy_unnamed(page):
    actions = page.get("actions") or []
    unnamed = {}
    for a in actions:
        if a.get("kind") in INTERACTIVE and (a.get("label") or "").strip().lower() == str(a.get("role") or "").lower():
            unnamed.setdefault(a.get("role"), []).append(a)
    drop = set()
    for role, group in unnamed.items():
        if len({a.get("node") for a in group}) >= UNNAMED_CLUTTER:
            drop.update(id(a) for a in group)
        else:
            for a in group:
                where = place_word(a.get("rect"), page.get("w"), page.get("h"))
                a["label"] = f"{role} with no label" + (f" at the {where}" if where else "")
    if drop:
        page["actions"] = [a for a in actions if id(a) not in drop]
        page["omitted_unnamed"] = len(drop)
    return page


def perceive(session, info):
    """The top document's snapshot plus its frames, with labels cleaned; fingerprint recomputed."""
    for a in info.get("actions") or []:
        if a.get("label"):
            a["label"] = scrub_label(a["label"])
    try:
        results = frame_reader(session).read(info)
    except StalePage:
        raise
    except Exception:  # noqa: BLE001 — the top document alone is still a valid observation
        results = []
    if results:
        merge_frames(info, results)
        for a in info["actions"]:
            if a.get("frame") and a.get("label"):
                a["label"] = scrub_label(a["label"])
    tidy_unnamed(info)
    info["fingerprint"] = browser_module.fingerprint(info)
    return info


def frame_point(session, action):
    """Top-level click point of a frame element, hit-tested inside its frame (CLICK_POINT_JS)."""
    reader = FRAMES.get(session)
    if reader is None:
        raise StalePage("The frame is gone. Observe again.")
    fsession, context, ox, oy = reader.locate(action["frame"])
    r = cdp("Runtime.evaluate", session_id=fsession, contextId=context,
            expression=CLICK_POINT_JS + "(" + json.dumps(action) + ")", returnByValue=True)
    if r.get("exceptionDetails"):
        raise StalePage("The frame changed during evaluation")
    target = (r.get("result") or {}).get("value")
    if target is None:
        raise StalePage("Target changed or is covered. Observe again.")
    return target["x"] + ox, target["y"] + oy


def frame_select(session, action):
    reader = FRAMES.get(session)
    if reader is None:
        raise StalePage("The frame is gone. Observe again.")
    fsession, context, _, _ = reader.locate_fast(action["frame"])
    r = cdp("Runtime.evaluate", session_id=fsession, contextId=context,
            expression=SELECT_JS + "(" + json.dumps(action) + ")", returnByValue=True)
    if r.get("exceptionDetails") or not (r.get("result") or {}).get("value"):
        raise StalePage("Dropdown changed or is gone. Observe again.")


# --- Adaptation 36: a perception gap is reported, not guessed around ---------
#
# Some of what a person sees still never reaches the table: a frame that cannot be read
# (closed shadow roots, a plugin, a document still loading after every retry), a dialog that
# offers nothing but its close button, a click that visibly changed the screen while the DOM
# Jev reads stayed the same (canvas apps, video players, WebGL maps), a captcha. Jev cannot
# work around what it is not shown; it only circles. After such an observation the runner
# looks again a few times (frames load after the dialog that holds them) and, if the gap is
# still there, says so:
#
#   page["perception_gap"] = {"reason": "unreadable_frame" | "empty_dialog" | "unseen_change"
#                                       | "captcha", "detail": "<one sentence>", ...}
#   {"event": "perception_gap", "reason": …, "detail": …, "url": …, "elements": N, …}
#
# once per page (fingerprint). The run controller decides what to do with it (a vision
# takeover; for "captcha", handing the page to the user — never solving it).

GAP_RETRIES = 4
GAP_RETRY_S = 0.25
VISUAL_CHANGE_MIN = 0.12      # share of thumbnail cells that must change for "unseen_change"
CLOSER =re.compile(r"^\s*(close|dismiss|cancel|no,? thanks|not now|skip|maybe later|go back|back)\b|^\s*[×✕✖xX]\s*$", re.I)


def thumbnail_cells(jpeg_b64, cols=32, rows=20):
    """Grey thumbnail of a JPEG as a flat list, or None (no Pillow / unreadable)."""
    if not jpeg_b64:
        return None
    try:
        import base64
        import io

        from PIL import Image
        with Image.open(io.BytesIO(base64.b64decode(jpeg_b64))) as img:
            return list(img.convert("L").resize((cols, rows)).tobytes())
    except Exception:  # noqa: BLE001
        return None


def visual_change(before, after, threshold=24):
    """Share of thumbnail cells that changed by more than `threshold` grey levels (None: unknown)."""
    if not before or not after or len(before) != len(after):
        return None
    return sum(1 for a, b in zip(before, after) if abs(a - b) > threshold) / len(before)


def perception_gap(page, before=None, action=None, changed=None):
    """What the table is missing that a person would see, or None. `before` is the page the
    last action was taken on, `action` that action, `changed` the share of the screen that
    changed visually (None when unknown)."""
    unread = page.get("unread_frames") or []
    url = page.get("url") or ""
    captcha = [f for f in unread if f.get("captcha")]
    if captcha:
        return {"reason": "captcha", "detail": "A captcha is on the page; it is the user's to answer.", "frames": captcha}
    if unread:
        f = unread[0]
        host = re.sub(r"^\w+://([^/?#]+).*$", r"\1", f.get("url") or "") or "a frame"
        return {"reason": "unreadable_frame",
                "detail": f"Part of the page ({host}, {f.get('w')}×{f.get('h')}) shows content Navi cannot read.", "frames": unread}
    interactive = [a for a in page.get("actions") or [] if a.get("kind") in INTERACTIVE]
    if page.get("dialog") and interactive and all(CLOSER.search(a.get("label") or "") for a in interactive):
        return {"reason": "empty_dialog",
                "detail": f"The dialog “{page['dialog']}” offers nothing to do but close it — its content is not readable."}
    if (before is not None and action is not None and action.get("kind") in {"click", "fill", "select"}
            and not action.get("canvas") and not action.get("docs_body")
            and before.get("fingerprint") == page.get("fingerprint") and before.get("url") == url
            and changed is not None and changed >= VISUAL_CHANGE_MIN):
        return {"reason": "unseen_change",
                "detail": f"‘{(action.get('label') or '')[:60]}’ visibly changed the screen, but nothing Navi reads changed."}
    return None


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
SAME_DOCUMENT_CHECK_S = 0.15
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
            # A click that changed this document (a dialog, a menu) may still be drawing it:
            # DoorDash's item dialog animated in after the snapshot, and Jev clicked the menu
            # behind it. One quick second look; a table still changing settles like a new page.
            history = agent.state.get("history") or []
            if not history or history[-1].get("page_changed") is not True:
                return 0
            time.sleep(SAME_DOCUMENT_CHECK_S)
            try:
                probe = browser.observe(screenshot=agent.screenshots)
            except Exception:  # noqa: BLE001 — swapped mid-observe; Jev's next look handles it
                return 0
            agent.state["page"] = probe
            if probe.get("fingerprint") == page.get("fingerprint"):
                return 1
            page, observations = probe, 1
            return observations + settle_loop(agent, page, max_s)
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
    return observations + settle_loop(agent, page, max_s)


def settle_loop(agent, page, max_s):
    """Observes until the document is complete and two snapshots agree; returns how many looks."""
    browser = agent.state["browser"]
    observations = 0
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


# --- Adaptation 30: "done" needs evidence ------------------------------------
#
# Chipotle "order me a random bowl" ended "done" twice with the bowl builder still on screen
# (Jev's DONE at 27-41 %; upstream accepts any DONE). A DONE is checked before it ends the run:
# for a purchase / cart goal the page must show the item went in (a cart or bag count above
# where the run started, "added to cart/bag", or the cart / checkout page); any other DONE
# below DONE_MIN_CONFIDENCE gets one fresh look. Each page is doubted once (`retried`), so a
# run never loops on it.

DONE_MIN_CONFIDENCE = 0.5
CART_COUNT = [re.compile(r"(\d+)\s*items?\b[^\n.]{0,24}?\b(cart|bag|basket)", re.I),
              re.compile(r"\b(?:cart|bag|basket)\b\s*[:(]?\s*(\d+)\s*\)?", re.I)]
ADDED = re.compile(r"\b(added to (your |the )?(cart|bag|basket|order)|item added|in your (cart|bag|basket)|subtotal \(\d+ items?\))", re.I)
CART_URL = re.compile(r"/(cart|bag|basket|checkout)\b", re.I)
NOT_BUYING = re.compile(r"\b(track|status|where is|history|past orders?|cancel|return|refund)\b", re.I)


def is_purchase_goal(goal):
    return bool(PURCHASE_GOAL.search(goal or "")) and not NOT_BUYING.search(goal or "")


def cart_count(page):
    """The largest cart / bag count the page shows (text and control labels), else None."""
    text = (page.get("text") or "") + "\n" + "\n".join(a.get("label") or "" for a in page.get("actions", []))
    counts = []
    for rx in CART_COUNT:
        for m in rx.finditer(text):
            digits = next((g for g in m.groups() if g and g.isdigit()), None)
            if digits is not None and int(digits) < 100:
                counts.append(int(digits))
    return max(counts) if counts else None


def done_doubt(state, decision):
    """Why a DONE is not believed yet, or None."""
    page = state.get("page") or {}
    if "navi_cart_start" not in state:
        state["navi_cart_start"] = cart_count(page)
    if not decision or decision.get("operation") != "DONE":
        return None
    if is_purchase_goal(state.get("goal")):
        start, now = state.get("navi_cart_start"), cart_count(page)
        went_in = (now is not None and now > (start or 0)) or ADDED.search(page.get("text") or "") \
            or CART_URL.search(page.get("url") or "") or any(CART_URL.search(h.get("url") or "") for h in state.get("history", [])[-3:])
        if not went_in:
            return "nothing shows the item in the cart or bag yet"
    if decision.get("confidence", 1.0) < DONE_MIN_CONFIDENCE:
        return "Jev was unsure (%d%%)" % round(100 * decision.get("confidence", 0))
    return None


# --- Adaptation 40: a document that is navigating is a stale page, not an error -----
#
# Kayak (bench 2026-11-01): a click that navigated mid-step raised CDP's "Document is navigating"
# out of `tick`, and the run ended on it as an error; a Google results page did the same on the
# first look (edge-006), and "Inspected target navigated or closed" likewise. Those are the page
# moving under the runner: observe again (a short beat first), like a StalePage. Only a run of them
# with nothing in between (the tab is really gone) still ends the run.

TRANSIENT_CDP = re.compile(r"document is navigating|inspected target navigated or closed|cannot find context with specified id|"
                           r"execution context was destroyed|cannot find default execution context|no node with given id|"
                           r"could not find node with given id|node with given id does not belong to the document|"
                           r"frame with the given id was not found|target (page, context,? or browser )?(has been )?closed",
                           re.I)
MAX_TRANSIENT = 6           # in a row, with no step in between
TRANSIENT_WAIT_S = 0.35


def is_transient(exc):
    """A CDP error that only says the page moved under us ("Document is navigating")."""
    return isinstance(exc, (RuntimeError, StalePage)) and bool(TRANSIENT_CDP.search(str(exc)))


def retry_transient(fn, tries=4, wait=TRANSIENT_WAIT_S):
    """fn(), retried while it fails only because the page is navigating."""
    for attempt in range(tries):
        try:
            return fn()
        except Exception as exc:  # noqa: BLE001 — re-raised unless transient
            if not is_transient(exc) or attempt == tries - 1:
                raise
            time.sleep(wait)


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
        try:
            agent.command("predict", {})
        except (JevUnavailable, ValueError) as exc:
            # Adaptation 38: no usable answer from Jev on this page (its request failed after a
            # retry, or the answer didn't validate) — the run controller judges where it stands.
            if isinstance(exc, ValueError) and "Invalid TypeSafe response" not in str(exc):
                raise
            state["decision"] = None
            state["status"] = "ready"
            state["model_error"] = str(exc)
            return "model_error"
        decision = state["decision"]
        fingerprint = state["page"]["fingerprint"]
        doubt = done_doubt(state, decision)
        if doubt and fingerprint not in retried and len(retried) < MAX_BLOCKED_RETRIES:
            # Adaptation 30: a DONE without evidence is not the end. Jev hears why and goes on.
            retried.add(fingerprint)
            state["decision"] = None
            state["status"] = "ready"
            state["history"].append({"step": len(state["history"]) + 1, "action": "Not done yet: " + doubt, "kind": "check",
                                     "text": None, "page_changed": None, "url": state["page"].get("url")})
            emit("status", message=f"Jev said done, but {doubt} — carrying on")
            return "not_done"
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
        if RECIPIENT_NOTES and state.get("history"):
            # Jev's recent_actions carry only action/kind/text/page_changed: the result rides in the action.
            note = RECIPIENT_NOTES.pop()
            state["history"][-1]["note"] = note
            state["history"][-1]["action"] = f"{state['history'][-1].get('action', '')} → {note}"
        RECIPIENT_NOTES.clear()
        state["navi_transient"] = 0
        return "acted"
    except StalePage:
        state["decision"] = None
        state["status"] = "ready"
        state["page"] = retry_transient(lambda: state["browser"].observe(screenshot=agent.screenshots))
        state["elapsed_ms"] = round((time.perf_counter() - state["started_at"]) * 1000)
        return "stale"
    except RuntimeError as exc:
        # Adaptation 40: "Document is navigating" — the page moved under the step. Look again.
        if not is_transient(exc):
            raise
        state["navi_transient"] = state.get("navi_transient", 0) + 1
        if state["navi_transient"] > MAX_TRANSIENT:
            raise
        emit("status", message=f"The page was still changing ({str(exc)[:60]}) — looking again")
        state["decision"] = None
        if state.get("status") not in {"done", "blocked"}:
            state["status"] = "ready"
        time.sleep(TRANSIENT_WAIT_S)
        try:
            state["page"] = retry_transient(lambda: state["browser"].observe(screenshot=agent.screenshots))
        except Exception as again:  # noqa: BLE001 — the next tick observes again
            if not is_transient(again):
                raise
        if state.get("started_at"):
            state["elapsed_ms"] = round((time.perf_counter() - state["started_at"]) * 1000)
        return "stale"


# --- Adaptation 23: dialogs and app-install detours ---------------------------
#
# A modal in front (McDonald's "Order Now" → "Scan the code, download the app") hides the
# page: clicks on what is behind it are rejected, and Jev kept choosing them (5 steps, then
# the coach). The snapshot offers only the top modal's controls while one is open (patch
# above). And a web task never wants the phone app: "Open in App Store", "Download the app",
# a QR "scan the code" button took a McDonald's order to the App Store. Those are dropped
# from the table unless the goal is about an app.

APP_DETOUR = re.compile(r"\b(app store|google play|play store|download (the |our )?([\w’'.]+ )?app|get the app|open (it )?in (the )?app|"
                        r"scan (the )?(qr )?code|install (the |our )?app|use (the |our )?app)\b", re.I)
WANTS_APP = re.compile(r"\b(app store|apps?|download|install|qr)\b", re.I)


def drop_app_detours(page, goal):
    """The page without links that send the user to a phone app instead of doing the task here."""
    if WANTS_APP.search(goal or ""):
        return page
    actions = [a for a in page["actions"] if a.get("kind") not in {"click"} or not APP_DETOUR.search(a.get("label") or "")]
    return {**page, "actions": actions} if len(actions) != len(page["actions"]) else page


# --- Adaptation 27: Navi never pays; the user does ---------------------------
#
# "buy a roll of toilet paper from amazon" may reach Amazon's 'Buy Now' — one click charges the
# saved card — and the runner had nothing but playbook text against it. The buttons that
# spend money are never offered to Jev: a purchase ends with the item in the cart (or the
# checkout page) and the user places the order.

PAYS = re.compile(r"\b(buy now|buy it now|place (your |my )?order|pay now|pay \$|complete (your |my )?(purchase|order)|"
                  r"confirm (and pay|purchase|order|payment)|submit (order|payment)|place bid|purchase now|book now and pay)\b", re.I)
PURCHASE_GOAL = re.compile(r"\b(buy|purchase|order|get me|checkout|check out)\b", re.I)


def drop_payments(page):
    actions = [a for a in page["actions"] if a.get("kind") not in {"click", "fill"} or not PAYS.search(a.get("label") or "")]
    return {**page, "actions": actions} if len(actions) != len(page["actions"]) else page


# --- Adaptation 39: never sign in, sign up or detour to a partner site for the user ---
#
# Bench 2026-11-01: on Desmos ("plot y=sin(x)/x") an unsure DONE let Jev wander into the sign-up
# dialog, and the text helper typed the user's real email and first name into it (about_the_user,
# adaptation 24); on DoorDash Jev pressed "Continue with Google" three times at checkout. Signing
# in or creating an account is the user's, never Navi's, unless the goal asks for it: a sign-in /
# sign-up / log-in / "Continue with Google" control is not offered to Jev, and the identity fields
# of an account form (email, name, phone, password) are not offered either. Jev is told why
# (`account_form`), so a form in the way is closed and one the task cannot get past is BLOCKED —
# judged needs_user, which pauses the task with "Sign in … in this tab" (adaptation 37).
# And a "Compare vs. Booking.com" box (Kayak) opens another site in front of the task: such
# partner-compare / open-in-a-new-site toggles are not offered unless the goal asks to compare.

ACCOUNT_GOAL = re.compile(r"\b(sign(ing|ed)?[ -]?(in|into|up|on|out)\b|log(ging|ged)?[ -]?(in|into|on|out)\b|login|logon|signup|"
                          r"register|registration|(create|make|open|set up) (an |a |my |new )?account|my account|account settings|subscribe)",
                          re.I)
OAUTH = re.compile(r"\b(continue|sign ?(in|up)|log ?in|register|join|connect|get started)\s+(with|using|via|through)\s+"
                   r"(google|apple|facebook|microsoft|github|twitter|x|amazon|linkedin|email|e-mail|phone|sso|passkey|your)\b", re.I)
AUTH_PHRASE = re.compile(r"\b(sign ?(in|up)|log ?(in|on)|login|signup|create (an |your |a |new )?account|register|"
                         r"forgot (your )?password)\b", re.I)
IDENTITY_FIELD = re.compile(r"e-?mail|password|passcode|user ?name|first name|last name|full name|^\W*name\W*$|your name|"
                            r"phone|mobile|birthday|date of birth|continue with", re.I)
PASSWORD = re.compile(r"\bpassword\b", re.I)
ACCOUNT_NOTE = ("This page asks the user to sign in or create an account. Navi never signs in, signs up or creates an "
                "account for the user, so those controls and the form's fields are not offered. If the form is in the way, "
                "close it or go back; if the task cannot go on without the user's account, answer BLOCKED.")
PAGE_NOTES = {}             # per decision: notes for Jev's state about the page it is offered (set by `choose`)


def is_account_goal(goal):
    return bool(ACCOUNT_GOAL.search(goal or ""))


def is_auth_control(label):
    """A control that signs in, signs up or logs in: "Continue with Google", "Sign up or Login", a "Sign In"
    tab, "Continue to Sign In", "Create account" (short labels only — a sentence that mentions signing in is text)."""
    label = (label or "").split(" → ")[0].split(" — ")[0].strip()
    if not label:
        return False
    if OAUTH.search(label):
        return True
    return bool(AUTH_PHRASE.search(label)) and len(re.findall(r"[\w']+", label)) <= 6


def account_form(page):
    """Is a sign-in / sign-up form on the page? An OAuth button, a password field (or its Show Password
    toggle), or a sign-in/up control next to an identity field."""
    actions = page.get("actions") or []
    labels = [(a.get("kind"), a.get("label") or "") for a in actions]
    if any(OAUTH.search(l) for _, l in labels) or any(PASSWORD.search(l) for _, l in labels):
        return True
    return any(k in {"click", "select"} and is_auth_control(l) for k, l in labels) and \
        any(k == "fill" and IDENTITY_FIELD.search(l) for k, l in labels)


def drop_account_controls(page, goal):
    """The page without the controls that would sign the user in or up, and without the identity fields of
    an account form; `account_gate` is set when a form was there. Unchanged for a goal about signing in."""
    if is_account_goal(goal):
        return page
    form = account_form(page)

    def auth(a):
        label = a.get("label") or ""
        if a.get("kind") in {"click", "select"} and is_auth_control(label):
            return True
        return form and a.get("kind") == "fill" and bool(IDENTITY_FIELD.search(label.split(" → ")[0]))

    actions = [a for a in page["actions"] if not auth(a)]
    if len(actions) == len(page["actions"]):
        return page
    return {**page, "actions": actions, "account_gate": form}


PARTNER_DETOUR = re.compile(r"^\W*compare\b.{0,60}\b(vs\.?|versus|against|with)\s|\bcompare\b.{0,50}\b[\w-]+\.(com|net|org|co|ca|de|fr|es|it)\b|"
                            r"\b(open|show|search|view)\b.{0,40}\b(in|on) (a )?(new|separate) (tab|window|site)\b|"
                            r"\bopens? (in )?(a )?(new|separate) (tab|window)\b", re.I)
TOGGLE_KINDS = {"checkbox", "switch", "radio", "menuitemcheckbox"}


def is_partner_detour(label, role=""):
    """A toggle that opens another site's results next to (or instead of) the task's: Kayak's "Compare vs.
    KAYAK Booking.com", "Open results in a new window"."""
    return (role or "").lower() in TOGGLE_KINDS and bool(PARTNER_DETOUR.search(label or ""))


def drop_partner_detours(page, goal):
    if re.search(r"\bcompar", goal or "", re.I):
        return page
    actions = [a for a in page["actions"] if a.get("kind") not in {"click", "select"}
               or not is_partner_detour(a.get("label"), a.get("role"))]
    return {**page, "actions": actions} if len(actions) != len(page["actions"]) else page


def with_page_notes(post):
    """Jev's request carries the notes `choose` left for the page it is deciding on (`account_form`)."""
    def post_json(url, key, body):
        if PAGE_NOTES and isinstance(body, dict) and "questions" in body and isinstance(body.get("state"), dict) \
                and "elements" in body["state"]:
            body = {**body, "state": {**body["state"], **PAGE_NOTES}}
        return post(url, key, body)
    return post_json


# --- Adaptation 24: the user's own details for their own errands -------------
#
# "Order me a burger" needs a delivery address; the text helper is told never to invent
# personal information, so a ZIP / address field got {"text": null} and the run stalled.
# Navi passes the user's own contact card (NAVI_USER_PROFILE_JSON: name, address, city,
# ZIP, phone, email — only what the card has); the helper sees it only for a field that
# asks for one of those, never in Jev's state.

PERSONAL_FIELD = re.compile(r"address|street|zip|postal|post ?code|city|town|location|deliver|state|"
                            r"\bname\b|phone|mobile|e-?mail|where", re.I)
TEXT_ADDENDUM = ("When present, about_the_user holds the user's own details from their contact card: use them for "
                 "their address, ZIP, city, name, phone or email on their own errands (that is not inventing). "
                 "A search box takes the key words of what the goal is looking for; do not return null for one.")


def user_profile():
    try:
        profile = json.loads(os.environ.get("NAVI_USER_PROFILE_JSON") or "{}")
    except ValueError:
        return {}
    return {k: v for k, v in profile.items() if isinstance(v, str) and v.strip()} if isinstance(profile, dict) else {}


ACCOUNT_FORM_TEXT = re.compile(r"\b(password|create (an |your )?account|sign ?up|sign up with|forgot (your )?password)\b", re.I)


def account_form_field(context):
    """Is this field one of a sign-in / sign-up form's identity fields (adaptation 39)? Its own label says
    email / name / phone / password, and the page shows an account form (an OAuth button, a password,
    "create account", "sign up")."""
    field = context.get("field") or {}
    label = str(field.get("label") or "")
    if not IDENTITY_FIELD.search(label):
        return False
    text = f"{label}\n{(context.get('page') or {}).get('title') or ''}\n{(context.get('page') or {}).get('text') or ''}"
    return bool(OAUTH.search(text) or ACCOUNT_FORM_TEXT.search(text))


def with_user_details(context, profile=None):
    """The helper's context plus about_the_user, for a field that asks for the user's own details — never
    for a sign-up / sign-in form's fields unless the goal is to sign in or up (adaptation 39)."""
    profile = user_profile() if profile is None else profile
    if not profile or not isinstance(context, dict):
        return context
    field = context.get("field") or {}
    if not PERSONAL_FIELD.search(f"{field.get('label') or ''} {field.get('role') or ''}"):
        return context
    if account_form_field(context) and not is_account_goal(context.get("goal")):
        return context
    return {**context, "about_the_user": profile}


def install_adaptations():
    if navi_cloud():
        jev_model.post_json = post_json_navi
        # Upstream reads TYPESAFE_API_KEY unconditionally; give it a placeholder (never sent).
        os.environ["TYPESAFE_API_KEY"] = "via-navi-cloud"
    elif os.environ.get("NAVI_JEV_TRANSPORT") == "navi":
        raise CloudError("Sign in to Navi to run browser tasks.", code="signed_out")
    elif os.environ.get("NAVI_JEV_TRANSPORT") == "vercel":
        jev_model.post_json = post_json_vercel
        # Upstream reads TYPESAFE_API_KEY unconditionally; give it a placeholder.
        os.environ.setdefault("TYPESAFE_API_KEY", "via-vercel-gateway")
    else:
        jev_model.post_json = post_json_typesafe
    # The takeover's irreversible gate asks Jev plain nouls: transport only, no playbook/coach layers.
    RAW_JEV_POST[0] = jev_model.post_json
    # Adaptation 38: innermost layer, so it sizes the request the playbook/context/coach layers built.
    jev_model.post_json = guarded_jev(jev_model.post_json)
    # Adaptation 39: the page's notes (an account form Jev is not offered) ride in the state.
    jev_model.post_json = with_page_notes(jev_model.post_json)
    import jev_ultrafast.agent as agent_module

    use_claude = navi_cloud() is not None or (not os.environ.get("TEXT_MODEL_API_KEY") and os.environ.get("ANTHROPIC_API_KEY"))
    helper = field_text_claude if use_claude else jev_model.field_text
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
        page = drop_payments(drop_app_detours(rejected.filter(page), goal))
        # Adaptation 39: never the user's sign-in / sign-up, never a partner site's compare box.
        page = drop_partner_detours(drop_account_controls(page, goal), goal)
        PAGE_NOTES.clear()
        if page.get("account_gate"):
            PAGE_NOTES["account_form"] = ACCOUNT_NOTE
        speculative.speculate(goal, page, history)
        try:
            return original_choose(page, goal, history)
        except JevTooLarge:
            # Adaptation 38: even the shortest version was refused — fewer controls, once.
            fewer = fewer_actions(page, goal)
            if fewer is page:
                raise
            emit("status", message=f"Too much on this page for one look — showing Jev the {TRIMMED_ACTIONS} likeliest controls")
            return original_choose(fewer, goal, history)

    agent_module.choose = choose
    return speculative, rejected


# --- Run --------------------------------------------------------------------

def summarize(history, status):
    if not history:
        return "No actions were taken." if status == "blocked" else "Nothing to do."
    parts = []
    for h in [h for h in history if h["kind"] not in {"coach", "check"}][-6:]:
        if h["kind"] == "fill" and h.get("text"):
            parts.append(f"typed “{h['text'][:40]}” into {h['action'].split(' → ')[0]}")
        elif h["kind"] == "wait":
            parts.append("waited")
        elif h["kind"] == "takeover":
            parts.append(h["action"])
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


def selftest():
    """`--version` / `--selftest`: prove this interpreter can run a browser task —
    every dependency imports — without touching Chrome or the network. Prints one
    JSON object; exit 0 when everything imported. Used by scripts/dev/runtime-smoke.sh
    and by Navi's Settings → Browser tasks status for the bundled runtime."""
    import importlib
    import platform

    info = {
        "python": platform.python_version(),
        "executable": sys.executable,
        "runner": os.path.abspath(__file__),
        "bundled": "/Contents/Resources/browser-runtime/" in os.path.abspath(__file__),
        "modules": {},
    }
    ok = True
    for name in ("jev_ultrafast", "jev_ultrafast.agent", "jev_ultrafast.browser", "jev_ultrafast.model",
                 "jev_ultrafast.questions", "browser_harness", "browser_harness.admin", "browser_harness.helpers",
                 "browser_harness.run", "cdp_use", "httpx", "h2", "websockets", "certifi", "ssl"):
        try:
            mod = importlib.import_module(name)
            info["modules"][name] = getattr(mod, "__version__", "ok")
        except Exception as exc:  # noqa: BLE001 — report every failure, not the first
            info["modules"][name] = f"ERROR: {exc}"
            ok = False
    try:
        import importlib.metadata as metadata

        info["browser_harness"] = metadata.version("browser-harness")
    except Exception:  # noqa: BLE001 — dist-info stripped; not fatal
        pass
    info["ok"] = ok
    print(json.dumps(info))
    return 0 if ok else 1


def purchase_note(goal, status):
    """A finished purchase task: say the order is the user's to place (adaptation 27)."""
    return "Ready for you to place the order — Navi never pays. " if status == "done" and PURCHASE_GOAL.search(goal or "") else ""


def acted_on_page(history):
    """Did any step do something on the page? Claude's coaching notes and waits act on nothing."""
    return any(h.get("kind") not in {"coach", "wait", "WAIT", "check"} for h in history)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url")
    parser.add_argument("--goal")
    parser.add_argument("--screenshots", action="store_true")
    parser.add_argument("--max-steps", type=int, default=0)
    parser.add_argument("--version", "--selftest", dest="selftest", action="store_true",
                        help="print the runtime's Python + dependency status as JSON and exit")
    args = parser.parse_args()
    if args.selftest:
        return selftest()
    if not args.url or not args.goal:
        parser.error("--url and --goal are required")

    try:
        speculative, rejected = install_adaptations()
    except CloudError as exc:
        emit("error", message=str(exc), **exc.fields)
        return 2
    playbook = Playbook(goal=args.goal)
    playbook.install()
    UserMoves().install()
    UserRoute().install()
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
    asked_user = False
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
                # The summary reaches the user's panel; the engine detail is in the status log.
                emit("status", message=f"Still failing after Claude's guidance ({why})")
                return ("blocked", f"Stopped: still stuck after a second look. {coach.diagnosis}")
            emit("status", message=f"Jev is struggling ({why}) — asking Claude to diagnose")
            shot = None
            try:
                # `state` is a snapshot (no browser in it); the live agent has the tab.
                shot = agent.state["browser"].observe(screenshot=True).get("screenshot")
            except Exception:  # noqa: BLE001 — coaching works without the picture
                pass
            try:
                ms = coach.ask(state["goal"], state["page"], state["history"], why, shot)
            except CloudError:
                raise           # signed out / over the plan: Navi words it (adaptation 20)
            except Exception as exc:  # noqa: BLE001
                emit("status", message=f"Jev keeps failing ({why}) and Claude's diagnosis was unavailable: {exc}")
                return ("blocked", "Stopped: stuck on this page.")
            emit("status", message=f"Claude · {ms} ms · {coach.diagnosis}")
            emit("guidance", text=coach.guidance)
            # A coaching entry breaks the no-change window so the stuck rule restarts.
            state["history"].append({"step": len(state["history"]) + 1, "action": "Claude guidance: " + coach.guidance[:200],
                                     "kind": "coach", "text": None, "page_changed": True, "url": state["page"]["url"]})
            # The snapshot's status is a copy: reset the live one too, or a
            # BLOCKED-triggered coaching ends `run_until_stop` with no "done" event.
            state["status"] = agent.state["status"] = "ready"
            return None

        takeover = Takeover()
        gaps_escalated = set()   # (url, reason) of perception gaps already handed to Claude
        takeover_mark = [0]       # history length when the last takeover ended

        def record_step(entry):
            """A step the takeover took: in the history Jev reads, and on Navi's timeline now."""
            nonlocal seen_steps
            history = agent.state["history"]
            elapsed = round((time.perf_counter() - agent.state["started_at"]) * 1000) if agent.state.get("started_at") else 0
            history.append({"step": len(history) + 1, "page_changed": None, "elapsed_ms": elapsed, **entry})
            for h in history[seen_steps:]:
                emit("step", step=h["step"], action=h["action"], kind=h["kind"], text=h.get("text"),
                     page_changed=h.get("page_changed"), url=h.get("url"), elapsed_ms=h.get("elapsed_ms"), note=h.get("note"))
            seen_steps = len(history)

        def look(why):
            """A typed judgment of the page as it is now (None when Claude can't be asked)."""
            if claude_endpoint() is None:
                return None
            shot = None
            # A dialog that just opened may still be drawing (DoorDash's sign-in read "still loading").
            time.sleep(JUDGE_SETTLE_S)
            try:
                agent.state["page"] = agent.state["browser"].observe(screenshot=False)
            except Exception:  # noqa: BLE001 — judge the last observation
                pass
            try:
                shot, _ = viewport_shot(agent.state["browser"])
            except Exception:  # noqa: BLE001 — the judge reads the page text without the picture
                pass
            try:
                verdict = judge(args.goal, agent.state["page"], agent.state["history"], why, shot)
            except CloudError:
                raise
            except Exception as exc:  # noqa: BLE001
                emit("status", message=f"Couldn't check the page with Claude ({exc})")
                return None
            emit("status", message=f"Checked the page: {verdict['verdict'].replace('_', ' ')} — {verdict['answer'][:200]}")
            return verdict

        def resume():
            agent.state["status"] = "ready"
            agent.state["decision"] = None

        def escalate(state, why, verdict=None):
            """Jev stopped short (stuck, BLOCKED, or an unsure DONE): judge where the run stands, then
            finish it, end it honestly, or let Claude drive. Returns (stop or None, verdict)."""
            if verdict is None:
                verdict = look(why)
            acted = any(h.get("kind") not in {"takeover", "coach", "check", "wait"}
                        for h in agent.state["history"][takeover_mark[0]:]) or takeover.count == 0
            move = escalation(verdict, takeover.available(), acted)
            if move == "done":
                return ("done", verdict["answer"]), verdict
            if move == "end":
                return ("blocked", (verdict or {}).get("answer") or "Stopped: stuck on this page."), verdict
            if move == "coach":
                return coach_or_stop(state, why), None
            emit("status", message=f"Jev is stuck ({why}) — Claude takes over for a few steps")
            started = time.perf_counter()
            try:
                res = takeover.run(agent, args.goal, why, verdict, record_step)
            except CloudError:
                raise
            except Exception as exc:  # noqa: BLE001
                emit("status", message=f"Claude's takeover failed: {exc}")
                return ("blocked", (verdict or {}).get("answer") or "Stopped: stuck on this page."), verdict
            takeover_mark[0] = len(agent.state["history"])
            emit("status", message=f"Claude's takeover ended ({res['result']}, {res['actions']} actions, "
                                   f"{round(time.perf_counter() - started)} s): {res['summary'][:200]}")
            try:
                agent.state["page"] = agent.state["browser"].observe(screenshot=agent.screenshots)
                settle_page(agent)
            except Exception:  # noqa: BLE001 — the next tick observes again
                pass
            coach.current_url = playbook.current_url = agent.state["page"].get("url")
            if res["result"] == "stopped":
                stopped = {"verdict": "needs_user", "answer": res["summary"], "next_step": ""}
                # Adaptation 37: Claude's "Stopped: …" becomes a question for the user — the judge words it
                # (a choice with the page's options, or what to do on screen); its own words otherwise.
                checked = look("Claude, driving, stopped: " + (res["summary"] or "(nothing)"))
                if checked and checked["verdict"] == "needs_user" and checked.get("question"):
                    stopped = dict(checked, answer=checked["answer"] or res["summary"])
                return ("blocked", res["summary"]), stopped
            if res["result"] in {"done", "no_progress"}:
                # Claude's "Done" — or a reply with no action, which is its read of the page ("the
                # Google option is clearly visible") — is checked on a fresh look, never taken on trust.
                checked = look("Claude, driving, says: " + (res["summary"] or "(nothing)"))
                if checked is None:
                    if res["result"] == "done":
                        return ("done", res["summary"]), {"verdict": "achieved", "answer": res["summary"], "next_step": "", "judged": False}
                    return ("blocked", (verdict or {}).get("answer") or "Stopped: stuck on this page."), verdict
                if checked["verdict"] == "achieved":
                    return ("done", checked["answer"]), checked
                if checked["verdict"] in {"impossible", "needs_user"} or res["result"] == "no_progress":
                    return ("blocked", checked["answer"]), checked
                verdict = checked
            emit("status", message="Back to Jev from here")
            resume()
            return None, verdict

        retried_blocked = set()
        early_block_exit = os.environ.get("NAVI_EARLY_BLOCK_EXIT") == "1"

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
                if recent[i].get("kind") in {"coach", "takeover"}:
                    recent = recent[i + 1:]
                    break
            why = None
            verdict = None
            model_error = agent.state.pop("model_error", None)
            if model_error:
                # Adaptation 38: Jev couldn't be asked here. Judge the page (the cart may already be
                # full) and let Claude drive if it isn't there yet, instead of ending on a raw error.
                why = model_error
            elif state["status"] == "blocked" and early_block_exit and not acted_on_page(state["history"]):
                # Nothing for this task on the page it started on (an unrelated tab): Navi starts
                # over where the task itself starts — no Claude diagnosis of the wrong page.
                emit("status", message="Nothing to do for this on this page")
                stop = ("blocked", "Stopped: nothing to do for this on this page.")
                verdict = {"verdict": "not_achieved", "answer": "", "next_step": ""}
            elif state["status"] == "blocked":
                why = Coach.flailing(recent) or "Jev answered BLOCKED"
            elif state["status"] == "ready":
                why = Coach.flailing(recent)
                # Adaptation 36 → 32: what Jev is offered misses what is on screen (a dialog with
                # nothing readable, a frame that won't read, a click that only changed pixels) —
                # Claude looks at the picture instead of Jev guessing from an incomplete table.
                # Once per page and reason; a captcha is the user's.
                gap = state["page"].get("perception_gap") if not why else None
                if gap:
                    key = (state["page"].get("url"), gap.get("reason"))
                    if gap.get("reason") == "captcha":
                        stop = ("blocked", "Stopped: this page wants you to prove you're human — that one's yours.")
                        verdict = {"verdict": "needs_user", "answer": stop[1], "next_step": ""}
                    elif key not in gaps_escalated:
                        gaps_escalated.add(key)
                        why = f"Jev can't see part of the page ({gap.get('reason')}: {str(gap.get('detail') or '')[:120]})"
            elif state["status"] == "done":
                # Adaptation 32: an unsure DONE is judged; "not there yet" goes on (takeover) instead of ending.
                last = state["decisions"][-1] if state["decisions"] else {}
                if should_judge_done(last.get("confidence")):
                    verdict = look("Jev judged the goal done (%d%% sure)" % round(100 * (last.get("confidence") or 0)))
                    if verdict and verdict["verdict"] != "achieved":
                        why = "Jev said done, but " + (verdict["answer"][:160] or "the page does not show it")
                        if verdict["verdict"] in {"impossible", "needs_user"}:
                            stop = ("blocked", verdict["answer"])
                            why = None
            if why:
                stop, verdict = escalate(state, why, verdict)
                if stop is None:
                    continue
            if state["status"] in {"done", "blocked"} or stop:
                status = stop[0] if stop else state["status"]
                final_status, final_steps = status, len(state["history"])
                if status == "done" and policy == "reveal":
                    reveal_tab(agent)
                if verdict is None:
                    verdict = {"verdict": "achieved" if status == "done" else "not_achieved", "answer": "", "next_step": "", "judged": False}
                summary = stop[1] if stop and stop[1] else (verdict.get("answer") or summarize(state["history"], status))
                if status == "done":
                    summary = purchase_note(args.goal, status) + summary
                # Adaptation 37: a stop only the user can unblock is a question; the tab stays for the rerun,
                # and something to do on it ("sign in") brings it forward.
                ask = user_question(verdict, args.goal, status)
                if ask:
                    asked_user = True
                    if ask["question_kind"] == "do_it":
                        reveal_tab(agent)
                emit(
                    "done",
                    **(ask or {}),
                    tab=getattr(agent.state.get("browser"), "target", None),
                    status=status,
                    outcome=verdict["verdict"],
                    answer=verdict.get("answer") or "",
                    next_step=verdict.get("next_step") or "",
                    judged=verdict.get("judged", True),
                    takeovers=takeover.count,
                    elapsed_ms=round((time.perf_counter() - agent.state["started_at"]) * 1000) if agent.state.get("started_at") else state["elapsed_ms"],
                    steps=len(state["history"]),
                    summary=summary,
                    url=agent.state["page"]["url"],
                    title=agent.state["page"].get("title", ""),
                    page_text=(agent.state["page"].get("text") or "")[:6000],
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
        message = str(exc)
        if "demo budget" in message:
            # Upstream's step limit ("Stopped at the 40-action demo budget") reaches the user's panel.
            message = f"Stopped after {final_steps} step{'s' if final_steps != 1 else ''} without finishing — the step limit was reached."
        emit("error", message=message, **getattr(exc, "fields", {}))
        return 1
    finally:
        # The tab is what the user asked for ("make a Google Doc"): it stays open
        # unless nothing happened on it, or a background lookup completed.
        if not asked_user and should_close_tab(policy, final_status, final_steps):
            try:
                agent.close()
            except Exception:  # noqa: BLE001
                pass


if __name__ == "__main__":
    sys.exit(main())
