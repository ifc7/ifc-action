#!/usr/bin/env bash
# Tests scripts/install.sh against a fake release served by stub curl and uname binaries.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/scripts/install.sh"
failures=0

# setup creates a sandbox with a fake ifc release for v0.2.0 (linux_amd64 and darwin_arm64).
setup() {
  sandbox="$(mktemp -d)"
  mkdir -p "$sandbox/bin" "$sandbox/runner" "$sandbox/releases/download/v0.2.0" "$sandbox/build"
  export RUNNER_TEMP="$sandbox/runner"
  export GITHUB_PATH="$sandbox/path"
  export IFC_RELEASES_URL="https://releases.example/ifc7/ifc/releases"
  export STUB_RELEASES="$sandbox/releases"
  export STUB_LOG="$sandbox/calls"
  export STUB_OS=Linux STUB_ARCH=x86_64
  export INPUT_IFC_VERSION=latest
  : >"$STUB_LOG"

  local plat
  for plat in linux_amd64 darwin_arm64; do
    printf '#!/usr/bin/env bash\necho "ifc %s"\n' "$plat" >"$sandbox/build/ifc"
    echo "license" >"$sandbox/build/LICENSE"
    tar -czf "$STUB_RELEASES/download/v0.2.0/ifc_0.2.0_${plat}.tar.gz" -C "$sandbox/build" ifc LICENSE
  done
  (cd "$STUB_RELEASES/download/v0.2.0" && shasum -a 256 ./*.tar.gz | sed 's| \./| |' >checksums.txt)

  cat >"$sandbox/bin/curl" <<'EOF'
#!/usr/bin/env bash
out="" write="" url="${*: -1}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -w) write="$2"; shift ;;
  esac
  shift
done
echo "curl $url" >>"$STUB_LOG"
path="${url#"$IFC_RELEASES_URL"}"
if [[ "$path" == "/latest" ]]; then
  [[ -n "$write" ]] && printf '%s' "$IFC_RELEASES_URL/tag/v0.2.0"
  exit 0
fi
file="$STUB_RELEASES$path"
[[ -f "$file" ]] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
cp "$file" "$out"
EOF
  cat >"$sandbox/bin/uname" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "-s" ]] && echo "$STUB_OS" || echo "$STUB_ARCH"
EOF
  chmod +x "$sandbox/bin/curl" "$sandbox/bin/uname"
}

run() {
  out="$(PATH="$sandbox/bin:$PATH" bash "$script" 2>&1)"
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
not_grep() { ! grep -q "$1" "$2"; }

test_case() {
  echo "--- $1"
  setup
}

installed() { [[ "$("$RUNNER_TEMP/ifc-bin/ifc")" == "ifc $1" ]]; }

test_case "latest resolves the release tag and installs the binary"
run
check "exits 0" [ "$status" -eq 0 ]
check "follows the latest redirect" grep -qx "curl $IFC_RELEASES_URL/latest" "$STUB_LOG"
check "downloads the linux amd64 archive" grep -qx "curl $IFC_RELEASES_URL/download/v0.2.0/ifc_0.2.0_linux_amd64.tar.gz" "$STUB_LOG"
check "installs the binary" installed linux_amd64
check "adds it to PATH" grep -qx "$RUNNER_TEMP/ifc-bin" "$GITHUB_PATH"

test_case "a version without the leading v is accepted"
export INPUT_IFC_VERSION=0.2.0 STUB_OS=Darwin STUB_ARCH=arm64
run
check "exits 0" [ "$status" -eq 0 ]
check "skips the latest lookup" not_grep /latest "$STUB_LOG"
check "installs the darwin arm64 binary" installed darwin_arm64

test_case "a release without binaries fails with guidance"
export INPUT_IFC_VERSION=v0.0.1
run
check "exits non-zero" [ "$status" -ne 0 ]
check "explains" contains "$out" "Failed to download ifc_0.0.1_linux_amd64.tar.gz from ifc release v0.0.1. Releases before CI support have no binaries"

test_case "a checksum mismatch fails"
echo "corrupt" >>"$STUB_RELEASES/download/v0.2.0/ifc_0.2.0_linux_amd64.tar.gz"
run
check "exits non-zero" [ "$status" -ne 0 ]
check "reports mismatch" contains "$out" "Checksum mismatch for ifc_0.2.0_linux_amd64.tar.gz"
check "does not install" [ ! -e "$RUNNER_TEMP/ifc-bin/ifc" ]

test_case "an unsupported OS fails"
export STUB_OS=MINGW64_NT
run
check "exits non-zero" [ "$status" -ne 0 ]
check "reports OS" contains "$out" "Unsupported runner OS MINGW64_NT"

echo
if [[ "$failures" -gt 0 ]]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All checks passed"
