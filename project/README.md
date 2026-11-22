# Test instance of {{PROJECT_LABEL}} on a Docker server (Portainer)

Written by `render.sh` on {{RENDER_DATE}} from `{{RENDER_SOURCE}}`: to change a value, change the parameter file and render again
(`render.sh <params> <project root> --force`), do not edit the files of this folder.

The stack `{{STACK_NAME}}` runs on a Docker server managed with Portainer. Your machine reaches it over the Docker network's DNS
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
Run the local steps from the **project root**, the folder this was rendered for:

```bash
cd "{{PROJECT_ROOT_ABS}}"
```

The template (with `stack/`) is at `{{TEMPLATE_REL}}` from there.

### Step 1, on your machine: a key and an alias

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

Copy the line it prints: step 3 needs it. The private key never leaves your machine and is never pasted into a chat.

### Step 2, on your machine: copy the build context of the two images to the server

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

The web image (Apache + PHP-FPM {{WEB_PHP_VERSION}}, with the extensions Perfex CRM needs). If you set `WEB_IMAGE` to an image of
your own, skip this build: that image does not come from `web/Dockerfile`, you provide it yourself (built on the server, or
pulled from your registry) under the name `{{WEB_IMAGE}}`:

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
3. The four database variables arrive from the file **empty**: type their values in the form, `PERFEX_DB_HOST`, `PERFEX_DB_NAME`,
   `PERFEX_DB_USER`, `PERFEX_DB_PASSWORD`. The values go in no file; while they are empty the stack refuses to start, on purpose.
4. **Deploy the stack**. The containers are `{{STACK_NAME}}` (web) and `{{STACK_NAME}}-tools`.

### Step 6, on your machine: check

```bash
{{DEST_REL}}/doctor.sh
```

It checks the SSH login, PHP and Composer in the container, the mounts, the stack variables (names only), the database,
that `locked.sh` is on the server, and that `{{APP_URL}}` answers; once the application is installed it also says, as a note,
whether `APP_BASE_URL` is fixed or dynamic (see step 7). On a fresh stack it reports `locked.sh` missing: `sync.sh`
puts it there together with your code (deploy and the matrix run it first), and `run.sh`, `snapshot.sh`, `reset.sh`,
`install-perfex.sh` and `base-url.sh` copy it by themselves when it is not there yet.

### Step 7, the application

Perfex CRM is proprietary: **bring your own licensed copy**, this template contains none of it; if you do not own a license
yet, buy it on CodeCanyon: https://codecanyon.net/item/perfex-powerful-open-source-crm/14013737. Copy your folder (the one
with `index.php` and `application/`) or your zip into `/app`:

```bash
{{DEST_REL}}/install-perfex.sh <your Perfex folder or zip>
```

Open `{{APP_URL}}` in a browser and complete the installation wizard: you create the administrator there. Then remove the
install folder, and point the application's email at Mailpit if you use it (Setup > Settings > Email: SMTP host
`{{MAILPIT_SMTP_HOST}}`, port `{{MAILPIT_SMTP_PORT}}`, no authentication):

```bash
{{DEST_REL}}/run.sh 'rm -rf /app/install'
```

**Behind a tunnel or an HTTPS proxy.** If you reach the instance through a tunnel (ngrok, Cloudflare Tunnel) or an HTTPS proxy
with a self-signed certificate, Perfex builds its links with the address the wizard wrote in `APP_BASE_URL`
(`application/config/app-config.php`), and the page does not come back. This makes the address follow the request instead:

```bash
{{DEST_REL}}/base-url.sh dynamic
```

`{{DEST_REL}}/base-url.sh fixed` puts the wizard's address back, and `{{DEST_REL}}/base-url.sh status` says which of the two you
have. The script comments the `define('APP_BASE_URL', …)` line of the wizard and adds, between two marker lines, a block that on
the command line (cron) keeps the configured address and on the web takes the scheme (`X-Forwarded-Proto`, `HTTPS`, port 443)
and the host (`X-Forwarded-Host`, else `Host`) from the request. It keeps a copy of the file in `/repo/.app-config-app.php.bak`
first, checks the new file with `php -l` before it replaces the old one, and keeps the line endings of the file (the wizard
writes CRLF). **Test instance only:** with `dynamic` the application trusts the `Host` header of every request, so a forged
header poisons the links in the emails it sends (a password reset, for one); on a real site that is a hole, never do it there.
Wait a few seconds after the change: the web container's opcache revalidates every two seconds. A file you already corrected by
hand, with a block of your own, has none of the markers the script looks for: `status` says "edited by hand" and `dynamic`
refuses; put the line the wizard wrote back, then run `dynamic`.

