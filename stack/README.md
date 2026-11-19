# stack/: what you paste into Portainer, and the two images

Everything in this folder is used **as it is**. `render.sh` never writes here: the values come from stack variables, each with a
neutral default, and the project folder that `render.sh` makes ships a `portainer.env` with the values of your project.

| File | What it is |
|---|---|
| `docker-compose.yml` | the stack: `web` (Apache + PHP-FPM) and `tools` (sshd, PHP CLI versions, Composer, rsync, MariaDB client) |
| `web-extra.yml` | optional: a second web instance on another PHP version, added with "Additional paths" |
| `web/` | the build context of the web image: `Dockerfile`, `entrypoint.sh`, `apache/000-default.conf`, `php/uploads.ini` |
| `tools.Dockerfile`, `tools/` | the build of the tools image: `entrypoint.sh` and `sshd_config` |

## Build the two images

There is no `build:` in the compose file: Portainer cannot build for remote environments. **You build the two images on the
server first**, as root, from a copy of this folder (the project README prints these commands with your values; `doctor.sh --guide`
too). The build context, the folder Docker copies files from, is not the same for the two images: the web image is built
from `web/` (its Dockerfile copies `apache/`, `php/` and `entrypoint.sh` from there), the tools image from this folder as a
whole (it copies `tools/sshd_config` and `tools/entrypoint.sh`).

```bash
# on your Mac, from the folder that holds perfex-crm-stack/: this folder goes to the server as <REMOTE_ROOT>/build/
rsync -av --delete perfex-crm-stack/stack/ root@SERVER:/srv/docker/perfexcrm/myproject/build/
```

On the server, as root, go to that copy first:

```bash
cd /srv/docker/perfexcrm/myproject/build
```

Each `docker build` names its Dockerfile with `-f` and ends with the build context: `web` for the web image, `.` for the
tools image. The web image, one per PHP version you use:

```bash
docker build -f web/Dockerfile --build-arg PHP_VERSION=8.4 -t perfex-web:8.4 web
```

The tools image (`TOOLS_NODE=1` adds Node):

```bash
docker build -f tools.Dockerfile --build-arg PHP_VERSIONS="8.1 8.2 8.3 8.4 8.5" --build-arg TOOLS_NODE=0 -t perfex-tools:8.1-8.5 .
```

Image names (`-t`): `perfex-web:<PHP version>` and `perfex-tools:<first>-<last PHP version>`, with an owner or registry prefix
in front when you keep images under one (`myowner/perfex-web:8.4`): that is what the `IMAGE_OWNER` parameter of the project
folder adds, and the names end up in `WEB_IMAGE` and `TOOLS_IMAGE` of its `portainer.env`.

Build arguments: web `PHP_VERSION` (8.4); tools `PHP_VERSIONS` (default `8.1 8.2 8.3 8.4 8.5`), `TOOLS_NODE` (0, set 1 for Node),
`DEBIAN_CODENAME` (`bookworm`). Everything a build downloads is pinned (versions, and a SHA-256 for the extension installer and
for Node): the comments at the top of each Dockerfile say how to update them. If the tools build stops because the PHP package
repository (Sury) does not have a version yet, drop it from `PHP_VERSIONS` (and from `TOOLS_PHP_VERSIONS` in your parameters).
After you change a file of the context, copy it again with `rsync --delete` before rebuilding: a `COPY` layer marked `CACHED`
means the server still has the old file. When both builds are done, `docker images` lists the two tags. After a rebuild
under the same tag, *Update the stack* with "Re-pull image" **off** recreates the container on the new image (it did on
19 November 2026; check with `docker inspect --format '{{.Image}}' <container>` against `docker images --no-trunc`); if the
container keeps the old image, open it and press **Recreate**, again with "Re-pull image" off.

## What to paste, and the variables

