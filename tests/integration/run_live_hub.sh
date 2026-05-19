#!/usr/bin/env bash
# Live integration test for rtl-buddy-nvim.
#
# Drives a real rtl-buddy-hub daemon against the plugin to verify the
# wire protocol works end-to-end. This is intentionally gated behind
# $RTLBUDDY_INTEGRATION so the default test runs stay hermetic.
#
# Prereqs: nvim 0.10+, uv, python 3.10+, network loopback.
#
# Usage:
#   RTLBUDDY_INTEGRATION=1 tests/integration/run_live_hub.sh                   # install rtl_buddy from PyPI
#   RTLBUDDY_INTEGRATION=1 RTLBUDDY_RB_SRC=../rtl_buddy  tests/integration/run_live_hub.sh   # install from a sibling checkout
set -euo pipefail

if [[ "${RTLBUDDY_INTEGRATION:-0}" != "1" ]]; then
  echo "rtl-buddy-nvim integration test skipped (set RTLBUDDY_INTEGRATION=1 to run)"
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RB_SRC="${RTLBUDDY_RB_SRC:-rtl_buddy}"   # PyPI package name OR a local path

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtlbuddy-live-XXXXXX")"
VENV="$TMPROOT/.venv"
HUB_LOG="$TMPROOT/hub.stdout"
LISTENER_LOG="$TMPROOT/listener.out"
HUB_PID=""
LISTENER_PID=""

cleanup() {
  set +e
  if [[ -n "$LISTENER_PID" ]] && kill -0 "$LISTENER_PID" 2>/dev/null; then
    kill "$LISTENER_PID" 2>/dev/null || true
    wait "$LISTENER_PID" 2>/dev/null || true
  fi
  if [[ -n "$HUB_PID" ]] && kill -0 "$HUB_PID" 2>/dev/null; then
    (cd "$TMPROOT" && "$VENV/bin/rtl-buddy" hub stop >/dev/null 2>&1) || true
    sleep 0.3
    kill -0 "$HUB_PID" 2>/dev/null && kill "$HUB_PID" 2>/dev/null || true
  fi
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

echo "=== rtl-buddy-nvim live hub integration test ==="
echo "tmp project: $TMPROOT"

# 1. Tmp project root (must have root_config.yaml or .git for rb's
#    discover_project_root to find it).
mkdir -p "$TMPROOT/design"
cat > "$TMPROOT/root_config.yaml" <<EOF
project_name: rtlbuddy_live_integration
EOF

# 2. Install rtl_buddy into an isolated venv.
echo "--- installing rtl_buddy from: $RB_SRC ---"
uv venv "$VENV" --python 3.12 -q
uv pip install --python "$VENV/bin/python" -q "$RB_SRC"
"$VENV/bin/python" -c "import rtl_buddy.hub" \
  || { echo "rtl_buddy install missing hub module — branch may not include it"; exit 1; }

# 3. Start the hub in the foreground, backgrounded by the shell, and
#    wait until .rtl-buddy/hub.json appears.
echo "--- starting rb hub ---"
( cd "$TMPROOT" && "$VENV/bin/rtl-buddy" hub start ) >"$HUB_LOG" 2>&1 &
HUB_PID=$!

for _ in $(seq 1 40); do
  if [[ -f "$TMPROOT/.rtl-buddy/hub.json" ]]; then break; fi
  sleep 0.1
done
if [[ ! -f "$TMPROOT/.rtl-buddy/hub.json" ]]; then
  echo "FAIL: hub never wrote .rtl-buddy/hub.json"
  echo "--- hub stdout/stderr ---"
  cat "$HUB_LOG"
  exit 1
fi

TCP=$("$VENV/bin/python" -c "import json,sys; print(json.load(open(sys.argv[1]))['tcp'])" "$TMPROOT/.rtl-buddy/hub.json")
HOST="${TCP%:*}"
PORT="${TCP##*:}"
echo "hub listening: $TCP (pid $HUB_PID)"

# 4. Start the view-origin listener; it will print RECEIVED <json> when
#    the source_focused broadcast arrives.
"$VENV/bin/python" "$REPO_ROOT/tests/integration/view_listener.py" \
  --host "$HOST" --port "$PORT" --timeout 8 >"$LISTENER_LOG" 2>&1 &
LISTENER_PID=$!
sleep 0.5  # let it complete its hello/welcome before nvim joins

# 5. Drive nvim against the hub. Plugin walks up from cwd → finds
#    .rtl-buddy/hub.json → connects → broadcasts source_focused.
echo "--- driving nvim ---"
( cd "$TMPROOT" && nvim --headless -u NONE --noplugin \
    -c "set rtp+=$REPO_ROOT" \
    -c "luafile $REPO_ROOT/tests/integration/drive_nvim.lua" \
    -c "qa!" )

# 6. Wait for the listener to finish and inspect what it saw.
wait "$LISTENER_PID" || true
LISTENER_PID=""

echo "--- listener output ---"
cat "$LISTENER_LOG"

if ! grep -q '^RECEIVED ' "$LISTENER_LOG"; then
  echo "FAIL: view listener did not receive source_focused"
  exit 1
fi

RECEIVED_JSON="$(awk '/^RECEIVED /{ sub(/^RECEIVED /,""); print; exit }' "$LISTENER_LOG")"
"$VENV/bin/python" - "$RECEIVED_JSON" <<'PY'
import json, sys
env = json.loads(sys.argv[1])
assert env["v"] == 1, env
assert env["origin"] == "src", env
assert env["kind"] == "event", env
assert env["type"] == "source_focused", env
p = env["payload"]
assert p["file"].endswith("design/example.sv"), p["file"]
assert p["line"] == 2, p
assert p["col"] == 9, p
print("PASS: source_focused envelope is correct")
PY

echo "=== integration test passed ==="
