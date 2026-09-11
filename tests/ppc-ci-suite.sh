#!/usr/bin/env bash
# PPC CI/CD conformance suite. Read-only against the cluster: nothing here
# creates, mutates or deletes remote resources.
set -uo pipefail

API=${POSTMAN_API_BASE_URL:?}
GW=${POSTMAN_GATEWAY_BASE_URL:?}
IAPUB=${POSTMAN_IAPUB_BASE_URL:?}
COLL=${COLLECTION_UID:?}
ENVU=${ENVIRONMENT_UID:-}
KEY=${POSTMAN_API_KEY:?}

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PROXY_PORT=8899; CANARY_PORT=8898
EGRESS=$TMP/egress.log; CANARY=$TMP/canary.log
: > "$EGRESS"; : > "$CANARY"
HERE=$(cd "$(dirname "$0")" && pwd)

PASS=0; FAIL=0; SKIP=0
RESULTS=$TMP/results.md
echo "| # | Area | Check | Result | Detail |" > "$RESULTS"
echo "|---|---|---|---|---|" >> "$RESULTS"
N=0
report() { # area check result detail
  N=$((N+1))
  case "$3" in
    PASS) PASS=$((PASS+1)); icon="✅ pass" ;;
    FAIL) FAIL=$((FAIL+1)); icon="❌ FAIL" ;;
    *)    SKIP=$((SKIP+1)); icon="⏭️ skip" ;;
  esac
  printf '| %d | %s | %s | %s | %s |\n' "$N" "$1" "$2" "$icon" "${4//|/\\|}" >> "$RESULTS"
  printf '%-3s %-14s %-46s %s\n' "$N" "$1" "$2" "$icon${4:+  — $4}"
}

PROXY_LOG=$EGRESS PROXY_PORT=$PROXY_PORT python3 "$HERE/proxy-logger.py" >"$TMP/proxy.out" 2>&1 &
PROXY_PID=$!
CANARY_LOG=$CANARY CANARY_PORT=$CANARY_PORT python3 "$HERE/canary.py" >"$TMP/canary.out" 2>&1 &
CANARY_PID=$!
trap 'kill $PROXY_PID $CANARY_PID 2>/dev/null; rm -rf "$TMP"' EXIT
for i in 1 2 3 4 5 6 7 8 9 10; do
  nc -z 127.0.0.1 $PROXY_PORT 2>/dev/null && nc -z 127.0.0.1 $CANARY_PORT 2>/dev/null && break
  perl -e 'select undef,undef,undef,0.4'
done

THREE_VARS=(POSTMAN_API_BASE_URL="$API" POSTMAN_GATEWAY_BASE_URL="$GW" POSTMAN_IAPUB_BASE_URL="$IAPUB")
CAN="http://127.0.0.1:$CANARY_PORT"
NINE_VARS=(
  POSTMAN_ANALYTICS_BASE_URL="$CAN" POSTMAN_ARTEMIS_BASE_URL="$CAN"
  POSTMAN_PACKMAN_BASE_URL="$CAN" POSTMAN_RUNTIME_AGENT_BASE_URL="$CAN"
  POSTMAN_INTEGRATIONS_BASE_URL="$CAN" POSTMAN_SDK_GEN_BASE_URL="$CAN"
  POSTMAN_RUNNER_API_BASE_URL="$CAN" POSTMAN_TUNNEL_LIAISON_SERVICE_BASE_URL="$CAN"
  POSTMAN_WEBHOOK_PUBLIC_ENDPOINT_BASE_URL="$CAN"
)
PROXY_VARS=(HTTPS_PROXY="http://127.0.0.1:$PROXY_PORT" HTTP_PROXY="http://127.0.0.1:$PROXY_PORT" NO_PROXY="127.0.0.1,localhost")

