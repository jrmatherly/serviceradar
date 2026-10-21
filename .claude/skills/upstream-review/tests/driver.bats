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
