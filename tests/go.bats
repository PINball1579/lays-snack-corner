#!/usr/bin/env bats

BASE="http://127.0.0.1:8899"

setup_file() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO

  # If something is already listening on 8899, the readiness probe below
  # would happily succeed against that foreign process instead of our test
  # server, and the whole suite would silently exercise the wrong code.
  # Refuse to run rather than risk a false green.
  if lsof -nP -iTCP:8899 -sTCP:LISTEN >/dev/null 2>&1; then
    echo "FATAL: port 8899 is already in use by another process; refusing to run tests against a foreign server. Free the port and retry." >&2
    return 1
  fi

  php -S 127.0.0.1:8899 -t "$REPO/site" "$REPO/tests/router.php" >/dev/null 2>&1 &
  local pid=$!
  echo "$pid" > "$BATS_FILE_TMPDIR/server.pid"

  # Give php -S a moment to either bind or die (e.g. a race lost against
  # another process for the port) before we trust the PID.
  sleep 0.2
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "FATAL: php -S (pid $pid) is not running; the test server failed to start. Aborting rather than probing an unrelated process." >&2
    return 1
  fi

  for _ in $(seq 1 60); do
    curl -sS -o /dev/null "http://127.0.0.1:8899/go" && break
    sleep 0.1
  done
}

teardown_file() {
  kill "$(cat "$BATS_FILE_TMPDIR/server.pid")" 2>/dev/null || true
}

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  LINK="$REPO/site/link.txt"
  if [ -f "$LINK" ]; then cp "$LINK" "$BATS_TEST_TMPDIR/link.bak"; fi
}

teardown() {
  # A test may have made link.txt unreadable (e.g. chmod 000) to exercise the
  # is_file/is_readable guard. Restore write access first so the restore
  # below can actually overwrite/remove it and the suite stays repeatable.
  if [ -e "$LINK" ]; then
    chmod u+rw "$LINK" 2>/dev/null || true
  fi
  if [ -f "$BATS_TEST_TMPDIR/link.bak" ]; then
    cp "$BATS_TEST_TMPDIR/link.bak" "$LINK"
  else
    rm -f "$LINK"
  fi
}

# Prints "<status> <resolved redirect target>"
probe() {
  curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' "$BASE/go"
}

@test "valid link.txt redirects to that URL" {
  printf 'https://valid.example.com/today\n' > "$LINK"
  run probe
  [ "$output" = "302 https://valid.example.com/today" ]
}

@test "status is 302 and never 301" {
  printf 'https://valid.example.com/today\n' > "$LINK"
  run curl -sS -o /dev/null -w '%{http_code}' "$BASE/go"
  [ "$output" = "302" ]
}

@test "missing link.txt falls back instead of erroring" {
  rm -f "$LINK"
  run probe
  [ "$output" = "302 $BASE/" ]
}

@test "empty link.txt falls back" {
  printf '' > "$LINK"
  run probe
  [ "$output" = "302 $BASE/" ]
}

@test "whitespace-only link.txt falls back" {
  printf '   \n\n' > "$LINK"
  run probe
  [ "$output" = "302 $BASE/" ]
}

@test "malformed link.txt falls back" {
  printf 'not a url at all\n' > "$LINK"
  run probe
  [ "$output" = "302 $BASE/" ]
}

@test "non-TLS http:// destination is refused and falls back" {
  printf 'http://insecure.example.com/\n' > "$LINK"
  run probe
  [ "$output" = "302 $BASE/" ]
}

@test "javascript: scheme is refused and falls back" {
  printf 'javascript:alert(1)\n' > "$LINK"
  run probe
  [ "$output" = "302 $BASE/" ]
}

@test "query string cannot override the destination (open redirect guard)" {
  printf 'https://valid.example.com/today\n' > "$LINK"
  run curl -sS -o /dev/null -w '%{redirect_url}' "$BASE/go?url=https://evil.example.com/"
  [ "$output" = "https://valid.example.com/today" ]
}

@test "userinfo brand-spoof (user@host) destination is refused and falls back" {
  printf 'https://www.lays.co.th@evil.example.com/\n' > "$LINK"
  run probe
  [ "$output" = "302 $BASE/" ]
}

@test "empty userinfo (:@host) destination is refused and falls back" {
  printf 'https://:@evil.example.com/\n' > "$LINK"
  run probe
  [ "$output" = "302 $BASE/" ]
}

@test "destination longer than 2048 characters is refused and falls back" {
  long_path="$(printf '%2050s' '' | tr ' ' 'a')"
  printf 'https://valid.example.com/%s\n' "$long_path" > "$LINK"
  run probe
  [ "$output" = "302 $BASE/" ]
}

@test "unreadable link.txt falls back instead of leaking a warning or erroring" {
  printf 'https://valid.example.com/today\n' > "$LINK"
  chmod 000 "$LINK"
  run probe
  [ "$output" = "302 $BASE/" ]
}

@test "response is not cacheable" {
  printf 'https://valid.example.com/today\n' > "$LINK"
  run bash -c "curl -sS -D - -o /dev/null '$BASE/go' | tr -d '\r'"
  [[ "$output" == *"Cache-Control: no-store"* ]]
}

@test "trailing slash form /go/ also redirects" {
  printf 'https://valid.example.com/today\n' > "$LINK"
  run curl -sS -o /dev/null -w '%{http_code}' "$BASE/go/"
  [ "$output" = "302" ]
}
