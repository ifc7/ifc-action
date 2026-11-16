#!/usr/bin/env bash
# Tests scripts/push.sh against stub ifc and curl binaries.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/scripts/push.sh"
failures=0

push_result='{"interfaces":[
  {"name":"rest-api","ref":"ifc7.dev/i/acme/rest-api","path":"api/v0.yaml","status":"pushed","revisionIds":["revision_1"]},
  {"name":"billing-api","ref":"ifc7.dev/i/acme/billing-api","path":"api/billing/v0.yaml","status":"up_to_date"},
  {"name":"new-api","path":"api/new.yaml","status":"skipped","reason":"no ref in ifc.yaml"}
]}'

# setup creates a sandbox with stub binaries and a git repo, and sets the globals used by run.
setup() {
  sandbox="$(mktemp -d)"
  mkdir -p "$sandbox/bin" "$sandbox/repo" "$sandbox/runner"
  export RUNNER_TEMP="$sandbox/runner"
  export GITHUB_OUTPUT="$sandbox/output"
  export GITHUB_STEP_SUMMARY="$sandbox/summary"
  export GITHUB_REPOSITORY="ifc7/example"
  export STUB_LOG="$sandbox/calls"
  export STUB_PUSH_RESULT="$push_result"
  export STUB_PUSH_EXIT=0
  # Space-separated statuses for successive exchange calls; the last one repeats.
  export STUB_EXCHANGE_STATUSES=200
  export STUB_EXCHANGE_MESSAGE="no trust matches: ref refs/heads/feature does not match refs/heads/main"
  export IFC_EXCHANGE_RETRY_DELAY=0
  export STUB_OLD_CLI=""
  export ACTIONS_ID_TOKEN_REQUEST_URL="https://token.example/req?api-version=2.0"
  export ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-token"
  export INPUT_HUB_URL="https://ifc7.dev/"
  export INPUT_AUDIENCE=""
  export INPUT_ORGANIZATION="acme"
  export INPUT_AGENT=""
  export INPUT_TOKEN=""
  export INPUT_NOTES=""
  export INPUT_WORKING_DIRECTORY="."
  : >"$STUB_LOG"

  cat >"$sandbox/bin/ifc" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 ${2:-}" == "push --help" ]]; then
  [[ -n "$STUB_OLD_CLI" ]] && echo "Usage: ifc push [ref]" || echo "      --json   print results as JSON"
  exit 0
fi
printf 'ifc %s | token=%s hub=%s\n' "$*" "${IFC_TOKEN:-}" "${IFC_HUB_URL:-}" >>"$STUB_LOG"
if [[ "$1" == "push" ]]; then
  printf '%s\n' "$STUB_PUSH_RESULT"
  exit "$STUB_PUSH_EXIT"
fi
EOF

  cat >"$sandbox/bin/curl" <<'EOF'
#!/usr/bin/env bash
args="$*"
if [[ "$args" == *"token.example"* ]]; then
  printf 'curl oidc %s\n' "${args##* }" >>"$STUB_LOG"
  echo '{"value":"github-oidc-jwt"}'
elif [[ "$args" == *"/api/v0/auth/github-oidc/token"* ]]; then
  if [[ -n "${STUB_EXCHANGE_UNREACHABLE:-}" ]]; then
    echo "curl: (6) Could not resolve host" >&2
    exit 6
  fi
  body="$(cat)"
  printf 'curl exchange %s body=%s\n' "${args##* }" "$(jq -c . <<<"$body")" >>"$STUB_LOG"
  read -ra statuses <<<"$STUB_EXCHANGE_STATUSES"
  n=$(grep -c '^curl exchange' "$STUB_LOG")
  i=$((n <= ${#statuses[@]} ? n - 1 : ${#statuses[@]} - 1))
  code="${statuses[$i]}"
  if [[ "$code" == "200" ]]; then
    printf '{"access_token":"ifc_agt_access","token_type":"Bearer","expires_in":900}\n200'
  else
    jq -cn --argjson c "$code" --arg m "$STUB_EXCHANGE_MESSAGE" '{code: $c, message: $m}'
    printf '%s' "$code"
  fi
else
  echo "unexpected curl $args" >&2
  exit 1
fi
EOF
  chmod +x "$sandbox/bin/ifc" "$sandbox/bin/curl"

  git -C "$sandbox/repo" init -q
  git -C "$sandbox/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "Add billing endpoints"
  head_sha="$(git -C "$sandbox/repo" rev-parse HEAD)"
}

# run executes push.sh in the sandbox repo, capturing stdout+stderr and the exit status.
run() {
  out="$(cd "$sandbox/repo" && PATH="$sandbox/bin:$PATH" bash "$script" 2>&1)"
  status=$?
}

check() {
  local desc="$1"
  shift
  if "$@"; then
    return 0
  fi
  echo "    FAIL: $desc"
  failures=$((failures + 1))
  return 1
}

contains() { [[ "$1" == *"$2"* ]]; }
not_contains() { [[ "$1" != *"$2"* ]]; }

test_case() {
  echo "--- $1"
  setup
}

test_case "OIDC exchange pushes changed interfaces and reports results"
run
calls="$(cat "$STUB_LOG")"
check "exits 0" [ "$status" -eq 0 ]
check "requests OIDC token with the hub host as audience" contains "$calls" "curl oidc https://token.example/req?api-version=2.0&audience=ifc7.dev"
check "sends token and organization, no agent" contains "$calls" \
  'curl exchange https://ifc7.dev/api/v0/auth/github-oidc/token body={"token":"github-oidc-jwt","organization":"acme"}'
check "exchanges once" [ "$(grep -c '^curl exchange' "$STUB_LOG")" -eq 1 ]
check "fetches owned interfaces with exchanged token" contains "$calls" "ifc fetch --owned --non-interactive | token=ifc_agt_access hub=https://ifc7.dev"
check "commits with subject and short sha" contains "$calls" "ifc commit --non-interactive --notes Add billing endpoints (${head_sha:0:7})"
check "pushes as JSON" contains "$calls" "ifc push --non-interactive --json"
check "masks OIDC token" contains "$out" "::add-mask::github-oidc-jwt"
check "masks access token" contains "$out" "::add-mask::ifc_agt_access"
check "warns about skipped interface" contains "$out" '::warning file=ifc.yaml,title=ifc7 interface skipped::Skipped "new-api": no ref in ifc.yaml'
check "outputs pushed names" grep -qx 'pushed=\["rest-api"\]' "$GITHUB_OUTPUT"
check "outputs skipped names" grep -qx 'skipped=\["new-api"\]' "$GITHUB_OUTPUT"
check "outputs single-line result" grep -q '^result={"interfaces":\[' "$GITHUB_OUTPUT"
check "writes summary row" grep -q '| rest-api | ifc7.dev/i/acme/rest-api | pushed |' "$GITHUB_STEP_SUMMARY"

test_case "token input skips the OIDC exchange"
export INPUT_TOKEN="explicit-token"
run
calls="$(cat "$STUB_LOG")"
check "exits 0" [ "$status" -eq 0 ]
check "does not call curl" not_contains "$calls" "curl"
check "passes token to ifc" contains "$calls" "token=explicit-token"
check "masks token" contains "$out" "::add-mask::explicit-token"

test_case "notes input overrides the commit subject"
export INPUT_NOTES="Release prep"
run
check "uses notes input" contains "$(cat "$STUB_LOG")" "ifc commit --non-interactive --notes Release prep |"

test_case "missing id-token permission fails with guidance"
unset ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN
run
check "exits non-zero" [ "$status" -ne 0 ]
check "explains permission" contains "$out" "permissions: id-token: write"
check "does not run ifc" not_contains "$(cat "$STUB_LOG")" "ifc fetch"

test_case "agent input is sent in the exchange body"
export INPUT_AGENT="ci-publisher"
run
check "exits 0" [ "$status" -eq 0 ]
check "sends agent" contains "$(cat "$STUB_LOG")" \
  'body={"token":"github-oidc-jwt","organization":"acme","agent":"ci-publisher"}'

test_case "audience defaults to the hub-url host"
export INPUT_HUB_URL="https://user@hub.example.com:8443/hub/"
run
calls="$(cat "$STUB_LOG")"
check "requests the hub host as audience" contains "$calls" "audience=hub.example.com"$'\n'
check "exchanges at the hub path" contains "$calls" "curl exchange https://user@hub.example.com:8443/hub/api/v0/auth/github-oidc/token"
check "passes hub to ifc" contains "$calls" "hub=https://user@hub.example.com:8443/hub"

test_case "audience input overrides the default"
export INPUT_HUB_URL="https://hub.example.com"
export INPUT_AUDIENCE="custom aud"
run
check "requests the given audience, URL-encoded" contains "$(cat "$STUB_LOG")" "audience=custom%20aud"

test_case "missing organization fails before requesting a GitHub token"
export INPUT_ORGANIZATION=""
run
check "exits non-zero" [ "$status" -ne 0 ]
check "names the input" contains "$out" "Set the 'organization' input"
check "does not call curl" not_contains "$(cat "$STUB_LOG")" "curl"

test_case "token input does not need organization"
export INPUT_ORGANIZATION=""
export INPUT_TOKEN="explicit-token"
run
check "exits 0" [ "$status" -eq 0 ]

# exchange_fails runs an exchange that the hub answers with the given status and checks
# that the job fails with the hub's message and the expected hint, without running ifc.
exchange_fails() {
  local code="$1" hint="$2"
  test_case "exchange HTTP $code fails with the hub's message"
  export STUB_EXCHANGE_STATUSES="$code"
  export STUB_EXCHANGE_MESSAGE="server says $code"
  run
  check "exits non-zero" [ "$status" -ne 0 ]
  check "reports status and message" contains "$out" "::error title=ifc7 push::ifc7 rejected the GitHub OIDC token exchange (HTTP $code: server says $code)."
  check "gives a hint" contains "$out" "$hint"
  check "does not run ifc" not_contains "$(cat "$STUB_LOG")" "ifc fetch"
}

exchange_fails 400 "check the 'organization' input"
exchange_fails 401 "invalid or expired. Check that the 'audience' input (ifc7.dev) is the audience the hub expects"
exchange_fails 403 "No GitHub trust on an agent of organization 'acme' matches this workflow (ifc7/example,"
exchange_fails 404 "exchange is turned off on https://ifc7.dev"
exchange_fails 409 "Set the 'agent' input"
exchange_fails 500 "Check 'hub-url', or re-run the job."
check "500 is not retried" [ "$(grep -c '^curl exchange' "$STUB_LOG")" -eq 1 ]

test_case "exchange HTTP 403 shows the unmet condition"
export STUB_EXCHANGE_STATUSES=403
export GITHUB_REF="refs/heads/feature" GITHUB_EVENT_NAME="push"
run
check "shows server message" contains "$out" "(HTTP 403: no trust matches: ref refs/heads/feature does not match refs/heads/main)"
check "names ref and event" contains "$out" "(ifc7/example, refs/heads/feature, push)"
unset GITHUB_REF GITHUB_EVENT_NAME

test_case "exchange HTTP 503 is retried once and can succeed"
export STUB_EXCHANGE_STATUSES="503 200"
run
check "exits 0" [ "$status" -eq 0 ]
check "exchanges twice" [ "$(grep -c '^curl exchange' "$STUB_LOG")" -eq 2 ]
check "says it is retrying" contains "$out" "Retrying in 0s"
check "uses the token from the retry" contains "$(cat "$STUB_LOG")" "token=ifc_agt_access"

test_case "exchange HTTP 503 twice fails"
export STUB_EXCHANGE_STATUSES="503"
export STUB_EXCHANGE_MESSAGE="not ready"
run
check "exits non-zero" [ "$status" -ne 0 ]
check "exchanges exactly twice" [ "$(grep -c '^curl exchange' "$STUB_LOG")" -eq 2 ]
check "reports status and message" contains "$out" "(HTTP 503: not ready)"
check "asks to re-run" contains "$out" "Re-run the job shortly"
check "does not run ifc" not_contains "$(cat "$STUB_LOG")" "ifc fetch"

test_case "unreachable hub fails"
export STUB_EXCHANGE_UNREACHABLE=1
run
check "exits non-zero" [ "$status" -ne 0 ]
check "reports unreachable hub" contains "$out" "Failed to reach https://ifc7.dev"
unset STUB_EXCHANGE_UNREACHABLE

test_case "failed push still reports partial results"
export STUB_PUSH_EXIT=1
run
check "exits with push status" [ "$status" -eq 1 ]
check "reports failure" contains "$out" "'ifc push' failed with exit code 1"
check "still outputs pushed names" grep -qx 'pushed=\["rest-api"\]' "$GITHUB_OUTPUT"

test_case "unreadable push output fails"
export STUB_PUSH_RESULT="Pushed revision for \"rest-api\"."
run
check "exits non-zero" [ "$status" -ne 0 ]
check "reports unreadable result" contains "$out" "produced no readable result"

test_case "old CLI without --json fails before authenticating"
export STUB_OLD_CLI=1
run
check "exits non-zero" [ "$status" -ne 0 ]
check "explains version requirement" contains "$out" "does not support non-interactive pushes"
check "does not call curl" not_contains "$(cat "$STUB_LOG")" "curl"

test_case "annotations point at ifc.yaml in the working directory"
export INPUT_WORKING_DIRECTORY="services/api/"
run
check "uses working directory path" contains "$out" "::warning file=services/api/ifc.yaml,"

echo
if [[ "$failures" -gt 0 ]]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All checks passed"
