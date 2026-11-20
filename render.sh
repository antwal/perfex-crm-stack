#!/usr/bin/env bash
# Validates a parameter file and writes the PROJECT FOLDER: the scripts, stack.conf, portainer.env and the documents
# with your values in them. It never writes stack/ (the compose file and the Dockerfiles are used as they are).
#
# Usage: render.sh <params.env> [<project root>] [--force]    write <project root>/<DEST_DIR> (default root: current folder)
#        render.sh --check <params.env>                        validate only, write nothing
#
# Without --force it refuses to write into a folder that is not empty; with --force it overwrites only the files it
# generates. The parameter file is sourced by bash: it is code, keep it yours. No secrets in it.
# Runs on bash 3.2 (macOS) and needs perl (present on macOS and on every Linux).
set -euo pipefail
_tpl="$(cd "$(dirname "$0")" && pwd -P)"
usage() {
    cat <<'EOT'
Usage: render.sh <params.env> [<project root>] [--force]    write <project root>/<DEST_DIR> (default root: current folder)
       render.sh --check <params.env>                        validate only, write nothing
EOT
}

_check=0; _force=0; _params=""; _root=""
for _arg in "$@"; do
    case "$_arg" in
        --check) _check=1 ;;
        --force) _force=1 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "unknown option: $_arg" >&2; usage >&2; exit 2 ;;
        *) if [ -z "$_params" ]; then _params="$_arg"; elif [ -z "$_root" ]; then _root="$_arg"; else echo "too many arguments" >&2; exit 2; fi ;;
    esac
done
[ -n "$_params" ] || { usage >&2; exit 2; }
[ -f "$_params" ] || { echo "parameter file not found: $_params" >&2; exit 2; }
command -v perl >/dev/null || { echo "perl is required (it ships with macOS and every Linux)" >&2; exit 2; }
[ -d "$_tpl/project" ] || { echo "the project/ folder of the template is missing next to render.sh" >&2; exit 2; }
_params="$(cd "$(dirname "$_params")" && pwd -P)/$(basename "$_params")"
if [ -n "$_root" ]; then [ -d "$_root" ] || { echo "project root not found: $_root" >&2; exit 2; }; fi
_root="$(cd "${_root:-$PWD}" && pwd -P)"

# ---- 1. parameters: unset every known name first, so nothing in the environment can stand in for a missing value -------
_ALL_PARAMS="PROJECT_LABEL STACK_NAME DOCKER_NETWORK APP_HOST TOOLS_HOST APP_URL SSH_ALIAS REMOTE_ROOT TZ WEB_PHP_VERSION IMAGE_OWNER \
WEB_IMAGE TOOLS_IMAGE TOOLS_PHP_VERSIONS TOOLS_NODE PASS_AUTHORIZATION TOOLS_CPUS TOOLS_MEM TOOLS_PIDS WEB_EXTRA_PHP_VERSION \
WEB_EXTRA_NAME WEB_EXTRA_HOST DEST_DIR LOCAL_TMP_DIR SYNC_DIR LOCK_FILE SYNC_EXCLUDES MODULES_DIR APP_TARGETS DEPLOY_MODULES \
DEPLOY_EXTRA DEPLOY_EXCLUDES DEV_MARKER CI_MODULES CI_CHECK_SCRIPT CI_STATIC_SCRIPT STATIC_TOOLS_DIR MATRIX_PHP_VERSIONS DEFAULT_PHP \
STATIC_PHP DEPLOY_PHP MAILPIT_URL MAILPIT_SMTP_HOST MAILPIT_SMTP_PORT INCLUDE_AI"
# shellcheck disable=SC2086
unset $_ALL_PARAMS
# A parameter file may refer to a value it forgot to define (APP_URL="http://${APP_HOST}"): the checks below report the
# missing value by its name, so bash's own "unbound variable" error must not get there first.
set +u
# shellcheck disable=SC1090
. "$_params"
set -u

