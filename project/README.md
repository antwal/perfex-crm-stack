# Test instance of {{PROJECT_LABEL}} on a Docker server (Portainer)

Written by `render.sh` on {{RENDER_DATE}} from `{{RENDER_SOURCE}}`: to change a value, change the parameter file and render again
(`render.sh <params> <project root> --force`), do not edit the files of this folder.

The stack `{{STACK_NAME}}` runs on a Docker server managed with Portainer. Your Mac reaches it over the Docker network's DNS
names. **There is one way in**: a service container (`tools`) with SSH, key only, user `www-data`. Nothing else is needed or
used: no root, no password, no Portainer, no Docker socket.

| Service | Address | What it does |
|---|---|---|
| `web` | `{{APP_URL}}` | the application, on the image `{{WEB_IMAGE}}` (Apache + PHP-FPM {{WEB_PHP_VERSION}}); files in `{{REMOTE_ROOT}}/app` |
| `tools` | `{{TOOLS_HOST}}`, port 2222, SSH alias `{{SSH_ALIAS}}` | PHP {{TOOLS_PHP_VERSIONS}} on the command line, Composer, rsync, MariaDB client; deploys, the PHP matrix, integration tests, snapshots |
| MariaDB | already on the server | a database for this instance; credentials only in the stack variables |
| Mailpit (optional) | `{{MAILPIT_URL}}`, SMTP `{{MAILPIT_SMTP_HOST}}:{{MAILPIT_SMTP_PORT}}` | test mailboxes; messages are readable from the API `/api/v1/messages` |

The instance is **throw-away**: tests install and uninstall modules and send abnormal requests. Never real data.

## 1. Installation, step by step

`SERVER` is how **you** log in to the server as root (an alias or an address). An AI agent has no such access and does not ask
for it: it prepares the commands, you run them. The same steps, with your values, come from `{{DEST_REL}}/doctor.sh --guide`.
Run the Mac steps from the **project root**, the folder this was rendered for:

```bash
cd {{PROJECT_ROOT_ABS}}
```

The template (with `stack/`) is at `{{TEMPLATE_REL}}` from there.

### Step 1, on the Mac: a key and an alias

```bash
ssh-keygen -t ed25519 -f ~/.ssh/{{SSH_ALIAS}} -C {{SSH_ALIAS}} -N ""
```

```bash
cat >> ~/.ssh/config <<'EOT'

Host {{SSH_ALIAS}}
    HostName {{TOOLS_HOST}}
    Port 2222
    User www-data
    IdentityFile ~/.ssh/{{SSH_ALIAS}}
    IdentitiesOnly yes
EOT
```

```bash
cat ~/.ssh/{{SSH_ALIAS}}.pub
```

Copy the line it prints: step 3 needs it. The private key never leaves the Mac and is never pasted into a chat.

### Step 2, on the Mac: copy the build context of the two images to the server

With `rsync`, not `scp -r`: if the `build` folder already exists, `scp -r` nests the copy and the build reuses stale files.

```bash
rsync -av --delete {{TEMPLATE_REL}}/stack/ root@SERVER:{{REMOTE_ROOT}}/build/
```

### Step 3, on the server as root: folders, key, the two images

```bash
ssh root@SERVER
```

The folders of the stack, owned by uid 33 (`www-data`, the owner of the application files). If you use the second web
instance (`web-extra.yml`), add `app-extra` to the list of folders and to the `chown`:

```bash
ROOT={{REMOTE_ROOT}}; mkdir -p $ROOT/app $ROOT/repo $ROOT/tools/hostkeys && chown -R 33:33 $ROOT/app $ROOT/repo
```

The authorized keys file. It must exist as a **file before the stack starts**, or Docker creates a folder with that name
and the mount fails without a clear message. Replace `ssh-ed25519 AAAA...` with the line copied in step 1:

```bash
printf '%s\n' 'ssh-ed25519 AAAA... {{SSH_ALIAS}}' > {{REMOTE_ROOT}}/tools/authorized_keys && chmod 644 {{REMOTE_ROOT}}/tools/authorized_keys
```

The two images, from the copy of `stack/` made in step 2. Go to that folder first:

```bash
cd {{REMOTE_ROOT}}/build
```

Each `docker build` names its Dockerfile with `-f` and ends with the build context, the folder Docker copies files from:
`web` for the web image (its Dockerfile copies `apache/`, `php/` and `entrypoint.sh` from there), `.` for the tools image (it
copies `tools/sshd_config` and `tools/entrypoint.sh`). The names after `-t` are `WEB_IMAGE` and `TOOLS_IMAGE` of your parameters
(`[<IMAGE_OWNER>/]perfex-web:<PHP version>` and `[<IMAGE_OWNER>/]perfex-tools:<first>-<last PHP version>`).

