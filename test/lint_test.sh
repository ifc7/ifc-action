#!/usr/bin/env bash
# Tests scripts/lint.sh against stub ifc and curl binaries.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/scripts/lint.sh"
failures=0

# A blocked push gate: one interface with an error, a warning, a hint and a waived finding, the
# other one not checked at all.
lint_result='{"passed": false, "interfaces": [
  {"name": "rest-api", "ref": "ifc7.dev/i/acme/rest-api", "path": "api/v0.yaml",
   "policy": {"source": "hub", "rulesetSha256": "abc", "waivers": 1, "gates": 2},
   "baseline": {"source": "release", "version": "v1.0.0"},
   "pluginId": "openapi-lint@v2", "rulesetSha256": "abc", "score": 74,
   "findings": [
     {"ruleId": "operation-operationId", "severity": "error", "message": "missing operationId", "pointer": "/paths/~1owners/get", "range": {"start": {"line": 22, "column": 5}, "end": {"line": 22, "column": 8}}, "fingerprint": "f1", "status": "open"},
     {"ruleId": "info-contact", "severity": "warn", "message": "no contact", "pointer": "/info", "fingerprint": "f2", "status": "open"},
     {"ruleId": "description-duplication", "severity": "hint", "message": "duplicate", "pointer": "", "fingerprint": "f3", "status": "open"},
     {"ruleId": "operation-operationId", "severity": "error", "message": "missing operationId", "pointer": "/paths/~1pets/get", "range": {"start": {"line": 15, "column": 5}, "end": {"line": 15, "column": 8}}, "fingerprint": "f4", "status": "waived", "waiverId": "waiver_1"}
   ],
   "compare": {"pluginId": "openapi-compare@v1", "against": "v1.0.0", "breaking": true, "changes": [
     {"kind": "pathItem.operation.removed", "pointer": "/paths/~1pets/delete", "breaking": true, "level": "error", "message": "removed delete", "fingerprint": "c1"}]},
   "outcome": {"stage": "push", "passed": false, "advisoryFailed": true, "score": 74, "breakingChanges": 1, "gates": [
     {"gate": "no-breaking", "enforcement": "blocking", "passed": false, "reasons": [{"code": "breaking_change", "message": "1 breaking change(s) against v1.0.0", "count": 1}]},
     {"gate": "score", "enforcement": "advisory", "passed": false, "reasons": [{"code": "min_score", "message": "score 74 is below the minimum 95"}]},
     {"gate": "new-errors", "enforcement": "blocking", "passed": true}]}},
  {"name": "new-api", "path": "api/new.yaml", "error": "api/new.yaml is not an owned interface with a ref in ifc.yaml"}
]}'

passed_result='{"passed": true, "interfaces": [
  {"name": "rest-api", "path": "api/v0.yaml", "policy": {"source": "default", "rulesetSha256": "abc", "waivers": 0, "gates": 0},
   "pluginId": "openapi-lint@v2", "rulesetSha256": "abc", "score": 98, "findings": []}
]}'

setup() {
  sandbox="$(mktemp -d)"
  mkdir -p "$sandbox/bin" "$sandbox/repo" "$sandbox/runner"
  export RUNNER_TEMP="$sandbox/runner"
  export GITHUB_OUTPUT="$sandbox/output"
  export GITHUB_STEP_SUMMARY="$sandbox/summary"
  export GITHUB_REPOSITORY="ifc7/example"
  export STUB_LOG="$sandbox/calls"
  export STUB_LINT_RESULT="$lint_result"
  export STUB_LINT_EXIT=2
  export STUB_OLD_CLI=""
  export IFC_EXCHANGE_RETRY_DELAY=0
  export ACTIONS_ID_TOKEN_REQUEST_URL="https://token.example/req?api-version=2.0"
  export ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-token"
  export INPUT_HUB_URL="https://ifc7.dev"
  export INPUT_AUDIENCE="" INPUT_ORGANIZATION="acme" INPUT_AGENT="" INPUT_TOKEN=""
  export INPUT_WORKING_DIRECTORY="."
  export INPUT_INTERFACES="" INPUT_GATE="push" INPUT_HUB="false" INPUT_RELEASE_VERSION=""
  export INPUT_RULESET="" INPUT_BASELINE="" INPUT_BASELINE_VERSION="" INPUT_FAIL_ON="" INPUT_MIN_SCORE=""
  export INPUT_BREAKING="" INPUT_NEW_ONLY="false" INPUT_STRICT="false" INPUT_ANNOTATIONS="warn"
  : >"$STUB_LOG"

  cat >"$sandbox/bin/ifc" <<'STUB'
#!/usr/bin/env bash
if [[ "$1 ${2:-}" == "lint --help" ]]; then
  [[ -n "$STUB_OLD_CLI" ]] && echo "  -v, --verbose" || echo "      --gate string   evaluate the hub's gates"
  exit 0
fi
printf 'ifc %s | token=%s hub=%s\n' "$*" "${IFC_TOKEN:-}" "${IFC_HUB_URL:-}" >>"$STUB_LOG"
printf '%s\n' "$STUB_LINT_RESULT"
exit "$STUB_LINT_EXIT"
STUB

  cat >"$sandbox/bin/curl" <<'STUB'
#!/usr/bin/env bash
args="$*"
if [[ "$args" == *"token.example"* ]]; then
  printf 'curl oidc %s\n' "${args##* }" >>"$STUB_LOG"
  echo '{"value":"github-oidc-jwt"}'
elif [[ "$args" == *"/api/v0/auth/github-oidc/token"* ]]; then
  printf 'curl exchange %s body=%s\n' "${args##* }" "$(jq -c . <<<"$(cat)")" >>"$STUB_LOG"
  printf '{"access_token":"ifc_agt_access","token_type":"Bearer","expires_in":900}\n200'
else
  echo "unexpected curl $args" >&2
  exit 1
fi
STUB
  chmod +x "$sandbox/bin/ifc" "$sandbox/bin/curl"
}

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

