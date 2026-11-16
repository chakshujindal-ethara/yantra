#!/usr/bin/env bash
# Back up the compose rig: Postgres roles, the yantra, keycloak and odoo databases (custom format), the NATS
# YANTRA stream, the MinIO bucket data (unit media, worker documents, deliverables) and the Odoo filestore.
# Output: backups/<UTC timestamp>/ at the repo root (gitignored: it holds personal data).
# The two volumes are archived through their own services' images (`compose run`, no extra image): MinIO is read
# while it runs, so an upload landing mid-archive may be missing or partial; stop the writers first for an exact copy.
# Deployed environments rely on managed Postgres PITR instead (deployment/README.md); this is the rig's drill.
#
#   deployment/scripts/backup.sh            # prints the backup directory on the last line
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
compose=(docker compose -f "$repo/deployment/local/compose.yaml")
network="yantra-local_default"
nats_box="natsio/nats-box:0.14.5"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
dir="$repo/backups/$stamp"
mkdir -p "$dir"
start=$(date +%s)

echo "== postgres roles"
"${compose[@]}" exec -T postgres pg_dumpall -U yantra --globals-only > "$dir/globals.sql"

for db in yantra keycloak odoo; do
  if "${compose[@]}" exec -T postgres psql -U yantra -d postgres -Atc "select 1 from pg_database where datname='$db'" | grep -q 1; then
    echo "== postgres $db"
    "${compose[@]}" exec -T postgres pg_dump -U yantra -Fc -d "$db" > "$dir/$db.dump"
  fi
done

echo "== nats stream YANTRA"
docker run --rm --network "$network" -v "$dir:/backup" "$nats_box" \
  nats --server nats://nats:4222 stream backup --no-progress YANTRA /backup/nats-YANTRA > /dev/null

echo "== minio objects"
"${compose[@]}" run --rm --no-deps -T --entrypoint tar minio -C /bitnami/minio/data -czf - . > "$dir/minio.tar.gz"

echo "== odoo filestore"
"${compose[@]}" run --rm --no-deps -T --entrypoint tar odoo -C /var/lib/odoo -czf - . > "$dir/odoo-filestore.tar.gz"

echo "took $(( $(date +%s) - start ))s; sizes:"
du -sh "$dir"/* | sed 's|'"$dir"'/||'
echo "$dir"
