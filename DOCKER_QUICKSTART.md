# ServiceRadar Docker Quick Start

## One Command Setup - RECOMMENDED

```bash
docker compose up
```

Uses the fork's pre-built images from GitHub Container Registry (GHCR), `ghcr.io/jrmatherly/serviceradar-*`.

## Development (Local Build)

```bash
make compose-load-local
APP_TAG=local docker compose up
```

Builds the app images from this checkout with Bazel, loads them into Docker as `:local`,
and runs them. `docker-compose.dev.yml` is an overlay that adds the dev-only `faker`
service (`--profile faker`).

Tip: To make the dev overlay the default (no `-f` needed), set this in `.env`:
```
COMPOSE_FILE=docker-compose.yml:docker-compose.dev.yml
```

## What happens with one command:
- ✅ Generate mTLS certificates automatically
- ✅ Generate random CNPG credentials stored in the cnpg-credentials volume
- ✅ Pull/Build Docker images  
- ✅ Start the ServiceRadar stack (CNPG, NATS, web-ng, core-elx, agent-gateway)
- ✅ Set up networking and persistent volumes
 - ✅ Run the core-elx migration runner to bootstrap schema/extensions

Developer routes are off by default. `SERVICERADAR_DEV_ROUTES=true docker compose up` (or the
same line in `.env`) enables `/dev/dashboard`, `/dev/mailbox` and `/dev/ash`; these pages have no
login, so leave them off on any host you do not fully control.

## Alternative Commands

```bash
# Production deployment with pre-built images (default)
docker compose up

# Development with images built from this checkout
make compose-load-local && APP_TAG=local docker compose up

# Using Makefile (uses pre-built images)
make -f Makefile.docker start

# All services plus faker (--profile full)
make -f Makefile.docker up-full
```

## Reaching the stack by another hostname

web-ng accepts LiveView websocket connections only from the origin it is configured for. The
compose default is `//<SERVICERADAR_HOST>` (`localhost` when unset), which covers both
`http://` and `https://` on that host, so `SERVICERADAR_HOST=192.0.2.10 docker compose up`
accepts browsers that open `https://192.0.2.10`. `SERVICERADAR_HOST` is a bare hostname or IP,
no port. For more than one hostname, set `PHX_CHECK_ORIGIN` to a comma-separated list such as
`//localhost,//192.0.2.10`, or to `true`, which accepts whatever host the browser used.
`PHX_CHECK_ORIGIN=false` disables the check and is not a production setting.

## Check Status

```bash
# View service status
make -f Makefile.docker status

# View logs
make -f Makefile.docker logs

# Test connectivity
make -f Makefile.docker test
```

## Access Services

- **Web UI**: http://localhost (Caddy)
- **Login**: `root@localhost` + password from `docker compose logs config-updater | grep "Password:"`
- **Core API**: http://localhost/api (via proxy) or http://localhost:8090
- **Metrics**: http://localhost:9090/metrics

## Stop Services

```bash
docker compose down
```

## Environment Variables (Optional)

Copy `.env-sample` to `.env` to customize:
- Database passwords
- API keys
- Log levels
- Service configuration
 - Optional compose defaults (`COMPOSE_FILE`)

All values have sensible defaults, so the `.env` file is optional.

Note: CNPG binds to loopback by default. Set `CNPG_PUBLIC_BIND=0.0.0.0` in `.env` if you need LAN access.

Note: Docker Compose now auto-migrates an existing PG16 CNPG data volume to
PG18 during startup. For existing installs, the normal path is still:

```bash
docker compose pull
docker compose up -d
```

Fresh installs and already-migrated PG18 volumes automatically no-op in the
migration step.

If you need to run the migration explicitly, the helper is still available:

```bash
./docker/compose/migrate-cnpg-pg16-to-pg18.sh
```

If you already have a CNPG data volume from a previous install, note that we
now store randomly generated DB credentials in a dedicated volume instead of
shipping static defaults. Seed the `cnpg-credentials` volume once before
starting. Legacy pre-security Compose data volumes are auto-recovered using the
old defaults on first restart. If you use custom credentials or lost a newer
`cnpg-credentials` volume, seed them explicitly:

```bash
docker compose run --rm \
  -e CNPG_SUPERUSER=<postgres-or-legacy-superuser> \
  -e CNPG_PASSWORD=<app-password> \
  -e CNPG_SUPERUSER_PASSWORD=<postgres-password> \
  db-credentials
```

## What's Running?

- **cert-generator**: One-time container that generates mTLS certificates
- **core-elx**: ServiceRadar control plane and business logic
- **core-elx-migrations**: One-shot migration runner (exits after schema bootstrap)

For full documentation, see [README-Docker.md](README-Docker.md).
