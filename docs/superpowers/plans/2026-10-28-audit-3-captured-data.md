# Captured-data regeneration implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the remaining fixtures and examples that look captured from a live system, by regenerating each from nothing so the shape no longer identifies anyone.

**Architecture:** One pull request per data family. Every task replaces inline literals in tests, docs and shipped source with values from the reserved ranges, keeps each test's assertion meaningful, and ends with an anchored `git grep` that returns nothing. The retired tokens themselves never enter a tracked file: the plan, the commit messages, the branch names and the committed check describe them by class, and the literal patterns live in a gitignored note.

**Tech Stack:** Go (a plugin module with its own `go.mod`), Elixir ExUnit (DB-free files in serviceradar_core; DB-backed in web-ng), Rust `cargo test`, Vitest, OpenSpec, Bazel.

**Spec:** Tier 3 of `private/findings/2026-10-28-project-audit.md` (gitignored). The retired tokens and the literal grep patterns for them live in `private/findings/captured-patterns.txt` (gitignored; Task 0 creates it). This plan refers to values by role and file:line only.

## Global constraints

- `CLAUDE.md`: fixtures are invented, never exported. Regenerate every field of a record; never swap a single token, because the shape is the tell. Reserved replacements are `host01.example.com`, `SITE01-...`, `192.0.2.0/24`, `198.51.100.0/24`, invented serials and builds, `555-01xx`. For public addresses use `203.0.113.0/24` (RFC 5737 TEST-NET-3; not in the CLAUDE.md table, same intent). For MACs use the RFC 7042 documentation range `00:00:5E:00:53:xx`; a locally administered MAC (`02:...`) is rejected by `column_mac_groups_from_rows/1` in `elixir/serviceradar_core/lib/serviceradar/inventory/identity/duplicate_sweep.ex:597-598`, so it must not be used where that code is under test.
- Do not name the affected party, the retired tokens, or the naming scheme in any commit message, branch name, PR title or tracked file. Describe by class. The same rule applies to this plan.
- The captured-data rule has no historical exemption; the Forgejo-link rule in `AGENTS.md:96` is a different rule. `CHANGELOG`, `openspec/changes/archive/` and `docs/learnings/adlr/` are left alone only after Task 0 has mapped them and the owner has accepted the copies there.
- One pathspec for every grep in this plan, written `$EXCL`: `-I -- ':!openspec/changes/archive' ':!CHANGELOG*' ':!docs/learnings/adlr' ':!third_party'`. `-I` skips the vendored crate archives that otherwise match any short token.
- The opentext-nom plugin has its own module. Run its tests from `go/cmd/wasm-plugins/opentext-nom` with `go test ./...`, not from the repo root.
- `cargo test` takes one filter before `--`; pass several names after `--` and assert the count of tests run, since a mistyped filter passes with zero tests.
- web-ng tests need the local database; prefix every `mix test` there with the env block from `elixir/web-ng/AGENTS.md` ("Running Tests with Docker Compose Database") including `SERVICERADAR_REQUIRE_DB_TESTS=1`, or the helper prints `Skipping web-ng tests` and exits 0.
- Bazel with `--config=remote` needs `.bazelrc.remote` copied from the main checkout into any worktree.
- Each PR ends with `/simplify`, then `/code-review` on its diff, before commit. A PR that adds or changes a test records `test-audit: not available` in its body (`AGENTS.md`).

## Review focus

- A regenerated MAC without a hex letter leaves the uppercase assertion in `TestCollectorLooksUpAttachedSwitchPortByEndpointMAC` unexercised (Task 3 pins a letter).
- A regenerated serial pair that is not two distinct comma-joined values breaks the split assertion in `TestNormalizeDeviceRowAcceptsHPNAIntegerFlags` (Task 1).
- A syslog peer value that is not a valid IP makes the parser return nil and the Elixir test fail for the wrong reason (Task 2).
- A device id used at only some of its ten sites in `config_retrieve_test.go` (Task 1 lists them all).
- An instance rename that misses the `textproto` filename or the Bazel label, which breaks `//config/...` builds (Task 5).

## Dependency graph

