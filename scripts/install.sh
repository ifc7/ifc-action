#!/usr/bin/env bash
# Installs a release binary of the ifc CLI and adds it to the job's PATH.
#
# Release assets are published by ifc7/ifc's GoReleaser config as
#   <releases>/download/<tag>/ifc_<version>_<os>_<arch>.tar.gz
# (version without the leading v), with sha256 sums in checksums.txt.
#
# Inputs (environment):
#   INPUT_IFC_VERSION  Release tag (e.g. v0.1.0 or 0.1.0) or "latest"
#   IFC_RELEASES_URL   Releases base URL; only overridden in tests
set -euo pipefail

releases_url="${IFC_RELEASES_URL:-https://github.com/ifc7/ifc/releases}"
version="${INPUT_IFC_VERSION:-latest}"
bin_dir="${RUNNER_TEMP:-/tmp}/ifc-bin"

error() {
  local s="$*"
  s="${s//'%'/%25}"
  s="${s//$'\r'/%0D}"
  s="${s//$'\n'/%0A}"
  echo "::error title=ifc7 install::$s"
}

# platform sets plat to the release's <os>_<arch> for this runner. Like resolve_tag, it
# sets a global so that error annotations reach stdout instead of a command substitution.
platform() {
  local os arch
  case "$(uname -s)" in
    Linux) os=linux ;;
    Darwin) os=darwin ;;
    *)
      error "Unsupported runner OS $(uname -s). The ifc CLI is released for Linux and macOS."
      return 1
      ;;
  esac
  case "$(uname -m)" in
    x86_64 | amd64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *)
      error "Unsupported runner architecture $(uname -m). The ifc CLI is released for amd64 and arm64."
      return 1
      ;;
  esac
  plat="${os}_${arch}"
}

# resolve_tag sets tag to the release tag for the version input. "latest" follows the
# releases/latest redirect, which avoids the GitHub API and its rate limits.
resolve_tag() {
  if [[ "$version" != "latest" ]]; then
    tag="v${version#v}"
    return
  fi
  local url
  if ! url=$(curl -fsSL -o /dev/null -w '%{url_effective}' "$releases_url/latest"); then
    error "Failed to look up the latest ifc release at $releases_url/latest."
    return 1
  fi
  if [[ "$url" != */tag/* ]]; then
    error "Could not find the latest ifc release (redirected to $url). Set 'ifc-version'."
    return 1
  fi
  tag="${url##*/tag/}"
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

main() {
  local plat tag asset
  platform
  resolve_tag
  asset="ifc_${tag#v}_${plat}.tar.gz"
  work=$(mktemp -d) # global, so the EXIT trap can still see it
  trap 'rm -rf "$work"' EXIT

  echo "Installing ifc $tag ($plat)"
  if ! curl -fsSL -o "$work/$asset" "$releases_url/download/$tag/$asset"; then
    error "Failed to download $asset from ifc release $tag. Releases before CI support have no binaries; set 'ifc-version' to a newer release."
    return 1
  fi
  if ! curl -fsSL -o "$work/checksums.txt" "$releases_url/download/$tag/checksums.txt"; then
    error "Failed to download checksums.txt for ifc release $tag."
    return 1
  fi

  local want got
  want=$(awk -v a="$asset" '$2 == a { print $1 }' "$work/checksums.txt")
  got=$(sha256 "$work/$asset")
  if [[ -z "$want" ]]; then
    error "checksums.txt for ifc release $tag has no entry for $asset."
    return 1
  fi
  if [[ "$want" != "$got" ]]; then
    error "Checksum mismatch for $asset (expected $want, got $got)."
    return 1
  fi

  mkdir -p "$bin_dir"
  tar -xzf "$work/$asset" -C "$work" ifc
  install -m 0755 "$work/ifc" "$bin_dir/ifc"
  echo "$bin_dir" >>"${GITHUB_PATH:-/dev/null}"
}

main "$@"