Paste `docker-compose.yml` into **Stacks > Add stack > Web editor**, or use a Git repository stack (the README of the template
explains both). Then set the variables: load the project folder's `portainer.env` (**Load variables from .env file**); the four database
variables arrive from the file with an **empty value**, and you type their values in the Portainer form (the values are
never in a file).

| Variable | Default | |
|---|---|---|
| `PERFEX_DB_HOST`, `PERFEX_DB_NAME`, `PERFEX_DB_USER`, `PERFEX_DB_PASSWORD` | none (loaded empty from `portainer.env`) | **required**: type the values in Portainer; the stack refuses to start while they are empty |
| `STACK_NAME` | `myproject` | container names: `<STACK_NAME>` and `<STACK_NAME>-tools` |
| `REMOTE_ROOT` | `/srv/docker/perfexcrm/myproject` | folder on the server: `app/`, `repo/`, `tools/` (every host path starts here) |
| `APP_HOST`, `TOOLS_HOST` | `myproject.perfexcrm.docker`, `myproject-tools.perfexcrm.docker` | DNS names on the network |
| `APP_URL` | `http://myproject.perfexcrm.docker` | what the tests and the scripts use to reach the application |
| `DOCKER_NETWORK` | `containers` | an existing external network |
| `WEB_IMAGE`, `TOOLS_IMAGE` | `perfex-web:8.4`, `perfex-tools:8.1-8.5` | the images you built (`[<owner>/]perfex-web:<PHP version>`, `[<owner>/]perfex-tools:<first>-<last PHP version>`), or your own |
| `TZ` | `UTC` | |
| `PASS_AUTHORIZATION` | `0` | `1` lets PHP see the `Authorization` header (see below) |
| `TOOLS_CPUS`, `TOOLS_MEM`, `TOOLS_PIDS` | `2`, `2g`, `512` | limits of the tools container |
| `MAILPIT_URL`, `MAILPIT_SMTP_HOST`, `MAILPIT_SMTP_PORT` | empty | an existing Mailpit, if you have one |
| `SSH_PORT` | `2222` | port of sshd in the container; if you change it, change `Port` in `~/.ssh/config` |
| `SSH_TCP_FORWARDING` | `0` | `1` allows `ssh -L` (off by default) |

**If your machine does not reach the Docker network.** The compose file publishes no port (`expose:` only), so the stack is
reached by DNS name, from a machine that resolves the names of the Docker network and routes to it: that is the reference
infrastructure. If your Mac cannot, publish two ports on the Docker host and point everything at the host's address; the DNS
names are then not needed. Add to the file (the compose file in the repository stays as it is):

```yaml
services:
  web:
    ports:
      - "8080:80"          # host port 8080 (any free port) -> Apache
  tools:
    ports:
      - "2200:2222"        # host port 2200 (any free port) -> sshd; the right side is SSH_PORT (2222 by default)
```

- **Web editor:** put the two `ports:` blocks under the existing `web` and `tools` services in the pasted file (they sit
  beside `expose:`). **Git repository stack:** its file cannot be edited in Portainer, so keep these lines in a small extra file
  in your own copy of the repository and list it in *Additional paths*, as with `web-extra.yml`.
- Parameters: set `APP_URL` to `http://<address of the host>:8080` and render again (the Mac scripts and `doctor.sh` use it);
  in `~/.ssh/config`, `HostName <address of the host>` and `Port 2200`. `doctor.sh` still prints the default `Port 2222` in its
  hints: the `Port` that counts is the one in your alias.
- In Portainer, the stack variable `APP_URL` is also what the tools container uses to reach the web container. Keep it at
  `http://<APP_HOST>`, which works inside the Docker network whatever the Mac does: after loading `portainer.env`, which now
  carries the host address, edit that one variable back. (The host address also works from the container if the host's
  firewall lets the container reach its own address; `doctor.sh` tells you when it does not.)
- Perfex keeps its address in `APP_BASE_URL` (`app-config.php`, written by the installation wizard): run the wizard through the
  address you will use.
