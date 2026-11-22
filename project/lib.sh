#!/usr/bin/env bash
# Shared helpers, sourced by the other scripts of this folder (never run on its own).
# Written for bash 3.2, the one macOS ships: no associative arrays, no mapfile, no ${var,,}.
# Everything that ends up in a command executed on the server is checked here first: the module, the target, the SSH alias
# and the paths are closed lists or values that match a strict pattern, never free text.
#
# THE API OF YOUR OWN SCRIPTS. A script of yours (in the extra/ folder next to this file: see extra/README.md and the section
# "Writing your own script" of README.md) sources this file and calls stack_load. From version 0.2.0 of the template, these
# functions are the API of such scripts and keep their names and arguments until the next major version, a change being
# announced in the CHANGELOG of the template: die, in_list, valid_host, valid_module, valid_ci_module, valid_target,
# valid_php, valid_relpath, valid_globs, stack_load (it sets HERE, HOST, ROOT and REPO_DIR and loads stack.conf),
# discover_modules, deploy_module_names, deploy_extra_names, deploy_extra_source, ci_module_names, remote_locked,
# ensure_locked_sh. Anything else in this file (the *_RE patterns, a helper that is not in that list) is internal and may
# change without notice.

die() { echo "$*" >&2; exit 1; }

in_list() { local needle="$1" item; shift; for item in "$@"; do [ "$item" = "$needle" ] && return 0; done; return 1; }

MODULE_RE='^[a-z][a-z0-9_]{1,63}$'            # the name of a module folder (and of its init file)
CI_MODULE_RE='^[a-z0-9][a-z0-9_-]{0,63}$'     # a folder tested by ci-local.sh (it may be a library, so - is allowed)
TARGET_RE='^[a-z0-9][a-z0-9_-]*$'             # an application folder on the server: /app, /app-extra
PHP_RE='^[0-9]+\.[0-9]+$'
RELPATH_RE='^[A-Za-z0-9_][A-Za-z0-9._/-]*$'
GLOB_RE='^[A-Za-z0-9._*?/-]+$'

valid_host() { [[ "$1" =~ ^[A-Za-z0-9._@-]+$ ]] && [[ "$1" != -* ]]; }
valid_module() { [[ "$1" =~ $MODULE_RE ]]; }
valid_ci_module() { [[ "$1" =~ $CI_MODULE_RE ]]; }
valid_target() { [[ "$1" =~ $TARGET_RE ]]; }
valid_php() { [[ "$1" =~ $PHP_RE ]]; }
# valid_relpath <path> [allow-empty]: a relative folder without ".." or "//", no leading "/" or ".", no trailing "/"
valid_relpath() {
    if [ -z "$1" ]; then [ "${2:-}" = "allow-empty" ]; return; fi
    [[ "$1" =~ $RELPATH_RE ]] || return 1
    case "/$1/" in */../*|*//*) return 1 ;; esac
    case "$1" in */) return 1 ;; esac
    return 0
}
# valid_globs <words>: rsync patterns separated by blanks, letters, digits and . _ - / * ? only
valid_globs() {
    local w rc=0
    set -f
    for w in $1; do [[ "$w" =~ $GLOB_RE ]] || rc=1; done
    set +f
    return $rc
}

# stack_load <folder of the script>: reads stack.conf and sets HERE, HOST (the SSH alias), ROOT (the project root) and
# REPO_DIR (the folder mirrored to the server). STACK_SSH in the environment replaces the alias of stack.conf.
stack_load() {
    HERE="$1"
    [ -f "$HERE/stack.conf" ] || die "stack.conf not found next to the scripts: write the project folder with render.sh first"
    # shellcheck disable=SC1090,SC1091
    . "$HERE/stack.conf"
    HOST="${STACK_SSH:-$SSH_ALIAS}"
    valid_host "$HOST" || die "invalid SSH alias: $HOST"
    valid_relpath "$SYNC_DIR" || die "invalid SYNC_DIR in stack.conf: $SYNC_DIR"
    [[ "$LOCKED_SH" =~ ^/repo/[A-Za-z0-9._/-]+$ ]] || die "invalid LOCKED_SH in stack.conf: $LOCKED_SH"
    ROOT="$(cd "$HERE/$PROJECT_ROOT_REL" && pwd -P)"
    REPO_DIR="$ROOT/$SYNC_DIR"
}

# discover_modules <folder>: names of the sub-folders <name>/<name>.php, one per line (symbolic links are skipped)
discover_modules() {
    local d n
    [ -d "$1" ] || return 0
    for d in "$1"/*/; do
        d="${d%/}"
        n="${d##*/}"
        [ -d "$d" ] && [ ! -L "$d" ] || continue
        valid_module "$n" || continue
        [ -f "$d/$n.php" ] || continue
        echo "$n"
    done
}

# deploy_module_names: DEPLOY_MODULES when it is set (a closed list), else the modules found in REPO_DIR
deploy_module_names() {
    if [ -n "${DEPLOY_MODULES:-}" ]; then echo "$DEPLOY_MODULES"; else discover_modules "$REPO_DIR" | tr '\n' ' '; fi
}

# deploy_extra_names: the names (the part after the colon) of the pairs <folder>:<name> in DEPLOY_EXTRA, blank-separated.
# A word without a colon is not a pair and is left out. DEPLOY_EXTRA may be missing from a stack.conf written by version 0.1.
deploy_extra_names() {
    local p out=""
    set -f
    for p in ${DEPLOY_EXTRA:-}; do
        case "$p" in *:*) out="${out:+$out }${p##*:}" ;; esac
    done
    set +f
    echo "$out"
}

# deploy_extra_source <name>: the folder, relative to SYNC_DIR, that DEPLOY_EXTRA lists for that name; nothing if the name is
# not there. The caller validates the folder (valid_relpath) before it uses it.
deploy_extra_source() {
    local p
    set -f
    for p in ${DEPLOY_EXTRA:-}; do
        case "$p" in
            *:*) if [ "${p##*:}" = "$1" ]; then echo "${p%:*}"; set +f; return 0; fi ;;
        esac
    done
    set +f
    return 0
}

# ci_module_names: CI_MODULES when it is set (a closed list), else the modules found in REPO_DIR
ci_module_names() {
    if [ -n "${CI_MODULES:-}" ]; then echo "$CI_MODULES"; else discover_modules "$REPO_DIR" | tr '\n' ' '; fi
}

# remote_locked <command>: runs a shell command on the server, inside the lock, as one single argument of locked.sh.
# The standard input of this call reaches the command (a script can be passed with a here-document).
remote_locked() {
    ssh "$HOST" "bash $(printf '%q' "$LOCKED_SH") $(printf '%q' "$1")"
}

# ensure_locked_sh: locked.sh must be on the server before remote_locked can use it. sync.sh copies it together with the
# code (deploy.sh and ci-local.sh run sync.sh first); the scripts that do not sync (run.sh, snapshot.sh, reset.sh,
# install-perfex.sh, base-url.sh) call this first: one ssh round trip, and the copy only when the file is missing. The probe reads
# /dev/null, so the caller's standard input stays for the command.
ensure_locked_sh() {
    if ! ssh "$HOST" "test -f $(printf '%q' "$LOCKED_SH")" < /dev/null; then
        ssh "$HOST" "mkdir -p $(printf '%q' "$(dirname "$LOCKED_SH")")" < /dev/null
        rsync -az -e ssh "$HERE/locked.sh" "$HOST:$LOCKED_SH"
        echo "locked.sh put on the server ($LOCKED_SH)" >&2
    fi
}
