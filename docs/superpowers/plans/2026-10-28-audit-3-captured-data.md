# Captured-data regeneration implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the remaining fixtures and examples that look captured from a live system, by regenerating each from nothing so the shape no longer identifies anyone.

**Architecture:** One pull request per data family. Every task replaces inline literals in tests, docs and shipped source with values from the reserved ranges in `CLAUDE.md`, keeps each test's assertion meaningful, and ends with an anchored `git grep` that returns nothing. No value is copied from this plan into a commit message, branch name or PR title; describe the change by class.

**Tech Stack:** Go (a plugin module with its own `go.mod`), Elixir ExUnit (DB-free files), Rust `cargo test`, Vitest, OpenSpec.

**Spec:** Tier 3 of `private/findings/2026-10-28-project-audit.md` (gitignored; it names the address families and schemes, which is why it stays local). This plan refers to values by role and file:line only.

## Global constraints

- `CLAUDE.md`: fixtures are invented, never exported. Regenerate; never search-and-replace a single token, because the shape is the tell. Reserved replacements are `host01.example.com`, `SITE01-...`, `192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24` for public addresses, invented serials and builds, `555-01xx`. An invented MAC may use a real vendor OUI.
- Do not name the affected party in any commit, branch or PR.
- Historical paths are exempt and untouched: `CHANGELOG*`, `openspec/changes/archive/`, `docs/learnings/adlr/`.
- The opentext-nom plugin has its own module. Run its tests from `go/cmd/wasm-plugins/opentext-nom` with `go test ./...`, not from the repo root.
- Each PR ends with `/simplify`, then `/code-review` on its diff, before commit.

## Review focus

- A regenerated MAC without a hex letter leaves the uppercase assertion in `TestCollectorLooksUpAttachedSwitchPortByEndpointMAC` unexercised (Task 3 pins a letter).
- A regenerated serial pair that is not two distinct comma-joined values breaks the split assertion in `TestNormalizeDeviceRowAcceptsHPNAIntegerFlags` (Task 1).
- A syslog peer value that is not a valid IP makes the parser return nil and the Elixir test fail for the wrong reason (Task 2).
- A device id used in `config_retrieve_test.go` at only some of its nine sites (Task 1 lists them all).
- An instance rename that misses the `textproto` filename or the Bazel label, which breaks `//config/...` builds (Task 5).

## Dependency graph

Tasks 1, 2, 3 are independent and start now. Tasks 4, 5, 6 each start only after the owner's decision in their first step. Task 7 is a single sweep that follows the others so its grep is the final gate. Tasks 1 and 3 both touch `collector_test.go` and `device_discovery_ingestor_test.exs`; land Task 1 first and rebase Task 3.

---

### Task 1: Regenerate the network-automation device record

**Files:**
- Modify: `go/cmd/wasm-plugins/opentext-nom/collector_test.go:30-40,86-130` and the three hard-coded memory literals in `TestInventoryDeviceMapsOCSFFieldsFromHPNARow`
- Modify: `go/cmd/wasm-plugins/opentext-nom/config_retrieve_test.go:27-29,54,58,69,113,124,181,186`
- Modify: `elixir/serviceradar_core/test/serviceradar/inventory/device_discovery_ingestor_test.exs:76-130`
- Modify: `elixir/serviceradar_core/test/serviceradar/inventory/sync/enrichment_hw_info_test.exs:9-27`
- Modify: `elixir/serviceradar_core/test/serviceradar/inventory/sync/device_records_managed_test.exs:16,24`

**Interfaces:**
- Consumes: nothing shared. There is no fixture helper; the record is inline in each file and mirrored by hand.
- Produces: one invented record used identically in all five files. Pick it once and write it at the top of the PR description by class, not value: an integer device id of any width; `SITE01-MDF01-SW01` as hostname; an address in `192.0.2.0/24`; two distinct invented serials joined by a comma; an invented firmware string of the vendor's shape (letters, dots, digits) used for both `softwareVersion` and `firmwareVersion`; a round memory count; a location string with leading and trailing spaces; a contact with trailing spaces; an invented instance name such as `example-automation` for `InstanceID`, `source_instance` and inside `integration_id`.

- [ ] **Step 1: Run the five test targets to record the green baseline**

