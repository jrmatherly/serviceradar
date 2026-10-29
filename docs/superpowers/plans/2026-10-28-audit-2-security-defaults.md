# Security defaults implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the fork's default deployment (a plain `docker compose up`) and its dependency intake safe without an operator reading the source first.

**Architecture:** Every task is one pull request against `staging` with its own failing check. Defaults move in `docker-compose.yml` and `elixir/web-ng/config`, intake moves in `.github/dependabot.yml` and the GitHub repository settings, and each flip ships with the test or command that proves the old default is gone.

**Tech Stack:** Docker Compose, Phoenix 1.8 (web-ng) behind Caddy, Bun 1.3.9 and pnpm 10 lockfiles, Dependabot, gitleaks.

**Spec:** Tier 2 of the project audit of 2026-10-28, `private/findings/2026-10-28-project-audit.md` (a gitignored note). Sibling plans: `2026-10-28-audit-1-ci-reds-and-release.md`, `2026-10-28-audit-3-captured-data.md`, `2026-10-28-audit-4-docs-and-hygiene.md`.

## Global constraints

- Never push to `staging`. Push with `git push origin <local>:refs/heads/<branch>` (`AGENTS.md`).
- A change under `.github/` runs `scripts/ci/check-fork-ci.sh` before commit (`AGENTS.md`).
- No fixture or example carries a value from a live system; passwords in examples are generated or `change-me` (`CLAUDE.md`).
- web-ng tests need the local database. Prefix every `mix test` in `elixir/web-ng` with the env block from `elixir/web-ng/AGENTS.md` "Running Tests with Docker Compose Database", including `SERVICERADAR_REQUIRE_DB_TESTS=1`; without it `test/test_helper.exs:129-130` prints `Skipping web-ng tests` and exits 0, so a run that prints that line counts as a failure. `ConnCase` starts a sandbox owner (`test/support/data_case.ex:68`), so no controller test can be `:db_free`.
- Every web-ng test file carries one lane tag (`elixir/web-ng/AGENTS.md:742-750`). A `:web_ng_shared_fixture_db` file is also listed in exactly one `NETWORKS_LIVE_DB_SHARD_SRCS` entry in `elixir/web-ng/BUILD.bazel` and in `SHARED_FIXTURE_SOURCES` in `build/contracts/web_ng_db_runner_contract_test.py`; otherwise `LaneCoverageGuard` fails and CI never runs it.
- A PR that adds or changes a test records `test-audit: not available` in its body (`AGENTS.md`).
- Bun stays at 1.3.9 (`mise.toml:11`); a newer bun rewrites `bun.lock` to a version 1.3.9 cannot read. `pnpm-lock.yaml` is the Bazel release input (`MODULE.bazel:853-870`); change it with pnpm 10 and `pnpm install --lockfile-only`, never by hand (`MODULE.bazel:856-860`). `bun.lock` is what dev setup and `web-ng-lint.yml` install from.
- Each PR ends with `/simplify`, then `/code-review` on its diff, before commit.

## Review focus

- A compose user who reaches web-ng through a VM address after the origin check flips; Task 2's default is an explicit origin derived from `SERVICERADAR_HOST`, and its live check is the gate.
- A developer who relied on `/dev/dashboard` in compose and now gets 404; the quickstart names the opt-in (Task 1).
- A CSP flip that blocks the god view's Wasm or blob workers; Task 3 keeps report-only as the default until the browser pass is recorded.
- A bun override that drifts from the pnpm override again; Task 4's check runs in the workflow that installs from bun.
- A Dependabot PR that edits `package.json` without `bun.lock` and breaks the frozen install in `web-ng-lint.yml`; Task 5 uses the `bun` ecosystem where only `bun.lock` exists.

## Dependency graph

Tasks 1, 2, 3 and 7 all edit `docker-compose.yml`; land them in that order and rebase each onto the previous. Tasks 4, 5 and 6 are independent and branch from `staging`. Task 3 and Task 8 wait for the owner's decision recorded in their first step.

---

### Task 1: Turn dev routes off by default in compose