test_case "a blocked push gate fails the job with annotations, outputs and a summary"
run
calls="$(cat "$STUB_LOG")"
summary="$(cat "$GITHUB_STEP_SUMMARY")"
check "exits 2" [ "$status" -eq 2 ]
check "exchanges the GitHub OIDC token" contains "$calls" 'body={"token":"github-oidc-jwt","organization":"acme"}'
check "runs ifc lint --gate push with the agent token" contains "$calls" "ifc lint --json --gate push | token=ifc_agt_access hub=https://ifc7.dev"
check "annotates the error at its line" contains "$out" "::error file=api/v0.yaml,line=22,title=error operation-operationId::missing operationId (/paths/~1owners/get)"
check "annotates the warning without a line" contains "$out" "::warning file=api/v0.yaml,title=warn info-contact::no contact (/info)"
check "skips the hint" not_contains "$out" "description-duplication"
check "skips the waived finding" not_contains "$out" "/paths/~1pets/get"
check "annotates the blocking gate as an error" contains "$out" "::error file=api/v0.yaml,title=ifc7 gate no-breaking (blocking) failed::1 breaking change(s) against v1.0.0"
check "annotates the advisory gate as a warning" contains "$out" "::warning file=api/v0.yaml,title=ifc7 gate score (advisory) failed::score 74 is below the minimum 95"
check "does not annotate passed gates" not_contains "$out" "gate new-errors"
check "annotates the interface that could not be checked" contains "$out" "::error file=api/new.yaml,title=ifc7 lint failed::api/new.yaml is not an owned interface"
check "says a gate failed" contains "$out" "::error title=ifc7 lint::A governance gate failed."
check "outputs passed=false" grep -qx 'passed=false' "$GITHUB_OUTPUT"
check "outputs single-line result" grep -q '^result={"passed":false,"interfaces":\[' "$GITHUB_OUTPUT"
check "summary heading names the gate" contains "$summary" "### ifc7 lint (gate: push)"
check "summary row" contains "$summary" "| rest-api | 74 | 1 error, 1 hint, 1 warn (1 waived) | release v1.0.0: 1 breaking | ❌ no-breaking: 1 breaking change(s) against v1.0.0<br>⚠️ score: score 74 is below the minimum 95<br>✅ new-errors |"
check "summary row for the failed interface" contains "$summary" "| new-api | – | – | – | ❌ api/new.yaml is not an owned interface"
check "summary says gates failed" contains "$summary" "**Gates failed.**"

test_case "inputs map to ifc lint flags"
export INPUT_GATE="release" INPUT_RELEASE_VERSION="2.0.0" INPUT_BASELINE="old.yaml" INPUT_BASELINE_VERSION="1.4.0"
export INPUT_FAIL_ON="warn" INPUT_MIN_SCORE="80" INPUT_BREAKING="requireMajor" INPUT_NEW_ONLY="true" INPUT_STRICT="TRUE"
export INPUT_INTERFACES=$'rest-api\n  billing-api api/extra.yaml'
export STUB_LINT_RESULT="$passed_result" STUB_LINT_EXIT=0
run
check "exits 0" [ "$status" -eq 0 ]
check "passes every flag and target" contains "$(cat "$STUB_LOG")" \
  "ifc lint --json --gate release --release-version 2.0.0 --baseline old.yaml --baseline-version 1.4.0 --fail-on warn --min-score 80 --breaking requireMajor --new-only --strict rest-api billing-api api/extra.yaml |"
