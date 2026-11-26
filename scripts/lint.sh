#!/usr/bin/env bash
# Lints owned interfaces with `ifc lint` and checks ifc7 governance gates, reporting findings as
# annotations and the gate outcome in the job summary. Fails when a gate blocks.
#
# Inputs (environment):
#   INPUT_INTERFACES         Owned interface names or spec paths, space or newline separated; empty means all
#   INPUT_GATE               push, release, or empty for no hub gates
#   INPUT_HUB                true to lint with the hub's policy without its gates
#   INPUT_RELEASE_VERSION    Version being released, for gate: release
#   INPUT_RULESET            Local OpenLint ruleset file (not with gate or hub)
#   INPUT_BASELINE           Spec file to compare against, or none; default the hub's release
#   INPUT_BASELINE_VERSION   Version of the baseline file
#   INPUT_FAIL_ON            error, warn, info or hint: an extra blocking gate on findings
#   INPUT_MIN_SCORE          An extra blocking gate on the score
#   INPUT_BREAKING           block or requireMajor: an extra blocking gate on breaking changes
#   INPUT_NEW_ONLY           true: fail-on counts only findings not in the baseline
#   INPUT_STRICT             true: advisory gate failures fail too
#   INPUT_ANNOTATIONS        error, warn (default), info, hint or none: lowest severity annotated
#   INPUT_HUB_URL, INPUT_AUDIENCE, INPUT_ORGANIZATION, INPUT_AGENT, INPUT_TOKEN  as for push.sh
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
result_file="${RUNNER_TEMP:-/tmp}/ifc-lint-result.json"
gate="${INPUT_GATE:-}"

error() {
  echo "::error title=ifc7 lint::$(escape_data "$*")"
}

# escape_property escapes a value for use as a workflow command property (file, title).
escape_property() {
  local s
  s="$(escape_data "$1")"
  s="${s//:/%3A}"
  s="${s//,/%2C}"
  printf '%s' "$s"
}

# is_true reports whether an input is "true" (case-insensitive).
is_true() {
  [[ "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" == "true" ]]
}

# require_cli fails early when the installed ifc CLI predates governance gates.
require_cli() {
  if ! command -v ifc >/dev/null 2>&1; then
    error "The ifc CLI is not installed."
    return 1
  fi
  if ! ifc lint --help 2>&1 | grep -q -- '--gate'; then
    error "The installed ifc CLI does not support governance gates ('ifc lint --gate'). Set 'ifc-version' to a release that does."
    return 1
  fi
}

# needs_hub reports whether the inputs read the hub's policy, which needs a token.
needs_hub() {
  [[ -n "$gate" ]] || is_true "${INPUT_HUB:-}"
}

# lint_args prints the ifc lint arguments, one per line.
lint_args() {
  printf '%s\n' lint --json
  [[ -n "$gate" ]] && printf '%s\n' --gate "$gate"
  is_true "${INPUT_HUB:-}" && [[ -z "$gate" ]] && printf '%s\n' --hub
  [[ -n "${INPUT_RELEASE_VERSION:-}" ]] && printf '%s\n' --release-version "$INPUT_RELEASE_VERSION"
  [[ -n "${INPUT_RULESET:-}" ]] && printf '%s\n' --ruleset "$INPUT_RULESET"
  [[ -n "${INPUT_BASELINE:-}" ]] && printf '%s\n' --baseline "$INPUT_BASELINE"
  [[ -n "${INPUT_BASELINE_VERSION:-}" ]] && printf '%s\n' --baseline-version "$INPUT_BASELINE_VERSION"
  [[ -n "${INPUT_FAIL_ON:-}" ]] && printf '%s\n' --fail-on "$INPUT_FAIL_ON"
  [[ -n "${INPUT_MIN_SCORE:-}" ]] && printf '%s\n' --min-score "$INPUT_MIN_SCORE"
  [[ -n "${INPUT_BREAKING:-}" ]] && printf '%s\n' --breaking "$INPUT_BREAKING"
  is_true "${INPUT_NEW_ONLY:-}" && printf '%s\n' --new-only
  is_true "${INPUT_STRICT:-}" && printf '%s\n' --strict
  local target
  # Word splitting is the point: the input is a space or newline separated list.
  # shellcheck disable=SC2086
  for target in ${INPUT_INTERFACES:-}; do
    printf '%s\n' "$target"
  done
  return 0
}

# severity_rank prints 0 for error up to 3 for hint, and 4 for none.
severity_rank() {
  case "$1" in
    error) echo 0 ;;
    warn) echo 1 ;;
    info) echo 2 ;;
    hint) echo 3 ;;
    *) echo 4 ;;
  esac
}

