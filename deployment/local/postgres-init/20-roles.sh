#!/bin/sh
# The local rig's per-deployable roles (deployment/sql/roles.sql), with the rig's own passwords. Runs once, on a
# fresh volume, after 10-keycloak.sql. A deployed database gets the same file and passwords from the secret store.
set -eu
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -f /yantra-sql/roles.sql
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'SQL'
ALTER ROLE yantra_work PASSWORD 'yantra_work';
ALTER ROLE yantra_money PASSWORD 'yantra_money';
SQL
