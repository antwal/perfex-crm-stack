# Prompts for an AI agent

Two ready prompts for an AI agent with shell access (Claude Code or another): **A** to connect to a stack that already runs,
**B** to build a new one. Copy one, fill the blanks of its table (the rows with a value already have the default), and
paste it in a new session opened at the **root of your project**. They assume the template is in the project as
`stack_docker/`; if it is somewhere else, change the path.

What the agent never has, and never asks for: root on the server, Portainer, the Docker socket, the private SSH key, the
database password. You run the steps that need them; the agent prepares the commands.

## A. Connect to a stack that is already running

```text
This project uses a test instance on a remote Docker server that is already running, made with the template in
`stack_docker/`. You only connect to it: you create and change nothing on the server.

1. Read `stack_docker/README.md`. Write `stack_docker/params.env` with the values of the table below (the defaults of
   `stack_docker/params.example.env` for anything not listed), run
   `stack_docker/render.sh --check stack_docker/params.env`, fix what it reports, then run
   `stack_docker/render.sh stack_docker/params.env .` from the project root. Use `--force` only if I tell you the
   folder must be written again.
2. Do not touch my SSH key or ~/.ssh/config: the alias already exists. Run
   `ssh <SSH_ALIAS> 'php -v | head -1; composer --version; ls /app /repo'` and show me the output. If it fails, tell me:
   do not try other users, ports, keys or passwords.
3. Run `<DEST_DIR>/doctor.sh` and show me the output.
4. Add the section of `<DEST_DIR>/ai/CLAUDE-section.md` to this project's CLAUDE.md (create the file if it is missing) and
   keep the note `<DEST_DIR>/ai/memory-note.md` in your memory.
5. From now on use only the scripts in `<DEST_DIR>` and `ssh <SSH_ALIAS>`. The daily commands are in
   `<DEST_DIR>/README.md`, section 2.

Rules: no secrets in files, chat, logs or commits; never type credentials for me in a browser; no change to the
instance's own files without asking me first; you have no root, Portainer or Docker socket access and you do not ask for it.

Parameters:
| Parameter     | Value |
|---------------|-------|
| PROJECT_LABEL |       |
| STACK_NAME    |       |
| APP_HOST      |       |
| TOOLS_HOST    |       |
| SSH_ALIAS     |       |
| REMOTE_ROOT   |       |
| DEST_DIR      | tools/docker |
| SYNC_DIR      | modules |
| MODULES_DIR   | modules |
| DEPLOY_MODULES|       |
```

## B. Build a new stack

```text
Use the template in `stack_docker/` to prepare a test instance of this project on a remote Docker server managed with
Portainer. Read `stack_docker/README.md` first, then go step by step. Do not connect to the server before I say so, and
stop for my answer where a step says so.

1. Write `stack_docker/params.env` with the values of the table below (the defaults of `stack_docker/params.example.env`
   for anything not listed) and tell me which defaults you used. No secrets in the file: the database credentials are
   stack variables I set in Portainer.
2. Run `stack_docker/render.sh --check stack_docker/params.env`, fix what it reports, then
   `stack_docker/render.sh stack_docker/params.env .` from the project root. Show me the list of written files.
3. Show me the `ssh-keygen` command and the `~/.ssh/config` block of step 1 of `<DEST_DIR>/README.md`. STOP: run them only
   after my OK. The private key stays on my Mac and is never pasted in chat: show me only the `.pub` line.
4. Give me, in one ordered list, the commands I run myself on the server as root and in Portainer (steps 2 to 5 of
   `<DEST_DIR>/README.md`), with my values already filled in. STOP until I tell you it is done.
5. Run `<DEST_DIR>/doctor.sh` and show me the output. If the application is not installed yet, tell me to run
   `<DEST_DIR>/install-perfex.sh` with my own copy of Perfex CRM, and wait: the installation wizard in the browser is mine.
6. Add `<DEST_DIR>/ai/CLAUDE-section.md` to this project's CLAUDE.md, keep `<DEST_DIR>/ai/memory-note.md` in your memory,
   run `bash <DEST_DIR>/tests/deploy-test.sh` and `bash <DEST_DIR>/tests/locked-test.sh`, and finish with a summary: what
   works, what is missing, the daily commands.

Rules: no secrets in files, chat, logs or commits; never type credentials for me in a browser; no change to the instance's
own files without asking me first; you have no root, Portainer or Docker socket access and you do not ask for it; touch
nothing outside `stack_docker/` and the rendered folder unless I ask.

Parameters:
| Parameter     | Value |
|---------------|-------|
| PROJECT_LABEL |       |
| STACK_NAME    |       |
| APP_HOST      |       |
| TOOLS_HOST    |       |
| SSH_ALIAS     |       |
| REMOTE_ROOT   |       |
| WEB_PHP_VERSION | 8.4 |
| DEST_DIR      | tools/docker |
| SYNC_DIR      | modules |
| MODULES_DIR   | modules |
| DEPLOY_MODULES|       |
| CI_MODULES    |       |
| MAILPIT_URL   |       |
```

## Notes for whoever fills the table

- `STACK_NAME`, the DNS names, the alias and `REMOTE_ROOT` must be **new** for every project: two stacks with the same name
  or the same folder step on each other.
- `DEPLOY_MODULES` and `CI_MODULES` are blank-separated lists of folder names. Leave them empty to use every
  `<name>/<name>.php` folder found under `SYNC_DIR`.
- `params.env` is a bash file that `render.sh` sources: keep it out of version control if it holds anything you would not publish.
