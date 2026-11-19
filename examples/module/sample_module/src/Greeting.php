<?php

declare(strict_types=1);

namespace SampleModule;

/**
 * The module's only class: enough to have something to test.
 */
final class Greeting
{
    public static function forName(string $name): string
    {
        $name = trim($name);

        return $name === '' ? 'Hello!' : sprintf('Hello, %s!', $name);
    }
}
