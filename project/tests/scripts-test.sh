#!/usr/bin/env bash
# Tests the other scripts (ci-local.sh, snapshot.sh, reset.sh, install-perfex.sh, doctor.sh) without touching any server,
# with a fake ssh, rsync, curl, git and npx that only record their calls: every refusal must happen BEFORE any call, a valid
# request must reach the server in the shape the server-side scripts expect, and doctor.sh must count what the server
# reports. (deploy.sh has its own test, tests/deploy-test.sh; run.sh and locked.sh tests/locked-test.sh.)
#
# The job of ci-local.sh reaches the server as a script on the standard input. This test takes that very text from the recorded
# call and runs it against a folder tree standing in for the server (STACK_SERVER_ROOT), with a fake composer and a fake php: a
# module with a composer.json takes the Composer road, one without it php -l on its PHP files and then the check file.
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
mkdir -p "$WORK/bin" "$WORK/fakebin" "$WORK/docker" "$WORK/src/sample_mod" "$WORK/src/plain_mod"
cp "$DOCKER_DIR"/*.sh "$WORK/docker/"
sed -e 's#^PROJECT_ROOT_REL=.*#PROJECT_ROOT_REL=".."#' -e 's#^SYNC_DIR=.*#SYNC_DIR="src"#' \
    -e 's#^CI_MODULES=.*#CI_MODULES=""#' -e 's#^CI_STATIC_SCRIPT=.*#CI_STATIC_SCRIPT=""#' \
    "$DOCKER_DIR/stack.conf" > "$WORK/docker/stack.conf"
# shellcheck disable=SC1091
. "$WORK/docker/stack.conf"
# a stack.conf written by a template older than 0.4.0 has no CI_CHECK_FILE (the scripts take the same default)
CI_CHECK_FILE="${CI_CHECK_FILE:-tests/check.sh}"
# sample_mod has a composer.json (the Composer road of ci-local.sh), plain_mod has none (the plain road)
: > "$WORK/src/sample_mod/sample_mod.php"; echo '{}' > "$WORK/src/sample_mod/composer.json"
echo '<?php' > "$WORK/src/plain_mod/plain_mod.php"
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
stdin_script() { # stdin_script: the file that holds the script an ssh call received on its standard input (the first one that is not empty)
    ls "$CALLS".stdin.* | while read -r f; do [ -s "$f" ] && echo "$f"; done | head -n 1
}

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
if [ "$STATUS" -eq 0 ] && grep -q 'matrix green' "$WORK/out" && called "[bash $LOCKED_SH "; then
    good "ci-local.sh: a valid run goes through locked.sh and reports green"
else
    bad "ci-local.sh: a valid run misbehaved (status $STATUS): $(cat "$WORK/out") / $(cat "$CALLS")"
fi
# the road is chosen on the server: no probe of composer.json before the job, so one call for the folders and one for the job
if [ "$(grep -c '^ssh ' "$CALLS" | tr -d ' ')" -eq 2 ] && ! grep -F 'ssh [' "$CALLS" | grep -qF 'composer.json'; then
    good "ci-local.sh: two ssh calls only (the folders of sync.sh and the job), and none asks for composer.json"
else
    bad "ci-local.sh: the ssh calls are not the folders and the job alone: $(cat "$CALLS")"
fi
if [ "$(job_words)" -eq 2 ] && [ "$(job_text)" = "bash -s -- $DEFAULT_PHP src sample_mod tests/check.sh check" ]; then
    good "ci-local.sh: the job is a script on the standard input, with the PHP version, folder, module, check file and check script as parameters"
else
    bad "ci-local.sh: the job that reached locked.sh is not as expected ($(job_words) words): $(job_text)"
fi
CI_SCRIPT="$(stdin_script)"
if [ -n "$CI_SCRIPT" ] && grep -qF 'composer validate --strict --no-check-version' "$CI_SCRIPT" && grep -qF 'php -l' "$CI_SCRIPT" && grep -qF 'syntax check only' "$CI_SCRIPT" \
    && ! grep -qF 'sample_mod' "$CI_SCRIPT" && ! grep -qF 'tests/check.sh' "$CI_SCRIPT"; then
    good "ci-local.sh: the script holds both roads, and none of your values (module, check file) is pasted into its text"
    cp "$CI_SCRIPT" "$WORK/ci-remote.sh"
else
    bad "ci-local.sh: the script on the standard input is missing, lacks a road, or carries a value of yours: ${CI_SCRIPT:-none}"
fi
MATRIX_PHP_VERSIONS="$DEFAULT_PHP" SKIP_STATIC=1 STACK_TEST_LOCKED_STATUS=1 sh_run ci-local.sh sample_mod
if [ "$STATUS" -ne 0 ] && grep -q 'matrix RED' "$WORK/out"; then good "ci-local.sh: a failing job makes the matrix red and the exit status non-zero"; else bad "ci-local.sh: a failing job was not reported (status $STATUS)"; fi

# a module without a composer.json is no longer skipped: it is a job like any other, and the server chooses its road
MATRIX_PHP_VERSIONS="$DEFAULT_PHP" SKIP_STATIC=1 sh_run ci-local.sh plain_mod
if [ "$STATUS" -eq 0 ] && grep -q 'matrix green' "$WORK/out" && ! grep -q 'skipped' "$WORK/out" && [ "$(grep -c '^ssh ' "$CALLS" | tr -d ' ')" -eq 2 ] \
    && [ "$(job_words)" -eq 2 ] && [ "$(job_text)" = "bash -s -- $DEFAULT_PHP src plain_mod tests/check.sh check" ]; then
    good "ci-local.sh: a module without a composer.json is not skipped: the same two calls, the same job with its own name"
else
    bad "ci-local.sh: a module without a composer.json misbehaved (status $STATUS): $(cat "$WORK/out") / $(cat "$CALLS")"
fi
cp "$WORK/docker/stack.conf" "$WORK/stack.conf.ci-keep"
set_conf() { # set_conf <name> <value>: the work copy of stack.conf with that one value replaced (or added)
    grep -v "^$1=" "$WORK/stack.conf.ci-keep" > "$WORK/docker/stack.conf"
    printf '%s="%s"\n' "$1" "$2" >> "$WORK/docker/stack.conf"
}
set_conf CI_CHECK_FILE ci/run.php
MATRIX_PHP_VERSIONS="$DEFAULT_PHP" SKIP_STATIC=1 sh_run ci-local.sh plain_mod
if [ "$STATUS" -eq 0 ] && [ "$(job_text)" = "bash -s -- $DEFAULT_PHP src plain_mod ci/run.php check" ]; then good "ci-local.sh: CI_CHECK_FILE of stack.conf reaches the job as the check file"; else bad "ci-local.sh: CI_CHECK_FILE of stack.conf was not passed (status $STATUS): $(job_text)"; fi
grep -v '^CI_CHECK_FILE=' "$WORK/stack.conf.ci-keep" > "$WORK/docker/stack.conf"
MATRIX_PHP_VERSIONS="$DEFAULT_PHP" SKIP_STATIC=1 sh_run ci-local.sh plain_mod
if [ "$STATUS" -eq 0 ] && [ "$(job_text)" = "bash -s -- $DEFAULT_PHP src plain_mod tests/check.sh check" ]; then good "ci-local.sh: a stack.conf without CI_CHECK_FILE (written before 0.4.0) gets tests/check.sh"; else bad "ci-local.sh: the default check file was not used (status $STATUS): $(job_text)"; fi
for hostile in '../x.sh' '/abs/x.sh' 'tests//check.sh' 'tests/check.txt' 'a b.sh' 'tests/check.sh;id' '.hidden/x.sh' 'tests/a..b.sh'; do
    set_conf CI_CHECK_FILE "$hostile"
    refused "a CI_CHECK_FILE of \"$hostile\" in stack.conf" ci-local.sh plain_mod
done
# the static analysis of a module without a composer.json is skipped on the server, before anything is installed
cp "$WORK/stack.conf.ci-keep" "$WORK/docker/stack.conf"
set_conf MATRIX_PHP_VERSIONS ""
printf '%s\n' 'CI_STATIC_SCRIPT="stan"' >> "$WORK/docker/stack.conf"
sh_run ci-local.sh plain_mod
job="$(job_text)"
if [ "$STATUS" -eq 0 ] && [ "$(grep -c "^ssh .*locked.sh" "$CALLS" | tr -d ' ')" -eq 1 ] \
    && case "$job" in *"[ -f composer.json ] ||"*"rm -rf vendor"*) true ;; *) false ;; esac && grep -q 'static analysis of plain_mod' "$WORK/out"; then
    good "ci-local.sh: the static analysis is one job that tests composer.json before rm -rf vendor, so a module without one is skipped there"
else
    bad "ci-local.sh: the static analysis job is not as expected (status $STATUS): $job / $(cat "$CALLS")"
fi
cp "$WORK/stack.conf.ci-keep" "$WORK/docker/stack.conf"

# ---- ci-local.sh, the job on the server: the very script that reached the standard input, run against a folder tree --------------------
echo "--- ci-local.sh: the script of the server, against a folder tree"
if [ ! -s "$WORK/ci-remote.sh" ]; then
    bad "no server script was captured from ci-local.sh"
else
    SRV="$WORK/server"; COMPOSER_LOG="$WORK/composer.log"; PHP_LOG="$WORK/php.log"
    mkdir -p "$SRV/repo/src"
    cat > "$WORK/fakebin/composer" <<'FAKE'
#!/usr/bin/env bash
# fake composer: records the call
echo "$*" >> "$STACK_TEST_COMPOSER_LOG"
FAKE
    cat > "$WORK/fakebin/php" <<'FAKE'
#!/usr/bin/env bash
# fake php: records the call; -v prints a version line, -l says whether the file holds the text SYNTAX ERROR; any other call
# (a check file run by php) exits with STACK_TEST_PHP_STATUS
echo "$*" >> "$STACK_TEST_PHP_LOG"
case "${1:-}" in
    -v) echo "PHP 8.4.0 (cli) (fake)"; exit 0 ;;
    -l)
        if grep -q 'SYNTAX ERROR' "${2:-}" 2>/dev/null; then echo "PHP Parse error: syntax error in ${2:-} on line 1"; exit 255; fi
        echo "No syntax errors detected in ${2:-}"; exit 0 ;;
esac
exit "${STACK_TEST_PHP_STATUS:-0}"
FAKE
    chmod +x "$WORK/fakebin/composer" "$WORK/fakebin/php"
    remote_ci() { # remote_ci <php> <sync dir> <module> <check file> <check script>: sets RSTATUS; the output is in $WORK/rout, the fakes' logs in $COMPOSER_LOG and $PHP_LOG
        : > "$COMPOSER_LOG"; : > "$PHP_LOG"
        PATH="$WORK/fakebin:$PATH" STACK_SERVER_ROOT="$SRV" STACK_TEST_COMPOSER_LOG="$COMPOSER_LOG" STACK_TEST_PHP_LOG="$PHP_LOG" \
            bash "$WORK/ci-remote.sh" "$@" > "$WORK/rout" 2>&1 < /dev/null
        RSTATUS=$?
    }
    check() { # check <label> <command...>: passes when the command succeeds
        local label="$1"; shift
        if "$@"; then good "$label"; else bad "$label (status $RSTATUS): $(cat "$WORK/rout")"; fi
    }
    lint_lines() { grep -c '^-l ' "$PHP_LOG" | tr -d ' '; }
    mk_plain() { # mk_plain <module>: a module without a composer.json, with PHP files in the places the lint must and must not reach
        local d="$SRV/repo/src/$1"
        rm -rf "$d"; mkdir -p "$d/src/Sub" "$d/vendor/pkg" "$d/node_modules/m" "$d/.git" "$d/tests"
        echo '<?php' > "$d/$1.php"; echo '<?php' > "$d/src/A.php"; echo '<?php' > "$d/src/Sub/B.php"
        echo '<?php' > "$d/vendor/pkg/V.php"; echo '<?php' > "$d/node_modules/m/N.php"; echo '<?php' > "$d/.git/H.php"
        printf '%s\n' '#!/usr/bin/env bash' 'echo "ok from check"' ': > check.ran' > "$d/tests/check.sh"
    }
    PLAIN="$SRV/repo/src/plain_mod"

    # a. a module with a composer.json: the Composer road, the three commands as they always were, no php -l
    mkdir -p "$SRV/repo/src/comp_mod/src"
    echo '{}' > "$SRV/repo/src/comp_mod/composer.json"; echo '<?php' > "$SRV/repo/src/comp_mod/comp_mod.php"; echo '<?php' > "$SRV/repo/src/comp_mod/src/A.php"
    remote_ci "$DEFAULT_PHP" src comp_mod tests/check.sh check
    check "server: a module with a composer.json succeeds" test "$RSTATUS" -eq 0
    check "server: the Composer road runs exactly install, validate and run, in that order, with the options of always" \
        test "$(cat "$COMPOSER_LOG")" = "$(printf '%s\n' 'install --no-interaction --prefer-dist --quiet' 'validate --strict --no-check-version' 'run --no-interaction check')"
    check "server: the Composer road makes no php -l" test "$(lint_lines)" -eq 0

    # b. a module without one: php -l on its own PHP files (not vendor/, node_modules/ or a dot-folder), then the check file
    mk_plain plain_mod
    remote_ci "$DEFAULT_PHP" src plain_mod tests/check.sh check
    check "server: a module without a composer.json succeeds" test "$RSTATUS" -eq 0
    check "server: the plain road does not call composer" test ! -s "$COMPOSER_LOG"
    check "server: three -l calls, for plain_mod.php, src/A.php and src/Sub/B.php, none for vendor/, node_modules/ or .git/" \
        sh -c "[ \"\$(grep -c '^-l ' '$PHP_LOG')\" -eq 3 ] && grep -qxF -- '-l ./plain_mod.php' '$PHP_LOG' && grep -qxF -- '-l ./src/A.php' '$PHP_LOG' && grep -qxF -- '-l ./src/Sub/B.php' '$PHP_LOG'"
    check "server: the check file ran in the folder of the module" test -f "$PLAIN/check.ran"
    check "server: the syntax check is reported before the output of the check file" \
        sh -c "[ \"\$(grep -n '^syntax check: 3 PHP file(s), no error\$' '$WORK/rout' | head -n 1 | cut -d: -f1)\" -lt \"\$(grep -n '^ok from check\$' '$WORK/rout' | head -n 1 | cut -d: -f1)\" ]"

    # c. the same module without a check file: only the syntax check, said so
    rm -f "$PLAIN/tests/check.sh" "$PLAIN/check.ran"
    remote_ci "$DEFAULT_PHP" src plain_mod tests/check.sh check
    check "server: a module without a check file is syntax-checked only, and says so" sh -c "[ $RSTATUS -eq 0 ] && grep -q 'syntax check only' '$WORK/rout'"

    # d. a check file in PHP runs with php (the match is exact: tests/check.php is also linted, as -l ./tests/check.php)
    echo '<?php' > "$PLAIN/tests/check.php"
    remote_ci "$DEFAULT_PHP" src plain_mod tests/check.php check
    check "server: a .php check file is run with php" sh -c "[ $RSTATUS -eq 0 ] && grep -qxF 'tests/check.php' '$PHP_LOG'"

    # e. a syntax error: the matrix fails, names the file, and the check file does not run
    mk_plain plain_mod
    echo '<?php // SYNTAX ERROR' > "$PLAIN/src/Bad.php"
    remote_ci "$DEFAULT_PHP" src plain_mod tests/check.sh check
    check "server: a syntax error fails the job, names the file, and the check file does not run" \
        sh -c "[ $RSTATUS -ne 0 ] && grep -q 'src/Bad.php' '$WORK/rout' && [ ! -e '$PLAIN/check.ran' ]"

    # f. a check file that fails: its status
    mk_plain plain_mod
    printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$PLAIN/tests/check.sh"
    remote_ci "$DEFAULT_PHP" src plain_mod tests/check.sh check
    check "server: a check file that exits 1 makes the job exit 1" test "$RSTATUS" -eq 1

    # g. a check file that is a symbolic link is never followed; neither is a folder on the way to it
    mk_plain plain_mod
    mkdir -p "$WORK/elsewhere"
    printf '%s\n' '#!/usr/bin/env bash' ': > "$(dirname "$0")/ran"' > "$WORK/elsewhere/target.sh"
    ln -s "$WORK/elsewhere/target.sh" "$PLAIN/tests/link.sh"
    remote_ci "$DEFAULT_PHP" src plain_mod tests/link.sh check
    check "server: a check file that is a symbolic link is refused, and its target did not run" \
        sh -c "[ $RSTATUS -ne 0 ] && grep -q 'symbolic link' '$WORK/rout' && [ ! -e '$WORK/elsewhere/ran' ] && ! grep -qxF 'tests/link.sh' '$PHP_LOG'"
    mkdir -p "$SRV/repo/src/linked_mod" "$WORK/elsewhere-dir"
    echo '<?php' > "$SRV/repo/src/linked_mod/linked_mod.php"
    printf '%s\n' '#!/usr/bin/env bash' ': > "$(dirname "$0")/ran"' > "$WORK/elsewhere-dir/check.sh"
    ln -s "$WORK/elsewhere-dir" "$SRV/repo/src/linked_mod/tests"
    remote_ci "$DEFAULT_PHP" src linked_mod tests/check.sh check
    check "server: a tests/ folder that is a symbolic link is refused, and the check file in it did not run" \
        sh -c "[ $RSTATUS -ne 0 ] && grep -q 'symbolic link' '$WORK/rout' && [ ! -e '$WORK/elsewhere-dir/ran' ] && ! grep -qxF 'tests/check.sh' '$PHP_LOG'"

    # h. a module that is not on the server
    remote_ci "$DEFAULT_PHP" src ghost_mod tests/check.sh check
    check "server: a module that is not there is refused, with the advice to run sync.sh" sh -c "[ $RSTATUS -ne 0 ] && grep -q 'run sync.sh' '$WORK/rout'"

    # i. hostile parameters are refused again on the server, before anything runs (not even php -v), and nothing is written
    mk_plain plain_mod
    before="$(find "$SRV" | wc -l | tr -d ' ')"
    hostile_ci() { # hostile_ci <label> <php> <sync dir> <module> <check file> <check script>
        local label="$1"; shift
        remote_ci "$@"
        check "server refuses $label, and nothing ran" sh -c "[ $RSTATUS -ne 0 ] && [ ! -s '$COMPOSER_LOG' ] && [ ! -s '$PHP_LOG' ]"
    }
    hostile_ci "a PHP version with a command"      '8.4;id' src plain_mod tests/check.sh check
    hostile_ci "an absolute sync folder"           "$DEFAULT_PHP" /abs plain_mod tests/check.sh check
    hostile_ci "a sync folder with .."             "$DEFAULT_PHP" src/../src plain_mod tests/check.sh check
    hostile_ci "a module with a command"           "$DEFAULT_PHP" src 'plain_mod;touch pwned' tests/check.sh check
    hostile_ci "a module with a path"              "$DEFAULT_PHP" src ../plain_mod tests/check.sh check
    hostile_ci "a check file with .."              "$DEFAULT_PHP" src plain_mod ../x.sh check
    hostile_ci "an absolute check file"            "$DEFAULT_PHP" src plain_mod /abs/x.sh check
    hostile_ci "a check file with //"              "$DEFAULT_PHP" src plain_mod a//b.sh check
    hostile_ci "a check file that is not .sh or .php" "$DEFAULT_PHP" src plain_mod x.txt check
    hostile_ci "a check file with a space"         "$DEFAULT_PHP" src plain_mod 'a b.sh' check
    hostile_ci "a check file with a command"       "$DEFAULT_PHP" src plain_mod '$(touch pwned).sh' check
    hostile_ci "a check script with a command"     "$DEFAULT_PHP" src plain_mod tests/check.sh 'check;id'
    check "hostile parameters wrote nothing" test "$(find "$SRV" | wc -l | tr -d ' ')" -eq "$before"
    check "no stray file was created by an injected command" test -z "$(find "$SRV" -name pwned)" -a ! -e "$WORK/pwned" -a ! -e "$PWD/pwned"
fi

# ---- examples/module/plain_module: the example module without Composer, through the same script of the server ------------------------
echo "--- examples/module/plain_module"
if [ ! -s "$WORK/ci-remote.sh" ]; then
    bad "no server script was captured from ci-local.sh: plain_module cannot be run"
elif [ -d "$TEMPLATE_DIR/examples/module/plain_module" ]; then
    rm -rf "$SRV/repo/src/plain_module"
    cp -R "$TEMPLATE_DIR/examples/module/plain_module" "$SRV/repo/src/plain_module"
    remote_ci "$DEFAULT_PHP" src plain_module tests/check.sh check
    check "plain_module: the job of the matrix succeeds, with the fake php" test "$RSTATUS" -eq 0
    check "plain_module: composer is not called" test ! -s "$COMPOSER_LOG"
    check "plain_module: php -l on its five PHP files" \
        sh -c "[ \"\$(grep -c '^-l ' '$PHP_LOG')\" -eq 5 ] && grep -qxF -- '-l ./plain_module.php' '$PHP_LOG' && grep -qxF -- '-l ./src/Greeting.php' '$PHP_LOG' && grep -qxF -- '-l ./tests/unit.php' '$PHP_LOG' && grep -qxF -- '-l ./tests/TestInstance.php' '$PHP_LOG' && grep -qxF -- '-l ./tests/integration.php' '$PHP_LOG'"
    check "plain_module: tests/check.sh ran, and it called php tests/unit.php (a line without -l)" grep -qxF 'tests/unit.php' "$PHP_LOG"
    if command -v php > /dev/null 2>&1; then
        # the real PHP of this machine, no fake in the PATH, and no Composer needed: the road is php -l and tests/check.sh
        PATH="$PATH" STACK_SERVER_ROOT="$SRV" bash "$WORK/ci-remote.sh" "$DEFAULT_PHP" src plain_module tests/check.sh check > "$WORK/rout" 2>&1 < /dev/null
        RSTATUS=$?
        check "plain_module: with the real php of this machine the job succeeds and its unit tests pass" \
            sh -c "[ $RSTATUS -eq 0 ] && grep -qF 'plain_module unit tests: 3 passed, 0 failed' '$WORK/rout' && grep -qF 'syntax check: 5 PHP file(s), no error' '$WORK/rout'"
        # outside the tools container the integration script skips itself and exits 0, whatever the variables of this machine say
        PERFEX_URL="" PERFEX_APP_PATH="" PERFEX_DB_HOST="" PERFEX_DB_NAME="" PERFEX_DB_USER="" PERFEX_DB_PASSWORD="" php "$SRV/repo/src/plain_module/tests/integration.php" > "$WORK/rout" 2>&1 < /dev/null
        RSTATUS=$?
        check "plain_module: tests/integration.php skips itself and exits 0 when the variables of the stack are not set" \
            sh -c "[ $RSTATUS -eq 0 ] && grep -q '^skipped: not in the tools container' '$WORK/rout'"
    else
        echo "skipped: no php on this machine (the real run of plain_module and of its integration script)"
    fi
else
    echo "skipped: no examples/module/plain_module/ in the template (STACK_TEMPLATE_DIR, or TEMPLATE_REL of stack.conf)"
fi

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

echo "--- examples/extra/bench.sh"
if [ -f "$WORK/docker/extra/bench.sh" ]; then
    BEN=extra/bench.sh
    CURLDIR="$WORK/curl-times"
    mk_curl_times() { # mk_curl_times [<timing header>]: the answers of the fake curl: calls 1-10 are the warm-up (9.999 s, which must not count),
                      # calls 11-20 the timed ones: nine of 0.010 s and, for the 5th of them (call 15), 0.100 s; with a header, each answer has it (4.00 ms)
        local k t
        rm -rf "$CURLDIR"; mkdir -p "$CURLDIR"
        for k in 1 2 3 4 5 6 7 8 9 10; do printf '%s' "9.999" > "$CURLDIR/$k"; done
        for k in 11 12 13 14 15 16 17 18 19 20; do
            t="0.010"; [ "$k" -ne 15 ] || t="0.100"
            if [ -n "${1:-}" ]; then printf 'HTTP/1.1 200 OK\r\nServer: x\r\n%s: 4.00\r\n\r\n%s' "$1" "$t" > "$CURLDIR/$k"; else printf '%s' "$t" > "$CURLDIR/$k"; fi
        done
    }
    refused "no argument"                                    "$BEN"
    refused "a path without a leading /"                     "$BEN" admin
    refused "a path with a space"                            "$BEN" '/a b'
    refused "a path with a command"                          "$BEN" '/a$(id)'
    refused "a path with a semicolon"                        "$BEN" '/a;id'
    refused "a path with a backtick"                         "$BEN" '/a`id`'
    refused "a path with a backslash"                        "$BEN" '/a\b'
    refused "a path with a quote"                            "$BEN" "/a'b"
    refused "a path with a newline"                          "$BEN" "$(printf '/a\nb')"
    refused "a number of requests in exponent form"          "$BEN" /x 1e3
    refused "0 requests"                                     "$BEN" /x 0
    refused "10000 requests"                                 "$BEN" /x 10000
    refused "a negative number of requests"                  "$BEN" /x -5
    refused "an empty number of requests"                    "$BEN" /x ''
    refused "a timing header with a colon"                   "$BEN" /x 10 'X-A:b'
    refused "a timing header with a space"                   "$BEN" /x 10 'X A'
    refused "a timing header with a command"                 "$BEN" /x 10 'X-A;id'
    refused "a timing header with an underscore"             "$BEN" /x 10 X_Timing
    refused "four arguments"                                 "$BEN" /x 10 X-A extra

    rm -rf "$WORK/.tmp/bench"; mk_curl_times ""
    STACK_TEST_CURL_DIR="$CURLDIR" sh_run "$BEN" '/admin/login?x=1&y=2' 10
    if [ "$STATUS" -eq 0 ] && [ "$(grep -c '^curl ' "$CALLS" | tr -d ' ')" -eq 20 ] && [ "$(wc -l < "$CALLS" | tr -d ' ')" -eq 20 ] \
        && [ "$(sed -n 1p "$CALLS")" = "curl [-s] [-o] [/dev/null] [-w] [%{time_total}] [--max-time] [30] [$APP_URL/admin/login?x=1&y=2]" ] && ! called "[-D]"; then
        good "bench.sh: ten warm-up and ten timed requests, each a GET of APP_URL + the path with no other option"
    else
        bad "bench.sh: the curl calls are not as expected (status $STATUS): $(cat "$WORK/out") / $(head -n 3 "$CALLS")"
    fi
    if grep -Eq '^total +10\.00 +100\.00 +100\.00$' "$WORK/out"; then
        good "bench.sh: nine times of 10 ms and one of 100 ms give p50 = 10.00 and p99 = 100.00 (the warm-up is not counted)"
    else
        bad "bench.sh: the percentiles are wrong: $(cat "$WORK/out")"
    fi
    report="$(ls "$WORK/.tmp/bench"/*.txt 2>/dev/null | head -n 1)"
    if [ -n "$report" ] && grep -Eq '^total +10\.00 +100\.00 +100\.00$' "$report" && grep -q "^bench: GET $APP_URL/admin/login" "$report" && [ -z "$(ls "$WORK/.tmp/bench"/*.raw 2>/dev/null)" ]; then
        good "bench.sh: the report is kept in .tmp/bench/<date>-<time>.txt and the raw answers are removed"
    else
        bad "bench.sh: no report in .tmp/bench/ (or a raw file was left): $(ls "$WORK/.tmp/bench" 2>&1)"
    fi

    mk_curl_times X-Timing
    STACK_TEST_CURL_DIR="$CURLDIR" sh_run "$BEN" /api/ping 10 X-Timing
    if [ "$STATUS" -eq 0 ] && called "[-s] [-o] [/dev/null] [-D] [-] [-w] [%{time_total}]" \
        && grep -Eq '^total +10\.00 +100\.00 +100\.00$' "$WORK/out" && grep -Eq '^X-Timing +4\.00 +4\.00 +4\.00$' "$WORK/out" \
        && grep -Eq '^total - X-Timing +6\.00 +96\.00 +96\.00$' "$WORK/out"; then
        good "bench.sh: with a timing header it reports the header (4.00 ms) and the difference (6.00 ms, 96.00 ms for the slow one)"
    else
        bad "bench.sh: the timing header was not read (status $STATUS): $(cat "$WORK/out")"
    fi
    mk_curl_times X-Other
    STACK_TEST_CURL_DIR="$CURLDIR" sh_run "$BEN" /api/ping 10 X-Timing
    if [ "$STATUS" -eq 1 ] && grep -q 'no response carried this header' "$WORK/out"; then good "bench.sh: a header that no response carries is an error (1)"; else bad "bench.sh: a missing header was not an error (status $STATUS): $(cat "$WORK/out")"; fi

    mk_curl_times ""
    STACK_TEST_CURL_STATUS=7 STACK_TEST_CURL_DIR="$CURLDIR" sh_run "$BEN" /x 10
    if [ "$STATUS" -ne 0 ] && [ "$(grep -c '^curl ' "$CALLS" | tr -d ' ')" -eq 1 ] && grep -q 'warm-up request failed (curl exit 7)' "$WORK/out"; then
        good "bench.sh: a curl that fails stops the script at once, naming the exit status"
    else
        bad "bench.sh: a failing curl was not reported (status $STATUS): $(cat "$WORK/out")"
    fi
    STACK_TEST_CURL_OUT=0.005 sh_run "$BEN" /
    if [ "$STATUS" -eq 0 ] && [ "$(grep -c '^curl ' "$CALLS" | tr -d ' ')" -eq 110 ] && grep -Eq '^requests: 100 timed, after 10 warm-up' "$WORK/out" && grep -Eq '^total +5\.00 +5\.00 +5\.00$' "$WORK/out"; then
        good "bench.sh: without a number it times 100 requests after 10 warm-up requests"
    else
        bad "bench.sh: the default of 100 requests was not used (status $STATUS): $(head -n 5 "$WORK/out")"
    fi
    STACK_TEST_CURL_OUT=0.007 sh_run "$BEN" /x 1
    if [ "$STATUS" -eq 0 ] && grep -Eq '^total +7\.00 +7\.00 +7\.00$' "$WORK/out"; then good "bench.sh: a single request gives the same value for every percentile"; else bad "bench.sh: one request misbehaved (status $STATUS): $(cat "$WORK/out")"; fi
else
    echo "skipped: no bench.sh in the examples/extra/ of the template (STACK_TEMPLATE_DIR, or TEMPLATE_REL of stack.conf)"
fi

echo "--- examples/extra/e2e.sh"
if [ -f "$WORK/docker/extra/e2e.sh" ]; then
    E2E=extra/e2e.sh
    mkdir -p "$WORK/tests/e2e/mysuite" "$WORK/tests/e2e/nocfg"; : > "$WORK/tests/e2e/mysuite/playwright.config.ts"
    refused "no argument"                                    "$E2E"
    refused "a folder with .."                               "$E2E" ../tests/e2e/mysuite
    refused "a folder with .. inside"                        "$E2E" tests/../tests/e2e/mysuite
    refused "an absolute folder"                             "$E2E" "$WORK/tests/e2e/mysuite"
    refused "a folder with a command"                        "$E2E" 'tests/e2e/mysuite;id'
    refused "a folder without playwright.config.ts"          "$E2E" tests/e2e/nocfg
    refused "a folder that does not exist"                   "$E2E" tests/e2e/ghost
    refused "an argument with a space"                       "$E2E" tests/e2e/mysuite '--grep=a b'
    refused "an argument with a semicolon"                   "$E2E" tests/e2e/mysuite '--grep=a;id'
    refused "an argument with a command substitution"        "$E2E" tests/e2e/mysuite '$(id)'
    refused "an argument with a backtick"                    "$E2E" tests/e2e/mysuite '`id`'
    refused "an argument with a quote"                       "$E2E" tests/e2e/mysuite "--grep='x'"
    refused "an argument with a pipe"                        "$E2E" tests/e2e/mysuite '--grep=a|b'
    refused "an empty argument"                              "$E2E" tests/e2e/mysuite ''
    STACK_SSH='-oProxyCommand=x' refused "an SSH alias that is an option" "$E2E" tests/e2e/mysuite

    sh_run "$E2E" tests/e2e/mysuite --grep=login specs/login.spec.ts
    expected_env="$(printf '%s\n' "MAILPIT_URL=$MAILPIT_URL" "PERFEX_URL=$APP_URL" "PLAYWRIGHT_OUTPUT_DIR=$WORK/.tmp/e2e/mysuite" "STACK_SSH=$SSH_ALIAS")"
    if [ "$STATUS" -eq 0 ] && [ "$(wc -l < "$CALLS" | tr -d ' ')" -eq 1 ] \
        && [ "$(cat "$CALLS")" = "npx [playwright] [test] [--config] [playwright.config.ts] [--grep=login] [specs/login.spec.ts]" ]; then
        good "e2e.sh: it runs npx playwright test --config playwright.config.ts with the arguments, and calls nothing else"
    else
        bad "e2e.sh: the npx call is not as expected (status $STATUS): $(cat "$CALLS") / $(cat "$WORK/out")"
    fi
    if [ "$(cat "$CALLS".env.1 2>/dev/null)" = "$expected_env" ] && [ "$(cat "$CALLS".pwd.1 2>/dev/null)" = "$WORK/tests/e2e/mysuite" ] && [ -d "$WORK/.tmp/e2e/mysuite" ]; then
        good "e2e.sh: in the suite's folder, with PERFEX_URL = APP_URL, STACK_SSH = the alias, MAILPIT_URL and an output folder under LOCAL_TMP_DIR"
    else
        bad "e2e.sh: the environment of playwright is not as expected: $(cat "$CALLS".env.1 2>&1) / folder $(cat "$CALLS".pwd.1 2>&1)"
    fi
    sh_run "$E2E" tests/e2e/mysuite
    if [ "$STATUS" -eq 0 ] && [ "$(cat "$CALLS")" = "npx [playwright] [test] [--config] [playwright.config.ts]" ]; then good "e2e.sh: with no further argument the call is the bare playwright test"; else bad "e2e.sh: the call without arguments is wrong (status $STATUS): $(cat "$CALLS")"; fi
    STACK_TEST_NPX_STATUS=3 sh_run "$E2E" tests/e2e/mysuite
    if [ "$STATUS" -eq 3 ]; then good "e2e.sh: the exit status is Playwright's (3)"; else bad "e2e.sh: Playwright's status was lost (status $STATUS)"; fi
    # no Mailpit in stack.conf: the variable is not passed, even if the caller has one in its environment
    cp "$WORK/docker/stack.conf" "$WORK/stack.conf.keep"
    sed -e 's#^MAILPIT_URL=.*#MAILPIT_URL=""#' "$WORK/stack.conf.keep" > "$WORK/docker/stack.conf"
    MAILPIT_URL=http://inherited.example sh_run "$E2E" tests/e2e/mysuite
    if [ "$STATUS" -eq 0 ] && ! grep -q '^MAILPIT_URL=' "$CALLS".env.1 && grep -q "^PERFEX_URL=$APP_URL\$" "$CALLS".env.1; then
        good "e2e.sh: without a Mailpit in stack.conf, MAILPIT_URL is not passed on (not even an inherited one)"
    else
        bad "e2e.sh: MAILPIT_URL was passed although stack.conf has none: $(cat "$CALLS".env.1 2>&1)"
    fi
    cp "$WORK/stack.conf.keep" "$WORK/docker/stack.conf"
else
    echo "skipped: no e2e.sh in the examples/extra/ of the template (STACK_TEMPLATE_DIR, or TEMPLATE_REL of stack.conf)"
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
if [ "$STATUS" -eq 2 ] && grep -q 'FAIL: cannot log in' "$WORK/out" && grep -q 'does not resolve from this machine' "$WORK/out"; then
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
# the notes on the instruction files of the AI agent: only when ai/ was rendered (INCLUDE_AI=1); never a failure
if [ -f "$DOCKER_DIR/ai/AGENTS-section.md" ]; then
    mkdir -p "$WORK/docker/ai"; cp "$DOCKER_DIR/ai/AGENTS-section.md" "$WORK/docker/ai/"
    rm -rf "$WORK/AGENTS.md" "$WORK/CLAUDE.md" "$WORK/.github"
    STACK_TEST_SSH_REPORT="$WORK/report" STACK_TEST_CURL_OUT=302 STACK_TEST_CURL_STATUS=0 sh_run doctor.sh
    if [ "$STATUS" -eq 2 ] && grep -q 'note: AGENTS.md is missing' "$WORK/out" && grep -q 'note: CLAUDE.md is missing' "$WORK/out"; then
        good "doctor.sh: a missing AGENTS.md and CLAUDE.md are two notes, not failures (the status stays 2)"
    else
        bad "doctor.sh: the notes on the missing instruction files misbehaved (status $STATUS): $(cat "$WORK/out")"
    fi
    printf '%s\n' '# my project' '<!-- perfex-crm-stack: test instance, begin -->' 'the rules' '<!-- perfex-crm-stack: test instance, end -->' > "$WORK/AGENTS.md"
    printf '%s\n' '@AGENTS.md' > "$WORK/CLAUDE.md"
    STACK_TEST_SSH_REPORT="$WORK/report" STACK_TEST_CURL_OUT=302 STACK_TEST_CURL_STATUS=0 sh_run doctor.sh
    if [ "$STATUS" -eq 2 ] && grep -q 'ok: AGENTS.md holds the test-instance section' "$WORK/out" && grep -q 'ok: CLAUDE.md imports AGENTS.md' "$WORK/out"; then
        good "doctor.sh: AGENTS.md with the section and CLAUDE.md with @AGENTS.md are both ok"
    else
        bad "doctor.sh: the ok path of the instruction files misbehaved (status $STATUS): $(cat "$WORK/out")"
    fi
    printf '%s\n' '# my project' 'no section here' > "$WORK/CLAUDE.md"
    mkdir -p "$WORK/.github"; printf '%s\n' 'chat rules' > "$WORK/.github/copilot-instructions.md"
    STACK_TEST_SSH_REPORT="$WORK/report" STACK_TEST_CURL_OUT=302 STACK_TEST_CURL_STATUS=0 sh_run doctor.sh
    if [ "$STATUS" -eq 2 ] && grep -q 'note: CLAUDE.md has no test-instance section' "$WORK/out" && grep -q 'note: .github/copilot-instructions.md exists without' "$WORK/out"; then
        good "doctor.sh: a CLAUDE.md without the section and a copilot-instructions.md without it are notes"
    else
        bad "doctor.sh: the note path of the instruction files misbehaved (status $STATUS): $(cat "$WORK/out")"
    fi
    rm -rf "$WORK/AGENTS.md" "$WORK/CLAUDE.md" "$WORK/.github"
else
    echo "skipped: no ai/AGENTS-section.md in this folder (INCLUDE_AI=0): the notes of doctor.sh on the instruction files are not tested"
fi

[ "$fail" -eq 0 ] && echo "=== scripts-test: all ok ===" || echo "=== scripts-test: FAILED ==="
exit "$fail"