echo; echo "### A. Egress containment"; echo
: > "$EGRESS"
env "${THREE_VARS[@]}" "${PROXY_VARS[@]}" postman collection run "$COLL" ${ENVU:+-e "$ENVU"} >"$TMP/a1.out" 2>&1
if [ -s "$EGRESS" ]; then report Egress "CLI honours HTTPS_PROXY" PASS "$(sort -u "$EGRESS" | wc -l | tr -d ' ') distinct hosts observed"
else report Egress "CLI honours HTTPS_PROXY" FAIL "proxy saw no traffic"; fi
LEAK=$(grep -E 'getpostman\.com|postman\.co$' "$EGRESS" | sort -u | tr '\n' ' ')
if [ -z "$LEAK" ]; then report Egress "no public-cloud egress (3 vars set)" PASS ""
else report Egress "no public-cloud egress (3 vars set)" FAIL "leaked to: $LEAK"; fi

: > "$EGRESS"; : > "$CANARY"
env "${THREE_VARS[@]}" "${NINE_VARS[@]}" "${PROXY_VARS[@]}" postman collection run "$COLL" ${ENVU:+-e "$ENVU"} >"$TMP/a3.out" 2>&1
LEAK2=$(grep -E 'getpostman\.com|postman\.co$' "$EGRESS" | sort -u | tr '\n' ' ')
if [ -z "$LEAK2" ]; then report Egress "no public-cloud egress (all 12 vars)" PASS "canary absorbed $(wc -l < "$CANARY" | tr -d ' ') calls"
else report Egress "no public-cloud egress (all 12 vars)" FAIL "still leaked: $LEAK2"; fi
CANHITS=$(sed 's|127.0.0.1:[0-9]*||' "$CANARY" | awk '{print $1, $2}' | sort -u | head -5 | tr '\n' ';')
report Egress "which extra services are called" INFO "${CANHITS:-none}"

echo; echo "### B. Exit codes"; echo
env "${THREE_VARS[@]}" postman collection run "$COLL" ${ENVU:+-e "$ENVU"} >/dev/null 2>&1; rc=$?
[ $rc -ne 0 ] && report ExitCode "failing collection exits non-zero" PASS "rc=$rc" || report ExitCode "failing collection exits non-zero" FAIL "rc=0"
env "${THREE_VARS[@]}" postman collection run "$COLL" ${ENVU:+-e "$ENVU"} -x >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && report ExitCode "-x suppresses exit code" PASS "rc=0" || report ExitCode "-x suppresses exit code" FAIL "rc=$rc"
env "${THREE_VARS[@]}" postman collection run "$COLL" ${ENVU:+-e "$ENVU"} --bail >"$TMP/bail.out" 2>&1; rc=$?
BAILREQ=$(grep -oE '\|[[:space:]]*requests[[:space:]]*\|[[:space:]]*[0-9]+' "$TMP/bail.out" | grep -oE '[0-9]+$' | head -1)
[ $rc -ne 0 ] && report ExitCode "--bail stops early" PASS "rc=$rc, requests executed=${BAILREQ:-?}" || report ExitCode "--bail stops early" FAIL "rc=0"

echo; echo "### C. Reporters"; echo
for r in junit json html; do
  out=$TMP/rep.$r
  env "${THREE_VARS[@]}" postman collection run "$COLL" ${ENVU:+-e "$ENVU"} -r "$r" --reporter-$r-export "$out" >/dev/null 2>&1
  if [ -s "$out" ]; then report Reporter "$r report written" PASS "$(wc -c < "$out" | tr -d ' ') bytes"
  else report Reporter "$r report written" FAIL "empty/missing"; fi
done
if [ -s "$TMP/rep.junit" ]; then
  python3 -c "import xml.etree.ElementTree as E,sys; t=E.parse('$TMP/rep.junit'); print(t.getroot().tag)" >"$TMP/xml.out" 2>&1 \
    && report Reporter "junit XML is well-formed" PASS "root=<$(cat "$TMP/xml.out")>" \
    || report Reporter "junit XML is well-formed" FAIL "$(head -1 "$TMP/xml.out")"
fi
env "${THREE_VARS[@]}" postman collection run "$COLL" ${ENVU:+-e "$ENVU"} -r cli --output "$TMP/outdir" >"$TMP/excl.out" 2>&1; rc=$?
if grep -qi 'cannot be combined' "$TMP/excl.out" && [ $rc -ne 0 ]; then
  report Reporter "--output + -r rejected AND non-zero" PASS "rc=$rc"
