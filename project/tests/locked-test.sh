#!/usr/bin/env bash
# Tests run.sh and locked.sh without a server, in two parts.
#
# Part 1, run.sh, with a fake ssh that only records its calls: the SSH alias is checked, and the command you pass reaches
# locked.sh as ONE argument, whatever it contains (quotes, semicolons, $(...)): the recorded remote command is parsed back
# by a shell to prove it. Nothing is called when the arguments are wrong. Before the command, run.sh may make one more call
# to the alias, the probe that checks locked.sh is on the server (the fake answers yes, so no copy follows).
#
# Part 2, locked.sh itself, on this machine. macOS has no flock and no setsid, so two small stand-ins (perl) are put first
# in PATH: flock takes an exclusive lock and keeps the lock file open in the command it starts, as the real one does,
# and setsid starts the command in a session of its own. With them the script is run for real and checked for: usage errors,
# the exit status, the standard input, a leftover background process being terminated (and not keeping the lock), and two
# jobs running one after the other. It tests the logic of locked.sh, not the flock of your server.
#
# Usage: bash <this folder>/tests/locked-test.sh      (exit status 1 at the first failure)
# Files go to <project root>/<LOCAL_TMP_DIR>/stack-tests/locked-test (or STACK_TESTS_WORK/locked-test).
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
DOCKER_DIR="$(cd "$HERE/.." && pwd -P)"
# shellcheck source=../stack.conf
. "$DOCKER_DIR/stack.conf"
ROOT="$(cd "$DOCKER_DIR/$PROJECT_ROOT_REL" && pwd -P)"
WORK="${STACK_TESTS_WORK:-$ROOT/$LOCAL_TMP_DIR/stack-tests}/locked-test"
command -v perl >/dev/null || { echo "perl is needed for the stand-ins of flock and setsid"; exit 1; }

rm -rf "$WORK"
mkdir -p "$WORK/bin" "$WORK/shims" "$WORK/docker"
cp "$DOCKER_DIR/run.sh" "$DOCKER_DIR/lib.sh" "$DOCKER_DIR/locked.sh" "$WORK/docker/"
sed -e 's#^PROJECT_ROOT_REL=.*#PROJECT_ROOT_REL=".."#' "$DOCKER_DIR/stack.conf" > "$WORK/docker/stack.conf"

fail=0
bad() { echo "FAIL: $*"; fail=1; }
good() { echo "ok: $*"; }

# ---- Part 1: run.sh -------------------------------------------------------------------------------------------------------------
cat > "$WORK/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
printf 'ssh' >> "$STACK_TEST_CALLS"
for a in "$@"; do printf ' [%s]' "$a" >> "$STACK_TEST_CALLS"; done
printf '\n' >> "$STACK_TEST_CALLS"
printf '%s' "$2" > "$STACK_TEST_ARG2"
cat > "$STACK_TEST_STDIN"
FAKE
chmod +x "$WORK/bin/ssh"
CALLS="$WORK/calls"; ARG2="$WORK/arg2"; STDIN="$WORK/stdin"
runsh() { # runsh <ssh alias> <run.sh arguments...>: sets STATUS
    local alias="$1"; shift
    : > "$CALLS"; : > "$ARG2"; : > "$STDIN"
    PATH="$WORK/bin:$PATH" STACK_SSH="$alias" STACK_TEST_CALLS="$CALLS" STACK_TEST_ARG2="$ARG2" STACK_TEST_STDIN="$STDIN" \
        bash "$WORK/docker/run.sh" "$@" > "$WORK/out" 2>&1 < "${RUN_STDIN:-/dev/null}"
    STATUS=$?
}
expect_refused() { # expect_refused <label> <ssh alias> <run.sh arguments...>
    local label="$1"; shift
    runsh "$@"
    if [ "$STATUS" -eq 0 ] || [ -s "$CALLS" ]; then bad "run.sh: $label was not refused (status $STATUS, calls: $(cat "$CALLS"))"; else good "run.sh: $label refused, no call made"; fi
}
echo "--- part 1: run.sh"
expect_refused "no command"                     "$SSH_ALIAS"
expect_refused "an empty command"               "$SSH_ALIAS" ''
expect_refused "two arguments"                  "$SSH_ALIAS" 'echo a' 'echo b'
expect_refused "an SSH alias that is an option" '-oProxyCommand=touch_pwned' 'echo a'
expect_refused "an SSH alias with a command"    "$SSH_ALIAS;id" 'echo a'