The web image (Apache + PHP-FPM {{WEB_PHP_VERSION}}, with the extensions Perfex CRM needs):

```bash
docker build -f web/Dockerfile --build-arg PHP_VERSION={{WEB_PHP_VERSION}} -t {{WEB_IMAGE}} web
```

The tools image (PHP {{TOOLS_PHP_VERSIONS}}, Composer, sshd, rsync, MariaDB client, and Node when `TOOLS_NODE` is 1):

```bash
docker build -f tools.Dockerfile --build-arg PHP_VERSIONS="{{TOOLS_PHP_VERSIONS}}" --build-arg TOOLS_NODE={{TOOLS_NODE}} -t {{TOOLS_IMAGE}} .
```

If the build stops because the PHP package repository (Sury) does not have one of the versions yet, remove it from the
`PHP_VERSIONS` argument and from `TOOLS_PHP_VERSIONS` in your parameters, and render again. The web build checks the SHA-256
of the extension installer by itself and stops if it does not match. When both are done, `docker images` lists `{{WEB_IMAGE}}`
and `{{TOOLS_IMAGE}}`; a `COPY` layer marked `CACHED` after you changed a file of the context means step 2 was not repeated.

Optional, your own upload limits instead of the ones built into the image: create `{{REMOTE_ROOT}}/web/uploads.ini` (a file) and
uncomment the `uploads.ini` volume of the `web` service in the stack.

### Step 4, the database

On the MariaDB that already runs on the server, with its **administrator** account (the one you create databases with, not
the user of this instance): a database with `utf8mb4_unicode_ci` and a user with all privileges **on that database only**,
with a password you choose. For example, with the stack name as the name of both:

```sql
CREATE DATABASE {{DB_NAME_EXAMPLE}} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '{{DB_NAME_EXAMPLE}}'@'%' IDENTIFIED BY '<a password you choose>';
GRANT ALL PRIVILEGES ON {{DB_NAME_EXAMPLE}}.* TO '{{DB_NAME_EXAMPLE}}'@'%';
FLUSH PRIVILEGES;
```

`'%'` lets the two containers of the Docker network connect; put that network's subnet in its place (`'10.0.0.%'`) to narrow
it. The four values become the Portainer variables of step 5 and go nowhere else, not in chat, not in a file: `PERFEX_DB_HOST`
(the name of the MariaDB host on the Docker network), `PERFEX_DB_NAME`, `PERFEX_DB_USER`, `PERFEX_DB_PASSWORD`. `doctor.sh`
(step 6) checks that the database answers with them.

### Step 5, in Portainer

1. **Stacks > Add stack**, name `{{STACK_NAME}}`, then either:
   - **Web editor**: paste the whole of `stack/docker-compose.yml`; or
   - **Repository**: the Git method of the template's README (reference a tag, Compose path `stack/docker-compose.yml`).
2. **Environment variables > Load variables from .env file**: choose `{{DEST_REL}}/portainer.env` (no secrets inside).
3. Add by hand the four database variables, **not** in any file: `PERFEX_DB_HOST`, `PERFEX_DB_NAME`, `PERFEX_DB_USER`,
   `PERFEX_DB_PASSWORD`. Without them the stack refuses to start, on purpose.
4. **Deploy the stack**. The containers are `{{STACK_NAME}}` (web) and `{{STACK_NAME}}-tools`.

### Step 6, on the Mac: check

```bash
{{DEST_REL}}/doctor.sh
```

It checks the SSH login, PHP and Composer in the container, the mounts, the stack variables (names only), the database,
that `locked.sh` is on the server, and that `{{APP_URL}}` answers. On a fresh stack it reports `locked.sh` missing: `sync.sh`
puts it there together with your code (deploy and the matrix run it first), and `run.sh`, `snapshot.sh`, `reset.sh` and
`install-perfex.sh` copy it by themselves when it is not there yet.

### Step 7, the application

Perfex CRM is proprietary: **bring your own licensed copy**, this template contains none of it. Copy your folder (the one with
`index.php` and `application/`) or your zip into `/app`:

```bash
{{DEST_REL}}/install-perfex.sh <your Perfex folder or zip>
```

Open `{{APP_URL}}` in a browser and complete the installation wizard: you create the administrator there. Then remove the
install folder, and point the application's email at Mailpit if you use it (Setup > Settings > Email: SMTP host
`{{MAILPIT_SMTP_HOST}}`, port `{{MAILPIT_SMTP_PORT}}`, no authentication):

```bash
{{DEST_REL}}/run.sh 'rm -rf /app/install'
```

If your modules or an API need the `Authorization` header (Bearer tokens, Basic), set the stack variable
`PASS_AUTHORIZATION=1` and update the stack (see "The Authorization header" below).

