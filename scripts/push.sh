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

# shellcheck source=auth.sh
source "$(dirname "${BASH_SOURCE[0]}")/auth.sh"

audience="${INPUT_AUDIENCE:-$(url_host "$hub_url")}"
working_directory="${INPUT_WORKING_DIRECTORY:-.}"
result_file="${RUNNER_TEMP:-/tmp}/ifc-push-result.json"

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