By hand: comment the `define('APP_BASE_URL', …)` line of `application/config/app-config.php` (put `// ` in front of it) and paste
this block right after it, with your address in the first `define`:

```php
// perfex-crm-stack: dynamic APP_BASE_URL (base-url.sh), begin
// The address follows the request, so that the instance also answers through a tunnel or an HTTPS proxy (ngrok, Cloudflare
// Tunnel, a reverse proxy with a self-signed certificate). On the command line (cron) the configured address stays.
// TEST INSTANCE ONLY: the base URL trusts the Host header of the request. Remove with: base-url.sh fixed
if (php_sapi_name() === 'cli' || (empty($_SERVER['HTTP_X_FORWARDED_HOST']) && empty($_SERVER['HTTP_HOST']))) {
    define('APP_BASE_URL', '{{APP_URL}}/');
} else {
    $is_https = (!empty($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https')
        || (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off')
        || (isset($_SERVER['SERVER_PORT']) && (int) $_SERVER['SERVER_PORT'] === 443);
    $host = !empty($_SERVER['HTTP_X_FORWARDED_HOST']) ? $_SERVER['HTTP_X_FORWARDED_HOST'] : $_SERVER['HTTP_HOST'];
    $host = trim(explode(',', $host)[0]);
    define('APP_BASE_URL', ($is_https ? 'https://' : 'http://') . $host . '/');
    unset($is_https, $host);
}
// perfex-crm-stack: dynamic APP_BASE_URL (base-url.sh), end
```

(With the original line commented by `// ` and the two marker lines kept as above, `base-url.sh status` and `fixed` understand
a file edited this way.)

If your modules or an API need the `Authorization` header (Bearer tokens, Basic), set the stack variable
`PASS_AUTHORIZATION=1` and update the stack (see "The Authorization header" below).

## 2. Daily use (from the project root)

Every command below is relative to the project root: `cd "{{PROJECT_ROOT_ABS}}"` first. The scripts take their values from
`stack.conf`; `STACK_SSH=<alias>` in the environment points them at another stack rendered with the same layout.

| Command | What it does |
|---|---|
| `{{DEST_REL}}/sync.sh` | mirrors `{{SYNC_DIR}}/` to `/repo/{{SYNC_DIR}}` on the server (without `vendor/`, `.git`, zips), and puts `locked.sh` in place |
| `{{DEST_REL}}/deploy.sh [--adopt] <module> [<target>]` | sync, then on the server: `composer install --no-dev` (when the module has a `composer.json`), copy of the module into `/<target>/{{MODULES_DIR}}/<module>`, development dependencies back in the repository copy (the same). Modules: `{{DEPLOY_MODULES}}` (empty = every `<name>/<name>.php` found); also the names of `DEPLOY_EXTRA` in `stack.conf` (modules that live deeper than `{{SYNC_DIR}}/<name>/`, see below); targets: `{{APP_TARGETS}}` |
| `{{DEST_REL}}/ci-local.sh [<module> ...]` | the PHP matrix `{{MATRIX_PHP_VERSIONS}}`, one job per module and version, the road chosen on the server by the module's folder: with a `composer.json`, `composer install`, `validate --strict`, `run {{CI_CHECK_SCRIPT}}`; without one, `php -l` on every PHP file of the module and then `{{CI_CHECK_FILE}}` if the module has it. Then the static analysis script (Composer modules only), if there is one, on PHP {{STATIC_PHP}} |
| `{{DEST_REL}}/run.sh '<command>'` | one command on the server, inside the lock, as `www-data` (it puts `locked.sh` there first if it is missing). Integration tests: `run.sh 'cd /repo/{{SYNC_DIR}}/<module> && PATH=/opt/php/{{DEPLOY_PHP}}:$PATH composer test:int'`, or, for a module without Composer, `… php tests/integration.php` |
| `{{DEST_REL}}/snapshot.sh [<label>]` | a dump of the database and an archive of `/app`, kept on the server in `/repo/.tmp/snapshots/<name>/` |
| `{{DEST_REL}}/reset.sh <name>` / `--list` | puts a snapshot back after you type its name; `--list` shows the snapshots |
| `{{DEST_REL}}/doctor.sh` / `--guide` | the checks / the setup steps with your values |
| `{{DEST_REL}}/install-perfex.sh <folder or zip>` | copies your Perfex CRM into `/app` (step 7) |
| `{{DEST_REL}}/base-url.sh status\|dynamic\|fixed [<target>]` | `APP_BASE_URL` of the application: the one the wizard wrote (`fixed`), or following the request behind a tunnel or an HTTPS proxy (`dynamic`, test instance only); `status` changes nothing (step 7) |
| `bash {{DEST_REL}}/tests/deploy-test.sh` | deploy.sh against a fake ssh and rsync, and its server script against a folder tree: nothing touches a server |
| `bash {{DEST_REL}}/tests/locked-test.sh` | run.sh and locked.sh without a server |
| `bash {{DEST_REL}}/tests/scripts-test.sh` | ci-local.sh (and its server script against a folder tree, with the example module `plain_module/` too), snapshot.sh, reset.sh, install-perfex.sh, base-url.sh (its server script against an `app-config.php` in LF and in CRLF), doctor.sh, the copy of locked.sh by run.sh and the example scripts of the template's `examples/extra/`, against a fake ssh, rsync, curl, git, npx, composer and php |
| `bash {{DEST_REL}}/tests/render-test.sh` | `render.sh`, with good and bad parameters (it finds the template through `TEMPLATE_REL`, or `STACK_TEMPLATE_DIR`) |
| `{{DEST_REL}}/extra/` | your own scripts; `render.sh --force` rewrites only its `README.md` (see "Writing your own script" below) |

