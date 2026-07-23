<?php
// Router for PHP's built-in dev server. Mirrors the production Apache rule
// `RewriteRule ^go/?$ go.php [L]` so local and deployed behavior match.
// Usage: php -S 127.0.0.1:8888 -t site tests/router.php

declare(strict_types=1);

$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);

if (preg_match('#^/go/?$#', (string) $path) === 1) {
    require __DIR__ . '/../site/go.php';
    return true;
}

// Fall through to the static file server.
return false;