Run: `cd go/cmd/wasm-plugins/opentext-nom && go test ./...` and `cd elixir/serviceradar_core && MIX_ENV=test mix test test/serviceradar/inventory/device_discovery_ingestor_test.exs test/serviceradar/inventory/sync/enrichment_hw_info_test.exs test/serviceradar/inventory/sync/device_records_managed_test.exs`
Expected: PASS, PASS (the first compile of serviceradar_core takes minutes).

- [ ] **Step 2: Write the Go record and re-run**

Keep what each test asserts: `managementStatus` 0 and 1 mapping, stringified integer id, `serialNumber` split into first serial and two chassis serials, `excludeFromPoll` false, `os.version` equal to the firmware string, `memory_bytes` equal to the input, trimmed owner and location, the marshalled payload containing `"serial":"<first>"` and `"memory_bytes":<n>` and not the joined serial. In `config_retrieve_test.go` use the same id at every one of the nine sites and in the `deviceid` request parameter.
Run: `cd go/cmd/wasm-plugins/opentext-nom && go test ./...`
Expected: PASS.

- [ ] **Step 3: Mirror the record in the three Elixir files and re-run**

The ingestor test asserts `is_managed`, `os.name`, `os.version`, `hw_info.serial_number`, two `chassis_serials`, `memory_bytes`, `owner.name`, `tags.inventory_source`, `metadata.os_name` and `metadata.geographical_location`. `enrichment_hw_info_test.exs` needs two serials, the firmware string and an integer memory value at the lines listed; `device_records_managed_test.exs` needs only the firmware string.
Run: the Elixir command from Step 1.
Expected: PASS.

- [ ] **Step 4: Prove the old shape is gone**

Run: `git grep -n -P '<old 5-digit id>|<old serial prefix>' -- ':!openspec/changes/archive' ':!CHANGELOG*'` using the tokens from the audit note, never pasted here.
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add go/cmd/wasm-plugins/opentext-nom/collector_test.go go/cmd/wasm-plugins/opentext-nom/config_retrieve_test.go elixir/serviceradar_core/test/serviceradar/inventory
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
- Produces: one address in `192.0.2.0/24` used at every site above. The Elixir and spec sites keep the `default:<ip>` partition-prefix shape, which is the behavior under test.

- [ ] **Step 1: Replace and run each test**

Run: `cargo test -p serviceradar-flowgger attaches_the_transport_peer_to_fallback_records`, `cargo test -p srql source_ip_eq_filter_targets_source_ip_column stats_query_accepts_source_ip_filter`, `cd elixir/serviceradar_core && MIX_ENV=test mix test test/serviceradar/event_writer/processors/logs_test.exs`, `openspec validate improve-syslog-ingestion-fidelity --strict`.
Expected: all PASS.

- [ ] **Step 2: Build the docs page**

Run: `cd docs && npm run build`
Expected: exit 0 (the line is a prose SRQL example; the build proves the page still renders).

- [ ] **Step 3: Prove the family is gone outside archives**

Run: `git grep -n -P '\b<first two octets of the old family>\.\d{1,3}\.\d{1,3}\b' -- ':!openspec/changes/archive' ':!CHANGELOG*'`
Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add docs/docs/syslog.md rust/flowgger rust/srql elixir/serviceradar_core/test/serviceradar/event_writer openspec/changes/improve-syslog-ingestion-fidelity
git commit -m "test(logs): use a reserved address for the syslog peer examples"
```

---

### Task 3: Regenerate the L2 endpoint and kiosk endpoint pairs

**Files:**
- Modify: `go/cmd/wasm-plugins/opentext-nom/collector_test.go:492,533,575`
- Modify: `elixir/serviceradar_core/test/serviceradar/inventory/device_discovery_ingestor_test.exs:140-145`
- Modify: `elixir/serviceradar_core/test/serviceradar/inventory/identity/duplicate_sweep_test.exs:151,152,160,161,189,190,199`
- Modify: `openspec/changes/add-canonical-device-facts-and-source-disagreement/specs/external-inventory-plugin/spec.md:29`

**Interfaces:**
- Produces: two invented MACs with a locally administered OUI (`02:00:5E:xx:xx:xx`), each containing at least one letter `A` to `F`, and an address in `192.0.2.0/24`. The first MAC is used at `collector_test.go:533` and in separator-free uppercase form at `:575`, and at `duplicate_sweep_test.exs:151,160,189`; the second MAC at `:152,161,190,199`.

- [ ] **Step 1: Replace and run**

Run: `cd go/cmd/wasm-plugins/opentext-nom && go test ./...` and `cd elixir/serviceradar_core && MIX_ENV=test mix test test/serviceradar/inventory/device_discovery_ingestor_test.exs test/serviceradar/inventory/identity/duplicate_sweep_test.exs` and `openspec validate add-canonical-device-facts-and-source-disagreement --strict`.
Expected: PASS. The lookup URL assertion at `collector_test.go:553` must see the 12 uppercase hex digits.

- [ ] **Step 2: Prove the old OUIs are gone**

Run: `git grep -n -i -P '<old OUI with and without colons>' -- ':!openspec/changes/archive'` for both old OUIs.
Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add go/cmd/wasm-plugins/opentext-nom/collector_test.go elixir/serviceradar_core/test/serviceradar/inventory openspec/changes/add-canonical-device-facts-and-source-disagreement
git commit -m "test(inventory): invent the endpoint MAC and address fixtures"
```

