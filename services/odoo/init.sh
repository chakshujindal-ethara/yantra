#!/bin/bash
# One-shot initialisation of the local Odoo, run on every `up` (cheap after the first):
#   1. install the Yantra bridge, Ethara's token gateway and Assessment v2 (vendor/), and the assessment bridge;
#   2. upgrade them when the code on disk changed since the last run (a fingerprint of the addon trees);
#   3. seed what the rig needs: the chart of accounts, the admin in the Yantra group, the gateway and Keycloak
#      settings, and Assessment v2's settings (MinIO, Redis, Mailpit, the app's origins; no seeded passwords).
set -euo pipefail
DSN="host=${HOST} user=${USER} password=${PASSWORD} dbname=odoo"
DB=(--db_host="${HOST}" --db_port="${PORT:-5432}" --db_user="${USER}" --db_password="${PASSWORD}")
until psql "host=${HOST} user=${USER} password=${PASSWORD} dbname=postgres" -tc "select 1" > /dev/null 2>&1; do sleep 1; done

MODULES="yantra_bridge,api_auth_gateway,assessments_be_v2"
if [[ -d /mnt/yantra-addons/yantra_assess_bridge ]]; then
  MODULES="${MODULES},yantra_assess_bridge"
fi
# what is on disk now, against what was installed or upgraded last time (stored in the database)
FINGERPRINT=$(cd /mnt && find yantra-addons vendor-addons -type f ! -name '*.pyc' ! -path '*/__pycache__/*' -print0 \
  | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)
# yantra_bridge,api_auth_gateway -> 'yantra_bridge','api_auth_gateway' (printf, not ${//}: bash versions quote that differently)
IN_LIST=$(IFS=,; printf "'%s'," ${MODULES})
IN_LIST=${IN_LIST%,}
installed() {
  psql "${DSN}" -tAc "select count(*) from ir_module_module where name in (${IN_LIST}) and state='installed'" \
    2> /dev/null || echo 0
}
recorded() {
  psql "${DSN}" -tAc "select value from ir_config_parameter where key='yantra.addons_fingerprint'" 2> /dev/null || true
}
wanted=$(echo "${MODULES}" | tr ',' '\n' | wc -l | tr -d ' ')
if [[ "$(installed)" != "${wanted}" ]]; then
  echo "installing ${MODULES}"
  odoo "${DB[@]}" -d odoo -i "${MODULES}" --stop-after-init --no-http
elif [[ "$(recorded)" != "${FINGERPRINT}" ]]; then
  echo "upgrading ${MODULES} (the addons changed on disk)"
  odoo "${DB[@]}" -d odoo -u "${MODULES}" --stop-after-init --no-http
fi

echo "seeding settings"
YANTRA_ADDONS_FINGERPRINT="${FINGERPRINT}" odoo shell "${DB[@]}" -d odoo --no-http <<'PY'
import os

env = self.env  # noqa: F821 - `self` is the shell's env holder
company = env.company
if not company.chart_template:
    env["account.chart.template"].try_loading("generic_coa", company=company, install_demo=False)
admin = env.ref("base.user_admin")
group = env.ref("yantra_bridge.group_yantra_ops")
if group not in admin.group_ids:
    admin.write({"group_ids": [(4, group.id)]})
params = env["ir.config_parameter"].sudo()
e = os.environ.get


def put(key, value):
    if value is not None and value != "":
        params.set_param(key, value)


for key, value in {
    "yantra.gateway_url": e("YANTRA_GATEWAY_URL", "http://gateway:8090"),
    "yantra.keycloak_url": e("YANTRA_KEYCLOAK_URL", "http://keycloak:8080"),
    "yantra.keycloak_client_id": e("YANTRA_KEYCLOAK_CLIENT_ID", "yantra-odoo"),
    "yantra.keycloak_client_secret": e("YANTRA_KEYCLOAK_CLIENT_SECRET", ""),
    "yantra.default_tds_rate": e("YANTRA_DEFAULT_TDS_RATE", "10.0"),
}.items():
    put(key, value)