Other things you will want, all through `ssh {{SSH_ALIAS}}` or `run.sh`:

```bash
{{DEST_REL}}/run.sh 'tail -n 50 /app/application/logs/log-$(date +%F).php'
{{DEST_REL}}/run.sh 'MYSQL_PWD="$PERFEX_DB_PASSWORD" mariadb -h "$PERFEX_DB_HOST" -u "$PERFEX_DB_USER" "$PERFEX_DB_NAME" -e "SHOW TABLES"'
curl -s {{MAILPIT_URL}}/api/v1/messages | jq '.messages[0].Subject'
```

(The log path is Perfex's. The credentials stay in the container: the variables are expanded on the server. The password goes
in `MYSQL_PWD`, not in a `-p…` option, because an environment variable does not show up in `ps`, while a command-line argument
does, to every process in the container. `mariadb` is the client the tools image ships, the same one `snapshot.sh` uses.)

PHP versions are chosen with `PATH=/opt/php/<version>:$PATH`: a shim that makes `php` that version, for Composer scripts,
`vendor/bin/*` and the check file of a module without Composer too. The release package of a module does **not** go through `deploy.sh`: your build produces it and you
install it from the application's interface, as a customer would.

A heavy job at a time: `deploy.sh`, `ci-local.sh`, `run.sh`, `snapshot.sh`, `reset.sh` and `base-url.sh` wait for each other at the lock
`{{LOCK_FILE}}` and run at low priority. If the lock is busy for over a minute, the script says so and keeps waiting.

### What a module needs to be deployed

A folder `<name>/<name>.php` under `{{SYNC_DIR}}/`, with `<name>` made of lowercase letters, digits and `_`, starting with a letter
(2 to 64 characters). That is also what a Perfex module is. A module has one of two forms, and `ci-local.sh` and `deploy.sh` tell
them apart on the server by the presence of a `composer.json` in its folder:

- **with a `composer.json`**: the matrix runs its `{{CI_CHECK_SCRIPT}}` script on every PHP version, and `deploy.sh` installs its
  dependencies. The example `examples/module/sample_module/` of the template shows the shape, including a `test:int` script and
  `tests/Integration/TestInstance.php`, a helper that reads the stack variables (`PERFEX_URL`, `PERFEX_APP_PATH`,
  `PERFEX_DB_*`, `MAILPIT_*`) that the SSH session provides;
- **without one**: the matrix runs `php -l` on every PHP file of the module (`vendor/`, `node_modules/` and the dot-folders
  are left out) and then the check file `{{CI_CHECK_FILE}}` (`CI_CHECK_FILE` in your parameters; `.sh` runs with bash, `.php`
  with php), if the module has it; `deploy.sh` copies the folder as it is. The example `examples/module/plain_module/` shows the shape:
  the same module and the same checks, with `require_once`, `tests/check.sh` and `php tests/integration.php`.