# defaults (":=" also replaces an empty value; "=" keeps an empty value that is allowed)
: "${DOCKER_NETWORK:=containers}" "${TZ:=UTC}" "${WEB_PHP_VERSION:=8.4}"
: "${APP_URL:=http://${APP_HOST:-}}"
: "${TOOLS_PHP_VERSIONS:=8.1 8.2 8.3 8.4 8.5}" "${TOOLS_NODE:=0}" "${PASS_AUTHORIZATION:=0}"
# the words of a list, joined by single blanks: a leading blank, a tab or a double blank in the parameter file must not
# reach the image tag, stack.conf or the docker build command
_squeeze() { # _squeeze <name>
    local _w _out=""
    set -f
    for _w in ${!1}; do _out="${_out:+$_out }$_w"; done
    set +f
    printf -v "$1" '%s' "$_out"
}
_squeeze TOOLS_PHP_VERSIONS
# image names: [<IMAGE_OWNER>/]perfex-web:<WEB_PHP_VERSION> and [<IMAGE_OWNER>/]perfex-tools:<first>-<last of TOOLS_PHP_VERSIONS>
# (always both ends, so a single version gives perfex-tools:8.4-8.4)
: "${IMAGE_OWNER=}"
_first_php="${TOOLS_PHP_VERSIONS%% *}"; _last_php="$_first_php"
for _v in $TOOLS_PHP_VERSIONS; do _last_php="$_v"; done
_tools_tag="$_first_php-$_last_php"
: "${WEB_IMAGE:=${IMAGE_OWNER:+$IMAGE_OWNER/}perfex-web:${WEB_PHP_VERSION}}" "${TOOLS_IMAGE:=${IMAGE_OWNER:+$IMAGE_OWNER/}perfex-tools:$_tools_tag}"
: "${TOOLS_CPUS:=2}" "${TOOLS_MEM:=2g}" "${TOOLS_PIDS:=512}"
: "${WEB_EXTRA_PHP_VERSION=}" "${WEB_EXTRA_NAME=}" "${WEB_EXTRA_HOST=}"
: "${DEST_DIR:=tools/docker}" "${LOCAL_TMP_DIR:=.tmp}" "${SYNC_DIR:=modules}" "${LOCK_FILE:=/repo/.tmp/ci.lock}"
: "${SYNC_EXCLUDES=.git vendor/ node_modules/ .DS_Store *.zip *.sha256 .composer/ .phpunit.cache/}"
: "${MODULES_DIR=modules}" "${APP_TARGETS:=app}" "${DEPLOY_MODULES=}" "${DEPLOY_EXTRA=}"
: "${DEPLOY_EXCLUDES=/tests/ /phpunit* /.php-cs-fixer* .DS_Store}"
: "${DEV_MARKER=}" "${CI_MODULES=}" "${CI_CHECK_SCRIPT:=check}" "${CI_STATIC_SCRIPT=}" "${STATIC_TOOLS_DIR=}"
: "${MATRIX_PHP_VERSIONS:=8.3 8.4 8.5}" "${DEFAULT_PHP:=8.4}" "${STATIC_PHP:=$DEFAULT_PHP}" "${DEPLOY_PHP:=$DEFAULT_PHP}"
: "${MAILPIT_URL=}" "${MAILPIT_SMTP_HOST=}" "${MAILPIT_SMTP_PORT=}" "${INCLUDE_AI:=1}"
: "${PROJECT_LABEL:=}" "${STACK_NAME:=}" "${APP_HOST:=}" "${TOOLS_HOST:=}" "${SSH_ALIAS:=}" "${REMOTE_ROOT:=}"

