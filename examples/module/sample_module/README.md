# sample_module

The smallest module that goes through everything the template does. It has no feature on purpose.

| File | Why it is there |
|---|---|
| `sample_module.php` | the init file Perfex looks for: `<folder>/<folder>.php`, with the module header. This name is also how `deploy.sh` discovers a module |
| `composer.json` | the scripts the template calls: `check` (run by `ci-local.sh` on every PHP version of the matrix) and `test:int` (run on the server against the instance) |
| `phpunit.xml.dist` | two suites: `unit`, and `integration` which needs the instance |
| `src/Greeting.php`, `tests/Unit/` | a class and its tests: they run anywhere, on every PHP version |
| `tests/Integration/TestInstance.php` | a helper that reads the stack variables of the SSH session (`PERFEX_URL`, `PERFEX_APP_PATH`, `PERFEX_DB_*`, `MAILPIT_URL`): HTTP requests, a database connection, Mailpit |
| `tests/Integration/InstanceTest.php` | four checks of the instance itself; they skip when the variables are not set |

To try it, copy this folder into the `modules/` folder of your project (the `SYNC_DIR` of your parameters), then:

```bash
tools/docker/deploy.sh sample_module                     # sync, composer install, copy into /app/modules/sample_module
tools/docker/ci-local.sh sample_module                   # the matrix: composer install, validate, check on 8.3, 8.4, 8.5
tools/docker/run.sh 'cd /repo/modules/sample_module && PATH=/opt/php/8.4:$PATH composer test:int'
```

(`tools/docker` is the default `DEST_DIR`.) Then activate the module from Setup > Modules in the application.

What it teaches, for your own modules:

- `deploy.sh` copies the module **without** `tests/`, `phpunit*`, `.php-cs-fixer*` and dot folders (`DEPLOY_EXCLUDES` in your
  parameters), and writes `vendor/.htaccess` so the web cannot read `vendor/`.
- `ci-local.sh` runs `composer install`, `composer validate --strict` and `composer run <CI_CHECK_SCRIPT>`: **what "check"
  does is up to your `composer.json`** (add coding standards, static analysis, more suites). Long suites: set
  `"process-timeout": 0` as here, because Composer stops a script after 300 seconds.
- Integration tests run in the tools container, where PHP, the database and the instance's URL are one hop away. They read
  everything from the environment and never contain a credential.

The same module without Composer is [`../plain_module/`](../plain_module/).
