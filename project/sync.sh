#!/usr/bin/env bash
# Mirrors the code folder of the project to the server and puts locked.sh in its place:
#   <project root>/<SYNC_DIR>/   ->   /repo/<SYNC_DIR>/       in the tools container (as www-data)
#   locked.sh (this folder)      ->   LOCKED_SH of stack.conf (/repo/<DEST_DIR>/locked.sh)
# The server mirrors the layout of your project (/repo is the project root), so a path relative to the project root means
# the same thing on your machine and on the server. locked.sh always arrives, wherever this folder is in your project.
# Usage: sync.sh            (SSH alias: STACK_SSH in the environment, default SSH_ALIAS of stack.conf)
# Values come from stack.conf, not from this file.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
stack_load "$HERE"
[ -d "$REPO_DIR" ] || die "folder to synchronise not found: $REPO_DIR (SYNC_DIR of stack.conf)"
valid_globs "$SYNC_EXCLUDES" || die "invalid SYNC_EXCLUDES in stack.conf: $SYNC_EXCLUDES"

excludes=()
set -f   # no glob expansion: *.zip must reach rsync as it is
for e in $SYNC_EXCLUDES; do excludes+=(--exclude "$e"); done
set +f

# rsync creates only the last folder of a destination: the parents are made first.
ssh "$HOST" "mkdir -p $(printf '%q %q' "/repo/$SYNC_DIR" "$(dirname "$LOCKED_SH")")"
rsync -az --delete -e ssh ${excludes[@]+"${excludes[@]}"} "$REPO_DIR/" "$HOST:/repo/$SYNC_DIR/"
rsync -az -e ssh "$HERE/locked.sh" "$HOST:$LOCKED_SH"
echo "synchronised $REPO_DIR -> $HOST:/repo/$SYNC_DIR (and locked.sh -> $LOCKED_SH)"
