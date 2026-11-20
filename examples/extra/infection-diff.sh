#!/usr/bin/env bash
# Infection (mutation testing) on the files of one module that changed, run on the server, inside the lock.
# Usage: infection-diff.sh <module> [<file> ...]      files are relative to the module's folder: src/Service/Foo.php
#   module   a name from CI_MODULES of stack.conf (every <SYNC_DIR>/<name>/<name>.php found when that list is empty).
#   file     a PHP source under src/ that exists. Without files: the PHP files of src/ that are added or modified compared
#            with BASE_BRANCH, from git on this machine (git diff --relative --name-only --diff-filter=AM <BASE_BRANCH>).
#            If none changed, the script says so and stops: an empty filter would make Infection run the whole suite.
# Environment (all optional):
#   BASE_BRANCH        the branch to compare with (default main)
#   INFECTION_THREADS  1 to 99 (default 4); the server is shared, keep it small
#   INFECTION_PHP      a PHP version of TOOLS_PHP_VERSIONS (default DEFAULT_PHP); pcov, which gives Infection its code coverage, is in the tools image
#   INFECTION_LOG      the text log that the module's infection.json5 declares in "logs": {"text": ...}, relative to the module's
#                      folder (default infection.log). The module needs Infection in its composer.json (vendor/bin/infection) and an infection.json5.
# What it does: synchronises the code (sync.sh), then, on the server inside the lock, runs in the module's folder
#   vendor/bin/infection --filter=<files> --threads=<n> --min-msi=0 --min-covered-msi=0 --no-progress
# (the criterion is the list of escaped mutants, not the score), copies the log to <project root>/<LOCAL_TMP_DIR>/infection/<module>/
# and prints the escaped mutants with file and line. The exit status is Infection's. Written for bash 3.2; it is an example of a
# script of the extra/ folder (README.md, section "Writing your own script"): copy it there and change what you need.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd -P)"   # the folder of the stack scripts (stack.conf, lib.sh, locked.sh)
# shellcheck source=../lib.sh
. "$HERE/lib.sh"
stack_load "$HERE"
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[ $# -ge 1 ] || { usage >&2; exit 2; }

# Everything below ends up in a command run on the server or handed to git: closed lists or strict patterns, checked first.
MOD="$1"; shift
valid_ci_module "$MOD" || die "invalid module name: \"$MOD\""
_allowed="$(ci_module_names)"
# shellcheck disable=SC2086
in_list "$MOD" $_allowed || die "module not allowed: $MOD (allowed: ${_allowed:-none found})"
BASE_BRANCH="${BASE_BRANCH:-main}"
THREADS="${INFECTION_THREADS:-4}"
PHP="${INFECTION_PHP:-$DEFAULT_PHP}"
LOG="${INFECTION_LOG:-infection.log}"
[[ "$BASE_BRANCH" =~ ^[A-Za-z0-9._/-]+$ && "$BASE_BRANCH" != -* && "$BASE_BRANCH" != *..* ]] || die "invalid BASE_BRANCH: \"$BASE_BRANCH\""
[[ "$THREADS" =~ ^[0-9]{1,2}$ ]] && [ "$((10#$THREADS))" -ge 1 ] || die "invalid INFECTION_THREADS: \"$THREADS\" (1 to 99)"
THREADS=$((10#$THREADS))
valid_php "$PHP" || die "invalid INFECTION_PHP: \"$PHP\""
# shellcheck disable=SC2086
in_list "$PHP" $TOOLS_PHP_VERSIONS || die "PHP $PHP is not in the tools image (TOOLS_PHP_VERSIONS: $TOOLS_PHP_VERSIONS)"
valid_relpath "$LOG" || die "invalid INFECTION_LOG: \"$LOG\" (a relative path inside the module's folder)"
_tmp_re='^[A-Za-z0-9._][A-Za-z0-9._/-]*$'
[[ "$LOCAL_TMP_DIR" =~ $_tmp_re && "$LOCAL_TMP_DIR" != *..* ]] || die "invalid LOCAL_TMP_DIR in stack.conf: $LOCAL_TMP_DIR"

_file_re='^src/[A-Za-z0-9_/-]+\.php$'
FILES=""; COUNT=0
add_file() { # add_file <path>: one file of src/, relative to the module's folder, checked and added to the filter
    local f="$1"
    [[ "$f" =~ $_file_re && "$f" != *//* ]] || die "invalid file: \"$f\" (a PHP source under src/, relative to the module's folder: src/Foo/Bar.php)"
    [ -f "$REPO_DIR/$MOD/$f" ] && [ ! -L "$REPO_DIR/$MOD/$f" ] || die "file not found: $SYNC_DIR/$MOD/$f"
    FILES="${FILES:+$FILES,}$f"; COUNT=$((COUNT + 1))
}
if [ $# -gt 0 ]; then
    for _f in "$@"; do add_file "$_f"; done
else
    # a failing git must stop the script: a wrong BASE_BRANCH is not "no file changed"
    _changed="$(git -C "$REPO_DIR/$MOD" diff --relative --name-only --diff-filter=AM "$BASE_BRANCH" -- ':(glob)src/**/*.php')" \
        || die "git could not compare $SYNC_DIR/$MOD with $BASE_BRANCH (is it a branch of the repository?)"
    while IFS= read -r _f; do
        [ -z "$_f" ] || add_file "$_f"
    done <<< "$_changed"
fi
if [ "$COUNT" -eq 0 ]; then
    echo "infection-diff: no PHP file of $MOD/src differs from $BASE_BRANCH, nothing to run (an empty filter would run everything)"
    exit 0
fi
echo "infection-diff: $MOD, $COUNT file(s), $THREADS thread(s), PHP $PHP"

"$HERE/sync.sh" > /dev/null
OUT="$ROOT/$LOCAL_TMP_DIR/infection/$MOD"
mkdir -p "$OUT"
rm -f "$OUT/infection.log" "$OUT/last-run.txt"
# the old log is removed first on the server: if Infection stops before it writes one, the log of the previous run is not read
JOB="set -euo pipefail; cd /repo/$SYNC_DIR/$MOD; export PATH=/opt/php/$PHP:\$PATH; [ -x vendor/bin/infection ] || composer install --no-interaction --prefer-dist --quiet; rm -f $LOG; vendor/bin/infection --filter=$FILES --threads=$THREADS --min-msi=0 --min-covered-msi=0 --no-progress"
rc=0
remote_locked "$JOB" > "$OUT/last-run.txt" 2>&1 < /dev/null || rc=$?

if ! rsync -az -e ssh "$HOST:/repo/$SYNC_DIR/$MOD/$LOG" "$OUT/infection.log"; then
    echo "infection-diff: Infection wrote no log ($LOG in the module's folder). The last lines of its output ($OUT/last-run.txt):" >&2
    tail -n 20 "$OUT/last-run.txt" >&2
    exit "$((rc == 0 ? 1 : rc))"
fi
grep -E 'mutations were generated|were killed|not covered|not detected|errors were|syntax errors|time outs|Mutation Score Indicator|Covered Code MSI|Mutation Code Coverage' "$OUT/last-run.txt" || true
# The escaped mutants: file:line, the mutator, and the changed lines. The section ends where the next one (Timed Out, Skipped ...) starts.
perl -e '
    my ($log, $prefix) = @ARGV;
    open(my $fh, "<", $log) or exit 0;
    local $/;
    my $text = <$fh>;
    my ($section) = $text =~ /^Escaped mutants:\n=*\n(.*?)(?=^[A-Z][A-Za-z ]* mutants:\n|\z)/ms;
    if (!defined $section) { print "no escaped mutant\n"; exit 0; }
    my $n = 0;
    for my $entry (split /\n(?=\d+\) \/repo\/)/, "\n$section") {
        my ($head, @rest) = split /\n/, $entry;
        next unless defined $head && $head =~ m{^\d+\) \Q$prefix\E(\S+?):(\d+)\s+\[M\] (\S+)};
        print "$1:$2 $3\n";
        $n++;
        for my $line (@rest) {
            next unless $line =~ /^[-+]/ && $line !~ /^(?:---|\+\+\+)/;
            print "   " . substr($line, 0, 200) . "\n";
        }
    }
    print "no escaped mutant\n" unless $n;
' "$OUT/infection.log" "/repo/$SYNC_DIR/$MOD/"
echo "infection-diff: log in $OUT/infection.log"
exit "$rc"
