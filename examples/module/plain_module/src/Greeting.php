<?php

declare(strict_types=1);

namespace PlainModule;

/**
 * The module's only class: enough to have something to test. It is the same class as in sample_module, on purpose.
 */
final class Greeting
{
    public static function forName(string $name): string
    {
        $name = trim($name);

        return $name === '' ? 'Hello!' : sprintf('Hello, %s!', $name);
    }
}
