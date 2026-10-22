"""The fork's registry identity, in one place.

Everything Starlark-side that needs an unstamped default (oci_push repository
files, local `docker load` tags, base-image annotations) reads these. The shell
twin is scripts/lib/fork-registry.sh; MODULE.bazel and build/rbe/BUILD must hold
literals and are listed in docs/fork-ci.md for the rebrand.
"""

FORK_OCI_REGISTRY = "ghcr.io"
FORK_OCI_PROJECT = "jrmatherly"
FORK_IMAGE_PREFIX = FORK_OCI_REGISTRY + "/" + FORK_OCI_PROJECT
