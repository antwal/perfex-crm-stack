#!/usr/bin/env bash
# Copies YOUR copy of Perfex CRM into /app on the server, so that you can finish the installation in the browser.
# Usage: install-perfex.sh [--force] <folder | zip>
#   folder   the Perfex application folder: the one that holds index.php and application/
#   zip      the zip you downloaded; the application folder is found inside it (up to two levels down)
#   --force  copy even if /app is not empty (files are overwritten, nothing is deleted: an installed instance keeps its
#            configuration, which the zip does not contain)
# This template ships no part of Perfex CRM and never will: it is proprietary software, bring your own licensed copy.
# The folder or zip you pass is only read. Afterwards: open the application URL, complete the installation wizard in the
# browser (you create the administrator there), then remove the install folder:  run.sh 'rm -rf /app/install'
# Only the first target (/app) is handled; a second instance (/app-extra, see stack/web-extra.yml) is copied by hand with
# rsync over the SSH alias into /app-extra, which the tools container mounts.
# Values come from stack.conf, not from this file.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
usage() { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

FORCE=0; SRC=""; _n=0
for _arg in "$@"; do
    case "$_arg" in
        --force) FORCE=1 ;;
        -h|--help) usage ;;
        -*) die "unknown option: $_arg" ;;
        *) _n=$((_n + 1)); [ "$_n" -eq 1 ] || die "too many arguments"; SRC="$_arg" ;;
    esac
done
[ "$_n" -eq 1 ] && [ -n "$SRC" ] || usage
stack_load "$HERE"

if [ -d "$SRC" ]; then
    KIND=folder
    [ -f "$SRC/index.php" ] && [ -d "$SRC/application" ] \
        || die "$SRC does not look like the Perfex application folder (index.php and application/ expected); if it holds a zip or a parent folder, point at the folder inside"
elif [ -f "$SRC" ]; then
    KIND=zip
    case "$SRC" in *.zip|*.ZIP) ;; *) die "$SRC is a file but not a .zip" ;; esac
else
    die "not found: $SRC"
fi

# a name starting with "-" must not be read as an option by rsync
case "$SRC" in /*|./*|../*) ;; *) SRC="./$SRC" ;; esac

if [ -n "$(ssh "$HOST" 'find /app -mindepth 1 -maxdepth 1 -print -quit')" ] && [ "$FORCE" -ne 1 ]; then
    die "/app on the server is not empty: the application seems to be there already. --force copies over it without deleting anything."
fi

if [ "$KIND" = folder ]; then
    rsync -az --exclude '.DS_Store' -e ssh "$SRC/" "$HOST:/app/"
else
    ssh "$HOST" "mkdir -p /repo/.tmp"
    rsync -az -e ssh "$SRC" "$HOST:/repo/.tmp/perfex-install.zip"
    ensure_locked_sh
    remote_locked "bash -s" <<'REMOTE'
set -euo pipefail
srv="${STACK_SERVER_ROOT:-}"
zip="$srv/repo/.tmp/perfex-install.zip"
work="$srv/repo/.tmp/perfex-install"
rm -rf "$work"
mkdir -p "$work"
unzip -q "$zip" -d "$work"
root=""
for d in "$work" "$work"/* "$work"/*/*; do
    if [ -f "$d/index.php" ] && [ -d "$d/application" ]; then root="$d"; break; fi
done
if [ -z "$root" ]; then
    rm -rf "$work" "$zip"
    echo "no application folder (index.php and application/) found inside the zip" >&2
    exit 1
fi
rsync -a --exclude '.DS_Store' "$root/" "$srv/app/"
rm -rf "$work" "$zip"
REMOTE
fi
echo "copied to /app on the server. Next: open $APP_URL and complete the installation wizard in the browser,"
echo "then remove the install folder:  $DEST_DIR/run.sh 'rm -rf /app/install'"
