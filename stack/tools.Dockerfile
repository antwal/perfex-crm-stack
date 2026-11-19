# Service container of the test stack: sshd (key only) + several PHP CLI versions + Composer + rsync + MariaDB client,
# and optionally Node.
#
# Built by you, on the server (README, "Build the two images"), from the build/ copy of stack/. The build context is that
# folder as a whole ("."), because the COPY lines below take tools/sshd_config and tools/entrypoint.sh from it. cd into it, then:
#   docker build -f tools.Dockerfile --build-arg PHP_VERSIONS="8.1 8.2 8.3 8.4 8.5" --build-arg TOOLS_NODE=0 -t perfex-tools:8.1-8.5 .
# Tag: [<IMAGE_OWNER>/]perfex-tools:<first>-<last PHP version>, the TOOLS_IMAGE of your parameters.
#
# Build arguments:
#   PHP_VERSIONS     PHP versions installed from the Sury repository, one /opt/php/<version>/php shim each. Reduce the
#                    list if Sury does not have a version yet, for example --build-arg PHP_VERSIONS="8.3 8.4".
#   TOOLS_NODE       1 adds Node (about 100 MB), for tests written in JavaScript that run on the server. Default 0.
#   DEBIAN_CODENAME  base distribution. bookworm has all of 8.1-8.5 in Sury; move to trixie only when Sury covers them all.
#   COMPOSER_VERSION tag of the official composer image the binary is copied from.
#   NODE_VERSION, NODE_SHA256   Node tarball and its checksum (x86-64 only). The checksum is the line for
#                    node-v<version>-linux-x64.tar.xz in https://nodejs.org/dist/v<version>/SHASUMS256.txt: change both together.
ARG COMPOSER_VERSION=2.11.1
ARG DEBIAN_CODENAME=bookworm

FROM composer:${COMPOSER_VERSION} AS composer

FROM debian:${DEBIAN_CODENAME}-slim

ARG DEBIAN_CODENAME=bookworm
ARG PHP_VERSIONS="8.1 8.2 8.3 8.4 8.5"
ARG TOOLS_NODE=0
ARG NODE_VERSION=22.23.3
ARG NODE_SHA256=df450af89261115ef9f9e3830c3eeb2cc9213b63c720b1af623cb5dcbe2e02de

ENV DEBIAN_FRONTEND=noninteractive \
    COMPOSER_ALLOW_SUPERUSER=0 \
    COMPOSER_HOME=/repo/.composer \
    COMPOSER_CACHE_DIR=/repo/.composer/cache

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg apt-transport-https; \
    curl -fsSLo /usr/share/keyrings/deb.sury.org-php.gpg https://packages.sury.org/php/apt.gpg; \
    echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ ${DEBIAN_CODENAME} main" > /etc/apt/sources.list.d/php.list; \
    apt-get update; \
    for v in $PHP_VERSIONS; do \
        apt-get install -y --no-install-recommends \
            php$v-cli php$v-mbstring php$v-xml php$v-curl php$v-zip php$v-mysql php$v-intl php$v-gd php$v-bcmath php$v-pcov; \
        mkdir -p /opt/php/$v; \
        ln -s /usr/bin/php$v /opt/php/$v/php; \
    done; \
    apt-get install -y --no-install-recommends git rsync unzip xz-utils jq less procps mariadb-client openssh-server openssh-client; \
    rm -rf /var/lib/apt/lists/*

COPY --from=composer /usr/bin/composer /usr/local/bin/composer

# Node, only when asked for (TOOLS_NODE=1): official tarball, version and SHA-256 pinned.
RUN set -eux; \
    if [ "$TOOLS_NODE" = "1" ]; then \
        [ "$(dpkg --print-architecture)" = "amd64" ] || { echo "TOOLS_NODE=1 is only prepared for amd64" >&2; exit 1; }; \
        curl -fsSLo /opt/node.tar.xz "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz"; \
        echo "${NODE_SHA256}  /opt/node.tar.xz" | sha256sum -c -; \
        mkdir -p /opt/node; \
        tar -xJf /opt/node.tar.xz -C /opt/node --strip-components=1; \
        rm /opt/node.tar.xz; \
        ln -s /opt/node/bin/node /usr/local/bin/node; \
        ln -s /opt/node/bin/npm /usr/local/bin/npm; \
        ln -s /opt/node/bin/npx /usr/local/bin/npx; \
    fi

# Working user: www-data (uid 33), the owner of the application files on the volume.
RUN set -eux; \
    usermod -s /bin/bash -d /home/www-data www-data; \
    mkdir -p /home/www-data /repo /app /run/sshd /etc/ssh/authorized_keys.d /etc/ssh/hostkeys /etc/ssh/sshd_config.d; \
    chown www-data:www-data /home/www-data /repo; \
    chmod 755 /etc/ssh/authorized_keys.d

COPY tools/sshd_config /etc/ssh/sshd_config
COPY tools/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 644 /etc/ssh/sshd_config && chmod 755 /usr/local/bin/entrypoint.sh

EXPOSE 2222
WORKDIR /repo
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
