#!/usr/bin/env bash
# Checks the stack from the Mac, over SSH and HTTP, and tells you what to fix. Changes nothing.
# Usage: doctor.sh            run the checks (exit status = number of failed checks)
#        doctor.sh --guide    print the setup steps with the values of stack.conf (the same steps as README.md, condensed)
# Checks: SSH login with the key; PHP and Composer versions; /app and /repo are mounted and writable; the stack variables
# are present in the SSH session (their NAMES only, never their values); the database answers; locked.sh is on the server
# (sync.sh puts it there); the authorized key file is not empty; the application name resolves from the Mac; GET / answers
# from the Mac and from the tools container. When ai/ was rendered (INCLUDE_AI=1): whether AGENTS.md and CLAUDE.md at the
# project root hold the test-instance section of ai/AGENTS-section.md (notes only, never a failure).
# Values come from stack.conf, not from this file.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
stack_load "$HERE"

if [ "${1:-}" = "--guide" ]; then
    db_example="${STACK_NAME//-/_}"
    cat <<EOT
Setup of the stack "$STACK_NAME": the steps with your values (README.md has the explanations).
Run the Mac steps from the project root:   cd "$ROOT"
"SERVER" is how YOU log in to the server as root; an AI agent has no such access.

1. Mac: a key and an alias
   ssh-keygen -t ed25519 -f ~/.ssh/$SSH_ALIAS -C $SSH_ALIAS -N ""
   Add to ~/.ssh/config:
       Host $SSH_ALIAS
           HostName $TOOLS_HOST
           Port 2222
           User www-data
           IdentityFile ~/.ssh/$SSH_ALIAS
           IdentitiesOnly yes
   cat ~/.ssh/$SSH_ALIAS.pub      (copy the line: step 3 needs it)

2. Mac: copy the build context of the two images to the server
   rsync -av --delete $TEMPLATE_REL/stack/ root@SERVER:$REMOTE_ROOT/build/

3. Server, as root: folders, key, images
   ROOT=$REMOTE_ROOT; mkdir -p \$ROOT/app \$ROOT/repo \$ROOT/tools/hostkeys && chown -R 33:33 \$ROOT/app \$ROOT/repo
   printf '%s\n' 'ssh-ed25519 AAAA... $SSH_ALIAS' > \$ROOT/tools/authorized_keys && chmod 644 \$ROOT/tools/authorized_keys
   cd $REMOTE_ROOT/build
   docker build -f web/Dockerfile --build-arg PHP_VERSION=$WEB_PHP_VERSION -t $WEB_IMAGE web
   docker build -f tools.Dockerfile --build-arg PHP_VERSIONS="$TOOLS_PHP_VERSIONS" --build-arg TOOLS_NODE=$TOOLS_NODE -t $TOOLS_IMAGE .
   If you set WEB_IMAGE to an image of your own, skip the first build: that image does not come from web/Dockerfile, you provide it under that name.

4. MariaDB, with its administrator account: a database (utf8mb4_unicode_ci) and a user with all privileges on it only,
   for example $db_example for both (README step 4 has the SQL). Keep the password out of chat and files.

5. Portainer: Stacks > Add stack, name $STACK_NAME, web editor (paste stack/docker-compose.yml) or Git repository.
   Stack variables: load $DEST_DIR/portainer.env, then type the values of PERFEX_DB_HOST, PERFEX_DB_NAME, PERFEX_DB_USER, PERFEX_DB_PASSWORD (loaded empty).

6. Mac: $DEST_DIR/doctor.sh      then, if the application is not installed yet:  $DEST_DIR/install-perfex.sh <your Perfex folder or zip>
   and open $APP_URL in the browser to finish the installation.
EOT
    exit 0
