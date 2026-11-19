# extra/: your own scripts

This folder is yours. `render.sh` writes only this file here, and `render.sh --force` rewrites only this file: every script
you put in this folder stays exactly as it is, whatever you render. Keep them in version control with the rest of your project.

A script that lives here starts with these lines. They load `stack.conf` and the helpers of `lib.sh` from the folder above:

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd -P)"   # the folder of the stack scripts (stack.conf, lib.sh, locked.sh)
# shellcheck source=../lib.sh
. "$HERE/lib.sh"
stack_load "$HERE"
```

From there the script has:

- `HOST`, the SSH alias (`{{SSH_ALIAS}}`, or `STACK_SSH` from the environment), `ROOT`, the project root, and `REPO_DIR`, the code
  folder that `sync.sh` mirrors to the server;
- every value of `stack.conf` as a variable: `APP_URL`, `LOCAL_TMP_DIR`, `DEFAULT_PHP`, `TOOLS_PHP_VERSIONS`, ...;
- `remote_locked '<command>'` (a heavy job on the server, inside the lock), `ensure_locked_sh`, and the validators
  (`valid_module`, `valid_php`, `valid_relpath`, ...).

The rules are the ones of the scripts next to this folder: everything that ends up in a command run on the server or handed to
another program is checked first, by a validator of `lib.sh` or against a closed list; temporary files go under
`$ROOT/$LOCAL_TMP_DIR/` (`{{LOCAL_TMP_DIR}}` for this project), in a folder named after the script; no secret in a script,
in a log or in an output. `chmod 755` the file, and keep it bash 3.2 clean (the bash of macOS).

The complete description, with the smallest working script, is the section "Writing your own script" of `{{DEST_REL}}/README.md`.
