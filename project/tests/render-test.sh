#!/usr/bin/env bash
# Tests render.sh, the script of the template that validates the parameters and writes the project folder.
# It lives in the template, not in this folder: stack.conf records where (TEMPLATE_REL, relative to the project root);
# STACK_TEMPLATE_DIR in the environment replaces that. The tests use the compiled example of the template
# (examples/params/example.env) and change one value at a time.
#
# Checks: the good parameters pass; every bad value is refused with a message that names the parameter (PHP versions,
# ".." in paths, module names, a lock file outside /repo, an SSH alias that looks like an option, ...); --check writes
# nothing; a folder that is not empty is refused without --force and only the generated files are replaced with it; the
# destination can never be inside the template; nothing in the environment can stand in for a missing parameter; the
# generated files have no placeholder left and every script passes `bash -n`; INCLUDE_AI=0 leaves out ai/.
#
# Usage: bash <this folder>/tests/render-test.sh      (exit status 1 at the first failure)
# Files go to <project root>/<LOCAL_TMP_DIR>/stack-tests/render-test (or STACK_TESTS_WORK/render-test).
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
DOCKER_DIR="$(cd "$HERE/.." && pwd -P)"
# shellcheck source=../stack.conf
. "$DOCKER_DIR/stack.conf"
ROOT="$(cd "$DOCKER_DIR/$PROJECT_ROOT_REL" && pwd -P)"
TEMPLATE_DIR="${STACK_TEMPLATE_DIR:-$ROOT/$TEMPLATE_REL}"
if [ ! -f "$TEMPLATE_DIR/render.sh" ]; then
    echo "the template was not found at $TEMPLATE_DIR (from TEMPLATE_REL in stack.conf): set STACK_TEMPLATE_DIR to its folder"
    exit 2
fi
TEMPLATE_DIR="$(cd "$TEMPLATE_DIR" && pwd -P)"
RENDER="$TEMPLATE_DIR/render.sh"
BASE="$TEMPLATE_DIR/examples/params/example.env"
[ -f "$BASE" ] || { echo "missing $BASE"; exit 2; }
WORK="${STACK_TESTS_WORK:-$ROOT/$LOCAL_TMP_DIR/stack-tests}/render-test"
rm -rf "$WORK"
mkdir -p "$WORK/p" "$WORK/emptycwd"

