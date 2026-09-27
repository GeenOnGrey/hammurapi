#!/usr/bin/env bash
# End-to-end smoke test against the demo stack:
#   docker compose --profile demo up -d --build && scripts/e2e-smoke.sh
# Uses the fake GitLab (sign-in as any login) and the scripted fake agent.
set -euo pipefail

WEB=${WEB:-http://localhost:8080}
GITLAB=${GITLAB:-http://localhost:8929}
SPECS_ZIP_SRC=${SPECS_ZIP_SRC:-}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0
# python3 on Windows may be the Store stub; use whichever interpreter really runs.
PY=python3; "$PY" -c 'import json' 2>/dev/null || PY=python

ok()   { pass=$((pass+1)); printf '  \033[32m✓\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m✗ %s\033[0m\n' "$*"; exit 1; }
json() { "$PY" -c "import sys,json; d=json.load(sys.stdin); print($1)"; }

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
wait_for() { # wait_for <description> <command…>
  local d=$1; shift
  for _ in $(seq 1 40); do if "$@" >/dev/null 2>&1; then ok "$d"; return; fi; sleep 0.5; done
  die "timeout: $d"
}

echo "Sign-in"
login admin; ok "admin signed in through the provider (bootstrap global admin)"
me=$(call admin GET /api/v1/auth/me); [[ $(echo "$me" | json 'd["globalAdmin"]') == True ]] || die "bootstrap admin"; ok "BOOTSTRAP_ADMINS grants global admin"
login anna; ok "anna signed in"
call anna POST /admin/api/v1/domains '{"key":"XX","name":"x"}' >/dev/null; expect 403 "non-admin cannot change the dictionary"
curl -s -b "$TMP/admin" -X POST -H 'Content-Type: application/json' -d '{}' -o /dev/null -w '%{http_code}' "$WEB/api/v1/features" | grep -q 403 && ok "CSRF token is required" || die "csrf"

echo "Roles and dictionary"
ADMIN_ID=$(echo "$me" | json 'd["id"]')
ANNA_ID=$(call anna GET /api/v1/auth/me | json 'd["id"]')
all='["product","design","arch","tech","qa"]'
call admin PUT "/admin/api/v1/users/$ADMIN_ID/roles" "{\"globalAdmin\":true,\"roles\":[{\"role\":\"editor\",\"areas\":$all},{\"role\":\"approver\",\"areas\":$all},{\"role\":\"admin\",\"areas\":[\"product\"]}]}" >/dev/null; expect 204 "admin roles set"
call admin PUT "/admin/api/v1/users/$ANNA_ID/roles" '{"globalAdmin":false,"roles":[{"role":"editor","areas":["product"]},{"role":"admin","areas":["product"]}]}' >/dev/null; expect 204 "anna: editor + admin of product"
call admin PUT "/admin/api/v1/users/$ADMIN_ID/roles" '{"globalAdmin":false,"roles":[]}' >/dev/null; expect 409 "last global admin cannot be removed"
call admin POST /admin/api/v1/domains '{"key":"FMS","name":"Fleet","approvalRequired":true}' >/dev/null; expect 201 "domain FMS"
call admin POST /admin/api/v1/domains/FMS/systems '{"key":"CAR","name":"Cars"}' >/dev/null; expect 201 "system FMS/CAR"
call admin POST /admin/api/v1/domains '{"key":"PLT","name":"Platform","approvalRequired":false}' >/dev/null; expect 201 "domain PLT without approval"
call admin POST /admin/api/v1/domains/PLT/systems '{"key":"HMR","name":"Hammurapi"}' >/dev/null; expect 201 "system PLT/HMR"
call admin POST /admin/api/v1/domains '{"key":"FMS","name":"Again"}' >/dev/null; expect 409 "duplicate domain key"
call admin PATCH /api/v1/profile '{"domains":["FMS"],"language":"ru"}' >/dev/null; expect 200 "profile: my domains + language"

echo "Feature lifecycle"
F=$(call admin POST /api/v1/features '{"domain":"FMS","system":"CAR","title":"Weekend booking"}' | json 'd["uniqueId"]'); expect 201 "feature created: $F"
[[ $F == FMS.CAR-0001 ]] || die "numbering"
doc=$(call admin GET "/api/v1/features/$F/gates/product/document")
echo "$doc" | json 'd["content"]' | head -1 | grep -q "Product specification: Weekend booking" && ok "document created from rules/product/template.md" || die "template"
sha=$(echo "$doc" | json 'd["sha"]')
call admin PUT "/api/v1/features/$F/gates/product/document" "{\"content\":\"# Weekend booking\\n\\nFirst draft.\\n\",\"baseSha\":\"$sha\"}" >/dev/null; expect 200 "document saved (commit)"
call admin PUT "/api/v1/features/$F/gates/product/document" "{\"content\":\"# x\\n\",\"baseSha\":\"$sha\"}" >/dev/null; expect 409 "stale baseSha refused"
history_has() { call admin GET "/api/v1/features/$F/gates/$1/history" | grep -q "\"$2\""; }
wait_for "push webhook → Kafka → worker wrote 'edited'" history_has product edited
call anna PUT "/api/v1/features/$F/gates/product/document" '{"content":"# anna\n"}' >/dev/null; expect 423 "another user is locked out while admin edits"
call admin DELETE "/api/v1/features/$F/lock" >/dev/null; expect 204 "lock released"
call admin POST "/api/v1/features/$F/gates/product/approve" >/dev/null; expect 409 "draft cannot be approved"
call admin POST "/api/v1/features/$F/gates/product/submit" >/dev/null; expect 200 "submitted for approval"
n=$(call admin GET /api/v1/approvals | json 'len(d["items"])'); [[ $n == 1 ]] && ok "appears in 'awaiting your approval'" || die "approvals list: $n"
call admin POST "/api/v1/features/$F/gates" '{"area":"design"}' >/dev/null; expect 201 "design gate added"
call admin DELETE "/api/v1/features/$F/lock" >/dev/null
call admin POST "/api/v1/features/$F/gates/design/submit" >/dev/null; expect 200 "design submitted"
call admin POST "/api/v1/features/$F/gates/design/approve" >/dev/null; expect 409 "design cannot be approved before product"
call admin POST "/api/v1/features/$F/gates/product/approve" >/dev/null; expect 200 "product approved"
call admin POST "/api/v1/features/$F/handoff" >/dev/null; expect 409 "hand-off needs all gates approved"
call admin POST "/api/v1/features/$F/gates/design/approve" >/dev/null; expect 200 "design approved"
call admin GET "/api/v1/features/$F/gates/product/diff" | grep -q "Weekend booking" && ok "diff since approval shows the document" || die "diff"
call admin POST "/api/v1/features/$F/handoff" >/dev/null; expect 204 "handed off (MR merged)"
st=$(call admin GET "/api/v1/features/$F" | json 'd["status"]'); [[ $st == handed_off ]] && ok "feature is handed off" || die "status $st"
call admin PUT "/api/v1/features/$F/gates/product/document" '{"content":"# x\n"}' >/dev/null; expect 409 "handed-off feature is read-only"
FIX=$(call admin POST /api/v1/features "{\"title\":\"Refund fix\",\"parent\":\"$F\"}" | json 'd["uniqueId"]'); expect 201 "fix feature $FIX"
call admin GET "/api/v1/features/$FIX/gates/product/document" | json 'd["content"]' | grep -q "parent: $F" && ok "fix document has front matter parent: $F" || die "fix front matter"
call admin DELETE "/api/v1/features/$FIX" '{"confirmUniqueId":"WRONG"}' >/dev/null; expect 422 "delete needs the ID typed"
call admin DELETE "/api/v1/features/$FIX" "{\"confirmUniqueId\":\"$FIX\"}" >/dev/null; expect 204 "fix feature deleted"
call admin GET "/api/v1/features/$FIX" >/dev/null; expect 410 "deleted feature answers 410"
N=$(call admin POST /api/v1/features '{"domain":"FMS","system":"CAR","title":"Next"}' | json 'd["uniqueId"]'); [[ $N == FMS.CAR-0003 ]] && ok "number of a deleted feature is not reused ($N)" || die "got $N"

echo "Agent (ACP + MCP)"
curl -s -N -b "$TMP/admin" --max-time 20 "$WEB/api/v1/events" > "$TMP/sse" &
SSE=$!
sleep 1
call admin POST /api/v1/chat/messages '{"text":"hello agent","mode":"general"}' >/dev/null; expect 202 "general question accepted"
wait_for "answer streamed over SSE (agent.token → agent.done)" grep -q "agent.done" "$TMP/sse"
grep -q '"text":"echo: hello' "$TMP/sse" && ok "tokens streamed" || die "tokens"
call admin POST /api/v1/chat/messages "{\"text\":\"edit product: # Next\\n\\nWritten by the agent.\",\"mode\":\"spec\",\"feature\":\"$N\",\"area\":\"product\"}" >/dev/null; expect 202 "spec-mode request accepted"
agent_edit() { call admin GET "/api/v1/features/$N/gates/product/history" | grep -q '"isAgent":true'; }
wait_for "agent edited the gate through MCP edit_spec (Hammurapi-Agent trailer)" agent_edit
call admin POST /api/v1/chat/messages "{\"text\":\"edit product: # nope\",\"mode\":\"general\"}" >/dev/null
sleep 2
grep -q "not available in general mode" "$TMP/sse" && ok "edit_spec refused in general mode" || die "general-mode edit"
kill $SSE 2>/dev/null || true; wait $SSE 2>/dev/null || true
h=$(call admin GET /api/v1/chat/history | json 'len(d["items"])'); [[ $h -ge 4 ]] && ok "chat history is stored ($h messages)" || die "history $h"

echo "Import from archive"
"$PY" - "$TMP/import.zip" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], "w")
for area in ["product", "design", "arch"]:
    z.writestr(f"specs/PLT/HMR/PLT.HMR-0001/{area}/spec.md", f"# Hammurapi {area}\n\nSee PLT.HMR-0001.\n")