fi
[ $# -eq 0 ] || die "usage: doctor.sh [--guide]"

valid_php "$DEFAULT_PHP" || die "invalid DEFAULT_PHP in stack.conf"
for v in $TOOLS_PHP_VERSIONS; do valid_php "$v" || die "invalid PHP version in TOOLS_PHP_VERSIONS: $v"; done
[[ "$TOOLS_NODE" =~ ^[01]$ ]] || die "invalid TOOLS_NODE in stack.conf"

failed=0
report() { # report <line>: prints it and counts the FAIL lines
    echo "$1"
    case "$1" in FAIL:*) failed=$((failed + 1)) ;; esac
}

# The checks that run on the server. The text goes to "bash -s" over ssh with the values as parameters; it prints names
# and versions, never the value of a variable. Lines start with "ok:", "note:" or "FAIL:".
remote_checks() {
    cat <<'REMOTE'
locked="$1"; php_versions="$2"; node="$3"
for v in $php_versions; do
    out="$(/opt/php/"$v"/php -v 2>/dev/null | head -n 1)"
    if [ -n "$out" ]; then echo "ok: PHP $v ($out)"; else echo "FAIL: PHP $v is not in the tools image: rebuild it, or remove $v from TOOLS_PHP_VERSIONS"; fi
done
out="$(composer --version 2>/dev/null | head -n 1)"
if [ -n "$out" ]; then echo "ok: $out"; else echo "FAIL: composer is not available"; fi
if [ "$node" = 1 ]; then
    out="$(node --version 2>/dev/null)"
    if [ -n "$out" ]; then echo "ok: node $out"; else echo "FAIL: TOOLS_NODE=1 but node is not in the image: rebuild it with --build-arg TOOLS_NODE=1"; fi
fi
for t in flock rsync mariadb; do
    if command -v "$t" >/dev/null 2>&1; then echo "ok: $t is installed"; else echo "FAIL: $t is not installed in the image"; fi
done
for m in /app /repo; do
    if awk -v m="$m" '$5 == m { f = 1 } END { exit !f }' /proc/self/mountinfo; then
        if [ -w "$m" ]; then echo "ok: $m is mounted and writable"; else echo "FAIL: $m is mounted but www-data cannot write it (chown 33:33 the folder on the host)"; fi
    else
        echo "FAIL: $m is not a mount of the container: check the volumes of the stack"
    fi
done
for n in PERFEX_URL PERFEX_APP_PATH PERFEX_DB_HOST PERFEX_DB_NAME PERFEX_DB_USER PERFEX_DB_PASSWORD; do
    if [ -n "${!n:-}" ]; then echo "ok: variable $n is set"; else echo "FAIL: variable $n is not set in the SSH session (stack variable missing, or the container was not recreated)"; fi
done
for n in MAILPIT_URL MAILPIT_SMTP_HOST MAILPIT_SMTP_PORT; do
    if [ -n "${!n:-}" ]; then echo "ok: variable $n is set"; else echo "note: variable $n is not set (optional)"; fi
done
if [ -n "${PERFEX_DB_HOST:-}" ] && [ -n "${PERFEX_DB_USER:-}" ] && [ -n "${PERFEX_DB_NAME:-}" ]; then
    if MYSQL_PWD="${PERFEX_DB_PASSWORD:-}" mariadb --connect-timeout=5 -h "$PERFEX_DB_HOST" -u "$PERFEX_DB_USER" "$PERFEX_DB_NAME" -e 'SELECT 1' >/dev/null 2>&1; then
        echo "ok: the database answers"
    else
        echo "FAIL: the database does not answer with the stack variables (host, name, user or password wrong, or the server cannot be reached from the container)"
    fi
fi
if [ -f "$locked" ]; then echo "ok: locked.sh is on the server ($locked)"; else echo "FAIL: locked.sh is not on the server: run sync.sh ($locked)"; fi
if [ -s /etc/ssh/authorized_keys.d/www-data ]; then
    echo "ok: authorized_keys holds $(grep -Ec '^(ssh-|ecdsa-|sk-)' /etc/ssh/authorized_keys.d/www-data) key line(s)"
else
    echo "FAIL: authorized_keys is empty or missing in the container"
fi
if [ -n "${PERFEX_URL:-}" ]; then
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$PERFEX_URL/" 2>/dev/null || true)"
    case "$code" in
        000|"") echo "FAIL: the tools container cannot reach $PERFEX_URL (is the web container up? is APP_URL right?)" ;;
        5??) echo "FAIL: GET $PERFEX_URL/ from the tools container answers $code (look at the web container's logs)" ;;
        *) echo "ok: GET $PERFEX_URL/ from the tools container answers $code" ;;
    esac
