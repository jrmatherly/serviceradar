# Upstream Review Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A tracked project skill, `/upstream-review`, that lists unreviewed `carverauto/serviceradar` pull requests, marks each touched file against our tree, records verdicts in a dated log, and advances a watermark.

**Architecture:** A bash driver under the skill directory does every deterministic step (fetch, first-parent listing, per-file markers, watermark) and is covered by bats tests against a generated fixture repository. `SKILL.md` carries the review method and repo rules; `references/` carry the deviations table, the log template and the validation commands. State is two tracked files under `.upstream-review/`.

**Tech Stack:** bash (`#!/usr/bin/env bash`, which is Homebrew bash 5.3 here; the script must also run under `/bin/bash` 3.2, exercised once in Task 8) plus git, jq; bats 1.14 and shellcheck for tests; Claude Code project skill (`.claude/skills/`).

**Spec:** `docs/superpowers/specs/2026-10-21-upstream-review-skill.md`

## Global Constraints

- Upstream remote is named `carverauto`, URL `https://github.com/carverauto/serviceradar.git`, branch `staging`. Never `upstream`.
- Fork point is `5993ec10432ccbddaeffb5fe3416ba7d261bede7` (2026-10-21).
- Adoption unit is the inner commit, cherry-picked with `-x`, oldest first. No squash, no `-m 1`.
- Markdown is ASCII only (repo rule). Fixture content is invented; no hostnames, IPs or names from any live system.
- Never push to `staging`. Push with `git push origin <local>:refs/heads/<branch>`. Push and PR only when the owner says so.
- The working tree already holds uncommitted `docker-compose.arm64.yml` and a `README.md` edit from another task. Never stage them.
- Every script passes `shellcheck`. Every bats file passes `bats`.
- The user's global git config sets `commit.gpgsign=true` with ssh signing through 1Password. Fixture commits must not inherit it: `helpers.bash` exports `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_NOSYSTEM=1`.
- In bash, a `[[ $s =~ ... ]]` regex that contains spaces must live in a variable (`r='...'; [[ $s =~ $r ]]`); inline it is a syntax error under bash 3.2.
- Under `set -euo pipefail`, a `while` loop body must end in a statement that exits 0 (an `if`, not `[ ... ] && echo`), or the pipeline's status aborts the script before the footer.
- `.github/` is treated as ours (a separate session replaces it); upstream workflow changes are hand-ported, never picked.
- `AGENTS.md` says to load the `test-audit` skill before writing tests. No such skill exists in this checkout or in the installed plugins (checked 2026-10-21), so the PR body records it as not run.
- The fork cannot run `make check`: `scripts/check.sh` uses `bazel --config=ci`, which `.bazelrc:135` points at upstream's in-cluster remote cache.

## Review Focus

1. A first-parent commit that is not a PR merge (a direct push or a squash merge upstream): must list and stat like a PR entry. Pinned in Task 3 and Task 4 by the fixture's direct commit.
2. Upstream history rewritten so the watermark is no longer on `carverauto/staging`: the driver must refuse with a clear message, not list the whole history. Pinned in Task 6.
3. `--advance` to a SHA behind the current watermark, off `carverauto/staging`, or an inner PR commit that is not on the first-parent chain (the next listing would re-show its PR): refuse. Pinned in Task 6.
4. Offline run after a successful first fetch: use the cached remote ref and say so, exit 0. Pinned in Task 3.
5. A file we deleted that upstream later edits (`x` with non-zero adds), and a file upstream renamed (`--no-renames` shows the old path as `<` or `~` with only deletions, the new path as `+`): never a crash on a missing blob. Pinned in Task 4.

---

### Task 1: Track `.claude/skills/` and `.upstream-review/` in git

**Files:**
- Modify: `.gitignore:27`
- Create: `.upstream-review/reviews/.gitkeep`

**Interfaces:**
- Produces: tracked paths `.claude/skills/**`, `.upstream-review/**` that every later task writes into.

- [ ] **Step 1: Write the failing check**

