#!/usr/bin/env bash
# Takes a snapshot of the instance: a dump of the database and an archive of /app, both kept on the server in
# /repo/.tmp/snapshots/<date>[-<label>]/ (never in your project's files).
# Usage: snapshot.sh [<label>]       label: lowercase letters, digits, - and _ (up to 32), appended to the name
# Prints the snapshot name; reset.sh <name> puts it back. A snapshot holds the application's configuration file, with the
# database password and the encryption key: it stays on the server, in a folder only www-data can read, on an instance
# that is meant to be thrown away. The database is dumped with the MariaDB client of the tools container, using a
# temporary option file (mode 600) so the password never appears in a process list.
# Runs inside the lock (locked.sh). Values come from stack.conf, not from this file.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
[ $# -le 1 ] || die "usage: snapshot.sh [<label>]"
LABEL="${1:-}"
if [ -n "$LABEL" ]; then [[ "$LABEL" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || die "invalid label: \"$LABEL\" (lowercase letters, digits, - and _, up to 32)"; fi
stack_load "$HERE"
ensure_locked_sh

NAME="$(date +%Y%m%d-%H%M%S)${LABEL:+-$LABEL}"
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
[ ! -e "$dir" ] || fail "snapshot $name already exists"
umask 077
mkdir -p "$dir"
ok=0
cnf="$dir/.client.cnf"
# an unfinished snapshot is removed, the option file with the password always
cleanup() { rm -f "$cnf"; if [ "$ok" != 1 ]; then rm -rf "$dir"; fi; }
trap cleanup EXIT
esc() { local s="${1//\\/\\\\}"; printf '%s' "${s//\"/\\\"}"; }
printf '[client]\nhost="%s"\nuser="%s"\npassword="%s"\n' "$(esc "$PERFEX_DB_HOST")" "$(esc "$PERFEX_DB_USER")" "$(esc "$PERFEX_DB_PASSWORD")" > "$cnf"
mariadb-dump --defaults-extra-file="$cnf" --single-transaction --routines --triggers --no-tablespaces "$PERFEX_DB_NAME" | gzip -c > "$dir/db.sql.gz"
gzip -t "$dir/db.sql.gz"
# tar exits with 1 when a file changed while it was read (logs, sessions): that is a warning, not a failure
rc=0
tar -czf "$dir/app.tar.gz" -C "$srv/app" . || rc=$?
[ "$rc" -le 1 ] || fail "archiving /app failed (tar exit $rc)"
tar -tzf "$dir/app.tar.gz" > /dev/null
printf 'created: %s\ndatabase: %s\n' "$(date -u +%FT%TZ)" "$PERFEX_DB_NAME" > "$dir/meta.txt"
ok=1
echo "snapshot $name: database $(du -h "$dir/db.sql.gz" | cut -f1), application $(du -h "$dir/app.tar.gz" | cut -f1), in /repo/.tmp/snapshots/$name"
REMOTE
echo "snapshot: $NAME   (put it back with: reset.sh $NAME)"