## 2. Daily use (from the project root)

Every command below is relative to the project root: `cd {{PROJECT_ROOT_ABS}}` first. The scripts take their values from
`stack.conf`; `STACK_SSH=<alias>` in the environment points them at another stack rendered with the same layout.

| Command | What it does |
|---|---|
| `{{DEST_REL}}/sync.sh` | mirrors `{{SYNC_DIR}}/` to `/repo/{{SYNC_DIR}}` on the server (without `vendor/`, `.git`, zips), and puts `locked.sh` in place |
| `{{DEST_REL}}/deploy.sh [--adopt] <module> [<target>]` | sync, then on the server: `composer install --no-dev`, copy of the module into `/<target>/{{MODULES_DIR}}/<module>`, development dependencies back in the repository copy. Modules: `{{DEPLOY_MODULES}}` (empty = every `<name>/<name>.php` found); targets: `{{APP_TARGETS}}` |
| `{{DEST_REL}}/ci-local.sh [<module> ...]` | the PHP matrix `{{MATRIX_PHP_VERSIONS}}`: `composer install`, `validate --strict`, `run {{CI_CHECK_SCRIPT}}`; then the static analysis script, if there is one, on PHP {{STATIC_PHP}} |
| `{{DEST_REL}}/run.sh '<command>'` | one command on the server, inside the lock, as `www-data` (it puts `locked.sh` there first if it is missing). Integration tests: `run.sh 'cd /repo/{{SYNC_DIR}}/<module> && PATH=/opt/php/{{DEPLOY_PHP}}:$PATH composer test:int'` |
| `{{DEST_REL}}/snapshot.sh [<label>]` | a dump of the database and an archive of `/app`, kept on the server in `/repo/.tmp/snapshots/<name>/` |
| `{{DEST_REL}}/reset.sh <name>` / `--list` | puts a snapshot back after you type its name; `--list` shows the snapshots |
| `{{DEST_REL}}/doctor.sh` / `--guide` | the checks / the setup steps with your values |
| `{{DEST_REL}}/install-perfex.sh <folder or zip>` | copies your Perfex CRM into `/app` (step 7) |
| `bash {{DEST_REL}}/tests/deploy-test.sh` | deploy.sh against a fake ssh and rsync, and its server script against a folder tree: nothing touches a server |
| `bash {{DEST_REL}}/tests/locked-test.sh` | run.sh and locked.sh without a server |
| `bash {{DEST_REL}}/tests/scripts-test.sh` | ci-local.sh, snapshot.sh, reset.sh, install-perfex.sh and doctor.sh against a fake ssh, rsync and curl |
| `bash {{DEST_REL}}/tests/render-test.sh` | `render.sh`, with good and bad parameters (it finds the template through `TEMPLATE_REL`, or `STACK_TEMPLATE_DIR`) |

Other things you will want, all through `ssh {{SSH_ALIAS}}` or `run.sh`:

```bash
{{DEST_REL}}/run.sh 'tail -n 50 /app/application/logs/log-$(date +%F).php'
{{DEST_REL}}/run.sh 'MYSQL_PWD="$PERFEX_DB_PASSWORD" mariadb -h "$PERFEX_DB_HOST" -u "$PERFEX_DB_USER" "$PERFEX_DB_NAME" -e "SHOW TABLES"'
curl -s {{MAILPIT_URL}}/api/v1/messages | jq '.messages[0].Subject'
```

(The log path is Perfex's. The credentials stay in the container: the variables are expanded on the server. The password goes
in `MYSQL_PWD`, not in a `-p…` option, because an environment variable does not show up in `ps`, while a command-line argument
does, to every process in the container. `mariadb` is the client the tools image ships, the same one `snapshot.sh` uses.)

PHP versions are chosen with `PATH=/opt/php/<version>:$PATH`: a shim that makes `php` that version, for Composer scripts and
`vendor/bin/*` too. The release package of a module does **not** go through `deploy.sh`: your build produces it and you
install it from the application's interface, as a customer would.

A heavy job at a time: `deploy.sh`, `ci-local.sh`, `run.sh`, `snapshot.sh` and `reset.sh` wait for each other at the lock
`{{LOCK_FILE}}` and run at low priority. If the lock is busy for over a minute, the script says so and keeps waiting.

### What a module needs to be deployed

A folder `<name>/<name>.php` under `{{SYNC_DIR}}/`, with `<name>` made of lowercase letters, digits and `_`, starting with a letter
(2 to 64 characters). That is also what a Perfex module is. If it has a `composer.json`, the matrix runs its `{{CI_CHECK_SCRIPT}}` script on every
PHP version. The example module of the template (`examples/module/sample_module/`) shows the shape, including a
`test:int` script and `tests/Integration/TestInstance.php`, a helper that reads the stack variables
(`PERFEX_URL`, `PERFEX_APP_PATH`, `PERFEX_DB_*`, `MAILPIT_*`) that the SSH session provides.

