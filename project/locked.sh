#!/usr/bin/env bash
# Runs ON THE SERVER, in the tools container (sync.sh copies it to /repo/<DEST_DIR>/locked.sh). One heavy job at a time:
#   bash /repo/<DEST_DIR>/locked.sh '<shell command>'
# The command runs inside the lock {{LOCK_FILE}} (flock), at low priority (nice) and in a process group of its own (setsid).
# When the command ends, whatever is left in that group (a server started in the background, a test that never finished)
# is terminated, so no leftover process keeps the lock. The exit status is the command's; the standard input reaches the
# command (deploy.sh passes a script that way).
# The lock is not a lock file you have to clean up: it is released by the kernel when the last holder exits.
# The group receives SIGTERM, not SIGKILL: a process that ignores SIGTERM stays, and the lock with it. If that happens,
# find the process with ps and kill -9 it by hand.
# STACK_LOCK_FILE replaces the lock path; it exists for tests/locked-test.sh and is never set on the server.
set -uo pipefail
LOCK="${STACK_LOCK_FILE:-{{LOCK_FILE}}}"
[ $# -eq 1 ] && [ -n "$1" ] || { echo "usage: locked.sh '<shell command>'" >&2; exit 2; }
mkdir -p "$(dirname "$LOCK")"
flock -w 60 "$LOCK" true < /dev/null || echo "warning: the lock $LOCK has been busy for over a minute (another heavy job is running), still waiting" >&2
# Inside the group bash is the group leader ($$ is the group): it ignores SIGTERM (`trap :`, which children do not
# inherit) to survive the kill and return the status.
exec flock -w 3600 "$LOCK" nice -n 15 setsid -w bash -c 'trap : TERM; bash -c "$1"; rc=$?; kill -TERM -- -$$ 2>/dev/null; exit $rc' locked "$1"
