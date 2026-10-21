# shellcheck disable=SC2034  # globals are consumed by the bats files that load this helper
# Shared by every bats file. DRIVER is the script under test; tmp repos live under BATS_TEST_TMPDIR.
# The user's global git config signs commits through 1Password; fixtures must not see it.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
DRIVER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/upstream-review.sh"

# shellcheck disable=SC2154  # $output is set by bats' run
line_after() { echo "$output" | grep -A1 "$1" | tail -1; }  # the stat line printed under an entry or commit line

write_watermark() { # <repo> <upstream_url> <fork_sha> <reviewed_sha>
  mkdir -p "$1/.upstream-review/reviews"
  jq -n --arg u "$2" --arg f "$3" --arg r "$4" \
    '{upstreamUrl:$u, upstreamRemote:"carverauto", upstreamBranch:"staging",
      forkPointSha:$f, forkPointDate:"2026-01-01",
      lastReviewedSha:$r, lastReviewedShaShort:($r|.[0:10]), lastReviewedDate:"2026-01-01",
      lastAdvancedAt:"2026-01-01T00:00:00Z", note:"fixture"}' > "$1/.upstream-review/watermark.json"
}
