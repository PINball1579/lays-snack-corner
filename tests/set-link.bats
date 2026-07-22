#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO/set-link.sh"
  export LAYS_LINK_FILE="$BATS_TEST_TMPDIR/link.txt"
  export LAYS_HISTORY_FILE="$BATS_TEST_TMPDIR/history.log"
  export LAYS_SKIP_REMOTE=1
}

@test "script is executable" {
  [ -x "$SCRIPT" ]
}

@test "accepts a valid https URL and writes it" {
  run "$SCRIPT" "https://promo.example.com/day-1"
  [ "$status" -eq 0 ]
  [ "$(cat "$LAYS_LINK_FILE")" = "https://promo.example.com/day-1" ]
}

@test "writes exactly one line with no trailing whitespace" {
  "$SCRIPT" "https://promo.example.com/day-1"
  run wc -l < "$LAYS_LINK_FILE"
  [ "$(echo "$output" | tr -d ' ')" = "1" ]
}

@test "appends a timestamped entry to the history log" {
  "$SCRIPT" "https://promo.example.com/day-1"
  "$SCRIPT" "https://promo.example.com/day-2"
  run wc -l < "$LAYS_HISTORY_FILE"
  [ "$(echo "$output" | tr -d ' ')" = "2" ]
  run grep -c "https://promo.example.com/day-2" "$LAYS_HISTORY_FILE"
  [ "$output" = "1" ]
}

@test "overwrites rather than appends to the link file" {
  "$SCRIPT" "https://promo.example.com/day-1"
  "$SCRIPT" "https://promo.example.com/day-2"
  [ "$(cat "$LAYS_LINK_FILE")" = "https://promo.example.com/day-2" ]
}

@test "rejects http:// and leaves the existing link untouched" {
  "$SCRIPT" "https://promo.example.com/good"
  run "$SCRIPT" "http://promo.example.com/bad"
  [ "$status" -ne 0 ]
  [[ "$output" == *"https://"* ]]
  [ "$(cat "$LAYS_LINK_FILE")" = "https://promo.example.com/good" ]
}

@test "rejects a malformed URL" {
  run "$SCRIPT" "not a url"
  [ "$status" -ne 0 ]
}

@test "rejects a scheme-only URL" {
  run "$SCRIPT" "https://"
  [ "$status" -ne 0 ]
}

@test "rejects a host with no dot" {
  run "$SCRIPT" "https://localhost/promo"
  [ "$status" -ne 0 ]
}

@test "rejects empty input" {
  run "$SCRIPT" ""
  [ "$status" -ne 0 ]
}

@test "rejects a missing argument" {
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage"* ]]
}

@test "rejects multi-line input" {
  run "$SCRIPT" "$(printf 'https://a.example.com/\nhttps://b.example.com/')"
  [ "$status" -ne 0 ]
}

@test "rejects a javascript: scheme" {
  run "$SCRIPT" "javascript:alert(1)"
  [ "$status" -ne 0 ]
}
