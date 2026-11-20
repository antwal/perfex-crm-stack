#!/usr/bin/env bash
# Tests release-notes.sh with small changelogs written here: the notes of a closed version (exact bytes, with the fixed last
# line), a fenced "## " that is not a heading, the link definitions and the blank lines cut from the end, a file with CRLF
# line ends; the refusals (an [Unreleased] on top, a version that is not on top, an empty section, a file with no section,
# a bad version, a missing file, bad arguments); and --check (a good file, a heading that is neither [Unreleased] nor a
# version, [Unreleased] not first or twice, versions out of order, an empty section, an empty [Unreleased]).
# No network and no git: a folder of files, removed at the end. The workflow runs it on every push and pull request.
# Usage: bash .github/scripts/release-notes-test.sh      (exit status 1 when a case fails; files go to $TMPDIR, or /tmp)
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
SCRIPT="$HERE/release-notes.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/release-notes-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

FOOTER='Perfex CRM is not part of this repository: bring your own licensed copy.'
fail=0
bad() { echo "FAIL: $*"; fail=1; }
good() { echo "ok: $*"; }
notes() { bash "$SCRIPT" "$WORK/$1" "$2" > "$WORK/out" 2> "$WORK/err"; st=$?; }   # notes <file> <version>
check() { bash "$SCRIPT" --check "$WORK/$1" > "$WORK/out" 2> "$WORK/err"; st=$?; } # check <file>
# refused <what> <status> <text>: the last run failed with that status, printed nothing, and its message says <text>
refused() {
    if [ "$st" -ne "$2" ]; then bad "$1: exit $st, expected $2 ($(cat "$WORK/err"))"
    elif [ -s "$WORK/out" ]; then bad "$1: refused, but something was printed"
    elif ! grep -qF -- "$3" "$WORK/err"; then bad "$1: the message does not say '$3': $(cat "$WORK/err")"
    else good "$1"; fi
}
# same <what> <expected file>: the last run succeeded and printed exactly that file
same() {
    if [ "$st" -ne 0 ]; then bad "$1: exit $st ($(cat "$WORK/err"))"
    elif ! cmp -s "$WORK/out" "$WORK/$2"; then bad "$1: the output differs from the expected one"; diff "$WORK/$2" "$WORK/out"
    else good "$1"; fi
}

# ---- the files -----------------------------------------------------------------------------------------------------------------
cat > "$WORK/closed.md" <<'EOF'
# Changelog

The changes of each version, in the format of Keep a Changelog.

## [0.3.0]

### Changed

- The first entry, on two lines:
  the second line of the first entry.

```text
## not a heading: inside a fence
```

### Added

