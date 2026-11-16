"""Install the Vertex service account and point the module at usable models.

    ETP_SA_JSON=/path/to/key.json \
      env -u PYTHONPATH .venv/bin/python src/odoo-bin shell \
      -c odoo.conf -d ethara_ops --no-http < tools/vertex_setup.py

Idempotent: re-running with the same key is a no-op beyond re-probing. Pass no
ETP_SA_JSON to re-probe and re-point models without touching the stored key.

WHY A SCRIPT AND NOT psql: the JSON holds a live private key. The module keeps
it in `ir.config_parameter` but ENCRYPTED (Fernet, keyed off `database.secret`)
and reads it back through `secret_store.get_secret`. A plaintext INSERT would
put the key in the database and every dump taken from it, and `_minted_bearer`
would fail to decrypt it anyway.

The key is never printed, never passed as argv, never echoed. Only a path comes
in; only non-secret fields go out.
"""

import json
import os

from odoo.addons.assessments_be_v2.services import (
    model_catalog, secret_store, vertex,
)

ICP = env["ir.config_parameter"].sudo()
SA_KEY = "assessments_be_v2.vertex_service_account_json"

# STRONGEST FIRST. The probe keeps every model that answers and the role
# assignment below picks from the survivors, so this order is policy: authoring
# quality at the top, cheap-and-fast at the bottom.
#
# The 3.x entries are listed ahead of 2.5 deliberately. This list used to start
# at gemini-2.5-pro, which meant that pointing the module at a project entitled
# to the newer generation would probe, find 2.5, and WRITE 2.5 into the config -
# actively downgrading a better project. The 2.5 and 1.5 tail stays so a project
# without 3.x entitlement (which is what stage and prod have today) still
# resolves to something that works.
CANDIDATES = (
    "gemini-3.1-pro-preview",   # authoring quality; $2/$12 per 1M
    "gemini-3.8-flash",         # ~3x cheaper, newest Flash reasoning
    "gemini-3.1-flash",
    "gemini-3.1-flash-lite",    # 8x cheaper than 3.1-pro on BOTH in and out
    "gemini-2.5-pro",
    "gemini-2.5-flash",
    "gemini-2.5-flash-lite",
    "gemini-2.0-flash",
    "gemini-1.5-pro-002",
    "gemini-1.5-flash-002",
)

# Image generation is a DIFFERENT model family and must be probed separately.
# Leaving `image_model` unset does not fall back to something sensible: the
# code falls through to `vertex_model`, and if that is a TEXT model the render
# fails with "400 Multi-modal output is not supported" - an error that names the
# symptom and hides the cause.
#
# Cheapest-adequate first here, not strongest first: these all render the same
# briefs, and the price spread is 4x ($0.0336 Lite vs $0.134 Pro per 1K image).
# Re-order if a quality bench says otherwise.
IMAGE_CANDIDATES = (
    "gemini-3.1-flash-lite-image",   # Nano Banana 2 Lite, $0.0336 / 1K image
    "gemini-3.1-flash-image",        # Nano Banana 2,      $0.067  / 1K image
    "gemini-3-pro-image",            # Nano Banana Pro,    $0.134  / 1K image
    "gemini-2.5-flash-image",
    "gemini-2.0-flash-preview-image-generation",
)

# Veo is NOT probed. Every Veo call renders a real clip and bills per second, so
# a probe would cost money to answer a question the catalog already answers.
# The configured value is validated against the pricing catalog instead.
VIDEO_CANDIDATES = (
    "veo-3.1-generate-001",        # $0.40/s
    "veo-3.1-fast-generate-001",   # $0.15/s
    "veo-3.1-lite-generate-001",   # $0.05/s, preview at time of writing
)


