#!/usr/bin/env bash
# Tests deploy.sh without touching any server, in two parts.
#
# Part 1, the Mac side, with a fake ssh and a fake rsync that only record their calls: module, target and SSH alias must
# come from closed lists or strict patterns, every refusal must happen BEFORE any call is made, and a valid deploy must
# pass the values to the server as positional parameters (never pasted into the script text). Both ways of choosing the
# modules are tried: a closed DEPLOY_MODULES list, and discovery of <name>/<name>.php folders.
#
# Part 2, the server side: the script that deploy.sh sends to the server is taken from the recorded call and run here
# against a folder tree standing in for the server (STACK_SERVER_ROOT), with the real rsync and a fake composer. It checks
# the .stack-managed marker (a folder the stack did not create is refused, --adopt takes it over, a symbolic link is
# never touched), the copy (excludes, --delete, dot-folders removed, vendor/.htaccess, the development marker) and
# that hostile parameters are refused again on the server.
#
# Usage: bash <this folder>/tests/deploy-test.sh      (exit status 1 at the first failure)
# Files go to <project root>/<LOCAL_TMP_DIR>/stack-tests/deploy-test (or STACK_TESTS_WORK/deploy-test).
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
DOCKER_DIR="$(cd "$HERE/.." && pwd -P)"
# shellcheck source=../stack.conf
. "$DOCKER_DIR/stack.conf"
ROOT="$(cd "$DOCKER_DIR/$PROJECT_ROOT_REL" && pwd -P)"
WORK="${STACK_TESTS_WORK:-$ROOT/$LOCAL_TMP_DIR/stack-tests}/deploy-test"

rm -rf "$WORK"
mkdir -p "$WORK/bin" "$WORK/fakebin" "$WORK/docker" "$WORK/src" "$WORK/server"
cp "$DOCKER_DIR/deploy.sh" "$DOCKER_DIR/sync.sh" "$DOCKER_DIR/lib.sh" "$DOCKER_DIR/locked.sh" "$WORK/docker/"

write_conf() { # write_conf <value of DEPLOY_MODULES> [<value of DEPLOY_EXTRA>]: the stack.conf of the test, pointing at the work folder
    sed -e 's#^PROJECT_ROOT_REL=.*#PROJECT_ROOT_REL=".."#' \
        -e 's#^SYNC_DIR=.*#SYNC_DIR="src"#' \
        -e "s#^DEPLOY_MODULES=.*#DEPLOY_MODULES=\"$1\"#" \
        -e "s#^DEPLOY_EXTRA=.*#DEPLOY_EXTRA=\"${2-}\"#" \
        -e 's#^MODULES_DIR=.*#MODULES_DIR="modules"#' \
        -e 's#^APP_TARGETS=.*#APP_TARGETS="app app-extra"#' \
        -e 's#^DEV_MARKER=.*#DEV_MARKER=""#' \
        "$DOCKER_DIR/stack.conf" > "$WORK/docker/stack.conf"
    # shellcheck disable=SC1091
    . "$WORK/docker/stack.conf"
}
DEPLOY="$WORK/docker/deploy.sh"
CALLS="$WORK/calls"; STDIN="$WORK/stdin"

# the fake ssh and rsync: record every call, keep the standard input of each call in stdin.<n>
for tool in ssh rsync; do
    cat > "$WORK/bin/$tool" <<'FAKE'
#!/usr/bin/env bash
n=$(( $(wc -l < "$STACK_TEST_CALLS") + 1 ))
printf '%s' "$(basename "$0")" >> "$STACK_TEST_CALLS"
for a in "$@"; do printf ' [%s]' "$a" >> "$STACK_TEST_CALLS"; done
printf '\n' >> "$STACK_TEST_CALLS"
cat > "$STACK_TEST_STDIN.$n"
FAKE
    chmod +x "$WORK/bin/$tool"
done

fail=0
bad() { echo "FAIL: $*"; fail=1; }
good() { echo "ok: $*"; }