# report turns the lint result into annotations, step outputs, and a job summary.
report() {
  local prefix="" annotate
  if [[ "$working_directory" != "." ]]; then
    prefix="${working_directory%/}/"
  fi
  annotate="$(severity_rank "${INPUT_ANNOTATIONS:-warn}")"
  # Fields are separated by US (0x1f), not tabs: read collapses runs of tabs, which would drop an
  # empty line number.
  local us=$'\x1f'

  # Findings that count: open ones, and inline ignores the policy still counts.
  local severity file line title message level
  while IFS="$us" read -r severity file line title message; do
    [[ "$annotate" -lt 4 && "$(severity_rank "$severity")" -le "$annotate" ]] || continue
    case "$severity" in
      error) level=error ;;
      warn) level=warning ;;
      *) level=notice ;;
    esac
    echo "::$level file=$(escape_property "$prefix$file")${line:+,line=$line},title=$(escape_property "$title")::$(escape_data "$message")"
  done < <(jq -r '.interfaces[] | . as $i | (.findings // [])[]
      | select(.status == "open" or .status == "ignored-counted")
      | [.severity, $i.path, (.range.start.line // "" | tostring), "\(.severity) \(.ruleId)", "\(.message) (\(if .pointer == "" then "root" else .pointer end))"]
      | map(gsub("[\u001f\n]"; " ")) | join("\u001f")' "$result_file")

  # One annotation per failed gate, on the interface's file.
  local gate_name enforcement reasons
  while IFS="$us" read -r file gate_name enforcement reasons; do
    level=warning
    [[ "$enforcement" == "blocking" ]] && level=error
    echo "::$level file=$(escape_property "$prefix$file"),title=$(escape_property "ifc7 gate $gate_name ($enforcement) failed")::$(escape_data "$reasons")"
  done < <(jq -r '.interfaces[] | . as $i | (.outcome.gates // [])[] | select(.passed | not)
      | [$i.path, .gate, .enforcement, ([.reasons[]?.message] | join("; "))]
      | map(gsub("[\u001f\n]"; " ")) | join("\u001f")' "$result_file")

  # Interfaces that could not be checked.
  while IFS="$us" read -r file message; do
    echo "::error file=$(escape_property "$prefix$file"),title=ifc7 lint failed::$(escape_data "$message")"
  done < <(jq -r '.interfaces[] | select(.error) | [.path, .error] | map(gsub("[\u001f\n]"; " ")) | join("\u001f")' "$result_file")

  {
    echo "passed=$(jq -r '.passed' "$result_file")"
    echo "result=$(jq -c . "$result_file")"
  } >> "${GITHUB_OUTPUT:-/dev/null}"

  {
    echo "### ifc7 lint${gate:+ (gate: $gate)}"
    echo
    echo "| Interface | Score | Findings | Compared with | Gates |"
    echo "| --- | --- | --- | --- | --- |"
    jq -r '
      def counts: [(.findings // [])[] | select(.status == "open" or .status == "ignored-counted") | .severity]
        | group_by(.) | map("\(length) \(.[0])") | join(", ") | if . == "" then "none" else . end;
      def waived: [(.findings // [])[] | select(.status == "waived")] | length;
      def gates: if .outcome == null then "–"
        else [.outcome.gates[] | if .passed then "✅ \(.gate)" else "\(if .enforcement == "blocking" then "❌" else "⚠️" end) \(.gate): \([.reasons[]?.message] | join("; "))" end] | join("<br>") end;
      def compared: if .compare == null then "–"
        else "\(if .baseline.source == "release" then "release \(.compare.against)" else .compare.against end): \([.compare.changes[]? | select(.level == "error")] | length) breaking" end;
      .interfaces[] |
      if .error then "| \(.name // .path) | – | – | – | ❌ \(.error) |"
      else "| \(.name // .path) | \(.score) | \(counts)\(if waived > 0 then " (\(waived) waived)" else "" end) | \(compared) | \(gates) |" end
    ' "$result_file"
    echo
    if [[ "$(jq -r '.passed' "$result_file")" == "true" ]]; then
      echo "All gates passed."
    else
      echo "**Gates failed.** Run \`ifc lint ${gate:+--gate $gate }-v\` locally for details."
    fi
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
}

main() {
  require_cli
  if [[ -n "${INPUT_RULESET:-}" ]] && needs_hub; then
    error "'ruleset' lints with a local ruleset, so it can't be combined with the hub's gates or policy. Set 'gate' to '' (and 'hub' to false), and use 'fail-on', 'min-score' or 'breaking' for gates."
    return 1
  fi
  export IFC_HUB_URL="$hub_url"
  # Linting with a local or the default ruleset needs no token; public ruleset references are
  # fetched without one.
  if needs_hub || [[ -n "${INPUT_TOKEN:-}" ]]; then
    authenticate
    export IFC_TOKEN
  fi

  local args=() arg
  while IFS= read -r arg; do
    args+=("$arg")
  done < <(lint_args)

  local lint_status=0
  ifc "${args[@]}" >"$result_file" || lint_status=$?

  if jq -e '.interfaces | type == "array"' "$result_file" >/dev/null 2>&1; then
    report
  else
    error "'ifc lint --json' produced no readable result (exit code $lint_status)."
    return "$(( lint_status == 0 ? 1 : lint_status ))"
  fi
  case "$lint_status" in
    0) ;;
    2) error "A governance gate failed. See the job summary for the reasons." ; return 2 ;;
    *) error "'ifc lint' failed with exit code $lint_status." ; return "$lint_status" ;;
  esac
}

main "$@"