A module with both takes the Composer road, and its check file is not run. The check file lives under `tests/`, which
`DEPLOY_EXCLUDES` keeps out of the application; a check file elsewhere must be added to the excludes.

A module that lives **inside another folder** of `{{SYNC_DIR}}/` (a sample module in `<module>/examples/<sample>/`, say) is
listed in the parameter `DEPLOY_EXTRA` as `<folder relative to {{SYNC_DIR}}>:<name>`, for example
`mymodule/examples/demo_notes:demo_notes`: the folder must hold `<name>.php`, and `deploy.sh demo_notes` copies it to
`/<target>/{{MODULES_DIR}}/demo_notes`. It follows the rules of every module: the `.stack-managed` marker, `--adopt`,
the excludes, no folder with a dot name, `vendor/.htaccess`. No folder of the path to it may be a symbolic link, and the name must
not also be a module of `{{SYNC_DIR}}/`.

### Writing your own script

Your own scripts live in `{{DEST_REL}}/extra/`: `render.sh --force` rewrites only the `README.md` of that folder and leaves
everything else there as it is. A script starts with the lines below and is made executable (`chmod 755`):

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd -P)"   # the folder of the stack scripts (stack.conf, lib.sh, locked.sh)
# shellcheck source=../lib.sh
. "$HERE/lib.sh"
stack_load "$HERE"
```

`stack_load` reads `stack.conf` and gives the script `HERE`, `HOST` (the SSH alias; `STACK_SSH` in the environment replaces
it), `ROOT` (the project root), `REPO_DIR` (`$ROOT/{{SYNC_DIR}}`, the folder mirrored to the server) and every variable of
`stack.conf`: `APP_URL`, `LOCAL_TMP_DIR`, `SYNC_DIR`, `DEFAULT_PHP`, `TOOLS_PHP_VERSIONS`, `MAILPIT_URL`, and the others.
`lib.sh` adds the functions below. They are the API of your scripts: from version 0.2.0 of the template they keep their names
and arguments until the next major version, and the template's `CHANGELOG.md` announces a change.

| Function | What it does |
|---|---|
| `die <message>` | prints the message on the error output and exits with status 1 |
| `in_list <word> <word> ...` | succeeds when the first word is one of the others: `in_list "$php" $TOOLS_PHP_VERSIONS` |
| `valid_host`, `valid_module`, `valid_ci_module`, `valid_target`, `valid_php` | succeed when the value matches the strict pattern of an SSH alias, of a module folder name, of a folder tested by `ci-local.sh` (a library may have `-`), of an application folder (`app`, `app-extra`), of a PHP version (`8.4`) |
| `valid_relpath <path> [allow-empty]` | a relative folder: no `..`, no `//`, no leading `/` or `.`, no trailing `/` |
| `valid_globs "<words>"` | blank-separated rsync patterns made of letters, digits and `. _ - / * ?` |
| `discover_modules <folder>` | the names of the sub-folders `<name>/<name>.php`, one per line (symbolic links are skipped) |
| `deploy_module_names`, `ci_module_names` | the modules `deploy.sh` and `ci-local.sh` accept: the closed list of `stack.conf`, or the ones found in `REPO_DIR` |
| `deploy_extra_names`, `deploy_extra_source <name>` | the names of `DEPLOY_EXTRA`, and the folder (relative to `SYNC_DIR`) listed for one name; validate it with `valid_relpath` before using it |
| `remote_locked '<command>'` | runs a shell command on the server, inside the lock, as one argument of `locked.sh`; the standard input reaches the command |
| `ensure_locked_sh` | puts `locked.sh` on the server when it is not there (one ssh round trip) |

**The rule.** Everything that ends up in a command run on the server, or handed to another program, passes a validator of
`lib.sh` or a closed list first, and the checks come **before** the first call. Values go to the server as positional
parameters quoted with `printf '%q'`, to a script sent with `bash -s --` and a here-document, never pasted into its text:
`deploy.sh` is the model (the `_args=` line and the `remote_locked "bash -s -- $_args" <<'REMOTE'` that follows it), and the
script on the server checks what it receives again: the server does not trust your machine more than your machine trusts free text.

