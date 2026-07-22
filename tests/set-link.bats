#!/usr/bin/env bats

# `run --separate-stderr` (used below to assert warnings land on stderr, not
# stdout) requires bats-core >= 1.5.0; this repo pins ^1.13.0, well above
# that, but declare it explicitly so the requirement is self-documenting and
# the warning bats-core would otherwise print is silenced.
bats_require_minimum_version 1.5.0

# Portable file-mode lookup. `stat -f %Lp` is BSD/macOS-only; under GNU
# coreutils (Linux CI) `-f` means `--file-system` and takes no format
# operand, so that invocation errors out and, under bats' errexit, fails
# setup()/every test in the file. Try the GNU form first, fall back to BSD.
file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

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
  # grep, not [[ ]]: under bats a failing [[ ]] mid-test does NOT fail the test
  # (only a trailing one does), so this assertion would be silently vacuous.
  printf '%s' "$output" | grep -q "https://"
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
  mode_before="$(file_mode "$LAYS_LINK_FILE")"

  long_path="$(printf 'a%.0s' $(seq 1 3000))"
  long_url="https://good.com/${long_path}"
  [ "${#long_url}" -gt 2048 ]

  run "$SCRIPT" "$long_url"
  [ "$status" -ne 0 ]
  [ "$(cat "$LAYS_LINK_FILE")" = "https://promo.example.com/good" ]
  [ "$(file_mode "$LAYS_LINK_FILE")" = "$mode_before" ]
}

@test "rejects an underscore in the hostname and leaves the existing link untouched" {
  "$SCRIPT" "https://promo.example.com/good"
  mode_before="$(file_mode "$LAYS_LINK_FILE")"

  run "$SCRIPT" "https://good_bad.com/"
  [ "$status" -ne 0 ]
  [ "$(cat "$LAYS_LINK_FILE")" = "https://promo.example.com/good" ]
  [ "$(file_mode "$LAYS_LINK_FILE")" = "$mode_before" ]
}

# --- C1: non-ASCII (a Thai-language campaign makes this plausible, not
# theoretical) and out-of-range ports must be rejected, matching go.php's
# FILTER_VALIDATE_URL exactly. -----------------------------------------

@test "rejects a Thai-language URL path and leaves the existing link untouched" {
  "$SCRIPT" "https://promo.example.com/good"
  mode_before="$(file_mode "$LAYS_LINK_FILE")"

  run "$SCRIPT" "https://example.com/ทดสอบ"
  [ "$status" -ne 0 ]
  [ "$(cat "$LAYS_LINK_FILE")" = "https://promo.example.com/good" ]
  [ "$(file_mode "$LAYS_LINK_FILE")" = "$mode_before" ]
}

@test "rejects a Thai-language query value and leaves the existing link untouched" {
  "$SCRIPT" "https://promo.example.com/good"
  mode_before="$(file_mode "$LAYS_LINK_FILE")"

  run "$SCRIPT" "https://example.com/a?q=มตล"
  [ "$status" -ne 0 ]
  [ "$(cat "$LAYS_LINK_FILE")" = "https://promo.example.com/good" ]
  [ "$(file_mode "$LAYS_LINK_FILE")" = "$mode_before" ]
}

@test "rejects a port above the 65535 maximum and leaves the existing link untouched" {
  "$SCRIPT" "https://promo.example.com/good"
  mode_before="$(file_mode "$LAYS_LINK_FILE")"

  run "$SCRIPT" "https://good.com:99999/x"
  [ "$status" -ne 0 ]
  [ "$(cat "$LAYS_LINK_FILE")" = "https://promo.example.com/good" ]
  [ "$(file_mode "$LAYS_LINK_FILE")" = "$mode_before" ]
}

@test "accepts a port at the 65535 boundary" {
  run "$SCRIPT" "https://good.com:65535/x"
  [ "$status" -eq 0 ]
  [ "$(cat "$LAYS_LINK_FILE")" = "https://good.com:65535/x" ]
}

@test "rejects a port one past the 65535 boundary" {
  run "$SCRIPT" "https://good.com:65536/x"
  [ "$status" -ne 0 ]
}

# --- I5: punycode/IDN TLDs are accepted by go.php and must be accepted here,
# too -- a plausible .ไทย-style TLD for a Thai campaign should not be
# rejected for no safety benefit. -------------------------------------

@test "accepts a punycode/IDN TLD" {
  run "$SCRIPT" "https://xn--o3cw4h.xn--o3cw4h/x"
  [ "$status" -eq 0 ]
  [ "$(cat "$LAYS_LINK_FILE")" = "https://xn--o3cw4h.xn--o3cw4h/x" ]
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
  # The push for "bad" never succeeded, so the history log must not assert
  # that it was ever made live (the one entry present is from the earlier,
  # successful, SKIP_REMOTE=1 "good" call above).
  run grep -c "https://promo.example.com/bad" "$LAYS_HISTORY_FILE"
  [ "$output" = "0" ]
}