check "outputs passed=true" grep -qx 'passed=true' "$GITHUB_OUTPUT"
check "summary says gates passed" contains "$(cat "$GITHUB_STEP_SUMMARY")" "All gates passed."

test_case "without hub gates no token is needed"
export INPUT_GATE="" INPUT_ORGANIZATION="" INPUT_FAIL_ON="error"
export STUB_LINT_RESULT="$passed_result" STUB_LINT_EXIT=0
unset ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN
run
calls="$(cat "$STUB_LOG")"
check "exits 0" [ "$status" -eq 0 ]
check "does not call curl" not_contains "$calls" "curl"
check "runs without --gate or --hub" contains "$calls" "ifc lint --json --fail-on error | token= hub=https://ifc7.dev"
check "summary shows no gates" contains "$(cat "$GITHUB_STEP_SUMMARY")" "| rest-api | 98 | none | – | – |"

test_case "hub input lints with the hub's policy without gates"
export INPUT_GATE="" INPUT_HUB="true"
export STUB_LINT_RESULT="$passed_result" STUB_LINT_EXIT=0
run
check "exits 0" [ "$status" -eq 0 ]
check "authenticates and passes --hub" contains "$(cat "$STUB_LOG")" "ifc lint --json --hub | token=ifc_agt_access"

test_case "a ruleset with the hub's gates fails before linting"
export INPUT_RULESET="openlint.yaml"
run
check "exits non-zero" [ "$status" -ne 0 ]
check "explains how to fix it" contains "$out" "Set 'gate' to ''"
check "does not run ifc lint" not_contains "$(cat "$STUB_LOG")" "ifc lint"

test_case "a ruleset without gates is passed through"
export INPUT_RULESET="openlint.yaml" INPUT_GATE="" INPUT_FAIL_ON="error"
export STUB_LINT_RESULT="$passed_result" STUB_LINT_EXIT=0
run
check "exits 0" [ "$status" -eq 0 ]
check "passes --ruleset" contains "$(cat "$STUB_LOG")" "ifc lint --json --ruleset openlint.yaml --fail-on error |"

test_case "annotations input sets the lowest severity annotated"
export INPUT_ANNOTATIONS="error"
run
check "annotates the error" contains "$out" "title=error operation-operationId"
check "skips the warning" not_contains "$out" "info-contact"
setup
export INPUT_ANNOTATIONS="none"
run
check "none annotates no findings" not_contains "$out" "operation-operationId"
check "none still annotates gates" contains "$out" "ifc7 gate no-breaking"

test_case "annotations point into the working directory"
export INPUT_WORKING_DIRECTORY="services/api/"
run
check "prefixes the file" contains "$out" "::error file=services/api/api/v0.yaml,line=22,"

test_case "the hub's gates need authentication"
unset ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN
run
check "exits non-zero" [ "$status" -ne 0 ]
check "explains the permission" contains "$out" "permissions: id-token: write"
check "does not run ifc lint" not_contains "$(cat "$STUB_LOG")" "ifc lint"

test_case "token input skips the OIDC exchange"
export INPUT_TOKEN="explicit-token" INPUT_ORGANIZATION=""
run
check "does not call curl" not_contains "$(cat "$STUB_LOG")" "curl"
check "passes the token" contains "$(cat "$STUB_LOG")" "token=explicit-token"
check "masks the token" contains "$out" "::add-mask::explicit-token"

test_case "an old CLI fails with guidance"
export STUB_OLD_CLI=1
run
check "exits non-zero" [ "$status" -ne 0 ]
check "explains the version" contains "$out" "does not support governance gates"
check "does not call curl" not_contains "$(cat "$STUB_LOG")" "curl"

test_case "other lint failures keep their exit code"
export STUB_LINT_EXIT=1
run
check "exits 1" [ "$status" -eq 1 ]
check "reports the exit code" contains "$out" "'ifc lint' failed with exit code 1."
check "still writes outputs" grep -qx 'passed=false' "$GITHUB_OUTPUT"

test_case "unreadable lint output fails"
export STUB_LINT_RESULT="Error: error loading project config" STUB_LINT_EXIT=1
run
check "exits 1" [ "$status" -eq 1 ]
check "reports unreadable result" contains "$out" "produced no readable result (exit code 1)"

echo
if [[ "$failures" -gt 0 ]]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All checks passed"