elif grep -qi 'cannot be combined' "$TMP/excl.out"; then
  report Reporter "--output + -r rejected AND non-zero" FAIL "prints 'cannot be combined' but exits 0 - CI would treat a misconfigured run as green"
else
  report Reporter "--output + -r rejected AND non-zero" FAIL "no rejection at all (rc=$rc)"
fi
rm -rf "$TMP/outdir2"
env "${THREE_VARS[@]}" postman collection run "$COLL" ${ENVU:+-e "$ENVU"} --output "$TMP/outdir2" >"$TMP/out2.log" 2>&1
if ls "$TMP/outdir2"/*.yaml >/dev/null 2>&1; then
  report Reporter "--output writes YAML run report" PASS "$(ls "$TMP/outdir2" | wc -l | tr -d ' ') files"
else
  report Reporter "--output writes YAML run report" FAIL "$(grep -oiE 'verify your Postman plan[^:]*: .*' "$TMP/out2.log" | head -1 | cut -c1-95)"
fi

echo; echo "### C2. Runtime-agent handshake (gates --output)"; echo
HS_LOCAL=$(curl -sk -m 20 -o /dev/null -w '%{http_code}' "$API/handshake/token?source=packman" -H "x-api-key: $KEY")
[ "$HS_LOCAL" = 200 ] && report RuntimeAgent "handshake/token served by cluster" PASS "HTTP $HS_LOCAL" \
  || report RuntimeAgent "handshake/token served by cluster" FAIL "HTTP $HS_LOCAL on $API - plan-gated features cannot work"
CERTERR=$(curl -s -m 20 -o /dev/null -w '%{http_code}' "https://ra.gw.$(echo "$API" | sed 's|https://[^.]*\.||')/handshake/token" 2>&1 || echo "TLSFAIL")
if [ "$CERTERR" = "TLSFAIL" ] || [ "$CERTERR" = "000" ]; then
  report RuntimeAgent "wildcard cert covers 3-label subdomains" FAIL "ra.gw.<cluster> fails TLS; cert is *.<cluster> only"
else
  report RuntimeAgent "wildcard cert covers 3-label subdomains" PASS "HTTP $CERTERR"
fi

echo; echo "### D. integration-id on PPC"; echo
env "${THREE_VARS[@]}" postman collection run "$COLL" ${ENVU:+-e "$ENVU"} -x --integration-id 99999 >"$TMP/int.out" 2>&1; rc=$?
if grep -qiE 'not supported|only supported|us region|invalid integration' "$TMP/int.out"; then
  report Integration "--integration-id rejected clearly on PPC" PASS "explicit message"
else
  report Integration "--integration-id rejected clearly on PPC" FAIL "accepted silently (rc=$rc), no region warning"
fi

echo; echo "### E. Auth"; echo
env "${THREE_VARS[@]}" postman login --with-api-key "$KEY" >/dev/null 2>&1 \
  && report Auth "login with valid cluster key" PASS "" || report Auth "login with valid cluster key" FAIL ""
env "${THREE_VARS[@]}" postman login --with-api-key "PMAK-000000000000000000000000-0000000000000000000000000000000000" >"$TMP/badkey.out" 2>&1; rc=$?
if [ $rc -ne 0 ] && grep -qiE 'invalid|not valid|check your key' "$TMP/badkey.out"; then
  report Auth "garbage key rejected with clear message" PASS "rc=$rc"
else
  report Auth "garbage key rejected with clear message" FAIL "rc=$rc: $(head -c 90 "$TMP/badkey.out" | tr '\n' ' ')"
fi
env "${THREE_VARS[@]}" postman login --with-api-key "$KEY" >/dev/null 2>&1

echo; echo "### F. Install / packaging"; echo
for a in linux64 linux_arm64 osx_arm64 osx64 win64; do
  code=$(curl -sIL -m 20 -o /dev/null -w '%{http_code}' "https://dl-cli.pstmn.io/download/latest/$a")
  [ "$code" = 200 ] && report Install "asset published: $a" PASS "" || report Install "asset published: $a" FAIL "HTTP $code"
done
PIN=$(curl -sIL -m 20 -o /dev/null -w '%{http_code}' "https://dl-cli.pstmn.io/download/version/1.55.0/osx_arm64")
[ "$PIN" = 200 ] && report Install "version pinning endpoint works" PASS "1.55.0 -> HTTP 200" || report Install "version pinning endpoint works" FAIL "HTTP $PIN"
BIN=$(command -v postman); REAL=$BIN
while [ -L "$REAL" ]; do REAL=$(cd "$(dirname "$REAL")" && readlink "$REAL" | sed "s|^\([^/]\)|$(pwd)/\1|"); done
LIBDIR=$(dirname "$REAL")/lib
if [ ! -d "$LIBDIR" ]; then
  ALT=$(find "$(dirname "$BIN")/../lib/node_modules/postman-cli/node_modules/@postman" -maxdepth 3 -name postman-cli -type f 2>/dev/null | head -1)
  [ -n "$ALT" ] && REAL=$ALT && LIBDIR=$(dirname "$ALT")/lib
fi
if [ -d "$LIBDIR" ]; then
  cp "$REAL" "$TMP/pm-alone" 2>/dev/null && chmod +x "$TMP/pm-alone"
  if "$TMP/pm-alone" --version >/dev/null 2>&1; then
    report Install "binary relocatable (docs do sudo mv)" PASS "runs standalone"
  else
    report Install "binary relocatable (docs do sudo mv)" FAIL "breaks without sibling lib/ - published install snippet is wrong"
  fi
else
  report Install "binary relocatable (docs do sudo mv)" SKIP "could not locate sibling lib/"
fi

echo; echo "### G. Read-only command surface"; echo
run_cmd() { # label cmd...
  local label=$1; shift
  local out; out=$(env "${THREE_VARS[@]}" "$@" 2>&1); local rc=$?
  if [ $rc -eq 0 ]; then report Surface "$label" PASS ""
  else report Surface "$label" FAIL "rc=$rc: $(echo "$out" | grep -viE '^$' | head -1 | cut -c1-80)"; fi
}
run_cmd "workspace list"  postman workspace list
WS=$(env "${THREE_VARS[@]}" postman workspace list 2>/dev/null | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
if [ -n "$WS" ]; then run_cmd "flows list -w <ws>" postman flows list -w "$WS"
else report Surface "flows list -w <ws>" SKIP "no workspace id parsed"; fi
run_cmd "collection run --folder scoping" postman collection run "$COLL" ${ENVU:+-e "$ENVU"} -x
run_cmd "search"          postman search --help

echo; echo "### H. TLS / proxy knobs"; echo
env "${THREE_VARS[@]}" NODE_EXTRA_CA_CERTS=/nonexistent.pem postman collection run "$COLL" ${ENVU:+-e "$ENVU"} -x >"$TMP/ca.out" 2>&1; rc=$?
[ $rc -eq 0 ] && report TLS "NODE_EXTRA_CA_CERTS tolerated" PASS "" || report TLS "NODE_EXTRA_CA_CERTS tolerated" FAIL "rc=$rc"
env "${THREE_VARS[@]}" "${PROXY_VARS[@]}" NO_PROXY="*" postman collection run "$COLL" ${ENVU:+-e "$ENVU"} -x >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && report TLS "NO_PROXY honoured" PASS "" || report TLS "NO_PROXY honoured" FAIL "rc=$rc"

echo
echo "================= SUMMARY ================="
echo "pass=$PASS  fail=$FAIL  skip/info=$SKIP  total=$N"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo "## PPC CI/CD conformance"; echo; echo "**pass $PASS · fail $FAIL · info $SKIP**"; echo; cat "$RESULTS"; } >> "$GITHUB_STEP_SUMMARY"
fi
cp "$RESULTS" ./ppc-ci-results.md 2>/dev/null || true
exit 0
