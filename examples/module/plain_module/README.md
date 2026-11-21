# plain_module

The smallest module that goes through everything the template does **without Composer**. It is the twin of
[`sample_module`](../sample_module/): the same class, the same four checks of the instance, no dependency and no
`composer.json`. The likeness is on purpose, so that you can read the two side by side.

| File | Why it is there |
|---|---|
| `plain_module.php` | the init file Perfex looks for: `<folder>/<folder>.php`, with the module header. It loads the classes with `require_once`, because there is no autoloader. This name is also how `deploy.sh` discovers a module |
| `src/Greeting.php` | a class, the same as in `sample_module` |
| `tests/check.sh` | the check that `ci-local.sh` runs on every PHP version of the matrix, after `php -l` on every PHP file: here it runs `php tests/unit.php`. It is `CI_CHECK_FILE` (default `tests/check.sh`) |
| `tests/unit.php` | the unit tests, a runner of thirty lines in plain PHP: three checks of `Greeting`, a count at the end and the exit status |
| `tests/TestInstance.php` | a helper that reads the stack variables of the SSH session (`PERFEX_URL`, `PERFEX_APP_PATH`, `PERFEX_DB_*`, `MAILPIT_URL`): HTTP requests, a database connection, Mailpit. It is the class of `sample_module`, copied: without Composer there is no package to share it through |
| `tests/integration.php` | four checks of the instance itself, one line each (`ok:`, `FAIL:` or `skipped:`); they skip when the variables are not set, and never print a value |

To try it, copy this folder into the `modules/` folder of your project (the `SYNC_DIR` of your parameters), then:

```bash
tools/docker/deploy.sh plain_module                      # sync, copy into /app/modules/plain_module: no composer install
tools/docker/ci-local.sh plain_module                    # the matrix: php -l on every PHP file, then tests/check.sh, on 8.3, 8.4, 8.5
tools/docker/run.sh 'cd /repo/modules/plain_module && PATH=/opt/php/8.4:$PATH php tests/integration.php'
```

(`tools/docker` is the default `DEST_DIR`.) To use it as it is, put `plain_module` in `DEPLOY_MODULES` and `CI_MODULES` of your
parameters, or leave both lists empty, so that the scripts find it by themselves. Then activate the module from Setup >
Modules in the application.

What it teaches, for your own modules:

- **The road is decided by the module.** `ci-local.sh` looks, on the server, for a `composer.json` in the module's folder: with one it
  takes the Composer road (`composer install`, `composer validate --strict`, `composer run <CI_CHECK_SCRIPT>`), without one the
  plain road you see here. A module that has both takes the Composer road, and its `tests/check.sh` is not run. `deploy.sh`
  does the same: it runs `composer install` only when there is a `composer.json`, and copies the folder as it is otherwise.
- **The check file is where your tests go.** After `php -l` on every PHP file of the module (`vendor/`, `node_modules/` and the
  folders that start with a dot are left out), `ci-local.sh` runs `tests/check.sh` with bash, or a `.php` file with php, with the
  PHP of the matrix first in the `PATH`. Put there the tests you like, with the tool you like: the exit status is the verdict.
  `CI_CHECK_FILE` in your parameters gives it another name. A module without that file is only syntax-checked.
- **`tests/` stays out of the application.** `deploy.sh` copies the module without `tests/` (`DEPLOY_EXCLUDES` in your
  parameters). If your check file lives elsewhere, add its folder to `DEPLOY_EXCLUDES`, or it is copied into the application.
- **Third-party code kept by hand.** If the module keeps libraries in a folder named `vendor/`, take `vendor/` out of
  `SYNC_EXCLUDES` in your parameters, or `sync.sh` does not send it to the server. `deploy.sh` then copies it as it is and writes
  `vendor/.htaccess`, so the web cannot read it; the matrix never compiles `vendor/` (it is not your code).
- Integration checks run in the tools container, where PHP, the database and the instance's URL are one hop away. They read
  everything from the environment and never contain a credential.
