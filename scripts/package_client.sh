#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${DIST_DIR:-${ROOT_DIR}/dist/client-packages}"
VERSION="${VERSION:-dev}"
COMMIT="${COMMIT:-$(git -C "${ROOT_DIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)}"
BUILD_DATE="${BUILD_DATE:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"
WINDOWS_ARCH="${WINDOWS_ARCH:-amd64}"
WINTUN_DLL="${WINTUN_DLL:-}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -v, --version <version>         Set client version (default: env VERSION or dev)
      --windows-arch <arch>       Set windows target arch (default: env WINDOWS_ARCH or amd64)
      --wintun-dll <path>         Path to wintun.dll (default: env WINTUN_DLL)
      --dist-dir <path>           Output directory (default: env DIST_DIR or ${ROOT_DIR}/dist/client-packages)
  -h, --help                      Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--version)
      [[ $# -ge 2 ]] || { echo "missing value for $1" >&2; usage; exit 1; }
      VERSION="$2"
      shift 2
      ;;
    --windows-arch)
      [[ $# -ge 2 ]] || { echo "missing value for $1" >&2; usage; exit 1; }
      WINDOWS_ARCH="$2"
      shift 2
      ;;
    --wintun-dll)
      [[ $# -ge 2 ]] || { echo "missing value for $1" >&2; usage; exit 1; }
      WINTUN_DLL="$2"
      shift 2
      ;;
    --dist-dir)
      [[ $# -ge 2 ]] || { echo "missing value for $1" >&2; usage; exit 1; }
      DIST_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

GO_BIN="${GO_BIN:-}"
if [[ -z "${GO_BIN}" ]]; then
  if command -v go >/dev/null 2>&1; then
    GO_BIN="$(command -v go)"
  elif [[ -x /usr/local/go/bin/go ]]; then
    GO_BIN="/usr/local/go/bin/go"
  else
    echo "go binary not found. Set GO_BIN=/path/to/go and retry." >&2
    exit 1
  fi
fi

find_first_existing() {
  local candidate
  for candidate in "$@"; do
    if [[ -n "${candidate}" && -f "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  return 1
}

require_file() {
  local label="$1"
  local path="$2"
  local help_text="$3"

  if [[ -f "${path}" ]]; then
    return 0
  fi

  echo "missing ${label}: ${path}" >&2
  echo "${help_text}" >&2
  exit 1
}

build_target() {
  local goos="$1"
  local goarch="$2"
  local ext="$3"

  local output_name="netbird-${goos}-${goarch}${ext}"
  local output_path="${DIST_DIR}/${output_name}"

  rm -f "${output_path}"

  echo "Building ${output_name}..."
  env \
    CGO_ENABLED=0 \
    GOOS="${goos}" \
    GOARCH="${goarch}" \
    GOTOOLCHAIN=auto \
    "${GO_BIN}" build \
      -trimpath \
      -ldflags="-s -w -X github.com/netbirdio/netbird/version.version=${VERSION} -X main.commit=${COMMIT} -X main.date=${BUILD_DATE} -X main.builtBy=package_client.sh" \
      -o "${output_path}" \
      "${ROOT_DIR}/client"
}

build_windows_exe() {
  local goarch="$1"
  local output_name="netbird-windows-${goarch}.exe"
  local output_path="${DIST_DIR}/${output_name}"
  local output_wintun="${DIST_DIR}/wintun.dll"
  local wintun_source=""
  rm -f "${output_path}" "${output_wintun}"

  wintun_source="$(find_first_existing \
    "${WINTUN_DLL}" \
    "${ROOT_DIR}/dist/wintun.dll" \
    "${ROOT_DIR}/dist/netbird_windows_${goarch}/wintun.dll" \
    "${ROOT_DIR}/wintun.dll")" || true
  require_file \
    "wintun.dll" \
    "${wintun_source}" \
    "Set WINTUN_DLL=/path/to/wintun.dll or place the file at dist/wintun.dll. The driver can be extracted from https://www.wintun.net/builds/wintun-0.14.1.zip."
  cp "${wintun_source}" "${output_wintun}"
  echo "Copied external wintun.dll to ${output_wintun}"

  echo "Building ${output_name}..."
  env \
    CGO_ENABLED=0 \
    GOOS=windows \
    GOARCH="${goarch}" \
    GOTOOLCHAIN=auto \
    "${GO_BIN}" build \
      -trimpath \
      -ldflags="-s -w -X github.com/netbirdio/netbird/version.version=${VERSION} -X main.commit=${COMMIT} -X main.date=${BUILD_DATE} -X main.builtBy=package_client.sh" \
      -o "${output_path}" \
      "${ROOT_DIR}/client"
}

build_darwin_universal() {
  local arm64_path="${DIST_DIR}/netbird-darwin-arm64"
  local amd64_path="${DIST_DIR}/netbird-darwin-amd64"
  local output_path="${DIST_DIR}/netbird-darwin"

  build_target "darwin" "arm64" ""
  build_target "darwin" "amd64" ""

  rm -f "${output_path}"

  echo "Creating netbird-darwin..."
  lipo -create -output "${output_path}" "${arm64_path}" "${amd64_path}"

  rm -f "${arm64_path}" "${amd64_path}"
}

mkdir -p "${DIST_DIR}"

build_darwin_universal
build_windows_exe "${WINDOWS_ARCH}"

echo
echo "Artifacts written to ${DIST_DIR}:"
ls -1 "${DIST_DIR}" | sed 's/^/  /'
