#!/usr/bin/env bash
# Scripted walkthrough of the Navi Cloud API against a running server.
#
#   Terminal 1:  cd cloud && MOCK_UPSTREAM=1 DEV_LOGIN_SECRET=dev npm run dev
#   Terminal 2:  cd cloud && scripts/smoke.sh
#
# Env: NAVI_CLOUD_URL (default http://localhost:3100), DEV_LOGIN_SECRET (default dev),
#      SMOKE_EMAIL (default a fresh smoke+<ts>@navi.local so every run starts on a clean profile).
# Needs curl and node. Exits non-zero on the first surprise.
set -euo pipefail

BASE=${NAVI_CLOUD_URL:-http://localhost:3100}
SECRET=${DEV_LOGIN_SECRET:-dev}
EMAIL=${SMOKE_EMAIL:-smoke+$(date +%s)@navi.local}

bold() { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }
fail() { printf '\n\033[31m✗ %s\033[0m\n' "$*"; exit 1; }
ok()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
uuid() { node -e 'console.log(require("crypto").randomUUID())'; }
# jsonget <path>  — reads JSON on stdin, prints a dotted path ("usage.tasksToday")
jsonget() { node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{const o=JSON.parse(d);const v=process.argv[1].split(".").reduce((a,k)=>a==null?a:a[k],o);console.log(v==null?"":typeof v==="object"?JSON.stringify(v):v)})' "$1"; }
# status <curl args…> — prints only the HTTP status
status() { curl -sS -o /dev/null -w '%{http_code}' "$@"; }

bold "GET /healthz"
curl -sS "$BASE/healthz"; echo

bold "POST /auth/dev-login  ($EMAIL, trial: false → plain Free tier)"
TOKENS=$(curl -sS -X POST "$BASE/auth/dev-login" \
  -H 'content-type: application/json' -H "x-dev-login-secret: $SECRET" \
  -d "{\"email\":\"$EMAIL\",\"trial\":false}")
echo "$TOKENS"
ACCESS=$(echo "$TOKENS" | jsonget accessToken)
REFRESH=$(echo "$TOKENS" | jsonget refreshToken)
[ -n "$ACCESS" ] || fail "dev-login returned no accessToken (is DEV_LOGIN_SECRET=$SECRET set on the server?)"
AUTH=(-H "authorization: Bearer $ACCESS")
ok "signed in"

bold "GET /v1/me"
ME=$(curl -sS "$BASE/v1/me" "${AUTH[@]}")
echo "$ME"
[ "$(echo "$ME" | jsonget tier)" = "free" ] || fail "expected tier free"
ok "tier=$(echo "$ME" | jsonget tier) quotas=$(echo "$ME" | jsonget quotas)"

bold "GET /v1/me without a token → 401"
CODE=$(status "$BASE/v1/me")
[ "$CODE" = "401" ] || fail "expected 401, got $CODE"
ok "401"

bold "POST /v1/jev  (X-Navi-Feature: route — never capped)"
curl -sS -X POST "$BASE/v1/jev" "${AUTH[@]}" \
  -H 'content-type: application/json' -H 'x-navi-feature: route' -H "x-navi-run: $(uuid)" \
  -d '{"state":{"query":"open chrome and search for cats","frontmost_app":"Finder"},"model":"jev-latest","questions":{"intent":{"type":"choice","instructions":"What does the user want?","criteria":{"open_app":"launch an app","task":"a multi-step computer task","answer":"a question to answer"}},"is_risky":{"type":"noul","instructions":"Could carrying this out be irreversible?"}}}'
echo
ok "jev answered"

bold "POST /v1/claude  stream:true  (X-Navi-Feature: answer) — first 600 bytes of the SSE"
STREAM=$(curl -sS -N -X POST "$BASE/v1/claude" "${AUTH[@]}" \
  -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' \
  -H 'x-navi-feature: answer' -H "x-navi-run: $(uuid)" \
  -d '{"model":"claude-opus-5","max_tokens":256,"stream":true,"messages":[{"role":"user","content":"What is Navi?"}]}')
echo "${STREAM:0:600}"; echo "… ($(printf %s "$STREAM" | wc -c | tr -d ' ') bytes total)"
printf %s "$STREAM" | grep -q '"type":"message_stop"' || fail "stream did not end with message_stop"
ok "streamed to message_stop"

bold "POST /v1/claude  non-streaming"
curl -sS -X POST "$BASE/v1/claude" "${AUTH[@]}" \
  -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' \
  -H 'x-navi-feature: answer' -H "x-navi-run: $(uuid)" \
  -d '{"model":"claude-opus-5","max_tokens":256,"messages":[{"role":"user","content":"What is Navi?"}]}'
echo

bold "POST /v1/digest on Free → 403 not_entitled"
BODY=$(curl -sS -X POST "$BASE/v1/digest" "${AUTH[@]}" -H 'content-type: application/json' -H "x-navi-run: $(uuid)" \
  -d '{"model":"claude-haiku-4-5","max_tokens":64,"messages":[{"role":"user","content":"digest this"}]}')
echo "$BODY"
[ "$(echo "$BODY" | jsonget error)" = "not_entitled" ] || fail "expected not_entitled"
ok "403 not_entitled"

bold "POST /v1/claude X-Navi-Feature: voice on Free → 403 not_entitled"
CODE=$(status -X POST "$BASE/v1/claude" "${AUTH[@]}" -H 'content-type: application/json' -H 'x-navi-feature: voice' -H "x-navi-run: $(uuid)" \
  -d '{"model":"claude-opus-5","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}')
[ "$CODE" = "403" ] || fail "expected 403, got $CODE"
ok "403"

bold "Loop tasks on Free (5/day): distinct X-Navi-Run per task, several calls per run"
FIRST_RUN=$(uuid)
for i in 1 2 3 4 5 6 7; do
  RUN=$(uuid); [ "$i" = 1 ] && RUN=$FIRST_RUN
  CODES=""
  for call in 1 2 3; do   # a task makes many calls; only the run counts
    CODES="$CODES $(status -X POST "$BASE/v1/jev" "${AUTH[@]}" -H 'content-type: application/json' -H 'x-navi-feature: task' -H "x-navi-run: $RUN" -d '{"state":"step","model":"jev-latest","questions":{"done":{"type":"noul","instructions":"done?"}}}')"
  done
  echo "task $i run=${RUN:0:8} →$CODES"
  if [ "$i" -le 5 ]; then
    [ "$CODES" = " 200 200 200" ] || fail "task $i should be 200s"
  else
    [ "$CODES" = " 402 402 402" ] || fail "task $i should be 402s"
  fi
done
ok "6th task → 402"

bold "The 402 body"
curl -sS -X POST "$BASE/v1/jev" "${AUTH[@]}" -H 'content-type: application/json' -H 'x-navi-feature: task' -H "x-navi-run: $(uuid)" \
  -d '{"state":"x","model":"jev-latest","questions":{"q":{"type":"noul","instructions":"?"}}}'
echo

bold "A run that already started keeps going after the cap (run=${FIRST_RUN:0:8})"
CODE=$(status -X POST "$BASE/v1/jev" "${AUTH[@]}" -H 'content-type: application/json' -H 'x-navi-feature: task' -H "x-navi-run: $FIRST_RUN" \
  -d '{"state":"x","model":"jev-latest","questions":{"q":{"type":"noul","instructions":"?"}}}')
[ "$CODE" = "200" ] || fail "expected 200 for an in-flight run, got $CODE"
ok "200"

bold "GET /v1/me shows the spent quota"
curl -sS "$BASE/v1/me" "${AUTH[@]}"; echo

USER_ID=$(echo "$ME" | jsonget user.id)
bold "POST /billing/webhook  checkout.session.completed → pro  (unsigned: MOCK_UPSTREAM dev mode only)"
WH=$(curl -sS -X POST "$BASE/billing/webhook" -H 'content-type: application/json' \
  -d "{\"id\":\"evt_smoke\",\"type\":\"checkout.session.completed\",\"data\":{\"object\":{\"mode\":\"subscription\",\"client_reference_id\":\"$USER_ID\",\"customer\":\"cus_smoke\",\"subscription\":\"sub_smoke\",\"metadata\":{\"plan\":\"pro\",\"user_id\":\"$USER_ID\"}}}}")
echo "$WH"
if [ "$(echo "$WH" | jsonget handled)" = "true" ]; then
  ME2=$(curl -sS "$BASE/v1/me" "${AUTH[@]}")
  echo "$ME2"
  [ "$(echo "$ME2" | jsonget tier)" = "pro" ] || fail "expected tier pro after webhook"
  CODE=$(status -X POST "$BASE/v1/jev" "${AUTH[@]}" -H 'content-type: application/json' -H 'x-navi-feature: task' -H "x-navi-run: $(uuid)" \
    -d '{"state":"x","model":"jev-latest","questions":{"q":{"type":"noul","instructions":"?"}}}')
  [ "$CODE" = "200" ] || fail "pro user should run tasks again, got $CODE"
  ok "tier=pro, tasks allowed again (monthly cap now)"
else
  echo "(webhook signature enforced on this server — skipping the upgrade check)"
fi

bold "POST /auth/refresh"
NEW=$(curl -sS -X POST "$BASE/auth/refresh" -H 'content-type: application/json' -d "{\"refreshToken\":\"$REFRESH\"}")
echo "$NEW"
[ -n "$(echo "$NEW" | jsonget accessToken)" ] || fail "refresh failed"
ok "refreshed"

bold "POST /auth/exchange with a bogus code → 400 invalid_code"
curl -sS -X POST "$BASE/auth/exchange" -H 'content-type: application/json' -d '{"code":"nope"}'; echo

bold "POST /waitlist → 201, then 200 on repeat"
C1=$(status -X POST "$BASE/waitlist" -H 'content-type: application/json' -d "{\"email\":\"$EMAIL\",\"source\":\"smoke\"}")
C2=$(status -X POST "$BASE/waitlist" -H 'content-type: application/json' -d "{\"email\":\"$EMAIL\",\"source\":\"smoke\"}")
echo "$C1 then $C2"
[ "$C1" = "201" ] && [ "$C2" = "200" ] || fail "waitlist codes"
ok "waitlist"

printf '\n\033[1;32mSmoke passed against %s\033[0m\n' "$BASE"
