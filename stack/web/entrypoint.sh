#!/bin/bash
# Start of the web container: the Authorization switch, PHP-FPM in the background, Apache as process 1.
set -eo pipefail

# ---- 1. PASS_AUTHORIZATION: should PHP see the Authorization header? ------------------------------------------------
# Apache with PHP-FPM drops the Authorization header (Bearer, Basic) unless told otherwise, and the .htaccess of the
# application does not tell it. 1 writes the directive built for this (CGIPassAuth, Apache 2.4.13 or later) and 0
# removes it, at every start, so changing the stack variable and updating the stack is all it takes. The .htaccess of
# the instance is never touched.
# An alternative that also works, if CGIPassAuth ever misbehaves: put this line in the Directory block below instead:
#     SetEnvIf Authorization "(.*)" HTTP_AUTHORIZATION=$1
conf=/etc/apache2/conf-enabled/pass-authorization.conf
case "${PASS_AUTHORIZATION:-0}" in
    1)
        cat > "$conf" <<'EOT'
# written by entrypoint.sh because PASS_AUTHORIZATION=1
<Directory /var/www/html>
    CGIPassAuth On
</Directory>
EOT
        ;;
    0) rm -f "$conf" ;;
    *) echo "PASS_AUTHORIZATION must be 0 or 1" >&2; exit 1 ;;
esac

# ---- 2. PHP-FPM ------------------------------------------------------------------------------------------------------
# Test the configuration first: a mistake stops the container here, with the message, instead of showing up as 502s.
# PHP-FPM runs in the foreground mode but in the background of this script ("php-fpm -D" would detach it from the
# container's stderr and lose its error log). When this script ends in the exec below, Apache becomes its parent.
php-fpm -t
php-fpm -F &

# ---- 3. Apache as process 1 --------------------------------------------------------------------------------------------
# apache2ctl is a wrapper that does not exec Apache, so it would stay process 1 and swallow Docker's SIGTERM (every stop
# would wait for the kill). The binary is started directly, with the environment apache2ctl would have set up.
. /etc/apache2/envvars
mkdir -p "$APACHE_RUN_DIR" "$APACHE_LOCK_DIR"
rm -f "$APACHE_PID_FILE"
exec apache2 -D FOREGROUND