fail=0
bad() { echo "FAIL: $*"; fail=1; }
good() { echo "ok: $*"; }
mkparams() { # mkparams <name> [<line> ...]: the example parameters plus the given lines (the last assignment wins)
    local name="$1"; shift
    cp "$BASE" "$WORK/p/$name.env"
    if [ $# -gt 0 ]; then printf '%s\n' "$@" >> "$WORK/p/$name.env"; fi
}

# ---- 1. the good parameters ------------------------------------------------------------------------------------------------------
echo "--- parameters"
mkparams good
bash "$RENDER" --check "$WORK/p/good.env" > "$WORK/out" 2>&1; st=$?
if [ "$st" -eq 0 ] && grep -q 'parameters are valid' "$WORK/out"; then good "the example parameters are valid"; else bad "the example parameters were refused: $(cat "$WORK/out")"; fi

# ---- 2. bad values: refused, and the message names the parameter ------------------------------------------------------------------
n=0
while IFS='|' read -r token line; do
    [ -n "$token" ] || continue
    n=$((n + 1))
    mkparams "bad$n" "$line"
    bash "$RENDER" --check "$WORK/p/bad$n.env" > "$WORK/out" 2>&1; st=$?
    if [ "$st" -eq 0 ]; then bad "accepted: $line"
    elif ! grep -q "$token" "$WORK/out"; then bad "refused, but the message does not name $token: $line ($(head -n 1 "$WORK/out"))"
    else good "refused: $line"; fi
done <<'CASES'
WEB_PHP_VERSION|WEB_PHP_VERSION="8"
WEB_PHP_VERSION|WEB_PHP_VERSION="8.4.1"
WEB_PHP_VERSION|WEB_PHP_VERSION="7.4"
TOOLS_PHP_VERSIONS|TOOLS_PHP_VERSIONS="8.4 x"
TOOLS_PHP_VERSIONS|TOOLS_PHP_VERSIONS="7.4 8.4"
MATRIX_PHP_VERSIONS|MATRIX_PHP_VERSIONS="8.4 8.9"
MATRIX_PHP_VERSIONS|MATRIX_PHP_VERSIONS="8.4 latest"
DEFAULT_PHP|DEFAULT_PHP="8.0"
DEFAULT_PHP|DEFAULT_PHP="eight"
SYNC_DIR|SYNC_DIR="../outside"
SYNC_DIR|SYNC_DIR="a//b"
SYNC_DIR|SYNC_DIR=".tmp"
DEST_DIR|DEST_DIR="a/../b"
DEST_DIR|DEST_DIR="/abs/path"
DEST_DIR|DEST_DIR="tools/docker/"
LOCAL_TMP_DIR|LOCAL_TMP_DIR="../tmp"
STATIC_TOOLS_DIR|STATIC_TOOLS_DIR="tools/../x"
MODULES_DIR|MODULES_DIR="../x"
DEPLOY_MODULES|DEPLOY_MODULES="Good_One"
DEPLOY_MODULES|DEPLOY_MODULES="good_one;id"
DEPLOY_MODULES|DEPLOY_MODULES="x"
DEPLOY_MODULES|DEPLOY_MODULES="../etc"
CI_MODULES|CI_MODULES="Bad Name"
CI_MODULES|CI_MODULES='$(id)'
LOCK_FILE|LOCK_FILE="/etc/passwd"
LOCK_FILE|LOCK_FILE="/repo/../etc/lock"
SSH_ALIAS|SSH_ALIAS="-oProxyCommand=x"
SSH_ALIAS|SSH_ALIAS="my host"
REMOTE_ROOT|REMOTE_ROOT="relative/path"
REMOTE_ROOT|REMOTE_ROOT="/srv/../etc"
REMOTE_ROOT|REMOTE_ROOT="/srv/stack/"
TOOLS_MEM|TOOLS_MEM="lots"
TOOLS_CPUS|TOOLS_CPUS="two"
STACK_NAME|STACK_NAME="Bad Name"
APP_HOST|APP_HOST="bad host"
APP_URL|APP_URL="http://x y"
APP_URL|APP_URL='http://x/$(id)'
PASS_AUTHORIZATION|PASS_AUTHORIZATION="2"
INCLUDE_AI|INCLUDE_AI="yes"
WEB_EXTRA|WEB_EXTRA_NAME="only-the-name"
DEPLOY_EXCLUDES|DEPLOY_EXCLUDES="/tests/;id"
SYNC_EXCLUDES|SYNC_EXCLUDES='.git $(id)'
DEV_MARKER|DEV_MARKER=".stack-managed"
CI_STATIC_SCRIPT|CI_STATIC_SCRIPT="a b"
PROJECT_LABEL|PROJECT_LABEL=""
PROJECT_LABEL|PROJECT_LABEL='My {{label}}; rm'
IMAGE_OWNER|IMAGE_OWNER="Bad Owner"
IMAGE_OWNER|IMAGE_OWNER="UPPER"
IMAGE_OWNER|IMAGE_OWNER='x$(id)'
IMAGE_OWNER|IMAGE_OWNER="a"
IMAGE_OWNER|IMAGE_OWNER="-owner"
IMAGE_OWNER|IMAGE_OWNER="owner/"
DEPLOY_EXTRA|DEPLOY_EXTRA="../x:mod"
DEPLOY_EXTRA|DEPLOY_EXTRA="a//b:mod"
DEPLOY_EXTRA|DEPLOY_EXTRA="a/b/:mod"
DEPLOY_EXTRA|DEPLOY_EXTRA="a/b:Bad"
DEPLOY_EXTRA|DEPLOY_EXTRA="a/b"
DEPLOY_EXTRA|DEPLOY_EXTRA="a/b:alpha_mod a/c:alpha_mod"
DEPLOY_EXTRA|DEPLOY_MODULES="alpha_mod"; DEPLOY_EXTRA="x/y:alpha_mod"
DEPLOY_EXTRA|DEPLOY_EXTRA="x/y:sample_module"
DEPLOY_EXTRA|DEPLOY_EXTRA="/abs/x:mod"
DEPLOY_EXTRA|DEPLOY_EXTRA="a:b:c"
DEPLOY_EXTRA|DEPLOY_EXTRA="a/*:mod"
DEPLOY_EXTRA|DEPLOY_EXTRA='a/$(id):mod'
DEPLOY_EXTRA|DEPLOY_EXTRA="a..b/c:mod"
DEPLOY_EXTRA|DEPLOY_EXTRA=":mod"
DEPLOY_EXTRA|DEPLOY_EXTRA="a/b:"
DEPLOY_EXTRA|DEPLOY_EXTRA=".hidden/x:mod"
DEPLOY_EXTRA|DEPLOY_EXTRA="a/b:m"
CASES

# ---- 3. nothing in the environment can stand in for a missing parameter -----------------------------------------------------------
grep -v '^STACK_NAME=' "$BASE" > "$WORK/p/nostack.env"
STACK_NAME=hijack bash "$RENDER" --check "$WORK/p/nostack.env" > "$WORK/out" 2>&1; st=$?
if [ "$st" -ne 0 ] && grep -q 'STACK_NAME' "$WORK/out"; then good "STACK_NAME in the environment does not replace a missing parameter"; else bad "an environment variable stood in for a missing parameter: $(cat "$WORK/out")"; fi

# a value that other lines refer to (APP_URL uses APP_HOST): the error must name it, not be bash's "unbound variable"
grep -v '^APP_HOST=' "$BASE" > "$WORK/p/noapphost.env"
bash "$RENDER" --check "$WORK/p/noapphost.env" > "$WORK/out" 2>&1; st=$?
if [ "$st" -ne 0 ] && grep -q 'APP_HOST: missing' "$WORK/out" && ! grep -q 'unbound variable' "$WORK/out"; then good "a missing APP_HOST is reported by name"; else bad "a missing APP_HOST was not reported as such: $(cat "$WORK/out")"; fi

# ---- 4. --check writes nothing -----------------------------------------------------------------------------------------------------
( cd "$WORK/emptycwd" && bash "$RENDER" --check "$WORK/p/good.env" > /dev/null 2>&1 )
if [ -z "$(ls -A "$WORK/emptycwd")" ]; then good "--check writes nothing"; else bad "--check wrote: $(ls -A "$WORK/emptycwd")"; fi

# ---- 5. writing -----------------------------------------------------------------------------------------------------------------------
echo "--- writing"
R="$WORK/root"; mkdir -p "$R"
bash "$RENDER" "$WORK/p/good.env" "$R" > "$WORK/out" 2>&1; st=$?
# the destination is the DEST_DIR of the example, which is read from the example, not from this project
EXAMPLE_DEST="$(sed -n 's/^DEST_DIR="\(.*\)"/\1/p' "$BASE" | head -n 1)"
D="$R/${EXAMPLE_DEST:-tools/docker}"
if [ "$st" -ne 0 ]; then bad "render failed: $(cat "$WORK/out")"
else
    good "render writes the project folder"
    for f in stack.conf portainer.env README.md lib.sh sync.sh deploy.sh ci-local.sh run.sh doctor.sh snapshot.sh reset.sh install-perfex.sh locked.sh extra/README.md tests/deploy-test.sh tests/locked-test.sh tests/scripts-test.sh tests/render-test.sh ai/PROMPT.md ai/AGENTS-section.md ai/memory-note.md; do
        [ -f "$D/$f" ] || bad "missing in the project folder: $f"
    done
    if [ "$(ls -A "$D/extra" | tr '\n' ' ')" = "README.md " ] && ( . "$BASE"; grep -q "$SSH_ALIAS" "$D/extra/README.md" ) && grep -q 'This folder is yours' "$D/extra/README.md"; then
        good "extra/ holds the README.md and nothing else, with the values of the project in it"
    else
        bad "extra/ is not the README.md alone: $(ls -A "$D/extra" 2>&1 | tr '\n' ' ')"
    fi
    if [ -f "$D/ai/AGENTS-section.md" ] && grep -q 'perfex-crm-stack: test instance, begin' "$D/ai/AGENTS-section.md" \
        && grep -q 'perfex-crm-stack: test instance, end' "$D/ai/AGENTS-section.md" && [ ! -e "$D/ai/CLAUDE-section.md" ]; then
        good "ai/AGENTS-section.md is written with its two markers, and no CLAUDE-section.md is left"
    else
        bad "ai/AGENTS-section.md is missing, has no markers, or an old CLAUDE-section.md is still written"
    fi
    for f in "$D"/*.sh "$D"/tests/*.sh; do
        [ -x "$f" ] || bad "not executable: $f"
        bash -n "$f" || bad "bash -n fails on $f"
    done
    if grep -rEq '\{\{[A-Z0-9_]+\}\}' "$D"; then bad "placeholders left: $(grep -rEn '\{\{[A-Z0-9_]+\}\}' "$D" | head -n 3)"; else good "no placeholder is left in the generated files"; fi
    if [ "$(ls -A "$R" | tr '\n' ' ')" = "$(echo "$EXAMPLE_DEST" | cut -d/ -f1) " ]; then good "nothing is written outside the destination folder"; else bad "the project root now holds: $(ls -A "$R" | tr '\n' ' ')"; fi
    ( . "$BASE"; grep -q "^SSH_ALIAS=\"$SSH_ALIAS\"\$" "$D/stack.conf" ) && good "stack.conf carries the values of the parameters" || bad "stack.conf does not carry the SSH alias of the parameters"
    if grep -Ev '^PERFEX_DB_' "$D/portainer.env" | grep -Eq '^[A-Z0-9_]+=\s*$'; then bad "portainer.env has a variable with no value (other than the four PERFEX_DB_*)"; else good "portainer.env has no empty variable other than the four PERFEX_DB_*"; fi
    if [ "$(grep -Ec '^PERFEX_DB_(HOST|NAME|USER|PASSWORD)=$' "$D/portainer.env")" -eq 4 ]; then good "portainer.env holds the four PERFEX_DB_* lines, all empty"; else bad "portainer.env does not hold exactly the four empty PERFEX_DB_* lines"; fi
    if grep -Eq '^PERFEX_DB_[A-Z]+=.+' "$D/portainer.env"; then bad "portainer.env holds a database value"; else good "portainer.env holds no database value"; fi
fi

# a folder that is not empty
echo "tampered" > "$D/stack.conf"; echo "mine" > "$D/notes.txt"
mkdir -p "$D/extra"; printf '#!/usr/bin/env bash\necho mine\n' > "$D/extra/mine.sh"; cp "$D/extra/mine.sh" "$WORK/mine.sh.orig"; echo "tampered" > "$D/extra/README.md"
bash "$RENDER" "$WORK/p/good.env" "$R" > "$WORK/out" 2>&1; st=$?
if [ "$st" -ne 0 ] && [ "$(cat "$D/stack.conf")" = tampered ]; then good "a folder that is not empty is refused without --force, and untouched"; else bad "a non-empty folder was not refused (status $st)"; fi
bash "$RENDER" "$WORK/p/good.env" "$R" --force > "$WORK/out" 2>&1; st=$?
if [ "$st" -eq 0 ] && grep -q '^SSH_ALIAS=' "$D/stack.conf" && [ "$(cat "$D/notes.txt")" = mine ]; then good "--force replaces the generated files and keeps the others"; else bad "--force did not behave (status $st): $(cat "$WORK/out")"; fi
if cmp -s "$D/extra/mine.sh" "$WORK/mine.sh.orig"; then good "--force keeps a script of the user in extra/, identical to what it was"; else bad "--force changed or removed the script in extra/"; fi
if [ "$(ls -A "$D/extra" | tr '\n' ' ')" = "README.md mine.sh " ] && grep -q 'This folder is yours' "$D/extra/README.md"; then good "--force rewrites extra/README.md and touches nothing else in extra/"; else bad "--force did not restore extra/README.md alone: $(ls -A "$D/extra" | tr '\n' ' ')"; fi

# the destination is never inside the template
before="$(find "$TEMPLATE_DIR" -type f | wc -l | tr -d ' ')"
bash "$RENDER" "$WORK/p/good.env" "$TEMPLATE_DIR" > "$WORK/out" 2>&1; st=$?
after="$(find "$TEMPLATE_DIR" -type f | wc -l | tr -d ' ')"
if [ "$st" -ne 0 ] && [ "$before" = "$after" ]; then good "a destination inside the template is refused, and nothing is written there"; else bad "the template was used as a destination (status $st, files $before -> $after)"; fi

# INCLUDE_AI=0, and a project root whose name has a space
mkparams noai 'INCLUDE_AI="0"'
R2="$WORK/root with space"; mkdir -p "$R2"
bash "$RENDER" "$WORK/p/noai.env" "$R2" > "$WORK/out" 2>&1; st=$?
if [ "$st" -eq 0 ] && [ ! -e "$R2/${EXAMPLE_DEST:-tools/docker}/ai" ] && [ -f "$R2/${EXAMPLE_DEST:-tools/docker}/stack.conf" ]; then good "INCLUDE_AI=0 leaves out ai/, and a root with a space works"; else bad "INCLUDE_AI=0 or the root with a space failed (status $st): $(cat "$WORK/out")"; fi

# ---- 6. image names, the list of PHP versions, the path of the template -----------------------------------------------------------------
echo "--- images, PHP versions, template path"
DEST_OF_EXAMPLE="${EXAMPLE_DEST:-tools/docker}"
render_conf() { # render_conf <name> [<line> ...]: renders the example plus the lines into $WORK/r-<name>; sets STATUS and CONF (its stack.conf)
    local name="$1"; shift
    mkparams "$name" "$@"
    rm -rf "$WORK/r-$name"; mkdir -p "$WORK/r-$name"
    bash "$RENDER" "$WORK/p/$name.env" "$WORK/r-$name" > "$WORK/out" 2>&1; STATUS=$?
    CONF="$WORK/r-$name/$DEST_OF_EXAMPLE/stack.conf"
}
conf_has() { grep -qxF -- "$1" "$CONF"; }

render_conf noowner
if [ "$STATUS" -eq 0 ] && conf_has 'WEB_IMAGE="perfex-web:8.4"' && conf_has 'TOOLS_IMAGE="perfex-tools:8.1-8.5"'; then good "no IMAGE_OWNER: the images are perfex-web:8.4 and perfex-tools:8.1-8.5"; else bad "the default image names are wrong (status $STATUS): $(cat "$WORK/out")"; fi
render_conf owner 'IMAGE_OWNER="myowner"'
if [ "$STATUS" -eq 0 ] && conf_has 'WEB_IMAGE="myowner/perfex-web:8.4"' && conf_has 'TOOLS_IMAGE="myowner/perfex-tools:8.1-8.5"'; then good "IMAGE_OWNER=myowner: stack.conf carries myowner/perfex-web:8.4 and myowner/perfex-tools:8.1-8.5"; else bad "IMAGE_OWNER did not prefix the images (status $STATUS): $(cat "$WORK/out")"; fi
if [ "$STATUS" -eq 0 ] && grep -qxF 'WEB_IMAGE=myowner/perfex-web:8.4' "$WORK/r-owner/$DEST_OF_EXAMPLE/portainer.env" && grep -qxF 'TOOLS_IMAGE=myowner/perfex-tools:8.1-8.5' "$WORK/r-owner/$DEST_OF_EXAMPLE/portainer.env"; then good "IMAGE_OWNER=myowner: portainer.env carries the same two names"; else bad "portainer.env does not carry the prefixed image names"; fi
render_conf registry 'IMAGE_OWNER="registry.example.com/team"'
if [ "$STATUS" -eq 0 ] && conf_has 'WEB_IMAGE="registry.example.com/team/perfex-web:8.4"'; then good "IMAGE_OWNER can be a registry with a path"; else bad "a registry prefix was not applied (status $STATUS): $(cat "$WORK/out")"; fi
render_conf ownover 'IMAGE_OWNER="myowner"' 'WEB_IMAGE="mine/web:1"'
if [ "$STATUS" -eq 0 ] && conf_has 'WEB_IMAGE="mine/web:1"' && conf_has 'TOOLS_IMAGE="myowner/perfex-tools:8.1-8.5"'; then good "WEB_IMAGE overrides the name of the web image only"; else bad "WEB_IMAGE did not override (status $STATUS): $(cat "$WORK/out")"; fi

# the blanks of a list of versions are squeezed (a leading blank used to give the tag perfex-tools:-8.3), and a single version names both ends
render_conf blanks 'TOOLS_PHP_VERSIONS="  8.3   8.4 "' 'MATRIX_PHP_VERSIONS="8.3 8.4"'
if [ "$STATUS" -eq 0 ] && conf_has 'TOOLS_PHP_VERSIONS="8.3 8.4"' && conf_has 'TOOLS_IMAGE="perfex-tools:8.3-8.4"'; then good "blanks in TOOLS_PHP_VERSIONS are squeezed: the list is \"8.3 8.4\" and the tag perfex-tools:8.3-8.4"; else bad "blanks in TOOLS_PHP_VERSIONS were not squeezed (status $STATUS): $(cat "$WORK/out") / $(grep -E '^TOOLS_' "$CONF")"; fi
render_conf tabs "TOOLS_PHP_VERSIONS=\"8.3$(printf '\t')8.4\"" 'MATRIX_PHP_VERSIONS="8.3 8.4"'
if [ "$STATUS" -eq 0 ] && conf_has 'TOOLS_IMAGE="perfex-tools:8.3-8.4"' && grep -q 'PHP_VERSIONS="8.3 8.4"' "$WORK/r-tabs/$DEST_OF_EXAMPLE/README.md"; then good "a tab between versions becomes one blank, in stack.conf and in the build command of the README"; else bad "a tab in TOOLS_PHP_VERSIONS was kept (status $STATUS)"; fi
render_conf oneversion 'TOOLS_PHP_VERSIONS="8.4"' 'MATRIX_PHP_VERSIONS="8.4"'
if [ "$STATUS" -eq 0 ] && conf_has 'TOOLS_IMAGE="perfex-tools:8.4-8.4"'; then good "a single PHP version gives the tag perfex-tools:8.4-8.4 (always <first>-<last>)"; else bad "the tag of a single version is not <v>-<v> (status $STATUS): $(cat "$WORK/out") / $(grep -E '^TOOLS_IMAGE' "$CONF")"; fi
mkparams blankonly 'TOOLS_PHP_VERSIONS="   "'
bash "$RENDER" --check "$WORK/p/blankonly.env" > "$WORK/out" 2>&1; st=$?
if [ "$st" -ne 0 ] && grep -q 'TOOLS_PHP_VERSIONS' "$WORK/out"; then good "a TOOLS_PHP_VERSIONS made of blanks is refused, by name"; else bad "a blank TOOLS_PHP_VERSIONS was accepted (status $st): $(cat "$WORK/out")"; fi

# DEPLOY_EXTRA: a good value ends in stack.conf, is listed by --check, and an empty one is allowed (the example's)
render_conf extra 'DEPLOY_EXTRA="alpha_mod/examples/alpha_notes:alpha_notes other/deep/folder:other_notes"'
if [ "$STATUS" -eq 0 ] && conf_has 'DEPLOY_EXTRA="alpha_mod/examples/alpha_notes:alpha_notes other/deep/folder:other_notes"'; then good "DEPLOY_EXTRA with two pairs ends in stack.conf"; else bad "a good DEPLOY_EXTRA was refused or not recorded (status $STATUS): $(cat "$WORK/out")"; fi
bash "$RENDER" --check "$WORK/p/extra.env" > "$WORK/out" 2>&1; st=$?
if [ "$st" -eq 0 ] && grep -q 'deploy: sample_module; extra: alpha_notes other_notes; matrix' "$WORK/out"; then good "--check names the extra modules on its deploy line"; else bad "--check does not list the extra names (status $st): $(cat "$WORK/out")"; fi
bash "$RENDER" --check "$WORK/p/good.env" > "$WORK/out" 2>&1; st=$?
if [ "$st" -eq 0 ] && grep -q 'deploy: sample_module; matrix' "$WORK/out" && ! grep -q 'extra:' "$WORK/out"; then good "--check says nothing of extras when there are none"; else bad "--check printed an extra line with an empty DEPLOY_EXTRA: $(cat "$WORK/out")"; fi
render_conf noextra
if [ "$STATUS" -eq 0 ] && conf_has 'DEPLOY_EXTRA=""'; then good "an empty DEPLOY_EXTRA gives DEPLOY_EXTRA=\"\" in stack.conf"; else bad "DEPLOY_EXTRA is missing from stack.conf (status $STATUS)"; fi

# the template folder, seen from the project root, goes into stack.conf: a plain relative path, ".." at the start allowed
copytpl() { # copytpl <destination>: the files render.sh needs, in another folder
    mkdir -p "$1"; cp "$TEMPLATE_DIR/render.sh" "$1/"; cp -R "$TEMPLATE_DIR/project" "$1/project"
    if [ -d "$TEMPLATE_DIR/ai" ]; then cp -R "$TEMPLATE_DIR/ai" "$1/ai"; fi
}
copytpl "$WORK/tpl with space"
mkdir -p "$WORK/root-ts"
bash "$WORK/tpl with space/render.sh" "$WORK/p/good.env" "$WORK/root-ts" > "$WORK/out" 2>&1; st=$?
if [ "$st" -ne 0 ] && grep -q 'TEMPLATE_REL' "$WORK/out" && [ -z "$(ls -A "$WORK/root-ts")" ]; then good "a template whose path from the root has a blank is refused by name, and nothing is written"; else bad "a template path with a blank was accepted or left files (status $st): $(cat "$WORK/out")"; fi
bash "$WORK/tpl with space/render.sh" --check "$WORK/p/good.env" > "$WORK/out" 2>&1; st=$?
if [ "$st" -ne 0 ] && grep -q 'TEMPLATE_REL' "$WORK/out"; then good "--check refuses it too"; else bad "--check accepted a template path with a blank (status $st)"; fi
copytpl "$WORK/tpl-ok"
mkdir -p "$WORK/root-ok"
bash "$WORK/tpl-ok/render.sh" "$WORK/p/good.env" "$WORK/root-ok" > "$WORK/out" 2>&1; st=$?
if [ "$st" -eq 0 ] && grep -qxF 'TEMPLATE_REL="../tpl-ok"' "$WORK/root-ok/$DEST_OF_EXAMPLE/stack.conf"; then good "a template next to the project (TEMPLATE_REL ../tpl-ok) is accepted, with the leading .."; else bad "a template next to the root was refused or recorded wrongly (status $st): $(cat "$WORK/out")"; fi

[ "$fail" -eq 0 ] && echo "=== render-test: all ok ===" || echo "=== render-test: FAILED ==="
exit "$fail"
