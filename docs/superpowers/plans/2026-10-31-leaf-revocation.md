# Leaf revocation: findings and options

Status: no fix built. The owner has not chosen an option.

## The gap

A revoked collector credential stops working at the hub, but a leaf maps a client certificate's CN to a static user and ignores the NATS credential. So a revoked package keeps publishing through its leaf until the site's bundle is re-installed.

`go/pkg/cli/nats_leaf_revocation_integration_test.go` (`TestLeafRefusesCollectorRevokedAtHub`) proves this and FAILS today by design. Do not merge it before the fix.

## Who is exposed

- Collector packages: no shipped setup runs one behind a leaf. `docker/compose/nats.docker.conf` has no `leafnodes`, and Helm sets no `NATS_ACCOUNT_NAME`, so `ProvisionCollectorWorker` marks packages failed with `nats_not_configured`. Read from config, not run on a deployment.
- Direct add-on leaf identities: the same static users on Helm, also needing a bundle re-install to revoke. This is the part exposed now.

## Measured on embedded nats-server 2.15.0

- Credential revoked at an operator-mode hub: the hub refuses it. The leaf still acks a publish on the open connection (stream 1 to 2) and accepts a new connection.
- Config reload after dropping the user: returns in under 1 ms, the open connection closes in under 1 ms, a new connection gets `Authorization Violation`, another collector keeps publishing, and the leaf link stays up.
- Certificate expiry: an open connection still publishes 2 s after NotAfter. Only a new connection fails.

Read from source, not run: `ocsp_peer` runs in TLS VerifyConnection (handshake only), a certificate with no AIA counts as valid, and operator mode rejects configured users (`jwt.go:98`). `serviceradar-nats.service` already has `ExecReload` (HUP).

## Options

| Option | Time to refuse | Cost | Limits |
|---|---|---|---|
| Leaf polls for its user list and reloads (recommended) | About 60 s with WAN | Roughly 400 lines (estimate): endpoint, per-site token, `include` in the leaf config, script and timer. Existing sites re-install once. | During a WAN outage, revocation waits for the link. Also covers direct add-on identities. |
| Leaf in operator mode, using the NATS credential | Probably seconds, not run | Largest. Helm's hub moves to operator mode, or Compose gains a leaf listener. | Add-on identities would need `.creds` files, which the base agent bundle does not contain. |
| Short-lived certificates | Next reconnect only | Collectors need a renewal client | Open connections keep publishing, so this does not meet the goal alone. |
| OCSP on the leaf | New connections only | New responder, every certificate re-issued | Certificates with no OCSP URL pass. A WAN outage would block reconnects by default. |
| Docs and a "re-install needed" UI flag | Whenever an operator re-installs | Small | No stated time, so it does not meet the goal. |

If polling is chosen, commit to 60 s, proved by a test that fails if the removed user stays connected.

## Experiments

`2026-10-31-leaf-revocation-experiments.go.txt` holds the experiment code. Copy it to `go/pkg/cli/zz_exp_test.go` to re-run.