- The second entry, with `code` and a [link](https://example.invalid/).

## [0.2.0]

~~~
## not a heading either
~~~

- The only entry of 0.2.0.

## [0.1.0]

- The first version.

[0.3.0]: https://example.invalid/compare/v0.2.0...v0.3.0
[0.2.0]: https://example.invalid/compare/v0.1.0...v0.2.0
[0.1.0]: https://example.invalid/releases/tag/v0.1.0
EOF
cat > "$WORK/closed.expected" <<EOF
### Changed

- The first entry, on two lines:
  the second line of the first entry.

\`\`\`text
## not a heading: inside a fence
\`\`\`

### Added

- The second entry, with \`code\` and a [link](https://example.invalid/).

$FOOTER
EOF
cat > "$WORK/oldest.md" <<'EOF'
## [0.1.0]

- The first version.


[0.1.0]: https://example.invalid/releases/tag/v0.1.0
EOF
cat > "$WORK/oldest.expected" <<EOF
- The first version.

$FOOTER
EOF
cat > "$WORK/unreleased.md" <<'EOF'
## [Unreleased]

- Work in progress.

## [0.3.0]

- The entry of 0.3.0.
EOF
cat > "$WORK/empty.md" <<'EOF'
## [0.3.0]


## [0.2.0]

- The entry of 0.2.0.
EOF
printf '# Changelog\r\n\r\n## [0.3.0]\r\n\r\n- One entry.\r\n- Two entries.\r\n\r\n## [0.2.0]\r\n\r\n- Old.\r\n' > "$WORK/crlf.md"
cat > "$WORK/crlf.expected" <<EOF
- One entry.
- Two entries.

$FOOTER
EOF
printf '# A file with no section\n\nSome text.\n' > "$WORK/nosection.md"
cat > "$WORK/badheading.md" <<'EOF'
## Version 0.3.0

- An entry.
EOF
cat > "$WORK/unreleased-second.md" <<'EOF'
## [0.3.0]

- An entry.

## [Unreleased]

- Another.
EOF
cat > "$WORK/unreleased-twice.md" <<'EOF'
## [Unreleased]

- An entry.

## [Unreleased]

- Another.
EOF
cat > "$WORK/order.md" <<'EOF'
## [0.2.0]

- An entry.

## [0.3.0]

- Another.
EOF
cat > "$WORK/order-same.md" <<'EOF'
## [0.3.0]

- An entry.

## [0.3.0]

- Another.
EOF
cat > "$WORK/order-numeric.md" <<'EOF'
## [0.10.0]

- Ten, which is newer than nine.

## [0.9.0]

- Nine.
EOF
cat > "$WORK/empty-unreleased.md" <<'EOF'
## [Unreleased]

## [0.3.0]

- An entry.
EOF

# ---- the notes -----------------------------------------------------------------------------------------------------------------
echo "--- notes"
notes closed.md 0.3.0;      same "the newest section, without the heading, the fence kept, the fixed last line added" closed.expected
notes oldest.md 0.1.0;      same "the only section: the link definitions and the blank lines before them are cut" oldest.expected
notes crlf.md 0.3.0;        same "CRLF line ends are accepted and written as LF" crlf.expected
notes unreleased.md 0.3.0;  refused "an [Unreleased] on top: no notes for 0.3.0" 1 "[Unreleased]"
grep -q "close the version 0.3.0" "$WORK/err" && good "the message says how to close the version" || bad "the message does not say how to close the version: $(cat "$WORK/err")"
notes closed.md 0.2.0;      refused "a version that is not the newest one" 1 "not [0.2.0]"
notes closed.md 0.4.0;      refused "a version the changelog does not have" 1 "not [0.4.0]"
notes empty.md 0.3.0;       refused "an empty section" 1 "is empty"
notes nosection.md 0.3.0;   refused "a file without sections" 1 "has no"
notes closed.md 0.3;        refused "a version that is not X.Y.Z" 2 "not a version"
notes closed.md v0.3.0;     refused "a version with the v of the tag" 2 "not a version"
notes missing.md 0.3.0;     refused "a missing file" 2 "cannot read"
bash "$SCRIPT" > "$WORK/out" 2> "$WORK/err"; st=$?;                              refused "no arguments" 2 "usage"
bash "$SCRIPT" "$WORK/closed.md" > "$WORK/out" 2> "$WORK/err"; st=$?;            refused "one argument" 2 "usage"
bash "$SCRIPT" --check "$WORK/closed.md" 0.3.0 > "$WORK/out" 2> "$WORK/err"; st=$?; refused "--check with a version" 2 "usage"

# ---- the check -----------------------------------------------------------------------------------------------------------------
echo "--- check"
check closed.md
if [ "$st" -eq 0 ] && grep -q "3 sections, the newest is \[0.3.0\]" "$WORK/out"; then good "a closed changelog passes and the summary counts its sections"; else bad "a closed changelog: exit $st, $(cat "$WORK/out" "$WORK/err")"; fi
check unreleased.md
if [ "$st" -eq 0 ] && grep -q "the newest is \[Unreleased\]" "$WORK/out"; then good "an [Unreleased] on top with an entry passes the check (it is the notes that refuse it)"; else bad "an [Unreleased] on top: exit $st, $(cat "$WORK/out" "$WORK/err")"; fi
check oldest.md
if [ "$st" -eq 0 ]; then good "a section followed by link definitions only is not empty"; else bad "link definitions: exit $st, $(cat "$WORK/err")"; fi
check order-numeric.md
if [ "$st" -eq 0 ]; then good "0.10.0 is newer than 0.9.0 (numeric order, not text order)"; else bad "numeric order: exit $st, $(cat "$WORK/err")"; fi
check badheading.md;        refused "a heading that is neither [Unreleased] nor a version" 1 "neither [Unreleased] nor [X.Y.Z]"
check unreleased-second.md; refused "[Unreleased] after a version" 1 "must be the first section"
check unreleased-twice.md;  refused "[Unreleased] twice" 1 "must be the first section"
check order.md;             refused "an older version before a newer one" 1 "from the newest to the oldest"
check order-same.md;        refused "the same version twice" 1 "from the newest to the oldest"
check empty.md;             refused "an empty version section" 1 "[0.3.0] of"
check empty-unreleased.md;  refused "an empty [Unreleased]" 1 "[Unreleased] of"
check nosection.md;         refused "a file without sections" 1 "has no"
check missing.md;           refused "a missing file" 2 "cannot read"

if [ "$fail" -ne 0 ]; then echo "release-notes-test: FAILED"; exit 1; fi
echo "release-notes-test: all green"