Run: `git check-ignore -q .claude/skills/upstream-review/SKILL.md; echo "exit=$?"`
Expected: `exit=0` (ignored today; the check must flip to `exit=1`).

- [ ] **Step 2: Edit `.gitignore`**

Replace the single line `.claude/` at line 27 with:

```
.claude/*
!.claude/skills/
```

`.claude/*` excludes the directory's entries rather than the directory itself, so `!.claude/skills/` can re-include one of them (git cannot re-include a child of an excluded directory). Everything else under `.claude/`, including `settings.local.json` and `worktrees/`, stays ignored.

- [ ] **Step 3: Verify**

Run: `git check-ignore -q .claude/skills/upstream-review/SKILL.md; echo "a=$?"; git check-ignore -q .claude/settings.local.json; echo "b=$?"; git check-ignore -q .claude/worktrees/x; echo "c=$?"; git check-ignore -q .upstream-review/watermark.json; echo "d=$?"`
Expected: `a=1 b=0 c=0 d=1`

- [ ] **Step 4: Create the branch and commit**

```bash
git switch -c feat/upstream-review-skill
mkdir -p .upstream-review/reviews && touch .upstream-review/reviews/.gitkeep
git add .gitignore .upstream-review/reviews/.gitkeep docs/superpowers/specs/2026-10-21-upstream-review-skill.md docs/superpowers/plans/2026-10-21-upstream-review-skill.md
git commit -m "chore(git): track project skills and upstream review state"
```

The spec and plan ride along in this first commit so the PR can cite them.

---

### Task 2: Watermark file and driver skeleton with validation

**Files:**
- Create: `.upstream-review/watermark.json`
- Create: `.claude/skills/upstream-review/scripts/upstream-review.sh`
- Test: `.claude/skills/upstream-review/tests/driver.bats`
- Test helper: `.claude/skills/upstream-review/tests/helpers.bash`

**Interfaces:**
- Produces: `watermark.json` with keys `upstreamUrl`, `upstreamRemote`, `upstreamBranch`, `forkPointSha`, `forkPointDate`, `lastReviewedSha`, `lastReviewedShaShort`, `lastReviewedDate`, `lastAdvancedAt`, `note`.
- Produces: driver entry `upstream-review.sh [--stat | --urls | --show <sha> | --diverged | --advance <sha> | -h]`, exit 0 on success, 1 on every error, errors on stderr prefixed `ERROR:`.
- Produces: helper `write_watermark <repo> <url> <fork_sha> <reviewed_sha>` in `helpers.bash`.

- [ ] **Step 1: Write the watermark**

`.upstream-review/watermark.json`, exact values:

```json
{
  "upstreamUrl": "https://github.com/carverauto/serviceradar.git",
  "upstreamRemote": "carverauto",
  "upstreamBranch": "staging",
  "forkPointSha": "5993ec10432ccbddaeffb5fe3416ba7d261bede7",
  "forkPointDate": "2026-10-21",
  "lastReviewedSha": "5993ec10432ccbddaeffb5fe3416ba7d261bede7",
  "lastReviewedShaShort": "5993ec1043",
  "lastReviewedDate": "2026-10-21",
  "lastAdvancedAt": "2026-10-21T00:00:00Z",
  "note": "forkPointSha = the carverauto/staging commit this fork was cut from (fixed). lastReviewedSha = the last upstream commit reviewed; advance it only with .claude/skills/upstream-review/scripts/upstream-review.sh --advance <tip-sha>."
}
```

- [ ] **Step 2: Write the failing validation tests**

`tests/helpers.bash`:

