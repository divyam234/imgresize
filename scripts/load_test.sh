#!/usr/bin/env bash
# Concurrent read-only URL resize load test; no Python dependency.
set -euo pipefail
: "${SOURCE_URL:?Set SOURCE_URL to an HTTP/HTTPS image URL}"
BASE=${BASE:-http://127.0.0.1:8080}
N=${N:-100}
ROUNDS=${ROUNDS:-3}
BENCH=${BENCH:-"$(dirname "$0")/../zig-out/bin/imgresize-bench"}
if [[ ! -x "$BENCH" ]]; then
  echo "Build the Zig benchmark first: nix-shell --run make" >&2
  exit 1
fi
args=("$SOURCE_URL" "$BASE" --concurrency "$N" --rounds "$ROUNDS")
if [[ -n ${PID:-} ]]; then
  args+=(--pid "$PID")
fi
exec "$BENCH" "${args[@]}"
