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

@test "--stat expands a PR into its commits and marks files against the commit's own parent" {
  make_fixture
  run "$DRIVER" --stat
  [ "$status" -eq 0 ]
  [[ "$output" == *"- $(git rev-parse --short "$C1")  a.txt two"* ]]
  [[ "$output" == *"- $(git rev-parse --short "$C2")  add b.txt"* ]]
  line_after "^    - $(git rev-parse --short "$C1")  " | grep -Eq '^ +[=] +\+1 +-0 +a\.txt$'   # ours equals c0's a.txt, the pre-image
  line_after "^    - $(git rev-parse --short "$C2")  " | grep -Eq '^ +[+] +\+1 +-0 +b\.txt$'   # new upstream file
  line_after "^    - $(git rev-parse --short "$C3")  " | grep -Eq '^ +[~] +\+1 +-0 +c\.txt$'   # we changed c.txt
  line_after "^    - $(git rev-parse --short "$C4")  " | grep -Eq '^ +[x] +\+1 +-0 +d\.txt$'   # we removed d.txt, upstream edits it
  c5="$(echo "$output" | grep -A2 "^\* $(git rev-parse --short "$C5")  ")"
  echo "$c5" | grep -Eq '^ +[<] +\+1 +-0 +a\.txt$'   # ours equals the fork point, not m12's pre-image: c1 comes first
  echo "$c5" | grep -Eq '^ +[<] +\+1 +-0 +b\.txt$'   # b.txt exists in neither ours nor the fork point: c2 comes first
}

@test "--stat on a direct commit stats it like a PR" {
  make_fixture
  run "$DRIVER" --stat
  [ "$(line_after "^\* $(git rev-parse --short "$C5")  " | awk '{print $1}')" = "<" ]
}

@test "a renamed file shows as removed plus added" {
  make_fixture
  git -C "$WORK" -c user.name=t -c user.email=t@example.com mv a.txt e.txt
  git -C "$WORK" -c user.name=t -c user.email=t@example.com commit -q -m "rename a to e"
  git -C "$WORK" push -q "$UP" staging
  run "$DRIVER" --stat
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq '^ +[<] +\+0 +-3 +a\.txt$'   # ours still equals the fork point's a.txt
  echo "$output" | grep -Eq '^ +[+] +\+3 +-0 +e\.txt$'
}

@test "--show on a PR merge prints its commits and combined diff" {
  make_fixture
  run "$DRIVER" --show "$M11"
  [ "$status" -eq 0 ]
  [[ "$output" == *"a.txt two"* ]]
  [[ "$output" == *"add b.txt"* ]]
  [[ "$output" == *"+++ b/b.txt"* ]]
}

@test "--show on a plain commit is git show" {
  make_fixture
  run "$DRIVER" --show "$C1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"+two"* ]]
  [[ "$output" != *"b.txt"* ]]
}

@test "--show without a sha is an error" {
  make_fixture
  run "$DRIVER" --show
  [ "$status" -eq 1 ]
  [[ "$output" == *"--show needs a <sha>"* ]]
}

@test "--diverged lists our footprint since the fork point" {
  make_fixture
  run "$DRIVER" --diverged
  [ "$status" -eq 0 ]
  [[ "$output" == *"c.txt"* ]]
  [[ "$output" == *"d.txt"* ]]
  [[ "$output" != *"a.txt"* ]]
}

@test "--advance moves the watermark and the next listing shrinks" {
  make_fixture
  run "$DRIVER" --advance "$M12"
  [ "$status" -eq 0 ]
  [ "$(jq -r .lastReviewedSha .upstream-review/watermark.json)" = "$M12" ]
  [ "$(jq -r .lastReviewedShaShort .upstream-review/watermark.json)" = "$(git rev-parse --short "$M12")" ]
  [[ "$(jq -r .lastAdvancedAt .upstream-review/watermark.json)" == 20[0-9][0-9]-*Z ]]
  run "$DRIVER"
  [[ "$output" == *"entries to review:   1"* ]]
}

@test "--advance refuses a sha behind the watermark" {
  make_fixture
  "$DRIVER" --advance "$M12" >/dev/null
  run "$DRIVER" --advance "$M11"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is behind the current watermark"* ]]
  [ "$(jq -r .lastReviewedSha .upstream-review/watermark.json)" = "$M12" ]
}

@test "--advance refuses a sha that is not on carverauto/staging" {
  make_fixture
  ours="$(git rev-parse HEAD)"
  run "$DRIVER" --advance "$ours"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not on carverauto/staging"* ]]
}

@test "--advance refuses an inner PR commit that is not on the first-parent chain" {
  make_fixture
  run "$DRIVER" --advance "$C1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not on the first-parent chain of carverauto/staging"* ]]
  [ "$(jq -r .lastReviewedSha .upstream-review/watermark.json)" = "$C0" ]
}

@test "a watermark no longer on carverauto/staging is an error" {
  make_fixture
  write_watermark "$FORK" "$UP" "$C0" "$(git rev-parse HEAD)"
  run "$DRIVER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"lastReviewedSha is not an ancestor of carverauto/staging"* ]]
}
