---
name: {{STACK_NAME}}-test-stack
description: "How to reach the test instance of {{PROJECT_LABEL}} on the external Docker server (Portainer stack {{STACK_NAME}}, container tools over SSH with the alias {{SSH_ALIAS}}) and what never to ask for (root, Portainer, the Docker socket)"
metadata:
  type: reference
---

Test stack `{{STACK_NAME}}` on the owner's external Docker server (Portainer, Docker network `{{DOCKER_NETWORK}}`, DNS names your
machine resolves). **Never ask for** root, Portainer, the Docker socket or the internal network: the one agreed way in is the `tools`
container. Written by render.sh on {{RENDER_DATE}}; the full procedure is in `{{DEST_REL}}/README.md`.

- Application: `{{APP_URL}}` (image `{{WEB_IMAGE}}`; files in `{{REMOTE_ROOT}}/app` on the server, mounted as `/app` in the `tools`
  container too).
- `tools` container: `ssh {{SSH_ALIAS}}` (`{{TOOLS_HOST}}`, port 2222, user `www-data`, key only). PHP {{TOOLS_PHP_VERSIONS}} with the
  shim `PATH=/opt/php/<version>:$PATH`, Composer, rsync, MariaDB client. The code is mirrored to `/repo/{{SYNC_DIR}}`.
- Variables in the SSH environment: `PERFEX_URL`, `PERFEX_APP_PATH`, `PERFEX_DB_HOST/NAME/USER/PASSWORD`, `MAILPIT_URL`, `MAILPIT_SMTP_HOST/PORT`,
  `COMPOSER_HOME`. Their values are never to be written anywhere.
- Mailpit (if present): `{{MAILPIT_URL}}` (API `/api/v1/messages`), SMTP `{{MAILPIT_SMTP_HOST}}:{{MAILPIT_SMTP_PORT}}`.
- Scripts in `{{DEST_REL}}/`: `sync.sh`, `deploy.sh [--adopt] <module> [<target>]` (modules `{{DEPLOY_MODULES}}`), `ci-local.sh`,
  `run.sh '<command>'`, `snapshot.sh`, `reset.sh` (a person types the snapshot name: do not run it), `doctor.sh`, `install-perfex.sh`,
  `extra/` (the owner's own scripts, same rules) and `tests/` (fake ssh and rsync, no server touched).

**How to apply:** for practical checks use `curl` from your machine to `{{APP_URL}}` and `ssh {{SSH_ALIAS}}` (or `run.sh`) for logs, deploys,
the CI matrix and database queries. For the web interface, have the owner sign in the browser: never type credentials on a host that
is not local; uploads from the browser are the owner's, verify over SSH. Never put credentials in chat, files, logs or commits (if it
happens, ask for them to be rotated). Before touching the instance's own configuration, ask, and leave a backup in `/repo/.<name>.bak`.
`deploy.sh` stops on a module folder without its `.stack-managed` marker: ask the owner before using `--adopt`.
