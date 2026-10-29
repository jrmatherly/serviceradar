# Security defaults implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the fork's default deployment (a plain `docker compose up`) and its dependency intake safe without an operator reading the source first.

**Architecture:** Every task is one pull request against `staging` with its own failing check. Defaults move in `docker-compose.yml` and `elixir/web-ng/config`, intake moves in `.github/dependabot.yml` and the GitHub repository settings, and each flip ships with the test or command that proves the old default is gone.

**Tech Stack:** Docker Compose, Phoenix 1.8 (web-ng), Bun 1.3.9 and pnpm lockfiles, Dependabot, gitleaks.

**Spec:** Tier 2 of the project audit of 2026-10-28, `private/findings/2026-10-28-project-audit.md` (a gitignored note; the auditors' pasted evidence is session-local). Sibling plans from the same audit: `2026-10-28-audit-1-ci-reds-and-release.md`, `2026-10-28-audit-3-captured-data.md`, `2026-10-28-audit-4-docs-and-hygiene.md`.

## Global constraints

- Never push to `staging`. Push with an explicit refspec `git push origin <local>:refs/heads/<branch>` (`AGENTS.md`).
- A change under `.github/` runs `scripts/ci/check-fork-ci.sh` before commit (`AGENTS.md`).
- No fixture or example carries a value from a live system; passwords in examples are generated or `change-me` (`CLAUDE.md`).
- Bun stays at 1.3.9 (`mise.toml:11`); a newer bun rewrites `bun.lock` to a version 1.3.9 cannot read.
- `pnpm-lock.yaml` is the source of truth for the Bazel release build (`MODULE.bazel:853-870`); `bun.lock` is what dev setup and `web-ng-lint.yml` install from.
- Each PR ends with `/simplify`, then `/code-review` on its diff, before commit.

## Review focus

- A compose user who reaches web-ng through a VM address rather than `localhost` after the origin check flips; the websocket must still connect (Task 2 adds the live check).
- A developer who relied on `/dev/dashboard` in compose and now gets 404; the quickstart must name the opt-in (Task 1).
- A CSP flip that blocks the god view's Wasm or blob workers; Task 3 keeps report-only as the default until the browser pass is recorded.
- A bun override that drifts from the pnpm override again; Task 4 adds the check that compares the two blocks.
- A Dependabot entry for a directory with no manifest, which fails the config silently; Task 5 validates each directory before commit.

## Dependency graph

Tasks 1, 2, 4, 5, 6 and 7 are independent and branch from `staging`. Task 3 and Task 8 depend on nothing in code but wait for the owner's decision recorded in their first step. Keep file boundaries: Task 1 and Task 2 both edit `docker-compose.yml` lines 1251 and 1252; land Task 1 first and rebase Task 2 onto it.

---

### Task 1: Turn dev routes off by default in compose

**Files:**
- Modify: `docker-compose.yml:1252`
- Modify: `DOCKER_QUICKSTART.md` (the "What happens with one command" list)
- Test: `elixir/web-ng/test/phoenix/controllers/dev_routes_test.exs` (create)

**Interfaces:**
- Consumes: `SERVICERADAR_DEV_ROUTES` parsing in `elixir/web-ng/config/runtime.exs:1636-1642` (unset means false) and `ensure_dev_routes_enabled/2` in `router.ex:1496-1504`.
- Produces: nothing new. The env default changes from `true` to `false`.

- [ ] **Step 1: Write the failing test for the gate**

```elixir
defmodule ServiceRadarWebNGWeb.DevRoutesTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  test "dev routes answer 404 when disabled", %{conn: conn} do
    Application.put_env(:serviceradar_web_ng, :dev_routes, false)
    assert conn |> get("/dev/dashboard") |> response(404)
  end

  test "dev routes mount when enabled", %{conn: conn} do
    Application.put_env(:serviceradar_web_ng, :dev_routes, true)
    assert get(conn, "/dev/dashboard").status in [200, 302]
  end
end
```

Restore the previous value in `on_exit`.

- [ ] **Step 2: Run the test to confirm the enabled case passes and the disabled case fails only if the plug is missing**

Run: `cd elixir/web-ng && mix test test/phoenix/controllers/dev_routes_test.exs`
Expected: both PASS (the gate already exists; the test pins it so Task 3 and later router edits cannot drop it). If the disabled case fails, stop and read `router.ex:243-245`.

- [ ] **Step 3: Change the compose default**

In `docker-compose.yml:1252` change `${SERVICERADAR_DEV_ROUTES:-true}` to `${SERVICERADAR_DEV_ROUTES:-false}`.

- [ ] **Step 4: Document the opt-in**

Add one line to `DOCKER_QUICKSTART.md` under the one-command section: `SERVICERADAR_DEV_ROUTES=true docker compose up` enables `/dev/dashboard`, `/dev/mailbox` and `/dev/ash`, and these pages have no login.

- [ ] **Step 5: Verify on the matching surface**

Run: `docker compose config | grep -n SERVICERADAR_DEV_ROUTES`
Expected: `SERVICERADAR_DEV_ROUTES=false`.
Run on the running Mac stack after `docker compose up -d --force-recreate web-ng`: `curl -sk -o /dev/null -w '%{http_code}\n' https://localhost/dev/dashboard`
Expected: `404`. Then with `SERVICERADAR_DEV_ROUTES=true` exported and the service recreated, expected `200` or `302`.

- [ ] **Step 6: Commit**

```bash
git add docker-compose.yml DOCKER_QUICKSTART.md elixir/web-ng/test/phoenix/controllers/dev_routes_test.exs
git commit -m "fix(compose): default dev routes off"
```

---

### Task 2: Match the compose origin check to Helm

**Files:**
- Modify: `docker-compose.yml:1251`
- Modify: `DOCKER_QUICKSTART.md` (the `SERVICERADAR_HOST` note)

**Interfaces:**
- Consumes: `PHX_CHECK_ORIGIN` parsing in `runtime.exs:1674-1681` (`"true"` and unset mean `:conn`, `"false"` disables, any other value is a comma list).
- Produces: compose default `true`, the same as `helm/serviceradar/values.yaml:1477`.

- [ ] **Step 1: Record the baseline on the running stack**

Run: `docker compose exec web-ng sh -c 'echo $PHX_CHECK_ORIGIN'`
Expected: `false`.

- [ ] **Step 2: Change the default**

In `docker-compose.yml:1251` change `${PHX_CHECK_ORIGIN:-false}` to `${PHX_CHECK_ORIGIN:-true}`.

- [ ] **Step 3: Verify the websocket still connects through Caddy**

Recreate web-ng. In the built-in browser open `https://localhost/users/log-in`, then check the console: no `Origin` rejection and the LiveView socket reaches `connected`. Repeat with the Mac's LAN address in place of `localhost` (Caddy forwards `Host`, so `:conn` accepts it; this is the claim to prove, not assume).
Expected: both pages render with a live socket. If the LAN address fails, the quickstart line in Step 4 must say to set `PHX_CHECK_ORIGIN` to the origin list.

- [ ] **Step 4: Document the override**

Add to `DOCKER_QUICKSTART.md` next to `SERVICERADAR_HOST`: when the stack is reached through more than one hostname, set `PHX_CHECK_ORIGIN` to a comma-separated list of origins.

- [ ] **Step 5: Commit**

```bash
git add docker-compose.yml DOCKER_QUICKSTART.md
git commit -m "fix(compose): enable the websocket origin check by default"
```

---

### Task 3: Make the CSP mode a runtime setting and flip it after a browser pass

**Files:**
- Modify: `elixir/web-ng/config/runtime.exs` (new env read next to the dev-routes block at 1636)
- Modify: `elixir/web-ng/config/config.exs:218-227`
- Modify: `docker-compose.yml` (web-ng env block), `helm/serviceradar/values.yaml` and `templates/web.yaml` (new `cspMode` value)
- Test: `elixir/web-ng/test/phoenix/controllers/security_headers_test.exs`

**Interfaces:**
- Consumes: `apply_csp_mode/2` in `plugs/security_headers.ex:103-122`, which already handles `:enforce` and `:report_only`.
- Produces: env var `SERVICERADAR_CSP_MODE` with values `enforce` and `report-only`; config key `csp_mode` set from it at runtime.

- [ ] **Step 1: Owner decision**

Record here which default ships: `report-only` (today) or `enforce`. Until recorded, Steps 2 to 6 ship with `report-only` as the default and the flip is Step 7.

- [ ] **Step 2: Write the failing test on the header name**

Add two cases to `security_headers_test.exs`: with `csp_mode: :enforce` the response has `content-security-policy` and no `content-security-policy-report-only`; with `:report_only` the reverse. Set the config with `Application.put_env(:serviceradar_web_ng, ServiceRadarWebNGWeb.Plugs.SecurityHeaders, csp_mode: ...)` and restore in `on_exit`.

- [ ] **Step 3: Run the test**

Run: `cd elixir/web-ng && mix test test/phoenix/controllers/security_headers_test.exs`
Expected: the enforce case FAILS today (the header is report-only).

- [ ] **Step 4: Read the env in runtime.exs**

Add `csp_mode = case System.get_env("SERVICERADAR_CSP_MODE") do "enforce" -> :enforce; _ -> :report_only end` and `config :serviceradar_web_ng, ServiceRadarWebNGWeb.Plugs.SecurityHeaders, csp_mode: csp_mode`. Leave `config.exs:225-227` as the compile-time default and update its comment to name the env var.

- [ ] **Step 5: Wire compose and Helm**

Compose: `SERVICERADAR_CSP_MODE=${SERVICERADAR_CSP_MODE:-report-only}`. Helm: `webNg.cspMode: "report-only"` rendered into the env block in `templates/web.yaml`; add the case to the chart's bool-default tests the way `checkOrigin` is covered at `helm/serviceradar/tests/bool_default_true_test.yaml:146-206`.

- [ ] **Step 6: Run the tests and the chart lint**

Run: `cd elixir/web-ng && mix test test/phoenix/controllers/security_headers_test.exs` then `helm lint helm/serviceradar` and `helm unittest helm/serviceradar`.
Expected: PASS, PASS.

- [ ] **Step 7: Browser pass before the flip (only after the owner picks enforce)**

With `SERVICERADAR_CSP_MODE=enforce` on the Mac stack, drive the login page, the dashboard, the devices list, the god view (Wasm and blob workers), maps, and SwaggerUI in the built-in browser. Record every `Refused to` console line. Expected: none. Any hit returns to the policy in `router.ex:29-58` before the default changes.

- [ ] **Step 8: Commit**

```bash
git add elixir/web-ng/config elixir/web-ng/test/phoenix/controllers/security_headers_test.exs docker-compose.yml helm/serviceradar
git commit -m "feat(web-ng): set the CSP mode from SERVICERADAR_CSP_MODE"
```

---

### Task 4: Reconcile the two JavaScript override blocks and clear the critical tar advisory

**Files:**
- Modify: `elixir/web-ng/assets/package.json:73-90` (`pnpm.overrides`) and `:109-` (`overrides`)
- Modify: `elixir/web-ng/assets/bun.lock` (regenerated), `elixir/web-ng/assets/pnpm-lock.yaml` (hand-edited per the fork's note; pnpm 12 drops the overrides block)
- Create: `scripts/check-web-ng-overrides.sh`
- Modify: `scripts/ci/check-fork-ci.sh` (call the new check) or `Makefile` target `lint`

**Interfaces:**
- Produces: `scripts/check-web-ng-overrides.sh`, exit 1 when `pnpm.overrides` and `overrides` in `package.json` differ in keys or values, exit 0 otherwise. Uses `jq`.

- [ ] **Step 1: Write the check and watch it fail**

The script reads `package.json` with `jq -S '.pnpm.overrides'` and `jq -S '.overrides'` and diffs them.
Run: `scripts/check-web-ng-overrides.sh`
Expected: exit 1 listing `vite`, `fflate`, `uuid`, `texture-compressor`, `brace-expansion`, `lodash`, `lodash-es`, `postcss`, `protocol-buffers-schema`.

- [ ] **Step 2: Merge the blocks**

Make both blocks the union of today's entries, with `vite` at `8.2.4` (the pnpm value; the Bazel build is the release path) and add `"tar": "^7.5.22"` to both (the pnpm lockfile already resolves 7.5.22; `bun.lock:1375` pins 7.5.11, which carries GHSA-23hp-3jrh-7fpw).

- [ ] **Step 3: Regenerate the bun lockfile and validate both**

Run: `cd elixir/web-ng/assets && mise x bun@1.3.9 -- bun install` then `mise x bun@1.3.9 -- bun install --frozen-lockfile` and `bun audit`.
Expected: frozen install exit 0; audit reports 0 critical and no `tar` entry.
Run: `pnpm audit --audit-level high` and `bazel build --config=remote //elixir/web-ng/assets:node_modules` (needs `.bazelrc.remote`).
Expected: still 1 high (zod, kept by decision); Bazel exit 0.

- [ ] **Step 4: Run the check and the lint**

Run: `scripts/check-web-ng-overrides.sh && make lint`
Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
git add elixir/web-ng/assets/package.json elixir/web-ng/assets/bun.lock elixir/web-ng/assets/pnpm-lock.yaml scripts/check-web-ng-overrides.sh scripts/ci/check-fork-ci.sh
git commit -m "fix(web-ng): keep the bun and pnpm overrides identical and bump tar"
```

---

### Task 5: Extend Dependabot to every manifest and turn on security updates

**Files:**
- Modify: `.github/dependabot.yml`
- Owner, in GitHub settings: enable Dependabot security updates (`gh api repos/jrmatherly/serviceradar/automated-security-fixes` reports `enabled: false` today); decide on code scanning default setup (`not-configured` today; Elixir is not among its languages).

**Interfaces:**
- Produces: entries for `mix` (7 directories under `elixir/`), `npm` (`/elixir/web-ng/assets`, `/elixir/web-ng/assets/component`, `/docs`, `/js/cli`, `/js/create-dashboard`), `gomod` for the 10 plugin directories under `/go/cmd/wasm-plugins/*` plus `/go/tools/wasm-plugin-harness`, each weekly with a group for minor and patch updates.

- [ ] **Step 1: List the manifests and confirm each directory**

Run: `git ls-files 'mix.exs' '*/mix.exs' '*/package.json' '*/go.mod' | grep -v third_party | grep -v templates`
Expected: the 7 Mix, 5 npm and 12 Go directories named above. Skip `docker` entries: images are Bazel-built from `docker/images/base_image_origins.txt`, so there is no Dockerfile `FROM` to bump.

- [ ] **Step 2: Add the entries**

One block per directory, `schedule.interval: weekly`, `open-pull-requests-limit: 5`, and a `groups` block that batches `minor` and `patch` the way the `github-actions` entry does. Mark the npm entries for the bun lockfile directories with a comment that Dependabot updates `package.json` and `bun.lock` together only when both are present.

- [ ] **Step 3: Validate**

Run: `scripts/ci/check-fork-ci.sh` and `gh api repos/jrmatherly/serviceradar/dependabot/secrets >/dev/null` (proves the token can read Dependabot); then after merge, `gh api 'repos/jrmatherly/serviceradar/dependabot/alerts?state=open' --jq length` and `gh pr list --author app/dependabot`.
Expected: the check exits 0; within a week Dependabot opens its first PR (today it has opened none).

- [ ] **Step 4: Owner flips the settings**

Settings, Code security: enable Dependabot security updates. Record the decision on code scanning (CodeQL covers Go, Rust, JavaScript and Actions here, not Elixir).

- [ ] **Step 5: Commit**

```bash
git add .github/dependabot.yml
git commit -m "chore(deps): cover mix, npm and plugin go modules in dependabot"
```

---

### Task 6: Make the weekly history secret scan pass with a triaged baseline

**Files:**
- Modify: `.gitleaksignore` (81 fingerprints today)
- Possibly modify: `.github/workflows/secret-scan.yml:48-85` (scheduled scope)

- [ ] **Step 1: Reproduce the failing run**

Run: `gitleaks git --no-banner --redact --report-format json --report-path /tmp/gl.json .` then `jq length /tmp/gl.json` and `jq -r '.[].File' /tmp/gl.json | sort | uniq -c | sort -rn | head -20`.
Expected: 163 findings; the top non-test files are `k8s/demo/base/secrets.yaml` (9) and `packaging/core/config/api.docker.env` (4).

- [ ] **Step 2: Owner triage of the two non-test files**

For each finding in those two files, the owner states whether the value was ever live. A live value is rotated at its source before anything else; a dead or placeholder value gets a fingerprint.

- [ ] **Step 3: Add fingerprints for the rest**

Run: `jq -r '.[].Fingerprint' /tmp/gl.json | sort -u >> .gitleaksignore` after removing any live-value entries, then `sort -u -o .gitleaksignore .gitleaksignore`.

- [ ] **Step 4: Prove the weekly scope passes and the PR scope still fails on a planted secret**

Run: the Step 1 command again. Expected: 0 findings. Then in a scratch commit add a file with a fake AWS key pattern, run `gitleaks git --log-opts HEAD~1..HEAD .`, expected exit 1, then drop the scratch commit.

- [ ] **Step 5: Commit**

```bash
git add .gitleaksignore
git commit -m "chore(security): baseline the history secret scan"
```

---

### Task 7: Generate the cold-tier MinIO credentials and pin its images

**Files:**
- Modify: `docker-compose.yml:1136-1186` (`minio`, `minio-init`), `:1191-` (`cold-head`)
- Modify: `docker/compose/coldtier.env.example:29-41`
- Create: `docker/compose/bootstrap-coldtier-credentials.sh` (copy the shape of `docker/compose/bootstrap-db-credentials.sh`)

**Interfaces:**
- Produces: volume `coldtier-credentials` holding `minio-root-user`, `minio-root-password`, `head-password`, written once by an `alpine:3.20` init service; `minio` and `minio-init` read them through `sh -c 'MINIO_ROOT_PASSWORD=$(cat ...) exec ...'` because `MINIO_ROOT_PASSWORD_FILE` support is unverified.

- [ ] **Step 1: Confirm the MinIO image has a shell**

Run: `docker run --rm --entrypoint sh minio/minio:<pinned tag> -c 'echo ok'`
Expected: `ok`. Pick the pinned tag from `docker pull minio/minio` today and record it; if `sh` is absent, use `MINIO_ROOT_PASSWORD_FILE` and verify it with the same image.

- [ ] **Step 2: Write the bootstrap script**

Same `generate_password`, `write_if_missing` and `umask 077` as the CNPG script; explicit `SR_COLDTIER_*` env values still win.

- [ ] **Step 3: Rewire the services and the example env**

Replace the literal defaults at `:1143`, `:1170-1171` and the head password line with reads from the volume; pin `minio/minio` and `minio/mc` tags; update `coldtier.env.example:29-41` to say the values come from the volume unless set.

- [ ] **Step 4: Verify**

Run: `docker compose --profile coldtier up -d minio minio-init cold-head` then `docker compose exec minio sh -c 'mc ready local'` and `grep -n '<old literal>' docker-compose.yml docker/compose/coldtier.env.example`.
Expected: ready; grep prints nothing.

- [ ] **Step 5: Commit**

```bash
git add docker-compose.yml docker/compose/bootstrap-coldtier-credentials.sh docker/compose/coldtier.env.example
git commit -m "fix(compose): generate cold-tier credentials and pin the minio images"
```

### Task 8: Owner decision, then bind the SAML login to a browser nonce

**Files:**
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/saml_controller.ex` (the `GET /auth/saml` start action and the ACS action; the residual is described in its moduledoc at lines 49-54)
- Test: `elixir/web-ng/test/phoenix/controllers/saml_controller_test.exs` (extend)

**Interfaces:**
- Consumes: the one-use RelayState with its 600 s TTL that the controller already keeps.
- Produces: a cookie `sr_saml_nonce` set at login start with `SameSite=None; Secure; HttpOnly`, its value stored beside the pending RelayState, and required to match at the ACS; a response posted without it is rejected with 403.

- [ ] **Step 1: Owner decision**

The owner states whether the login CSRF residual (an attacker signs a victim's browser into the attacker's account by relaying one SAML response within the TTL) is accepted or fixed. If accepted, record it in the moduledoc and close.

- [ ] **Step 2: Write the failing test**

A test that starts a login (captures the cookie), then posts a valid assertion to the ACS from a connection without the cookie; assert 403 and no session. A second test with the cookie asserts the login succeeds as today.
Run: `cd elixir/web-ng && mix test test/phoenix/controllers/saml_controller_test.exs`
Expected: the first FAILS today (the ACS accepts the response).

- [ ] **Step 3: Implement the nonce**

Set the cookie in the start action, store the nonce with the pending request, compare at the ACS. The SAML HTTP-POST binding is a cross-site POST from the identity provider, which is why `SameSite=None` is required and a Phoenix CSRF token cannot be used.

- [ ] **Step 4: Run the tests and a live login**

Run: the Step 2 command, then a login against a test identity provider on the Mac stack with the browser; check the cookie is present on the ACS request in the network panel.
Expected: PASS; login succeeds; the ACS request carries the cookie.

- [ ] **Step 5: Commit** as `fix(web-ng): bind the SAML login to a browser nonce`.

## Appendix A. Alternatives rejected

- Removing the `/dev` scope from the compose image entirely. The scope is gated already; a default flip keeps the developer path with one env var.
- Flipping CSP to enforce in the same PR as the runtime switch. The god view's workers are the likely casualty and nobody has a report-only log from a real run, so the flip waits for the browser pass.
- One lockfile for web-ng. The Bazel rules consume pnpm and the tooling consumes bun; converging them is a build change out of scope here. The check in Task 4 stops the drift instead.

## Appendix B. Risks

- Task 2 can break a compose user who reaches web-ng through a hostname Caddy does not forward unchanged. The live check in its Step 3 is the guard.
- Task 4 regenerates `bun.lock`; a bun newer than 1.3.9 on the path rewrites the lockfile version. Use `mise x bun@1.3.9`.
- Task 6 can hide a live secret behind a fingerprint if Step 2 is skipped. Do not run Step 3 before Step 2 is recorded.
