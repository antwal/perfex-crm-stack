<?php

declare(strict_types=1);

namespace SampleModule\Tests\Unit;

use PHPUnit\Framework\TestCase;
use SampleModule\Greeting;

final class GreetingTest extends TestCase
{
    public function test_it_greets_by_name(): void
    {
        $this->assertSame('Hello, Ada!', Greeting::forName('Ada'));
    }

    public function test_it_trims_the_name(): void
    {
        $this->assertSame('Hello, Ada!', Greeting::forName("  Ada \n"));
    }

    public function test_it_greets_nobody_when_the_name_is_empty(): void
    {
        $this->assertSame('Hello!', Greeting::forName('   '));
    }
}
