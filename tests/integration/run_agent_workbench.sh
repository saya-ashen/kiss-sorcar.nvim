#!/bin/sh
set -eu

if [ "${KISS_REAL_DAEMON_AGENT_WORKBENCH_TEST:-}" != "1" ]; then
  echo "SKIP real Agent Workbench backend test; set KISS_REAL_DAEMON_AGENT_WORKBENCH_TEST=1"
  exit 0
fi

repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
source_repo=${KISS_SOURCE_REPO:-"$repo/../kiss_ai"}
[ -f "$source_repo/pyproject.toml" ] || { echo "KISS_SOURCE_REPO does not contain pyproject.toml: $source_repo" >&2; exit 2; }
[ -f "$repo/agent-workbench.nvim/lua/agent-workbench/init.lua" ] || { echo "Agent Workbench checkout missing: $repo/agent-workbench.nvim" >&2; exit 2; }

mkdir -p "$repo/tmp"
fixture=$(mktemp -d "$repo/tmp/real-agent-workbench.XXXXXX")
kiss_home="$fixture/kiss-home"
work_dir="$fixture/workspace"
socket_path="$repo/tmp/aw-$$.sock"
daemon_log="$fixture/daemon.log"
event_log="$fixture/events.ndjson"
mkdir -p "$kiss_home" "$work_dir"
printf 'Disposable Agent Workbench Sorcar fixture.\n' > "$work_dir/README.txt"
git -C "$work_dir" init -q
git -C "$work_dir" config user.name "KISS integration fixture"
git -C "$work_dir" config user.email "fixture.invalid"
git -C "$work_dir" add README.txt
git -C "$work_dir" commit -qm "Disposable Agent Workbench fixture"
before_tree=$(git -C "$work_dir" write-tree)
before_status=$(git -C "$work_dir" status --porcelain=v1 --untracked-files=all)

daemon_pid=
cleanup() {
  if [ -n "$daemon_pid" ] && kill -0 "$daemon_pid" 2>/dev/null; then
    kill -TERM "$daemon_pid"
    wait "$daemon_pid" 2>/dev/null || true
  fi
  rm -f "$socket_path"
}
trap cleanup EXIT HUP INT TERM

(
  cd "$repo"
  exec env KISS_HOME="$kiss_home" KISS_TEST_SOCKET="$socket_path" uv run --project "$source_repo" python -c \
    'from kiss.server.web_server import RemoteAccessServer; RemoteAccessServer(host="127.0.0.1", port=0, use_tunnel=False, work_dir=None, uds_path=__import__("os").environ["KISS_TEST_SOCKET"]).start()'
) >"$daemon_log" 2>&1 &
daemon_pid=$!

count=0
while [ ! -S "$socket_path" ]; do
  if ! kill -0 "$daemon_pid" 2>/dev/null; then cat "$daemon_log" >&2; exit 1; fi
  count=$((count + 1))
  [ "$count" -lt 300 ] || { cat "$daemon_log" >&2; echo "timeout waiting for daemon" >&2; exit 1; }
  sleep 0.1
done

cd "$work_dir"
env KISS_TEST_REPO="$repo" KISS_TEST_SOCKET="$socket_path" KISS_TEST_WORK_DIR="$work_dir" \
  KISS_TEST_EVENT_LOG="$event_log" KISS_TEST_MODEL="${KISS_TEST_MODEL:-codex/gpt-5.6-sol}" \
  nvim --headless -i NONE -u "$repo/agent-workbench.nvim/tests/minimal_init.lua" -l "$repo/tests/integration/agent_workbench.lua"

kill -TERM "$daemon_pid"
wait "$daemon_pid"
daemon_pid=

after_tree=$(git -C "$work_dir" write-tree)
after_status=$(git -C "$work_dir" status --porcelain=v1 --untracked-files=all)
[ "$before_tree" = "$after_tree" ] || { echo "tracked workspace content changed" >&2; exit 1; }
[ "$before_status" = "$after_status" ] || { echo "workspace status changed" >&2; git -C "$work_dir" status --short >&2; exit 1; }

env KISS_TEST_HOME="$kiss_home" python3 - <<'PY'
import json, os, sqlite3
from pathlib import Path
home = Path(os.environ["KISS_TEST_HOME"])
assert json.loads((home / "tabs.json").read_text())["tabs"] == []
with sqlite3.connect(home / "sorcar.db") as db:
    rows = db.execute("SELECT result FROM task_history").fetchall()
assert len(rows) == 1 and rows[0][0] and rows[0][0] != "Agent Failed Abruptly", rows
PY

printf 'PASS isolated Agent Workbench Sorcar persistence: empty tabs; 1 terminal task; workspace unchanged\n'
printf 'EVENT_LOG=%s\nDAEMON_LOG=%s\n' "$event_log" "$daemon_log"
