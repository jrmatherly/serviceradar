# shellcheck disable=SC2034  # globals are consumed by the bats files that load this helper
# Shared by every bats file. DRIVER is the script under test; tmp repos live under BATS_TEST_TMPDIR.
# The user's global git config signs commits through 1Password; fixtures must not see it.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
DRIVER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/upstream-review.sh"

# shellcheck disable=SC2154  # $output is set by bats' run
line_after() { echo "$output" | grep -A1 "$1" | tail -1; }  # the stat line printed under an entry or commit line

# A bare upstream (UP), the clone that authored it (WORK), and our fork (FORK, cwd afterwards).
# Two PRs merged with merge commits, one direct push, and one local deviation; every file ends in a newline.
make_fixture() {
  UP="$BATS_TEST_TMPDIR/up"; WORK="$BATS_TEST_TMPDIR/work"; FORK="$BATS_TEST_TMPDIR/fork"
  local G="git -c user.name=t -c user.email=t@example.com"
  git init -q --bare -b staging "$UP"
  $G init -q -b staging "$WORK"
  cd "$WORK" || return 1
  printf 'one\n' > a.txt; printf 'see\n' > c.txt; printf 'dee\n' > d.txt
  $G add . && $G commit -q -m base; C0=$(git rev-parse HEAD)
  $G switch -q -c feat/alpha
  printf 'one\ntwo\n' > a.txt; $G commit -q -am "a.txt two"; C1=$(git rev-parse HEAD)
  printf 'bee\n' > b.txt; $G add b.txt; $G commit -q -m "add b.txt"; C2=$(git rev-parse HEAD)
  $G switch -q staging
  $G merge -q --no-ff -m "Merge pull request #11 from carverauto/feat/alpha" -m "add alpha" feat/alpha; M11=$(git rev-parse HEAD)
  $G switch -q -c fix/beta
  printf 'see\nsaw\n' > c.txt; $G commit -q -am "c.txt saw"; C3=$(git rev-parse HEAD)
  printf 'dee\ndoo\n' > d.txt; $G commit -q -am "d.txt doo"; C4=$(git rev-parse HEAD)
  $G switch -q staging
  $G merge -q --no-ff -m "Merge pull request #12 from carverauto/fix/beta" -m "fix beta" fix/beta; M12=$(git rev-parse HEAD)
  printf 'one\ntwo\nthree\n' > a.txt; printf 'bee\nboo\n' > b.txt; $G commit -q -am "a.txt three"; C5=$(git rev-parse HEAD)
  $G push -q "$UP" staging
  $G clone -q "$UP" "$FORK"
  cd "$FORK" || return 1
  $G reset -q --hard "$C0"
  printf 'ours\n' > c.txt; $G rm -q d.txt; $G commit -q -am ours
  write_watermark "$FORK" "$UP" "$C0" "$C0"
}

write_watermark() { # <repo> <upstream_url> <fork_sha> <reviewed_sha>
  mkdir -p "$1/.upstream-review/reviews"
  jq -n --arg u "$2" --arg f "$3" --arg r "$4" \
    '{upstreamUrl:$u, upstreamRemote:"carverauto", upstreamBranch:"staging",
      forkPointSha:$f, forkPointDate:"2026-01-01",
      lastReviewedSha:$r, lastReviewedShaShort:($r|.[0:10]), lastReviewedDate:"2026-01-01",
      lastAdvancedAt:"2026-01-01T00:00:00Z", note:"fixture"}' > "$1/.upstream-review/watermark.json"
}
