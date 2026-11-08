#!/usr/bin/env bash

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEB_DIR="$ROOT_DIR/web"
WEB_MODE="${WEB_MODE:-dev}"
WEB_PORT="${WEB_PORT:-3080}"
RESTART_DELAY_SECONDS="${RESTART_DELAY_SECONDS:-2}"
LOCK_DIR="${TMPDIR:-/tmp}/hoopreplay-web-${WEB_PORT}.lock"
shutdown_requested=0
child_pid=""

case "$WEB_MODE" in
  dev|start) ;;
  *)
    echo "Error: WEB_MODE must be 'dev' or 'start', got: $WEB_MODE" >&2
    exit 1
    ;;
esac

command -v npm >/dev/null 2>&1 || {
  echo "Error: npm is not available." >&2
  exit 1
}

[[ -f "$WEB_DIR/package.json" ]] || {
  echo "Error: missing $WEB_DIR/package.json" >&2
  exit 1
}

[[ -d "$WEB_DIR/node_modules" ]] || {
  echo "Error: web dependencies are not installed. Run: cd '$WEB_DIR' && npm ci" >&2
  exit 1
}

if [[ "$WEB_MODE" == "start" && ! -d "$WEB_DIR/.next" ]]; then
  echo "Error: production build not found. Run: cd '$WEB_DIR' && npm run build" >&2
  exit 1
fi

cleanup_lock() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

stop_web() {
  shutdown_requested=1
  if [[ -n "$child_pid" ]] && kill -0 "$child_pid" 2>/dev/null; then
    kill -TERM "$child_pid" 2>/dev/null || true
  fi
}

stop_conflicting_web_processes() {
  if ! command -v lsof >/dev/null 2>&1; then
    return 0
  fi

  local conflicting_pids=""
  local process_pid process_command

  while read -r process_pid process_command; do
    [[ -z "$process_pid" || "$process_pid" == "$$" ]] && continue
    if [[ "$process_command" == *"scripts/web-run.sh"* ]]; then
      conflicting_pids+="${process_pid}"$'\n'
    fi
  done < <(ps -axo pid=,command=)

  conflicting_pids+="$(lsof -tiTCP:"$WEB_PORT" -sTCP:LISTEN 2>/dev/null || true)"$'\n'
  conflicting_pids=$(printf '%s' "$conflicting_pids" | awk 'NF && !seen[$1]++')
  [[ -z "$conflicting_pids" ]] && return 0

  echo "Stopping other HoopReplay Web process(es): ${conflicting_pids//$'\n'/ }..." >&2
  while read -r process_pid; do
    [[ -n "$process_pid" ]] && kill -TERM "$process_pid" 2>/dev/null || true
  done <<< "$conflicting_pids"

  for _ in {1..20}; do
    if ! lsof -tiTCP:"$WEB_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done

  echo "Error: port ${WEB_PORT} is still in use after stopping conflicting processes." >&2
  return 1
}

stop_conflicting_web_processes || exit 1

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "Error: another HoopReplay Web server is already running for port ${WEB_PORT}." >&2
  exit 1
fi

trap 'stop_web' INT TERM HUP
trap cleanup_lock EXIT

cd "$WEB_DIR"
echo "Keeping HoopReplay Web running in '$WEB_MODE' mode on port $WEB_PORT. Press Ctrl+C to stop."

while [[ "$shutdown_requested" -eq 0 ]]; do
  echo "Starting Web at $(date '+%Y-%m-%d %H:%M:%S')..."
  npm run "$WEB_MODE" -- --port "$WEB_PORT" "$@" &
  child_pid=$!

  if wait "$child_pid"; then
    exit_status=0
  else
    exit_status=$?
  fi
  child_pid=""

  if [[ "$shutdown_requested" -ne 0 ]]; then
    break
  fi

  if [[ "$exit_status" -eq 130 || "$exit_status" -eq 143 ]]; then
    break
  fi

  echo "Web exited with status $exit_status; restarting in ${RESTART_DELAY_SECONDS}s..." >&2
  sleep "$RESTART_DELAY_SECONDS" &
  child_pid=$!
  if ! wait "$child_pid"; then
    :
  fi
  child_pid=""
done

echo "HoopReplay Web stopped."
