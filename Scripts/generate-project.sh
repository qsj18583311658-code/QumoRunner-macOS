#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "缺少 XcodeGen。请先执行：brew install xcodegen" >&2
  exit 1
fi

cd "${PROJECT_DIR}"
xcodegen generate
echo "已生成 ${PROJECT_DIR}/QumoRunner.xcodeproj"
