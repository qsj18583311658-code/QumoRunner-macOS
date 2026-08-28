#!/bin/sh

case "$1" in
  version)
    echo "libtv 1.0.2"
    ;;
  home)
    printf '%s' "$HOME"
    ;;
  success)
    echo "libtv: submitting"
    echo '{"event":"accepted"}'
    echo '{"data":{"taskInfo":{"taskId":"remote-123","status":2,"loading":false,"progressPercent":100,"outputs":[{"url":"https://example.invalid/result.png"}]}}}'
    ;;
  success-local)
    printf '{"data":{"taskInfo":{"taskId":"remote-123","status":2,"loading":false,"progressPercent":100,"outputs":[{"url":"%s"}]}}}\n' "$2"
    ;;
  running)
    echo '{"data":{"taskInfo":{"taskId":"remote-123","status":1,"loading":true,"progressPercent":42}}}'
    ;;
  stream-task)
    echo '[run] task=remote-stream-123 status=1 progress=1%' >&2
    sleep "${2:-0.35}"
    echo '[run] task=remote-stream-123 status=3 progress=100%' >&2
    exit 1
    ;;
  node)
    printf '%s\n' "$*" >> "$HOME/invocations.log"
    if [ "$2" = "create" ] && [ "$3" = "visibility-race" ]; then
      : > "$HOME/visibility-race-created"
      echo '未找到可运行的节点（展示名或 id 完全匹配）: visibility-race' >&2
      exit 1
    fi
    if [ "$2" = "visibility-race" ] && [ -f "$HOME/visibility-race-created" ]; then
      case " $* " in
        *" --run "*)
          echo '[run] task=remote-visibility-123 status=1 progress=1%' >&2
          echo '{"data":{"taskInfo":{"taskId":"remote-visibility-123","status":2,"loading":false,"progressPercent":100,"outputs":[{"url":"https://example.invalid/visibility.png"}]}}}'
          ;;
        *)
          echo '{"nodeKey":"visible-node","name":"visibility-race"}'
          ;;
      esac
    else
      echo '{"data":{"taskInfo":{"taskId":"remote-layout-123","status":1,"loading":true,"progressPercent":42}}}'
    fi
    ;;
  sleep)
    sleep "${2:-1}"
    echo '{"data":{"taskInfo":{"taskId":"slow","status":1,"loading":true,"progressPercent":1}}}'
    ;;
  crash)
    kill -SEGV $$
    ;;
  argument-rejected)
    echo "error: unknown option '--type'" >&2
    exit 1
    ;;
  remote-failed)
    echo '[run] task=remote-failed-123 status=3 progress=100%' >&2
    exit 1
    ;;
  query-network-failed)
    echo 'API Request Error: TypeError: fetch failed (ECONNRESET) 拉取画布失败' >&2
    exit 1
    ;;
  echo-arg)
    printf '%s' "$2"
    ;;
  identity-env)
    printf '%s|%s|%s' "${LIBTV_TOKEN-}" "${LIBTV_CONFIG_DIR-}" "$HOME"
    ;;
  *)
    echo "unknown scenario" >&2
    exit 64
    ;;
esac
