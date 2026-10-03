#!/usr/bin/env bash
# End-to-end smoke test of the closed cycle (HMR.CMN-0002) against the demo stack:
#   docker compose --profile demo up -d --build && scripts/e2e-smoke.sh
# Uses the fake GitLab (sign-in as any login; specification and service
# repositories, MRs, CI results, deploy target, Prometheus) and the real agent
# (Pi in the agent operator) on the scripted fakellm (Analysis, tech/qa
# generation, code generation in the runner through the workspace server).
#
# Scenario (qa spec OPS-01): issue → Discovery → feature → gates (tech/qa
# generated) → code generation (runner, local executor) → validation →
# release (merge in order, deploy marks, confirmation) → second release with a
# configured deploy pipeline → rollback.
set -euo pipefail

WEB=${WEB:-http://localhost:8080}
GITLAB=${GITLAB:-http://localhost:8929}
API_SERVICE=${API_SERVICE:-http://localhost:9100}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0
# python3 on Windows may be the Store stub; use whichever interpreter really runs.
PY=python3; "$PY" -c 'import json' 2>/dev/null || PY=python

ok()   { pass=$((pass+1)); printf '  \033[32m✓\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m✗ %s\033[0m\n' "$*"; exit 1; }
# Python on Windows ends lines with CRLF: strip CR so piped greps match too.
json() { "$PY" -c "import sys,json; d=json.load(sys.stdin); print($1)" | tr -d '\r'; }

# login <user>: OAuth through the fake GitLab, cookies in $TMP/<user>.
login() {
  local jar="$TMP/$1" loc
  loc=$(curl -s -c "$jar" -b "$jar" -o /dev/null -w '%{redirect_url}' "$WEB/api/v1/auth/login")
  loc=$(curl -s -o /dev/null -w '%{redirect_url}' "${loc}&user=$1")
  curl -s -c "$jar" -b "$jar" -o /dev/null "$loc"
  grep -q hmr_session "$jar" || die "login $1"
}
csrf() { awk '$6=="csrf_token"{print $7}' "$TMP/$1"; }
# call <user> <method> <path> [json] → body; status in $TMP/status
call() {
  local u=$1 m=$2 p=$3 body=${4:-}
  local args=(-s -b "$TMP/$u" -c "$TMP/$u" -X "$m" -H "X-CSRF-Token: $(csrf "$u")" -o "$TMP/body" -w '%{http_code}')
  [[ -n $body ]] && args+=(-H 'Content-Type: application/json' -d "$body")
  curl "${args[@]}" "$WEB$p" > "$TMP/status"
  cat "$TMP/body"
}
status() { cat "$TMP/status"; }
expect() { [[ $(status) == "$1" ]] || die "$2: HTTP $(status) $(cat "$TMP/body")"; ok "$2"; }
wait_for() { # wait_for <description> <command…> (up to 90 s)
  local d=$1; shift
  for _ in $(seq 1 180); do if "$@" >/dev/null 2>&1; then ok "$d"; return; fi; sleep 0.5; done
  die "timeout: $d"
}
field() { call "$1" "$2" "$3" | json "$4"; } # field <user> <method> <path> <python expression over d>

echo "Sign-in and roles (R39)"
login admin; ok "admin signed in through the provider (bootstrap global admin)"
me=$(call admin GET /api/v1/auth/me); [[ $(echo "$me" | json 'd["globalAdmin"]') == True ]] || die "bootstrap admin"; ok "BOOTSTRAP_ADMINS grants global admin"
login anna; login oleg; ok "anna and oleg signed in"
ADMIN_ID=$(echo "$me" | json 'd["id"]')
ANNA_ID=$(field anna GET /api/v1/auth/me 'd["id"]')
OLEG_ID=$(field oleg GET /api/v1/auth/me 'd["id"]')
call anna POST /admin/api/v1/domains '{"key":"XX","name":"x"}' >/dev/null; expect 403 "non-admin cannot change the dictionary"
call admin PUT "/admin/api/v1/users/$ADMIN_ID/roles" '{"globalAdmin":true,"areaAdmin":["product"]}' >/dev/null; expect 204 "roles: global admin + product area admin (no editor/approver roles)"
call admin PUT "/admin/api/v1/users/$ADMIN_ID/roles" '{"globalAdmin":false,"areaAdmin":[]}' >/dev/null; expect 409 "last global admin cannot be removed"

echo "Agent configuration (HMR.CMN-0004)"
conn=$(call admin GET /admin/api/v1/agent/connections); expect 200 "Admin → Agent: connections"
[[ $(echo "$conn" | json 'len(d["items"])') -ge 1 ]] && ok "the first LLM connection from BOOTSTRAP_DEEPSEEK_API_KEY" || die "no connection: $conn"
call anna GET /admin/api/v1/agent/connections >/dev/null; expect 403 "the Agent section is for global administrators only"
[[ $(field anna GET /api/v1/chat/session 'd["model"]') == deepseek-v4-flash ]] && ok "chat header shows the default model" || die "chat model"

echo "Dictionary, experts, services (R10, R11, R17)"
call admin POST /admin/api/v1/domains '{"key":"FMS","name":"Fleet","approvalRequired":true}' >/dev/null; expect 201 "domain FMS"
call admin POST /admin/api/v1/domains/FMS/systems '{"key":"CAR","name":"Cars"}' >/dev/null; expect 201 "system FMS/CAR"
call admin PUT /admin/api/v1/domains/FMS/experts "{\"product\":[\"$ANNA_ID\"],\"technical\":[\"$OLEG_ID\",\"$ANNA_ID\"]}" >/dev/null; expect 204 "experts of FMS: anna (product, technical), oleg (technical)"
call admin POST /admin/api/v1/services '{"key":"booking","name":"Booking","system":"FMS/CAR","repo":"demo/booking","ownerRef":"user:anna"}' >/dev/null; expect 201 "service booking (manual catalog)"
call admin POST /admin/api/v1/services '{"key":"pricing","name":"Pricing","system":"FMS/CAR","repo":"demo/pricing","ownerRef":"group:team-fleet"}' >/dev/null; expect 201 "service pricing owned by group:team-fleet"
login anna # new roles
call anna PUT /api/v1/services/pricing/autonomy '{"level":"autonomous"}' >/dev/null; expect 204 "owner sets autonomy of pricing"
login oleg
call oleg PUT /api/v1/services/booking/autonomy '{"level":"plan"}' >/dev/null; expect 403 "non-owner cannot change autonomy (CG-07)"
call admin POST /admin/api/v1/metric-sources '{"name":"demo","type":"prometheus","endpoint":"http://fakegitlab:8929/fake/prometheus"}' >/dev/null; expect 201 "metric source demo (Prometheus)"
v=$(call admin POST /admin/api/v1/metric-sources/demo/test '{"query":"sum(hammurapi_demo_value)"}' | json 'd["value"] == 42'); [[ $v == True ]] && ok "metric source dry run returns a value (MET-04)" || die "metric test: $v"

echo "Research: issue and Discovery (R1–R7)"
curl -s -N -b "$TMP/anna" --max-time 600 "$WEB/api/v1/events" > "$TMP/sse" &
SSE=$!
call anna POST /api/v1/issues '{"type":"idea","domain":"FMS","title":"Weekend tariffs","description":"Customers ask for weekend tariffs."}' >/dev/null; expect 201 "issue created by a reader"
ISS=$(cat "$TMP/body" | json 'd["key"]'); [[ $ISS == ISS.FMS-0001 ]] && ok "key $ISS" || die "key $ISS"
verified() { [[ $(field anna GET "/api/v1/issues/$ISS" 'd["status"]') == verification ]]; }
wait_for "Discovery by the agent → verification (DSC-01)" verified
[[ $(field anna GET "/api/v1/issues/$ISS/discovery" 'd["complete"]') == True ]] && ok "Discovery has value and measure" || die "discovery incomplete"
call anna POST "/api/v1/issues/$ISS/reject" '{"reason":""}' >/dev/null; expect 422 "reject needs a reason (DSC-05)"
F=$(call anna POST "/api/v1/issues/$ISS/accept" '{"system":"CAR"}' | json 'd["featureKey"]'); expect 201 "issue accepted → feature $F (DSC-09)"
[[ $F == FTR.FMS.CAR-0001 ]] || die "feature key $F"
[[ $(field anna GET "/api/v1/issues/$ISS" 'd["status"]') == accepted ]] && ok "issue accepted" || die "issue status"
field anna GET "/api/v1/features/$F/gates/product/document" 'd["content"]' | grep -q "sum(hammurapi_demo_value)" && ok "success metric in the product draft" || die "metric not in product spec"
call anna POST /api/v1/features '{"domain":"FMS","system":"CAR","title":"x"}' >/dev/null; [[ $(status) == 405 || $(status) == 404 ]] && ok "no direct feature creation (DSC-13)" || die "direct creation $(status)"

echo "Specification: gates, generated tech/qa (R12–R15)"
doc=$(call anna GET "/api/v1/features/$F/gates/product/document"); sha=$(echo "$doc" | json 'd["sha"]')
call anna PUT "/api/v1/features/$F/gates/product/document" "{\"content\":\"# Weekend tariffs\\n\\n## Requirements\\n\\n**R1.** Weekend tariff in booking.\\n- Given a weekend day, when a car is booked, then the weekend tariff applies.\\n\\n**R2.** Price calculation.\\n- Given the weekend tariff, when the price is shown, then it uses the tariff.\\n\",\"baseSha\":\"$sha\"}" >/dev/null; expect 200 "product document saved"
call anna DELETE "/api/v1/features/$F/lock" >/dev/null
reqs() { [[ $(field anna GET "/api/v1/features/$F/requirements" 'len(d)') == 2 ]]; }
wait_for "requirements R1, R2 projected from the product spec (GEN-05)" reqs
call anna POST "/api/v1/features/$F/gates/product/submit" >/dev/null; expect 200 "product submitted"
call oleg POST "/api/v1/features/$F/gates/product/approve" >/dev/null; expect 403 "technical expert cannot approve product (GEN-09)"
call anna POST "/api/v1/features/$F/gates/product/approve" >/dev/null; expect 200 "product approved by the product expert"
generated() { [[ $(field anna GET "/api/v1/features/$F" 'len(d["pendingGates"])') == 0 ]]; }
wait_for "tech and qa generated by the agent (GEN-01)" generated
field anna GET "/api/v1/features/$F/gates/tech/document" 'd["content"]' | grep -q "| booking |" && ok "tech has the service table" || die "tech table"
call oleg PUT "/api/v1/features/$F/gates/tech/document" '{"content":"# x\n"}' >/dev/null; expect 403 "tech is not edited by hand (GEN-03)"
svcs() { [[ $(field anna GET "/api/v1/features/$F" 'len(d["services"])') == 2 ]]; }
wait_for "affected services projected from tech" svcs
call anna POST "/api/v1/features/$F/codegen" >/dev/null; expect 409 "codegen before approval (CG-01)"
for a in tech qa; do
  call oleg POST "/api/v1/features/$F/gates/$a/submit" >/dev/null; expect 200 "$a submitted"
  call oleg POST "/api/v1/features/$F/gates/$a/approve" >/dev/null; expect 200 "$a approved by a technical expert"
done

echo "Code generation (R16–R21, runner with the local executor)"
n=$(call anna POST "/api/v1/features/$F/codegen" | json 'len(d["services"])'); expect 202 "code generation started"
[[ $n == 2 ]] && ok "plan: 2 services" || die "plan $n"
call anna PUT "/api/v1/features/$F/gates/product/document" '{"content":"# x\n"}' >/dev/null; expect 409 "specifications read-only during codegen"
validation() { [[ $(field anna GET "/api/v1/features/$F" 'd["phase"]') == validation ]]; }
wait_for "agent PRs in both services → phase Validation (CG-11)" validation
impl=$(call anna GET "/api/v1/features/$F/implementation")
echo "$impl" | json 'all(s["pr"] and s["pr"]["byAgent"] for s in d["services"])' | grep -q True && ok "PRs from the bot in each service (CG-04)" || die "PRs $impl"
echo "$impl" | json '[s["pr"]["state"] for s in d["services"]]' | grep -q merged && die "a PR was merged during development" || ok "nothing merged during development (R17)"
echo "$impl" | json 'sum(len(r["prs"]) for r in d["matrix"])' | grep -qE '^[1-9]' && ok "matrix requirement → test case → PR (R21)" || die "matrix"

echo "Validation (R22–R25)"
ready() { [[ $(field anna GET "/api/v1/features/$F/validation" 'd["state"]') == awaiting_signatures ]]; }
wait_for "CI results of the PR branches received (fake CI → /hooks/v1/ci-results)" ready
field anna GET "/api/v1/features/$F/validation" '[t["status"] for t in d["tests"]]' | grep -q passed && ok "test cases linked to CI results (VAL-01)" || die "tests"
call oleg POST "/api/v1/features/$F/validation/sign" '{"side":"product"}' >/dev/null; expect 403 "technical expert cannot sign the product side (VAL-07)"
call anna POST "/api/v1/features/$F/validation/sign" '{"side":"product"}' >/dev/null; expect 200 "product side signed"
R=$(call oleg POST "/api/v1/features/$F/validation/sign" '{"side":"technical"}' | json 'd["releaseKey"]'); expect 200 "technical side signed"
[[ $R == RLS.FMS.CAR-0001 ]] && ok "second signature created release $R (VAL-12)" || die "release $R"

echo "Release (R26–R28, R31)"
rel=$(call anna GET "/api/v1/releases/$R")
[[ $(echo "$rel" | json 'd["step"]') == awaiting_start ]] && ok "release waits for the merge start" || die "step"
[[ $(echo "$rel" | json 'd["prs"][-1]["kind"]') == spec ]] && ok "spec PR is the last one (REL-01)" || die "spec PR last"
call anna PUT "/api/v1/releases/$R/plan" '{"order":["pricing","booking"]}' >/dev/null; expect 204 "plan reordered before the merge (REL-02)"
call anna POST "/api/v1/releases/$R/merge" >/dev/null; expect 202 "merge started"
for s in pricing booking; do
  deploying() { [[ $(field anna GET "/api/v1/releases/$R" 'd["currentService"]') == "$s" && $(field anna GET "/api/v1/releases/$R" 'd["status"]') == deploying ]]; }
  wait_for "$s merged, waiting for its release" deploying
  call oleg POST "/api/v1/releases/$R/deploys/$s/mark" '{"version":"v1"}' >/dev/null; expect 202 "$s marked released by a technical expert (REL-10)"
done
confirmable() { [[ $(field anna GET "/api/v1/releases/$R" 'd["status"]') == awaiting_confirmation ]]; }
wait_for "release awaits confirmation (no flags, no metric window in the first release)" confirmable
call anna POST "/api/v1/releases/$R/confirm" >/dev/null; expect 202 "release confirmed"
succeeded() { [[ $(field anna GET "/api/v1/releases/$R" 'd["status"]') == succeeded ]]; }
wait_for "spec PR merged, release succeeded (REL-16)" succeeded
[[ $(field anna GET "/api/v1/features/$F" 'd["phase"]') == released ]] && ok "feature released" || die "feature phase"
[[ $(field anna GET "/api/v1/issues/$ISS" 'd["status"]') == resolved ]] && ok "issue resolved" || die "issue status"
call anna POST "/api/v1/releases/$R/rollback" '{"reason":"late"}' >/dev/null; expect 409 "a succeeded release cannot be rolled back (REL-19)"

echo "Deploy pipeline and rollback (R32–R34, R40)"
secret=$(call admin PUT /admin/api/v1/deploy/production '{"type":"webhook","url":"http://fakegitlab:8929/fake/deploy","auth":"secret","params":{"service":"{service}"},"timeoutMinutes":10}' | json 'd["secret"]'); expect 200 "production deploy configured (webhook)"
curl -s -X POST -H 'Content-Type: application/json' -d "{\"deploySecret\":\"$secret\"}" "$GITLAB/fake/config" >/dev/null && ok "deploy target knows the result secret"
call admin POST /admin/api/v1/deploy/production/test '{"service":"booking"}' | grep -q '"ok":true' && ok "dry run of the pipeline (DEP-06)" || die "deploy test"
call anna POST /api/v1/issues '{"type":"problem","domain":"FMS","title":"Refunds","description":"Refund flow."}' >/dev/null
ISS2=$(cat "$TMP/body" | json 'd["key"]')
v2() { [[ $(field anna GET "/api/v1/issues/$ISS2" 'd["status"]') == verification ]]; }
wait_for "second issue $ISS2 through Discovery" v2
F2=$(call anna POST "/api/v1/issues/$ISS2/accept" '{"noFeature":true,"system":"CAR"}' | json 'd["featureKey"]'); expect 201 "Problem without a feature → new feature $F2 (DSC-11)"
[[ $(field anna GET "/api/v1/features/$F2" 'd["isProblem"]') == True ]] && ok "feature marked Problem" || die "isProblem"
sha=$(field anna GET "/api/v1/features/$F2/gates/product/document" 'd["sha"]')
call anna PUT "/api/v1/features/$F2/gates/product/document" "{\"content\":\"# Refunds\\n\\n**R1.** Refund in booking.\\n- Given a paid booking, when it is cancelled, then money returns.\\n\",\"baseSha\":\"$sha\"}" >/dev/null
call anna DELETE "/api/v1/features/$F2/lock" >/dev/null
call anna POST "/api/v1/features/$F2/gates/product/submit" >/dev/null
call anna POST "/api/v1/features/$F2/gates/product/approve" >/dev/null; expect 200 "product of $F2 approved"
g2() { [[ $(field anna GET "/api/v1/features/$F2" 'len(d["pendingGates"])') == 0 ]]; }
wait_for "tech and qa generated" g2
for a in tech qa; do call oleg POST "/api/v1/features/$F2/gates/$a/submit" >/dev/null; call oleg POST "/api/v1/features/$F2/gates/$a/approve" >/dev/null; done
call anna POST "/api/v1/features/$F2/codegen" >/dev/null; expect 202 "code generation of $F2"
val2() { [[ $(field anna GET "/api/v1/features/$F2/validation" 'd["state"]') == awaiting_signatures ]]; }
wait_for "$F2 in validation with CI results" val2
call anna POST "/api/v1/features/$F2/validation/sign" '{"side":"product"}' >/dev/null
R2=$(call anna POST "/api/v1/features/$F2/validation/sign" '{"side":"technical"}' | json 'd["releaseKey"]'); expect 200 "one expert of both kinds signs both sides (VAL-08) → $R2"
call anna POST "/api/v1/releases/$R2/merge" >/dev/null; expect 202 "merge of $R2 started"
released_one() { call anna GET "/api/v1/releases/$R2" | json '[x for x in d["deploys"] if x["status"]=="success" and x["signal"]=="pipeline"]' | grep -q pipeline; }
wait_for "pipeline started with run_id, result webhook counted the release (REL-06, REL-07)" released_one
call anna POST "/api/v1/releases/$R2/rollback" '{"reason":""}' >/dev/null; expect 422 "rollback needs a reason (RB-01)"
call anna POST "/api/v1/releases/$R2/rollback" '{"reason":"refund errors grow"}' >/dev/null; expect 202 "rollback started"
rolled() { [[ $(field anna GET "/api/v1/releases/$R2" 'd["status"]') == rolled_back ]]; }
wait_for "revert PRs by the bot, merged, redeployed; spec PR closed (RB-02…RB-05)" rolled
[[ $(field anna GET "/api/v1/features/$F2" 'd["phase"]') == rolled_back ]] && ok "feature rolled back" || die "feature phase"
call anna GET "/api/v1/issues/$ISS2" | json 'd["rolledBackRelease"]' | grep -q "$R2" && ok "issue returned with a link to the release (RB-06)" || die "issue link"
field anna GET "/api/v1/releases/$R2" '[p["kind"] for p in d["prs"]]' | grep -q revert && ok "revert PRs recorded in the release" || die "revert PRs"

echo "General section (R37) and chat"
field anna GET /api/v1/focus 'len(d["research"])' | grep -qE '^[0-9]+$' && ok "In focus answers by stage" || die "focus"
field anna GET "/api/v1/overview?domain=all" 'len(d["issues"]) + len(d["features"]) + len(d["releases"])' | grep -qE '^[0-9]+$' && ok "Overview in three columns" || die "overview"
call anna POST /api/v1/chat/messages '{"text":"hello agent","mode":"general"}' >/dev/null; expect 202 "chat question accepted"
wait_for "answer streamed over SSE" grep -q "agent.done" "$TMP/sse"
[[ $(field admin GET /admin/api/v1/agent/usage 'd["totals"]["runs"]') -ge 1 ]] && ok "agent usage recorded (USE-01)" || die "no usage"
grep -q "issue.updated" "$TMP/sse" && ok "issue.updated events over SSE" || die "sse issue.updated"
grep -q "release.updated" "$TMP/sse" && ok "release.updated events over SSE" || die "sse release.updated"
kill $SSE 2>/dev/null || true; wait $SSE 2>/dev/null || true

echo "Observability"
metrics=$(curl -s "$API_SERVICE/metrics"); grep -q hammurapi_gate_transitions_total <<<"$metrics" && ok "api metrics exported" || die "metrics"
wm=$(curl -s "${WORKER_SERVICE:-http://localhost:9101}/metrics")
grep -q hammurapi_workflow_transition_duration_seconds <<<"$wm" && grep -q hammurapi_runner_tasks <<<"$wm" && ok "workflow and runner metrics exported (OPS-03)" || die "worker metrics"

printf '\n\033[32m%d checks passed\033[0m\n' "$pass"