# ---- 2. validation -------------------------------------------------------------------------------------------------------
_fail=0
err() { echo "ERROR    $*" >&2; _fail=1; }
warn() { echo "WARNING  $*" >&2; }
req() { local n; for n in "$@"; do [ -n "${!n:-}" ] || err "$n: missing or empty (required)"; done; }
match() { # match <name> <regex> [opt]   (opt: an empty value is allowed)
    local v="${!1:-}"
    if [ -z "$v" ] && [ "${3:-}" = "opt" ]; then return 0; fi
    [[ "$v" =~ $2 ]] || err "$1=\"$v\" does not match the format $2"
}
in_list() { local needle="$1" item; shift; for item in "$@"; do [ "$item" = "$needle" ] && return 0; done; return 1; }
# no_dots <name>: a relative path must not contain "..", "//" or end with "/"
no_dots() {
    local v="${!1:-}"
    [ -n "$v" ] || return 0
    case "$v" in */) err "$1=\"$v\": must not end with \"/\"" ;; esac
    v="${v#/}"
    case "/$v/" in */../*|*//*) err "$1=\"${!1}\": must not contain \"..\" or \"//\"" ;; esac
}
php_versions() { # php_versions <name>: every word is <major>.<minor>, at least one, 8.1 or later
    local v maj min n=0
    for v in ${!1:-}; do
        n=$((n + 1))
        if [[ "$v" =~ ^[0-9]+\.[0-9]+$ ]]; then
            maj="${v%%.*}"; min="${v#*.}"
            if [ "$maj" -lt 8 ] || { [ "$maj" -eq 8 ] && [ "$min" -lt 1 ]; }; then err "$1 contains $v: Perfex CRM 3.4 needs PHP 8.1 or later"; fi
            if [ "$maj" -gt 8 ] || { [ "$maj" -eq 8 ] && [ "$min" -gt 5 ]; }; then warn "$1 contains $v: the template was prepared for PHP 8.1 to 8.5"; fi
        else
            err "$1 contains \"$v\": expected <major>.<minor>, for example 8.4"
        fi
    done
    [ "$n" -gt 0 ] || err "$1: at least one PHP version is required"
}
words() { # words <name> <regex> <what>: every blank-separated word matches the regex (globs are NOT expanded)
    local w
    set -f
    for w in ${!1:-}; do [[ "$w" =~ $2 ]] || err "$1: \"$w\" is not a valid $3"; done
    set +f
}

_label='^[A-Za-z0-9][A-Za-z0-9 ._()-]*$'
_name='^[a-z0-9][a-z0-9_-]*$'
_host='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$'
_url='^https?://[A-Za-z0-9._~:/?&=%#@+,;-]+$'
_abs='^/[A-Za-z0-9._/-]+$'
_dir='^[A-Za-z0-9_][A-Za-z0-9._/-]*$'      # relative folder, no leading dot
_tmpdir='^[A-Za-z0-9._][A-Za-z0-9._/-]*$'  # relative folder, a leading dot is fine (.tmp)
_image='^[A-Za-z0-9][A-Za-z0-9._/:@-]*$'
_script='^[A-Za-z0-9:_-]+$'
_modname='^[a-z][a-z0-9_]{1,63}$'
_cimodname='^[a-z0-9][a-z0-9_-]{0,63}$'
_glob='^[A-Za-z0-9._*?/-]+$'

req PROJECT_LABEL STACK_NAME APP_HOST TOOLS_HOST SSH_ALIAS REMOTE_ROOT
match PROJECT_LABEL "$_label"
match STACK_NAME "$_name"
match DOCKER_NETWORK '^[A-Za-z0-9][A-Za-z0-9._-]*$'
match APP_HOST "$_host"; match TOOLS_HOST "$_host"
match APP_URL "$_url"
match SSH_ALIAS '^[A-Za-z0-9][A-Za-z0-9._-]*$'
match REMOTE_ROOT "$_abs"; no_dots REMOTE_ROOT
match TZ '^[A-Za-z0-9_+/-]+$'
match WEB_PHP_VERSION '^[0-9]+\.[0-9]+$'; php_versions WEB_PHP_VERSION
match IMAGE_OWNER '^[a-z0-9][a-z0-9._:/-]*[a-z0-9]$' opt
match WEB_IMAGE "$_image"; match TOOLS_IMAGE "$_image"
php_versions TOOLS_PHP_VERSIONS
match TOOLS_NODE '^[01]$'; match PASS_AUTHORIZATION '^[01]$'; match INCLUDE_AI '^[01]$'
match TOOLS_CPUS '^[0-9]+(\.[0-9]+)?$'; match TOOLS_MEM '^[0-9]+[bBkKmMgG]$'; match TOOLS_PIDS '^[0-9]+$'
# the second web instance is all or nothing
if [ -n "$WEB_EXTRA_PHP_VERSION$WEB_EXTRA_NAME$WEB_EXTRA_HOST" ]; then
    req WEB_EXTRA_PHP_VERSION WEB_EXTRA_NAME WEB_EXTRA_HOST
    match WEB_EXTRA_PHP_VERSION '^[0-9]+\.[0-9]+$'; php_versions WEB_EXTRA_PHP_VERSION
    match WEB_EXTRA_NAME "$_name"; match WEB_EXTRA_HOST "$_host"
fi
match DEST_DIR "$_dir"; no_dots DEST_DIR
match LOCAL_TMP_DIR "$_tmpdir"; no_dots LOCAL_TMP_DIR
match SYNC_DIR "$_dir"; no_dots SYNC_DIR
match LOCK_FILE '^/repo/[A-Za-z0-9._/-]+$'; no_dots LOCK_FILE
words SYNC_EXCLUDES "$_glob" "rsync exclude pattern (letters, digits, . _ - / * ?)"
match MODULES_DIR "$_dir" opt; no_dots MODULES_DIR
words APP_TARGETS '^[a-z0-9][a-z0-9_-]*$' "target name (lowercase letters, digits, - and _)"
[ -n "$APP_TARGETS" ] || err "APP_TARGETS: at least one target is required"
words DEPLOY_MODULES "$_modname" "module name (^[a-z][a-z0-9_]{1,63}\$)"
# DEPLOY_EXTRA: blank-separated pairs <folder relative to SYNC_DIR>:<name>; the name is the folder in the application and the
# word deploy.sh takes, it must be a module name that DEPLOY_MODULES and the other pairs do not use
_extra_names=""
set -f
for _w in $DEPLOY_EXTRA; do
    case "$_w" in
        *:*:*|:*|*:) err "DEPLOY_EXTRA: \"$_w\" is not <folder>:<name> (exactly one colon, a folder before it and a name after it)"; continue ;;
        *:*) ;;
        *) err "DEPLOY_EXTRA: \"$_w\" is not <folder>:<name> (the colon is missing)"; continue ;;
    esac
    _l="${_w%%:*}"; _r="${_w#*:}"
    [[ "$_l" =~ $_dir ]] || err "DEPLOY_EXTRA: the folder of \"$_w\" does not match the format $_dir (relative to SYNC_DIR, no leading dot)"
    case "$_l" in */) err "DEPLOY_EXTRA: the folder of \"$_w\" must not end with \"/\"" ;; esac
    case "/$_l/" in */../*|*//*) err "DEPLOY_EXTRA: the folder of \"$_w\" must not contain \"..\" or \"//\"" ;; esac
    case "$_l" in *..*) err "DEPLOY_EXTRA: the folder of \"$_w\" must not contain \"..\"" ;; esac
    [[ "$_r" =~ $_modname ]] || err "DEPLOY_EXTRA: the name of \"$_w\" is not a valid module name (^[a-z][a-z0-9_]{1,63}\$)"
    # shellcheck disable=SC2086
    if in_list "$_r" $DEPLOY_MODULES; then err "DEPLOY_EXTRA: the name \"$_r\" is also in DEPLOY_MODULES (a name has one source folder)"; fi
    case " $_extra_names " in *" $_r "*) err "DEPLOY_EXTRA: the name \"$_r\" appears twice" ;; esac
    _extra_names="${_extra_names:+$_extra_names }$_r"
done
set +f
words DEPLOY_EXCLUDES "$_glob" "rsync exclude pattern (letters, digits, . _ - / * ?)"
match DEV_MARKER '^[A-Za-z0-9._-]+$' opt
case "$DEV_MARKER" in .|..|.stack-managed) err "DEV_MARKER=\"$DEV_MARKER\" is reserved" ;; esac
words CI_MODULES "$_cimodname" "module name (^[a-z0-9][a-z0-9_-]{0,63}\$)"
match CI_CHECK_SCRIPT "$_script"; match CI_STATIC_SCRIPT "$_script" opt
match STATIC_TOOLS_DIR "$_dir" opt; no_dots STATIC_TOOLS_DIR
php_versions MATRIX_PHP_VERSIONS
for _v in $MATRIX_PHP_VERSIONS; do
    # shellcheck disable=SC2086
    in_list "$_v" $TOOLS_PHP_VERSIONS || err "MATRIX_PHP_VERSIONS contains $_v, which is not in TOOLS_PHP_VERSIONS ($TOOLS_PHP_VERSIONS)"
done
for _n in DEFAULT_PHP STATIC_PHP DEPLOY_PHP; do
    match "$_n" '^[0-9]+\.[0-9]+$'
    # shellcheck disable=SC2086
    in_list "${!_n}" $TOOLS_PHP_VERSIONS || err "$_n=${!_n} is not in TOOLS_PHP_VERSIONS ($TOOLS_PHP_VERSIONS)"
done
match MAILPIT_URL "$_url" opt; match MAILPIT_SMTP_HOST "$_host" opt; match MAILPIT_SMTP_PORT '^[0-9]{1,5}$' opt

# where the template is, seen from the project root: stack.conf and the generated documents carry it in commands, so it is
# a plain relative path (leading ".." allowed: the template may sit above the project root), without blanks or special characters
TEMPLATE_REL="$(perl -MFile::Spec -e 'print File::Spec->abs2rel($ARGV[0], $ARGV[1])' "$_tpl" "$_root")"
[[ "$TEMPLATE_REL" =~ ^[A-Za-z0-9._][A-Za-z0-9._/-]*$ ]] || err "TEMPLATE_REL=\"$TEMPLATE_REL\" (the template folder seen from the project root) must be a relative path of letters, digits and . _ - / only: move the template, or the project, so that the path between them has no blank or special character"

# the destination is never inside the template (stack/ and project/ are the sources)
_dest="$_root/$DEST_DIR"
case "$_dest/" in "$_tpl"/*) err "the destination $_dest is inside the template folder: use the root of your own project" ;; esac
[ "$_fail" -eq 0 ] || { echo "invalid parameters: fix $_params" >&2; exit 1; }

# ---- 3. derived values ------------------------------------------------------------------------------------------------------
_depth=0
IFS=/ read -r -a _parts <<< "$DEST_DIR"
for _p in "${_parts[@]}"; do [ -z "$_p" ] || [ "$_p" = "." ] || _depth=$((_depth + 1)); done
PROJECT_ROOT_REL=""
_i=0
while [ "$_i" -lt "$_depth" ]; do PROJECT_ROOT_REL="${PROJECT_ROOT_REL:+$PROJECT_ROOT_REL/}.."; _i=$((_i + 1)); done
[ -n "$PROJECT_ROOT_REL" ] || PROJECT_ROOT_REL="."
DEST_REL="$DEST_DIR"
LOCKED_SH="/repo/$DEST_DIR/locked.sh"
# an example name for the database and its user (README step 4): the stack name with "_" instead of "-"
DB_NAME_EXAMPLE="${STACK_NAME//-/_}"
# the image of the optional second web instance follows the same naming; empty when the instance is not used
WEB_EXTRA_IMAGE="${WEB_EXTRA_PHP_VERSION:+${IMAGE_OWNER:+$IMAGE_OWNER/}perfex-web:$WEB_EXTRA_PHP_VERSION}"
RENDER_DATE="$(date +%F)"
RENDER_SOURCE="$(basename "$_params")"
PROJECT_ROOT_ABS="$_root"
# shellcheck disable=SC2086
export $_ALL_PARAMS PROJECT_ROOT_REL PROJECT_ROOT_ABS DEST_REL LOCKED_SH WEB_EXTRA_IMAGE DB_NAME_EXAMPLE TEMPLATE_REL RENDER_DATE RENDER_SOURCE

if [ "$_check" -eq 1 ]; then
    echo "parameters are valid ($RENDER_SOURCE)"
    echo "  stack $STACK_NAME: web $APP_URL (image $WEB_IMAGE), tools over ssh as $SSH_ALIAS ($TOOLS_HOST:2222, image $TOOLS_IMAGE)"
    echo "  server folder: $REMOTE_ROOT; PHP in tools: $TOOLS_PHP_VERSIONS; matrix: $MATRIX_PHP_VERSIONS; default: $DEFAULT_PHP"
    echo "  project folder: $_dest (project root as seen by the scripts: $PROJECT_ROOT_REL)"
    echo "  synced: $SYNC_DIR -> /repo/$SYNC_DIR; modules in /<target>/${MODULES_DIR:-.}; targets: $APP_TARGETS"
    echo "  deploy: ${DEPLOY_MODULES:-every module found}${_extra_names:+; extra: $_extra_names}; matrix: ${CI_MODULES:-every module found}"
    exit 0
fi

# ---- 4. writing -----------------------------------------------------------------------------------------------------------------
if [ -d "$_dest" ] && [ -n "$(ls -A "$_dest" 2>/dev/null)" ] && [ "$_force" -ne 1 ]; then
    echo "the folder $_dest is not empty: use --force to overwrite the files this script generates (other files stay)" >&2
    exit 1
fi
render_file() { # render_file <source> <destination>
    mkdir -p "$(dirname "$2")"
    perl -pe 's/\{\{([A-Z0-9_]+)\}\}/exists $ENV{$1} ? $ENV{$1} : die "placeholder without a parameter: {{$1}} in $ARGV\n"/ge' "$1" > "$2"
    case "$1" in *.sh) chmod 755 "$2" ;; *) chmod 644 "$2" ;; esac
}
_written=()
while IFS= read -r _f; do
    _relpath="${_f#"$_tpl/project/"}"
    render_file "$_f" "$_dest/$_relpath"
    _written+=("$_relpath")
done < <(find "$_tpl/project" -type f ! -name '.DS_Store' | sort)
if [ "$INCLUDE_AI" = 1 ] && [ -d "$_tpl/ai" ]; then
    while IFS= read -r _f; do
        _relpath="ai/${_f#"$_tpl/ai/"}"
        render_file "$_f" "$_dest/$_relpath"
        _written+=("$_relpath")
    done < <(find "$_tpl/ai" -type f ! -name '.DS_Store' | sort)
fi
# portainer.env: a variable with no value is left out, so that Portainer does not get an empty variable; the four
# PERFEX_DB_* lines are the exception: they are empty on purpose, so that loading the file creates them in Portainer and
# the user only types the values there (the stack refuses to start while they are empty)
if [ -f "$_dest/portainer.env" ]; then
    perl -ni -e 'print unless /^(?!PERFEX_DB_)[A-Z0-9_]+=\s*$/' "$_dest/portainer.env"
fi
for _relpath in "${_written[@]}"; do
    if grep -Eq '\{\{[A-Z0-9_]+\}\}' "$_dest/$_relpath"; then
        echo "placeholders left in $_dest/$_relpath:" >&2; grep -En '\{\{[A-Z0-9_]+\}\}' "$_dest/$_relpath" >&2; exit 1
    fi
done

echo "written to $_dest:"
printf '  %s\n' "${_written[@]}"
cat <<EOT

Next steps:
  1. read $DEST_DIR/README.md (your values are in it): the local, the server and the Portainer steps
  2. check the scripts without touching any server:  bash $DEST_DIR/tests/deploy-test.sh && bash $DEST_DIR/tests/locked-test.sh
  3. after the stack is up:  $DEST_DIR/doctor.sh      (and  $DEST_DIR/doctor.sh --guide  prints the steps with your values)
EOT