run() { # run <ssh alias> <deploy.sh arguments...>: sets STATUS, the calls are in $CALLS
    local alias="$1"; shift
    : > "$CALLS"; rm -f "$STDIN".*
    PATH="$WORK/bin:$PATH" STACK_SSH="$alias" STACK_TEST_CALLS="$CALLS" STACK_TEST_STDIN="$STDIN" bash "$DEPLOY" "$@" > "$WORK/out" 2>&1 < /dev/null
    STATUS=$?
}
expect_refused() { # expect_refused <label> <ssh alias> <deploy.sh arguments...>
    local label="$1"; shift
    run "$@"
    if [ "$STATUS" -eq 0 ] || [ -s "$CALLS" ]; then bad "$label was not refused (status $STATUS, calls: $(cat "$CALLS"))"; else good "$label refused, no call made"; fi
}

# ---- Part 1a: a closed list of modules ---------------------------------------------------------------------------------------
write_conf "alpha_mod beta_mod delta_mod linked_mod"
mkdir -p "$WORK/src/alpha_mod" "$WORK/src/beta_mod" "$WORK/src/gamma_mod"
: > "$WORK/src/alpha_mod/alpha_mod.php"; : > "$WORK/src/gamma_mod/gamma_mod.php"
ln -s alpha_mod "$WORK/src/linked_mod"      # in the list, but a symbolic link
# beta_mod: in the list, folder without its init file; delta_mod: in the list, no folder; gamma_mod: valid, not in the list

echo "--- part 1: the Mac side"
expect_refused "module with a command"            "$SSH_ALIAS" "alpha_mod; touch pwned"
expect_refused "module with a path"               "$SSH_ALIAS" "../alpha_mod"
expect_refused "module with a space"              "$SSH_ALIAS" "alpha_mod -v"
expect_refused "unknown module"                   "$SSH_ALIAS" "no_such_mod"
expect_refused "module in capitals"               "$SSH_ALIAS" "ALPHA_MOD"
expect_refused "empty module"                     "$SSH_ALIAS" ''
expect_refused "valid name that is not in the list" "$SSH_ALIAS" gamma_mod
expect_refused "module without its init file"     "$SSH_ALIAS" beta_mod
expect_refused "module without a folder"          "$SSH_ALIAS" delta_mod
expect_refused "module that is a symbolic link"   "$SSH_ALIAS" linked_mod
expect_refused "target with a command"            "$SSH_ALIAS" alpha_mod "app; id"
expect_refused "target that is not allowed"       "$SSH_ALIAS" alpha_mod elsewhere
expect_refused "SSH alias that is an option"      '-oProxyCommand=touch_pwned' alpha_mod
expect_refused "SSH alias with a space"           "$SSH_ALIAS -v" alpha_mod
expect_refused "SSH alias with a command"         "$SSH_ALIAS;id" alpha_mod
expect_refused "unknown option"                   "$SSH_ALIAS" --bogus alpha_mod
expect_refused "too many arguments"               "$SSH_ALIAS" alpha_mod app app-extra
expect_refused "--adopt without a module"         "$SSH_ALIAS" --adopt

