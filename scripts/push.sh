#!/usr/bin/env bash
# Pushes new ifc7.dev revisions for every owned interface in ifc.yaml whose file changed.
#
# Inputs (environment):
#   INPUT_HUB_URL            Base URL of the ifc7 hub (e.g. https://ifc7.dev)
#   INPUT_AUDIENCE           Audience requested for the GitHub OIDC token; defaults to the hub-url host
#   INPUT_ORGANIZATION       Slug of the ifc7 organization whose agent the workflow acts as
#   INPUT_AGENT              Optional agent name or ID, when several agents trust the workflow
#   INPUT_TOKEN              Optional ifc7 access token; skips the OIDC exchange
#   INPUT_NOTES              Optional revision notes; defaults to "<commit subject> (<short sha>)"
#   INPUT_WORKING_DIRECTORY  Directory containing ifc.yaml, relative to the repo root (for annotations)
set -euo pipefail

hub_url="${INPUT_HUB_URL:-https://ifc7.dev}"
hub_url="${hub_url%/}"
organization="${INPUT_ORGANIZATION:-}"
agent="${INPUT_AGENT:-}"
# How long to wait before retrying an exchange the hub answered with 503.
retry_delay="${IFC_EXCHANGE_RETRY_DELAY:-5}"

# url_host prints the host of a URL, without scheme, credentials, port or path.
url_host() {
  local h="${1#*://}"
  h="${h%%/*}"
  h="${h##*@}"
  h="${h%:*}"
  printf '%s' "$h"
}

audience="${INPUT_AUDIENCE:-$(url_host "$hub_url")}"
working_directory="${INPUT_WORKING_DIRECTORY:-.}"
result_file="${RUNNER_TEMP:-/tmp}/ifc-push-result.json"

# escape_data escapes a value for use in a workflow command message.
escape_data() {
  local s="$1"
  s="${s//'%'/%25}"
  s="${s//$'\r'/%0D}"
  s="${s//$'\n'/%0A}"
  printf '%s' "$s"
}

error() {
  echo "::error title=ifc7 push::$(escape_data "$*")"
}

# require_cli fails early when the installed ifc CLI predates non-interactive support.
require_cli() {
  if ! command -v ifc >/dev/null 2>&1; then
    error "The ifc CLI is not installed."
    return 1
  fi
  if ! ifc push --help 2>&1 | grep -q -- '--json'; then
    error "The installed ifc CLI does not support non-interactive pushes ('ifc push --json'). Set 'ifc-version' to a release that does."
    return 1
  fi
}

# exchange posts the GitHub OIDC token to the hub and sets the caller's status and
# body. A transport failure leaves status empty.
exchange() {
  local response
  status=""
  body=""
  if ! response=$(jq -n --arg t "$1" --arg o "$organization" --arg a "$agent" \
    '{token: $t, organization: $o} + (if $a == "" then {} else {agent: $a} end)' |
    curl -sS -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' --data @- \
      "$hub_url/api/v0/auth/github-oidc/token"); then
    return
  fi
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"
}

# exchange_error reports a failed exchange, with the hub's message and a hint for the status.
exchange_error() {
  local status="$1" body="$2" message hint
  if [[ -z "$status" ]]; then
    error "Failed to reach $hub_url to exchange the GitHub OIDC token."
    return
  fi
  message=$(jq -r '.message // .error // empty' <<<"$body" 2>/dev/null || true)
  case "$status" in
    400) hint="The exchange request was malformed; check the 'organization' input." ;;
    401) hint="The GitHub OIDC token is invalid or expired. Check that the 'audience' input ($audience) is the audience the hub expects." ;;
    403) hint="No GitHub trust on an agent of organization '$organization' matches this workflow (${GITHUB_REPOSITORY:-this repository}, ${GITHUB_REF:-this ref}, ${GITHUB_EVENT_NAME:-this event}). An organization admin must add or fix the trust." ;;
    404) hint="GitHub OIDC exchange is turned off on $hub_url. Check 'hub-url', or pass the 'token' input." ;;
    409) hint="Several agents in organization '$organization' trust this workflow. Set the 'agent' input to choose one." ;;
    503) hint="The hub still isn't ready to verify GitHub tokens. Re-run the job shortly." ;;
    *) hint="Check 'hub-url', or re-run the job." ;;
  esac
  error "ifc7 rejected the GitHub OIDC token exchange (HTTP $status${message:+: $message}). $hint"
}