for cmd in 'echo hello' 'echo "a b"; id' "printf '%s' \"it's\" \$(date) \`id\`" 'cd /repo/x && PATH=/opt/php/8.4:$PATH composer test:int'; do
    runsh "$SSH_ALIAS" "$cmd"
    if [ "$STATUS" -ne 0 ]; then bad "run.sh: a valid command failed: $(cat "$WORK/out")"; continue; fi
    # one call runs the command through locked.sh; the only other call allowed is the probe that checks locked.sh is on the server
    if [ "$(grep -cF "ssh [$SSH_ALIAS] [bash " "$CALLS" | tr -d ' ')" -ne 1 ] || grep -vF "ssh [$SSH_ALIAS] " "$CALLS" | grep -q . || [ "$(wc -l < "$CALLS" | tr -d ' ')" -gt 2 ]; then bad "run.sh: expected one locked call to the alias (plus, at most, the probe for locked.sh): $(cat "$CALLS")"; continue; fi
    # parse the remote command back with a shell: "bash <locked.sh> <command>" must be exactly three words
    parsed="$(bash -c 'eval "set -- ${1#bash }"; printf "%s\n" "$#"; printf "%s\n" "$1"; printf "%s" "$2"' _ "$(cat "$ARG2")")"
    if [ "$(printf '%s\n' "$parsed" | sed -n 1p)" != 2 ]; then bad "run.sh: the command did not stay one argument: $(cat "$ARG2")"; continue; fi
    if [ "$(printf '%s\n' "$parsed" | sed -n 2p)" != "$LOCKED_SH" ]; then bad "run.sh: locked.sh is not the path of stack.conf: $(cat "$ARG2")"; continue; fi
    if [ "$(printf '%s\n' "$parsed" | sed '1,2d')" != "$cmd" ]; then bad "run.sh: the command changed on the way: $parsed"; continue; fi
    good "run.sh: \"$cmd\" arrives as one argument of $LOCKED_SH"
done
printf 'piped data' > "$WORK/input"
RUN_STDIN="$WORK/input" runsh "$SSH_ALIAS" 'cat'
if [ "$(cat "$STDIN")" = "piped data" ]; then good "run.sh: the standard input reaches the remote command"; else bad "run.sh: the standard input was lost"; fi

# ---- Part 2: locked.sh -----------------------------------------------------------------------------------------------------------
cat > "$WORK/shims/flock" <<'SHIM'
#!/usr/bin/env perl
# stand-in for flock(1): flock [-w <seconds>] <lock file> <command...>. Waits as long as needed; keeps the lock file open in the command.
use strict; use warnings; use Fcntl qw(:flock);
$^F = 255;
my @a = @ARGV;
if (@a && $a[0] eq '-w') { shift @a; shift @a; }
my $lock = shift @a;
open(my $fh, '>>', $lock) or die "flock stand-in: cannot open $lock: $!\n";
flock($fh, LOCK_EX) or die "flock stand-in: $!\n";
my $pid = fork();
die "flock stand-in: fork: $!\n" unless defined $pid;
if ($pid == 0) { exec { $a[0] } @a or die "flock stand-in: exec $a[0]: $!\n"; }
waitpid($pid, 0);
exit($? >> 8);
SHIM
cat > "$WORK/shims/setsid" <<'SHIM'
#!/usr/bin/env perl
# stand-in for setsid(1): setsid [-w] <command...>. Starts the command in a new session (its own process group) and waits for it.
use strict; use warnings; use POSIX ();
my @a = @ARGV;
if (@a && $a[0] eq '-w') { shift @a; }
my $pid = fork();
die "setsid stand-in: fork: $!\n" unless defined $pid;
if ($pid == 0) { POSIX::setsid(); exec { $a[0] } @a or die "setsid stand-in: exec $a[0]: $!\n"; }
waitpid($pid, 0);
exit($? >> 8);
SHIM
chmod +x "$WORK/shims/flock" "$WORK/shims/setsid"

LOCKED="$WORK/docker/locked.sh"
export STACK_LOCK_FILE="$WORK/lock/sub/ci.lock"      # the folder does not exist: locked.sh must create it
export LOG="$WORK/log" PIDFILE="$WORK/pid"
locked() { PATH="$WORK/shims:$PATH" perl -e 'alarm shift @ARGV; exec @ARGV or die "exec: $!\n"' 20 bash "$LOCKED" "$@"; }

echo "--- part 2: locked.sh"
locked > "$WORK/out" 2>&1;               st=$?; if [ "$st" -eq 2 ] && grep -q usage "$WORK/out"; then good "locked.sh: no argument is a usage error (2)"; else bad "locked.sh: no argument gave status $st"; fi
locked '' > "$WORK/out" 2>&1;            st=$?; if [ "$st" -eq 2 ]; then good "locked.sh: an empty command is a usage error (2)"; else bad "locked.sh: an empty command gave status $st"; fi
locked 'echo a' 'echo b' > "$WORK/out" 2>&1; st=$?; if [ "$st" -eq 2 ]; then good "locked.sh: two arguments are a usage error (2)"; else bad "locked.sh: two arguments gave status $st"; fi
out="$(locked 'echo ran')"
if [ "$out" = ran ] && [ -d "$WORK/lock/sub" ]; then good "locked.sh: runs the command and creates the lock folder"; else bad "locked.sh: expected 'ran', got '$out'"; fi
locked 'exit 7' > /dev/null 2>&1; st=$?
if [ "$st" -eq 7 ]; then good "locked.sh: the exit status is the command's (7)"; else bad "locked.sh: the exit status was $st, not 7"; fi
out="$(printf 'hello' | locked 'cat')"
if [ "$out" = hello ]; then good "locked.sh: the standard input reaches the command"; else bad "locked.sh: the standard input was lost ('$out')"; fi

# a background process left behind is terminated when the command ends, and does not keep the lock
: > "$PIDFILE"
locked 'sleep 60 > /dev/null 2>&1 & echo $! > "$PIDFILE"' > /dev/null 2>&1; st=$?
pid="$(cat "$PIDFILE")"
alive=1; i=0
while [ "$i" -lt 30 ]; do kill -0 "$pid" 2>/dev/null || { alive=0; break; }; sleep 0.1 2>/dev/null || sleep 1; i=$((i + 1)); done
if [ "$st" -eq 0 ] && [ "$alive" -eq 0 ]; then good "locked.sh: a process left in the background is terminated"; else bad "locked.sh: the background process $pid is still alive (status $st)"; kill "$pid" 2>/dev/null; fi
out="$(locked 'echo free')"
if [ "$out" = free ]; then good "locked.sh: the lock is free after a command that left a process behind"; else bad "locked.sh: the lock was not released ('$out')"; fi

# two jobs: the second waits for the first
: > "$LOG"
locked 'echo A-start >> "$LOG"; sleep 2; echo A-end >> "$LOG"' > /dev/null 2>&1 &
first=$!
i=0
while [ "$i" -lt 40 ] && ! grep -q A-start "$LOG"; do sleep 0.1 2>/dev/null || sleep 1; i=$((i + 1)); done
locked 'echo B >> "$LOG"' > /dev/null 2>&1
wait "$first"
if [ "$(tr '\n' ' ' < "$LOG")" = "A-start A-end B " ]; then good "locked.sh: a second job waits for the first (A-start A-end B)"; else bad "locked.sh: order of the jobs was: $(tr '\n' ' ' < "$LOG")"; fi

[ "$fail" -eq 0 ] && echo "=== locked-test: all ok ===" || echo "=== locked-test: FAILED ==="
exit "$fail"
