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
"""

import argparse
import json
import math
import os
import sys
import threading
import time
from concurrent.futures import Future

import httpx

from jev_ultrafast import Agent, model as jev_model
from jev_ultrafast.browser import Browser
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

def field_text_claude(context):
    """Same contract as upstream field_text, using the Anthropic Messages API."""
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        raise ValueError("TYPE_TEXT needs ANTHROPIC_API_KEY or TEXT_MODEL_API_KEY; nothing typed.")
    model = os.environ.get("NAVI_TEXT_MODEL", "claude-haiku-4-5")
    base = os.environ.get("ANTHROPIC_BASE_URL", "https://api.anthropic.com").rstrip("/")
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
        self.target = cdp("Target.createTarget", url="about:blank", background=True)["targetId"]
        self.session = cdp("Target.attachToTarget", targetId=self.target, flatten=True)["sessionId"]
        self.call("Emulation.setDeviceMetricsOverride", width=1120, height=780, deviceScaleFactor=1, mobile=False)
        self.call("Emulation.setFocusEmulationEnabled", enabled=True)
        self.call("Page.navigate", url=url)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            try:
                if self.evaluate("document.readyState") in self.READY:
                    break
            except Exception:  # noqa: BLE001 — document swapped mid-evaluate
                pass
            time.sleep(0.02)


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
    original_choose = agent_module.choose

    def choose(page, goal, history):
        speculative.speculate(goal, page, history)
        return original_choose(page, goal, history)

    agent_module.choose = choose
    return speculative


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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--goal", required=True)
    parser.add_argument("--screenshots", action="store_true")
    parser.add_argument("--max-steps", type=int, default=0)
    args = parser.parse_args()

    speculative = install_adaptations()
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
    try:
        page = agent.state["page"]
        emit("ready", elements=len(agent.snapshot()["elements"]), url=page["url"], title=page["title"])
        if args.screenshots and page.get("screenshot"):
            emit("screenshot", jpeg_base64=page["screenshot"])
        seen_steps = 0
        seen_decisions = 0
        for state in agent.run():
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
                )
            seen_steps = len(state["history"])
            if args.screenshots and state["page"].get("screenshot"):
                emit("screenshot", jpeg_base64=state["page"]["screenshot"])
            if state["status"] in {"done", "blocked"}:
                emit(
                    "done",
                    status=state["status"],
                    elapsed_ms=state["elapsed_ms"],
                    steps=len(state["history"]),
                    summary=summarize(state["history"], state["status"]),
                    url=state["page"]["url"],
                    speculative_text=speculative.stats,
                )
        return 0
    except KeyboardInterrupt:
        emit("done", status="cancelled", elapsed_ms=agent.state.get("elapsed_ms", 0),
             steps=len(agent.state["history"]), summary="Cancelled.")
        return 130
    except Exception as exc:  # noqa: BLE001
        emit("error", message=str(exc))
        return 1
    finally:
        if not os.environ.get("NAVI_KEEP_TAB"):
            try:
                agent.close()
            except Exception:  # noqa: BLE001
                pass


if __name__ == "__main__":
    sys.exit(main())
