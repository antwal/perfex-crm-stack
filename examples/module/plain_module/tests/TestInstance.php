<?php

declare(strict_types=1);

namespace PlainModule\Tests;

/**
 * What an integration check needs to talk to the test instance, written from scratch for this template.
 *
 * It is the same class as tests/Integration/TestInstance.php of the sample_module example, copied here: without Composer there
 * is no package to share it through, and a module that has no autoloader copies what it needs.
 *
 * Everything comes from the variables of the SSH session in the tools container, which the stack sets:
 *   PERFEX_URL          the application's address                      (http://myproject.perfexcrm.docker)
 *   PERFEX_APP_PATH     the application's files in the container       (/app)
 *   PERFEX_DB_HOST, PERFEX_DB_NAME, PERFEX_DB_USER, PERFEX_DB_PASSWORD  the instance's database
 *   MAILPIT_URL         the Mailpit web interface and API, if there is one
 * Outside the tools container none of them is set, and configured() says so: a check skips itself instead of failing.
 * The values are never printed, logged or put in an exception message.
 */
final class TestInstance
{
    private const REQUIRED = ['PERFEX_URL', 'PERFEX_APP_PATH', 'PERFEX_DB_HOST', 'PERFEX_DB_NAME', 'PERFEX_DB_USER', 'PERFEX_DB_PASSWORD'];

    /** True when every variable of the instance is present. */
    public static function configured(): bool
    {
        foreach (self::REQUIRED as $name) {
            if (self::env($name) === '') {
                return false;
            }
        }

        return true;
    }

    public static function url(): string
    {
        return rtrim(self::env('PERFEX_URL'), '/');
    }

    public static function appPath(): string
    {
        return rtrim(self::env('PERFEX_APP_PATH'), '/');
    }

    /** A connection to the instance's database. The host may carry a port: "host:3307". */
    public static function pdo(): \PDO
    {
        $host = self::env('PERFEX_DB_HOST');
        $port = '';
        if (preg_match('/^(.+):([0-9]{1,5})$/', $host, $m) === 1) {
            $host = $m[1];
            $port = ';port=' . $m[2];
        }
        $dsn = sprintf('mysql:host=%s%s;dbname=%s;charset=utf8mb4', $host, $port, self::env('PERFEX_DB_NAME'));

        return new \PDO($dsn, self::env('PERFEX_DB_USER'), self::env('PERFEX_DB_PASSWORD'), [
            \PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION,
            \PDO::ATTR_TIMEOUT => 5,
        ]);
    }

    /**
     * A GET request to the application (redirects are not followed, so a check sees them).
     *
     * @param list<string> $headers lines such as "Authorization: Bearer ..."
     *
     * @return array{0: int, 1: string} the status code and the body; status 0 when nothing answered
     */
    public static function get(string $path, array $headers = []): array
    {
        return self::request(self::url() . '/' . ltrim($path, '/'), $headers);
    }

    public static function mailpitConfigured(): bool
    {
        return self::env('MAILPIT_URL') !== '';
    }

    /**
     * The messages Mailpit holds, as it lists them (its API: GET /api/v1/messages).
     *
     * @return list<array<string, mixed>>
     */
    public static function mailpitMessages(): array
    {
        [$status, $body] = self::request(rtrim(self::env('MAILPIT_URL'), '/') . '/api/v1/messages', []);
        if ($status !== 200) {
            throw new \RuntimeException('Mailpit did not answer 200 (status ' . $status . ')');
        }
        $data = json_decode($body, true);

        return is_array($data) && isset($data['messages']) && is_array($data['messages']) ? array_values($data['messages']) : [];
    }

    private static function env(string $name): string
    {
        $value = getenv($name);

        return $value === false ? '' : $value;
    }

    /**
     * @param list<string> $headers
     *
     * @return array{0: int, 1: string}
     */
    private static function request(string $url, array $headers): array
    {
        $curl = curl_init($url);
        if ($curl === false) {
            throw new \RuntimeException('curl could not be initialised');
        }
        curl_setopt_array($curl, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_FOLLOWLOCATION => false,
            CURLOPT_CONNECTTIMEOUT => 5,
            CURLOPT_TIMEOUT => 30,
            CURLOPT_HTTPHEADER => $headers,
        ]);
        $body = curl_exec($curl);
        $status = (int) curl_getinfo($curl, CURLINFO_RESPONSE_CODE);
        curl_close($curl);

        return [$status, is_string($body) ? $body : ''];
    }
}