# Assessment v2. Odoo's own address (links in v2's mails and media URLs), frozen so a request through the exam app's
# proxy never rewrites it.
put("web.base.url", e("YANTRA_ODOO_PUBLIC_URL", "http://localhost:8069"))
put("web.base.url.freeze", "True")
app = e("YANTRA_ASSESS_APP_URL", "http://localhost:8096")
v2 = "assessments_be_v2."
for key, value in {
    "cors_origins": app,
    "candidate_app_base_url": app,
    "password_reset_url": f"{app}/reset-password",
    # a worker signs in through Yantra (Keycloak); v2 never seeds or mails a password
    "seed_candidate_password": "0",
    # MinIO: the server talks to it inside the network, a browser at the published port (Yantra patch 0002)
    "s3_bucket": e("YANTRA_ASSESS_S3_BUCKET", "yantra-assess"),
    "s3_access_key_id": e("YANTRA_ASSESS_S3_ACCESS_KEY", "yantra"),
    "s3_region": e("YANTRA_ASSESS_S3_REGION", "us-east-1"),
    "s3_folder": e("YANTRA_ASSESS_S3_FOLDER", "assess"),
    "s3_endpoint_url": e("YANTRA_ASSESS_S3_ENDPOINT", "http://minio:9000"),
    "s3_public_endpoint_url": e("YANTRA_ASSESS_S3_PUBLIC_ENDPOINT", "http://localhost:9000"),
    "redis_url": e("YANTRA_ASSESS_REDIS_URL", "redis://redis:6379/2"),
}.items():
    put(v2 + key, value)
# stored URLs of uploaded media are the public bucket URL, so v2 recognises them as its own and presigns them
public = e("YANTRA_ASSESS_S3_PUBLIC_ENDPOINT", "http://localhost:9000").rstrip("/")
put(v2 + "s3_cdn_url", f"{public}/{e('YANTRA_ASSESS_S3_BUCKET', 'yantra-assess')}")

from odoo.addons.assessments_be_v2.services import secret_store  # noqa: E402

if e("YANTRA_ASSESS_S3_SECRET_KEY"):
    secret_store.set_secret(env, v2 + "s3_secret_key", e("YANTRA_ASSESS_S3_SECRET_KEY"))
# Vertex AI (paper generation from an SOP, LLM marking, images and video): only when a service account is mounted
sa_file = e("YANTRA_VERTEX_SA_JSON_FILE")
if sa_file and os.path.isfile(sa_file):
    secret_store.set_secret(env, v2 + "vertex_service_account_json", open(sa_file).read())
    put(v2 + "vertex_service_account_filename", os.path.basename(sa_file))

# outgoing mail to Mailpit on the rig
smtp_host = e("YANTRA_SMTP_HOST", "mailpit")
if smtp_host and not env["ir.mail_server"].sudo().search([("smtp_host", "=", smtp_host)], limit=1):
    env["ir.mail_server"].sudo().create({
        "name": smtp_host,
        "smtp_host": smtp_host,
        "smtp_port": int(e("YANTRA_SMTP_PORT", "1025")),
        "smtp_encryption": "none",
    })
put("mail.catchall.domain", e("YANTRA_MAIL_DOMAIN", "yantra.local"))
put("mail.default.from", "no-reply")

# the assessment bridge (Keycloak service client, ticket lifetimes, Yantra's origin)
for key, value in {
    "keycloak_issuer": e("YANTRA_ASSESS_KEYCLOAK_ISSUER", "http://localhost:8180/realms/yantra"),
    "jwks_url": e("YANTRA_ASSESS_JWKS_URL", "http://keycloak:8080/realms/yantra/protocol/openid-connect/certs"),
    "service_client_id": e("YANTRA_ASSESS_CLIENT_ID", "yantra-assess"),
    "app_url": app,
    "return_origins": e("YANTRA_APP_URL", "http://localhost:8095"),
    "suppress_invitations": "1",
    "ticket_ttl_seconds": "120",
}.items():
    put("yantra_assess_bridge." + key, value)

params.set_param("yantra.addons_fingerprint", e("YANTRA_ADDONS_FINGERPRINT"))
env.cr.commit()
print("seeded")
PY
