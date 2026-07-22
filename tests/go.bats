#!/usr/bin/env bats

BASE="http://127.0.0.1:8899"

setup_file() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO
  php -S 127.0.0.1:8899 -t "$REPO/site" "$REPO/tests/router.php" >/dev/null 2>&1 &
  echo $! > "$BATS_FILE_TMPDIR/server.pid"
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