fi
REMOTE
}

echo "--- SSH login as $HOST (key only)"
if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" true; then
    report "FAIL: cannot log in with the alias $HOST. Check ~/.ssh/config (HostName $TOOLS_HOST, Port 2222, User www-data, IdentityFile), the key, that authorized_keys on the server holds its public line, and that the stack is running. 'doctor.sh --guide' prints the steps."
else
    report "ok: SSH login as $HOST"
    echo "--- inside the tools container"
    checks="$(remote_checks | ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "bash -s -- $(printf '%q %q %q' "$LOCKED_SH" "$TOOLS_PHP_VERSIONS" "$TOOLS_NODE")")" || true
    if [ -z "$checks" ]; then
        report "FAIL: the checks inside the container did not run"
    else
        while IFS= read -r line; do
            [ -z "$line" ] || report "$line"
        done <<< "$checks"
    fi
fi

echo "--- the application from this Mac"
app_host="${APP_URL#*://}"; app_host="${app_host%%/*}"; app_host="${app_host%%:*}"
rc=0
out="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$APP_URL/" 2>&1)" || rc=$?
if [ "$rc" -eq 6 ]; then
    report "FAIL: $app_host does not resolve from this Mac: check the DNS that serves your Docker network names"
elif [ "$rc" -ne 0 ]; then
    report "FAIL: $APP_URL/ does not answer from this Mac (curl exit $rc): the name resolves, but the web container cannot be reached"
else
    report "ok: $app_host resolves from this Mac"
    case "$out" in
        5??) report "FAIL: GET $APP_URL/ answers $out (look at the web container's logs in Portainer; 502 usually means PHP-FPM is down)" ;;
        *) report "ok: GET $APP_URL/ answers $out" ;;
    esac
fi

if [ -f "$HERE/ai/AGENTS-section.md" ]; then
    echo "--- the instruction files of your AI agent (notes only)"
    marker="perfex-crm-stack: test instance, begin"
    for f in AGENTS.md CLAUDE.md; do
        if [ ! -f "$ROOT/$f" ]; then
            report "note: $f is missing at the project root: an agent that reads it knows nothing of the instance ($DEST_DIR/ai/AGENTS-section.md says where it goes)"
        elif grep -qF "$marker" "$ROOT/$f"; then
            report "ok: $f holds the test-instance section"
        elif [ "$f" = CLAUDE.md ] && grep -qE '^@AGENTS\.md[[:space:]]*$' "$ROOT/$f" && [ -f "$ROOT/AGENTS.md" ] && grep -qF "$marker" "$ROOT/AGENTS.md"; then
            report "ok: CLAUDE.md imports AGENTS.md, which holds the test-instance section"
        else
            report "note: $f has no test-instance section: add $DEST_DIR/ai/AGENTS-section.md to it, between its two markers"
        fi
    done
    if [ -f "$ROOT/.github/copilot-instructions.md" ] && ! grep -qF "$marker" "$ROOT/.github/copilot-instructions.md"; then
        report "note: .github/copilot-instructions.md exists without the test-instance section (Copilot Chat reads only that file)"
    fi
fi

echo
if [ "$failed" -eq 0 ]; then echo "doctor: all checks passed"; else echo "doctor: $failed check(s) failed"; fi
exit "$failed"
