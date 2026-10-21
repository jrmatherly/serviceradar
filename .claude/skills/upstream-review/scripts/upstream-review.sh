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
TIP="refs/remotes/$REMOTE/$BRANCH"
REFSPEC="+refs/heads/$BRANCH:$TIP"
GH_WEB="${URL%.git}/commit"
PR_SUBJECT='^Merge pull request #([0-9]+) from [^/]+/(.*)$'

g() { git -C "$REPO_ROOT" "$@"; }

ensure_upstream() {
  local have
  if have="$(g remote get-url -- "$REMOTE" 2>/dev/null)"; then
    [ "$have" = "$URL" ] || die "remote '$REMOTE' points at $have, watermark.json says $URL"
  else
    echo "[upstream-review] adding remote $REMOTE -> $URL" >&2
    g remote add --no-tags -- "$REMOTE" "$URL"
  fi
  echo "[upstream-review] fetching $REMOTE/$BRANCH" >&2
  if ! g fetch -q --no-tags -- "$REMOTE" "$REFSPEC" 2>/dev/null; then
    g rev-parse -q --verify "$TIP" >/dev/null || die "fetch failed and no cached $TIP"
    echo "[upstream-review] fetch failed; using cached $TIP" >&2
  fi
  g merge-base --is-ancestor "$WATERMARK" "$TIP" || die "lastReviewedSha is not an ancestor of $REMOTE/$BRANCH (history rewritten?)"
}

# The PR title GitHub writes into the merge commit body: its first non-empty line.
pr_title() { g log -1 --format=%b "$1" | sed -n '/./{p;q;}'; }

# Print one line per file the commit touches: marker, +adds, -dels, path. Three git calls per commit:
# diff-tree --raw gives the pre-image blob, --numstat the counts, cat-file --batch-check our HEAD and fork-point blobs.
stat_commit() {
  local commit="$1" meta path pre head fork i j n=0 m
  local paths pres heads forks adds dels; paths=(); pres=(); heads=(); forks=(); adds=(); dels=()
  while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
    read -r _ _ pre _ <<<"$meta"
    paths[n]="$path"; pres[n]="$pre"; n=$((n+1))
  done < <(g diff-tree --no-commit-id --no-renames -r -z --raw "$commit")
  [ "$n" -gt 0 ] || return 0
  i=0
  while IFS=$'\t' read -r -d '' add del path; do adds[i]="$add"; dels[i]="$del"; i=$((i+1)); done < <(g diff-tree --no-commit-id --no-renames -r -z --numstat "$commit")
  i=0
  while read -r head _ && read -r fork _; do heads[i]="$head"; forks[i]="$fork"; i=$((i+1)); done < <(
    for ((j=0; j<n; j++)); do printf 'HEAD:%s\n%s:%s\n' "${paths[j]}" "$FORKSHA" "${paths[j]}"; done |
    g cat-file --batch-check='%(objectname) %(objecttype)' | sed 's/^.* missing$/- missing/')
  for ((i=0; i<n; i++)); do
    pre="${pres[i]}"; head="${heads[i]}"; fork="${forks[i]}"
    if [ "${adds[i]}" = "-" ]; then m=bin
    elif [[ "$pre" =~ ^0+$ ]]; then
      if [ "$head" = "-" ]; then m="+"; elif [ "$head" = "$fork" ]; then m="<"; else m="~"; fi
    elif [ "$head" = "-" ]; then
      if [ "$fork" = "-" ]; then m="<"; else m=x; fi
    elif [ "$head" = "$pre" ]; then m="="
    elif [ "$head" = "$fork" ]; then m="<"
    else m="~"; fi
    if [ "$m" = bin ]; then printf '      %-3s %5s %5s  %s\n' bin "" "" "${paths[i]}"
    else printf '      %-3s %5s %5s  %s\n' "$m" "+${adds[i]}" "-${dels[i]}" "${paths[i]}"; fi
  done
}

case "$cmd" in
  --show|--diverged|--advance) die "not implemented" ;;
  list|--stat|--urls) ;;
  *) die "unknown option '$cmd' (see --help)" ;;
esac

ensure_upstream
RANGE="$WATERMARK..$TIP"
COUNT="$(g rev-list --count --first-parent "$RANGE")"
TIPSHA="$(g rev-parse "$TIP")"
echo "Upstream review: $REMOTE/$BRANCH"
echo "  fork point:          $(g rev-parse --short "$FORKSHA") $(g log -1 --date=short --pretty=%ad "$FORKSHA")"
echo "  last reviewed:       $(g rev-parse --short "$WATERMARK") $(g log -1 --date=short --pretty=%ad "$WATERMARK")"
echo "  upstream tip:        $TIPSHA"
echo "  entries to review:   $COUNT"
[ "$COUNT" -eq 0 ] && { echo "Up to date."; exit 0; }

g log --first-parent --reverse --date=short --pretty='%H%x09%h%x09%ad%x09%P%x09%s' "$RANGE" |
while IFS=$'\t' read -r full short date parents subj; do
  echo
  if [[ "$parents" == *" "* ]]; then
    k="$(g rev-list --count "$full^1..$full^2")"
    if [[ "$subj" =~ $PR_SUBJECT ]]; then
      echo "* $short  $date  PR #${BASH_REMATCH[1]} ${BASH_REMATCH[2]}: $(pr_title "$full")  [$k commits]"
    else
      echo "* $short  $date  merge $subj  [$k commits]"
    fi
    if [ "$cmd" = "--stat" ]; then
      g log --reverse --pretty='%h%x09%s' "$full^1..$full^2" | while IFS=$'\t' read -r ishort isubj; do
        echo "    - $ishort  $isubj"
        stat_commit "$ishort"
      done
    fi
  else
    echo "* $short  $date  $subj"
    if [ "$cmd" = "--stat" ]; then stat_commit "$full"; fi
  fi
  if [ "$cmd" = "--urls" ]; then echo "    $GH_WEB/$full"; fi
done

echo
echo "Next: classify each entry (see SKILL.md), write .upstream-review/reviews/$(date +%Y-%m-%d)-review.md"
echo "with 'Window: $(g rev-parse --short "$WATERMARK")..$TIPSHA', then: $0 --advance $TIPSHA"