def install(path):
    """Store the key encrypted, derive project id, invalidate cached tokens."""
    with open(path, "r", encoding="utf-8") as fh:
        raw = fh.read()
    sa = json.loads(raw)
    if sa.get("type") != "service_account" or not sa.get("private_key"):
        return "not_a_service_account", None

    secret_store.set_secret(env, SA_KEY, raw)
    ICP.set_param("assessments_be_v2.vertex_service_account_filename",
                  os.path.basename(path))
    ICP.set_param("assessments_be_v2.vertex_project_id", sa["project_id"])
    # Not in the JSON, and no safe universal default. us-central1 carries the
    # widest model availability, Veo included.
    if not ICP.get_param("assessments_be_v2.vertex_location"):
        ICP.set_param("assessments_be_v2.vertex_location", "us-central1")
    # A token minted against a PREVIOUS key must not survive a key swap.
    ICP.set_param("assessments_be_v2.vertex_minted_token", "")
    ICP.set_param("assessments_be_v2.vertex_minted_token_expires", "0")
    # Record the key fingerprint and mark the project id as ADOPTED FROM THIS
    # KEY. Both are what lets the next swap re-point the project automatically
    # instead of authenticating as the new service account against the old
    # project - see vertex._sync_service_account_identity.
    ICP.set_param(vertex.SA_FINGERPRINT_PARAM, vertex._sa_fingerprint(sa))
    ICP.set_param(vertex.SA_PROJECT_SOURCE_PARAM, sa["project_id"])
    env.cr.commit()

    # A stored secret that cannot be decrypted is worse than one never stored:
    # it fails at generation time, not here. So prove the round trip.
    back = secret_store.get_secret(env, SA_KEY, "")
    ok = json.loads(back).get("client_email") == sa["client_email"]
    return ("installed" if ok else "roundtrip_failed"), sa["client_email"]


def usable(models, image=False):
    """Which candidates does this project answer on? Measured, not assumed."""
    project, location = vertex._vertex_creds(env)[:2]
    client = vertex._httpx()
    body = {"contents": [{"role": "user", "parts": [{"text": "hi"}]}],
            "generationConfig": {"maxOutputTokens": 16}}
    if image:
        # An image model must be asked for an image, or it answers as text and
        # a text model would pass a probe it cannot actually serve.
        body["generationConfig"] = {"responseModalities": ["TEXT", "IMAGE"]}
    found = []
    for model in models:
        url = ("https://%s-aiplatform.googleapis.com/v1/projects/%s"
               "/locations/%s/publishers/google/models/%s:generateContent"
               % (location, project, location, model))
        try:
            r = client.post(url,
                            headers={"Authorization": "Bearer %s" % token},
                            json=body, timeout=60)
        except Exception as exc:                                # noqa: BLE001
            print("  ERR   %-22s %s" % (model, type(exc).__name__))
            continue
        print("  %-5s %-22s" % ("OK" if r.status_code == 200 else r.status_code,
                                model))
        if r.status_code == 200:
            found.append(model)
    return found


sa_path = os.environ.get("ETP_SA_JSON", "").strip()
if sa_path:
    if not os.path.exists(sa_path):
        print("RESULT missing_sa_json")
        raise SystemExit
    state, email = install(sa_path)
    print("RESULT %s email=%s" % (state, email))
    if state != "installed":
        raise SystemExit

print("PROJECT %s  LOCATION %s" % vertex._vertex_creds(env)[:2])
print("ENCRYPTED %s" % ICP.get_param(SA_KEY, "").startswith("enc:v1:"))

token = vertex._minted_bearer(env)
if not token:
    print("MINT failed - no usable service account")
    raise SystemExit
print("MINT ok len=%d" % len(token))

print("\nTEXT models:")
models = usable(CANDIDATES)
if not models:
    print("MODELS none reachable - check project entitlement")
    raise SystemExit

