#!/usr/bin/env bash
# The check that ci-local.sh runs for a module without a composer.json, on every PHP version of the matrix, after php -l on
# every PHP file of the module. Put your own tests here, with the tool you like: the exit status is the verdict.
set -euo pipefail
# the folder of the module, so that the script also runs by hand from anywhere
cd "$(dirname "$0")/.."
php tests/unit.php
