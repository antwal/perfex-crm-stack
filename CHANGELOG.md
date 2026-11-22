# Changelog

The changes of each version of the template, in the format of [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions are
numbered MAJOR.MINOR.PATCH. The functions of `project/lib.sh` listed in "Writing your own script" (the generated README) are the API
of the scripts you write yourself: they keep their names and arguments until the next major version.

## [Unreleased]

### Added

- `base-url.sh status|dynamic|fixed [<target>]`, for an instance reached through a tunnel (ngrok, Cloudflare Tunnel) or an HTTPS
  proxy with a self-signed certificate. Perfex builds its links with the address the installation wizard wrote in `APP_BASE_URL`
  (`application/config/app-config.php`), and behind a tunnel the page does not come back. `dynamic` comments that `define` and adds,
  between two marker lines, a block that keeps the configured address on the command line and, on the web, takes the scheme
  (`X-Forwarded-Proto`, `HTTPS`, port 443) and the host (`X-Forwarded-Host`, else `Host`) from the request; `fixed` removes the
  block and uncomments the line; `status` says which of the two the file is in and changes nothing. A copy of the file is kept in
  `/repo/.app-config-<target>.php.bak` first, the new file is checked with `php -l` before it replaces the old one, the owner,
  the mode and the line endings are kept (the file the wizard writes is CRLF), and only the `APP_BASE_URL` line is read or
  printed: the file holds the credentials of the instance. A file edited by hand, or an address that is not in the shape the
  wizard writes, is refused. **Test instance only:** the application then trusts the `Host` header of every request; the script
  and the READMEs say so. The generated README has the same block to paste by hand.
- `doctor.sh` says, as a note and never a failure, whether the application is installed and whether `APP_BASE_URL` is fixed or
  dynamic; `doctor.sh --guide` names `base-url.sh dynamic` in step 6.
- The AI section (`ai/AGENTS-section.md`, `ai/memory-note.md`, prompt B) lists `base-url.sh`: `dynamic` and `fixed` change a file
  of the instance, so an agent runs them only when the owner asks; `status` is always fine.
- Tests. `scripts-test.sh` runs the very script that `base-url.sh` sends to the server against a folder tree, with a file in LF
  and the same file in CRLF: the round trip gives the original back byte for byte (a file with no final newline gets one), a value that could carry code, two defines, a
  path in the address, a missing file or a symbolic link, a failing `php -l` and a file edited by hand are refused with the file
  untouched, hostile parameters are refused on the server too. With the real `php` of the machine, when there is one, the patched
  file loads and the block gives the right address for each kind of request. It also runs the checks that `doctor.sh` sends to the
  server against a folder tree, for each state of `APP_BASE_URL`.

### Changed

- `install-perfex.sh` (header and closing message) and the READMEs name `base-url.sh dynamic` where they say to remove the
  `install` folder after the wizard; `lib.sh` lists `base-url.sh` among the scripts that call `ensure_locked_sh` (no code change).

## [0.4.0]

### Added

- `CI_CHECK_FILE`, a parameter for the matrix of a module **without** a `composer.json`: the file `ci-local.sh` runs after `php -l`,
  relative to the module, `.sh` (run with bash) or `.php` (run with php); default `tests/check.sh`, which `DEPLOY_EXCLUDES` keeps out
  of the application. `render.sh` validates it (an extension of `.sh` or `.php`, no `..`, no `//`, no leading `/` or `.`), writes it
  in `stack.conf` and prints it with `--check`; a parameter file or a `stack.conf` written by an older template, without the line,
  gets the default.
- The matrix now runs a module without a `composer.json`: `php -l` on every PHP file of the module (`vendor/`, `node_modules/` and
  the folders that start with a dot are left out), then the check file if the module has it, otherwise only the syntax check. A
  module with both a `composer.json` and a check file takes the Composer road, and the file is not run.
- `examples/module/plain_module/`, the twin of `sample_module` without Composer: classes loaded with `require_once`, a unit runner
  (`tests/unit.php`) and an integration script (`tests/integration.php`) in plain PHP, a `tests/check.sh`, and a README.
- Tests. `scripts-test.sh` runs the very script that `ci-local.sh` sends to the server against a folder tree, with a fake `composer`
  and a fake `php`: both roads, a syntax error, a check file that fails, a check file or a `tests/` folder that is a symbolic link,
  a module that is not on the server, hostile parameters; it also runs `plain_module` with the real `php` of the machine, when there
  is one. `deploy-test.sh` deploys a module without a `composer.json`, with and without a `vendor/` of its own; `render-test.sh`
  checks `CI_CHECK_FILE`.

### Changed

- The job of the matrix reaches the server as a fixed script on the standard input, with the values as positional parameters
  (quoted with `%q` and checked again on the server), as `deploy.sh` already did, and the road is chosen there, by the module's
  folder: the `ssh` probe for a `composer.json` is gone, and a module without one is no longer skipped. For a module with a
  `composer.json` the three Composer commands, their options and their order are the same; `composer run` has `< /dev/null`
  after it, so a script of the module that reads the standard input cannot take the rest of the job.
- The static analysis is skipped, on the server, for a module without a `composer.json`.
- The README of the template and the one of the project folder, `run.sh` and `ai/AGENTS-section.md` describe both forms of a
  module; the lessons of README §8 say that a module without Composer that keeps third-party code in a `vendor/` folder needs
  `vendor/` removed from `SYNC_EXCLUDES`.

## [0.3.1]

### Changed

- The documents, the scripts and the diagram say "your machine" where they said "your Mac": the template was built on macOS,
  but Linux works and Windows through WSL (untested); the facts about macOS (bash 3.2, no flock) stay where they are.

### Added

- `.github/workflows/release.yml`: on every push and pull request it checks the form of this file (headings `[Unreleased]` or
  `[X.Y.Z]`, `[Unreleased]` first and once, versions from the newest to the oldest, no empty section); on a tag `vX.Y.Z` it creates
  the GitHub Release, with the section of the version as the body (it must be the newest section of the file at the tag) and the
  fixed last line about the license of Perfex CRM. The tag must be annotated, with a signature GitHub verifies and the message
  `Perfex CRM Stack Docker X.Y.Z`; a Release is never overwritten. `.github/scripts/release-notes.sh` cuts the section (and
  `--check` reads the whole file), `release-notes-test.sh` tests it; "Run workflow" with dry run rehearses on an existing tag
  without creating anything.

## [0.3.0]

### Changed

- `ai/CLAUDE-section.md` is now `ai/AGENTS-section.md`: the same section for every AI agent, wrapped in two markers
  (`perfex-crm-stack: test instance, begin` and `end`). Its header says which file each tool reads (`AGENTS.md` for Codex,
  Copilot and the other tools that read it; `CLAUDE.md` for Claude Code, which can import `AGENTS.md` with `@AGENTS.md`;
  `.github/copilot-instructions.md` for Copilot Chat only) and tells an agent that finds the section missing from its file to
  add it there, between the markers, without committing. The two prompts of `ai/PROMPT.md` say the same; `ai/memory-note.md`
  is for Claude Code only.
- README: the tree of §2 lists every file with what it does; the reference infrastructure of §1 is an SVG diagram in `docs/`
  (a light and a dark variant) instead of the ASCII sketch; the notes on AI agents name Codex and Copilot next to Claude Code
  and say that a cloud agent has no SSH key and no route to the Docker network.

### Added

- `doctor.sh`, when `ai/` was rendered: notes (never failures) on `AGENTS.md` and `CLAUDE.md` at the project root, whether they
  hold the test-instance section (or `CLAUDE.md` imports `AGENTS.md`), and on a `.github/copilot-instructions.md` that exists
  without it. `tests/scripts-test.sh` covers the three cases; `tests/render-test.sh` checks the new file and its markers.

## [0.2.0]

### Added

- `extra/` in the generated folder, a place for your own scripts. `render.sh` writes only its `README.md`, and `render.sh --force`
  rewrites only that file: what you put there stays as it is.
- `lib.sh` is a documented API: the list of functions at the top of the file, and a section "Writing your own script" in the
  generated README (the lines every script starts with, what `stack_load` gives, the validator rule, the lock, temporary files
  and secrets, the smallest complete script, how to test one with a fake `ssh`, `rsync` and `curl`).
- `DEPLOY_EXTRA`, a parameter for modules that live deeper than `<SYNC_DIR>/<name>/` (a sample module inside another module):
  blank-separated `<folder relative to SYNC_DIR>:<name>` pairs. `deploy.sh <name>` deploys them with the same `.stack-managed`
  marker, `--adopt`, excludes and `vendor/.htaccess` as any module, and refuses a symbolic link anywhere on the way to the
  source. `render.sh` validates the pairs (a name is never in both `DEPLOY_MODULES` and `DEPLOY_EXTRA`, nor twice); `--check` lists
  the names; `lib.sh` has `deploy_extra_names` and `deploy_extra_source`. The server script of `deploy.sh` takes the source folder
  as a ninth parameter and validates it again.
- Three example scripts in `examples/extra/`, to copy into `extra/`: `infection-diff.sh` (Infection on the changed files of a
  module, on the server, inside the lock), `bench.sh` (response times of one URL from the Mac, with p50, p95 and p99) and `e2e.sh`
  (a Playwright suite of your project against the instance). `tests/scripts-test.sh` tests them with a fake `ssh`, `rsync`, `curl`,
  `git` and `npx`; it skips them when the template it finds has no `examples/extra/`.
- `render.sh` checks the path of the template as seen from the project root (`TEMPLATE_REL`): letters, digits and `. _ - /`
  only, leading `..` allowed. A blank in it is refused by name before anything is written.

### Changed

- The tag of the tools image always names both ends of `TOOLS_PHP_VERSIONS`: with a single version it is `perfex-tools:8.4-8.4`
  (it was `perfex-tools:8.4`). Blanks in `TOOLS_PHP_VERSIONS` (a leading one, a tab, a double blank) are squeezed to one blank, so a
  leading blank no longer gives the tag `perfex-tools:-8.2`.
- `stack/README.md`: the section on the SSH key and the alias comes before the server steps, as its title says, and the example
  database is `myproject`, like in the generated README and in `doctor.sh --guide`.

### Fixed

- `cd` to the project root is quoted in the generated README and in `doctor.sh --guide`, for a root whose path has a blank.
- The generated README and `doctor.sh --guide` say that with your own `WEB_IMAGE` the web image is not built from
  `web/Dockerfile`.
- `tests/scripts-test.sh` tells the probe that asks whether `locked.sh` is on the server from the call that runs a job through it,
  and tests the copy of a missing `locked.sh` (probe, `mkdir`, `rsync`, then the command).
- `tests/render-test.sh` checks that `IMAGE_OWNER` prefixes both image names in `stack.conf` and `portainer.env`, and refuses an
  owner of one character, or one that starts with `-` or ends with `/`.

## [0.1.0]

- `stack/`: the compose file (web and tools), the web image (Apache and PHP-FPM) and the tools image (several PHP versions,
  Composer, sshd, rsync, MariaDB client, optional Node), an optional second web instance, and the README of the stack.
- `render.sh` and `params.example.env`: validation of the parameters and generation of the project folder, without ever writing
  `stack/`.
- `project/`: the scripts of the generated folder (`sync.sh`, `deploy.sh`, `ci-local.sh`, `run.sh`, `locked.sh`, `snapshot.sh`,
  `reset.sh`, `install-perfex.sh`, `doctor.sh`), `stack.conf`, `portainer.env`, the runbook of the instance, and four tests with
  a fake `ssh`, `rsync` and `curl` (no server is touched).
- `examples/`: a filled-in parameter file and the smallest module that goes through the whole chain, with unit and integration
  tests.
- `ai/`: two prompts for an AI agent, a section for its `CLAUDE.md` and a memory note.
