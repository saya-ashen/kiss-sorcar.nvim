#!/bin/sh
set -eu

if [ "${KISS_REAL_DAEMON_TEST:-}" != "1" ]; then
  echo "SKIP real daemon control-plane test; set KISS_REAL_DAEMON_TEST=1"
  exit 0
fi

repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
source_repo=${KISS_SOURCE_REPO:-"$repo/../kiss_ai"}
if [ ! -f "$source_repo/pyproject.toml" ]; then
  echo "KISS_SOURCE_REPO does not contain pyproject.toml: $source_repo" >&2
  exit 2
fi

mkdir -p "$repo/tmp"
fixture=$(mktemp -d "$repo/tmp/real-daemon-control.XXXXXX")
kiss_home="$fixture/kiss-home"
work_dir="$fixture/workspace"
# Keep UDS pathname below Linux sockaddr_un limit despite long worktree path.
socket_path=$(realpath --relative-to="$repo" "$fixture")/sorcar.sock
daemon_log="$fixture/daemon.log"
mkdir -p "$kiss_home" "$work_dir"

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
  nvim --headless -u NONE -l tests/integration/control_plane.lua

kill -TERM "$daemon_pid"
wait "$daemon_pid"
daemon_pid=

KISS_TEST_HOME="$kiss_home" python3 - <<'PY'
import json
import os
import sqlite3
from pathlib import Path

home = Path(os.environ["KISS_TEST_HOME"])
assert json.loads((home / "tabs.json").read_text())["tabs"] == [], "disposable tab persisted after close"
with sqlite3.connect(home / "sorcar.db") as database:
    assert database.execute("SELECT count(*) FROM task_history").fetchone()[0] == 0, "LLM task was created"
PY

echo "PASS isolated persistence: empty tabs registry; 0 task_history rows"
