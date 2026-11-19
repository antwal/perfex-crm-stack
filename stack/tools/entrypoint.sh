#!/bin/bash
# Start of the tools container: persistent host keys, the stack environment in SSH sessions, optional sshd switches,
# sshd in the foreground.
# The variables to export into SSH sessions are listed in SSH_EXPORT_VARS (set by the compose file).
set -euo pipefail

mkdir -p /etc/ssh/hostkeys /run/sshd /etc/ssh/sshd_config.d /etc/profile.d
for t in ed25519 rsa; do
    [ -f "/etc/ssh/hostkeys/ssh_host_${t}_key" ] || ssh-keygen -q -t "$t" -N "" -f "/etc/ssh/hostkeys/ssh_host_${t}_key"
done
chmod 600 /etc/ssh/hostkeys/ssh_host_*_key

# ---- 1. The stack environment in SSH sessions --------------------------------------------------------------------------
# SSH sessions do not inherit the container's environment. Two ways, so that "ssh host command" is covered as well:
#  1. SetEnv in sshd: sshd considers only the FIRST SetEnv line of its configuration, so all variables go on one line,
#     with the values in double quotes;
#  2. /etc/profile.d/stack-env.sh loaded from ~/.bashrc: Debian's bash reads ~/.bashrc for non-interactive SSH commands too.
VARS="${SSH_EXPORT_VARS:-TZ COMPOSER_HOME COMPOSER_CACHE_DIR}"
setenv_line="SetEnv"
profile_file=/etc/profile.d/stack-env.sh
echo "# written by entrypoint.sh" > "$profile_file"
for var in $VARS; do
    [[ "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    val="${!var:-}"
    [ -n "$val" ] || continue
    quoted="${val//\\/\\\\}"
    quoted="${quoted//\"/\\\"}"
    setenv_line="$setenv_line $var=\"$quoted\""
    printf 'export %s=%q\n' "$var" "$val" >> "$profile_file"
done
# the file holds the database credentials too: readable by root and www-data only
chown root:www-data "$profile_file" && chmod 640 "$profile_file"
printf '# written by entrypoint.sh\n%s\n' "$setenv_line" > /etc/ssh/sshd_config.d/10-env.conf
chmod 600 /etc/ssh/sshd_config.d/10-env.conf
cat > /home/www-data/.bashrc <<'EOT'
# written by entrypoint.sh: the stack environment, also in non-interactive SSH commands
[ -f /etc/profile.d/stack-env.sh ] && . /etc/profile.d/stack-env.sh
EOT
chown www-data:www-data /home/www-data/.bashrc

# The volumes can be created by root: the working folders must belong to www-data.
chown www-data:www-data /home/www-data /repo 2>/dev/null || true
mkdir -p /repo/.composer/cache && chown -R www-data:www-data /repo/.composer 2>/dev/null || true

# ---- 2. Optional sshd switches ----------------------------------------------------------------------------------------
# Each start rewrites or removes the file, so removing the stack variable and updating the stack is enough to go back.
# The file is read before the restrictive value in /etc/ssh/sshd_config, because that file starts with the Include.
forwarding_file=/etc/ssh/sshd_config.d/20-forwarding.conf
case "${SSH_TCP_FORWARDING:-0}" in
    1) printf '# written by entrypoint.sh because SSH_TCP_FORWARDING=1\nAllowTcpForwarding yes\n' > "$forwarding_file" ;;
    0|"") rm -f "$forwarding_file" ;;
    *) echo "SSH_TCP_FORWARDING must be 0 or 1" >&2; exit 1 ;;
esac

# SSH_PORT replaces the port of sshd_config. It goes on the command line (-p) and not in sshd_config.d because "Port"
# accumulates: a second Port line would make sshd listen on the new port and on 2222.
sshd_args=(-D -e)
if [ -n "${SSH_PORT:-}" ]; then
    if ! [[ "$SSH_PORT" =~ ^[1-9][0-9]{0,4}$ ]] || [ "$SSH_PORT" -gt 65535 ]; then
        echo "SSH_PORT must be a port number between 1 and 65535" >&2
        exit 1
    fi
    sshd_args+=(-p "$SSH_PORT")
fi

/usr/sbin/sshd -t
exec /usr/sbin/sshd "${sshd_args[@]}"