**Heavy jobs.** `remote_locked '<command>'` runs the command inside the lock `{{LOCK_FILE}}`: one heavy job at a time per
server, at low priority, and whatever is left in its process group is terminated when it ends. The standard input crosses
it, so a probe that must not consume it reads from `/dev/null` (`ensure_locked_sh` shows how). A script that does not go
through `sync.sh` (which copies `locked.sh` together with the code) calls `ensure_locked_sh` before `remote_locked`. To
choose the PHP on the server put `PATH=/opt/php/<version>:$PATH` in the command, after `valid_php` and `in_list "$v"
$TOOLS_PHP_VERSIONS` have checked the version.

**Files and secrets.** Temporary files and outputs go in `$ROOT/$LOCAL_TMP_DIR/<name of the script>/` (`{{LOCAL_TMP_DIR}}/`
in this project): one folder to ignore and to clean. No secret in a file, a log or an output: the database credentials live
in the stack variables on the server, and a script that needs them reads them there, over ssh. The scripts run on your machine:
write bash 3.2 (no associative arrays, no `mapfile`, no `${var,,}`, and no `"${array[@]}"` of an empty array under `set -u`).

**The smallest complete script** prints the version of the default PHP of the tools container, inside the lock. Save it as
`{{DEST_REL}}/extra/php-version.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd -P)"
. "$HERE/lib.sh"
stack_load "$HERE"
valid_php "$DEFAULT_PHP" || die "invalid DEFAULT_PHP: $DEFAULT_PHP"
# shellcheck disable=SC2086
in_list "$DEFAULT_PHP" $TOOLS_PHP_VERSIONS || die "PHP $DEFAULT_PHP is not in the tools image"
ensure_locked_sh
remote_locked "PATH=/opt/php/$DEFAULT_PHP:\$PATH php -v | head -n 1"
```

**Examples.** The template has three scripts of this kind in `examples/extra/`: `infection-diff.sh` (Infection on the files of a
module that changed, on the server), `bench.sh` (the response times of one URL, with percentiles) and `e2e.sh` (a Playwright
suite of your project against the instance). Copy the ones you want:

```bash
cp {{TEMPLATE_REL}}/examples/extra/<name>.sh {{DEST_REL}}/extra/
```

`e2e.sh <folder>` runs `npx playwright test` in a folder of your project that holds a `playwright.config.ts`, and hands the
instance to it through the environment: `PERFEX_URL` (the application's address), `PLAYWRIGHT_OUTPUT_DIR` (a folder under
`{{LOCAL_TMP_DIR}}/e2e/`), `STACK_SSH` (the SSH alias, for a fixture that must be made on the server) and `MAILPIT_URL` when
there is one. The template brings no Node: the suite, Playwright and its browsers are yours. The smallest configuration that
reads those variables:

```ts
import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './specs',                                              // your *.spec.ts files
  outputDir: process.env.PLAYWRIGHT_OUTPUT_DIR ?? 'test-results',  // e2e.sh puts it under {{LOCAL_TMP_DIR}}/e2e/
  use: { baseURL: process.env.PERFEX_URL },                        // e2e.sh sets it to the address of the application
  reporter: 'list',
});
```

**Testing a script of yours.** Use the scheme of `tests/scripts-test.sh`: a fake `ssh`, `rsync` and `curl` that only record
their calls, first in `PATH`; run your script with them, and check that every refusal made no call at all and that a good run
made the `ssh` call you expect. The fakes are at the top of that test: copy them.

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
  MariaDB client from your machine; off by default), `SSH_PORT` changes the port (then change `Port` in `~/.ssh/config` too).

## 7. Rules

- One user, `www-data` (uid 33): it can write the application files and `/repo`, nothing else. No root, no password.
- The database credentials live in the stack variables and in the SSH environment of the container: never in a file of the
  project, in chat, in logs or in commits. A credential that lands in chat or in a screenshot is considered compromised: rotate it.
- `app/` on the server is a **copy** of the application: your own copy of the source stays on your machine, outside the repository.
- Changes to the instance's own files (`.htaccess`, the application's configuration) only with the owner's permission and with
  a backup outside the web folder: `/repo/.<name>.bak`.
- `deploy.sh`, `ci-local.sh`, `snapshot.sh`, `reset.sh`, `install-perfex.sh` and `base-url.sh` accept only the modules, targets and aliases
  listed in `stack.conf` (or found as `<name>/<name>.php`): to allow another, change the parameters and render again, do
  not loosen the check.
- `reset.sh` asks a person to type the snapshot name. An AI agent does not set `STACK_RESET_YES` and does not pipe an answer:
  it asks you to run the command.
