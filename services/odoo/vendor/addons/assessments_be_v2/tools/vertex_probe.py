"""Prove the Vertex credential works, end to end. Read-only.

    env -u PYTHONPATH .venv/bin/python src/odoo-bin shell \
      -c odoo.conf -d ethara_ops --no-http < tools/vertex_probe.py

"It is configured" is not "it works". This mints a real bearer token and makes
one real generateContent call through the module's OWN path, because the
failure modes that matter - wrong project, API disabled, key missing the
aiplatform role, PyJWT/crypto absent, model not entitled - all look identical
from the database and only surface on the wire.

Prints no secret: token length only, never its value. Passes no `usage_ctx`,
so a diagnostic never bills the LLM ledger or pollutes the budget screen.
"""

from odoo.addons.assessments_be_v2.services import vertex

ICP = env["ir.config_parameter"].sudo()
project, location = vertex._vertex_creds(env)[:2]

print("PROJECT %s" % project)
print("LOCATION %s" % location)
print("MODEL %s" % (ICP.get_param("assessments_be_v2.generation_model")
                    or "(module default)"))
print("ENCRYPTED %s" % ICP.get_param(
    "assessments_be_v2.vertex_service_account_json", "").startswith("enc:v1:"))

try:
    token = vertex._minted_bearer(env)
except Exception as exc:                                        # noqa: BLE001
    print("MINT failed %s: %s" % (type(exc).__name__, exc))
    raise SystemExit

if not token:
    print("MINT empty - no service account resolved")
    raise SystemExit
print("MINT ok len=%d" % len(token))

try:
    out = vertex._call_vertex_single(
        env,
        system_prompt="Answer with one word.",
        user_text="Reply with the single word: ready",
        # Not 16: gemini-2.5-pro spends an internal thinking budget before
        # emitting text, so a tight cap returns finishReason MAX_TOKENS with no
        # content and reads as a refusal.
        max_tokens=2048,
    )
    text = out[0] if isinstance(out, (tuple, list)) else out
    if isinstance(text, dict):
        text = text.get("text") or text
    print("CALL ok reply=%r" % str(text).strip()[:80])
except Exception as exc:                                        # noqa: BLE001
    print("CALL failed %s: %s" % (type(exc).__name__, str(exc)[:300]))
