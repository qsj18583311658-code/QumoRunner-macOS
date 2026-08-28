#!/bin/zsh
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "用法：$0 <libtv-path> <expected-sha256>" >&2
  exit 64
fi

LIBTV_PATH="$1"
EXPECTED_SHA="$2"
[[ -x "${LIBTV_PATH}" ]] || { echo "LibTV 不存在或不可执行" >&2; exit 1; }
[[ "$(uname -m)" == "arm64" ]] || { echo "仅支持 Apple Silicon" >&2; exit 1; }
[[ "$(/usr/bin/lipo -archs "${LIBTV_PATH}")" == "arm64" ]] || { echo "LibTV 必须是 thin ARM64 Mach-O" >&2; exit 1; }

ACTUAL_SHA="$(/usr/bin/shasum -a 256 "${LIBTV_PATH}" | /usr/bin/awk '{print $1}')"
[[ "${ACTUAL_SHA}" == "${EXPECTED_SHA}" ]] || { echo "SHA-256 不匹配" >&2; exit 1; }
/usr/bin/codesign --verify --strict --verbose=2 "${LIBTV_PATH}"
SIGNATURE_INFO="$(/usr/bin/codesign -dv --verbose=4 "${LIBTV_PATH}" 2>&1)"
[[ "${SIGNATURE_INFO}" == *"TeamIdentifier=U5N2L989V7"* ]] || { echo "LibTV Developer ID Team 不匹配" >&2; exit 1; }
"${LIBTV_PATH}" --version | /usr/bin/grep -F "1.0.2" >/dev/null
echo "LibTV 1.0.2 ARM64 校验通过"