---

### Task 4: Owner call, then regenerate the partition slug and the display-device CSV rows

**Files:**
- Shipped copy: `elixir/web-ng/lib/serviceradar_web_ng_web/live/device_live/index_events/device_management.ex:70,156`, `index_view/import_modal.ex:107,237`, `elixir/web-ng/lib/serviceradar_web_ng/devices/manual_device_creator.ex:66`, `elixir/web-ng/priv/mcp/srql-cookbook.md:131,144`, `rust/srql/src/query/devices/filters/identity.rs:18`
- Tests: `elixir/web-ng/test/phoenix/live/device_live/index_helpers_test.exs` (rows at 56, 90, 471, 492, 531 and the slug sites listed in the audit note), `manual_device_creator_attrs_test.exs:22-63`, `manual_device_creator_test.exs:348-490`, `dashboard_package_preferences_test.exs`, `active_scans_components_test.exs:12,21`, `layouts_topbar_actions_test.exs:66`, `mtr_profiles_live_test.exs:11`, `js/cli/tests/dashboard-resolve.test.mjs`, `rust/srql/src/query/tests/device_queries.rs:770-819`
- Plan doc: `docs/superpowers/plans/2026-09-02-sweep-diagnostics-srql-entities.md:791,838,841-843`

- [ ] **Step 1: Owner decision**

The owner states whether the four-letter slug and the `<class>-<airport>-<gate>` hostname scheme with its tag set are from a real estate. If no, close this task with that note. If yes, continue.

- [ ] **Step 2: Pick replacements**

A new slug such as `retail` used everywhere the old one appears (23 files); CSV rows with `host01.example.com`-style hostnames, addresses in `192.0.2.0/24`, a tag list that still has `key=value` pairs so `parse_csv_file` splits into `tags` and `metadata`.

- [ ] **Step 3: Replace, then run**

Run: `cd elixir/web-ng && mix test test/phoenix/live/device_live/index_helpers_test.exs test/serviceradar_web_ng/devices/manual_device_creator_attrs_test.exs test/serviceradar_web_ng/devices test/serviceradar_web_ng_web/dashboard_package_preferences_test.exs test/phoenix/live/settings test/phoenix/components` (the creator test needs the local test database; see `docs/agent-runbooks.md` "Local test database (fork)"), `cargo test -p srql device_queries`, `cd js/cli && npm test`.
Expected: PASS.

- [ ] **Step 4: Prove it**

Run: `git grep -n -P '\b<old slug>\b' -- ':!openspec/changes/archive' ':!CHANGELOG*'`
Expected: no output.

- [ ] **Step 5: Commit** as `test(devices): regenerate the partition and import fixtures`.

---

### Task 5: Owner call, then rename the on-prem example instance

**Files:**
- Rename: `config/environments/onprem/<instance>.textproto` (git mv) and its `instance:` field at line 22 and header at line 1
- Modify: `config/environments/onprem/BUILD.bazel:16-17`, `config/manager_validator/rust/tests/BUILD.bazel:38`, `config/README.md:42,57`, `openspec/specs/unified-configuration/spec.md:391`, `config/rules/fixtures/fixtures.textproto:304`
- Tests: `config/manager_config/elixir/test/identity_test.exs:29,44`, `manager_test.exs:27,70,73`, `config/manager_validator/elixir/test/validator_vector_test.exs:41`, `config/manager_config/go/manager_test.go:33,95,99`, `selector_test.go:55,59,85`, `config/manager_validator/go/vector_test.go:99`, `config/manager_config/rust/tests/types/config_manager_tests.rs:74,81`, `identity_tests.rs:49,51,71`, `source_tests.rs:26`, `config/manager_validator/rust/src/utils_tests/mod.rs:61`

