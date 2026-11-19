#!/usr/bin/env bash
# Runs ONE command on the server, in the tools container, inside the lock (locked.sh), as www-data.
# Usage: run.sh '<shell command>'
#   run.sh 'cd /repo/modules/my_module && PATH=/opt/php/8.4:$PATH composer test:int'
#   run.sh 'tail -n 50 /app/application/logs/log-$(date +%F).php'
# The command is quoted so that it reaches locked.sh as one single argument; the alias comes from stack.conf (or STACK_SSH)
# and is checked. The command is yours by definition: this script is the way to run it, not a filter. The standard input
# reaches the command. locked.sh normally arrives with sync.sh (deploy.sh and ci-local.sh run it first); if it is not on the
# server yet, this script puts it there before running the command (one extra ssh call to check).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
[ $# -eq 1 ] && [ -n "$1" ] || { sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
stack_load "$HERE"
ensure_locked_sh
remote_locked "$1"
