<?php
/**
 * CTA redirect endpoint.
 *
 * The destination is read ONLY from the server-side link.txt. It must never be
 * taken from a query parameter, path segment, header, or cookie: a redirect
 * whose target comes from user input is an open redirect, and on a page
 * carrying Lay's branding that is a phishing vector aimed at the brand.
 */

declare(strict_types=1);

const LINK_FILE = __DIR__ . '/link.txt';

// Used when link.txt is missing, empty, or invalid. '/' sends the visitor to
// this site's own root rather than an error page. Task 6 replaces this with a
// permanent campaign URL if one is provided.
const FALLBACK_URL = '/';

// RFC 3986 does not bound URL length, but no client can follow an
// unbounded Location header; 2048 is the conservative, widely used ceiling
// for URLs that must survive real HTTP clients and browsers.
const MAX_URL_LENGTH = 2048;

function is_valid_https_url(string $url): bool
{
    if ($url === '' || strpbrk($url, "\r\n") !== false) {
        return false;
    }
    if (strlen($url) > MAX_URL_LENGTH) {
        return false;
    }
    if (filter_var($url, FILTER_VALIDATE_URL) === false) {
        return false;
    }

    // Reject userinfo (user[:pass]@host). A URL like
    // https://www.lays.co.th@evil.example.com/ visually opens with the
    // trusted domain but the real authority is evil.example.com — a
    // brand-spoofing vector filter_var/FILTER_VALIDATE_URL does not catch.
    if (parse_url($url, PHP_URL_USER) !== null || parse_url($url, PHP_URL_PASS) !== null) {
        return false;
    }

    return strtolower((string) parse_url($url, PHP_URL_SCHEME)) === 'https';
}

function resolve_destination(string $path, string $fallback): string
{
    if (!is_file($path) || !is_readable($path)) {
        return $fallback;
    }

    $raw = file_get_contents($path);
    if ($raw === false) {
        return $fallback;
    }

    $url = trim($raw);

    return is_valid_https_url($url) ? $url : $fallback;
}

$destination = resolve_destination(LINK_FILE, FALLBACK_URL);

header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');
header('Pragma: no-cache');
header('Referrer-Policy: strict-origin-when-cross-origin');

// 302 (temporary), never 301. The destination changes daily; a permanent
// redirect would be cached indefinitely by browsers with no way to clear it.
header('Location: ' . $destination, true, 302);
exit;
