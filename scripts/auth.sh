#!/usr/bin/env bash
# Shared helpers for the action's scripts: workflow-command escaping and authentication to the
# ifc7 hub. Source it after setting hub_url, organization, agent, audience and retry_delay, and
# after defining error MESSAGE.
# shellcheck disable=SC2154 # hub_url, organization, agent, audience and retry_delay are set by the caller.

# url_host prints the host of a URL, without scheme, credentials, port or path.
url_host() {
  local h="${1#*://}"
  h="${h%%/*}"
  h="${h##*@}"
  h="${h%:*}"
  printf '%s' "$h"
}

# escape_data escapes a value for use in a workflow command message.
escape_data() {
  local s="$1"
  s="${s//'%'/%25}"
  s="${s//$'\r'/%0D}"
  s="${s//$'\n'/%0A}"
  printf '%s' "$s"
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
