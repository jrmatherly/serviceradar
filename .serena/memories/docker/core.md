# Docker / deploy

- Compose files at root: `docker-compose.yml`, `docker-compose.dev.yml`; `Makefile.docker`; Dockerfiles in `docker/compose/` (`Dockerfile.agent`, `Dockerfile.agent-gateway`, ...); OCI images built by Bazel (`docker/images/BUILD.bazel`, `.bzl` helpers). Supported k8s install: `helm/serviceradar/`.
- Compose refresh and demo-namespace Helm refresh procedures: `docs/agent-runbooks.md`.
- macOS cannot `make push-web-ng`; use `make push_all`.
- Do not run docker commands unless the user asks.
