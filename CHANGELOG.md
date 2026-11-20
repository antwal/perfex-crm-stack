# Changelog

The changes of each version of the template, in the format of [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions are
numbered MAJOR.MINOR.PATCH. The functions of `project/lib.sh` listed in "Writing your own script" (the generated README) are the API
of the scripts you write yourself: they keep their names and arguments until the next major version.

## [Unreleased]

### Changed

- The documents, the scripts and the diagram say "your machine" where they said "your Mac": the template was built on macOS,
  but Linux works and Windows through WSL (untested); the facts about macOS (bash 3.2, no flock) stay where they are.

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