# the arguments exactly as deploy.sh must pass them to the server
expected_remote() { # expected_remote <module> <target> <adopt> [<source folder, relative to SYNC_DIR; default: the module>]
    local inner
    inner="$(printf '%q %q %q %q %q %q %q %q %q' "$1" "$2" "$DEPLOY_PHP" "$SYNC_DIR" "$MODULES_DIR" "$DEV_MARKER" "$3" "$DEPLOY_EXCLUDES" "${4:-$1}")"
    echo "ssh [$SSH_ALIAS] [bash $(printf '%q' "$LOCKED_SH") $(printf '%q' "bash -s -- $inner")]"
}
# check_valid takes the source folder the server must be told from SRC_REL_EXPECTED (default: the module's own name)
check_valid() { # check_valid <label> <module> <target> <adopt> <deploy.sh arguments...>
    local label="$1" mod="$2" target="$3" adopt="$4" f n=0 script="" src_rel="${SRC_REL_EXPECTED:-$2}"
    shift 4
    run "$SSH_ALIAS" "$@"
    if [ "$STATUS" -ne 0 ]; then bad "$label: a valid deploy failed: $(cat "$WORK/out")"; return; fi
    if ! grep -qF "$(expected_remote "$mod" "$target" "$adopt" "$src_rel")" "$CALLS"; then bad "$label: unexpected remote call: $(cat "$CALLS")"; return; fi
    if ! grep -qF "ssh [$SSH_ALIAS] [mkdir -p /repo/$SYNC_DIR $(dirname "$LOCKED_SH")]" "$CALLS"; then bad "$label: the folders are not made before the copy: $(cat "$CALLS")"; return; fi
    if ! grep -qF "rsync [-az] [--delete] [-e] [ssh]" "$CALLS" || ! grep -qF "[$SSH_ALIAS:/repo/$SYNC_DIR/]" "$CALLS" || ! grep -qF "[$SSH_ALIAS:$LOCKED_SH]" "$CALLS"; then
        bad "$label: the code folder and locked.sh are not both synchronised: $(cat "$CALLS")"; return
    fi
    for f in "$STDIN".*; do [ -s "$f" ] && { script="$f"; n=$((n + 1)); }; done
    if [ "$n" -ne 1 ]; then bad "$label: expected exactly one script on the standard input of ssh, found $n"; return; fi
    if ! grep -q '^mod="\$1"' "$script"; then bad "$label: the script does not read the module from its parameters"; return; fi
    if grep -qF "$mod" "$script" || grep -qF "$src_rel" "$script"; then bad "$label: the module name or its folder is pasted into the script text, not passed as a parameter"; return; fi
    good "$label: values go to the server as parameters, the script text has none of them"
    cp "$script" "$WORK/remote.sh"
}
check_valid "valid deploy"            alpha_mod app 0 alpha_mod app
check_valid "valid deploy, default target" alpha_mod app 0 alpha_mod
check_valid "valid deploy, second target"  alpha_mod app-extra 0 alpha_mod app-extra
check_valid "valid deploy with --adopt"    alpha_mod app 1 --adopt alpha_mod app

# ---- Part 1a, DEPLOY_EXTRA: modules that live deeper than <SYNC_DIR>/<name>/ ------------------------------------------------------
echo "--- part 1, DEPLOY_EXTRA"
EXTRA_OK="alpha_mod/examples/alpha_notes:alpha_notes"
write_conf "alpha_mod beta_mod delta_mod linked_mod" "$EXTRA_OK alpha_mod/examples/nofile_notes:nofile_notes alpha_mod/examples/ghost_notes:ghost_notes alpha_mod/viasym/via_notes:via_notes"
mkdir -p "$WORK/src/alpha_mod/examples/alpha_notes" "$WORK/src/alpha_mod/examples/nofile_notes" "$WORK/src/alpha_mod/examples/via_notes"
: > "$WORK/src/alpha_mod/examples/alpha_notes/alpha_notes.php"; : > "$WORK/src/alpha_mod/examples/via_notes/via_notes.php"
ln -s examples "$WORK/src/alpha_mod/viasym"          # via_notes is reachable through a symbolic link in the middle of its path
# nofile_notes: a folder without its init file; ghost_notes: no folder at all; via_notes: a symbolic link on the way
SRC_REL_EXPECTED="alpha_mod/examples/alpha_notes" check_valid "valid deploy of an extra"            alpha_notes app 0 alpha_notes app
SRC_REL_EXPECTED="alpha_mod/examples/alpha_notes" check_valid "valid deploy of an extra, default target" alpha_notes app 0 alpha_notes
SRC_REL_EXPECTED="alpha_mod/examples/alpha_notes" check_valid "valid deploy of an extra, second target"  alpha_notes app-extra 0 alpha_notes app-extra
SRC_REL_EXPECTED="alpha_mod/examples/alpha_notes" check_valid "valid deploy of an extra with --adopt"    alpha_notes app 1 --adopt alpha_notes
check_valid "a plain module still sends its own name as the source folder" alpha_mod app 0 alpha_mod
expect_refused "an extra without its init file"               "$SSH_ALIAS" nofile_notes
expect_refused "an extra without a folder"                    "$SSH_ALIAS" ghost_notes
expect_refused "an extra behind a symbolic link in its path"  "$SSH_ALIAS" via_notes
expect_refused "a name that is in neither list"               "$SSH_ALIAS" no_such_notes
expect_refused "the source folder given instead of the name"  "$SSH_ALIAS" alpha_mod/examples/alpha_notes
expect_refused "an extra name with a command"                 "$SSH_ALIAS" 'alpha_notes;id'
expect_refused "an extra on a target that is not allowed"     "$SSH_ALIAS" alpha_notes elsewhere
# stack.conf is not trusted either: a source folder that render.sh would never write is refused here, before any call. The folders
# exist and hold the init file, so that only the check of the path can refuse them.
for hostile_dir in x abs/x alpha_mod/a..b/x "alpha_mod/ex;id" alpha_mod/x alpha_mod/examples/alpha_notes .hidden/x; do
    mkdir -p "$WORK/src/$hostile_dir"; : > "$WORK/src/$hostile_dir/evil_notes.php"
