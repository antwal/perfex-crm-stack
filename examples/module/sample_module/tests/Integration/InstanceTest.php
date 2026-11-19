<?php

declare(strict_types=1);

namespace SampleModule\Tests\Integration;

use PHPUnit\Framework\TestCase;

/**
 * Checks the test instance itself, from the tools container: "composer test:int" after "deploy.sh sample_module".
 * Outside the container the variables of the stack are not set and every test is skipped.
 */
final class InstanceTest extends TestCase
{
    protected function setUp(): void
    {
        if (!TestInstance::configured()) {
            $this->markTestSkipped('Not in the tools container: PERFEX_URL, PERFEX_APP_PATH and PERFEX_DB_* are not set.');
        }
    }

    public function test_the_application_answers(): void
    {
        [$status] = TestInstance::get('/');

        $this->assertGreaterThan(0, $status, 'nothing answered at PERFEX_URL');
        $this->assertLessThan(500, $status, 'the application answers with a server error');
    }

    public function test_the_database_answers(): void
    {
        $this->assertSame(1, (int) TestInstance::pdo()->query('SELECT 1')->fetchColumn());
    }

    public function test_the_module_is_deployed(): void
    {
        $this->assertFileExists(TestInstance::appPath() . '/modules/sample_module/sample_module.php', 'run deploy.sh sample_module first');
        $this->assertFileExists(TestInstance::appPath() . '/modules/sample_module/.stack-managed', 'deploy.sh writes this marker');
    }

    public function test_mailpit_answers_when_there_is_one(): void
    {
        if (!TestInstance::mailpitConfigured()) {
            $this->markTestSkipped('MAILPIT_URL is not set.');
        }

        $this->assertIsArray(TestInstance::mailpitMessages());
    }
}
