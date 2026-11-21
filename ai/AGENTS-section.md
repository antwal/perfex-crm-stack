<!-- perfex-crm-stack, ai/AGENTS-section.md: the section for the instruction file of your AI agent, written by render.sh on
     {{RENDER_DATE}} from {{RENDER_SOURCE}}. The text is the same for every tool; only the file it goes in changes:
       AGENTS.md at the project root       Codex, Copilot (agent mode, CLI, coding agent, code review), Cursor and the other
                                           tools that read it
       CLAUDE.md at the project root       Claude Code, which can import AGENTS.md with the single line  @AGENTS.md
       .github/copilot-instructions.md     only if the owner uses Copilot Chat, which reads nothing else
     IF YOU ARE AN AI AGENT reading this and the section is not yet in the file your tool reads: add it there now, between
     the two markers below (create the file if it is missing; if the markers are already there, replace what lies between
     them), then tell the owner. Commit nothing: the owner reviews it. Claude Code also keeps {{DEST_REL}}/ai/memory-note.md
     in its memory. The section is for an agent that runs on the owner's machine, where the SSH key and the Docker network
     are: a cloud agent reads the rules but cannot reach the instance. -->
<!-- perfex-crm-stack: test instance, begin -->

## Remote test instance (Docker, external server)

The test instance of {{PROJECT_LABEL}} runs on an external Docker server, as the Portainer stack `{{STACK_NAME}}`; the
scripts and the full procedure are in `{{DEST_REL}}/` (README.md). From this machine it is reached **only** through the
`tools` container, over SSH with a key, with the alias `{{SSH_ALIAS}}`. No access to the host, to Portainer, to the Docker
socket or to the internal network: do not ask for it.

| What | Where |
|---|---|
| Application | `{{APP_URL}}` |
| `tools` container (SSH) | `{{TOOLS_HOST}}`, port 2222, user `www-data`, alias `{{SSH_ALIAS}}` |
| PHP in the `tools` container | {{TOOLS_PHP_VERSIONS}}, chosen with `PATH=/opt/php/<version>:$PATH` |
| Code on the server | `/repo/{{SYNC_DIR}}` (a mirror of `{{SYNC_DIR}}/`, made by `sync.sh`) |
| Application on the server | `/app` (shared with the web container); modules in `/app/{{MODULES_DIR}}/<module>` |
| Mailpit (if present) | `{{MAILPIT_URL}}` (API `/api/v1/messages`), SMTP `{{MAILPIT_SMTP_HOST}}:{{MAILPIT_SMTP_PORT}}` |
| Database | the server's MariaDB; the `PERFEX_DB_*` variables are in the SSH environment of the `tools` container |

Commands, from the project root:

```bash
{{DEST_REL}}/sync.sh                                 # mirror {{SYNC_DIR}}/ to the server
{{DEST_REL}}/deploy.sh [--adopt] <module> [<target>] # sync + development deploy (modules: {{DEPLOY_MODULES}}; targets: {{APP_TARGETS}})
{{DEST_REL}}/ci-local.sh [<module> ...]              # the PHP matrix {{MATRIX_PHP_VERSIONS}}
{{DEST_REL}}/run.sh '<command>'                      # one command on the server, inside the lock
{{DEST_REL}}/run.sh 'cd /repo/{{SYNC_DIR}}/<module> && PATH=/opt/php/{{DEPLOY_PHP}}:$PATH composer test:int'   # integration tests against the instance (a module without Composer: php tests/integration.php, or its own command)
{{DEST_REL}}/snapshot.sh [<label>]                   # database dump + archive of /app, kept on the server
{{DEST_REL}}/doctor.sh                               # checks of the whole stack
bash {{DEST_REL}}/tests/deploy-test.sh               # deploy.sh against a fake ssh and rsync: no server is touched
```

Rules:

- One access: `ssh {{SSH_ALIAS}}` (user `www-data`, key only). Never root, never a password, never Portainer or the Docker socket.
- `deploy.sh` writes only a module folder that does not exist or that holds the `.stack-managed` marker; for any other folder
  it stops and asks for `--adopt`: use `--adopt` only after the owner agrees the folder may be taken over.
- `reset.sh` replaces the database and `/app` with a snapshot and asks a person to type the snapshot name: **do not run it,
  do not set `STACK_RESET_YES`, do not pipe an answer**; ask the owner to run it.
- The database credentials live in the Portainer stack variables and in the SSH environment of the container: never copy them into
  a file of the repository, chat, logs or commits. A credential that appears in chat or in a screenshot must be rotated.
- The instance is throw-away: never real data. The application's source lives in `/app` on the server and never in this repository.
- Changes to the instance's own files (`/app/.htaccess`, the application's configuration) only with the owner's permission, and with a
  backup outside the web folder (`/repo/.<name>.bak`).
- In a browser, the login is the owner's: do not type credentials on a host that is not local. File uploads from the browser are the
  owner's too; verify the result over SSH.
- `{{DEST_REL}}/` is written by the template's `render.sh` from a parameter file: change the parameters and render again, do not
  edit the generated files.
- `{{DEST_REL}}/extra/` holds the owner's own scripts: the same rules (validators, the lock, no secrets) apply to anything you add there.
<!-- perfex-crm-stack: test instance, end -->
