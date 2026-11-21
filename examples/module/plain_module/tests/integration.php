<?php

declare(strict_types=1);

// The integration checks of the module against the test instance, in plain PHP: no Composer, no PHPUnit. Run it in the tools
// container after "deploy.sh plain_module":
//   run.sh 'cd /repo/modules/plain_module && PATH=/opt/php/8.4:$PATH php tests/integration.php'
// Outside the container the variables of the stack are not set: it says so and exits 0. It never prints a value of the stack.
// The exit status is 0 when no check fails and 1 otherwise.

require __DIR__ . '/TestInstance.php';

use PlainModule\Tests\TestInstance;

if (!TestInstance::configured()) {
    echo "skipped: not in the tools container (PERFEX_URL, PERFEX_APP_PATH and PERFEX_DB_* are not set)\n";
    exit(0);
}

$passed = 0;
$failed = 0;
$skipped = 0;

function report(string $outcome, string $what): void
{
    global $passed, $failed, $skipped;
    if ($outcome === 'ok') {
        ++$passed;
    } elseif ($outcome === 'FAIL') {
        ++$failed;
    } else {
        ++$skipped;
    }
    echo "{$outcome}: {$what}\n";
}

// the application answers
[$status] = TestInstance::get('/');
report($status >= 1 && $status <= 499 ? 'ok' : 'FAIL', 'the application answers (a status from 1 to 499)');

// the database answers (only the class of an error is shown: its message could carry a value of the stack)
try {
    report((int) TestInstance::pdo()->query('SELECT 1')->fetchColumn() === 1 ? 'ok' : 'FAIL', 'the database answers');
} catch (Throwable $e) {
    report('FAIL', 'the database answers (' . get_class($e) . ')');
}

// the module is deployed: run deploy.sh plain_module first
$deployed = TestInstance::appPath() . '/modules/plain_module';
report(is_file($deployed . '/plain_module.php') && is_file($deployed . '/.stack-managed') ? 'ok' : 'FAIL', 'the module is deployed (plain_module.php and the .stack-managed marker)');

// Mailpit answers, when there is one
if (!TestInstance::mailpitConfigured()) {
    report('skipped', 'mailpit answers (MAILPIT_URL is not set)');
} else {
    try {
        TestInstance::mailpitMessages();
        report('ok', 'mailpit answers with a list of messages');
    } catch (Throwable $e) {
        report('FAIL', 'mailpit answers with a list of messages (' . get_class($e) . ')');
    }
}

echo "plain_module integration tests: {$passed} passed, {$failed} failed, {$skipped} skipped\n";
exit($failed === 0 ? 0 : 1);
