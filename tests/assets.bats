#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "background asset exists at 1080x1920" {
  run file "$REPO/site/assets/bg.png"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PNG image data, 1080 x 1920"* ]]
}

@test "Lay's logo asset exists at 190x179" {
  run file "$REPO/site/assets/logo-lays.png"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PNG image data, 190 x 179"* ]]
}

@test "mtr badge asset exists at 472x274" {
  run file "$REPO/site/assets/logo-mtr.png"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PNG image data, 472 x 274"* ]]
}

@test "CTA button asset exists at 913x280" {
  run file "$REPO/site/assets/btn-add-template.png"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PNG image data, 913 x 280"* ]]
}

@test "Open Graph image exists at 1200x630" {
  # 1200x630 (~1.91:1) is what LINE, Facebook and X render link previews at.
  # The page's own artwork is 9:16 portrait; handing that to them center-crops
  # the Lay's logo out of the card entirely. Regenerate with: npm run og:build
  run file "$REPO/site/assets/og-image.png"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PNG image data, 1200 x 630"* ]]
}

@test "favicon exists" {
  [ -f "$REPO/site/favicon.png" ]
}

@test "no deployed asset filename contains a space" {
  run bash -c "find \"$REPO/site\" -name '* *' -print"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