```bash
# shellcheck disable=SC2034  # globals are consumed by the bats files that load this helper
# Shared by every bats file. DRIVER is the script under test; tmp repos live under BATS_TEST_TMPDIR.
# The user's global git config signs commits through 1Password; fixtures must not see it.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
DRIVER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/upstream-review.sh"

line_after() { echo "$output" | grep -A1 "$1" | tail -1; }  # the stat line printed under an entry or commit line

write_watermark() { # <repo> <upstream_url> <fork_sha> <reviewed_sha>
  mkdir -p "$1/.upstream-review/reviews"
  jq -n --arg u "$2" --arg f "$3" --arg r "$4" \
    '{upstreamUrl:$u, upstreamRemote:"carverauto", upstreamBranch:"staging",
      forkPointSha:$f, forkPointDate:"2026-01-01",
      lastReviewedSha:$r, lastReviewedShaShort:($r|.[0:10]), lastReviewedDate:"2026-01-01",
      lastAdvancedAt:"2026-01-01T00:00:00Z", note:"fixture"}' > "$1/.upstream-review/watermark.json"
}
```

`tests/driver.bats`:

```bash
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
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bats .claude/skills/upstream-review/tests/driver.bats`
Expected: 4 failures ("No such file or directory" for the driver).

- [ ] **Step 4: Write the driver skeleton**

`scripts/upstream-review.sh`, `chmod +x`, `#!/usr/bin/env bash`, `set -euo pipefail`, header comment that `--help` prints (sed over the header lines, as the ai-kb driver does). Port the validation block of `/Users/jason/dev/ai-kb/.claude/skills/upstream-review/scripts/upstream-review.sh` lines 30-53 with these changes: `STATE="$REPO_ROOT/.upstream-review/watermark.json"`; drop `ARCHIVED_GIT`; read `forkPointSha` into `FORKSHA` where ai-kb read `seedSha` into `SEED`; in the `jq` read use `map(. // "-")` and have `require` test `[ "$2" != "-" ]`, because a tab-IFS `read` collapses empty fields and would shift every later value; accept `upstreamUrl` matching `^(https://[A-Za-z0-9._/-]+|/[^[:space:]]+)$` so fixtures can use a local path; `GH_WEB="${URL%.git}/commit"`. Handle `-h|--help` before the watermark is read, so help works in any repo (the ai-kb driver validates first and would die with `missing`). Then validate, then dispatch `case "$cmd"` with the six modes as stubs that `die "not implemented"`, and `*) die "unknown option '$cmd' (see --help)"`.

- [ ] **Step 5: Run the tests to verify they pass, then shellcheck**

Run: `bats .claude/skills/upstream-review/tests/driver.bats && shellcheck .claude/skills/upstream-review/scripts/upstream-review.sh && git ls-files -s .claude/skills/upstream-review/scripts/upstream-review.sh`
Expected: `4 tests, 0 failures`, no shellcheck output, and the mode `100755` once the file is added (Step 6).

- [ ] **Step 6: Commit**

```bash
git add .upstream-review/watermark.json .claude/skills/upstream-review
git commit -m "feat(upstream-review): watermark state and driver skeleton"
```

---

### Task 3: Fixture repository and the listing modes

**Files:**
- Modify: `.claude/skills/upstream-review/tests/helpers.bash`
- Modify: `.claude/skills/upstream-review/scripts/upstream-review.sh`
- Test: `.claude/skills/upstream-review/tests/driver.bats`

**Interfaces:**
- Consumes: `write_watermark` from Task 2.
- Produces: helper `make_fixture` that sets `UP` (bare upstream path), `FORK` (our clone path, cwd after the call), and SHAs `C0 C1 C2 M11 C3 C4 M12 C5` as globals.
- Produces: driver function `ensure_upstream` and list output format (below).

Fixture, all content invented:

```
UP="$BATS_TEST_TMPDIR/up" (git init --bare -b staging; no .git suffix)   work="$BATS_TEST_TMPDIR/work"   FORK="$BATS_TEST_TMPDIR/fork"
c0  "base":        a.txt="one"  c.txt="see"  d.txt="dee"      <- fork point, on staging
branch feat/alpha: c1 "a.txt two": a.txt="one\ntwo"    c2 "add b.txt": b.txt="bee"
m11 = merge --no-ff into staging, -m "Merge pull request #11 from carverauto/feat/alpha" -m "add alpha"
branch fix/beta:   c3 "c.txt saw": c.txt="see\nsaw"    c4 "d.txt doo": d.txt="dee\ndoo"
m12 = merge --no-ff into staging, -m "Merge pull request #12 from carverauto/fix/beta" -m "fix beta"
c5  "a.txt three": direct commit on staging, a.txt="one\ntwo\nthree" and b.txt="bee\nboo"
fork = clone of UP reset to c0, then one commit "ours": c.txt="ours", git rm d.txt
watermark: upstreamUrl=$UP (path), forkPointSha=c0, lastReviewedSha=c0
```

