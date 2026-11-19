#!/usr/bin/env bash
# The PHP matrix, run in the tools container on the server over SSH: the local equivalent of a CI.
# Usage: ci-local.sh [module ...]       default: CI_MODULES of stack.conf; when that is empty, every <SYNC_DIR>/<name>/<name>.php
# Environment: STACK_SSH (SSH alias, default SSH_ALIAS), MATRIX_PHP_VERSIONS and STATIC_PHP (default from stack.conf),
#   SKIP_STATIC=1 skips static analysis; MATRIX_PHP_VERSIONS="" runs static analysis only.
# For each module and PHP version: composer install, composer validate --strict, composer run <CI_CHECK_SCRIPT>. What
# "check" does is decided by the composer.json of the module: add your own tests there. Then, on STATIC_PHP: composer
# install in STATIC_TOOLS_DIR (if set and vendor/ is missing) and composer run <CI_STATIC_SCRIPT> in the module, if the
# module defines it. A module without a composer.json is skipped. Every job runs inside the lock (locked.sh).
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

MODS=("$@")
if [ ${#MODS[@]} -eq 0 ]; then read -r -a MODS <<< "$(ci_module_names)"; fi
[ ${#MODS[@]} -gt 0 ] || die "no module: pass a name, fill CI_MODULES or add a folder <name>/<name>.php under $SYNC_DIR"

# Everything below ends up in commands run on the server: closed values or strict patterns.
valid_php "$STATIC_PHP" || die "invalid STATIC_PHP: $STATIC_PHP"
[[ "$STATIC_TOOLS_DIR" =~ ^[A-Za-z0-9._/-]*$ ]] && [[ "$STATIC_TOOLS_DIR" != *..* ]] || die "invalid STATIC_TOOLS_DIR in stack.conf: $STATIC_TOOLS_DIR"
[[ "$CI_CHECK_SCRIPT" =~ ^[A-Za-z0-9:_-]+$ && "$CI_STATIC_SCRIPT" =~ ^[A-Za-z0-9:_-]*$ ]] || die "invalid CI_CHECK_SCRIPT or CI_STATIC_SCRIPT in stack.conf"
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
for m in "${MODS[@]}"; do
    if ! ssh "$HOST" "[ -f /repo/$SYNC_DIR/$m/composer.json ]"; then
        echo "--- $m: no composer.json, skipped"; continue
    fi
    for v in $MATRIX_PHP_VERSIONS; do
        echo "=== $m / PHP $v ==="
        if run_remote "$v" "$m" "php -v | head -1; rm -rf vendor; composer install --no-interaction --prefer-dist --quiet && composer validate --strict --no-check-version && composer run --no-interaction $CI_CHECK_SCRIPT"; then
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
        if run_remote "$STATIC_PHP" "$m" "rm -rf vendor; composer install --no-interaction --prefer-dist --quiet; if composer run --list 2>/dev/null | grep -q '^ *$CI_STATIC_SCRIPT'; then composer run --no-interaction $CI_STATIC_SCRIPT; else echo '$CI_STATIC_SCRIPT is not defined, skipped'; fi"; then
            echo "OK: static analysis of $m"
        else
            echo "FAILED: static analysis of $m"; fail=1
        fi
    fi
done
if [ "$fail" -eq 0 ]; then echo "=== matrix green ==="; else echo "=== matrix RED ==="; fi
exit "$fail"
