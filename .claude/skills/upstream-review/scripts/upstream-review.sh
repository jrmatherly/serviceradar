#!/usr/bin/env bash
# upstream-review.sh - list, classify and watermark upstream (carverauto/serviceradar) pull
# requests for this fork.
#
# The fork shares history with upstream. Two SHAs in .upstream-review/watermark.json bound the work:
#   forkPointSha     the carverauto/staging commit the fork was cut from (fixed)
#   lastReviewedSha  the last upstream commit we assessed (advances per review)
# Ranges are <lastReviewedSha>..<remote>/<branch>, listed first-parent so one entry is one PR.
#
# USAGE (from anywhere inside the repo)
#   upstream-review.sh                 fetch upstream, list un-reviewed entries (oldest first)
#   upstream-review.sh --stat          same, plus each PR's commits and each touched file with a marker
#   upstream-review.sh --urls          same, plus a github.com commit URL per entry
#   upstream-review.sh --show <sha>    a PR merge: its commits and combined diff; any other commit: git show
#   upstream-review.sh --diverged      files where our HEAD differs from forkPointSha (our footprint)
#   upstream-review.sh --advance <sha> set lastReviewedSha to the tip SHA printed by the listing you reviewed
#
# Markers in --stat compare our HEAD with the commit's own parent (the pre-image a cherry-pick merges from),
# falling back to the fork point:
#   =   our file equals the pre-image        git cherry-pick -x <sha> applies cleanly for this file
#   <   equals the fork point, not the pre-image, or exists in neither   an earlier un-reviewed entry touched it; pick in order
#   ~   differs from both                    we changed it; expect conflicts, hand-port or resolve the 3-way
#   x   we removed it                        skip unless we want the file back
#   +   new upstream file                    cherry-pick creates it
#   bin binary file                          inspect by hand
# Only --advance writes anything, and only to the watermark file.
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

cmd="${1:-list}"
case "$cmd" in
  -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

REPO_ROOT="$(git rev-parse --show-toplevel)"
STATE="$REPO_ROOT/.upstream-review/watermark.json"
[ -f "$STATE" ] || die "missing $STATE"

require() { [ "$2" != "-" ] || die "watermark.json: $1 is missing"; }
is_sha()  { [[ "$1" =~ ^[0-9a-f]{40}$ ]] || die "watermark.json: $2 is not a full SHA: $1"; }
is_name() { [[ "$1" =~ ^[A-Za-z0-9._][A-Za-z0-9._/-]*$ ]] || die "watermark.json: $2 is not a safe git name: $1"; }

IFS=$'\t' read -r URL REMOTE BRANCH FORKSHA WATERMARK < <(
  jq -r '[.upstreamUrl, .upstreamRemote, .upstreamBranch, .forkPointSha, .lastReviewedSha] | map(. // "-") | @tsv' "$STATE")
require upstreamUrl "$URL"
require upstreamRemote "$REMOTE";     is_name "$REMOTE" upstreamRemote
require upstreamBranch "$BRANCH";     is_name "$BRANCH" upstreamBranch
require forkPointSha "$FORKSHA";      is_sha "$FORKSHA" forkPointSha
require lastReviewedSha "$WATERMARK"; is_sha "$WATERMARK" lastReviewedSha
[[ "$URL" =~ ^(https://[A-Za-z0-9._/-]+|/[^[:space:]]+)$ ]] || die "watermark.json: upstreamUrl must be a plain https URL or an absolute path"

case "$cmd" in
  --show|--diverged|--advance|list|--stat|--urls) die "not implemented" ;;
  *) die "unknown option '$cmd' (see --help)" ;;
esac
