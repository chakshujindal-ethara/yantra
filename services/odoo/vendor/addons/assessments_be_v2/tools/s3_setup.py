"""Install the S3 credentials and point the module at the assessment bucket.

    AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... \
      env -u PYTHONPATH .venv/bin/python src/odoo-bin shell \
      -c odoo.conf -d etp_local --no-http < custom_addons/assessments_be_v2/tools/s3_setup.py

Optional overrides (sensible defaults below):
    AWS_BUCKET   default ethara-etp-assessment
    AWS_REGION   default ap-south-1
    AWS_FOLDER   default assessments_be
    AWS_CDN_URL  default unset

Idempotent: re-running re-writes the same values and re-probes. Omit the two
credential variables to re-probe and re-point without touching the stored key.

WHY A SCRIPT AND NOT psql, exactly as with tools/vertex_setup.py: the module
keeps `s3_secret_key` in `ir.config_parameter` but ENCRYPTED (Fernet, keyed off
`database.secret`) and reads it back through `secret_store.get_secret`. A
plaintext INSERT would put the live secret in the database and every dump taken
from it, and `_client` would then fail to decrypt it anyway - the failure looks
like a credentials error, which sends you debugging IAM instead of storage.

The secret is never printed, never passed as argv, never echoed. Only
non-secret fields go out.

SHARING A BUCKET WITH etp_assessment_pro IS SAFE. Object keys are
`{folder}/{hint}-{uuid4}.{ext}` (services/s3_service.py::upload_b64), so two
modules writing the same bucket cannot collide even on the same prefix. The
default folder still differs from upstream's so the two are easy to tell apart
in the console.
"""

import os

from odoo.addons.assessments_be_v2.services import s3_service, secret_store

ICP = env["ir.config_parameter"].sudo()

SECRET_KEY_PARAM = "assessments_be_v2.s3_secret_key"
ACCESS_KEY_PARAM = "assessments_be_v2.s3_access_key_id"

DEFAULTS = {
    "assessments_be_v2.s3_bucket": os.environ.get(
        "AWS_BUCKET", "ethara-etp-assessment"),
    "assessments_be_v2.s3_region": os.environ.get("AWS_REGION", "ap-south-1"),
    "assessments_be_v2.s3_folder": os.environ.get("AWS_FOLDER",
                                                  "assessments_be"),
}

access_key = os.environ.get("AWS_ACCESS_KEY_ID", "").strip()
secret_key = os.environ.get("AWS_SECRET_ACCESS_KEY", "").strip()
cdn_url = os.environ.get("AWS_CDN_URL", "").strip()

for key, value in DEFAULTS.items():
    ICP.set_param(key, value)
    print(f"  {key} = {value}")

if cdn_url:
    ICP.set_param("assessments_be_v2.s3_cdn_url", cdn_url)
    print(f"  assessments_be_v2.s3_cdn_url = {cdn_url}")

if access_key and secret_key:
    ICP.set_param(ACCESS_KEY_PARAM, access_key)
    # Through secret_store, never set_param: see the module docstring.
    secret_store.set_secret(env, SECRET_KEY_PARAM, secret_key)
    print(f"  {ACCESS_KEY_PARAM} = {access_key[:4]}...{access_key[-4:]}")
    print(f"  {SECRET_KEY_PARAM} = <stored encrypted, "
          f"{len(secret_key)} chars>")
elif access_key or secret_key:
    print("\n! Both AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are needed to "
          "store credentials; neither was written.")
else:
    print("\n  No credentials in the environment - existing ones left alone.")

env.cr.commit()

# is_configured only checks that the parameters are present. The round trip
# below is what proves the credentials actually reach the bucket, which is the
# thing that silently fails later inside a cron nobody is watching.
print("\nconfigured:", s3_service.is_configured(env))
if s3_service.is_configured(env):
    try:
        client = s3_service._client(env)
        bucket = ICP.get_param("assessments_be_v2.s3_bucket")
        client.head_bucket(Bucket=bucket)
        print(f"reachable: yes - head_bucket on {bucket} succeeded")
    except Exception as exc:                                    # noqa: BLE001
        # Printed, not raised: a failed probe must not leave the credentials
        # half-written, and the message is the useful part.
        print(f"reachable: NO - {type(exc).__name__}: {exc}")
