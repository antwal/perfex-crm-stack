#!/usr/bin/env bash
# Copies a module into the test instance in development mode (no zip) and installs its runtime dependencies.
# Usage: deploy.sh [--adopt] <module> [<target>]
#   module   a name from DEPLOY_MODULES of stack.conf; when that list is empty, any folder <SYNC_DIR>/<name>/<name>.php. Or a name
#            from DEPLOY_EXTRA: a module that lives deeper, in <SYNC_DIR>/<folder>/ (which holds <name>.php); it is deployed as
#            /<target>/<MODULES_DIR>/<name> like any other, with the same marker, --adopt and excludes.
#   target   an application folder from APP_TARGETS (the first one is the default): /app, /app-extra.
#   --adopt  take over a module folder that this stack did not create (see below).
# What it does:
#   - synchronises the code folder to the server (sync.sh);
#   - on the server, inside the lock (locked.sh):
#       1. CHECKS THE FOLDER FIRST: /<target>/<MODULES_DIR>/<module> is written only if it does not exist or holds the
#          marker file .stack-managed (written at the first deploy). Anything else (a module that comes with the
#          application, one installed from a zip, one left behind by an uninstall) is refused unless --adopt is given;
#       2. composer install --no-dev in the module's folder on the server (PHP DEPLOY_PHP), when it has a composer.json;
#       3. rsync of the module into the application (the excludes of DEPLOY_EXCLUDES, no dot-folders, --delete-excluded);
#       4. removes dot-folders that are still there (the application's uninstall does not delete them and cannot remove
#          the module folder after them), writes vendor/.htaccess (denied for the web), creates DEV_MARKER if set;
#       5. composer install again, with the development dependencies, in the module's folder, so test:int runs at once.
# The release package of a module does not go through this script: you install it from the application's own interface,
# as a customer would.
# Values come from stack.conf, not from this file.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; }

ADOPT=0; MOD=""; TARGET=""; _n=0
for _arg in "$@"; do
    case "$_arg" in
        --adopt) ADOPT=1 ;;
        -h|--help) usage; exit 0 ;;
        -*) die "unknown option: $_arg" ;;
        *) _n=$((_n + 1))
           case "$_n" in 1) MOD="$_arg" ;; 2) TARGET="$_arg" ;; *) die "too many arguments" ;; esac ;;
    esac
done
[ "$_n" -ge 1 ] || { usage >&2; exit 2; }

stack_load "$HERE"
TARGET="${TARGET:-${APP_TARGETS%% *}}"

# The module, the target and the alias end up in a command executed on the server: closed lists or a strict pattern.
valid_module "$MOD" || die "invalid module name: \"$MOD\" (lowercase letters, digits and _, starting with a letter)"
# The name is one of the modules (folder <SYNC_DIR>/<name>) or one of DEPLOY_EXTRA (a folder listed in stack.conf): SRC_REL is
# where its source is, relative to SYNC_DIR. A name in both lists has two possible sources: refused.
_allowed="$(deploy_module_names)"
_extras="$(deploy_extra_names)"
SRC_REL=""
# shellcheck disable=SC2086
if in_list "$MOD" $_allowed; then
    # shellcheck disable=SC2086
    if in_list "$MOD" $_extras; then die "ambiguous: $MOD is a module of $SYNC_DIR/ and also a name in DEPLOY_EXTRA of stack.conf"; fi
    SRC_REL="$MOD"
elif in_list "$MOD" $_extras; then
    SRC_REL="$(deploy_extra_source "$MOD")"
    # the server refuses any ".." in it: the Mac does too, before anything is copied
    { valid_relpath "$SRC_REL" && [[ "$SRC_REL" != *..* ]]; } || die "invalid folder for $MOD in DEPLOY_EXTRA of stack.conf: \"$SRC_REL\""
else
    die "module not allowed: $MOD (allowed: ${_allowed:-none found}${_extras:+; in DEPLOY_EXTRA: $_extras})"