Task 0 first; it produces the private pattern file every later gate reads. Then Task 1, then Task 3 (both touch `collector_test.go` and `device_discovery_ingestor_test.exs`), then Task 2 (its family also appears in Task 3's files, so its gate passes only after Task 3). Tasks 4, 5, 6 each start after the owner's decision in their first step; Task 4 touches `duplicate_sweep_test.exs` after Task 3. Task 7 is last and carries the committed check.

---

### Task 0: Map the spread of each family before touching anything

**Files:**
- Create: `private/findings/captured-patterns.txt` (gitignored; one anchored `-P` pattern per line, with a `#` comment naming the class)
- Modify: `private/findings/2026-10-28-project-audit.md` (a "Spread" section)

- [ ] **Step 1: Write the pattern file**

From the audit note, one pattern per family: the device id and serial prefix, the firmware string, the memory figure, the site code, the ROM build (Task 1); the address family (Task 2); the two old OUIs with and without separators (Task 3); the slug, case-insensitive, and the hostname-scheme template (Task 4); the instance token (Task 5); the first coordinate of the GPS pair (Task 6).

- [ ] **Step 2: Record where each pattern already is**

For each pattern run `git grep -n -i -P -f <(grep -v '^#' private/findings/captured-patterns.txt) $EXCL` and, separately, the same without the exclusions, so the archive, `CHANGELOG` and adlr copies are listed. For the introducing commit of each family (`git log -S<token> --oneline | tail -1`) run `git tag --contains <sha>` (no local tags today) and `gh api repos/jrmatherly/serviceradar/pulls --jq '.[].head.sha'` is not enough: note that a merged PR's head ref stays fetchable on GitHub and only the host can purge it (`AGENTS.md`). Note that `docs/docs/syslog.md` ships on the docs site if `docs-pages.yml` publishes.

- [ ] **Step 3: Owner decision on the historical copies**

Record per family: accepted as historical, or included in the sweep. The slug has 4 `CHANGELOG` lines and 2 archive files; the decision covers them.

---

### Task 1: Regenerate the network-automation device record

**Files:**
- Modify: `go/cmd/wasm-plugins/opentext-nom/collector_test.go:30-67,86-166,192`
- Modify: `go/cmd/wasm-plugins/opentext-nom/config_retrieve_test.go:27,28,29,54,58,69,113,124,181,186` (ten sites of the device id)
- Modify: `elixir/serviceradar_core/test/serviceradar/inventory/device_discovery_ingestor_test.exs:76-130,140,172`
- Modify: `elixir/serviceradar_core/test/serviceradar/inventory/sync/enrichment_hw_info_test.exs:9-27`
- Modify: `elixir/serviceradar_core/test/serviceradar/inventory/sync/device_records_managed_test.exs:16,24`
- Decide in Step 2 whether the source instance name moves; if yes also `go/cmd/wasm-plugins/opentext-nom/config_test.go:39,54,74,128,226,255,264-266` (`validTestConfig()`) and `testdata/config-{invalid-command,invalid-context,valid-default,valid-multiple-queries,valid-nnm-origin}.json:2`

**Interfaces:**
- Consumes: nothing shared. The record is inline in each file and mirrored by hand.
- Produces: one invented record used identically everywhere. Every shape field is re-picked, not only the flagged ones: an integer device id of a different width; `SITE01-MDF01-SW01` as hostname; an address in `192.0.2.0/24`; two distinct invented serials joined by a comma; an invented firmware string of the vendor's shape used for both `softwareVersion` and `firmwareVersion`; an invented ROM build; a round memory count; re-picked total and free port counts; a re-picked processor string; a location of the form `SITE01_MDF1` padded with spaces; a contact with trailing spaces. Vendor and model are public product names and stay.

- [ ] **Step 1: Run the five test targets to record the green baseline**

Run: `cd go/cmd/wasm-plugins/opentext-nom && go test ./...` and `cd elixir/serviceradar_core && MIX_ENV=test mix test test/serviceradar/inventory/device_discovery_ingestor_test.exs test/serviceradar/inventory/sync/enrichment_hw_info_test.exs test/serviceradar/inventory/sync/device_records_managed_test.exs`
Expected: PASS, PASS (the first compile of serviceradar_core takes minutes).

- [ ] **Step 2: Decide the instance name**

The source instance name (`InstanceID`, `source_instance`, inside `integration_id`) is a product-category word plus `-prod`. The owner says whether it is captured. If yes, it changes at all 16 sites listed in Files, including the shared `validTestConfig()` helper that `collector_test.go:192` asserts through. If no, record that and leave it.

- [ ] **Step 3: Write the Go record and re-run**

Keep what each test asserts: `managementStatus` 0 and 1 mapping, stringified integer id, `serialNumber` split into first serial and two chassis serials, `excludeFromPoll` false, `os.version` equal to the firmware string, `memory_bytes` equal to the input (hard-coded three times in `TestInventoryDeviceMapsOCSFFieldsFromHPNARow`), trimmed owner and location, the marshalled payload containing `"serial":"<first>"` and `"memory_bytes":<n>` and not the joined serial. In `config_retrieve_test.go` use the same id at all ten sites and in the `deviceid` request parameter.
Run: `cd go/cmd/wasm-plugins/opentext-nom && go test ./...`
Expected: PASS.

- [ ] **Step 4: Mirror the record in the three Elixir files and re-run**

The ingestor test asserts `is_managed`, `os.name`, `os.version`, `hw_info.serial_number`, two `chassis_serials`, `memory_bytes`, `owner.name`, `tags.inventory_source`, `metadata.os_name`, `metadata.geographical_location`, and at `:172` the instance name. `enrichment_hw_info_test.exs` needs two serials, the firmware string, the processor string and an integer memory value; `device_records_managed_test.exs` needs only the firmware string.
Run: the Elixir command from Step 1.
Expected: PASS.

- [ ] **Step 5: Prove the old shape is gone**

Run: `git grep -n -i -P -f <(grep -v '^#' private/findings/captured-patterns.txt | sed -n '1,6p') $EXCL` (the Task 1 patterns).
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add go/cmd/wasm-plugins/opentext-nom elixir/serviceradar_core/test/serviceradar/inventory
git commit -m "test(inventory): regenerate the network-automation device fixture"
```

---

### Task 2: Replace the syslog transport peer address family

**Files:**
- Modify: `docs/docs/syslog.md:85`
- Modify: `rust/flowgger/src/flowgger/decoder/auto_decoder.rs:192,198`
- Modify: `rust/srql/src/query/logs/filters.rs:453,460`, `rust/srql/src/query/logs/stats.rs:292`
- Modify: `elixir/serviceradar_core/test/serviceradar/event_writer/processors/logs_test.exs:351,358,359,396,403,404`
- Modify: `openspec/changes/improve-syslog-ingestion-fidelity/specs/observability-signals/spec.md:103,105`

**Interfaces:**
- Produces: one address in `192.0.2.0/24` at every site above. The Elixir and spec sites keep the `default:<ip>` partition-prefix shape, which is the behavior under test.

- [ ] **Step 1: Replace and run each test**

Run: `cargo test -p serviceradar-flowgger -- attaches_the_transport_peer_to_fallback_records` (expected `1 passed`), `cargo test -p srql -- source_ip_eq_filter_targets_source_ip_column stats_query_accepts_source_ip_filter` (expected `2 passed`), `cd elixir/serviceradar_core && MIX_ENV=test mix test test/serviceradar/event_writer/processors/logs_test.exs` (expected 0 failures), `openspec validate improve-syslog-ingestion-fidelity --strict` (the CLI is not installed on this machine; install per `openspec/AGENTS.md` first).
Expected: as stated; `0 passed` is a failure.

- [ ] **Step 2: Build the docs page**

Run: `cd docs && sfw npm ci && npm run build`
Expected: exit 0 (`docs/node_modules` is absent on a fresh checkout).

- [ ] **Step 3: Prove the family is gone**

Run: `git grep -n -P '<the Task 2 pattern from the private file>' $EXCL`
Expected: no output. This holds only after Task 3 has landed, because the same family sits in Task 3's `collector_test.go:492,533`.

- [ ] **Step 4: Commit**

```bash
git add docs/docs/syslog.md rust/flowgger rust/srql elixir/serviceradar_core/test/serviceradar/event_writer openspec/changes/improve-syslog-ingestion-fidelity
git commit -m "test(logs): use a reserved address for the syslog peer examples"
```

---

### Task 3: Regenerate the endpoint MAC and address pairs

**Files:**
- Modify: `go/cmd/wasm-plugins/opentext-nom/collector_test.go:492,533,553,575`
- Modify: `elixir/serviceradar_core/test/serviceradar/inventory/device_discovery_ingestor_test.exs:144-145`
- Modify: `elixir/serviceradar_core/test/serviceradar/inventory/identity/duplicate_sweep_test.exs:151,152,160,161,189,190,199`
- Modify: `openspec/changes/add-canonical-device-facts-and-source-disagreement/specs/external-inventory-plugin/spec.md:29`

**Interfaces:**
- Produces: four invented, universally administered MACs from `00:00:5E:00:53:xx`, each with at least one hex letter, and addresses in `192.0.2.0/24`. MAC-A replaces the identifier at `duplicate_sweep_test.exs:151,160,189,199` and its colon form at `:161`. MAC-B replaces `:152,190,199` (line 199 holds both). MAC-C goes at `collector_test.go:492,533` and in separator-free uppercase form at `:553,575`. MAC-D at `device_discovery_ingestor_test.exs:145`. Lines 151 and 152 must stay two different MACs; 160 and 161 must stay one MAC in two encodings.

- [ ] **Step 1: Replace and run**

Run: `cd go/cmd/wasm-plugins/opentext-nom && go test ./...` and `cd elixir/serviceradar_core && MIX_ENV=test mix test test/serviceradar/inventory/device_discovery_ingestor_test.exs test/serviceradar/inventory/identity/duplicate_sweep_test.exs` and `openspec validate add-canonical-device-facts-and-source-disagreement --strict`.
Expected: PASS. The lookup URL assertion at `collector_test.go:553` must see the 12 uppercase hex digits; the sweep tests at `duplicate_sweep_test.exs:149-165` must still group by equal MAC rather than return `[]` for a locally administered one.

- [ ] **Step 2: Prove the old OUIs are gone**

Run: `git grep -n -i -P '<the two Task 3 patterns>' $EXCL`
Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add go/cmd/wasm-plugins/opentext-nom/collector_test.go elixir/serviceradar_core/test/serviceradar/inventory openspec/changes/add-canonical-device-facts-and-source-disagreement
git commit -m "test(inventory): invent the endpoint MAC and address fixtures"
```

---

### Task 4: Owner call, then regenerate the partition slug and the display-device CSV rows

**Files (26 files; the case-insensitive grep in Step 2 is the list of record):**
- Shipped copy: `elixir/web-ng/lib/serviceradar_web_ng_web/live/device_live/index_events/device_management.ex:70,156`, `index_view/import_modal.ex:107,237`, `elixir/web-ng/lib/serviceradar_web_ng/devices/manual_device_creator.ex:66`, `elixir/web-ng/priv/mcp/srql-cookbook.md:131,144`, `rust/srql/src/query/devices/filters/identity.rs:18`
- web-ng tests: `test/phoenix/live/device_live/index_helpers_test.exs` (rows at 56, 90, 471, 475, 492, 531, 540 and the slug sites), `test/serviceradar_web_ng/devices/manual_device_creator_attrs_test.exs:22-63`, `manual_device_creator_test.exs:348-490`, `test/serviceradar_web_ng_web/dashboard_package_preferences_test.exs`, `test/phoenix/live/settings/active_scans_components_test.exs:12,21,34`, `test/phoenix/components/layouts_topbar_actions_test.exs:66,67`, `test/phoenix/components/mtr_profiles_live_test.exs:11,16`
- serviceradar_core tests: `composite_checks/validation/coverage_test.exs`, `edge/agent_command_bus_registry_test.exs`, `edge/sweep_config_distribution_integration_test.exs`, `inventory/identity/duplicate_sweep_test.exs:151`, `inventory/identity_reconciler_merge_test.exs`, `inventory/sync_ingestor_vendor_type_test.exs:633`, `sweep_jobs/sweep_results_flow_e2e_test.exs`
- `rust/srql/src/parser/tests.rs`, `rust/srql/src/query/tests/device_queries.rs:770-819`, `js/cli/tests/dashboard-resolve.test.mjs`
- Active specs: `openspec/changes/add-device-group-grants/{proposal.md:9,design.md:56,specs/device-group-grants/spec.md}`
- Plan doc: `docs/superpowers/plans/2026-09-02-sweep-diagnostics-srql-entities.md:791,838,841-843`

- [ ] **Step 1: Owner decision**

The owner states whether the slug, the hostname scheme in the CSV rows (see the private note), and the device counts next to them are from a real estate. The counts are a fleet-scale figure, a CLAUDE.md class, at `sync_ingestor_vendor_type_test.exs:633`, `openspec/changes/add-device-group-grants/proposal.md:9`, and `openspec/changes/add-composite-service-checks/specs/build-web-ui/spec.md:16` plus `specs/composite-checks/spec.md:284,292,294,448`. If no, close this task with that note. If yes, continue.

- [ ] **Step 2: Pick replacements and list the sites**

A new slug such as `retail` used everywhere; CSV rows with `host01.example.com`-style hostnames, addresses in `192.0.2.0/24`, and a tag list that still carries `key=value` pairs so `parse_csv_file` splits into `tags` and `metadata`; rounded, re-picked counts.
Run: `git grep -l -i -P '<the Task 4 slug pattern>' $EXCL`
Expected: 26 files, the list above.

- [ ] **Step 3: Replace, then run**

Run: `cd elixir/web-ng && <env block> mix test test/phoenix/live/device_live/index_helpers_test.exs test/serviceradar_web_ng/devices test/serviceradar_web_ng_web/dashboard_package_preferences_test.exs test/phoenix/live/settings test/phoenix/components`, `cd elixir/serviceradar_core && MIX_ENV=test mix test <the seven core files>`, `cargo test -p srql -- parser device_queries`, `cd js/cli && npm test`, `openspec validate add-device-group-grants --strict`.
Expected: 0 failures each; the cargo run reports more than 0 tests.

- [ ] **Step 4: Prove it**

Run: `git grep -n -i -P '<the Task 4 slug pattern>' $EXCL`
Expected: no output.

- [ ] **Step 5: Commit** as `test(devices): regenerate the partition and import fixtures`.

---

### Task 5: Owner call, then rename the on-prem example instance

**Files:**
- Rename: `config/environments/onprem/<instance>.textproto` (git mv) and its `instance:` field at line 22 and header at line 1
- Modify: `config/environments/onprem/BUILD.bazel:16-17`, `config/manager_validator/rust/tests/BUILD.bazel:38`, `config/README.md:42,57`, `openspec/specs/unified-configuration/spec.md:391`, `config/rules/fixtures/fixtures.textproto:304`
- Tests: `config/manager_config/elixir/test/identity_test.exs:29,44`, `manager_test.exs:27,70,73`, `config/manager_validator/elixir/test/validator_vector_test.exs:41`, `config/manager_config/go/manager_test.go:33,95,99`, `selector_test.go:55,59,85`, `config/manager_validator/go/vector_test.go:99`, `config/manager_config/rust/tests/types/config_manager_tests.rs:74,81`, `identity_tests.rs:49,51,71`, `source_tests.rs:26`, `config/manager_validator/rust/src/utils_tests/mod.rs:61`

- [ ] **Step 1: Owner decision**

The owner states whether the instance token is an organization abbreviation. If no, close with that note.

- [ ] **Step 2: Rename to `example` and run**

The instance must equal the filename stem; `INSTANCES` in the validator vectors enumerates the files. The two Elixir test directories have no `mix.exs`; they are Bazel `ex_unit_tests` targets.
Run: `go test ./config/manager_config/go/... ./config/manager_validator/go/...`, `cargo test -p serviceradar-config-manager -p serviceradar-config-validator`, `bazel test --config=remote //config/...` (covers `//config/manager_config/elixir:unit_tests` and `//config/manager_validator/elixir:unit_tests`).
Expected: PASS.

- [ ] **Step 3: Prove it**

Run: `git grep -n -P '<the Task 5 pattern>' $EXCL`
Expected: no output.

- [ ] **Step 4: Commit** as `chore(config): rename the on-prem example instance`.

---

### Task 6: Owner call, then move the map test anchor to a public landmark

**Files:**
- Modify: `elixir/web-ng/assets/js/hooks/OperationsTrafficMap.test.js:125,126,134,200,284-294`

- [ ] **Step 1: Owner decision**

The owner states whether the coordinate pair at 125, 126, 134 and 200 is from a site record, and whether the agent id at `:292` (it names a cluster worker) and the process id at `:294` are captured. Lines 106, 145, 156 and 199 already hold the public facility pair from PR 20 and stay.

- [ ] **Step 2: Use a public airport**

Use the same public pair as lines 106 and 145 at 125, 126 and 134, and a nearby public pair at 200. Replace the source label at 284 with a different public city from the target label at 285 (which already reads `Chicago, IL`), the addresses at 285-286 with `203.0.113.0/24`, and the agent id and pid with invented values if the owner says so.
Run: `cd elixir/web-ng/assets && bunx vitest run js/hooks/OperationsTrafficMap.test.js`
Expected: PASS (the spread assertion only needs `link.to` to differ from `link.from`).

- [ ] **Step 3: Prove it**

Run: `git grep -n -F '<the first value of the old pair, from the private file>' $EXCL`
Expected: no output.

- [ ] **Step 4: Commit** as `test(web-ng): anchor the traffic map test on a public landmark`.

---

### Task 7: Sweep the remaining vendor MACs and public addresses, and add the committed check

**Files:**
- Modify, the first MAC (a hypervisor vendor OUI): `go/cmd/wasm-plugins/awx/identity.go:145-148,186` (doc comment), `go/cmd/wasm-plugins/awx/identity_test.go:60,69,83,87,98,110,124,138,153`, `go/cmd/wasm-plugins/awx/main_test.go:2263`, `go/cmd/wasm-plugins/proxmox/main_test.go:389,420,475,482`
- Modify, the second MAC (a network vendor OUI): `elixir/serviceradar_core/lib/serviceradar/network_discovery/topology_graph/utils.ex:338-341` (comment), `elixir/serviceradar_core/test/serviceradar/network_discovery/topology_graph/utils_test.exs:10,32`, `go/pkg/mapper/topology_identity_test.go:50,73`
- Modify, public addresses: `elixir/serviceradar_core/test/serviceradar/inventory/interface_classifier_test.exs:47`, `go/pkg/mapper/interface_dedup_test.go:108,123` (use `203.0.113.0/24`)
- Create: `scripts/check-captured-data.sh`; Modify: `Makefile` (`lint` depends on it)
- Owner call on the lab names in `AGENTS.md:181`, `buildbuddy.yaml:64,1295`, `k8s/buildbuddy/*`, `k8s/srql-fixtures/README.md`, `k8s/starrocks/*` (upstream cluster manifests, left by design in PR 20)

- [ ] **Step 1: Replace the MAC and address sites and run**

Each MAC becomes a documentation-range MAC kept identical across its files (the comment and the tests that use it describe one device).
Run: `go test ./go/pkg/mapper/...`, `cd go/cmd/wasm-plugins/awx && go test ./...`, `cd go/cmd/wasm-plugins/proxmox && go test ./...`, `cd elixir/serviceradar_core && MIX_ENV=test mix test test/serviceradar/inventory/interface_classifier_test.exs test/serviceradar/network_discovery/topology_graph/utils_test.exs`.
Expected: PASS.

- [ ] **Step 2: Record the owner's decision on the `k8s/` and `buildbuddy.yaml` names**

Either "accepted upstream residue, not shipped" in `private/findings/INDEX.md`, or a follow-up task.

- [ ] **Step 3: Write the committed check and prove it fails on staging**

`scripts/check-captured-data.sh` checks classes only, never tokens: every MAC in tracked files under `$EXCL` must be in `00:00:5E:00:53:xx` or locally administered (`x2`, `x6`, `xA`, `xE` second nibble), in both colon and bare-hex forms. When `private/findings/captured-patterns.txt` exists it also runs those patterns with `-i`. It exits 1 on any hit and prints file:line. Add it to `make lint`. Do not add a private-IPv4 class check: 623 tracked files hold RFC 1918 addresses on purpose (`10.0.0.x` defaults in fixtures), so that gate could never pass.
Run: `scripts/check-captured-data.sh` on this PR's head, then `git stash && git checkout 46738d3a1e -- . && scripts/check-captured-data.sh; git checkout - -- . && git stash pop` (or run it in a worktree at staging).
Expected: exit 0 on the head; exit 1 at staging 46738d3a1e naming at least the MAC sites above.

- [ ] **Step 4: Commit** as `chore(fixtures): replace upstream example addresses and add the captured-data check`.

## Appendix A. Alternatives rejected

- Search-and-replace of the single flagged token per file. `CLAUDE.md` rejects it; the device id, serial format, build string and memory figure together still identify the estate.
- Leaving the docs-site address because upstream published it first. The docs site is this fork's published product too.
- Committing the retired tokens as grep patterns in the check script. That re-publishes what the sweep removes; the class checks are committed and the token patterns stay private.
- A private-IPv4 class gate. Too many intentional `10.x` defaults; the private pattern file covers the retired families instead.

## Appendix B. Risks

- Task 1's Elixir compile is slow on first run; budget minutes, not seconds.
- Task 5 touches Bazel labels; a missed label fails `//config/...` and the fix is the label, not the test.
- Task 7's MAC class check will also flag any future fixture that uses a real vendor OUI; that is the intent, and `CLAUDE.md` allows a real OUI only when the MAC is invented, which the documentation range makes unnecessary.
