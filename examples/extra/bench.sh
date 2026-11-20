#!/usr/bin/env bash
# Response times of one URL of the instance, measured from this machine: curl in a loop, then percentiles.
# Usage: bench.sh <path> [<requests> [<timing header>]]
#   path           what follows APP_URL, starting with "/" and made of letters, digits and . _ ~ / % ? = & -   (/admin/auth/login)
#   requests       how many requests are timed: 1 to 9999 (default 100). Ten more requests, not counted, warm the application first.
#   timing header  the name of a response header (letters, digits and -) whose value is a number of milliseconds, for example
#                  X-Response-Time: the script then reports that header too, and the difference between the total time and
#                  the header (what is not spent in the code that wrote the header). The first occurrence of the header counts.
# Each request is an anonymous GET: curl -s -o /dev/null -w '%{time_total}' (plus -D - to read the headers), with a limit of
# 30 seconds. There is no other option for curl and no authentication, and the HTTP status is not looked at: open the URL once
# first. A benchmark that signs in (an API key, a session cookie) is a script of yours that starts from this one.
# Output, printed and kept in <project root>/<LOCAL_TMP_DIR>/bench/<date>-<time>.txt, milliseconds with two decimals:
#   bench: GET <url>
#   requests: <n> timed, after 10 warm-up (not counted)
#   milliseconds                      p50        p95        p99
#   total                           12.34      15.67      20.10
#   <timing header>                  ...        (and "total - <timing header>", when a header is given)
# A percentile is the value at position ceil(p x n) of the sorted list: with 10 requests, p95 and p99 are the slowest one.
# The exit status is 1 when a request fails or when the header you asked for is in no response, and 2 for a usage error.
# Not a step of any test run: times on a shared server change from one run to the next. Written for bash 3.2 (perl is needed,
# as for render.sh).
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd -P)"   # the folder of the stack scripts (stack.conf, lib.sh, locked.sh)
# shellcheck source=../lib.sh
. "$HERE/lib.sh"
stack_load "$HERE"
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[ $# -ge 1 ] && [ $# -le 3 ] || { usage >&2; exit 2; }

# What ends up in the curl command is the URL, and nothing else you give: strict patterns, checked before the first request.
URL_PATH="$1"; REQUESTS="${2-100}"; HEADER="${3-}"
WARMUP=10
_path_re='^/[A-Za-z0-9._~/%?=&-]*$'
_url_re='^https?://[A-Za-z0-9._~:/?&=%#@+,;-]+$'
_tmp_re='^[A-Za-z0-9._][A-Za-z0-9._/-]*$'
[[ "$URL_PATH" =~ $_path_re ]] || die "invalid path: \"$URL_PATH\" (it starts with / and holds letters, digits and . _ ~ / % ? = & - only)"
[[ "$REQUESTS" =~ ^[0-9]{1,4}$ ]] && [ "$((10#$REQUESTS))" -ge 1 ] || die "invalid number of requests: \"$REQUESTS\" (1 to 9999)"
REQUESTS=$((10#$REQUESTS))
[ -z "$HEADER" ] || [[ "$HEADER" =~ ^[A-Za-z0-9-]+$ ]] || die "invalid timing header: \"$HEADER\" (letters, digits and - only)"
[[ "$APP_URL" =~ $_url_re ]] || die "invalid APP_URL in stack.conf: $APP_URL"
[[ "$LOCAL_TMP_DIR" =~ $_tmp_re && "$LOCAL_TMP_DIR" != *..* ]] || die "invalid LOCAL_TMP_DIR in stack.conf: $LOCAL_TMP_DIR"
URL="${APP_URL%/}$URL_PATH"

OUT="$ROOT/$LOCAL_TMP_DIR/bench"
mkdir -p "$OUT"
STAMP="$(date +%Y%m%d-%H%M%S)"
RAW="$OUT/$STAMP.raw"; REPORT="$OUT/$STAMP.txt"
: > "$RAW"

fetch() { # one GET: the response headers when a timing header is wanted, then the total time in seconds
    if [ -n "$HEADER" ]; then
        curl -s -o /dev/null -D - -w '%{time_total}' --max-time 30 "$URL"
    else
        curl -s -o /dev/null -w '%{time_total}' --max-time 30 "$URL"
    fi
}
i=0
while [ "$i" -lt "$WARMUP" ]; do
    fetch > /dev/null || die "a warm-up request failed (curl exit $?): $URL"
    i=$((i + 1))
done
i=0
while [ "$i" -lt "$REQUESTS" ]; do
    resp="$(fetch)" || die "request $((i + 1)) failed (curl exit $?): $URL"
    printf '%s\n--END--\n' "$resp" >> "$RAW"
    i=$((i + 1))
done

rc=0
perl -e '
    use strict; use warnings;
    my ($raw, $name, $url, $warm) = @ARGV;
    local $/;
    open(my $fh, "<", $raw) or die "cannot read $raw: $!\n";
    my $text = <$fh>;
    close $fh;
    my (@total, @hdr, @diff);
    for my $chunk (split /\n--END--\n/, $text) {
        my @lines = grep { /\S/ } split /\r?\n/, $chunk;
        next unless @lines;
        (my $t = $lines[-1]) =~ s/\s+//g;
        next unless $t =~ /\A[0-9]+(?:\.[0-9]+)?\z/;
        my $ms = $t * 1000;
        push @total, $ms;
        next unless length $name;
        for my $l (@lines) {
            if ($l =~ /\A\Q$name\E:\s*([0-9]+(?:\.[0-9]+)?)\s*\z/i) { push @hdr, $1 + 0; push @diff, $ms - $1; last; }
        }
    }
    # position ceil(p x n) of the sorted list, with integers only: no rounding surprise at the boundaries
    sub pct {
        my ($v, $p) = @_;
        my @s = sort { $a <=> $b } @$v;
        my $n = scalar @s;
        my $k = int(($p * $n + 99) / 100);
        $k = 1 if $k < 1;
        $k = $n if $k > $n;
        return $s[$k - 1];
    }
    sub row { my ($label, $v) = @_; printf "%-26s %10.2f %10.2f %10.2f\n", $label, pct($v, 50), pct($v, 95), pct($v, 99); }
    printf "bench: GET %s\n", $url;
    if (!@total) { print "no request gave a usable time\n"; exit 1; }
    printf "requests: %d timed, after %d warm-up (not counted)\n", scalar(@total), $warm;
    printf "%-26s %10s %10s %10s\n", "milliseconds", "p50", "p95", "p99";
    row("total", \@total);
    my $status = 0;
    if (length $name) {
        if (@hdr) {
            row($name, \@hdr);
            row("total - $name", \@diff);
            printf "note: only %d of %d responses carried %s\n", scalar(@hdr), scalar(@total), $name if @hdr < @total;
        } else {
            print "$name: no response carried this header\n";
            $status = 1;
        }
    }
    exit $status;
' "$RAW" "$HEADER" "$URL" "$WARMUP" | tee "$REPORT" || rc=$?
rm -f "$RAW"
echo "bench: report kept in $REPORT"
exit "$rc"
