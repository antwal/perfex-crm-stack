#!/usr/bin/env bash
# The PHP matrix, run in the tools container on the server over SSH: the local equivalent of a CI.
# Usage: ci-local.sh [module ...]       default: CI_MODULES of stack.conf; when that is empty, every <SYNC_DIR>/<name>/<name>.php
# Environment: STACK_SSH (SSH alias, default SSH_ALIAS), MATRIX_PHP_VERSIONS and STATIC_PHP (default from stack.conf),
#   SKIP_STATIC=1 skips static analysis; MATRIX_PHP_VERSIONS="" runs static analysis only.
# For each module and PHP version, one job inside the lock (locked.sh), decided ON THE SERVER by looking at the module's folder:
#   - with a composer.json: composer install, composer validate --strict, composer run <CI_CHECK_SCRIPT>. What "check" does
#     is decided by the composer.json of the module: add your own tests there;
#   - without one: php -l on every PHP file of the module (vendor/, node_modules/ and the folders that start with a dot are
#     left out), then the file CI_CHECK_FILE (default tests/check.sh; .sh runs with bash, .php with php, both with the PHP of
#     the matrix first in the PATH) if the module has it; a module without that file is only syntax-checked.
# A module with both a composer.json and a tests/check.sh takes the Composer road and the file is not run.
# Then, on STATIC_PHP and only for a module with a composer.json: composer install in STATIC_TOOLS_DIR (if set and vendor/ is
# missing) and composer run <CI_STATIC_SCRIPT> in the module, if the module defines it.
# Values come from stack.conf, not from this file.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
ENV_MATRIX="${MATRIX_PHP_VERSIONS-__unset__}"
ENV_STATIC_PHP="${STATIC_PHP-}"
stack_load "$HERE"
[ "$ENV_MATRIX" = "__unset__" ] || MATRIX_PHP_VERSIONS="$ENV_MATRIX"
[ -z "$ENV_STATIC_PHP" ] || STATIC_PHP="$ENV_STATIC_PHP"
# a stack.conf written by a template older than 0.4.0 has no CI_CHECK_FILE
CI_CHECK_FILE="${CI_CHECK_FILE:-tests/check.sh}"

