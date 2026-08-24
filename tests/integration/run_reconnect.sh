#!/bin/sh
set -eu

if [ "${KISS_REAL_DAEMON_RECONNECT_TEST:-}" != "1" ]; then
  echo "SKIP real daemon reconnect test; set KISS_REAL_DAEMON_RECONNECT_TEST=1"
  exit 0
fi

repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
source_repo=${KISS_SOURCE_REPO:-"$repo/../kiss_ai"}
if [ ! -f "$source_repo/pyproject.toml" ]; then
  echo "KISS_SOURCE_REPO does not contain pyproject.toml: $source_repo" >&2
  exit 2
fi

mkdir -p "$repo/tmp"
fixture=$(mktemp -d "$repo/tmp/real-daemon-reconnect.XXXXXX")
kiss_home="$fixture/kiss-home"
work_dir="$fixture/workspace"
socket_path=$(realpath --relative-to="$repo" "$fixture")/sorcar.sock
daemon_log="$fixture/daemon.log"
event_log="$fixture/events.ndjson"
mkdir -p "$kiss_home" "$work_dir"

git -C "$repo" archive HEAD | tar -x -C "$work_dir"
git -C "$work_dir" init -q
git -C "$work_dir" config user.name "KISS integration fixture"
git -C "$work_dir" config user.email "fixture.invalid"
git -C "$work_dir" add .
git -C "$work_dir" commit -qm "Disposable integration fixture"
before_tree=$(git -C "$work_dir" write-tree)
before_status=$(git -C "$work_dir" status --porcelain=v1 --untracked-files=all)

daemon_pid=
cleanup() {
  if [ -n "$daemon_pid" ] && kill -0 "$daemon_pid" 2>/dev/null; then
    kill -TERM "$daemon_pid"
    wait "$daemon_pid" 2>/dev/null || true
  fi
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
  if ! kill -0 "$daemon_pid" 2>/dev/null; then
    cat "$daemon_log" >&2
    echo "real daemon exited before socket creation" >&2
    exit 1
  fi
  count=$((count + 1))
  if [ "$count" -ge 300 ]; then
    cat "$daemon_log" >&2
    echo "timeout waiting for isolated daemon socket" >&2
    exit 1
  fi
  sleep 0.1
done

cd "$repo"
env KISS_TEST_SOCKET="$socket_path" KISS_TEST_WORK_DIR="$work_dir" \
  KISS_TEST_EVENT_LOG="$event_log" KISS_TEST_MODEL="${KISS_TEST_MODEL:-}" \
  KISS_TEST_TIMEOUT_MS="${KISS_TEST_TIMEOUT_MS:-300000}" \
  nvim --headless -u NONE -l tests/integration/reconnect.lua

kill -TERM "$daemon_pid"
wait "$daemon_pid"
daemon_pid=

after_tree=$(git -C "$work_dir" write-tree)
after_status=$(git -C "$work_dir" status --porcelain=v1 --untracked-files=all)
[ "$before_tree" = "$after_tree" ] || { echo "tracked workspace content changed" >&2; exit 1; }
[ "$before_status" = "$after_status" ] || { echo "workspace status changed" >&2; git -C "$work_dir" status --short >&2; exit 1; }

KISS_TEST_HOME="$kiss_home" KISS_TEST_EVENT_LOG="$event_log" python3 - <<'PY'
import json
import os
import sqlite3
from pathlib import Path

home = Path(os.environ["KISS_TEST_HOME"])
assert json.loads((home / "tabs.json").read_text())["tabs"] == [], "disposable tabs persisted after close"
with sqlite3.connect(home / "sorcar.db") as database:
    rows = database.execute("SELECT task, result FROM task_history ORDER BY timestamp").fetchall()
assert len(rows) == 1, f"expected one task_history row, got {len(rows)}"
assert rows[0][1] and rows[0][1] != "Agent Failed Abruptly", rows

records = [json.loads(line) for line in Path(os.environ["KISS_TEST_EVENT_LOG"]).read_text().splitlines()]
metadata = records[0]["metadata"]
commands = metadata["sent_commands"]
assert sum(command["type"] == "run" for command in commands) == 1, commands
assert sum(command["type"] == "openTab" for command in commands) == 1, commands
assert not any(command["type"] in {"stop", "appendUserMessage", "userAnswer", "worktreeAction"} for command in commands), commands
assert metadata["new_generation"] != metadata["old_generation"], metadata
PY

printf 'PASS isolated reconnect persistence: empty tabs registry; 1 terminal task_history row; workspace unchanged\n'
printf 'EVENT_LOG=%s\nDAEMON_LOG=%s\n' "$event_log" "$daemon_log"
