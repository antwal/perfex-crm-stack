#!/usr/bin/env bash
# Puts a snapshot back: the database and the contents of /app are replaced by what snapshot.sh saved.
# Usage: reset.sh --list          the snapshots on the server
#        reset.sh <name>          restore that snapshot (it asks you to type the name first)
# EVERYTHING created since the snapshot is lost: module data, uploads, installed modules, configuration. That is the
# point of a throw-away instance, and the reason for the confirmation: a person types the snapshot name. Without a
# terminal the script refuses; STACK_RESET_YES=<name> exists for scripts that YOU control and is never for an AI agent:
# an agent asks you to run the command.
# Before anything is deleted the server checks that both files of the snapshot are intact (gzip -t, tar -t). All the
# tables of the database are dropped and the dump is loaded; then /app is emptied and the archive extracted.
# Runs inside the lock (locked.sh). Values come from stack.conf, not from this file.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
[ $# -eq 1 ] && [ -n "$1" ] || { sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
stack_load "$HERE"

if [ "$1" = "--list" ]; then
    ssh "$HOST" 'ls -1 /repo/.tmp/snapshots 2>/dev/null || true'
    exit 0
fi
NAME="$1"
[[ "$NAME" =~ ^[0-9]{8}-[0-9]{6}(-[a-z0-9][a-z0-9_-]{0,31})?$ ]] || die "invalid snapshot name: \"$NAME\" (reset.sh --list shows them)"

echo "This replaces the DATABASE and the CONTENTS OF /app on $HOST with the snapshot $NAME." >&2
echo "Everything created since then is lost." >&2
if [ "${STACK_RESET_YES:-}" = "$NAME" ]; then
    answer="$NAME"
elif [ -t 0 ]; then
    printf 'Type the snapshot name to continue: ' >&2
    read -r answer
else
    die "no terminal to ask for confirmation: run reset.sh yourself, in a terminal"
fi
[ "$answer" = "$NAME" ] || die "not confirmed: nothing was changed"

ensure_locked_sh
remote_locked "bash -s -- $(printf '%q' "$NAME")" <<'REMOTE'
set -euo pipefail
name="$1"
srv="${STACK_SERVER_ROOT:-}"
fail() { echo "$1" >&2; exit 1; }
[[ "$name" =~ ^[0-9]{8}-[0-9]{6}(-[a-z0-9][a-z0-9_-]{0,31})?$ ]] || fail "invalid snapshot name: $name"
for v in PERFEX_DB_HOST PERFEX_DB_NAME PERFEX_DB_USER PERFEX_DB_PASSWORD; do
    [ -n "${!v:-}" ] || fail "$v is not set in the tools container"
done
[ -d "$srv/app" ] || fail "/app is not mounted in the tools container"
dir="$srv/repo/.tmp/snapshots/$name"
{ [ -d "$dir" ] && [ ! -L "$dir" ]; } || fail "snapshot not found: $name"
[ -f "$dir/db.sql.gz" ] && [ -f "$dir/app.tar.gz" ] || fail "snapshot $name is incomplete"
# Nothing is deleted before both files have been read through once.
gzip -t "$dir/db.sql.gz" || fail "the database dump of $name is damaged: nothing was changed"
tar -tzf "$dir/app.tar.gz" > /dev/null || fail "the application archive of $name is damaged: nothing was changed"

umask 077
cnf="$dir/.client.cnf"
drops="$dir/.drop.sql"
trap 'rm -f "$cnf" "$drops"' EXIT
esc() { local s="${1//\\/\\\\}"; printf '%s' "${s//\"/\\\"}"; }
printf '[client]\nhost="%s"\nuser="%s"\npassword="%s"\n' "$(esc "$PERFEX_DB_HOST")" "$(esc "$PERFEX_DB_USER")" "$(esc "$PERFEX_DB_PASSWORD")" > "$cnf"

# Database: drop every table and view of the database, then load the dump (it creates what it needs).
sql="SELECT CONCAT('DROP ', IF(table_type = 'VIEW', 'VIEW', 'TABLE'), ' IF EXISTS ', CHAR(96), table_name, CHAR(96), ';') FROM information_schema.tables WHERE table_schema = DATABASE()"
mariadb --defaults-extra-file="$cnf" -N -B "$PERFEX_DB_NAME" -e "$sql" > "$drops"
{ echo 'SET FOREIGN_KEY_CHECKS=0;'; cat "$drops"; } | mariadb --defaults-extra-file="$cnf" "$PERFEX_DB_NAME"
gzip -dc "$dir/db.sql.gz" | mariadb --defaults-extra-file="$cnf" "$PERFEX_DB_NAME"

# Application: empty /app (the folder is a mount: its contents go, not the folder), then extract.
find "$srv/app" -mindepth 1 -delete
tar -xzf "$dir/app.tar.gz" -C "$srv/app"
echo "restored snapshot $name: database and /app are as they were"
REMOTE
echo "reset done: $NAME"