- [ ] **Step 1: Owner decision**

The owner states whether the four-letter instance token is an organization abbreviation. If no, close with that note.

- [ ] **Step 2: Rename to `example` and run**

The instance must equal the filename stem; `INSTANCES` in the validator vectors enumerates the files.
Run: `go test ./config/manager_config/go/... ./config/manager_validator/go/...`, `cd config/manager_config/elixir && mix test`, `cd config/manager_validator/elixir && mix test`, `cargo test -p serviceradar-config-manager -p serviceradar-config-manager-validator` (confirm crate names in their `Cargo.toml`), `bazel test --config=remote //config/...`.
Expected: PASS.

- [ ] **Step 3: Prove it**

Run: `git grep -n -P '\b<old token>\b' -- ':!openspec/changes/archive' ':!CHANGELOG*'`
Expected: no output.

- [ ] **Step 4: Commit** as `chore(config): rename the on-prem example instance`.

---

### Task 6: Owner call, then move the map test anchor to a public landmark

**Files:**
- Modify: `elixir/web-ng/assets/js/hooks/OperationsTrafficMap.test.js:125,126,134,200,284-286`

- [ ] **Step 1: Owner decision**

The owner states whether the coordinate pair is from a site record. If no, close.

- [ ] **Step 2: Use a public airport**

The fork already uses O'Hare's public coordinates in the PR 20 sweep; use the same pair at 125, 126, 134 and a nearby public pair at 200. Replace the city-plus-public-IP label at 284-286 with `Chicago, IL` and a `203.0.113.0/24` address.
Run: `cd elixir/web-ng/assets && bunx vitest run js/hooks/OperationsTrafficMap.test.js`
Expected: PASS (the spread assertion only needs `link.to` to differ from `link.from`).

- [ ] **Step 3: Commit** as `test(web-ng): anchor the traffic map test on a public landmark`.

---

### Task 7: Sweep upstream residue the fork chooses not to carry

**Files:**
- Modify: `go/cmd/wasm-plugins/awx/identity.go:145-148,186` (doc comment example MAC), `elixir/serviceradar_core/lib/serviceradar/network_discovery/topology_graph/utils.ex:338-341` (comment)
- Modify: `elixir/serviceradar_core/test/serviceradar/inventory/interface_classifier_test.exs:47`, `go/pkg/mapper/interface_dedup_test.go:108,123` (public addresses, use `203.0.113.0/24`)
- Owner call on `AGENTS.md:181` (an illustrative name upstream wrote), `buildbuddy.yaml:64,1295`, `k8s/buildbuddy/*`, `k8s/srql-fixtures/README.md`, `k8s/starrocks/*` (upstream cluster manifests, left by design in PR 20)

- [ ] **Step 1: Replace the four code and test sites and run**

Run: `go test ./go/pkg/mapper/...`, `cd go/cmd/wasm-plugins/awx && go test ./...`, `cd elixir/serviceradar_core && MIX_ENV=test mix test test/serviceradar/inventory/interface_classifier_test.exs`.
Expected: PASS.

- [ ] **Step 2: Record the owner's decision on the `k8s/` and `buildbuddy.yaml` names**

Either "accepted upstream residue, not shipped" in `private/findings/INDEX.md`, or a follow-up task.

- [ ] **Step 3: Final gate for the whole plan**

Run the anchored patterns from the audit (private addresses outside the reserved ranges, the two old OUIs, the old slug and token, the old family) in one script `scripts/check-captured-data.sh` that exits 1 on any hit outside the exempt paths, and add it to `make lint`. The patterns themselves live in the script, which is the one committed place a reviewer re-runs.
Expected: exit 0 on the PR head; exit 1 when run against `staging` before this plan.

- [ ] **Step 4: Commit** as `chore(fixtures): replace upstream example addresses and add the captured-data check`.

## Appendix A. Alternatives rejected

- Search-and-replace of the single flagged token per file. `CLAUDE.md` rejects it; the device id, serial format, build string and memory figure together still identify the estate.
- Leaving the docs-site address because upstream published it first. The docs site is this fork's published product too.

## Appendix B. Risks

- Task 1's Elixir compile is slow on first run; budget minutes, not seconds.
- Task 5 touches Bazel labels; a missed label fails `//config/...` and the fix is the label, not the test.
- Task 7's check script must be anchored; an unanchored three-letter token matched 20,000 lines in this repo before.