**Files:**
- Modify: `docker-compose.yml:1252`
- Modify: `DOCKER_QUICKSTART.md` (the "What happens with one command" list)
- Create: `elixir/web-ng/test/phoenix/controllers/dev_routes_test.exs`
- Modify: `elixir/web-ng/BUILD.bazel` (add the file to one `NETWORKS_LIVE_DB_SHARD_SRCS` list; siblings at lines 695-696), `build/contracts/web_ng_db_runner_contract_test.py` (`SHARED_FIXTURE_SOURCES`; siblings at lines 120-121)

**Interfaces:**
- Consumes: `SERVICERADAR_DEV_ROUTES` parsing in `elixir/web-ng/config/runtime.exs:1636-1642` (inside the `config_env() == :prod` block opened at `:1520`; unset means false) and `ensure_dev_routes_enabled/2` in `router.ex:1496-1504`.
- Produces: nothing new. The env default changes from `true` to `false`.

- [ ] **Step 1: Write the test for the gate**

```elixir
defmodule ServiceRadarWebNGWeb.DevRoutesTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  @moduletag :web_ng_shared_fixture_db

  setup do
    previous = Application.get_env(:serviceradar_web_ng, :dev_routes)
    on_exit(fn -> Application.put_env(:serviceradar_web_ng, :dev_routes, previous) end)
    :ok
  end

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

- [ ] **Step 2: Run it with the database env**

Run: `cd elixir/web-ng && <env block> mix test test/phoenix/controllers/dev_routes_test.exs`
Expected: 2 tests, 0 failures, and no `Skipping web-ng tests` line (the gate already exists; the test pins it so a later router edit cannot drop it). Then `bazel test --config=remote //elixir/web-ng:networks_live_db_test_<n>` for the shard you added it to, and `bazel test --config=remote //build/contracts:web_ng_db_runner_contract_test` (pytest is not installed here; the Bazel target runs the contract).
Expected: PASS, PASS.

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
git add docker-compose.yml DOCKER_QUICKSTART.md elixir/web-ng/test/phoenix/controllers/dev_routes_test.exs elixir/web-ng/BUILD.bazel build/contracts/web_ng_db_runner_contract_test.py
git commit -m "fix(compose): default dev routes off"
```

---

### Task 2: Give compose an explicit websocket origin

**Files:**
- Modify: `docker-compose.yml:1251`
- Modify: `DOCKER_QUICKSTART.md` (new section "Reaching the stack by another hostname"; there is no `SERVICERADAR_HOST` note today)
- Check, not necessarily modify: `helm/serviceradar/values.yaml:1477` (`checkOrigin: "true"`)

**Interfaces:**
- Consumes: `PHX_CHECK_ORIGIN` parsing in `runtime.exs:1674-1681` (`"true"` and unset mean `:conn`, `"false"` disables, any other value is a comma list).
- Produces: compose default `${PHX_CHECK_ORIGIN:-https://${SERVICERADAR_HOST:-localhost}}`. Not `true`: `:conn` compares host, scheme and port (`deps/phoenix/lib/phoenix/socket/transport.ex:624-627`), Caddy terminates TLS and proxies plain HTTP to `web-ng:4000` (`docker/compose/Caddyfile:11,14,23`), so the browser's `https://localhost` origin (port 443) would not equal the connection's `http` scheme and port, and the endpoint has no forwarded-header handling. That inference is from source, not observed; Step 3 observes it.

- [ ] **Step 1: Record the baseline on the running stack**

Run: `docker compose exec web-ng sh -c 'echo $PHX_CHECK_ORIGIN'`
Expected: `false`.

- [ ] **Step 2: Change the default**

In `docker-compose.yml:1251` set the value above. Compose nested defaults `${A:-${B:-c}}` are supported by Compose v2; confirm with `docker compose config | grep PHX_CHECK_ORIGIN`, expected `https://localhost`.

- [ ] **Step 3: Verify the websocket connects through Caddy, and that `true` would not**

Recreate web-ng. In the built-in browser open `https://localhost/users/log-in`; the console shows no origin rejection and the LiveView socket reaches `connected`. Repeat with the Mac's LAN address and `SERVICERADAR_HOST` set to it. Then set `PHX_CHECK_ORIGIN=true`, recreate, and record whether the socket is rejected (the inference above).
Expected: both explicit-origin pages connect; the `true` run is recorded either way and, if it connects, the plan's reasoning is corrected in the PR body.

- [ ] **Step 4: Check Helm**

Helm renders `checkOrigin: "true"` (`templates/web.yaml:398-399`) behind its own gateway. If Step 3 shows `true` fails behind a TLS-terminating proxy, open a follow-up for the chart; do not change it here.

- [ ] **Step 5: Document the override**

New quickstart section: when the stack is reached through more than one hostname, set `PHX_CHECK_ORIGIN` to a comma-separated list of origins; `false` disables the check and is not a production setting.

- [ ] **Step 6: Commit**

```bash
git add docker-compose.yml DOCKER_QUICKSTART.md
git commit -m "fix(compose): check the websocket origin against the configured host"
```

---

### Task 3: Make the CSP mode a runtime setting and flip it after a browser pass

**Files:**
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/plugs/security_headers.ex` (add `csp_mode_from_env/1`)
- Modify: `elixir/web-ng/config/runtime.exs` (call it next to `SigningSecret.validate!` at `:1632`)
- Modify: `elixir/web-ng/config/config.exs:218-227` (comment names the env var)
- Modify: `docker-compose.yml` (web-ng env block), `helm/serviceradar/values.yaml` and `templates/web.yaml` (new `webNg.cspMode`)
- Create: `elixir/web-ng/test/phoenix/plugs/security_headers_env_test.exs` (`:db_free`), `helm/serviceradar/tests/web_ng_csp_mode_env_test.yaml` (modeled on `local_mailer_env_test.yaml`)

**Interfaces:**
- Consumes: `apply_csp_mode/2` in `plugs/security_headers.ex:103-122`, which already handles `:enforce` and `:report_only` and reads `Application.get_env` at call time (`:56-57`), so `Application.put_env` already drives it and the existing `security_headers_test.exs` passes in either mode.
- Produces: `SecurityHeaders.csp_mode_from_env(String.t() | nil) :: :enforce | :report_only`, raising `ArgumentError` on any other value (a silent fallback would swallow a typo such as `enforced`); env var `SERVICERADAR_CSP_MODE` with values `enforce` and `report-only`; Helm value `webNg.cspMode`, a string enum, default `report-only`.

- [ ] **Step 1: Owner decision**

Record which default ships: `report-only` (today) or `enforce`. Until recorded, Steps 2 to 6 ship with `report-only` and the flip is Step 7.

- [ ] **Step 2: Write the failing unit test**

`security_headers_env_test.exs`, tagged `:db_free`: `csp_mode_from_env("enforce") == :enforce`, `csp_mode_from_env("report-only") == :report_only`, `csp_mode_from_env(nil) == :report_only`, and `assert_raise ArgumentError, fn -> csp_mode_from_env("enforced") end`.
Run: `cd elixir/web-ng && mix test test/phoenix/plugs/security_headers_env_test.exs`
Expected: FAIL, undefined function.

- [ ] **Step 3: Implement and wire**

Add the function; in `runtime.exs` set `config :serviceradar_web_ng, ServiceRadarWebNGWeb.Plugs.SecurityHeaders, csp_mode: SecurityHeaders.csp_mode_from_env(System.get_env("SERVICERADAR_CSP_MODE"))`. Compose: `SERVICERADAR_CSP_MODE=${SERVICERADAR_CSP_MODE:-report-only}`. Helm: `webNg.cspMode` rendered into the env block.
Run: the Step 2 command, then `bazel test --config=remote //elixir/web-ng:unit_tests` and `bazel test --config=remote //helm/serviceradar:helm_unittest_suite_test` (the `helm unittest` plugin is not installed locally; the Bazel target runs it).
Expected: PASS, PASS, PASS.

- [ ] **Step 4: Prove the header name follows the mode end to end**

Add two cases to `test/phoenix/controllers/security_headers_test.exs` using `Application.put_env` on the plug's config with `on_exit` restore: `:enforce` yields `content-security-policy` and no report-only header; `:report_only` the reverse.
Run: `cd elixir/web-ng && <env block> mix test test/phoenix/controllers/security_headers_test.exs`
Expected: 0 failures, no `Skipping` line.

- [ ] **Step 5: Browser pass before the flip (only after the owner picks enforce)**

With `SERVICERADAR_CSP_MODE=enforce` on the Mac stack, drive the login page, the dashboard, the devices list, the god view (Wasm and blob workers), maps, and SwaggerUI in the built-in browser. Record every `Refused to` console line.
Expected: none. Any hit returns to the browser policy at `router.ex:29-42` or the SwaggerUI policy at `router.ex:44-57` before the default changes.

- [ ] **Step 6: Commit**

```bash
git add elixir/web-ng/lib/serviceradar_web_ng_web/plugs/security_headers.ex elixir/web-ng/config elixir/web-ng/test docker-compose.yml helm/serviceradar
git commit -m "feat(web-ng): set the CSP mode from SERVICERADAR_CSP_MODE"
```

---

### Task 4: Reconcile the two JavaScript override blocks and clear the critical tar advisory

**Files:**
- Modify: `elixir/web-ng/assets/package.json:73-90` (`pnpm.overrides`) and `:109-` (`overrides`)
- Modify: `elixir/web-ng/assets/bun.lock` and `elixir/web-ng/assets/pnpm-lock.yaml` (both regenerated by their tools)
- Create: `scripts/check-web-ng-overrides.sh`
- Modify: `.github/workflows/web-ng-lint.yml` (call the check before `bun install`; add `elixir/web-ng/assets/package.json` to its path filter)

**Interfaces:**
- Produces: `scripts/check-web-ng-overrides.sh`, exit 1 when `jq -S .pnpm.overrides` and `jq -S .overrides` of `package.json` differ, exit 0 otherwise.

- [ ] **Step 1: Write the check and watch it fail**

Run: `scripts/check-web-ng-overrides.sh`
Expected: exit 1 listing the 13 differing keys: `vite`, `@loaders.gl/compression>fflate`, `exceljs>uuid`, `texture-compressor`, `brace-expansion`, `lodash`, `lodash-es`, `postcss`, `protocol-buffers-schema`, `react`, `react-dom`, `react-is`, `hoist-non-react-statics>react-is`.

- [ ] **Step 2: Merge the blocks**

Both blocks become the union of today's entries plus `"tar": "^7.5.22"` (`bun.lock:1375` pins 7.5.11, GHSA-23hp-3jrh-7fpw; pnpm already resolves 7.5.22). `vite` goes to `8.2.4` in both, which moves the bun dev path from the `7.3.3` it resolves today to a new major; that is a deliberate step and the PR body says so.

- [ ] **Step 3: Regenerate both lockfiles and prove the bun path still works on vite 8**

Run: `cd elixir/web-ng/assets && npx pnpm@10 install --lockfile-only && mise x bun@1.3.9 -- bun install && mise x bun@1.3.9 -- bun install --frozen-lockfile && bun run lint && bun run test && bun run build`
Expected: all exit 0; the `overrides:` block at `pnpm-lock.yaml:7-24` now matches `package.json`.
Run: `bun audit` and `pnpm audit --audit-level high`.
Expected: 0 critical and no `tar` entry from bun; still 1 high (zod, kept by decision) from pnpm.
Run: `bazel build --config=remote //elixir/web-ng/assets:node_modules`.
Expected: exit 0.

- [ ] **Step 4: Wire the check and run the fork CI check**

Run: `scripts/check-web-ng-overrides.sh && scripts/ci/check-fork-ci.sh`
Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
git add elixir/web-ng/assets/package.json elixir/web-ng/assets/bun.lock elixir/web-ng/assets/pnpm-lock.yaml scripts/check-web-ng-overrides.sh .github/workflows/web-ng-lint.yml
git commit -m "fix(web-ng): keep the bun and pnpm overrides identical and bump tar"
```

---

### Task 5: Extend Dependabot to every manifest and turn on security updates

**Files:**
- Modify: `.github/dependabot.yml`
- Owner, in GitHub settings: enable Dependabot security updates (`gh api repos/jrmatherly/serviceradar/automated-security-fixes` reports `enabled: false`); decide on code scanning default setup (`gh api .../code-scanning/default-setup` reports `not-configured`; its language list has no Elixir).

**Interfaces:**
- Produces: entries for `mix` (7 directories under `elixir/`; version updates only, GitHub runs no security updates for Hex, which `elixir-dependency-audit.yml` covers), `bun` for `/elixir/web-ng/assets/component` (only `bun.lock` there; `package-ecosystem: bun` needs bun 1.1.39 or newer), `npm` for `/docs`, `/js/cli`, `/js/create-dashboard` and `/demo/dashboard-kit`, `gomod` for the 10 plugin directories under `/go/cmd/wasm-plugins/*` plus `/go/tools/wasm-plugin-harness` (11), each weekly with a group for minor and patch updates. `/elixir/web-ng/assets` has both `bun.lock` and `pnpm-lock.yaml`; the owner picks `bun` or `npm` for it, knowing a PR that moves one lock without the other breaks either the frozen bun install or the Bazel build, and Task 4's check does not compare resolved versions.

- [ ] **Step 1: List the manifests**

Run: `git ls-files 'mix.exs' '*/mix.exs' '*/package.json' '*/go.mod' | grep -v -e third_party -e templates -e '^demo/' -e testdata`
Expected: 7 Mix, 6 npm (5 plus `demo/dashboard-kit`, which the filter removes; add it back by hand) and 11 Go directories. Skip `docker`: images are Bazel-built from `docker/images/base_image_origins.txt`, so there is no `FROM` to bump.

- [ ] **Step 2: Add the entries**

One block per directory, `schedule.interval: weekly`, `open-pull-requests-limit: 5`, and a `groups` block batching `minor` and `patch` the way the `github-actions` entry does.

- [ ] **Step 3: Validate every directory has its manifest**

Run: `yq '.updates[] | .directory + " " + ."package-ecosystem"' .github/dependabot.yml | while read -r d eco; do case $eco in mix) f=mix.exs;; npm|bun) f=package.json;; gomod) f=go.mod;; cargo) f=Cargo.toml;; github-actions) f=.github;; esac; [ -e ".$d/$f" ] || echo "missing $f in $d"; done` and `scripts/ci/check-fork-ci.sh`.
Expected: no `missing` line; exit 0. After merge, check the repository's Insights, Dependency graph, Dependabot tab for a parse error, then `gh pr list --author app/dependabot` within a week.

- [ ] **Step 4: Owner flips the settings**

Settings, Code security: enable Dependabot security updates (covers npm, gomod and cargo; not mix, and not bun, which gets version updates only). Record the code-scanning decision.

- [ ] **Step 5: Commit**

```bash
git add .github/dependabot.yml
git commit -m "chore(deps): cover mix, bun, npm and plugin go modules in dependabot"
```

---

### Task 6: Make the weekly history secret scan pass with a triaged baseline

**Files:**
- Modify: `.gitleaksignore` (24 fingerprints today, each with a `#` rationale comment; append a dated block, never sort the file)
- Create: `scripts/gitleaks-triage.jq` (the filter that separates test, testdata, fixture and vendored paths from the rest)

- [ ] **Step 1: Reproduce the failing run**

Run: `gitleaks git --no-banner --redact --report-format json --report-path /tmp/gl.json . ; jq length /tmp/gl.json`
Expected: 163.

- [ ] **Step 2: Triage every finding outside test and vendored paths**

Run: `jq -r -f scripts/gitleaks-triage.jq /tmp/gl.json` where the filter prints `File RuleID Fingerprint` for every finding whose path is not under `test/`, `testdata/`, `fixtures/`, `third_party/` or `contrib/snmp/mibs/`.
Expected: about 113 lines, including `k8s/demo/base/secrets.yaml`, `k8s/demo/base/spire/pg-secret.yaml`, `packaging/core/config/api.docker.env`, `packaging/proton/config/users.yaml`, `docker/compose/api.docker.env`, `helm/serviceradar/values.yaml`, `docker-compose.yml`, `scripts/sign-oci-publish.sh`, `rust/otel/src/tls.rs`, `pkg/discovery/utils.go`, `docs/docs/api-credentials.md`. For each, the owner states whether the value was ever live. A live value is rotated at its source before anything else and its fingerprint is not added.

- [ ] **Step 3: Baseline the rest**

Append to `.gitleaksignore` a block headed `# 2026-10 history baseline: test fixtures and vendored checksums, triaged <date>` followed by the fingerprints from the test and vendored set, plus the non-test fingerprints the owner marked dead, each with its one-line reason.

- [ ] **Step 4: Prove the weekly scope passes and a planted secret still fails**

Run: the Step 1 command. Expected: 0 findings. Then in a scratch commit add a file whose content matches the `generic-api-key` rule with a value that is not on gitleaks' allowlists (confirm first with `gitleaks detect --no-git` on the single file that it trips), run `gitleaks git --log-opts HEAD~1..HEAD .`, expected exit 1, then drop the scratch commit.

- [ ] **Step 5: Commit**

```bash
git add .gitleaksignore scripts/gitleaks-triage.jq
git commit -m "chore(security): baseline the history secret scan"
```

---

### Task 7: Generate the cold-tier credentials and pin its images

**Files:**
- Modify: `docker-compose.yml:1136-1186` (`minio`, `minio-init`), `:1191-` (`cold-head`), and the core-elx service (mount the new volume)
- Modify: `docker/compose/coldtier.env.example:29-41`
- Create: `docker/compose/bootstrap-coldtier-credentials.sh` (copy the shape of `docker/compose/bootstrap-db-credentials.sh`, including its "do not generate when the data volume already exists" check that reads the data directory)

**Interfaces:**
- Consumes: `secret_env/1` in `elixir/serviceradar_core/lib/serviceradar/cold_tier/config.ex:232-237`, which already honors a `_FILE` suffix for `SERVICERADAR_COLD_TIER_S3_ACCESS_KEY_ID`, `..._S3_SECRET_ACCESS_KEY` and `..._HEAD_PASSWORD`.
- Produces: volume `coldtier-credentials` with `minio-root-user`, `minio-root-password`, `head-password`, written once by an `alpine:3.20` init service that skips generation when `coldtier-minio-data` or `coldtier-head-data` already holds data (an existing head volume was initialized with the old literal, and `POSTGRES_PASSWORD` applies only at initdb). `minio` reads `MINIO_ROOT_PASSWORD_FILE` if the pinned image honors it (verify in Step 1), else a `sh -c` wrapper; `cold-head` reads `POSTGRES_PASSWORD_FILE`; core-elx mounts the volume read-only and the example env switches to the `_FILE` variables.

- [ ] **Step 1: Confirm the image state and the file-variable support**

Run: `docker pull minio/minio:<candidate tag>` after reading the tag's date on Docker Hub (community images may have stopped in late 2025; if the newest tag is older than the current `latest` digest, record that), then `docker run --rm --entrypoint sh minio/minio:<tag> -c 'echo ok'` and `docker run --rm -e MINIO_ROOT_USER=u -e MINIO_ROOT_PASSWORD_FILE=/tmp/p -v $(mktemp -d):/tmp minio/minio:<tag> server /data` with a password file present.
Expected: `ok`; MinIO starts with the file variable or logs that it is unknown. Record which.

- [ ] **Step 2: Write the bootstrap script**

Same `generate_password`, `write_if_missing` and `umask 077` as the CNPG script; explicit `SR_COLDTIER_*` env values win; when either data volume is non-empty and no env value is set, write the previous literal defaults so existing installs keep working, and log that a rotation is needed.

- [ ] **Step 3: Rewire the services and the example env**

Replace the literal defaults at `:1143`, `:1170-1171` and the head password line with file reads; mount `coldtier-credentials:ro` into core-elx; pin `minio/minio` and `minio/mc` tags; switch `coldtier.env.example:29-41` to `SERVICERADAR_COLD_TIER_S3_ACCESS_KEY_ID_FILE`, `..._S3_SECRET_ACCESS_KEY_FILE` and `..._HEAD_PASSWORD_FILE` paths under `/etc/serviceradar/coldtier/`.

- [ ] **Step 4: Verify on a fresh volume and on an existing one**

Run: `docker compose --profile coldtier up -d` on fresh volumes, then `docker compose exec minio sh -c 'mc ready local'`, a core-elx log line showing the cold tier connected, and `grep -n '<old literal>' docker-compose.yml docker/compose/coldtier.env.example`. Then repeat on the Mac's existing cold-tier volumes.
Expected: ready and connected on both; the grep prints nothing.

- [ ] **Step 5: Commit**

```bash
git add docker-compose.yml docker/compose/bootstrap-coldtier-credentials.sh docker/compose/coldtier.env.example
git commit -m "fix(compose): generate cold-tier credentials and pin the minio images"
```

---

### Task 8: Owner decision, then bind the SAML login to a browser nonce

**Files:**
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/saml_controller.ex` (`request/2`, `consume/2`, the moduledoc section "The ACS does not use the browser session" at lines 21-55, `reject/2` at 210-217)
- Modify: `elixir/web-ng/test/phoenix/controllers/saml_controller_test.exs` (helpers `open_pending_request/1` at 272-281 and `cross_site_post`; the no-cookie assertion at `:69`; the SSO-URL fixture)

**Interfaces:**
- Consumes: `SAMLPendingRequest` in `elixir/serviceradar_core/lib/serviceradar/identity/saml_pending_request.ex`, which stores only `relay_state_hash`, `request_id`, `return_to`, `expires_at` (`:108-125`); `take/1` deletes the row atomically on a hash match; the `:saml_acs` pipeline fetches the session and cookies (`router.ex:92-98`).
- Produces: no schema change. `request/2` sets cookie `sr_saml_nonce` (`SameSite=None; Secure; HttpOnly`, max age equal to the pending TTL) and opens the pending row with `relay_state <> "." <> nonce` as the keyed value. `consume/2` reads the cookie and calls `take(params["RelayState"] <> "." <> nonce)`; a missing or wrong cookie yields `:unknown_relay_state` and goes through the existing `reject/2`, which redirects to `/users/log-in` with the invalid-request flash (there is no 403 path today). The cookie is cleared at the ACS. The SAML HTTP-POST binding is a cross-site POST from the identity provider, which is why `SameSite=None` is required and a Phoenix CSRF token cannot be used.

- [ ] **Step 1: Owner decision**

The owner states whether the login CSRF residual (an attacker signs a victim's browser into the attacker's account by relaying one SAML response within the TTL) is accepted or fixed, and whether two concurrent login tabs must both succeed (a single cookie name is overwritten by the second tab; keying the cookie name by a RelayState prefix avoids that). If accepted, record it in the moduledoc and close.

- [ ] **Step 2: Update the test helpers and write the failing case**

`open_pending_request/1` returns the nonce it keyed; `cross_site_post` takes an optional cookie. Rewrite the existing no-cookie test at `:69` as the rejection case: post a valid assertion without the cookie, `assert redirected_to(conn) == ~p"/users/log-in"`, the invalid-request flash, and no `live_socket_id` (the shape `assert_failed` already uses). For the one test that goes through `GET /auth/saml`, use an SSO host the outbound policy allows (the fixture's `https://127.0.0.1/sso` is rejected, test at `:48-57`).
Run: `cd elixir/web-ng && <env block> mix test test/phoenix/controllers/saml_controller_test.exs`
Expected: the rejection case FAILS today (the ACS accepts the response); no `Skipping` line.

- [ ] **Step 3: Implement**

Keyed RelayState as described; cookie set in `request/2`, read and cleared in `consume/2`; moduledoc updated.
Run: the Step 2 command.
Expected: 0 failures.

- [ ] **Step 4: Live login**

Log in through a test identity provider on the Mac stack with the built-in browser; in the network panel the ACS request carries `sr_saml_nonce` and the login lands on the dashboard.
Expected: as stated.

- [ ] **Step 5: Commit** as `fix(web-ng): bind the SAML login to a browser nonce`.

## Appendix A. Alternatives rejected

- Removing the `/dev` scope from the compose image entirely. The scope is gated already; a default flip keeps the developer path with one env var.
- `PHX_CHECK_ORIGIN=true` in compose to match Helm. `:conn` compares scheme and port, which a TLS-terminating proxy changes; an explicit origin is the honest default and Helm gets its own check.
- Flipping CSP to enforce in the same PR as the runtime switch. The god view's workers are the likely casualty and nobody has a report-only log from a real run.
- A new column on the pending SAML request for the nonce. Folding the nonce into the keyed RelayState needs no migration and keeps the atomic take.
- One lockfile for web-ng. The Bazel rules consume pnpm and the tooling consumes bun; the check in Task 4 stops the drift instead.

## Appendix B. Risks

- Task 2's inference about `:conn` behind Caddy comes from the Phoenix and Bandit source, not a run; Step 3 records the real behavior and the PR body corrects the plan if it differs.
- Task 4 moves the bun dev path to vite 8; the lint, test and build run in Step 3 is the guard.
- Task 6 can hide a live secret behind a fingerprint if Step 2 is skipped. Do not run Step 3 before Step 2 is recorded.
- Task 7 changes credentials on a volume that may already hold data; the existing-volume branch in the bootstrap script is what keeps current installs working.
