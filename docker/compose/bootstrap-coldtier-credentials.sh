#!/bin/sh
# Writes the cold-tier credentials once into the coldtier-credentials volume.
# Explicit SR_COLDTIER_* values win. A data volume initialised before this
# script existed used the old literal defaults (PostgreSQL applies
# POSTGRES_PASSWORD only at initdb), so a non-empty data volume without a
# persisted credential keeps that literal and asks for a rotation.
set -eu

CRED_DIR="${COLDTIER_CRED_DIR:-/etc/serviceradar/coldtier}"
MINIO_DATA_DIR="${COLDTIER_MINIO_DATA_DIR:-/data/minio}"
HEAD_DATA_DIR="${COLDTIER_HEAD_DATA_DIR:-/data/head}"

umask 077
mkdir -p "$CRED_DIR"

generate_password() {
  od -An -N 32 -tx1 /dev/urandom | tr -d ' \n'
}

has_data() {
  [ -n "$(ls -A "$1" 2>/dev/null)" ]
}

# resolve <file> <explicit value> <data dir> <legacy literal>
resolve() {
  target="$1"
  if [ -n "$2" ]; then
    printf "%s" "$2" > "$target"
    echo "Wrote $target from environment"
  elif [ -s "$target" ]; then
    echo "Credential already present at $target; skipping"
  elif has_data "$3"; then
    echo "Existing data in $3 without a persisted credential; keeping the legacy default. Set the SR_COLDTIER_* variable and change the password in the service to rotate it." >&2
    printf "%s" "$4" > "$target"
    echo "Wrote $target"
  else
    generate_password > "$target"
    echo "Wrote $target"
  fi
  chmod 0644 "$target"
}

if [ -n "${SR_COLDTIER_MINIO_USER:-}" ]; then
  printf "%s" "$SR_COLDTIER_MINIO_USER" > "$CRED_DIR/minio-root-user"
elif [ ! -s "$CRED_DIR/minio-root-user" ]; then
  printf "%s" "serviceradar" > "$CRED_DIR/minio-root-user"
fi
chmod 0644 "$CRED_DIR/minio-root-user"

resolve "$CRED_DIR/minio-root-password" "${SR_COLDTIER_MINIO_PASSWORD:-}" "$MINIO_DATA_DIR" serviceradarcold
resolve "$CRED_DIR/head-password" "${SR_COLDTIER_HEAD_PASSWORD:-}" "$HEAD_DATA_DIR" serviceradarcoldhead
