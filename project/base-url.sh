#!/usr/bin/env bash
# Makes APP_BASE_URL of the application follow the request (a tunnel, an HTTPS proxy, a self-signed certificate), or puts it back.
# Usage: base-url.sh status|dynamic|fixed [<target>]
#   status   says whether APP_BASE_URL is fixed or dynamic, and the configured address (changes nothing)
#   dynamic  comments the define the installation wizard wrote and adds a block that keeps the configured address on the
#            command line and, on the web, takes the scheme and the host from the request (X-Forwarded-Proto, HTTPS, port 443;
#            X-Forwarded-Host or Host). A copy of the file is kept in /repo/.app-config-<target>.php.bak first.
#   fixed    removes that block and uncomments the define: the address is the configured one again.
#   target   an application folder from APP_TARGETS (the first one is the default).
# TEST INSTANCE ONLY: with "dynamic" the application trusts the Host header of every request. Never do this on a real site.
# The file is application/config/app-config.php of the target, written by the wizard: install the application first.
# Values come from stack.conf, not from this file.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; }

ACTION=""; TARGET=""; _n=0
for _arg in "$@"; do
    case "$_arg" in
        -h|--help) usage; exit 0 ;;
        -*) die "unknown option: $_arg" ;;
        *) _n=$((_n + 1))
           case "$_n" in 1) ACTION="$_arg" ;; 2) TARGET="$_arg" ;; *) die "too many arguments" ;; esac ;;
    esac
done
[ "$_n" -ge 1 ] || { usage >&2; exit 2; }

stack_load "$HERE"
TARGET="${TARGET:-${APP_TARGETS%% *}}"

# The action, the target and the PHP version end up in a command executed on the server: closed lists or a strict pattern.
case "$ACTION" in
    status|dynamic|fixed) ;;
    *) die "unknown action: \"$ACTION\" (status, dynamic or fixed)" ;;
esac
valid_target "$TARGET" || die "invalid target: \"$TARGET\""
# shellcheck disable=SC2086
in_list "$TARGET" $APP_TARGETS || die "target not allowed: $TARGET (allowed: $APP_TARGETS)"
valid_php "$DEFAULT_PHP" || die "invalid DEFAULT_PHP in stack.conf: $DEFAULT_PHP"

# This script does not go through sync.sh: locked.sh must be on the server before the job runs.
ensure_locked_sh

# The script runs on the server with the values as positional parameters (quoted with %q), never pasted into its text.
# It checks them again. STACK_SERVER_ROOT is empty on the server; tests/scripts-test.sh sets it to run this very text against a
# folder tree. What it says (the state, the configured address, the copy, the warning) is what you see: nothing is added here.
remote_locked "bash -s -- $(printf '%q %q %q' "$ACTION" "$TARGET" "$DEFAULT_PHP")" <<'REMOTE'
set -euo pipefail
action="$1"; target="$2"; php="$3"
srv="${STACK_SERVER_ROOT:-}"
fail() { echo "$1" >&2; exit "${2:-1}"; }
case "$action" in status|dynamic|fixed) ;; *) fail "invalid action: $action" ;; esac
[[ "$target" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || fail "invalid target: $target"
[[ "$php" =~ ^[0-9]+\.[0-9]+$ ]] || fail "invalid PHP version: $php"

app="$srv/$target"
cfg="$app/application/config/app-config.php"
bak="$srv/repo/.app-config-$target.php.bak"
begin='// perfex-crm-stack: dynamic APP_BASE_URL (base-url.sh), begin'
end='// perfex-crm-stack: dynamic APP_BASE_URL (base-url.sh), end'
fixed_re="^define\('APP_BASE_URL', '(https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?)'\);$"
[ -d "$app" ] || fail "target /$target is not mounted in the tools container"
{ [ -f "$cfg" ] && [ ! -L "$cfg" ]; } || fail "application/config/app-config.php not found under /$target: install the application first (the wizard writes it)"

# The file the wizard writes has CRLF line endings: the lines are compared without the CR, and the lines this script adds get
# the line ending of the file, so that "fixed" gives the file back byte for byte. The text stays in a variable: it holds the
# credentials of the instance, and nothing of it is ever printed but the APP_BASE_URL value.
cr=""
if grep -q "$(printf '\r')" "$cfg"; then cr="$(printf '\r')"; fi
body="$(tr -d '\r' < "$cfg")"
count() { printf '%s\n' "$body" | grep -c "$@" || true; }
n_begin="$(count -xF -- "$begin")"; n_end="$(count -xF -- "$end")"
n_def="$(count "^define('APP_BASE_URL', ")"; n_off="$(count "^// define('APP_BASE_URL', ")"
url=""
if [ "$n_begin" -eq 0 ] && [ "$n_end" -eq 0 ] && [ "$n_def" -eq 1 ] && [ "$n_off" -eq 0 ]; then
    shape=fixed; line="$(printf '%s\n' "$body" | grep "^define('APP_BASE_URL', ")"
    [[ "$line" =~ $fixed_re ]] || fail "the APP_BASE_URL line of app-config.php is not in the shape the wizard writes, or its value has unexpected characters: not touching it"
    url="${BASH_REMATCH[1]}"
elif [ "$n_begin" -eq 1 ] && [ "$n_end" -eq 1 ] && [ "$n_def" -eq 0 ] && [ "$n_off" -eq 1 ]; then
    shape=dynamic; line="$(printf '%s\n' "$body" | grep "^// define('APP_BASE_URL', ")"; line="${line#// }"
    [[ "$line" =~ $fixed_re ]] || fail "the commented APP_BASE_URL line of app-config.php is not as base-url.sh left it: not touching it"
    url="${BASH_REMATCH[1]}"
else
    shape=unknown
fi

case "$action" in
status)
    case "$shape" in
        fixed) echo "APP_BASE_URL is fixed: $url" ;;
        dynamic) echo "APP_BASE_URL is dynamic (the scheme and the host follow the request; on the command line: $url)" ;;
        *) echo "APP_BASE_URL: app-config.php is neither as the wizard wrote it nor as base-url.sh leaves it (edited by hand?)"; exit 1 ;;
    esac
    exit 0 ;;
