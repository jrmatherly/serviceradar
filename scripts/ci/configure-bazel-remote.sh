#!/usr/bin/env bash
# Writes .bazelrc.remote so Bazel talks to the fork's BuildBuddy org.
#
# .bazelrc is try-imported LAST by //.bazelrc, so lines here override its
# build:cache_only / build:remote_base endpoints. The config prefixes matter: a
# plain `build --remote_executor=...` line loses to the `--config=remote`
# expansion on the command line.
#
# Env (set by the workflow step "Configure Bazel remote execution"):
#   BAZEL_REMOTE_ENABLED    "true" (default) to use BuildBuddy; anything else fails
#                           fast: there is no local-Bazel publish path on hosted runners
#   BUILDBUDDY_ENDPOINT     gRPC host, default remote.buildbuddy.io
#   BUILDBUDDY_APP_URL      UI base URL, default https://app.buildbuddy.io
#   BUILDBUDDY_ORG_API_KEY  org API key; required when enabled
set -euo pipefail

enabled="${BAZEL_REMOTE_ENABLED:-true}"
endpoint="${BUILDBUDDY_ENDPOINT:-remote.buildbuddy.io}"
app_url="${BUILDBUDDY_APP_URL:-https://app.buildbuddy.io}"
app_url="${app_url%/}"

if [[ "${enabled}" != "true" ]]; then
  echo "BAZEL_REMOTE_ENABLED is '${enabled}': Bazel jobs need BuildBuddy remote execution and cannot run. Set the variable to true." >&2
  exit 1
fi

if [[ -z "${BUILDBUDDY_ORG_API_KEY:-}" ]]; then
  echo "BAZEL_REMOTE_ENABLED is true but the BUILDBUDDY_API_KEY secret is not set." >&2
  exit 1
fi

umask 077
cat > .bazelrc.remote <<EOF
common --remote_header=x-buildbuddy-api-key=${BUILDBUDDY_ORG_API_KEY}
build:cache_only --remote_bytestream_uri_prefix=${endpoint}
build:cache_only --remote_cache=grpcs://${endpoint}
build:cache_only --bes_backend=grpcs://${endpoint}
build:cache_only --bes_results_url=${app_url}/invocation/
build:remote_base --remote_executor=grpcs://${endpoint}
EOF

echo "BUILDBUDDY_INVOCATIONS=${app_url}/invocation/" >> "${GITHUB_ENV:-/dev/null}"
echo "Bazel remote execution enabled against ${endpoint}."
