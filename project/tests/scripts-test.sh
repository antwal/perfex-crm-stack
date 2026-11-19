#!/usr/bin/env bash
# Tests the other scripts (ci-local.sh, snapshot.sh, reset.sh, install-perfex.sh, doctor.sh) without touching any server,
# with a fake ssh, rsync and curl that only record their calls: every refusal must happen BEFORE any call, a valid
# request must reach the server in the shape the server-side scripts expect, and doctor.sh must count what the server
# reports. (deploy.sh has its own test, tests/deploy-test.sh; run.sh and locked.sh tests/locked-test.sh.)
#
# Usage: bash <this folder>/tests/scripts-test.sh      (exit status 1 at the first failure)
# Files go to <project root>/<LOCAL_TMP_DIR>/stack-tests/scripts-test (or STACK_TESTS_WORK/scripts-test).
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
DOCKER_DIR="$(cd "$HERE/.." && pwd -P)"
# shellcheck source=../stack.conf
. "$DOCKER_DIR/stack.conf"
ROOT="$(cd "$DOCKER_DIR/$PROJECT_ROOT_REL" && pwd -P)"
WORK="${STACK_TESTS_WORK:-$ROOT/$LOCAL_TMP_DIR/stack-tests}/scripts-test"

rm -rf "$WORK"
mkdir -p "$WORK/bin" "$WORK/docker" "$WORK/src/sample_mod"
cp "$DOCKER_DIR"/*.sh "$WORK/docker/"
sed -e 's#^PROJECT_ROOT_REL=.*#PROJECT_ROOT_REL=".."#' -e 's#^SYNC_DIR=.*#SYNC_DIR="src"#' \
    -e 's#^CI_MODULES=.*#CI_MODULES=""#' -e 's#^CI_STATIC_SCRIPT=.*#CI_STATIC_SCRIPT=""#' \
    "$DOCKER_DIR/stack.conf" > "$WORK/docker/stack.conf"
# shellcheck disable=SC1091
. "$WORK/docker/stack.conf"
: > "$WORK/src/sample_mod/sample_mod.php"; echo '{}' > "$WORK/src/sample_mod/composer.json"

CALLS="$WORK/calls"
# The fakes record every call. ssh prints STACK_TEST_SSH_OUT (or the lines of the file STACK_TEST_SSH_REPORT when it is asked
# to run a script) and exits with STACK_TEST_SSH_STATUS, or with STACK_TEST_LOCKED_STATUS for the calls that go through
# locked.sh (the command starts with "bash " and names locked.sh), or with STACK_TEST_PROBE_STATUS for the probe that asks
# whether locked.sh is on the server ("test -f ..."): 1 means "it is not"; curl prints STACK_TEST_CURL_OUT and exits with
# STACK_TEST_CURL_STATUS.
for tool in ssh rsync curl; do
    cat > "$WORK/bin/$tool" <<'FAKE'
#!/usr/bin/env bash
name="$(basename "$0")"
n=$(( $(wc -l < "$STACK_TEST_CALLS") + 1 ))
printf '%s' "$name" >> "$STACK_TEST_CALLS"
for a in "$@"; do printf ' [%s]' "$a" >> "$STACK_TEST_CALLS"; done
printf '\n' >> "$STACK_TEST_CALLS"
cat > "$STACK_TEST_CALLS.stdin.$n"
case "$name" in
    ssh)
        status="${STACK_TEST_SSH_STATUS:-0}"
        case "${2:-}" in
            "bash "*locked.sh*) status="${STACK_TEST_LOCKED_STATUS:-$status}" ;;
            "test -f "*) status="${STACK_TEST_PROBE_STATUS:-$status}" ;;
        esac
        case "$*" in
            *"bash -s --"*) [ -z "${STACK_TEST_SSH_REPORT:-}" ] || cat "$STACK_TEST_SSH_REPORT" ;;
            *) [ -z "${STACK_TEST_SSH_OUT:-}" ] || printf '%s\n' "$STACK_TEST_SSH_OUT" ;;
        esac
        exit "$status" ;;
    curl) [ -z "${STACK_TEST_CURL_OUT:-}" ] || printf '%s' "$STACK_TEST_CURL_OUT"; exit "${STACK_TEST_CURL_STATUS:-0}" ;;
esac
exit 0
FAKE
    chmod +x "$WORK/bin/$tool"
done

fail=0
bad() { echo "FAIL: $*"; fail=1; }
good() { echo "ok: $*"; }
sh_run() { # sh_run <script> <args...>: runs a script of the work folder with the fakes; sets STATUS; stdin is /dev/null
    local script="$1"; shift
    : > "$CALLS"; rm -f "$CALLS".stdin.*
    PATH="$WORK/bin:$PATH" STACK_TEST_CALLS="$CALLS" bash "$WORK/docker/$script" "$@" > "$WORK/out" 2>&1 < /dev/null
    STATUS=$?
}
refused() { # refused <label> <script> <args...>: no success and no call at all
    local label="$1"; shift
    sh_run "$@"
    if [ "$STATUS" -eq 0 ] || [ -s "$CALLS" ]; then bad "$label was not refused (status $STATUS, calls: $(cat "$CALLS"))"; else good "$label refused, no call made"; fi
}
called() { grep -qF -- "$1" "$CALLS"; }

# ---- ci-local.sh -------------------------------------------------------------------------------------------------------------
echo "--- ci-local.sh"
refused "a module with a command"            ci-local.sh 'sample_mod;id'
refused "a module in capitals"               ci-local.sh SAMPLE
refused "a module with a path"               ci-local.sh ../x
STACK_SSH='-oProxyCommand=x' refused "an SSH alias that is an option" ci-local.sh sample_mod
MATRIX_PHP_VERSIONS='8.4;id' refused "a PHP version with a command" ci-local.sh sample_mod
MATRIX_PHP_VERSIONS='8.9' refused "a PHP version the image does not have" ci-local.sh sample_mod
STATIC_PHP='7.4' refused "a static PHP version the image does not have" ci-local.sh sample_mod
MATRIX_PHP_VERSIONS="$DEFAULT_PHP" SKIP_STATIC=1 sh_run ci-local.sh sample_mod
if [ "$STATUS" -eq 0 ] && grep -q 'matrix green' "$WORK/out" \
    && called "[bash $LOCKED_SH " && called "composer\\ validate\\ --strict" && called "/opt/php/$DEFAULT_PHP"; then
    good "ci-local.sh: a valid run goes through locked.sh, validates and checks, and reports green"
else
    bad "ci-local.sh: a valid run misbehaved (status $STATUS): $(cat "$WORK/out") / $(cat "$CALLS")"
fi
MATRIX_PHP_VERSIONS="$DEFAULT_PHP" SKIP_STATIC=1 STACK_TEST_LOCKED_STATUS=1 sh_run ci-local.sh sample_mod
if [ "$STATUS" -ne 0 ] && grep -q 'matrix RED' "$WORK/out"; then good "ci-local.sh: a failing job makes the matrix red and the exit status non-zero"; else bad "ci-local.sh: a failing job was not reported (status $STATUS)"; fi

# ---- snapshot.sh -------------------------------------------------------------------------------------------------------------
echo "--- snapshot.sh"
refused "a label with a space"       snapshot.sh 'Bad Label'
refused "a label with a command"     snapshot.sh 'a;id'
refused "a label in capitals"        snapshot.sh CLEAN
refused "two arguments"              snapshot.sh a b
refused "a label that is too long"   snapshot.sh abcdefghijklmnopqrstuvwxyz0123456789
sh_run snapshot.sh zzlabel9
if [ "$STATUS" -eq 0 ] && grep -Eq 'bash\\ -s\\ --\\ [0-9]{8}-[0-9]{6}-zzlabel9\]' "$CALLS" && called "[bash $LOCKED_SH "; then
    good "snapshot.sh: a valid label reaches the server through locked.sh as a dated name"
else
    bad "snapshot.sh: a valid snapshot misbehaved (status $STATUS): $(cat "$WORK/out") / $(cat "$CALLS")"
fi
script="$(ls "$CALLS".stdin.* | while read -r f; do [ -s "$f" ] && echo "$f"; done | head -n 1)"
if [ -n "$script" ] && grep -q 'mariadb-dump --defaults-extra-file' "$script" && ! grep -q 'zzlabel9' "$script" && ! grep -Eq -- '-p"?\$PERFEX_DB_PASSWORD|--password' "$script"; then
    good "snapshot.sh: the script dumps with an option file (no password on a command line) and carries no value of yours"
else
    bad "snapshot.sh: the server script is not as expected"
fi

# ---- reset.sh ----------------------------------------------------------------------------------------------------------------
echo "--- reset.sh"
NAME1="20261107-120000-clean"
refused "no argument"                         reset.sh
refused "a name that is not a snapshot name"  reset.sh 'latest'
refused "a name with a command"               reset.sh '20261107-120000;id'
refused "a name with a path"                  reset.sh '../20261107-120000'
refused "no terminal and no confirmation"     reset.sh "$NAME1"
STACK_RESET_YES='20261107-999999' refused "a confirmation for another snapshot" reset.sh "$NAME1"
sh_run reset.sh --list
if [ "$STATUS" -eq 0 ] && called "ls -1 /repo/.tmp/snapshots"; then good "reset.sh --list asks the server for the snapshots"; else bad "reset.sh --list misbehaved: $(cat "$CALLS")"; fi
STACK_RESET_YES="$NAME1" sh_run reset.sh "$NAME1"
if [ "$STATUS" -eq 0 ] && called "bash\\ -s\\ --\\ $NAME1" && called "[bash $LOCKED_SH "; then good "reset.sh: with the confirmation, the name reaches the server through locked.sh"; else bad "reset.sh: a confirmed reset misbehaved (status $STATUS): $(cat "$WORK/out") / $(cat "$CALLS")"; fi
script="$(ls "$CALLS".stdin.* | while read -r f; do [ -s "$f" ] && echo "$f"; done | head -n 1)"
if [ -n "$script" ] && grep -q 'gzip -t' "$script" && grep -q 'tar -tzf' "$script" && ! grep -q "$NAME1" "$script"; then
    good "reset.sh: the server script checks both files before deleting and carries no value of yours"
else
    bad "reset.sh: the server script is not as expected"
fi

# ---- install-perfex.sh ---------------------------------------------------------------------------------------------------------
echo "--- install-perfex.sh"
mkdir -p "$WORK/app-ok/application" "$WORK/app-bad"; : > "$WORK/app-ok/index.php"; echo hi > "$WORK/notes.txt"
refused "no argument"                         install-perfex.sh
refused "a path that does not exist"          install-perfex.sh "$WORK/nowhere"
refused "a folder without index.php/application" install-perfex.sh "$WORK/app-bad"
refused "a file that is not a zip"            install-perfex.sh "$WORK/notes.txt"
refused "two sources"                         install-perfex.sh "$WORK/app-ok" "$WORK/app-ok"
sh_run install-perfex.sh "$WORK/app-ok"
if [ "$STATUS" -eq 0 ] && called "rsync [-az] [--exclude] [.DS_Store] [-e] [ssh] [$WORK/app-ok/] [$SSH_ALIAS:/app/]"; then good "install-perfex.sh: a folder is copied to /app"; else bad "install-perfex.sh: a folder was not copied (status $STATUS): $(cat "$WORK/out") / $(cat "$CALLS")"; fi
STACK_TEST_SSH_OUT="/app/index.php" sh_run install-perfex.sh "$WORK/app-ok"
if [ "$STATUS" -ne 0 ] && ! called "rsync" && grep -q -- '--force' "$WORK/out"; then good "install-perfex.sh: a /app that is not empty is refused, and --force is named"; else bad "install-perfex.sh: a non-empty /app was not refused (status $STATUS)"; fi
STACK_TEST_SSH_OUT="/app/index.php" sh_run install-perfex.sh --force "$WORK/app-ok"
if [ "$STATUS" -eq 0 ] && called "[$SSH_ALIAS:/app/]"; then good "install-perfex.sh: --force copies over a non-empty /app"; else bad "install-perfex.sh: --force did not copy (status $STATUS)"; fi
( cd "$WORK" && mkdir -p zipdir && : > zipdir/x && /usr/bin/zip -q -r perfex.zip zipdir >/dev/null 2>&1 || : )
if [ -f "$WORK/perfex.zip" ]; then
    sh_run install-perfex.sh "$WORK/perfex.zip"
    script="$(ls "$CALLS".stdin.* | while read -r f; do [ -s "$f" ] && echo "$f"; done | head -n 1)"
    if [ "$STATUS" -eq 0 ] && called "$SSH_ALIAS:/repo/.tmp/perfex-install.zip" && [ -n "$script" ] && grep -q 'unzip -q' "$script"; then
        good "install-perfex.sh: a zip is sent to /repo/.tmp and unpacked on the server"
    else
        bad "install-perfex.sh: a zip was not handled (status $STATUS): $(cat "$WORK/out")"
    fi
fi

# ---- ensure_locked_sh (run.sh): locked.sh already on the server, or missing --------------------------------------------------------
echo "--- run.sh and the copy of locked.sh"
sh_run run.sh 'echo hi'
if [ "$STATUS" -eq 0 ] && [ "$(wc -l < "$CALLS" | tr -d ' ')" -eq 2 ] \
    && [ "$(sed -n 1p "$CALLS")" = "ssh [$SSH_ALIAS] [test -f $LOCKED_SH]" ] \
    && [ "$(sed -n 2p "$CALLS")" = "ssh [$SSH_ALIAS] [bash $LOCKED_SH echo\\ hi]" ]; then
    good "run.sh: locked.sh is on the server, so the probe is followed by the command and by no copy"
else
    bad "run.sh: with locked.sh in place the calls were not probe + command (status $STATUS): $(cat "$CALLS")"
fi
STACK_TEST_PROBE_STATUS=1 sh_run run.sh 'echo hi'
if [ "$STATUS" -eq 0 ] && [ "$(wc -l < "$CALLS" | tr -d ' ')" -eq 4 ] \
    && [ "$(sed -n 1p "$CALLS")" = "ssh [$SSH_ALIAS] [test -f $LOCKED_SH]" ] \
    && [ "$(sed -n 2p "$CALLS")" = "ssh [$SSH_ALIAS] [mkdir -p $(dirname "$LOCKED_SH")]" ] \
    && [ "$(sed -n 3p "$CALLS")" = "rsync [-az] [-e] [ssh] [$WORK/docker/locked.sh] [$SSH_ALIAS:$LOCKED_SH]" ] \
    && [ "$(sed -n 4p "$CALLS")" = "ssh [$SSH_ALIAS] [bash $LOCKED_SH echo\\ hi]" ] \
    && grep -q 'locked.sh put on the server' "$WORK/out"; then
    good "run.sh: locked.sh missing on the server: probe, mkdir, rsync of locked.sh, then the command, in that order"
else
    bad "run.sh: the copy of a missing locked.sh did not go probe, mkdir, rsync, command (status $STATUS): $(cat "$CALLS")"
fi
# a failing locked job must not be taken for a missing locked.sh: the probe is not a call through locked.sh
STACK_TEST_LOCKED_STATUS=1 sh_run run.sh 'false'
if [ "$STATUS" -eq 1 ] && [ "$(wc -l < "$CALLS" | tr -d ' ')" -eq 2 ] && ! called "rsync"; then
    good "run.sh: the status of the locked job (1) is not the answer of the probe, so locked.sh is not copied again"
else
    bad "run.sh: a failing job was mixed up with the probe (status $STATUS): $(cat "$CALLS")"
fi

# ---- doctor.sh -----------------------------------------------------------------------------------------------------------------
echo "--- doctor.sh"
sh_run doctor.sh --guide
if [ "$STATUS" -eq 0 ] && grep -q "Host $SSH_ALIAS" "$WORK/out" && grep -q 'Port 2222' "$WORK/out" && grep -q 'docker build' "$WORK/out" && [ ! -s "$CALLS" ]; then
    good "doctor.sh --guide prints the steps with the values, without any call"
else
    bad "doctor.sh --guide misbehaved (status $STATUS)"
fi
refused "an unknown argument" doctor.sh --nope
STACK_TEST_SSH_STATUS=255 STACK_TEST_CURL_OUT=000 STACK_TEST_CURL_STATUS=6 sh_run doctor.sh
if [ "$STATUS" -eq 2 ] && grep -q 'FAIL: cannot log in' "$WORK/out" && grep -q 'does not resolve from this Mac' "$WORK/out"; then
    good "doctor.sh: no login and no DNS are two failures, and the exit status counts them"
else
    bad "doctor.sh: failure path misbehaved (status $STATUS): $(cat "$WORK/out")"
fi
printf '%s\n' 'ok: PHP 8.4 (PHP 8.4.0)' 'note: variable MAILPIT_URL is not set (optional)' 'FAIL: variable PERFEX_DB_PASSWORD is not set in the SSH session' 'FAIL: locked.sh is not on the server' > "$WORK/report"
STACK_TEST_SSH_REPORT="$WORK/report" STACK_TEST_CURL_OUT=302 STACK_TEST_CURL_STATUS=0 sh_run doctor.sh
if [ "$STATUS" -eq 2 ] && grep -q 'ok: SSH login' "$WORK/out" && grep -q 'FAIL: locked.sh is not on the server' "$WORK/out" && grep -q 'ok: GET .* answers 302' "$WORK/out"; then
    good "doctor.sh: it reports what the server says, counts the failures (2) and checks the application"
else
    bad "doctor.sh: with a server report it misbehaved (status $STATUS): $(cat "$WORK/out")"
fi
STACK_TEST_SSH_REPORT="$WORK/report" STACK_TEST_CURL_OUT=502 STACK_TEST_CURL_STATUS=0 sh_run doctor.sh
if [ "$STATUS" -eq 3 ] && grep -q 'FAIL: GET .* answers 502' "$WORK/out"; then good "doctor.sh: a 502 from the application is a failure"; else bad "doctor.sh: a 502 was not counted (status $STATUS)"; fi

[ "$fail" -eq 0 ] && echo "=== scripts-test: all ok ===" || echo "=== scripts-test: FAILED ==="
exit "$fail"