## 3. The `.stack-managed` marker: what deploy.sh may overwrite

The server writes `/<target>/{{MODULES_DIR}}/<module>` **only if that folder does not exist or holds the marker file
`.stack-managed`**, which the first deploy writes. Anything else is refused (exit status 3), before anything is copied:
a module that comes with the application, one installed from a zip, one a person made by hand.

- If the folder is yours and you want deploy to manage it: `deploy.sh --adopt <module>` writes the marker and takes it over
  (the folder's contents are replaced by the module).
- **After an uninstall from the application's interface:** the application deletes the files with a dot name but leaves
  the folders with a dot name, so the module folder may stay behind. The marker is a dot file, so it is gone with the
  uninstall. If the folder is gone too, the next deploy starts clean. If the folder stayed (there was a dot folder inside),
  the next deploy asks for `--adopt`. Deploy never leaves dot folders in the copy it makes, so that is rare.
- A symbolic link is never followed, not even with `--adopt`.

## 4. Snapshots

`snapshot.sh` takes a dump of the database and an archive of `/app` and keeps them on the server in
`/repo/.tmp/snapshots/<date>[-<label>]/` (never in your project's files). `reset.sh <name>` puts both back after you type
the snapshot name: it checks that the two files are intact, drops every table, loads the dump, empties `/app` and extracts
the archive. Take a snapshot after a clean installation of the application: that is your "factory reset". A snapshot holds
the application's configuration file (database password, encryption key): it stays on the server, readable by `www-data`
only, on an instance that is meant to be thrown away.

## 5. The Authorization header

With Apache in front of PHP-FPM, the `Authorization` header (Bearer, Basic) does **not** reach PHP unless Apache is told to
pass it. The web image has the switch: stack variable `PASS_AUTHORIZATION=1` (default 0), read at every start of the
container, so change the variable in Portainer and **Update the stack**. It writes one Apache directive (`CGIPassAuth On` for
the application folder); the `.htaccess` of the application is never touched. Check with an endpoint of yours that reads the
header. If you run your own image (`WEB_IMAGE`), put this in its Apache configuration instead (Apache 2.4.13 or later):

```
<Directory /var/www/html>
    CGIPassAuth On
</Directory>
```

or `SetEnvIf Authorization "(.*)" HTTP_AUTHORIZATION=$1` (needs `mod_setenvif`).

## 6. Updating

- **A parameter changes:** edit the parameter file, `render.sh <params> <project root> --force`, look at the difference
  (`git diff` if this folder is versioned), and apply it: a change in `portainer.env` means the stack variables in Portainer
  and **Update the stack**.
- **The compose file changes** (`stack/docker-compose.yml`): paste it again in the web editor, or **Pull and redeploy** for a
  Git repository stack, then **Update the stack**.
- **A Dockerfile, an entrypoint or `sshd_config` changes:** repeat steps 2 and 3 (copy the context, build), then in Portainer
  **Update the stack** with "Re-pull image" **off** (the images are local). If the container is not recreated (same tag),
  open it and press **Recreate**. A build where the `COPY` of an entrypoint says `CACHED` after you changed it means the server
  still has the old files: repeat step 2.
- The SSH host keys of the `tools` container live in `{{REMOTE_ROOT}}/tools/hostkeys`: rebuilding the image does not change the fingerprint.
- Optional switches of the `tools` container, as stack variables: `SSH_TCP_FORWARDING=1` allows `ssh -L` (for example a graphical
  MariaDB client from your Mac; off by default), `SSH_PORT` changes the port (then change `Port` in `~/.ssh/config` too).

## 7. Rules

- One user, `www-data` (uid 33): it can write the application files and `/repo`, nothing else. No root, no password.
- The database credentials live in the stack variables and in the SSH environment of the container: never in a file of the
  project, in chat, in logs or in commits. A credential that lands in chat or in a screenshot is considered compromised: rotate it.
- `app/` on the server is a **copy** of the application: your own copy of the source stays on the Mac, outside the repository.
- Changes to the instance's own files (`.htaccess`, the application's configuration) only with the owner's permission and with
  a backup outside the web folder: `/repo/.<name>.bak`.
- `deploy.sh`, `ci-local.sh`, `snapshot.sh`, `reset.sh` and `install-perfex.sh` accept only the modules, targets and aliases
  listed in `stack.conf` (or found as `<name>/<name>.php`): to allow another, change the parameters and render again, do
  not loosen the check.
- `reset.sh` asks a person to type the snapshot name. An AI agent does not set `STACK_RESET_YES` and does not pipe an answer:
  it asks you to run the command.