done
for conf_extra in "alpha_mod/../x:evil_notes" "/abs/x:evil_notes" "alpha_mod/a..b/x:evil_notes" "alpha_mod/ex;id:evil_notes" "alpha_mod//x:evil_notes" "alpha_mod/examples/alpha_notes/:evil_notes" ".hidden/x:evil_notes"; do
    write_conf "alpha_mod" "$conf_extra"
    expect_refused "an extra with the source folder \"$conf_extra\" in stack.conf" "$SSH_ALIAS" evil_notes
done
write_conf "alpha_mod" "alpha_mod/examples/alpha_notes"
expect_refused "a DEPLOY_EXTRA word without a colon names nothing" "$SSH_ALIAS" alpha_mod/examples/alpha_notes
expect_refused "a DEPLOY_EXTRA word without a colon does not allow its last part" "$SSH_ALIAS" alpha_notes
write_conf "alpha_mod" "alpha_mod/examples/alpha_notes:alpha_mod"
expect_refused "a name in DEPLOY_MODULES and in DEPLOY_EXTRA is ambiguous" "$SSH_ALIAS" alpha_mod
grep -q 'ambiguous' "$WORK/out" && good "the refusal says why: ambiguous" || bad "the refusal of an ambiguous name does not say so: $(cat "$WORK/out")"
write_conf "alpha_mod beta_mod delta_mod linked_mod"

# ---- Part 1b: discovery (DEPLOY_MODULES empty) ------------------------------------------------------------------------------------
write_conf ""
rm -rf "$WORK/src"; mkdir -p "$WORK/src/found_mod" "$WORK/src/Bad-Name" "$WORK/src/noinit_mod"
: > "$WORK/src/found_mod/found_mod.php"; : > "$WORK/src/Bad-Name/Bad-Name.php"
ln -s found_mod "$WORK/src/link_mod"
echo "--- part 1, discovery"
expect_refused "discovery: folder with an invalid name"  "$SSH_ALIAS" Bad-Name
expect_refused "discovery: folder without init file"     "$SSH_ALIAS" noinit_mod
expect_refused "discovery: symbolic link"                "$SSH_ALIAS" link_mod
expect_refused "discovery: nothing of that name"         "$SSH_ALIAS" zz_unknown
expect_refused "discovery: command in the name"          "$SSH_ALIAS" 'found_mod;id'
# an extra whose name is also a folder found on disk: render.sh cannot see that, deploy.sh refuses
mkdir -p "$WORK/src/found_mod/examples/found_notes"; : > "$WORK/src/found_mod/examples/found_notes/found_mod.php"; : > "$WORK/src/found_mod/examples/found_notes/found_notes.php"
write_conf "" "found_mod/examples/found_notes:found_mod"
expect_refused "discovery: an extra with the name of a module found on disk is ambiguous" "$SSH_ALIAS" found_mod
write_conf "" "found_mod/examples/found_notes:found_notes"
SRC_REL_EXPECTED="found_mod/examples/found_notes" check_valid "discovery: an extra next to the modules found on disk" found_notes app 0 found_notes
check_valid "discovery: the module found on disk is still deployed as itself" found_mod app 0 found_mod
write_conf ""
check_valid "discovery: a module found on disk" found_mod app 0 found_mod

