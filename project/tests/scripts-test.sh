#!/usr/bin/env bash
# Tests the other scripts (ci-local.sh, snapshot.sh, reset.sh, install-perfex.sh, doctor.sh) without touching any server,
# with a fake ssh, rsync, curl, git and npx that only record their calls: every refusal must happen BEFORE any call, a valid
# request must reach the server in the shape the server-side scripts expect, and doctor.sh must count what the server
# reports. (deploy.sh has its own test, tests/deploy-test.sh; run.sh and locked.sh tests/locked-test.sh.)
#
# It also tests the example scripts of the template, examples/extra/ (infection-diff.sh, bench.sh, e2e.sh): it finds the
# template through TEMPLATE_REL of stack.conf, or STACK_TEMPLATE_DIR, copies them into the work folder as if they were in
# this project's extra/ folder, and runs them with the same fakes. If the template has no examples/extra/ (this folder was
# written by an older template), that part is skipped and the test does not fail.
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
# the example scripts of the template, as if they sat in this folder's extra/
TEMPLATE_DIR="${STACK_TEMPLATE_DIR:-$ROOT/$TEMPLATE_REL}"
HAVE_EXAMPLES=0
if [ -d "$TEMPLATE_DIR/examples/extra" ]; then
    HAVE_EXAMPLES=1; mkdir -p "$WORK/docker/extra"; cp "$TEMPLATE_DIR"/examples/extra/*.sh "$WORK/docker/extra/"
fi

CALLS="$WORK/calls"
# The fakes record every call. ssh prints STACK_TEST_SSH_OUT (or the lines of the file STACK_TEST_SSH_REPORT when it is asked
# to run a script) and exits with STACK_TEST_SSH_STATUS, or with STACK_TEST_LOCKED_STATUS for the calls that go through
# locked.sh (the command starts with "bash " and names locked.sh), or with STACK_TEST_PROBE_STATUS for the probe that asks
# whether locked.sh is on the server ("test -f ..."): 1 means "it is not"; the second argument of every ssh call is kept in
# <calls>.arg2.<n>, to parse it back. curl prints the file <STACK_TEST_CURL_DIR>/<n> for its n-th call (or STACK_TEST_CURL_OUT)
# and exits with STACK_TEST_CURL_STATUS. rsync copies STACK_TEST_RSYNC_PULL to its last argument when its source is a remote
# path (a pull), and exits with 23, "no such file", when that variable is not set. git prints STACK_TEST_GIT_OUT and exits with STACK_TEST_GIT_STATUS. npx keeps the stack variables of its
# environment and its folder in <calls>.env.<n> and <calls>.pwd.<n>, and exits with STACK_TEST_NPX_STATUS.
for tool in ssh rsync curl git npx; do
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
        printf '%s' "${2:-}" > "$STACK_TEST_CALLS.arg2.$n"
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
    curl)
        if [ -n "${STACK_TEST_CURL_DIR:-}" ]; then
            k=$(( $(cat "$STACK_TEST_CALLS.curl-n" 2>/dev/null || echo 0) + 1 )); echo "$k" > "$STACK_TEST_CALLS.curl-n"
            [ ! -f "$STACK_TEST_CURL_DIR/$k" ] || cat "$STACK_TEST_CURL_DIR/$k"
        else
            [ -z "${STACK_TEST_CURL_OUT:-}" ] || printf '%s' "$STACK_TEST_CURL_OUT"
        fi
        exit "${STACK_TEST_CURL_STATUS:-0}" ;;
    rsync)
        prev=""; last=""
        for a in "$@"; do prev="$last"; last="$a"; done
        # a pull (the first source is a remote path): the file of STACK_TEST_RSYNC_PULL, or rsync's "no such file" (23)
        case "$prev" in
            *:/repo/*) if [ -n "${STACK_TEST_RSYNC_PULL:-}" ]; then cp "$STACK_TEST_RSYNC_PULL" "$last"; else exit 23; fi ;;
        esac
        exit 0 ;;
    git) [ -z "${STACK_TEST_GIT_OUT:-}" ] || printf '%s\n' "$STACK_TEST_GIT_OUT"; exit "${STACK_TEST_GIT_STATUS:-0}" ;;
    npx)
        env | grep -E '^(PERFEX_URL|STACK_SSH|MAILPIT_URL|PLAYWRIGHT_OUTPUT_DIR)=' | sort > "$STACK_TEST_CALLS.env.$n" || true
        pwd -P > "$STACK_TEST_CALLS.pwd.$n"
        exit "${STACK_TEST_NPX_STATUS:-0}" ;;
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
    : > "$CALLS"; rm -f "$CALLS".stdin.* "$CALLS".arg2.* "$CALLS".env.* "$CALLS".pwd.* "$CALLS".curl-n
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

# ---- examples/extra ------------------------------------------------------------------------------------------------------------------
locked_job() { # locked_job: what locked.sh received in the last run, parsed back from the recorded ssh call: the number of words, then the command
    local f
    for f in "$CALLS".arg2.*; do
        [ -f "$f" ] || continue
        case "$(cat "$f")" in
            "bash "*locked.sh*) bash -c 'eval "set -- ${1#bash }"; printf "%s\n" "$#"; printf "%s" "$2"' _ "$(cat "$f")"; return ;;
        esac
    done
}
job_words() { locked_job | sed -n 1p; }
job_text() { locked_job | sed '1d'; }
call_line() { grep -nF -- "$1" "$CALLS" | head -n 1 | cut -d: -f1; }

echo "--- examples/extra/infection-diff.sh"
if [ -f "$WORK/docker/extra/infection-diff.sh" ]; then
    INF=extra/infection-diff.sh
    mkdir -p "$WORK/src/sample_mod/src/Sub" "$WORK/src/sample_mod/tests"
    : > "$WORK/src/sample_mod/src/A.php"; : > "$WORK/src/sample_mod/src/B.php"; : > "$WORK/src/sample_mod/src/Sub/C.php"; : > "$WORK/src/sample_mod/tests/ATest.php"
    ln -s A.php "$WORK/src/sample_mod/src/L.php"
    cat > "$WORK/infection.sample.log" <<'EOF'
Escaped mutants:
================

1) /repo/src/sample_mod/src/A.php:12    [M] Plus

--- Original
+++ New
@@ @@

-        return $a + $b;
+        return $a - $b;

2) /repo/src/sample_mod/src/B.php:7    [M] GreaterThan

--- Original
+++ New
@@ @@

-        if ($x > 0) {
+        if ($x >= 0) {

Timed Out mutants:
==================

1) /repo/src/sample_mod/src/B.php:30    [M] Foreach_

--- Original
+++ New
@@ @@

-        foreach ($list as $item) {
+        foreach ([] as $item) {
EOF
    printf '%s\n' 'Killed mutants:' '===============' '' '1) /repo/src/sample_mod/src/A.php:3    [M] Minus' > "$WORK/infection.clean.log"
    SUMMARY="$(printf '%s\n' '12 mutations were generated:' '       9 mutants were killed' '       3 covered mutants were not detected' '         Covered Code MSI: 75%')"

    # every refusal happens before any call (git included)
    refused "no argument"                                   "$INF"
    refused "a module with a command"                       "$INF" 'sample_mod;id' src/A.php
    refused "a module that is not in the list"              "$INF" zz_mod src/A.php
    refused "a module in capitals"                          "$INF" SAMPLE src/A.php
    refused "a module with a path"                          "$INF" ../sample_mod src/A.php
    STACK_SSH='-oProxyCommand=x' refused "an SSH alias that is an option" "$INF" sample_mod src/A.php
    refused "a file outside src/"                           "$INF" sample_mod tests/ATest.php
    refused "a file with a space"                           "$INF" sample_mod 'src/A B.php'
    refused "a file with a command"                         "$INF" sample_mod 'src/A.php;id'
    refused "a file with .."                                "$INF" sample_mod src/../A.php
    refused "a file with //"                                "$INF" sample_mod src//A.php
    refused "an absolute file"                              "$INF" sample_mod /etc/passwd
    refused "an option instead of a file"                   "$INF" sample_mod --filter=x
    refused "a file that is not PHP"                        "$INF" sample_mod src/A.txt
    refused "a file that does not exist"                    "$INF" sample_mod src/Nope.php
    refused "a file that is a symbolic link"                "$INF" sample_mod src/L.php
    BASE_BRANCH='-x' refused "a BASE_BRANCH that looks like an option" "$INF" sample_mod
    BASE_BRANCH='a..b' refused "a BASE_BRANCH that is a range" "$INF" sample_mod
    BASE_BRANCH='a b' refused "a BASE_BRANCH with a space"  "$INF" sample_mod
    BASE_BRANCH='main;id' refused "a BASE_BRANCH with a command" "$INF" sample_mod
    INFECTION_THREADS=many refused "INFECTION_THREADS that is not a number" "$INF" sample_mod src/A.php
    INFECTION_THREADS=0 refused "INFECTION_THREADS of 0"    "$INF" sample_mod src/A.php
    INFECTION_THREADS=100 refused "INFECTION_THREADS of three digits" "$INF" sample_mod src/A.php
    INFECTION_THREADS='4;id' refused "INFECTION_THREADS with a command" "$INF" sample_mod src/A.php
    INFECTION_PHP='8.4;id' refused "INFECTION_PHP with a command" "$INF" sample_mod src/A.php
    INFECTION_PHP=7.4 refused "an INFECTION_PHP the image does not have" "$INF" sample_mod src/A.php
    INFECTION_LOG='../x.log' refused "an INFECTION_LOG with .." "$INF" sample_mod src/A.php
    INFECTION_LOG='/abs/x.log' refused "an absolute INFECTION_LOG" "$INF" sample_mod src/A.php
    INFECTION_LOG='a b.log' refused "an INFECTION_LOG with a space" "$INF" sample_mod src/A.php
    INFECTION_LOG='x;id' refused "an INFECTION_LOG with a command" "$INF" sample_mod src/A.php

    # the files come from git: the call is what the script documents, the filter reaches locked.sh as one argument
    STACK_TEST_GIT_OUT=$'src/A.php\nsrc/B.php' STACK_TEST_SSH_OUT="$SUMMARY" STACK_TEST_RSYNC_PULL="$WORK/infection.sample.log" sh_run "$INF" sample_mod
    job="$(job_text)"
    if [ "$STATUS" -eq 0 ] \
        && [ "$(grep -c '^git ' "$CALLS" | tr -d ' ')" -eq 1 ] \
        && called "git [-C] [$WORK/src/sample_mod] [diff] [--relative] [--name-only] [--diff-filter=AM] [main] [--] [:(glob)src/**/*.php]"; then
        good "infection-diff.sh: without files it asks git for the added and modified PHP files of src/ against main"
    else
        bad "infection-diff.sh: the git call is not the documented one (status $STATUS): $(cat "$CALLS")"
    fi
    if [ "$(job_words)" -eq 2 ] \
        && [ "$job" = "set -euo pipefail; cd /repo/src/sample_mod; export PATH=/opt/php/$DEFAULT_PHP:\$PATH; [ -x vendor/bin/infection ] || composer install --no-interaction --prefer-dist --quiet; rm -f infection.log; vendor/bin/infection --filter=src/A.php,src/B.php --threads=4 --min-msi=0 --min-covered-msi=0 --no-progress" ]; then
        good "infection-diff.sh: the two files from git end in one --filter=src/A.php,src/B.php, with 4 threads, inside one argument of locked.sh"
    else
        bad "infection-diff.sh: the job that reached locked.sh is not as expected ($(job_words) words): $job"
    fi
    sync_line="$(call_line "[$SSH_ALIAS:/repo/src/]")"; locked_line="$(call_line "[bash $LOCKED_SH ")"; pull_line="$(call_line "[$SSH_ALIAS:/repo/src/sample_mod/infection.log]")"
    if [ -n "$sync_line" ] && [ -n "$locked_line" ] && [ -n "$pull_line" ] && [ "$sync_line" -lt "$locked_line" ] && [ "$locked_line" -lt "$pull_line" ] \
        && called "[$SSH_ALIAS:/repo/src/sample_mod/infection.log] [$WORK/.tmp/infection/sample_mod/infection.log]"; then
        good "infection-diff.sh: sync first, then the job inside the lock, then the log is copied to .tmp/infection/sample_mod/"
    else
        bad "infection-diff.sh: the order or the paths of the calls are wrong: $(cat "$CALLS")"
    fi
    if grep -q '^src/A.php:12 Plus$' "$WORK/out" && grep -q '^   -        return \$a + \$b;$' "$WORK/out" && grep -q '^src/B.php:7 GreaterThan$' "$WORK/out" \
        && ! grep -q 'B.php:30' "$WORK/out" && ! grep -q -- '--- Original' "$WORK/out" && grep -q 'were killed' "$WORK/out"; then
        good "infection-diff.sh: it prints the escaped mutants with file, line and changed lines (not the timed out ones) and the summary"
    else
        bad "infection-diff.sh: the report is not as expected: $(cat "$WORK/out")"
    fi
    if [ -f "$WORK/.tmp/infection/sample_mod/infection.log" ] && [ "$STATUS" -eq 0 ]; then good "infection-diff.sh: the log is kept in .tmp/infection/sample_mod/"; else bad "infection-diff.sh: no log in .tmp/infection/sample_mod/"; fi

    # files given as arguments: git is not called
    STACK_TEST_RSYNC_PULL="$WORK/infection.clean.log" sh_run "$INF" sample_mod src/Sub/C.php
    if [ "$STATUS" -eq 0 ] && ! called "git " && [ "$(job_text | grep -c -- '--filter=src/Sub/C.php --threads=4')" -eq 1 ] && grep -q '^no escaped mutant$' "$WORK/out"; then
        good "infection-diff.sh: a file given as an argument is used without calling git, and a log with no escaped mutant says so"
    else
        bad "infection-diff.sh: a file argument misbehaved (status $STATUS): $(cat "$WORK/out") / $(cat "$CALLS")"
    fi
    # the environment: branch, threads, PHP version and log
    BASE_BRANCH=develop INFECTION_THREADS=2 INFECTION_PHP=8.3 INFECTION_LOG=var/infection.log STACK_TEST_GIT_OUT='src/B.php' STACK_TEST_RSYNC_PULL="$WORK/infection.clean.log" sh_run "$INF" sample_mod
    job="$(job_text)"
    if [ "$STATUS" -eq 0 ] && called "[develop] [--] [:(glob)src/**/*.php]" && case "$job" in *"export PATH=/opt/php/8.3:\$PATH;"*"rm -f var/infection.log;"*"--filter=src/B.php --threads=2 "*) true ;; *) false ;; esac \
        && called "[$SSH_ALIAS:/repo/src/sample_mod/var/infection.log]"; then
        good "infection-diff.sh: BASE_BRANCH, INFECTION_THREADS, INFECTION_PHP and INFECTION_LOG reach git, the job and the copy of the log"
    else
        bad "infection-diff.sh: the environment was not honoured (status $STATUS): $job / $(cat "$CALLS")"
    fi
    # nothing changed: it says so and calls nothing but git (an empty filter would run the whole suite)
    sh_run "$INF" sample_mod
    if [ "$STATUS" -eq 0 ] && called "git " && ! called "ssh [" && ! called "rsync" && grep -q 'nothing to run' "$WORK/out"; then
        good "infection-diff.sh: when git lists no file it says so, exits 0 and makes no call to the server"
    else
        bad "infection-diff.sh: with no changed file it did not stop quietly (status $STATUS): $(cat "$WORK/out") / $(cat "$CALLS")"
    fi
    # a failing git is an error, not an empty list
    STACK_TEST_GIT_STATUS=128 sh_run "$INF" sample_mod
    if [ "$STATUS" -ne 0 ] && ! called "ssh [" && ! called "rsync" && grep -q 'main' "$WORK/out"; then
        good "infection-diff.sh: a failing git (a wrong BASE_BRANCH) stops the script, naming the branch, without any call to the server"
    else
        bad "infection-diff.sh: a failing git was taken for an empty list (status $STATUS): $(cat "$WORK/out")"
    fi
    # the exit status is Infection's, and the escaped mutants are still printed
    STACK_TEST_LOCKED_STATUS=3 STACK_TEST_RSYNC_PULL="$WORK/infection.sample.log" sh_run "$INF" sample_mod src/A.php
    if [ "$STATUS" -eq 3 ] && grep -q '^src/A.php:12 Plus$' "$WORK/out"; then good "infection-diff.sh: the exit status is Infection's (3) and the mutants are printed"; else bad "infection-diff.sh: Infection's status 3 was lost (status $STATUS): $(cat "$WORK/out")"; fi
    # no log at all: not a success, whatever the job said
    sh_run "$INF" sample_mod src/A.php
    if [ "$STATUS" -eq 1 ] && grep -q 'wrote no log' "$WORK/out"; then good "infection-diff.sh: no log on the server is an error (1)"; else bad "infection-diff.sh: a missing log was not an error (status $STATUS): $(cat "$WORK/out")"; fi
    STACK_TEST_LOCKED_STATUS=3 sh_run "$INF" sample_mod src/A.php
    if [ "$STATUS" -eq 3 ] && grep -q 'wrote no log' "$WORK/out"; then good "infection-diff.sh: no log and Infection's status 3: the script exits with 3"; else bad "infection-diff.sh: Infection's status was lost when there was no log (status $STATUS)"; fi
else
    echo "skipped: no infection-diff.sh in the examples/extra/ of the template (STACK_TEMPLATE_DIR, or TEMPLATE_REL of stack.conf)"
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
