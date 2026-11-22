# Prompts for an AI agent

Two ready prompts for an AI agent with shell access on your machine (Claude Code, Codex, Copilot in agent mode or another): **A** to connect to a stack that already runs,
**B** to build a new one. Copy one, fill the blanks of its table (the rows with a value already have the default), and
paste it in a new session opened at the **root of your project**. They assume the template is in the project as
`perfex-crm-stack/`, the name a clone gets; if it is somewhere else, change the path.

What the agent never has, and never asks for: root on the server, Portainer, the Docker socket, the private SSH key, the
database password. You run the steps that need them; the agent prepares the commands.

## A. Connect to a stack that is already running

```text
This project uses a test instance on a remote Docker server that is already running, made with the template in
`perfex-crm-stack/`. You only connect to it: you create and change nothing on the server.

1. Read `perfex-crm-stack/README.md`. Write `perfex-crm-stack/params.env` with the values of the table below (the
   defaults of `perfex-crm-stack/params.example.env` for anything not listed), run
   `perfex-crm-stack/render.sh --check perfex-crm-stack/params.env`, fix what it reports, then run
   `perfex-crm-stack/render.sh perfex-crm-stack/params.env .` from the project root. Use `--force` only if I tell you
   the folder must be written again.
2. Check this project's `.gitignore`: it must ignore `perfex-crm-stack/` (unless it is a git submodule), the temporary
   folder (`.tmp`, or the `LOCAL_TMP_DIR` of `params.env`) and my copy of Perfex CRM if it is in the project (a folder
   or a zip). Add the missing lines, show me the file, commit nothing.
3. Do not touch my SSH key or ~/.ssh/config: the alias already exists. Run
   `ssh <SSH_ALIAS> 'php -v | head -1; composer --version; ls /app /repo'` and show me the output. If it fails, tell me:
   do not try other users, ports, keys or passwords.
4. Run `<DEST_DIR>/doctor.sh` and show me the output.
5. Install `<DEST_DIR>/ai/AGENTS-section.md` as its header says: between its two markers, in the instruction file your tool
   reads at the project root (`AGENTS.md`; for Claude Code `CLAUDE.md`, which may just import it with `@AGENTS.md`), creating
   the file if it is missing; show me the result and commit nothing. If you are Claude Code, also keep
   `<DEST_DIR>/ai/memory-note.md` in your memory.
6. From now on use only the scripts in `<DEST_DIR>` and `ssh <SSH_ALIAS>`. The daily commands are in
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
| IMAGE_OWNER   |       |
| DEST_DIR      | tools/docker |
| SYNC_DIR      | modules |
| MODULES_DIR   | modules |
| DEPLOY_MODULES|       |
| DEPLOY_EXTRA  |       |
```

## B. Build a new stack

```text
Use the template in `perfex-crm-stack/` to prepare a test instance of this project on a remote Docker server managed with
Portainer. Read `perfex-crm-stack/README.md` first, then go step by step. Do not connect to the server before I say so, and
stop for my answer where a step says so.

1. Write `perfex-crm-stack/params.env` with the values of the table below (the defaults of
   `perfex-crm-stack/params.example.env` for anything not listed) and tell me which defaults you used. No secrets in the
   file: the database credentials are stack variables I set in Portainer.
2. Run `perfex-crm-stack/render.sh --check perfex-crm-stack/params.env`, fix what it reports, then
   `perfex-crm-stack/render.sh perfex-crm-stack/params.env .` from the project root. Show me the list of written files.
3. Check this project's `.gitignore`: it must ignore `perfex-crm-stack/` (unless it is a git submodule), the temporary
   folder (`.tmp`, or the `LOCAL_TMP_DIR` of `params.env`) and my copy of Perfex CRM if it is in the project (a folder
   or a zip). Add the missing lines, show me the file, commit nothing.
4. Show me the `ssh-keygen` command and the `~/.ssh/config` block of step 1 of `<DEST_DIR>/README.md`. STOP: run them only
   after my OK. The private key stays on my machine and is never pasted in chat: show me only the `.pub` line.
5. Give me, in one ordered list, the commands I run myself on the server as root and in Portainer (steps 2 to 5 of
   `<DEST_DIR>/README.md`), with my values already filled in. STOP until I tell you it is done.
6. Run `<DEST_DIR>/doctor.sh` and show me the output. If the application is not installed yet, tell me to run
   `<DEST_DIR>/install-perfex.sh` with my own licensed copy of Perfex CRM (if I do not own a license yet, I buy it at
   https://codecanyon.net/item/perfex-powerful-open-source-crm/14013737), and wait: the installation wizard in the
   browser is mine. After the wizard, if I reach the instance through a tunnel or an HTTPS proxy, I tell you and you run
   `<DEST_DIR>/base-url.sh dynamic` (test instance only: the application then trusts the `Host` header).
7. Install `<DEST_DIR>/ai/AGENTS-section.md` as its header says (in `AGENTS.md`, or `CLAUDE.md` for Claude Code, between its
   two markers, creating the file if it is missing; commit nothing); if you are Claude Code, also keep
   `<DEST_DIR>/ai/memory-note.md` in your memory. Then run `bash <DEST_DIR>/tests/deploy-test.sh` and
   `bash <DEST_DIR>/tests/locked-test.sh`, and finish with a summary: what works, what is missing, the daily commands.

Rules: no secrets in files, chat, logs or commits; never type credentials for me in a browser; no change to the instance's
own files without asking me first; you have no root, Portainer or Docker socket access and you do not ask for it; touch
nothing outside `perfex-crm-stack/`, the rendered folder and `.gitignore` unless I ask.

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
| IMAGE_OWNER   |       |
| DEST_DIR      | tools/docker |
| SYNC_DIR      | modules |
| MODULES_DIR   | modules |
| DEPLOY_MODULES|       |
| DEPLOY_EXTRA  |       |
| CI_MODULES    |       |
| MAILPIT_URL   |       |
```

## Notes for whoever fills the table

- `STACK_NAME`, the DNS names, the alias and `REMOTE_ROOT` must be **new** for every project: two stacks with the same name
  or the same folder step on each other.
- `DEPLOY_MODULES` and `CI_MODULES` are blank-separated lists of folder names. Leave them empty to use every
  `<name>/<name>.php` folder found under `SYNC_DIR`.
- `params.env` is a bash file that `render.sh` sources: keep it out of version control if it holds anything you would not publish.
- The template folder (a clone or a copy), the temporary folder `LOCAL_TMP_DIR` and your copy of Perfex CRM are not part of
  your repository: the prompts have the agent add them to `.gitignore`. A submodule is recorded by git itself and is not ignored.
- `ai/AGENTS-section.md` is the same text for every tool; its header says which file each tool reads (`AGENTS.md`, `CLAUDE.md`,
  `.github/copilot-instructions.md`) and tells an agent to install it there if it is missing. The prompts are for an agent on
  your machine: a cloud agent (the Copilot coding agent, Codex cloud) reads the rules but has no SSH key and no route to the Docker network.