# The module's compiled-in defaults (gemini-3-*) 404 without entitlement.
# These are config overrides, NOT source edits: the constants stay correct for
# projects that do have the newer models.
#
# `models` is CANDIDATES order filtered to what answered, so index 0 is the
# strongest reachable and index -1 the cheapest. Roles are assigned by what the
# lane actually needs rather than by one best/cheap split:
#   generation - authors from the SOP PDF, wants the strongest
#   scoring    - the RECURRING cost, and the one to bench before trusting cheap
#   utility    - bulk tags/vocab/skill labels, always the cheapest
#   detection  - reads an image, returns JSON; cheap is fine
#   fallback   - must DIFFER from the primary or it is not a fallback
best, cheap = models[0], models[-1]
second = models[1] if len(models) > 1 else best
roles = {
    "vertex_model": best,
    "generation_model": best,
    # Left at the generation model on purpose. Grading quality is the one thing
    # a probe cannot measure, so this script will not silently move the judge to
    # a cheaper model - set `scoring_model` by hand once you have benched it.
    "scoring_model": best,
    "utility_model": cheap,
    "detection_model": cheap,
    "fallback_model": second if second != best else "",
}
for key, value in roles.items():
    ICP.set_param("assessments_be_v2.%s" % key, value)

print("\nIMAGE models:")
images = usable(IMAGE_CANDIDATES, image=True)
if images:
    ICP.set_param("assessments_be_v2.image_model", images[0])
else:
    # Explicitly blank rather than left stale: a wrong image model produces
    # "400 Multi-modal output is not supported" at render time, which reads as
    # a bug rather than as missing entitlement.
    ICP.set_param("assessments_be_v2.image_model", "")

env.cr.commit()

print("\nCONFIGURED")
for key in ("vertex_model", "generation_model", "scoring_model",
            "utility_model", "detection_model", "fallback_model",
            "image_model", "video_model"):
    value = ICP.get_param("assessments_be_v2.%s" % key, "") or ""
    print("  %-18s %s" % (key, value or "(unset)"))

# A model missing from the pricing catalog bills at a deliberately pessimistic
# default, which keeps the daily spend cap honest but misreports the ledger.
# Surface it HERE, at configuration time, rather than in a month-end invoice.
print("\nPRICING COVERAGE (services/model_catalog.py)")
unpriced = []
for key in ("vertex_model", "generation_model", "scoring_model",
            "utility_model", "detection_model", "fallback_model",
            "image_model"):
    name = ICP.get_param("assessments_be_v2.%s" % key, "") or ""
    if not name:
        continue
    # `price_is_known`, not a comparison against the default: the pessimistic
    # default is set at real Nano Banana Pro rates, so a fallen-through price
    # is numerically identical to a correct one.
    known = model_catalog.price_is_known(name)
    price = model_catalog.price_for(name)
    print("  %-18s %-32s %s in=$%.2f out=$%.2f image=$%.4f"
          % (key, name, "OK   " if known else "GUESS",
             price["in"], price["out"], price.get("image", 0.0)))
    if not known:
        unpriced.append(name)

video = ICP.get_param("assessments_be_v2.video_model", "") or ""
if video:
    rate = model_catalog.video_rate_for(video)
    known = model_catalog.video_rate_is_known(video)
    print("  %-18s %-32s %s $%.3f/s  (2 clips x 8s = $%.2f)"
          % ("video_model", video, "OK   " if known else "GUESS", rate,
             rate * 16))
    if not known:
        unpriced.append(video)

if unpriced:
    print("\nWARNING these models have NO catalog price: %s"
          % ", ".join(sorted(set(unpriced))))
    print("        They bill at the pessimistic default, so the cost ledger "
          "over-reports\n        and the $/day cap is enforced on a guess. Add "
          "a row to\n        services/model_catalog.py.")

if not images:
    print("\nNOTE image question types cannot be generated on this project")
print("\nNOTE Veo is never probed - a probe renders a real clip and bills for "
      "it.\n     Set video_model by hand from: %s" % ", ".join(VIDEO_CANDIDATES))