dynamic)
    [ "$shape" != dynamic ] || { echo "APP_BASE_URL is already dynamic (on the command line: $url): nothing to do"; exit 0; }
    [ "$shape" = fixed ] || fail "app-config.php is neither as the wizard wrote it nor as base-url.sh leaves it (edited by hand?): not touching it"
    rest="${url#*://}"
    case "$rest" in */?*) fail "dynamic works for an application at the root of its host; the configured address has a path: $url" ;; esac
    ;;
fixed)
    [ "$shape" != fixed ] || { echo "APP_BASE_URL is already fixed: $url"; exit 0; }
    [ "$shape" = dynamic ] || fail "app-config.php is neither as the wizard wrote it nor as base-url.sh leaves it (edited by hand?): not touching it"
    ;;
esac

# The copy comes first; the new text is built next to the file, checked with php -l, and moved over it only then (the owner and
# the mode stay). Whatever happens, the working files are removed on exit: a copy of the credentials never stays behind.
tmp="$cfg.base-url.tmp"; blk="$cfg.base-url.block"
trap 'rm -f "$tmp" "$blk" "$blk.2"' EXIT
if [ "$action" = dynamic ]; then cp -p "$cfg" "$bak"; fi
cp -p "$cfg" "$tmp"
if [ "$action" = dynamic ]; then
    cat > "$blk" <<'PHP'
// perfex-crm-stack: dynamic APP_BASE_URL (base-url.sh), begin
// The address follows the request, so that the instance also answers through a tunnel or an HTTPS proxy (ngrok, Cloudflare
// Tunnel, a reverse proxy with a self-signed certificate). On the command line (cron) the configured address stays.
// TEST INSTANCE ONLY: the base URL trusts the Host header of the request. Remove with: base-url.sh fixed
if (php_sapi_name() === 'cli' || (empty($_SERVER['HTTP_X_FORWARDED_HOST']) && empty($_SERVER['HTTP_HOST']))) {
    define('APP_BASE_URL', '__URL__');
} else {
    $is_https = (!empty($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https')
        || (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off')
        || (isset($_SERVER['SERVER_PORT']) && (int) $_SERVER['SERVER_PORT'] === 443);
    $host = !empty($_SERVER['HTTP_X_FORWARDED_HOST']) ? $_SERVER['HTTP_X_FORWARDED_HOST'] : $_SERVER['HTTP_HOST'];
    $host = trim(explode(',', $host)[0]);
    define('APP_BASE_URL', ($is_https ? 'https://' : 'http://') . $host . '/');
    unset($is_https, $host);
}
// perfex-crm-stack: dynamic APP_BASE_URL (base-url.sh), end
PHP
    sed "s|__URL__|$url|" "$blk" | awk -v cr="$cr" '{ print $0 cr }' > "$blk.2"
    awk 'FNR == NR { blk = blk $0 "\n"; next } /^define\(.APP_BASE_URL., / { print "// " $0; printf "%s", blk; next } { print }' "$blk.2" "$cfg" > "$tmp"
else
    awk -v b="$begin" -v e="$end" '{ l = $0; sub(/\r$/, "", l) } l == b { skip = 1; next } l == e { skip = 0; next } skip { next } l ~ /^\/\/ define\(.APP_BASE_URL., / { sub(/^\/\/ /, ""); print; next } { print }' "$cfg" > "$tmp"
fi
if ! PATH="/opt/php/$php:$PATH" php -l "$tmp" > /dev/null 2>&1 < /dev/null; then
    fail "the new app-config.php does not pass php -l: the file was not changed"
fi
mv -f "$tmp" "$cfg"
if [ "$action" = dynamic ]; then
    echo "APP_BASE_URL is now dynamic: the scheme and the host follow the request (X-Forwarded-Proto, HTTPS, port 443; X-Forwarded-Host or Host); on the command line it stays $url"
    echo "copy of the file before the change: /repo/.app-config-$target.php.bak. Test instance only: the application now trusts the Host header. Wait a few seconds (opcache) before you try"
else
    echo "APP_BASE_URL is fixed again: $url (the copy /repo/.app-config-$target.php.bak stays)"
fi
REMOTE
