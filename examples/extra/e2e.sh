#!/usr/bin/env bash
# Runs a Playwright suite of your project against the instance, from this Mac.
# Usage: e2e.sh <folder> [<playwright argument> ...]
#   folder    a folder of the project, relative to the project root, that holds playwright.config.ts (tests/e2e/mysuite)
#   argument  handed to "playwright test" as it is, if it is made of letters, digits and . _ = / , : @ - only: no blank, no quote,
#             no shell character (--grep=login   specs/login.spec.ts   --project=chromium)
# In that folder it runs
#   npx playwright test --config playwright.config.ts <arguments>
# with these variables in the environment, for your playwright.config.ts and your tests to read:
#   PERFEX_URL             APP_URL of stack.conf, the address of the application (the baseURL)
#   STACK_SSH              the SSH alias, for a setup that must run on the server (a fixture made over ssh, for example)
#   MAILPIT_URL            only when stack.conf has one
#   PLAYWRIGHT_OUTPUT_DIR  <project root>/<LOCAL_TMP_DIR>/e2e/<last part of the folder>, for outputDir: reports and traces
#                          stay in the temporary folder of the project
# The template brings no Node: the suite and Playwright (npm install, npx playwright install) are yours, in the folder. The exit
# status is Playwright's. The smallest playwright.config.ts that uses the variables is in the generated README.md (section "Writing
# your own script"). This is an example of a script of the extra/ folder: copy it there and change what you need. Written for bash 3.2.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd -P)"   # the folder of the stack scripts (stack.conf, lib.sh, locked.sh)
# shellcheck source=../lib.sh
. "$HERE/lib.sh"
stack_load "$HERE"
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[ $# -ge 1 ] || { usage >&2; exit 2; }

# The folder and the arguments end up in a command: a strict pattern for each, checked before anything runs.
FOLDER="$1"; shift
valid_relpath "$FOLDER" || die "invalid folder: \"$FOLDER\" (a folder of the project, relative to its root: no .., no leading / or .)"
[ -d "$ROOT/$FOLDER" ] && [ -f "$ROOT/$FOLDER/playwright.config.ts" ] || die "no playwright.config.ts in $ROOT/$FOLDER"
_arg_re='^[A-Za-z0-9._=/,:@-]+$'
for _a in "$@"; do
    [[ "$_a" =~ $_arg_re ]] || die "invalid argument: \"$_a\" (letters, digits and . _ = / , : @ - only)"
done
_url_re='^https?://[A-Za-z0-9._~:/?&=%#@+,;-]+$'
_tmp_re='^[A-Za-z0-9._][A-Za-z0-9._/-]*$'
[[ "$APP_URL" =~ $_url_re ]] || die "invalid APP_URL in stack.conf: $APP_URL"
[[ "$LOCAL_TMP_DIR" =~ $_tmp_re && "$LOCAL_TMP_DIR" != *..* ]] || die "invalid LOCAL_TMP_DIR in stack.conf: $LOCAL_TMP_DIR"
command -v npx > /dev/null || die "npx not found: this script needs Node on this Mac (the template installs none)"

OUT="$ROOT/$LOCAL_TMP_DIR/e2e/${FOLDER##*/}"
mkdir -p "$OUT"
cd "$ROOT/$FOLDER"
export PERFEX_URL="$APP_URL" STACK_SSH="$HOST" PLAYWRIGHT_OUTPUT_DIR="$OUT"
if [ -n "${MAILPIT_URL:-}" ]; then export MAILPIT_URL; else unset MAILPIT_URL; fi
rc=0
npx playwright test --config playwright.config.ts "$@" || rc=$?
exit "$rc"