z.writestr("specs/LOG/DLV/LOG.DLV-0003/product/spec.md", "# Keys by courier\n")
z.writestr("rules/product/template.md", "# Product: <feature title>\n\n## Problem\n\n## Risks\n")
z.close()
PY
job=$(curl -s -b "$TMP/admin" -H "X-CSRF-Token: $(csrf admin)" -F "file=@$TMP/import.zip" "$WEB/api/v1/imports")
JOB=$(echo "$job" | json 'd["id"]'); ok "archive uploaded, preview created"
echo "$job" | json '[f["newId"] for f in d["features"]]' | grep -q "PLT.HMR-0001" && ok "preview shows the new ID" || die "preview: $job"
echo "$job" | grep -q unknown_domain && ok "unknown domain LOG reported for its feature only" || die "unknown domain"
echo "$job" | grep -q old_id_mentioned && ok "old ID mentions reported" || die "old id"
call admin POST "/api/v1/imports/$JOB/confirm" >/dev/null; expect 200 "import confirmed"
import_done() { call admin GET "/api/v1/imports/$JOB" | grep -q '"status":"done"'; }
wait_for "worker executed the import" import_done
g=$(call admin GET /api/v1/features/PLT.HMR-0001 | json 'len(d["gates"])'); [[ $g == 3 ]] && ok "imported feature has 3 gates" || die "gates $g"
call admin GET /api/v1/features/PLT.HMR-0001 | json 'd["permissions"]["handoff"]' | grep -q True && ok "domain without approval: hand-off available at once" || die "handoff perm"

