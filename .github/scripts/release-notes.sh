#!/usr/bin/env bash
# The release notes of one version of the template, cut from CHANGELOG.md, and the check of the form of the changelog.
# The workflow .github/workflows/release.yml runs this script to write the body of the GitHub Release of a tag vX.Y.Z; run it
# yourself before the tag and you see the same bytes. bash 3.2 and the awk of macOS are enough; no other tool is used.
#
#   release-notes.sh <CHANGELOG.md> <X.Y.Z>   prints the section "## [X.Y.Z]" of the changelog: everything between its heading
#                                             and the next "## " heading, without the heading itself, the blank lines at both
#                                             ends and the link definitions ("[x]: url") that close the file; then a blank line
#                                             and the fixed last line about the license of Perfex CRM.
#   release-notes.sh --check <CHANGELOG.md>   checks the form of the whole changelog and prints nothing but a summary.
#
# The notes fail (exit 1, nothing on the standard output) when the newest section of the changelog is not "## [X.Y.Z]": a version
# is closed by renaming "## [Unreleased]" into its number in the last commit before the tag, so a tag put before that, or on another
# version than the one on top, gets no Release. They fail too when the section is empty.
# The check fails (exit 1) when a "## " heading is neither "[Unreleased]" nor "[X.Y.Z]", when "[Unreleased]" is not the first section
# or appears twice, when the versions do not go from the newest to the oldest, or when a section is empty (an empty "[Unreleased]"
# too: remove it, or put an entry in it). Lines inside a fenced code block (``` or ~~~) are never taken for a heading.
# Exit 2 is a mistake in the arguments or an unreadable file.
set -euo pipefail

FOOTER='Perfex CRM is not part of this repository: bring your own licensed copy.'

usage() {
    echo "usage: release-notes.sh <CHANGELOG.md> <X.Y.Z>" >&2
    echo "       release-notes.sh --check <CHANGELOG.md>" >&2
    exit 2
}

mode=notes
version=""
if [ "${1:-}" = "--check" ]; then
    mode=check
    shift
    [ $# -eq 1 ] || usage
else
    [ $# -eq 2 ] || usage
    version="$2"
    if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "release-notes: '$version' is not a version (X.Y.Z)" >&2
        exit 2
    fi
fi
file="$1"
if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "release-notes: cannot read $file" >&2
    exit 2
fi

awk -v mode="$mode" -v version="$version" -v footer="$FOOTER" -v file="$file" '
function fail(message) {
    print "release-notes: " message > "/dev/stderr"
    exit 1
}
# trim_section(i) sets FIRST and LAST: the lines of section i without the blank lines at both ends and without the link
# definitions that close the file (they belong to no section).
function trim_section(i,    first, last) {
    first = 1
    last = len[i]
    while (last >= first && (body[i, last] ~ /^[[:space:]]*$/ || body[i, last] ~ /^\[[^]]+\]:[[:space:]]*[^[:space:]]/)) last--
    while (first <= last && body[i, first] ~ /^[[:space:]]*$/) first++
    FIRST = first
    LAST = last
}
function is_version(name) { return name ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ }
# newer(a, b) is 1 when the version a is newer than the version b
function newer(a, b,    pa, pb, k) {
    split(a, pa, ".")
    split(b, pb, ".")
    for (k = 1; k <= 3; k++) {
        if (pa[k] + 0 > pb[k] + 0) return 1
        if (pa[k] + 0 < pb[k] + 0) return 0
    }
    return 0
}
BEGIN { n = 0; fence = 0 }
{
    line = $0
    sub(/\r$/, "", line)
    if (line ~ /^(```|~~~)/) {
        fence = !fence
    } else if (!fence && line ~ /^## /) {
        n++
        name[n] = ""
        if (match(line, /^## \[[^]]+\]/)) name[n] = substr(line, 5, RLENGTH - 5)
        heading[n] = line
        row[n] = NR
        len[n] = 0
        next
    }
    if (n > 0) { len[n]++; body[n, len[n]] = line }
}
END {
    if (n == 0) fail(file " has no \"## \" section")
    if (mode == "check") {
        for (i = 1; i <= n; i++) {
            if (name[i] == "Unreleased") {
                if (i != 1) fail("line " row[i] ": [Unreleased] must be the first section of " file ", and the only one")
            } else if (!is_version(name[i])) {
                fail("line " row[i] ": the heading \"" heading[i] "\" is neither [Unreleased] nor [X.Y.Z]")
            }
            trim_section(i)
            if (FIRST > LAST) fail("line " row[i] ": the section [" name[i] "] of " file " is empty")
        }
        previous = ""
        for (i = 1; i <= n; i++) {
            if (name[i] == "Unreleased") continue
            if (previous != "" && !newer(previous, name[i])) fail("line " row[i] ": [" name[i] "] comes after [" previous "]: the versions go from the newest to the oldest")
            previous = name[i]
        }
        print file ": " n " sections, the newest is [" name[1] "]"
        exit 0
    }
    if (name[1] == "Unreleased") fail("the newest section of " file " is [Unreleased]: close the version " version " (rename the heading) before its notes can be written")
    if (name[1] != version) fail("the newest section of " file " is [" name[1] "], not [" version "]")
    trim_section(1)
    if (FIRST > LAST) fail("the section [" version "] of " file " is empty")
    for (k = FIRST; k <= LAST; k++) print body[1, k]
    print ""
    print footer
}
' "$file"
