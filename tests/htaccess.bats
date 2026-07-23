#!/usr/bin/env bats
#
# Verifies site/.htaccess against a real Apache httpd (2.4, mod_rewrite +
# mod_headers), not just PHP's built-in dev server. tests/go.bats exercises
# go.php's own logic through tests/router.php, which reimplements the
# `RewriteRule ^go/?$ go.php [L]` rule in PHP -- it never runs the actual
# .htaccess file through actual Apache. In particular the `/go/` case
# (trailing slash) is exactly where mod_dir's DirectorySlash behavior can
# diverge from a hand-rolled router, and that gap was previously
# unverifiable without a deployed origin. This file closes it locally.

HTTPD=/usr/sbin/httpd
APACHE_MODULES_DIR=/usr/libexec/apache2
PORT=8921
BASE="http://127.0.0.1:$PORT"

# Portable file-mode lookup, see tests/go.bats for why both forms are tried.
file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

setup_file() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO

  if [ ! -x "$HTTPD" ]; then
    echo "FATAL: $HTTPD not found or not executable; cannot verify .htaccess against real Apache." >&2
    return 1
  fi

  PHP_CGI="$(command -v php-cgi || true)"
  export PHP_CGI
  if [ -z "$PHP_CGI" ]; then
    echo "FATAL: php-cgi not found on PATH; cannot run go.php under Apache." >&2
    return 1
  fi

  # Refuse to run against a foreign server already bound to our port, same
  # rationale as tests/go.bats: a false green here is worse than no test.
  if command -v lsof >/dev/null 2>&1; then
    if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
      echo "FATAL: port $PORT is already in use by another process; refusing to run tests against a foreign server. Free the port and retry." >&2
      return 1
    fi
  else
    echo "WARNING: lsof not found; skipping the port-$PORT-in-use guard. This run will not detect an already-listening foreign process on that port." >&2
  fi

  # --- Stage a copy of site/ outside $HOME/Documents -------------------
  #
  # DocumentRoot cannot point directly at "$REPO/site" on this machine.
  # macOS's TCC privacy protection blocks /usr/sbin/httpd (Apple's system
  # Apache) from reading anything under ~/Documents -- confirmed directly:
  # pointing DocumentRoot at the real repo path, and even at a symlink that
  # resolves into it, both fail with a kernel-level "(1)Operation not
  # permitted" on every file open, including .htaccess itself. The same
  # config against an identical copy placed under $TMPDIR succeeds
  # immediately. This is an OS permission boundary (fixable only by
  # granting Terminal/httpd Full Disk Access in System Settings, a manual,
  # interactive, machine-specific step), not a bug in the site or the test.
  #
  # The workaround: copy site/ verbatim into BATS_FILE_TMPDIR (which bats
  # places under $TMPDIR, outside the protected folders) fresh on every
  # run, and point Apache at the copy. This still exercises the real,
  # currently-committed .htaccess/go.php/link.txt byte-for-byte -- nothing
  # here is hand-duplicated -- it is only relocated to a path Apache is
  # permitted to read.
  SITE_ROOT="$BATS_FILE_TMPDIR/site_root"
  rm -rf "$SITE_ROOT"
  mkdir -p "$SITE_ROOT"
  cp -Rp "$REPO/site/." "$SITE_ROOT/"
  export SITE_ROOT

  # The redirect target is whatever site/link.txt currently holds, read the
  # same way go.php does (trim), so this test keeps working if the value
  # ever changes rather than pinning today's URL.
  EXPECTED_LINK="$(cat "$SITE_ROOT/link.txt")"
  export EXPECTED_LINK

  CGI_BIN="$BATS_FILE_TMPDIR/cgi-bin"
  mkdir -p "$CGI_BIN"
  ln -sf "$PHP_CGI" "$CGI_BIN/php-cgi"

  CONF="$BATS_FILE_TMPDIR/httpd.conf"
  cat > "$CONF" <<EOF
ServerRoot "/usr"
Listen 127.0.0.1:$PORT
ServerName 127.0.0.1:$PORT

LoadModule authz_core_module $APACHE_MODULES_DIR/mod_authz_core.so
LoadModule authz_host_module $APACHE_MODULES_DIR/mod_authz_host.so
LoadModule mime_module $APACHE_MODULES_DIR/mod_mime.so
LoadModule dir_module $APACHE_MODULES_DIR/mod_dir.so
LoadModule alias_module $APACHE_MODULES_DIR/mod_alias.so
LoadModule rewrite_module $APACHE_MODULES_DIR/mod_rewrite.so
LoadModule headers_module $APACHE_MODULES_DIR/mod_headers.so
LoadModule cgi_module $APACHE_MODULES_DIR/mod_cgi.so
LoadModule actions_module $APACHE_MODULES_DIR/mod_actions.so
LoadModule autoindex_module $APACHE_MODULES_DIR/mod_autoindex.so
LoadModule log_config_module $APACHE_MODULES_DIR/mod_log_config.so
LoadModule unixd_module $APACHE_MODULES_DIR/mod_unixd.so
LoadModule mpm_prefork_module $APACHE_MODULES_DIR/mod_mpm_prefork.so

