<?php

declare(strict_types=1);

// The unit tests of the module, in plain PHP: no Composer, no PHPUnit. tests/check.sh runs this file; run it by hand with
// "php tests/unit.php". The exit status is 0 when every check passes and 1 otherwise.

require __DIR__ . '/../src/Greeting.php';

use PlainModule\Greeting;

$passed = 0;
$failed = 0;

function check(string $what, bool $ok): void
{
    global $passed, $failed;
    if ($ok) {
        ++$passed;
        echo "ok: {$what}\n";
    } else {
        ++$failed;
        echo "FAIL: {$what}\n";
    }
}

check('it greets by name', Greeting::forName('Ada') === 'Hello, Ada!');
check('it trims the name', Greeting::forName("  Ada \n") === 'Hello, Ada!');
check('it greets nobody when the name is empty', Greeting::forName('   ') === 'Hello!');

echo "plain_module unit tests: {$passed} passed, {$failed} failed\n";
exit($failed === 0 ? 0 : 1);