fi
valid_target "$TARGET" || die "invalid target: \"$TARGET\""
# shellcheck disable=SC2086
in_list "$TARGET" $APP_TARGETS || die "target not allowed: $TARGET (allowed: $APP_TARGETS)"
valid_php "$DEPLOY_PHP" || die "invalid DEPLOY_PHP in stack.conf: $DEPLOY_PHP"
valid_relpath "$MODULES_DIR" allow-empty || die "invalid MODULES_DIR in stack.conf: $MODULES_DIR"
[[ "$DEV_MARKER" =~ ^[A-Za-z0-9._-]*$ ]] || die "invalid DEV_MARKER in stack.conf: $DEV_MARKER"
valid_globs "$DEPLOY_EXCLUDES" || die "invalid DEPLOY_EXCLUDES in stack.conf: $DEPLOY_EXCLUDES"
# no symbolic link on the way to the source (the last one included), and the init file in it
_walk="$REPO_DIR"
for _c in ${SRC_REL//\// }; do
    _walk="$_walk/$_c"
    [ ! -L "$_walk" ] || die "$SYNC_DIR/${_walk#"$REPO_DIR"/} is a symbolic link: not following it"
done
[ -d "$REPO_DIR/$SRC_REL" ] && [ -f "$REPO_DIR/$SRC_REL/$MOD.php" ] \
    || die "module $MOD not found in $REPO_DIR (expected $SYNC_DIR/$SRC_REL/$MOD.php, not a symbolic link)"

"$HERE/sync.sh"

# The script runs on the server with the values as positional parameters (quoted with %q), never pasted into its text.
# It checks them again: the server does not trust the Mac more than the Mac trusts free text.
# STACK_SERVER_ROOT is empty on the server; tests/deploy-test.sh sets it to run this very text against a folder tree.
_args="$(printf '%q %q %q %q %q %q %q %q %q' "$MOD" "$TARGET" "$DEPLOY_PHP" "$SYNC_DIR" "$MODULES_DIR" "$DEV_MARKER" "$ADOPT" "$DEPLOY_EXCLUDES" "$SRC_REL")"
remote_locked "bash -s -- $_args" <<'REMOTE'
set -euo pipefail
mod="$1"; target="$2"; php="$3"; sync_dir="$4"; modules_dir="$5"; dev_marker="$6"; adopt="$7"; excludes="$8"; src_rel="$9"
srv="${STACK_SERVER_ROOT:-}"
managed=".stack-managed"
fail() { echo "$1" >&2; exit "${2:-1}"; }

[[ "$mod" =~ ^[a-z][a-z0-9_]{1,63}$ ]] || fail "invalid module name: $mod"
[[ "$target" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || fail "invalid target: $target"
[[ "$php" =~ ^[0-9]+\.[0-9]+$ ]] || fail "invalid PHP version: $php"
[[ "$sync_dir" =~ ^[A-Za-z0-9_][A-Za-z0-9._/-]*$ && "$sync_dir" != *..* ]] || fail "invalid sync folder: $sync_dir"
[[ -z "$modules_dir" || ( "$modules_dir" =~ ^[A-Za-z0-9_][A-Za-z0-9._/-]*$ && "$modules_dir" != *..* ) ]] || fail "invalid modules folder: $modules_dir"
[[ "$dev_marker" =~ ^[A-Za-z0-9._-]*$ && "$dev_marker" != "." && "$dev_marker" != ".." && "$dev_marker" != "$managed" ]] || fail "invalid development marker: $dev_marker"
[[ "$adopt" =~ ^[01]$ ]] || fail "invalid adopt flag: $adopt"
[[ "$src_rel" =~ ^[A-Za-z0-9_][A-Za-z0-9._/-]*$ && "$src_rel" != *..* && "$src_rel" != *//* && "$src_rel" != */ ]] || fail "invalid source folder: $src_rel"
set -f
for e in $excludes; do [[ "$e" =~ ^[A-Za-z0-9._*?/-]+$ ]] || fail "invalid exclude pattern: $e"; done
set +f

src="$srv/repo/$sync_dir/$src_rel"
app="$srv/$target"
parent="$app${modules_dir:+/$modules_dir}"
dest="$parent/$mod"
[ -d "$app" ] || fail "target /$target is not mounted in the tools container"
[ -d "$parent" ] || fail "the modules folder ${parent#"$srv"} does not exist: install the application first"
walk="$srv/repo/$sync_dir"
for c in ${src_rel//\// }; do
    walk="$walk/$c"
    [ ! -L "$walk" ] || fail "${walk#"$srv"} is a symbolic link: not following it"
done
{ [ -d "$src" ] && [ ! -L "$src" ]; } || fail "module not found on the server: /repo/$sync_dir/$src_rel (run sync.sh)"

# 1. The folder is checked BEFORE anything is written in the application.
if [ -e "$dest" ] || [ -L "$dest" ]; then
    { [ -d "$dest" ] && [ ! -L "$dest" ]; } || fail "${dest#"$srv"} exists and is not a plain folder: not touching it"
    if [ ! -f "$dest/$managed" ]; then
        if [ "$adopt" = 1 ]; then
            echo "taking over ${dest#"$srv"}: it has no $managed marker, --adopt was given"
        else
            fail "refusing to write ${dest#"$srv"}: it has no $managed marker, so this stack did not create it (a module that comes with the application, one installed from a zip, or what an uninstall left behind). If it is yours, run deploy.sh --adopt." 3
        fi
    fi
fi

# 2. Runtime dependencies, in the module's folder on the server.
cd "$src"
if [ -f composer.json ]; then
    rm -rf vendor
    PATH="/opt/php/$php:$PATH" composer install --no-dev --prefer-dist --no-interaction --quiet --classmap-authoritative
fi

# 3. Copy. The marker is written first and protected from --delete, so an interrupted copy leaves the folder managed.
mkdir -p "$dest"
printf 'created by the Perfex CRM Stack Docker deploy script: deploy.sh may overwrite this folder\n' > "$dest/$managed"
ex=()
set -f
for e in $excludes; do ex+=(--exclude "$e"); done
set +f
rsync -a --delete --delete-excluded --filter "P /$managed" --exclude '.*/' ${ex[@]+"${ex[@]}"} "$src/" "$dest/"

# 4. Dot-folders (the application's uninstall does not delete them, so it could not remove the folder), vendor/.htaccess,
#    the optional development marker.
find "$dest" -mindepth 1 -type d -name '.*' -prune -exec rm -rf {} +
if [ -d "$dest/vendor" ]; then printf 'Require all denied\n' > "$dest/vendor/.htaccess"; fi
if [ -n "$dev_marker" ]; then : > "$dest/$dev_marker"; fi

# 5. The module's folder on the server gets its development dependencies back: the copy in the application keeps the
#    runtime ones only, and test:int works right after the deploy.
if [ -f composer.json ]; then
    PATH="/opt/php/$php:$PATH" composer install --prefer-dist --no-interaction --quiet
fi
echo "deployed $mod to ${dest#"$srv"} (marker $managed written${dev_marker:+, development marker $dev_marker})"
REMOTE
echo "done: activate or reactivate the module from the application's interface at $APP_URL"