The second `-m` on each merge is the PR title, where GitHub puts it (the real upstream merge for PR #5877 carries `feat(plugins): roll Wasm plugin owners ...` as its body).

Every file content ends with a newline (`printf 'one\ntwo\n'`). Without it, numstat reports a changed last line as `+2 -1` and every count below is off.

- [ ] **Step 1: Add `make_fixture` to `helpers.bash`**

Build the tree above with `git -c user.name=t -c user.email=t@example.com` on every commit, `git init -q --bare -b staging "$UP"` (without `-b` the clone warns about a missing remote HEAD), a work clone to create the commits, `git -C work push -q "$UP" staging`, then `git clone -q "$UP" "$FORK"`, `git -C "$FORK" reset -q --hard "$C0"`, the "ours" commit, `write_watermark "$FORK" "$UP" "$C0" "$C0"`, and `cd "$FORK"`. Set the default branch name explicitly (`git init -q -b staging`) so the fixture does not depend on `init.defaultBranch`.

- [ ] **Step 2: Write the failing listing tests**

Append to `driver.bats`:

```bash
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
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bats .claude/skills/upstream-review/tests/driver.bats`
Expected: the 5 new tests fail with `not implemented`.

- [ ] **Step 4: Implement `ensure_upstream` and the listing**

Port `ensure_upstream` from the ai-kb driver (lines 55-75) without the archived-git bootstrap; `g remote add --no-tags -- "$REMOTE" "$URL"`. The fetch refspec is `+refs/heads/$BRANCH:refs/remotes/$REMOTE/$BRANCH`. Listing: `g log --first-parent --reverse --date=short --pretty='%H%x09%h%x09%ad%x09%P%x09%s%x09%b' "$WATERMARK..$TIP"` (the `%b` field is the merge body; take its first non-empty line as the PR title and strip anything after the first newline). An entry is a PR when `%P` contains a space (two parents), whatever its subject. For a PR, print `* <short>  <date>  PR #<n> <branch>: <title>  [<k> commits]` where `n` and `branch` come from the regex `^Merge pull request #([0-9]+) from [^/]+/(.*)$` (held in a variable, see Global Constraints) and `k=$(g rev-list --count "$full^1..$full^2")`; a two-parent entry whose subject does not match prints `* <short>  <date>  merge <subject>  [<k> commits]`. A one-parent entry prints `* <short>  <date>  <subject>`. Header lines: `Upstream review: $REMOTE/$BRANCH`, `  fork point:          <short> <date>`, `  last reviewed:       <short> <date>`, `  upstream tip:        <full>`, `  entries to review:   <n>` (count of first-parent commits). Footer: the two "Next:" lines as in ai-kb, naming `--advance <tipsha>`. `--urls` adds `    $GH_WEB/<full>` under each entry; write it as an `if` so the loop body never ends on a failed `&&` (the footer test in this task catches the regression).

- [ ] **Step 5: Run the tests to verify they pass, then shellcheck**

Run: `bats .claude/skills/upstream-review/tests/driver.bats && shellcheck .claude/skills/upstream-review/scripts/upstream-review.sh`
Expected: `9 tests, 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add .claude/skills/upstream-review
git commit -m "feat(upstream-review): list unreviewed upstream PRs first-parent"
```

---

### Task 4: `--stat` with per-file markers

**Files:**
- Modify: `.claude/skills/upstream-review/scripts/upstream-review.sh`
- Test: `.claude/skills/upstream-review/tests/driver.bats`

**Interfaces:**
- Consumes: `make_fixture` globals.
- Produces: function `stat_commit <sha>` printing `      <marker> +<adds> -<dels>  <path>` per touched file, markers `=`, `<`, `~`, `x`, `+`, `bin`.

- [ ] **Step 1: Write the failing marker tests**

```bash
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
  git -C "$BATS_TEST_TMPDIR/work" -c user.name=t -c user.email=t@example.com mv a.txt e.txt
  git -C "$BATS_TEST_TMPDIR/work" -c user.name=t -c user.email=t@example.com commit -q -m "rename a to e"
  git -C "$BATS_TEST_TMPDIR/work" push -q "$UP" staging
  run "$DRIVER" --stat
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq '^ +[<] +\+0 +-3 +a\.txt$'   # ours still equals the fork point's a.txt
  echo "$output" | grep -Eq '^ +[+] +\+3 +-0 +e\.txt$'
}
```

Keep `work` (the fixture's upstream work clone) under `$BATS_TEST_TMPDIR/work` in `make_fixture` so the rename test can extend upstream.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats .claude/skills/upstream-review/tests/driver.bats`
Expected: 3 new failures.

- [ ] **Step 3: Implement `stat_commit` and wire `--stat`**

Port `stat_commit` from the ai-kb driver (lines 79-104) as is, with `$FORKSHA:<path>` in place of `$SEED:<path>` in the `cat-file` batch, and one added case: when the pre-image is non-zero, HEAD is missing and the fork point is also missing, the marker is `<` (an earlier window commit created the file), not `x`. The full rule: `bin` if numstat adds is `-`; pre-image all zeros: `+` if HEAD missing, `<` if HEAD equals the fork point, else `~`; HEAD missing: `<` if the fork point is missing too, else `x`; HEAD equals pre-image: `=`; HEAD equals fork point: `<`; else `~`. Under each two-parent entry print its commits oldest first as `    - <short>  <subject>` (`g log --reverse --pretty='%h%x09%s' "$full^1..$full^2"`) each followed by `stat_commit`; a one-parent entry gets `stat_commit` directly.

- [ ] **Step 4: Run the tests to verify they pass, then shellcheck**

Run: `bats .claude/skills/upstream-review/tests/driver.bats && shellcheck .claude/skills/upstream-review/scripts/upstream-review.sh`
Expected: `12 tests, 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add .claude/skills/upstream-review
git commit -m "feat(upstream-review): per-file divergence markers in --stat"
```

---

### Task 5: `--show` and `--diverged`

**Files:**
- Modify: `.claude/skills/upstream-review/scripts/upstream-review.sh`
- Test: `.claude/skills/upstream-review/tests/driver.bats`

- [ ] **Step 1: Write the failing tests**

```bash
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
}

@test "--diverged lists our footprint since the fork point" {
  make_fixture
  run "$DRIVER" --diverged
  [ "$status" -eq 0 ]
  [[ "$output" == *"c.txt"* ]]
  [[ "$output" == *"d.txt"* ]]
  [[ "$output" != *"a.txt"* ]]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats .claude/skills/upstream-review/tests/driver.bats`
Expected: 4 new failures.

- [ ] **Step 3: Implement**

`--show <sha>`: call `ensure_upstream` first (a listed SHA may not be local yet), resolve with `rev-parse -q --verify "$2^{commit}"`; if it has two parents, print `g log --reverse --pretty='%h  %s' "$sha^1..$sha^2"` then `g diff "$sha^1" "$sha"`; otherwise `g show "$sha"`. `--diverged`: `g diff --stat=120 "$FORKSHA" HEAD` under the heading `Files where our HEAD differs from fork point <short>:`.

- [ ] **Step 4: Run the tests to verify they pass, then shellcheck**

Run: `bats .claude/skills/upstream-review/tests/driver.bats && shellcheck .claude/skills/upstream-review/scripts/upstream-review.sh`
Expected: `16 tests, 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add .claude/skills/upstream-review
git commit -m "feat(upstream-review): --show a PR or commit and --diverged footprint"
```

---

### Task 6: `--advance` and history-rewrite guard

**Files:**
- Modify: `.claude/skills/upstream-review/scripts/upstream-review.sh`
- Test: `.claude/skills/upstream-review/tests/driver.bats`

- [ ] **Step 1: Write the failing tests**

```bash
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats .claude/skills/upstream-review/tests/driver.bats`
Expected: 4 of the 5 new tests fail; the rewritten-history test already passes because `ensure_upstream`, ported whole in Task 3, carries the ancestor guard.

- [ ] **Step 3: Implement `--advance`**

Port the ai-kb `--advance` block (lines 117-130) and add, before writing, in this order: `g merge-base --is-ancestor "$NEWSHA" "$TIP" || die "$2 is not on $REMOTE/$BRANCH"`; `g rev-list --first-parent "$TIP" | grep -qx "$NEWSHA" || die "$2 is not on the first-parent chain of $REMOTE/$BRANCH"`; `g merge-base --is-ancestor "$WATERMARK" "$NEWSHA" || die "$2 is behind the current watermark"`. Keep the `jq` rewrite through a temp file.

- [ ] **Step 4: Run the tests to verify they pass, then shellcheck**

Run: `bats .claude/skills/upstream-review/tests/driver.bats && shellcheck .claude/skills/upstream-review/scripts/upstream-review.sh`
Expected: `21 tests, 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add .claude/skills/upstream-review
git commit -m "feat(upstream-review): advance the watermark with ancestry guards"
```

---

### Task 7: `SKILL.md` and references

**Files:**
- Create: `.claude/skills/upstream-review/SKILL.md`
- Create: `.claude/skills/upstream-review/references/deviations.md`
- Create: `.claude/skills/upstream-review/references/decision-log-template.md`
- Create: `.claude/skills/upstream-review/references/validation.md`
- Test: `.claude/skills/upstream-review/tests/skill.bats`

**Interfaces:**
- Consumes: the driver modes and output format from Tasks 3-6.

- [ ] **Step 1: Write the failing skill-shape tests**

`tests/skill.bats`:

```bash
load helpers
SKILL="$(dirname "$DRIVER")/../SKILL.md"

@test "frontmatter name matches the directory" {
  [ "$(sed -n 's/^name: //p' "$SKILL")" = "upstream-review" ]
}

@test "description is third person, under 1024 chars, and names the trigger phrases" {
  d="$(sed -n 's/^description: //p' "$SKILL")"
  [ "${#d}" -le 1024 ]
  [[ "$d" == *"what changed upstream"* ]]
  [[ "$d" == *"sync from upstream"* ]]
  [[ "$d" == Reviews* ]]
}

@test "allowed-tools lets the driver run without a prompt" {
  grep -qF 'Bash(${CLAUDE_SKILL_DIR}/scripts/upstream-review.sh *)' "$SKILL"
}

@test "body stays under 2000 words" {
  [ "$(awk 'f{print} /^---$/{c++; if(c==2) f=1}' "$SKILL" | wc -w)" -le 2000 ]
}

@test "every bundled file is wired from SKILL.md and no file is ASCII-unclean" {
  for f in references/deviations.md references/decision-log-template.md references/validation.md scripts/upstream-review.sh; do
    grep -q "$f" "$SKILL"
  done
  ! LC_ALL=C grep -rn '[^ -~'"$(printf '\t')"']' "$(dirname "$SKILL")" --include='*.md'
}
```

`/usr/bin/grep` is BSD grep and has no `-P`; the bracket class under `LC_ALL=C` matches any byte outside printable ASCII and tab.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats .claude/skills/upstream-review/tests/skill.bats`
Expected: 5 failures (no SKILL.md).

- [ ] **Step 3: Write `SKILL.md`**

Frontmatter:

```yaml
---
name: upstream-review
description: Reviews what changed upstream in carverauto/serviceradar (staging) since the last review and decides which pull requests to adopt into this fork. Use for "sync from upstream", "what changed upstream", "review upstream PRs", "did carverauto update", "bring upstream PR N in", "check upstream for new features", or any periodic upstream check. Encodes the fork facts, the watermark driver, the per-file divergence markers and the adoption rules for this repo.
argument-hint: "[--stat | --urls | --show <sha> | --diverged | --advance <sha>]"
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/upstream-review.sh *) Bash(git show *) Bash(git log *) Bash(git diff *) Bash(git rev-parse *) Read Grep Glob
---
```

Only reads are pre-approved, as in ai-kb. `git cherry-pick`, `git switch`, `git commit` and `git push` change history and prompt.

Body sections, imperative voice, in this order, each a few lines: the fork facts (shared history; fork point SHA; remote `carverauto`, never `upstream`; run `gh repo set-default jrmatherly/serviceradar` once); Tooling table (driver path, watermark, reviews dir) and the six driver invocations; Markers table (`=`, `<`, `~`, `x`, `+`, `bin`) with the adoption path per marker (`<` means pick the older entry first); Method (the seven steps from the spec, with the subagent fan-out rule for windows over about 20 PRs); Rules for this repo (`-x` on every pick, rewrite `#NNNN` to `carverauto/serviceradar#NNNN`, `.github/` is ours and upstream workflow changes are hand-ported, keep upstream subjects including the `no-mistakes(scope):` prefix, "Version, changelog and dependency-only PRs: no rule yet; see `references/deviations.md`", "Rebrand step: when `scripts/rebrand/apply.sh` exists, run it on every picked file; until then this step is a no-op and `references/deviations.md` says so"); Red flags (merge of `carverauto/staging`; picking a `~` file unread; state outside `.upstream-review/`; advancing to a SHA other than the listed tip; a batch that lands with any area's validation failing); Resources list wiring the three references and the driver, one line each.

- [ ] **Step 4: Write the references**

`references/deviations.md`: a table `Upstream | Ours | Status | Notes` with three rows: `.github/ workflows | our own CI | planned (session "Replace upstream CI workflows") | hand-port validation commands`; `carverauto names, module path, image registry | rebrand | planned | mapper to be adapted from ai-kb scripts/rebrand/; until it exists the rebrand step is a no-op`; `upstream VERSION, CHANGELOG and dependency bumps | undecided | open | ai-kb skips version bumps and takes dependency versions, never hunks; the owner decides for this fork`. Below it the heading `Deleted or moved paths` with the sentence "Add a line here for every path we remove, with where the content went or why it is gone." and no rows.

`references/decision-log-template.md`: the ai-kb template with `Window: <from>..<full tip sha> on carverauto/staging, N PRs (M direct commits)` and a Verdicts table with columns `# | PR | Area | Our state | Markers | Verdict | Evidence`, and an `Adopted` section listing cherry-picked SHAs in order with the validation result per area.

`references/validation.md`: per area, the commands the batch must pass, taken from `AGENTS.md` and the Makefile: Elixir `make lint-elixir` for every project, plus `mix precommit` inside `elixir/web-ng` and `elixir/palisade`, the only two `mix.exs` that define that alias (`grep -l precommit elixir/*/mix.exs`); Go `gofmt -l <files>`, `make lint-go`, `make tidy`; Rust `cargo fmt --check`, `./scripts/lint-rust.sh`; proto `make proto-lint proto-breaking verify-proto-elixir`; helm: the command `helm-lint.yml` runs (there is no Makefile target). Do not list `make check`; say in one line why it cannot run on the fork (Global Constraints). Verify each target exists with `grep -n '^<target>:' Makefile` while writing and name only the ones that do.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats .claude/skills/upstream-review/tests/`
Expected: `26 tests, 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add .claude/skills/upstream-review
git commit -m "feat(upstream-review): skill body, deviations, log template and validation references"
```

---

### Task 8: Runbook pointer and real-upstream verification

**Files:**
- Modify: `docs/agent-runbooks.md` (append a section)
- Create: `.serena/memories/upstream.md` (local only, not committed; `.serena/` stays untracked)

- [ ] **Step 1: Append to `docs/agent-runbooks.md`**

Section `## Upstream review (carverauto/serviceradar)`: four lines: the skill path, the one-time `gh repo set-default jrmatherly/serviceradar`, the state files, and "Run `/upstream-review` or the driver directly; the skill body has the method." ASCII only.

- [ ] **Step 2: Write the Serena memory**

`.serena/memories/upstream.md`: the fork facts from the spec's first section condensed to ten lines, the remote name rule, the state file paths, and a pointer to the skill. Do not `git add` it.

- [ ] **Step 3: Run the driver against the real upstream**

Run: `.claude/skills/upstream-review/scripts/upstream-review.sh --stat | head -60`
Expected: header shows fork point `5993ec1043`, `entries to review:` at least 9, first entry `PR #5877 feat/wasm-plugin-rollout-trigger: feat(plugins): roll Wasm plugin owners tracking latest approved to newly approved packages  [5 commits]`, markers `=`, `+` or `<` everywhere except `.gitignore` and `docs/agent-runbooks.md`, which this branch changed and may show `~`. Inside PR #5877, `addon_rollout_coordinator.ex` is touched by two commits, so its second line is `<`. `git remote get-url carverauto` prints the https URL; `git tag | wc -l` is unchanged from before the run.

- [ ] **Step 4: Dry-run an adoption in a scratch worktree**

Run:

```bash
S=$(mktemp -d)
M=$(git log --first-parent --format=%H --reverse HEAD..carverauto/staging | head -1)
git worktree add -q --detach "$S/adopt" HEAD
for c in $(git log --reverse --format=%H "$M^1..$M^2"); do git -C "$S/adopt" -c commit.gpgsign=false cherry-pick -x "$c" || break; done
git -C "$S/adopt" log --format='%s%n%b' -5 | grep -c 'cherry picked from commit'
git worktree remove --force "$S/adopt"
```

Expected: the final count equals the PR's commit count (5 for #5877), no conflict.

- [ ] **Step 4b: Run the driver once under `/bin/bash` 3.2**

Run: `/bin/bash .claude/skills/upstream-review/scripts/upstream-review.sh --stat | head -20; echo "exit=${PIPESTATUS[0]}"`
Expected: the same header as Step 3 and `exit=0`. A syntax error here means a bash 4+ feature slipped in.

- [ ] **Step 5: Confirm `--advance` refuses a bogus SHA against the real remote**

Run: `.claude/skills/upstream-review/scripts/upstream-review.sh --advance 0000000000000000000000000000000000000000; echo "exit=$?"`
Expected: `ERROR: not a commit`, `exit=1`, watermark unchanged (`jq -r .lastReviewedSha .upstream-review/watermark.json` is still `5993ec10432ccbddaeffb5fe3416ba7d261bede7`).

- [ ] **Step 6: Trigger test**

In a fresh Claude Code turn ask "what changed upstream since we forked?" and confirm the skill is invoked (the reply runs the driver). If it does not trigger, tighten the description's phrases and rerun `tests/skill.bats`.

- [ ] **Step 7: Commit**

```bash
git add docs/agent-runbooks.md
git commit -m "docs(runbooks): point at the upstream review skill"
```

---

### Task 9: Review and open the PR

- [ ] **Step 1: Full test and lint run**

Run: `bats .claude/skills/upstream-review/tests/ && shellcheck .claude/skills/upstream-review/scripts/upstream-review.sh .claude/skills/upstream-review/tests/helpers.bash && git status --short`
Expected: `26 tests, 0 failures`; shellcheck silent; status shows only the pre-existing `docker-compose.arm64.yml` (untracked), `README.md` (modified, same docker task) and `.serena/`.

- [ ] **Step 2: `/simplify` then `/code-review` on `origin/staging..HEAD`**

Apply what they find as one follow-up commit, `refactor(upstream-review): apply review findings`, and rerun Step 1.

- [ ] **Step 3: Push with an explicit refspec and open the PR**

Only after the owner says to push:

```bash
git push origin feat/upstream-review-skill:refs/heads/feat/upstream-review-skill
gh pr create --repo jrmatherly/serviceradar --base staging --title "feat(upstream-review): skill and driver for reviewing carverauto PRs" --body-file <body>
```

The body names the spec and plan paths, the four owner decisions, and the dedup experiment result. Do not merge.
