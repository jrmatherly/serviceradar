#!/usr/bin/env bash
# The fork's registry identity for shell tooling: defaults for OCI_REGISTRY and
# OCI_PROJECT when the caller (a workflow, or a developer) has not set them.
# Starlark twin: docker/images/fork_registry.bzl. Keep the two in agreement.
: "${OCI_REGISTRY:=ghcr.io}"
: "${OCI_PROJECT:=jrmatherly}"
export OCI_REGISTRY OCI_PROJECT