- `ports:` listens on every interface of the host. Bind to a private address (`"10.0.0.5:8080:80"`) or close the two ports
  in the host's firewall to whoever should not have them; sshd accepts keys only, but the application is open to anyone who
  can reach the port.

## The database

On the MariaDB that already runs on the server, with its administrator account: a database (`utf8mb4_unicode_ci`) and a user
with all privileges **on that database only**, with a password you choose. The four values become the required stack
variables above and go nowhere else. For example:

```sql
CREATE DATABASE perfex_myproject CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'perfex_myproject'@'%' IDENTIFIED BY '<a password you choose>';
GRANT ALL PRIVILEGES ON perfex_myproject.* TO 'perfex_myproject'@'%';
FLUSH PRIVILEGES;
```

`'%'` lets the containers of the Docker network connect; put that network's subnet in its place (`'10.0.0.%'`) to narrow it.

## The SSH key and the alias (on your Mac, before the server steps)

The tools container accepts one user, `www-data`, with a public key only: the key pair is made on your Mac, and its public
line goes into `<REMOTE_ROOT>/tools/authorized_keys` on the server (below). `render.sh` writes these two commands with your
values in the project README (step 1), and `doctor.sh --guide` prints them; here they are for whoever uses `stack/` alone.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/myproject-test -C myproject-test -N ""
```

```bash
cat >> ~/.ssh/config <<'EOT'

Host myproject-test
    HostName myproject-tools.perfexcrm.docker
    Port 2222
    User www-data
    IdentityFile ~/.ssh/myproject-test
    IdentitiesOnly yes
EOT
```

```bash
cat ~/.ssh/myproject-test.pub
```

The line it prints goes into `authorized_keys` (`myproject-test` is the `SSH_ALIAS` of `params.example.env`: use yours). `HostName` is your `TOOLS_HOST`; `Port` is `SSH_PORT` if you
set it, or the host port if you publish one (above). The private key never leaves the Mac and is never pasted into a chat.
One key per alias keeps things simple; an existing key works too, with its path in `IdentityFile` and its public line in
`authorized_keys`.

**The files that must exist on the server before the stack starts:** `<REMOTE_ROOT>/tools/authorized_keys` (a file with the
public line printed above) and the folders `app`, `repo`, `tools/hostkeys`. If a path is missing Docker creates a *folder* with that name, and the mount
fails or misleads. Same for `<REMOTE_ROOT>/web/uploads.ini` if you uncomment its volume.

## A second web instance

`web-extra.yml` adds `web-extra` (image `WEB_EXTRA_IMAGE`: the `[<owner>/]perfex-web:<PHP version>` you built for that version)
with its own folder `app-extra`, and gives the tools container `/app-extra`. Build the image for that version first, from the
`build/` copy (`docker build -f web/Dockerfile --build-arg PHP_VERSION=8.5 -t perfex-web:8.5 web`: the template publishes no
image, only the Dockerfile), create `<REMOTE_ROOT>/app-extra` owned by uid 33, set `WEB_EXTRA_IMAGE`, `WEB_EXTRA_NAME` and
`WEB_EXTRA_HOST` (the project folder's `portainer.env` carries them when the `WEB_EXTRA_*` parameters are set), and:

- with a **Git repository** stack, write `stack/web-extra.yml` in **Additional paths** (the files are merged like several `-f`);
- with the **web editor**, paste its two blocks into the main file (the `tools` block merges into the existing one).

Add `app-extra` to `APP_TARGETS` in your parameters so `deploy.sh` can write there.

## The Authorization header

`PASS_AUTHORIZATION=1` makes the web image write `CGIPassAuth On` for the application folder at every start, so Bearer and Basic
headers reach PHP; `0` removes it. If you use your own `WEB_IMAGE`, add to its Apache configuration, inside the vhost
(Apache 2.4.13 or later): `<Directory /var/www/html> CGIPassAuth On </Directory>`, or `SetEnvIf Authorization "(.*)" HTTP_AUTHORIZATION=$1`.