MODS=("$@")
if [ ${#MODS[@]} -eq 0 ]; then read -r -a MODS <<< "$(ci_module_names)"; fi
[ ${#MODS[@]} -gt 0 ] || die "no module: pass a name, fill CI_MODULES or add a folder <name>/<name>.php under $SYNC_DIR"

# Everything below ends up in commands run on the server: closed values or strict patterns.
valid_php "$STATIC_PHP" || die "invalid STATIC_PHP: $STATIC_PHP"
[[ "$STATIC_TOOLS_DIR" =~ ^[A-Za-z0-9._/-]*$ ]] && [[ "$STATIC_TOOLS_DIR" != *..* ]] || die "invalid STATIC_TOOLS_DIR in stack.conf: $STATIC_TOOLS_DIR"
[[ "$CI_CHECK_SCRIPT" =~ ^[A-Za-z0-9:_-]+$ && "$CI_STATIC_SCRIPT" =~ ^[A-Za-z0-9:_-]*$ ]] || die "invalid CI_CHECK_SCRIPT or CI_STATIC_SCRIPT in stack.conf"
_checkfile_re='^[A-Za-z0-9_][A-Za-z0-9._/-]*\.(sh|php)$'
[[ "$CI_CHECK_FILE" =~ $_checkfile_re && "$CI_CHECK_FILE" != *..* && "$CI_CHECK_FILE" != *//* ]] || die "invalid CI_CHECK_FILE in stack.conf: $CI_CHECK_FILE"
for v in $MATRIX_PHP_VERSIONS $STATIC_PHP; do
    valid_php "$v" || die "invalid PHP version: $v"
    # shellcheck disable=SC2086
    in_list "$v" $TOOLS_PHP_VERSIONS || die "PHP $v is not installed in the tools image (TOOLS_PHP_VERSIONS: $TOOLS_PHP_VERSIONS)"
done
for m in "${MODS[@]}"; do valid_ci_module "$m" || die "invalid module name: \"$m\""; done

"$HERE/sync.sh"

fail=0
run_remote() { # run_remote <php> <module> <shell snippet>
    local v="$1" m="$2"; shift 2
    remote_locked "set -euo pipefail; cd /repo/$SYNC_DIR/$m; export PATH=/opt/php/$v:\$PATH; $*"
}
# The job of the matrix, one script for every module and PHP version. It runs on the server with the values as positional
# parameters (quoted with %q), never pasted into its text, and checks them again: the server does not trust your machine more
# than your machine trusts free text. The road (Composer or not) is chosen there, by the module's folder.
# STACK_SERVER_ROOT is empty on the server; tests/scripts-test.sh sets it to run this very text against a folder tree.
matrix_job() {
    cat <<'REMOTE'
set -euo pipefail
php="$1"; sync_dir="$2"; mod="$3"; check_file="$4"; check_script="$5"
srv="${STACK_SERVER_ROOT:-}"
fail() { echo "$1" >&2; exit "${2:-1}"; }
checkfile_re='^[A-Za-z0-9_][A-Za-z0-9._/-]*\.(sh|php)$'

[[ "$php" =~ ^[0-9]+\.[0-9]+$ ]] || fail "invalid PHP version: $php"
[[ "$sync_dir" =~ ^[A-Za-z0-9_][A-Za-z0-9._/-]*$ && "$sync_dir" != *..* && "$sync_dir" != *//* ]] || fail "invalid sync folder: $sync_dir"
[[ "$mod" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]] || fail "invalid module name: $mod"
[[ "$check_file" =~ $checkfile_re && "$check_file" != *..* && "$check_file" != *//* ]] || fail "invalid check file: $check_file"
[[ "$check_script" =~ ^[A-Za-z0-9:_-]+$ ]] || fail "invalid check script: $check_script"

dir="$srv/repo/$sync_dir/$mod"
{ [ -d "$dir" ] && [ ! -L "$dir" ]; } || fail "module not found on the server: /repo/$sync_dir/$mod (run sync.sh)"
cd "$dir"
export PATH="/opt/php/$php:$PATH"
php -v | head -n 1

if [ -f composer.json ]; then
    # the Composer road: the same three commands as before version 0.4.0 of the template (the script arrives on the standard
    # input, so a script of the module that reads it must not eat the rest of this job: /dev/null)
    rm -rf vendor
    composer install --no-interaction --prefer-dist --quiet && composer validate --strict --no-check-version && composer run --no-interaction "$check_script" < /dev/null
else
    # the plain road: every PHP file of the module is compiled (vendor/, node_modules/ and the dot-folders are third-party or
    # tooling and are left out), then the check file, if the module has one
    n=0; bad=0
    while IFS= read -r -d '' f; do
        n=$((n + 1))
        if ! out="$(php -l "$f" 2>&1)"; then echo "$out"; bad=$((bad + 1)); fi
    done < <(find . -mindepth 1 -type d \( -name vendor -o -name node_modules -o -name '.*' \) -prune -o -type f -name '*.php' -print0)
    [ "$bad" -eq 0 ] || fail "syntax check: $bad of $n PHP file(s) failed"
    echo "syntax check: $n PHP file(s), no error"
    if [ -e "$check_file" ] || [ -L "$check_file" ]; then
        # no symbolic link on the way to the check file, the file itself included (as deploy.sh does for the source folder)
        walk="."
        for c in ${check_file//\// }; do
            walk="$walk/$c"
            [ ! -L "$walk" ] || fail "$check_file: ${walk#./} is a symbolic link: not following it"
        done
        [ -f "$check_file" ] || fail "$check_file is not a plain file"
        case "$check_file" in *.sh) bash "$check_file" < /dev/null ;; *.php) php "$check_file" < /dev/null ;; esac
    else
        echo "no $check_file: syntax check only"
    fi
fi
REMOTE
}
for m in "${MODS[@]}"; do
    for v in $MATRIX_PHP_VERSIONS; do
        echo "=== $m / PHP $v ==="
        _args="$(printf '%q %q %q %q %q' "$v" "$SYNC_DIR" "$m" "$CI_CHECK_FILE" "$CI_CHECK_SCRIPT")"
        if matrix_job | remote_locked "bash -s -- $_args"; then
            echo "OK: $m on PHP $v"
        else
            echo "FAILED: $m on PHP $v"; fail=1
        fi
    done
    if [ "${SKIP_STATIC:-0}" != "1" ] && [ -n "$CI_STATIC_SCRIPT" ]; then
        echo "=== $m / static analysis on PHP $STATIC_PHP ==="
        if [ -n "$STATIC_TOOLS_DIR" ] && ! remote_locked "set -euo pipefail; [ -f /repo/$SYNC_DIR/$STATIC_TOOLS_DIR/composer.json ] || exit 0; cd /repo/$SYNC_DIR/$STATIC_TOOLS_DIR; export PATH=/opt/php/$STATIC_PHP:\$PATH; [ -d vendor ] || composer install --no-interaction --prefer-dist --quiet"; then
            echo "FAILED: installing $STATIC_TOOLS_DIR"; fail=1; continue
        fi
        if run_remote "$STATIC_PHP" "$m" "[ -f composer.json ] || { echo 'no composer.json: static analysis skipped'; exit 0; }; rm -rf vendor; composer install --no-interaction --prefer-dist --quiet; if composer run --list 2>/dev/null | grep -q '^ *$CI_STATIC_SCRIPT'; then composer run --no-interaction $CI_STATIC_SCRIPT; else echo '$CI_STATIC_SCRIPT is not defined, skipped'; fi"; then
            echo "OK: static analysis of $m"
        else
            echo "FAILED: static analysis of $m"; fail=1
        fi
    fi
done
if [ "$fail" -eq 0 ]; then echo "=== matrix green ==="; else echo "=== matrix RED ==="; fi
exit "$fail"