@test "remote push writes via a tmp file and atomic rename, and forces mode 644 regardless of remote umask" {
  "$SCRIPT" "https://promo.example.com/good"

  fake_bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$fake_bin"
  remote_dir="$BATS_TEST_TMPDIR/remote"
  mkdir -p "$remote_dir"
  cmd_log="$BATS_TEST_TMPDIR/ssh_cmd.log"

  cat > "$fake_bin/ssh" <<EOF
#!/usr/bin/env bash
# \$1 = host, \$2 = the remote command string set-link.sh built.
printf '%s' "\$2" > "$cmd_log"
umask 077
cd "$remote_dir" || exit 1
bash -c "\$2"
EOF
  chmod +x "$fake_bin/ssh"

  export LAYS_REMOTE_HOST="fake_user@fake.invalid"
  export LAYS_REMOTE_PATH="."
  export LAYS_SKIP_REMOTE=0
  PATH="$fake_bin:$PATH" run "$SCRIPT" "https://promo.example.com/atomic"

  [ "$status" -eq 0 ]
  # Must write to a .tmp file and rename into place -- never `cat >` the
  # real filename directly. A dropped connection mid `cat >` truncates then
  # streams, and a prefix of a valid URL (".../day-1" -> ".../day") is often
  # itself a valid URL go.php would accept and serve to every visitor.
  grep -qF "link.txt.tmp" "$cmd_log"
  grep -qF "mv -f" "$cmd_log"
  [ ! -e "$remote_dir/link.txt.tmp" ]
  [ "$(cat "$remote_dir/link.txt")" = "https://promo.example.com/atomic" ]
  # Forced to 644 by the remote command itself, not left to the remote
  # umask (deliberately set restrictive above to prove the chmod, not the
  # umask, is what determines the final mode).
  [ "$(file_mode "$remote_dir/link.txt")" = "644" ]
}

# --- I2: history is recorded only once the push has actually succeeded,
# and a reminder to commit the changed link file is visible on stderr. -----

@test "history log is appended only after a successful push, not before" {
  "$SCRIPT" "https://promo.example.com/good"

  fake_bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/ssh" <<'FAKESSH'
#!/usr/bin/env bash
exit 0
FAKESSH
  chmod +x "$fake_bin/ssh"

  export LAYS_REMOTE_HOST="fake_user@fake.invalid"
  export LAYS_REMOTE_PATH="/fake/path"
  export LAYS_SKIP_REMOTE=0
  PATH="$fake_bin:$PATH" run "$SCRIPT" "https://promo.example.com/pushed-ok"

  [ "$status" -eq 0 ]
  run grep -c "https://promo.example.com/pushed-ok" "$LAYS_HISTORY_FILE"
  [ "$output" = "1" ]
}

@test "prints a reminder to stderr that the changed link file should be committed" {
  run --separate-stderr "$SCRIPT" "https://promo.example.com/good"
  [ "$status" -eq 0 ]
  # grep, not [[ ]]: under bats a failing [[ ]] mid-test does NOT fail the
  # test (only a trailing one does), so those assertions would be silently
  # vacuous. See the identical note on "rejects http://" above.
  grep -qF "$LAYS_LINK_FILE" <<< "$stderr"
  grep -qF "commit" <<< "$stderr"
  # Must be on stderr, not mixed into the routine stdout progress output.
  run grep -c "commit" <<< "$output"
  [ "$output" = "0" ]
}

@test "warns on stderr, not stdout, when verification is skipped because LAYS_SITE_URL is unset" {
  fake_bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/ssh" <<'FAKESSH'
#!/usr/bin/env bash
exit 0
FAKESSH
  chmod +x "$fake_bin/ssh"

  export LAYS_REMOTE_HOST="fake_user@fake.invalid"
  export LAYS_REMOTE_PATH="/fake/path"
  export LAYS_SKIP_REMOTE=0
  unset LAYS_SITE_URL
  PATH="$fake_bin:$PATH" run --separate-stderr "$SCRIPT" "https://promo.example.com/good"

  [ "$status" -eq 0 ]
  # grep, not [[ ]]: see the note in the test above.
  grep -qF "skipped" <<< "$stderr"
  grep -qF "LAYS_SITE_URL" <<< "$stderr"
  run grep -c "skipped" <<< "$output"
  [ "$output" = "0" ]
}

# --- Trailing slash in LAYS_SITE_URL must not produce "//go" --------------

@test "strips a trailing slash from LAYS_SITE_URL before building the verify URL" {
  fake_bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/ssh" <<'FAKESSH'
#!/usr/bin/env bash
exit 0
FAKESSH
  chmod +x "$fake_bin/ssh"

  curl_log="$BATS_TEST_TMPDIR/curl.log"
  cat > "$fake_bin/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$curl_log"
printf '%s' "https://promo.example.com/trailing-slash-test"
EOF
  chmod +x "$fake_bin/curl"

  export LAYS_REMOTE_HOST="fake_user@fake.invalid"
  export LAYS_REMOTE_PATH="/fake/path"
  export LAYS_SKIP_REMOTE=0
  export LAYS_SITE_URL="https://example.com/"
  PATH="$fake_bin:$PATH" run "$SCRIPT" "https://promo.example.com/trailing-slash-test"

  [ "$status" -eq 0 ]
  grep -qF "https://example.com/go" "$curl_log"
  # `!`, not a bare command: a negated command's failure is exempt from
  # bats' errexit regardless of position (unlike plain `[[ ]]`, this one is
  # a documented bash -e rule, not just a bats quirk), so `! grep ...` here
  # would be silently vacuous even as the trailing statement. Use `run` and
  # assert on the captured exit status instead.
  run grep -qF "https://example.com//go" "$curl_log"
  [ "$status" -ne 0 ]
}