# ---- Part 2: the script that runs on the server -----------------------------------------------------------------------------------
echo "--- part 2: the server side, against a folder tree"
[ -s "$WORK/remote.sh" ] || { bad "no server script was captured"; exit 1; }
REMOTE="$WORK/remote.sh"
SRV="$WORK/server"
cat > "$WORK/fakebin/composer" <<'FAKE'
#!/usr/bin/env bash
# fake composer: records the call, makes a vendor folder when installing
echo "$*" >> "$STACK_TEST_COMPOSER_LOG"
case " $* " in
    *" install "*) mkdir -p vendor/pkg; echo '<?php' > vendor/autoload.php; echo '<?php' > vendor/pkg/Thing.php ;;
esac
FAKE
chmod +x "$WORK/fakebin/composer"
COMPOSER_LOG="$WORK/composer.log"

mkdir -p "$SRV/repo/src" "$SRV/app/modules" "$SRV/app-extra"
make_source() { # make_source <module>: a module in the server's copy of the repository
    local m="$1" d="$SRV/repo/src/$1"
    rm -rf "$d"; mkdir -p "$d/src" "$d/tests" "$d/.git" "$d/.hidden"
    echo '<?php' > "$d/$m.php"; echo '<?php' > "$d/src/Thing.php"; echo '<?php' > "$d/tests/ThingTest.php"
    echo x > "$d/.git/HEAD"; echo x > "$d/.hidden/file"; echo '{}' > "$d/composer.json"; echo x > "$d/phpunit.xml.dist"
}
remote() { # remote <module> <target> <adopt> [<dev marker> [<modules dir> [<sync dir> [<excludes> [<source folder>]]]]]; sets RSTATUS
    local excludes="$DEPLOY_EXCLUDES"
    [ $# -ge 7 ] && excludes="$7"
    : > "$COMPOSER_LOG"
    PATH="$WORK/fakebin:$PATH" STACK_SERVER_ROOT="$SRV" STACK_TEST_COMPOSER_LOG="$COMPOSER_LOG" \
        bash "$REMOTE" "$1" "$2" "$DEPLOY_PHP" "${6-src}" "${5-modules}" "${4-}" "$3" "$excludes" "${8-$1}" > "$WORK/rout" 2>&1 < /dev/null
    RSTATUS=$?
}
check() { # check <label> <command...>: passes when the command succeeds
    local label="$1"; shift
    if "$@"; then good "$label"; else bad "$label"; fi
}
absent() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
M="$SRV/app/modules"

# a. first deploy: no folder yet
make_source alpha_mod
remote alpha_mod app 0
check "first deploy succeeds ($(tail -n 1 "$WORK/rout"))" test "$RSTATUS" -eq 0
check "first deploy: the module files are copied"           test -f "$M/alpha_mod/alpha_mod.php" -a -f "$M/alpha_mod/src/Thing.php"
check "first deploy: the marker .stack-managed is written"  test -f "$M/alpha_mod/.stack-managed"
check "first deploy: tests/ and phpunit files are left out" absent "$M/alpha_mod/tests"
check "first deploy: phpunit.xml.dist is left out"          absent "$M/alpha_mod/phpunit.xml.dist"
check "first deploy: dot-folders are left out"              test ! -e "$M/alpha_mod/.git" -a ! -e "$M/alpha_mod/.hidden"
check "first deploy: vendor/.htaccess denies the web"       grep -q '^Require all denied$' "$M/alpha_mod/vendor/.htaccess"
check "first deploy: composer ran twice, runtime then dev"  test "$(wc -l < "$COMPOSER_LOG" | tr -d ' ')" -eq 2
check "first deploy: the first install had --no-dev"        sh -c "head -n 1 '$COMPOSER_LOG' | grep -q -- '--no-dev'"
check "first deploy: the second install had no --no-dev"    sh -c "! tail -n 1 '$COMPOSER_LOG' | grep -q -- '--no-dev'"

# b. redeploy: stale files and dot-folders go, the marker stays
echo stale > "$M/alpha_mod/stale.txt"; mkdir -p "$M/alpha_mod/.leftover/sub"; echo x > "$M/alpha_mod/.leftover/sub/f"
rm -f "$SRV/repo/src/alpha_mod/src/Thing.php"; echo '<?php' > "$SRV/repo/src/alpha_mod/src/Other.php"
remote alpha_mod app 0 .dev-mode
check "redeploy succeeds" test "$RSTATUS" -eq 0
check "redeploy: a file removed from the source is removed"  absent "$M/alpha_mod/src/Thing.php"
check "redeploy: a new file arrives"                          test -f "$M/alpha_mod/src/Other.php"
check "redeploy: a stale file is deleted"                     absent "$M/alpha_mod/stale.txt"
check "redeploy: a dot-folder left behind is removed"         absent "$M/alpha_mod/.leftover"
check "redeploy: the marker is still there"                   test -f "$M/alpha_mod/.stack-managed"
check "redeploy: the development marker is created"           test -f "$M/alpha_mod/.dev-mode"

# c. a folder this stack did not create is refused, untouched
make_source core_mod
mkdir -p "$M/core_mod"; echo mine > "$M/core_mod/core.php"
remote core_mod app 0
check "a folder without the marker is refused (exit 3)"       test "$RSTATUS" -eq 3
check "the refusal names --adopt"                              grep -q -- '--adopt' "$WORK/rout"
check "the refused folder is untouched"                        test -f "$M/core_mod/core.php" -a ! -e "$M/core_mod/core_mod.php" -a ! -e "$M/core_mod/.stack-managed"
check "nothing ran before the refusal (no composer call)"     test ! -s "$COMPOSER_LOG"

# d. --adopt takes it over
remote core_mod app 1
check "--adopt takes the folder over"                          test "$RSTATUS" -eq 0
check "--adopt: the marker is written and the module copied"  test -f "$M/core_mod/.stack-managed" -a -f "$M/core_mod/core_mod.php"
check "--adopt: what was there is replaced (rsync --delete)"  absent "$M/core_mod/core.php"

# e. a symbolic link is never followed
make_source link_mod
mkdir -p "$WORK/elsewhere"; echo precious > "$WORK/elsewhere/keep.txt"
ln -s "$WORK/elsewhere" "$M/link_mod"
remote link_mod app 1
check "a symbolic link is refused, even with --adopt"         test "$RSTATUS" -ne 0
check "the target of the link is untouched"                   test "$(cat "$WORK/elsewhere/keep.txt")" = precious -a "$(ls -A "$WORK/elsewhere" | wc -l | tr -d ' ')" -eq 1
rm -f "$M/link_mod"

# f. the application is not installed (no modules folder) or the target is not mounted
make_source alpha_mod
remote alpha_mod app-extra 0
check "no modules folder: refused, and the folder is not created"  test "$RSTATUS" -ne 0 -a ! -e "$SRV/app-extra/modules"
remote alpha_mod nowhere 0
check "a target that is not mounted is refused"               test "$RSTATUS" -ne 0

# g. hostile parameters are refused again on the server, and nothing is written
before="$(find "$SRV" | wc -l | tr -d ' ')"
remote 'alpha_mod;touch pwned' app 0;  check "server refuses a module with a command"        test "$RSTATUS" -ne 0
remote '../alpha_mod' app 0;           check "server refuses a module with a path"           test "$RSTATUS" -ne 0
remote alpha_mod 'app;id' 0;           check "server refuses a target with a command"        test "$RSTATUS" -ne 0
remote alpha_mod app 2;                check "server refuses an adopt flag that is not 0 or 1" test "$RSTATUS" -ne 0
remote alpha_mod app 0 '' '../../etc'; check "server refuses a modules folder with .."       test "$RSTATUS" -ne 0
remote alpha_mod app 0 '' modules '/abs'; check "server refuses a sync folder that is absolute" test "$RSTATUS" -ne 0
remote alpha_mod app 0 .stack-managed; check "server refuses the managed marker as the development marker" test "$RSTATUS" -ne 0
remote alpha_mod app 0 '' modules src '/tests/;id'; check "server refuses an exclude with a command" test "$RSTATUS" -ne 0
check "hostile parameters wrote nothing" test "$(find "$SRV" | wc -l | tr -d ' ')" -eq "$before"
check "no stray file was created by an injected command" test ! -e "$WORK/server/pwned" -a ! -e "$PWD/pwned"

# h. a module that lives deeper than <sync dir>/<name>/ (DEPLOY_EXTRA): same marker, same excludes, same --adopt
make_nested() { # make_nested <source folder> <name>: a module inside another folder, in the server's copy of the repository
    local d="$SRV/repo/src/$1" m="$2"
    rm -rf "$d"; mkdir -p "$d/src" "$d/tests" "$d/.git"
    echo '<?php' > "$d/$m.php"; echo '<?php' > "$d/src/Nested.php"; echo '<?php' > "$d/tests/NestedTest.php"
    echo x > "$d/.git/HEAD"; echo '{}' > "$d/composer.json"
}
NESTED=alpha_mod/examples/alpha_notes
make_nested "$NESTED" alpha_notes
remote alpha_notes app 0 '' modules src "$DEPLOY_EXCLUDES" "$NESTED"
check "nested deploy succeeds ($(tail -n 1 "$WORK/rout"))"                    test "$RSTATUS" -eq 0
check "nested deploy: the files land in /app/modules/alpha_notes"             test -f "$M/alpha_notes/alpha_notes.php" -a -f "$M/alpha_notes/src/Nested.php"
check "nested deploy: the marker .stack-managed is written there"             test -f "$M/alpha_notes/.stack-managed"
check "nested deploy: tests/ and dot-folders are left out, as for a module"   test ! -e "$M/alpha_notes/tests" -a ! -e "$M/alpha_notes/.git"
check "nested deploy: the path to the source is not recreated in the application" test ! -e "$M/alpha_notes/examples" -a ! -e "$M/alpha_mod/examples/alpha_notes"
check "nested deploy: composer ran twice, in the module's folder"            test "$(wc -l < "$COMPOSER_LOG" | tr -d ' ')" -eq 2
check "nested deploy: vendor/.htaccess denies the web"                        grep -q '^Require all denied$' "$M/alpha_notes/vendor/.htaccess"
# the marker rules are the same: a folder the stack did not create is refused, --adopt takes it over
make_nested alpha_mod/examples/other_notes other_notes
mkdir -p "$M/other_notes"; echo mine > "$M/other_notes/core.php"
remote other_notes app 0 '' modules src "$DEPLOY_EXCLUDES" alpha_mod/examples/other_notes
check "nested deploy: a folder without the marker is refused (exit 3), untouched" test "$RSTATUS" -eq 3 -a -f "$M/other_notes/core.php" -a ! -e "$M/other_notes/other_notes.php"
remote other_notes app 1 '' modules src "$DEPLOY_EXCLUDES" alpha_mod/examples/other_notes
check "nested deploy: --adopt takes it over"                                  test "$RSTATUS" -eq 0 -a -f "$M/other_notes/.stack-managed" -a -f "$M/other_notes/other_notes.php" -a ! -e "$M/other_notes/core.php"
# a symbolic link in the middle of the path is refused on the server too, and nothing is written
ln -s alpha_mod/examples "$SRV/repo/src/viasym"
remote via_notes app 0 '' modules src "$DEPLOY_EXCLUDES" viasym/alpha_notes
check "nested deploy: a symbolic link on the way to the source is refused by the server" test "$RSTATUS" -ne 0 -a ! -e "$M/via_notes"
rm -f "$SRV/repo/src/viasym"
# i. a hostile source folder is refused again on the server, and nothing is written
before="$(find "$SRV" | wc -l | tr -d ' ')"
for bad_src in '..' '../alpha_mod' '/etc' 'alpha_mod;touch pwned' 'alpha_mod/../alpha_mod' 'alpha_mod//examples' 'alpha_mod/examples/' 'a..b' '' '$(touch pwned)' '.hidden'; do
    remote alpha_notes app 0 '' modules src "$DEPLOY_EXCLUDES" "$bad_src"
    check "server refuses the source folder \"$bad_src\"" test "$RSTATUS" -ne 0
done
check "hostile source folders wrote nothing" test "$(find "$SRV" | wc -l | tr -d ' ')" -eq "$before"
check "no stray file was created by an injected source folder" test ! -e "$WORK/server/pwned" -a ! -e "$PWD/pwned" -a ! -e "$SRV/repo/src/pwned"

[ "$fail" -eq 0 ] && echo "=== deploy-test: all ok ===" || echo "=== deploy-test: FAILED ==="
exit "$fail"