echo "Rules (four eyes)"
rules=$(call admin GET /admin/api/v1/rules/product); expect 200 "rules readable"
rsha=$(echo "$rules" | json '[f["sha"] for f in d["files"] if f["file"]=="template"][0]')
# The import above (admin is admin of product) already proposed a template change.
open=$(call admin GET "/admin/api/v1/rules/changes?area=product&status=open" | json 'len(d["items"])'); [[ $open == 1 ]] && ok "import proposed a rules change" || die "open changes $open"
CH=$(call admin GET "/admin/api/v1/rules/changes?area=product&status=open" | json 'd["items"][0]["id"]')
call admin POST "/admin/api/v1/rules/product/changes" "{\"file\":\"template\",\"content\":\"# x\\n\",\"baseSha\":\"$rsha\"}" >/dev/null; expect 409 "one open change per file"
call admin POST "/admin/api/v1/rules/changes/$CH/approve" >/dev/null; expect 403 "author cannot approve own change"
call anna POST "/admin/api/v1/rules/changes/$CH/approve" >/dev/null; expect 200 "another product admin approves and merges"
call admin GET /admin/api/v1/rules/product | grep -q "Risks" && ok "new template is active on the default branch" || die "rules not merged"

echo "Misc"
url=$(call anna POST /api/v1/feedback '{"text":"Great tool"}' | json 'd["url"]'); expect 201 "feedback → issue $url"
call admin GET /api/v1/features?domain=mine | json 'len(d["items"])' | grep -qE '^[1-9]' && ok "'Mine' filter follows profile domains" || die "mine filter"
metrics=$(curl -s "${API_SERVICE:-http://localhost:9100}/metrics"); grep -q hammurapi_gate_transitions_total <<<"$metrics" && ok "Prometheus metrics exported" || die "metrics"

printf '\n\033[32m%d checks passed\033[0m\n' "$pass"
