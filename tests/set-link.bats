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
  content="$(cat "$LAYS_LINK_FILE")"
  # cat via command substitution strips only the trailing newline(s), so any
  # trailing space/tab left before that newline would still show up here.
  case "$content" in
    *[[:space:]]) trailing_space=1 ;;
    *) trailing_space=0 ;;
  esac
  [ "$trailing_space" -eq 0 ]
}

@test "appends a timestamped entry to the history log" {
  "$SCRIPT" "https://promo.example.com/day-1"
  "$SCRIPT" "https://promo.example.com/day-2"
  run wc -l < "$LAYS_HISTORY_FILE"
  [ "$(echo "$output" | tr -d ' ')" = "2" ]
  run grep -c "https://promo.example.com/day-2" "$LAYS_HISTORY_FILE"
  [ "$output" = "1" ]

  last_line="$(tail -n 1 "$LAYS_HISTORY_FILE")"
  field_count="$(printf '%s' "$last_line" | awk -F'\t' '{print NF}')"
  timestamp_field="$(printf '%s' "$last_line" | cut -f1)"
  url_field="$(printf '%s' "$last_line" | cut -f2)"

  [ "$field_count" -eq 2 ]
  printf '%s' "$timestamp_field" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
  [ "$url_field" = "https://promo.example.com/day-2" ]
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

# --- C1: accept-set must agree with go.php's is_valid_https_url() ---------

@test "rejects a URL longer than 2048 characters and leaves the existing link untouched" {
  "$SCRIPT" "https://promo.example.com/good"
  mode_before="$(stat -f '%Lp' "$LAYS_LINK_FILE")"

  long_path="$(printf 'a%.0s' $(seq 1 3000))"
  long_url="https://good.com/${long_path}"
  [ "${#long_url}" -gt 2048 ]

  run "$SCRIPT" "$long_url"
  [ "$status" -ne 0 ]
  [ "$(cat "$LAYS_LINK_FILE")" = "https://promo.example.com/good" ]
  [ "$(stat -f '%Lp' "$LAYS_LINK_FILE")" = "$mode_before" ]
}

@test "rejects an underscore in the hostname and leaves the existing link untouched" {
  "$SCRIPT" "https://promo.example.com/good"
  mode_before="$(stat -f '%Lp' "$LAYS_LINK_FILE")"

  run "$SCRIPT" "https://good_bad.com/"
  [ "$status" -ne 0 ]
  [ "$(cat "$LAYS_LINK_FILE")" = "https://promo.example.com/good" ]
  [ "$(stat -f '%Lp' "$LAYS_LINK_FILE")" = "$mode_before" ]
}

# --- I2: the stricter-than-go.php direction must stay rejected ------------

@test "rejects a URL with a userinfo component (brand-spoofing) and leaves the existing link untouched" {
  "$SCRIPT" "https://promo.example.com/good"

  run "$SCRIPT" "https://good.com@evil.com/"
  [ "$status" -ne 0 ]
  [ "$(cat "$LAYS_LINK_FILE")" = "https://promo.example.com/good" ]

  run "$SCRIPT" "https://user:pass@evil.com/"
  [ "$status" -ne 0 ]
  [ "$(cat "$LAYS_LINK_FILE")" = "https://promo.example.com/good" ]
}

# --- I1: a failed SSH push must be reported plainly, not silently ---------

@test "SSH push failure states plainly that local was updated but remote was not" {
  "$SCRIPT" "https://promo.example.com/good"

  fake_bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/ssh" <<'FAKESSH'
#!/usr/bin/env bash
exit 1
FAKESSH
  chmod +x "$fake_bin/ssh"

  export LAYS_REMOTE_HOST="fake_user@fake.invalid"
  export LAYS_REMOTE_PATH="/fake/path"
  export LAYS_SKIP_REMOTE=0
  PATH="$fake_bin:$PATH" run "$SCRIPT" "https://promo.example.com/bad"

  [ "$status" -ne 0 ]
  grep -qF "local" <<< "$output"
  grep -qF "NOT" <<< "$output"
  grep -qF "still serving" <<< "$output"
  grep -qF "Re-run" <<< "$output"
  [ "$(cat "$LAYS_LINK_FILE")" = "https://promo.example.com/bad" ]
}
