# Web image for the test stack: Apache (event MPM) in front of PHP-FPM, with the PHP extensions Perfex CRM needs.
#
# Built by you, on the server, once per PHP version (README, "Build the two images"), from the build/ copy of stack/. The
# build context is the web/ folder, because the COPY lines below take apache/, php/ and entrypoint.sh from it. cd into build/, then:
#   docker build -f web/Dockerfile --build-arg PHP_VERSION=8.4 -t perfex-web:8.4 web
# Tag: [<IMAGE_OWNER>/]perfex-web:<PHP version>, the WEB_IMAGE of your parameters.
#
# Everything the build downloads is pinned: the base image by PHP version, the extension installer by version AND
# SHA-256 (checked before it is made executable). To update the installer, change the two ARGs together: version and
# SHA-256 are both shown on the installer's GitHub release page (https://github.com/mlocati/docker-php-extension-installer/releases),
# never use "releases/latest".
#
# Why the extensions are built here: the official php images no longer ship "imap" (Perfex's installer requires it).
ARG PHP_VERSION=8.4
FROM php:${PHP_VERSION}-fpm

ARG IPE_VERSION=2.13.2
ARG IPE_SHA256=27fa8d80bd4e22feb9ddcadff1ca40c8f3e8ea942eb2dd8f446ed1afd2f2f0ab

ENV APACHE_RUN_USER=www-data \
    APACHE_RUN_GROUP=www-data

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends apache2 ca-certificates curl procps; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    curl -fsSL -o /usr/local/bin/install-php-extensions \
        "https://github.com/mlocati/docker-php-extension-installer/releases/download/${IPE_VERSION}/install-php-extensions"; \
    echo "${IPE_SHA256}  /usr/local/bin/install-php-extensions" | sha256sum -c -; \
    chmod 0755 /usr/local/bin/install-php-extensions

RUN install-php-extensions mysqli pdo_mysql gd curl mbstring iconv zip imap

# Apache: modules, no version banner, logs on stdout/stderr (docker logs), no startup warning about ServerName.
RUN set -eux; \
    a2enmod proxy proxy_fcgi setenvif rewrite; \
    a2disconf other-vhosts-access-log; \
    echo 'ServerName localhost' > /etc/apache2/conf-available/servername.conf; \
    a2enconf servername; \
    sed -i -e 's#^ServerTokens .*#ServerTokens Prod#' -e 's#^ServerSignature .*#ServerSignature Off#' /etc/apache2/conf-available/security.conf; \
    sed -i 's#^ErrorLog .*#ErrorLog /proc/self/fd/2#' /etc/apache2/apache2.conf; \
    grep -q '^ErrorLog /proc/self/fd/2$' /etc/apache2/apache2.conf

COPY apache/000-default.conf /etc/apache2/sites-available/000-default.conf

# PHP: the production php.ini (display_errors and expose_php off), then the upload limits. A uploads.ini mounted at the
# same path (see the compose file) replaces the one copied here.
RUN cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"
COPY php/uploads.ini $PHP_INI_DIR/conf.d/uploads.ini

# PHP-FPM listens on the loopback only: Apache is the only client, and nothing else on the Docker network can talk
# FastCGI to it. The file name sorts after the image's own pool settings, so this value wins.
RUN printf '%s\n' '[www]' 'listen = 127.0.0.1:9000' > /usr/local/etc/php-fpm.d/zzz-listen.conf

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN set -eux; \
    chmod 755 /usr/local/bin/entrypoint.sh; \
    chown -R www-data:www-data /var/www; \
    chmod -R 755 /var/www

WORKDIR /var/www/html
EXPOSE 80
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
