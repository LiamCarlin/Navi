"""Perception fixtures in a real Chrome: what the runner offers Jev from frames, shadow roots,
dialogs and overlays (adaptations 33–36).

Starts a private headless Chrome (temporary profile, never the user's) and two local servers
on different sites (127.0.0.1 and localhost), so a cross-site <iframe> is out of process
exactly like identity.doordash.com in DoorDash's sign-in dialog. Skips when Chrome is absent.

  cd vendor/jev-ultrafast && PYTHONPATH=. ~/Navi/vendor/jev-ultrafast/.venv/bin/python \\
      ../../scripts/ultrafast/test_perception_chrome.py
"""
import http.server
import itertools
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ.setdefault("AI_GATEWAY_API_KEY", "vck_test")
os.environ.setdefault("NAVI_JEV_TRANSPORT", "vercel")

CHROME = os.environ.get("NAVI_TEST_CHROME", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
if not os.path.exists(CHROME):
    print("perception fixtures skipped: no Chrome at", CHROME)
    sys.exit(0)

from websockets.sync.client import connect  # noqa: E402

import navi_runner as nr  # noqa: E402
from jev_ultrafast import browser as browser_module  # noqa: E402


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class LocalChrome:
    """Headless Chrome with a throwaway profile and a minimal synchronous CDP client."""

    def __init__(self):
        self.profile = tempfile.mkdtemp(prefix="navi-perception-")
        self.port = free_port()
        self.proc = subprocess.Popen([CHROME, "--headless=new", f"--remote-debugging-port={self.port}",
                                      f"--user-data-dir={self.profile}", "--no-first-run", "--no-default-browser-check",
                                      "--site-per-process", "--window-size=1120,780", "about:blank"],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.time() + 20
        while True:
            try:
                info = json.load(urllib.request.urlopen(f"http://127.0.0.1:{self.port}/json/version", timeout=1))
                break
            except Exception:  # noqa: BLE001
                if time.time() > deadline:
                    raise
                time.sleep(0.1)
        self.ws = connect(info["webSocketDebuggerUrl"], max_size=None)
        self.ids = itertools.count(1)
        self.lock = threading.Lock()

    def cdp(self, method, session_id=None, **params):
        with self.lock:
            i = next(self.ids)
            msg = {"id": i, "method": method, "params": params}
            if session_id:
                msg["sessionId"] = session_id
            self.ws.send(json.dumps(msg))
            while True:
                r = json.loads(self.ws.recv())
                if r.get("id") == i:
                    if "error" in r:
                        raise RuntimeError(r["error"])
                    return r.get("result", {})

    def close(self):
        try:
            self.ws.close()
        except Exception:  # noqa: BLE001
            pass
        self.proc.terminate()
        try:
            self.proc.wait(5)
        except Exception:  # noqa: BLE001
            self.proc.kill()
        shutil.rmtree(self.profile, ignore_errors=True)


A, B = free_port(), free_port()          # 127.0.0.1:A is the page's site, localhost:B another site
OTHER = f"http://localhost:{B}"
PAGES = {
    # DoorDash's sign-in: an aria-modal dialog whose content is a cross-site iframe.
    "/doordash": f"""<body style="margin:0"><button id=behind style="position:absolute;left:20px;top:20px">Sign In</button>
      <div style="position:fixed;inset:0;background:rgba(0,0,0,.5)"></div>
      <div role=dialog aria-modal=true aria-label="Sign in or Sign up" style="position:fixed;left:280px;top:100px;width:560px;height:600px;background:#fff">
        <button aria-label="Close Sign in or Sign up">×</button>
        <iframe title="Login/Signup" src="{OTHER}/login" style="display:block;width:540px;height:540px;border:0;margin:4px"></iframe>
      </div></body>""",
    "/login": """<body><h2>Sign in or Sign up</h2><button onclick="document.title='google clicked'">Continue with Google</button>
      <input aria-label="Email" style="display:block;margin-top:20px"></body>""",
    # A same-origin frame on a plain page (no dialog), next to a frame an overlay covers.
    "/frames": f"""<body style="margin:0"><button>Top button</button>
      <iframe src="/inner" style="position:absolute;left:10px;top:60px;width:400px;height:200px;border:0"></iframe>
      <iframe src="{OTHER}/covered" style="position:absolute;left:500px;top:60px;width:400px;height:200px;border:0"></iframe>
      <div style="position:absolute;left:480px;top:40px;width:460px;height:260px;background:#eee;z-index:5">A banner on top</div></body>""",
    "/inner": "<body><a href='#more'>Same-origin link</a></body>",
    "/covered": "<body><button>Covered frame button</button></body>",
    # A dialog in an open shadow root.
    "/shadow": """<body><button id=b>Behind the shadow dialog</button><x-modal></x-modal><script>
      const host=document.querySelector('x-modal'), root=host.attachShadow({mode:'open'});
      root.innerHTML='<div style="position:fixed;inset:0;background:rgba(0,0,0,.4)"></div>'+
        '<div role=dialog aria-modal=true aria-labelledby=t style="position:fixed;left:300px;top:200px;width:400px;height:200px;background:#fff">'+
        '<h3 id=t>Cookies</h3><button onclick="document.title=\\'accepted\\'">Accept all</button><button>Reject all</button></div>';
      </script></body>""",
    # A full-screen overlay with no ARIA at all, plus a <style> inside a button.
    "/overlay": """<body><p>Menu text behind</p><button>Behind overlay</button>
      <div style="position:fixed;inset:0;background:rgba(0,0,0,.6);z-index:100;display:flex;align-items:center;justify-content:center">
        <div style="background:#fff;padding:20px"><p>Choose your size</p>
          <button><style>.prism-size-msf7vl > * { --prism-inline-children-spacing: var(--x); }</style>Large · $9.99</button>
        </div></div></body>""",
    # A dialog whose content frame shows nothing readable (a widget in a closed shadow root).
    "/emptydialog": f"""<body><div role=dialog aria-modal=true aria-label="Pay" style="position:fixed;left:200px;top:80px;width:600px;height:560px;background:#fff">
      <button>Close</button><iframe src="{OTHER}/closed" style="width:560px;height:480px;border:0"></iframe></div></body>""",
    "/closed": """<body style='margin:0'><x-pay style="display:block;width:500px;height:400px"></x-pay><script>
      document.querySelector('x-pay').attachShadow({mode:'closed'}).innerHTML='<button>Pay now</button><p>Card number</p>';
      </script></body>""",
    # A captcha frame (never offered) and an invisible reCAPTCHA badge (ignored).
    "/captcha": f"""<body><button>Submit</button>
      <iframe src="{OTHER}/recaptcha/api2/anchor?k=x&size=normal" style="width:320px;height:90px;border:0"></iframe>
      <iframe src="{OTHER}/recaptcha/api2/anchor?k=x&size=invisible" style="width:256px;height:60px;border:0"></iframe></body>""",
    "/recaptcha/api2/anchor": "<body><span role=checkbox tabindex=0 aria-checked=false>I'm not a robot</span></body>",
    # Unnamed controls: eight map pins (noise) and one unnamed icon link.
    "/unnamed": """<body style="margin:0"><div id=map style="position:relative;width:600px;height:400px"></div>
      <a href="#menu" style="position:absolute;right:10px;top:10px;width:30px;height:30px;display:block"></a>
      <script>for (let i=0;i<8;i++){const b=document.createElement('button');b.style.cssText=
      'position:absolute;width:20px;height:20px;left:'+(40+i*60)+'px;top:'+(100+i*20)+'px';document.getElementById('map').appendChild(b);}</script></body>""",
    # A click whose effect is only pixels (a canvas too flat to be offered as one).
    "/pixels": """<body style="margin:0;background:#fff"><button onclick="const c=document.querySelector('canvas').getContext('2d');
      c.fillStyle=(window.k=!window.k)?'#000':'#fff';c.fillRect(0,0,1100,119)">Paint</button><canvas width=1100 height=119 style="display:block"></canvas></body>""",
}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = PAGES.get(self.path.split("?")[0])
        self.send_response(200 if body else 404)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write((body or "not found").encode())

    def log_message(self, *args):
        pass


for port in (A, B):
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()

chrome = LocalChrome()
nr.cdp = chrome.cdp
browser_module.cdp = chrome.cdp
nr.install_adaptations()


def open_page(path):
    target = chrome.cdp("Target.createTarget", url="about:blank")["targetId"]
    session = chrome.cdp("Target.attachToTarget", targetId=target, flatten=True)["sessionId"]
    chrome.cdp("Emulation.setDeviceMetricsOverride", session_id=session, width=1120, height=780, deviceScaleFactor=1, mobile=False)
    chrome.cdp("Page.navigate", session_id=session, url=f"http://127.0.0.1:{A}{path}")
    for _ in range(100):
        if chrome.cdp("Runtime.evaluate", session_id=session, expression="document.readyState",
                      returnByValue=True)["result"].get("value") == "complete":
            break
        time.sleep(0.05)
    time.sleep(0.4)       # frames finish loading
    return target, session


def observe(session):
    return nr.browser_operation_navi({"operation": "observe", "session": session, "screenshot": False})


def labels(page):
    return [a["label"] for a in page["actions"] if a["kind"] in nr.INTERACTIVE]


def find(page, label, kind="click"):
    return next(a for a in page["actions"] if a["kind"] == kind and a["label"] == label)


try:
    # --- DoorDash: the dialog's iframe is part of the table (adaptation 33) ---
    target, s = open_page("/doordash")
    page = observe(s)
    got = labels(page)
    assert "Close Sign in or Sign up" in got and "Continue with Google" in got and "Email" in got, got
    assert "Sign In" not in got, got                                  # behind the dialog
    google = find(page, "Continue with Google")
    assert google.get("frame") and google["node"] > nr.FRAME_NODE_BASE, google
    assert 280 < google["rect"]["x"] < 840 and google["rect"]["y"] > 100, google["rect"]   # top-level coordinates
    assert page["dialog"] == "Sign in or Sign up" and page["text"].startswith("Sign in or Sign up"), page["text"][:80]
    assert nr.FRAMES[s].last[google["frame"]].get("context")
    # Clicking it reaches the button inside the cross-site frame.
    nr.browser_operation_navi({"operation": "act", "session": s, "action": google, "text": None})
    time.sleep(0.2)
    page = observe(s)
    oopif = nr.FRAMES[s].last[google["frame"]]
    title = chrome.cdp("Runtime.evaluate", session_id=oopif["session"], contextId=oopif["context"],
                       expression="document.title", returnByValue=True)["result"]["value"]
    assert title == "google clicked", title
    # Typing goes into the frame's field.
    email = find(page, "Email", "fill")
    nr.browser_operation_navi({"operation": "act", "session": s, "action": email, "text": "me@example.com"})
    value = chrome.cdp("Runtime.evaluate", session_id=oopif["session"], contextId=oopif["context"],
                       expression="document.querySelector('input').value", returnByValue=True)["result"]["value"]
    assert value == "me@example.com", value
    # Freshness of a frame element is judged in its own frame.
    fb = object.__new__(nr.FastBrowser)
    fb.session = s
    page = observe(s)
    google = find(page, "Continue with Google")
    assert fb.fresh(page, google)
    stale = dict(page, guards={**page["guards"], str(google["node"]): ["x"]})
    assert not fb.fresh(stale, google)
    chrome.cdp("Target.closeTarget", targetId=target)
    print("iframe dialog (DoorDash) ok")

    # --- frames on a plain page: same-origin kept, covered one left out ---
    target, s = open_page("/frames")
    got = labels(observe(s))
    assert "Top button" in got and "Same-origin link" in got, got
    assert "Covered frame button" not in got, got
    chrome.cdp("Target.closeTarget", targetId=target)
    print("same-origin and covered frames ok")

    # --- a dialog inside an open shadow root (adaptation 34) ---
    target, s = open_page("/shadow")
    page = observe(s)
    got = labels(page)
    assert "Accept all" in got and "Reject all" in got and "Behind the shadow dialog" not in got, got
    assert page["dialog"] == "Cookies", page["dialog"]
    nr.browser_operation_navi({"operation": "act", "session": s, "action": find(page, "Accept all"), "text": None})
    assert chrome.cdp("Runtime.evaluate", session_id=s, expression="document.title", returnByValue=True)["result"]["value"] == "accepted"
    chrome.cdp("Target.closeTarget", targetId=target)
    print("shadow dialog ok")

    # --- an overlay with no ARIA; <style> text never in a label (adaptations 34/35) ---
    target, s = open_page("/overlay")
    page = observe(s)
    got = labels(page)
    assert got == ["Large · $9.99"], got
    assert page["dialog"] == "Choose your size" and page["text"].startswith("Choose your size"), (page["dialog"], page["text"][:60])
    chrome.cdp("Target.closeTarget", targetId=target)
    print("overlay and style text ok")

    # --- perception gaps (adaptation 36) ---
    target, s = open_page("/emptydialog")
    page = observe(s)
    gap = nr.perception_gap(page)
    assert gap and gap["reason"] == "unreadable_frame" and "localhost" in gap["detail"], gap
    fb = object.__new__(nr.FastBrowser)
    fb.session, fb.target, fb.screenshots = s, target, False
    nr.GAP_RETRY_S = 0.01
    page = fb.observe(screenshot=False)
    assert page["perception_gap"]["reason"] == "unreadable_frame", page.get("perception_gap")
    chrome.cdp("Target.closeTarget", targetId=target)

    target, s = open_page("/captcha")
    page = observe(s)
    got = labels(page)
    assert got == ["Submit"], got                                     # the challenge is never offered
    gap = nr.perception_gap(page)
    assert gap["reason"] == "captcha" and len(gap["frames"]) == 1, gap   # the invisible badge is not one
    chrome.cdp("Target.closeTarget", targetId=target)
    print("perception gaps ok")

    # --- unnamed controls (adaptation 35) ---
    target, s = open_page("/unnamed")
    page = observe(s)
    got = labels(page)
    assert got == ["link with no label at the top right"], got
    assert page["omitted_unnamed"] == 8
    chrome.cdp("Target.closeTarget", targetId=target)
    print("unnamed controls ok")

    # --- a click that changed only pixels: unseen_change (adaptation 36) ---
    target, s = open_page("/pixels")
    fb = object.__new__(nr.FastBrowser)
    fb.session, fb.target, fb.screenshots = s, target, False
    page = fb.observe(screenshot=False)
    assert "perception_gap" not in page
    # An ordinary click takes no picture first (~140 ms each); one that changed nothing Navi reads
    # makes the next click on this page take one, and that click's pixel-only change is reported.
    fb.act(find(page, "Paint"), page)
    after = fb.observe(screenshot=False)
    assert after["fingerprint"] == page["fingerprint"] and "perception_gap" not in after and fb.last_unchanged
    fb.act(find(after, "Paint"), after)
    again = fb.observe(screenshot=False)
    assert again["fingerprint"] == page["fingerprint"] and again["perception_gap"]["reason"] == "unseen_change", again.get("perception_gap")
    chrome.cdp("Target.closeTarget", targetId=target)
    print("unseen change ok")
finally:
    chrome.close()
