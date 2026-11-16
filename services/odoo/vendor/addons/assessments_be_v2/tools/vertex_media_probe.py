"""What image and video models can this project actually reach? Read-only.

    env -u PYTHONPATH .venv/bin/python src/odoo-bin shell \
      -c odoo.conf -d ethara_ops --no-http < tools/vertex_media_probe.py

WHY THIS EXISTS: "no image or video entitlement" was once concluded from ONE
404 on the module's default (`gemini-3-pro-image`). That was wrong. Image and
video are three different families on two different endpoint shapes, and a 404
on one says nothing about the others:

    Imagen  -> :predict            (publishers/google/models/imagen-*)
    Gemini  -> :generateContent    (responseModalities: [TEXT, IMAGE])
    Veo     -> :predictLongRunning (and not in every region)

So each family is probed on its own path, Veo across regions, and the module's
own `generate_image()` is exercised at the end - because a raw 200 proves the
endpoint answers, not that the module can parse what comes back.

Reads the wire only: writes no config, saves no file, passes no `usage_ctx`, so
it neither bills the LLM ledger nor litters the filestore.
"""

import base64

from odoo.addons.assessments_be_v2.services import vertex

ICP = env["ir.config_parameter"].sudo()
project, location = vertex._vertex_creds(env)[:2]
token = vertex._minted_bearer(env)
client = vertex._httpx()

if not token:
    print("MINT failed - no usable service account")
    raise SystemExit

# Veo is not available in every region even when the project is entitled, which
# is why the module keeps a `_video_location` separate from the text one.
# `global` FIRST because it is what the module is configured with and what the
# stage instance uses. Omitting it is why an earlier run of this probe reported
# "no Veo entitlement": every regional endpoint 404s for models that are only
# served globally, which looks identical to a missing grant.
VIDEO_LOCATIONS = ("global", "us-central1", "us-east4", "europe-west4")

IMAGE_BODY = {"contents": [{"role": "user", "parts": [{"text": "a red circle"}]}],
              "generationConfig": {"responseModalities": ["TEXT", "IMAGE"]}}
IMAGEN_BODY = {"instances": [{"prompt": "a red circle on white"}],
               "parameters": {"sampleCount": 1}}
VEO_BODY = {"instances": [{"prompt": "a red circle rotating"}],
            "parameters": {"sampleCount": 1, "durationSeconds": 4}}


def probe(model, verb, body, loc=None):
    """POST once and report the status. 404 = absent, 403 = IAM, 429 = a PASS."""
    loc = loc or location
    # `global` is served from the BARE host; every other region prefixes it.
    # Building `global-aiplatform.googleapis.com` resolves to nothing, and the
    # connection error was being reported as a plain failure - which is how
    # this probe previously concluded "no Veo entitlement" for a project whose
    # veo-3.1 endpoint answers 200.
    host = ("aiplatform.googleapis.com" if loc == "global"
            else "%s-aiplatform.googleapis.com" % loc)
    url = ("https://%s/v1/projects/%s/locations/%s"
           "/publishers/google/models/%s:%s" % (host, project, loc, model, verb))
    try:
        r = client.post(url, headers={"Authorization": "Bearer %s" % token},
                        json=body, timeout=90)
        return r.status_code
    except Exception as exc:                                    # noqa: BLE001
        return type(exc).__name__[:8]


print("PROJECT %s  LOCATION %s\n" % (project, location))

print("== IMAGE ==")
reachable = []
for model, verb, body in (
        ("imagen-4.0-generate-001", "predict", IMAGEN_BODY),
        ("imagen-3.0-generate-002", "predict", IMAGEN_BODY),
        ("gemini-2.5-flash-image", "generateContent", IMAGE_BODY),
        ("gemini-3-pro-image", "generateContent", IMAGE_BODY)):
    code = probe(model, verb, body)
    print("  %-5s %s" % (code, model))
    if code == 200:
        reachable.append(model)

print("\n== VIDEO (Veo) ==")
print("  %-26s %s" % ("MODEL", "  ".join("%-14s" % l for l in VIDEO_LOCATIONS)))
veo = []
for model in ("veo-3.1-generate-001", "veo-3.1-generate-preview",
              "veo-3.0-generate-001",
              "veo-2.0-generate-001"):
    row = []
    for loc in VIDEO_LOCATIONS:
        code = probe(model, "predictLongRunning", VEO_BODY, loc=loc)
        row.append(str(code))
        if code in (200, 429):
            veo.append("%s @ %s" % (model, loc))
    print("  %-26s %s" % (model, "  ".join("%-14s" % c for c in row)))

print("\n== The module's OWN image path ==")
print("  configured: %s" % (ICP.get_param("assessments_be_v2.image_model")
                            or "(falls back to the text model - will 400)"))
try:
    out = vertex.generate_image(
        env,
        image_prompt="A weathered wooden crate on a concrete warehouse "
                     "floor, overhead light, photographic.",
        aspect_hint="1:1",
    )
    # Shape varies by version: bytes, base64 str, dict, or (data, mime) tuple.
    data = out
    if isinstance(data, (tuple, list)):
        data = next((x for x in data if isinstance(x, (bytes, bytearray))),
                    data[0])
    if isinstance(data, dict):
        data = data.get("bytes") or data.get("data") or data.get("image") or b""
    if isinstance(data, str):
        data = base64.b64decode(data)
    magic = bytes(data or b"")[:4]
    real = len(data or b"") > 1000 and (magic.startswith(b"\x89PNG")
                                        or magic.startswith(b"\xff\xd8\xff"))
    print("  generate_image -> %d bytes, png=%s"
          % (len(data or b""), magic.startswith(b"\x89PNG")))
    print("IMAGE %s" % ("works" if real else "returned no usable image"))
except Exception as exc:                                        # noqa: BLE001
    msg = str(exc)
    print("  generate_image failed %s: %s" % (type(exc).__name__, msg[:200]))
    # A safety/recitation refusal is the MODEL declining one prompt, not a
    # broken path: auth, region and model resolution all had to work to get
    # far enough to be refused. Reporting it as "broken" made this probe
    # contradict itself, printing 200 for the same model two lines earlier.
    declined = any(w in msg for w in ("RECITATION", "SAFETY", "PROHIBITED",
                                      "BLOCKLIST", "finishReason"))
    print("IMAGE %s" % ("reachable, model declined this prompt" if declined
                        else "broken"))

print("VIDEO %s" % (", ".join(veo) if veo else
                    "no Veo entitlement in any probed region"))
