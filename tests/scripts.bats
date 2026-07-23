#!/usr/bin/env bats
#
# Config-lint checks for the deploy/provisioning shell scripts. These do not
# require an Ubuntu box -- they check the scripts themselves, statically --
# but they pin the exact failure modes that are otherwise invisible until
# production: a locked-out Droplet (ufw enabled before the SSH rule exists)
# or a silently-ignored .htaccess (missing AllowOverride All).

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PROVISION="$REPO/provision.sh"
  DEPLOY="$REPO/deploy.sh"
}

# All shell scripts this repo ships at the top level. Kept as a literal list
# (rather than a glob expanded at test time) so an unexpected missing file
# fails loudly via the executable/shebang checks below instead of silently
# shrinking the set under test.
all_scripts() {
  printf '%s\n' \
    "$REPO/provision.sh" \
    "$REPO/deploy.sh" \
    "$REPO/verify-deploy.sh" \
    "$REPO/set-link.sh"
}

@test "every shell script exists" {
  while IFS= read -r f; do
    [ -f "$f" ]
  done < <(all_scripts)
}

@test "every shell script passes bash -n (syntax check)" {
  while IFS= read -r f; do
    run bash -n "$f"
    [ "$status" -eq 0 ] || {
      printf 'bash -n failed for %s:\n%s\n' "$f" "$output" >&2
      return 1
    }
  done < <(all_scripts)
}

@test "every shell script is executable" {
  while IFS= read -r f; do
    [ -x "$f" ] || {
      printf '%s is not executable\n' "$f" >&2
      return 1
    }
  done < <(all_scripts)
}

@test "every shell script has a #!/usr/bin/env bash shebang" {
  while IFS= read -r f; do
    first_line="$(head -n 1 "$f")"
    [ "$first_line" = "#!/usr/bin/env bash" ] || {
      printf '%s has shebang "%s", expected "#!/usr/bin/env bash"\n' "$f" "$first_line" >&2
      return 1
    }
  done < <(all_scripts)
}

# --- provision.sh: the checks that pin genuinely destructive failure modes -

@test "provision.sh adds the SSH allow rule before enabling ufw" {
  # Getting this wrong permanently locks the operator out of the Droplet,
  # recoverable only through DigitalOcean's web console -- assert on the
  # actual line ordering in the file, not just that both strings appear
  # somewhere in it.
  ssh_line="$(grep -n 'ufw allow OpenSSH' "$PROVISION" | head -n 1 | cut -d: -f1)"
  enable_line="$(grep -n 'ufw --force enable' "$PROVISION" | head -n 1 | cut -d: -f1)"

  [ -n "$ssh_line" ]
  [ -n "$enable_line" ]
  [ "$ssh_line" -lt "$enable_line" ]
}

@test "provision.sh contains AllowOverride All on the document root" {
  # Without it, Apache silently ignores site/.htaccess -- both the /go
  # rewrite and the link.txt deny stop working with no error anywhere.
  grep -q 'AllowOverride All' "$PROVISION"
}

@test "provision.sh does not open 80 or 443 to the world" {
  # No literal 0.0.0.0/0 anywhere, and no ufw rule whose source is "any"
  # for port 80 or 443. Every ufw allow rule for 80/443 in this script must
  # be scoped to a specific Cloudflare CIDR (ufw allow from <cidr> ...).
  ! grep -q '0\.0\.0\.0/0' "$PROVISION"
  ! grep -qE 'from any to any port (80|443)' "$PROVISION"
  ! grep -qE '(^|[^0-9])(ufw allow )(80|443)(/tcp)?([^0-9]|$)' "$PROVISION"
}

@test "provision.sh scopes 80/443 ufw rules to a variable Cloudflare CIDR, not a hardcoded one" {
  # The allow rules must come from the live-fetched range, referenced via
  # the loop variable, not a hardcoded/stale IP baked into the script.
  grep -qE 'ufw allow from "\$cidr" to any port 80 proto tcp' "$PROVISION"
  grep -qE 'ufw allow from "\$cidr" to any port 443 proto tcp' "$PROVISION"
}

@test "provision.sh aborts (does not fall back) when a Cloudflare IP fetch fails or fails validation" {
  grep -q 'CF_IPV4_URL' "$PROVISION"
  grep -q 'CF_IPV6_URL' "$PROVISION"
  grep -q 'die "failed to fetch Cloudflare IPv4 ranges' "$PROVISION"
  grep -q 'die "failed to fetch Cloudflare IPv6 ranges' "$PROVISION"
  grep -q 'die "response from \$CF_IPV4_URL does not look like a list of IPv4 CIDR ranges' "$PROVISION"
  grep -q 'die "response from \$CF_IPV6_URL does not look like a list of IPv6 CIDR ranges' "$PROVISION"
}

@test "provision.sh refuses to reload Apache on a failed configtest" {
  grep -q 'apache2ctl configtest' "$PROVISION"
  grep -q 'refusing to reload Apache with a broken config' "$PROVISION"
}

@test "provision.sh reads the origin certificate and key from /root and chmods the key 600" {
  grep -q '/root/cloudflare-origin.pem' "$PROVISION"
  grep -q '/root/cloudflare-origin.key' "$PROVISION"
  grep -q 'chmod 600' "$PROVISION"
}

@test "provision.sh requires root and Ubuntu 24.04" {
  grep -q 'id -u' "$PROVISION"
  grep -q '24.04' "$PROVISION"
}

# --- deploy.sh --------------------------------------------------------------

@test "deploy.sh still excludes link.txt from the rsync" {
  # Load-bearing: link.txt is operator state owned by set-link.sh, not
  # build output. Without this exclusion a deploy silently reverts the
  # live CTA to the committed seed value.
  grep -qF -- "--exclude 'link.txt'" "$DEPLOY"
}

@test "deploy.sh targets the Droplet document root, not Cloudways public_html" {
  ! grep -q 'public_html' "$DEPLOY"
  ! grep -qi 'cloudways' "$DEPLOY"
}

@test "provision.sh refuses to disable SSH passwords without an installed key" {
  # Turning off password auth with no key installed permanently locks the
  # operator out of the Droplet -- recoverable only via DigitalOcean's browser
  # console. The guard must check authorized_keys and bail out first.
  run grep -n "authorized_keys" "$REPO/provision.sh"
  [ "$status" -eq 0 ]

  guard="$(grep -n 'SKIPPING SSH hardening' "$REPO/provision.sh" | head -1 | cut -d: -f1)"
  disable="$(grep -n '^PasswordAuthentication no' "$REPO/provision.sh" | head -1 | cut -d: -f1)"
  [ -n "$guard" ]
  [ -n "$disable" ]
  # The bail-out must appear before the directive that disables passwords.
  [ "$guard" -lt "$disable" ]
}

@test "provision.sh validates sshd config before reloading" {
  # A malformed drop-in that is reloaded without `sshd -t` takes SSH down.
  run grep -q "sshd -t" "$REPO/provision.sh"
  [ "$status" -eq 0 ]
}
