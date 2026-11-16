#!/usr/bin/env bash
# Restore the compose rig from a backup.sh directory, then prove it with `yantra smoke`.
# Destructive: it replaces the rig's databases, the YANTRA stream, the MinIO data and the Odoo filestore with the
# backup's contents.
#
#   deployment/scripts/restore.sh backups/<timestamp> [--no-smoke]
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <backup dir> [--no-smoke]" >&2
  exit 2
fi
dir="$(cd "$1" && pwd)"
smoke=true
[[ "${2:-}" == "--no-smoke" ]] && smoke=false

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
compose=(docker compose -f "$repo/deployment/local/compose.yaml")
network="yantra-local_default"
nats_box="natsio/nats-box:0.14.5"
writers=(gateway work work-events money money-events odoo keycloak minio)
start=$(date +%s)

echo "== stop everything that writes"
"${compose[@]}" stop "${writers[@]}"

for dump in "$dir"/*.dump; do
  db="$(basename "$dump" .dump)"
  echo "== postgres $db"
  "${compose[@]}" exec -T postgres psql -U yantra -d postgres -qc "DROP DATABASE IF EXISTS \"$db\" WITH (FORCE)"
  "${compose[@]}" exec -T postgres psql -U yantra -d postgres -qc "CREATE DATABASE \"$db\""
  "${compose[@]}" exec -T postgres pg_restore -U yantra -d "$db" --no-owner --exit-on-error < "$dump"
done

if [[ -d "$dir/nats-YANTRA" ]]; then
  echo "== nats stream YANTRA"
  docker run --rm --network "$network" "$nats_box" nats --server nats://nats:4222 stream rm -f YANTRA > /dev/null 2>&1 || true
  docker run --rm --network "$network" -v "$dir:/backup:ro" "$nats_box" \
    nats --server nats://nats:4222 stream restore --no-progress /backup/nats-YANTRA > /dev/null
fi

# replace a volume's contents with an archive, through the service's own image (the service is stopped). The
# volume's mount point belongs to root while the image runs as its own user, so tar may not set the mount point's
# own mode or times ("tar: .: ..."): that, and only that, is tolerated; any other error fails the restore.
restore_volume() { # <service> <path in the container> <archive>
  "${compose[@]}" run --rm --no-deps -T --entrypoint sh "$1" -c "
    find '$2' -mindepth 1 -delete
    tar --no-same-owner -C '$2' -xzf - 2> /tmp/tar.err && exit 0
    if grep -v -e '^tar: \\.: ' -e 'Exiting with failure status' /tmp/tar.err | grep -q .; then
      cat /tmp/tar.err >&2
      exit 1
    fi
  " < "$3"
}
if [[ -f "$dir/minio.tar.gz" ]]; then
  echo "== minio objects"
  restore_volume minio /bitnami/minio/data "$dir/minio.tar.gz"
fi
if [[ -f "$dir/odoo-filestore.tar.gz" ]]; then
  echo "== odoo filestore"
  restore_volume odoo /var/lib/odoo "$dir/odoo-filestore.tar.gz"
fi

echo "== start"
"${compose[@]}" start minio keycloak work money work-events money-events gateway odoo
for _ in $(seq 1 60); do
  curl -sf localhost:8090/health > /dev/null && break
  sleep 1
done
restored=$(( $(date +%s) - start ))
echo "restored in ${restored}s"

if "$smoke"; then
  echo "== smoke"
  (cd "$repo" && uv run yantra smoke)
fi
echo "total $(( $(date +%s) - start ))s"
