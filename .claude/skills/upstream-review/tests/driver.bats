load helpers

setup() { REPO="$BATS_TEST_TMPDIR/repo"; git init -q "$REPO"; cd "$REPO"; git -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m base; }

@test "help prints usage and exits 0" {
  run "$DRIVER" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--advance"* ]]
}

@test "missing watermark is an error" {
  run "$DRIVER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: missing"*".upstream-review/watermark.json"* ]]
}

@test "a short SHA in the watermark is rejected" {
  write_watermark "$REPO" "https://example.com/u.git" "abc123" "abc123"
  run "$DRIVER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"forkPointSha is not a full SHA"* ]]
}

@test "an unknown option is an error" {
  write_watermark "$REPO" "https://example.com/u.git" "$(git rev-parse HEAD)" "$(git rev-parse HEAD)"
  run "$DRIVER" --bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown option"* ]]
}

@test "first run adds the carverauto remote without tags and lists entries oldest first" {
  make_fixture
  run "$DRIVER"
  [ "$status" -eq 0 ]
  [ "$(git remote get-url carverauto)" = "$UP" ]
  [ "$(git config --get remote.carverauto.tagOpt)" = "--no-tags" ]
  [[ "$output" == *"entries to review:   3"* ]]
  [[ "$output" == *"* $(git rev-parse --short "$M11")  "*"PR #11 feat/alpha: add alpha  [2 commits]"* ]]
  [[ "$output" == *"* $(git rev-parse --short "$M12")  "*"PR #12 fix/beta: fix beta  [2 commits]"* ]]
  [[ "$output" == *"* $(git rev-parse --short "$C5")  "*"a.txt three"* ]]
  [ "$(echo "$output" | grep '^\* ' | head -1 | awk '{print $2}')" = "$(git rev-parse --short "$M11")" ]
  [ "$(echo "$output" | grep '^\* ' | tail -1 | awk '{print $2}')" = "$(git rev-parse --short "$C5")" ]
  [[ "$output" == *"--advance $(git rev-parse "$C5")"* ]]
}

@test "up to date when the watermark is the tip" {
  make_fixture
  write_watermark "$FORK" "$UP" "$C0" "$C5"
  run "$DRIVER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Up to date."* ]]
}

@test "--urls prints one commit URL per entry" {
  make_fixture
  run "$DRIVER" --urls
  [ "$status" -eq 0 ]
  [[ "$output" == *"$UP/commit/$M11"* ]]
  [[ "$output" == *"$UP/commit/$C5"* ]]
}

@test "offline after a first fetch uses the cached ref" {
  make_fixture
  "$DRIVER" >/dev/null
  mv "$UP" "$UP.gone"
  run "$DRIVER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fetch failed; using cached"* ]]
  [[ "$output" == *"entries to review:   3"* ]]
}

@test "a remote named carverauto that points elsewhere is an error" {
  make_fixture
  git remote add carverauto /nowhere/else
  run "$DRIVER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"remote 'carverauto' points at /nowhere/else"* ]]
}