PidFile "$BATS_FILE_TMPDIR/httpd.pid"
ErrorLog "$BATS_FILE_TMPDIR/error_log"
LogLevel warn
TypesConfig /etc/apache2/mime.types

DocumentRoot "$SITE_ROOT"

<Directory "/">
  AllowOverride None
  Require all denied
</Directory>

# mod_autoindex is loaded deliberately (the brief's module list doesn't
# require it) so that the "/assets/ has no directory listing" assertion
# actually proves .htaccess's "Options -Indexes" is doing the work, rather
# than trivially passing because no module can generate a listing anyway.
<Directory "$SITE_ROOT">
  AllowOverride All
  Require all granted
</Directory>

# php-cgi runs as a CGI Action target, not mod_php -- there is no mod_php
# for this Apache build. ScriptAlias is scoped to a directory containing
# only a symlink to php-cgi, not a general filesystem path, so this does
# not expose arbitrary binaries as CGI.
ScriptAlias /cgi-bin/ "$CGI_BIN/"
<Directory "$CGI_BIN">
  Require all granted
  Options +ExecCGI
</Directory>

AddType application/x-httpd-php .php
Action application/x-httpd-php /cgi-bin/php-cgi
EOF

  # -X: run in the foreground, single process, no daemonizing fork. Without
  # it, $! below would be the pid of a process that immediately exits after
  # forking off the real (untracked) daemon, and teardown_file's kill would
  # hit nothing -- the same class of problem the go.bats pid-tracking
  # comment warns about, just from the opposite direction (double-fork
  # instead of an early-death race).
  "$HTTPD" -f "$CONF" -X >/dev/null 2>&1 &
  local pid=$!
  echo "$pid" > "$BATS_FILE_TMPDIR/httpd.pid"

  sleep 0.3
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "FATAL: httpd (pid $pid) is not running; the test server failed to start. Check $BATS_FILE_TMPDIR/error_log. Aborting rather than probing an unrelated process." >&2
    return 1
  fi

  for _ in $(seq 1 60); do
    curl -sS -o /dev/null "$BASE/" && break
    sleep 0.1
  done
}

teardown_file() {
  if [ -f "$BATS_FILE_TMPDIR/httpd.pid" ]; then
    kill "$(cat "$BATS_FILE_TMPDIR/httpd.pid")" 2>/dev/null || true
  fi
}

# Prints "<status> <resolved redirect target>"
probe() {
  curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' "$BASE/go"
}

probe_slash() {
  curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' "$BASE/go/"
}

@test "GET /go returns 302 to the current link.txt destination" {
  run probe
  [ "$output" = "302 $EXPECTED_LINK" ]
}

@test "GET /go/ also returns 302 to the same destination (DirectorySlash does not hijack it)" {
  # The single highest-value assertion in this file. go/ is not a real
  # directory under DocumentRoot, so mod_dir's "append a slash and
  # redirect" behavior is a live hazard here: if RewriteRule's `^go/?$`
  # were ever evaluated after mod_dir's directory-handler instead of
  # before it, this would come back as a 404 or a redirect to a
  # non-existent directory listing instead of go.php's 302. This is exactly
  # the kind of divergence that only shows up against real Apache.
  run probe_slash
  [ "$output" = "302 $EXPECTED_LINK" ]
}

@test "GET /link.txt is denied" {
  run curl -sS -o /dev/null -w '%{http_code}' "$BASE/link.txt"
  [ "$output" = "403" ]
}

@test "GET /assets/bg.png is cached for a year, immutable" {
  run bash -c "curl -sSI '$BASE/assets/bg.png' | tr -d '\r'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi '^Cache-Control: public, max-age=31536000, immutable$'
}

@test "GET / serves index.html with 200 and Cache-Control: no-cache" {
  run curl -sS -o /dev/null -w '%{http_code}' "$BASE/"
  [ "$output" = "200" ]

  run bash -c "curl -sS '$BASE/'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '<title>มตล Snack Corner | Lay'\''s</title>'

  run bash -c "curl -sSI '$BASE/' | tr -d '\r'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi '^Cache-Control: no-cache$'
}

@test "GET /assets/ does not return a directory listing" {
  run bash -c "curl -sS -o /dev/null -w '%{http_code}' '$BASE/assets/'"
  [ "$output" != "200" ]

  run bash -c "curl -sS '$BASE/assets/'"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qi 'Index of /assets'
}

@test "security headers are present" {
  run bash -c "curl -sSI '$BASE/' | tr -d '\r'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi '^X-Content-Type-Options: nosniff$'
  echo "$output" | grep -qi '^X-Frame-Options: SAMEORIGIN$'
}