# authenticate sets IFC_TOKEN, either from the token input or by exchanging a GitHub
# OIDC token at the hub. It assigns a global rather than printing the token, so the
# ::add-mask:: commands reach the runner instead of a command substitution.
authenticate() {
  if [[ -n "${INPUT_TOKEN:-}" ]]; then
    echo "::add-mask::$INPUT_TOKEN"
    IFC_TOKEN="$INPUT_TOKEN"
    return
  fi
  if [[ -z "$organization" ]]; then
    error "Set the 'organization' input to the slug of the ifc7 organization whose agent this workflow acts as, or pass the 'token' input."
    return 1
  fi
  if [[ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" || -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]]; then
    error "GitHub OIDC is unavailable. Grant the job 'permissions: id-token: write', or pass the 'token' input."
    return 1
  fi

  local encoded_audience oidc_response oidc_token
  encoded_audience=$(jq -rn --arg a "$audience" '$a | @uri')
  if ! oidc_response=$(curl -fsS -H "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
    "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$encoded_audience"); then
    error "Failed to request a GitHub OIDC token."
    return 1
  fi
  oidc_token=$(jq -r '.value // empty' <<<"$oidc_response")
  if [[ -z "$oidc_token" ]]; then
    error "GitHub returned an empty OIDC token."
    return 1
  fi
  echo "::add-mask::$oidc_token"

  local status body
  exchange "$oidc_token"
  if [[ "$status" == "503" ]]; then
    echo "The hub isn't ready to verify GitHub tokens yet (HTTP 503). Retrying in ${retry_delay}s."
    sleep "$retry_delay"
    exchange "$oidc_token"
  fi
  if [[ "$status" != "200" ]]; then
    exchange_error "$status" "$body"
    return 1
  fi
  IFC_TOKEN=$(jq -r '.access_token // empty' <<<"$body")
  if [[ -z "$IFC_TOKEN" ]]; then
    error "ifc7 returned no access token."
    return 1
  fi
  echo "::add-mask::$IFC_TOKEN"
}

revision_notes() {
  if [[ -n "${INPUT_NOTES:-}" ]]; then
    printf '%s' "$INPUT_NOTES"
    return
  fi
  local sha subject
  sha=$(git rev-parse HEAD 2>/dev/null || printf '%s' "${GITHUB_SHA:-}")
  subject=$(git log -1 --format=%s "$sha" 2>/dev/null || true)
  if [[ -z "$sha" ]]; then
    printf 'Pushed by GitHub Actions'
  elif [[ -z "$subject" ]]; then
    printf '%s' "${sha:0:7}"
  else
    printf '%s (%s)' "$subject" "${sha:0:7}"
  fi
}

# report turns the push result into annotations, step outputs, and a job summary.
report() {
  local config_file="ifc.yaml"
  if [[ "$working_directory" != "." ]]; then
    config_file="${working_directory%/}/ifc.yaml"
  fi

  local name reason
  while IFS=$'\t' read -r name reason; do
    echo "::warning file=$config_file,title=ifc7 interface skipped::$(escape_data "Skipped \"$name\": $reason")"
  done < <(jq -r '.interfaces[] | select(.status == "skipped") | [.name, (.reason // "skipped")] | @tsv' "$result_file")

  {
    echo "pushed=$(jq -c '[.interfaces[] | select(.status == "pushed") | .name]' "$result_file")"
    echo "skipped=$(jq -c '[.interfaces[] | select(.status == "skipped") | .name]' "$result_file")"
    echo "result=$(jq -c . "$result_file")"
  } >> "${GITHUB_OUTPUT:-/dev/null}"

  {
    echo "### ifc7 push"
    echo
    echo "| Interface | Ref | Status |"
    echo "| --- | --- | --- |"
    jq -r '.interfaces[] | "| \(.name) | \(.ref // "") | \(.status)\(if .reason then " (\(.reason))" else "" end) |"' "$result_file"
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
}

main() {
  require_cli
  authenticate
  export IFC_TOKEN
  export IFC_HUB_URL="$hub_url"

  local notes
  notes=$(revision_notes)

  ifc fetch --owned --non-interactive
  ifc commit --non-interactive --notes "$notes"

  local push_status=0
  ifc push --non-interactive --json >"$result_file" || push_status=$?

  if jq -e '.interfaces | type == "array"' "$result_file" >/dev/null 2>&1; then
    report
  elif [[ "$push_status" -eq 0 ]]; then
    error "'ifc push --json' produced no readable result."
    return 1
  fi
  if [[ "$push_status" -ne 0 ]]; then
    error "'ifc push' failed with exit code $push_status."
    return "$push_status"
  fi
}

main "$@"
