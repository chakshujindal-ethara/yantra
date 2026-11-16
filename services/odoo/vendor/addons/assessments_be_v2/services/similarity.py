# -*- coding: utf-8 -*-
"""SOP similarity mapping — 1:1 port of the research harness ``similar.py``.

Answers "how close is this new SOP to what we already run?" with a percentage
per project, so a duplicate, a sibling (whose renderer / cutoff / worker pool
carries over), or genuinely new territory is visible BEFORE paying for a full
generation run.

    final = 0.30 * lexical + 0.70 * semantic

WHY HYBRID (verbatim from research). ``mapping`` is authored by a model, so its
wording drifts between runs: one run writes ``domain:image-annotation``, another
``domain:ui-annotation`` for the same kind of work. String overlap alone
therefore under-reads real siblings. So:

  LEXICAL   deterministic faceted overlap on the mapping array. Free, offline,
            reproducible, and it shows exactly which facet values matched. Exact
            value hits score 1.0; shared word-stems score partial, so annotation
            wording drift still registers.
  SEMANTIC  one model call under ``prompts/mapping.md`` — matches values BY
            MEANING and returns per-facet scores + a plain reason per project.

Semantic leads because it survives the drift; lexical anchors the number to
something auditable and keeps it honest when the model is generous.

PARITY NOTE (logged divergence): the harness ``similar.py`` bundles Excel export,
terminal box-drawing, an ``_index.json`` filesystem cache and a ``--matrix`` CLI.
Per the research ODOO19_HANDOFF §10 those ~350 lines "disappear in Odoo": the
ORM ``mapping_json`` field IS the index, and the ``assessments.be.similarity``
model + a native pivot view IS the matrix + xlsx export. What is kept here is the
ACTUAL ALGORITHM — ``_facets``, ``_vsim``, ``lexical_score``, ``facet_breakdown``,
``_evidence_line``, ``semantic_rank``, ``_band``, ``card_from_prompt`` — verbatim,
so the numbers match the harness bit-for-bit (validated: proj-3 -> omni-elo 61%
lexical, identical to the harness offline matrix).
"""

import json
import logging
import re

_logger = logging.getLogger(__name__)

# Facet weights — the SAME ones prompts/mapping.md scores with, so the
# deterministic half and the model half weigh the profile identically. Ported
# verbatim from research similar.py::WEIGHTS.
WEIGHTS = {"task": 0.30, "skill": 0.25, "domain": 0.20, "modality": 0.20,
           "output-format": 0.05}
BLEND_LEXICAL = 0.30
BLEND_SEMANTIC = 0.70

# Band cutoffs (research _band): a LABEL on the number, never a shade OF it.
BAND_NEAR_DUPLICATE = 75
BAND_SAME_FAMILY = 40


# lexical (deterministic)

def _facets(mapping):
    """['domain:image-evaluation', ...] -> {'domain': {'image-evaluation'}, ...}"""
    out = {}
    for entry in mapping or []:
        if not isinstance(entry, str) or ":" not in entry:
            continue
        facet, value = entry.split(":", 1)
        facet, value = facet.strip().lower(), value.strip().lower()
        if facet == "other" or not value:
            continue
        out.setdefault(facet, set()).add(value)
    return out


def _vsim(a, b):
    """Value similarity: exact hit, else shared word-stems.

    ui-annotation vs image-annotation share 'annotation' -> partial credit,
    which is exactly the model-authored wording drift a pure string match misses.
    """
    if a == b:
        return 1.0
    ta, tb = set(a.split("-")), set(b.split("-"))
    inter = ta & tb
    return len(inter) / len(ta | tb) if inter else 0.0


def lexical_score(card_a, card_b):
    """Weighted faceted overlap -> (0..1, [matched facet:value strings]).

    Per facet: greedily pair each value with its best counterpart and divide by
    the LARGER value set, so padding a profile with extra values can never
    inflate it. Weights are renormalised over the facets actually present, so a
    profile that simply omits output-format is not silently capped below 1.0.
    """
    fa, fb = _facets(card_a.get("mapping")), _facets(card_b.get("mapping"))
    total, used, matched = 0.0, 0.0, []
    for facet in set(fa) | set(fb):
        w = WEIGHTS.get(facet, 0.05)
        used += w
        A, B = fa.get(facet, set()), fb.get(facet, set())
        if not A or not B:
            continue
        got = 0.0
        for a in A:
            best, partner = 0.0, None
            for b in B:
                s = _vsim(a, b)
                if s > best:
                    best, partner = s, b
            got += best
            if best >= 0.999:
                matched.append("%s:%s" % (facet, a))
            elif best > 0:
                matched.append("%s:%s~%s" % (facet, a, partner))
        total += w * (got / max(len(A), len(B)))
    base = total / used if used else 0.0
    ta, tb = set(card_a.get("tags") or []), set(card_b.get("tags") or [])
    tag_j = len(ta & tb) / len(ta | tb) if (ta | tb) else 0.0
    return 0.9 * base + 0.1 * tag_j, sorted(matched)


def facet_breakdown(card_a, card_b):
    """Per-facet evidence for a pair: what matched, what did not, and by how much.

    Computed, not asserted, so the percentage can be defended without trusting
    the model: every point of the lexical half traces back to a line here.
    """
    fa, fb = _facets(card_a.get("mapping")), _facets(card_b.get("mapping"))
    rows = []
    for facet in ("task", "skill", "domain", "modality", "output-format"):
        A, B = fa.get(facet, set()), fb.get(facet, set())
        if not A and not B:
            continue
        sim = 0.0
        if A and B:
            sim = sum(max(_vsim(x, y) for y in B) for x in A) / max(len(A), len(B))
        rows.append({"facet": facet, "weight": WEIGHTS.get(facet, 0.05),
                     "sim": round(sim, 2), "a": sorted(A), "b": sorted(B),
                     "status": ("match" if sim >= 0.99 else "partial" if sim > 0
                                else "absent one side" if not (A and B)
                                else "differs")})
    return rows


def _evidence_line(breakdown):
    """One plain sentence of the computed evidence: what is shared, what diverges."""
    shared = [r["facet"] for r in breakdown if r["sim"] >= 0.99]
    part = [r["facet"] for r in breakdown if 0 < r["sim"] < 0.99]
    diff = [r for r in breakdown if r["sim"] == 0 and r["a"] and r["b"]]
    bits = []
    if shared:
        bits.append("same " + ", ".join(shared))
    if part:
        bits.append("partial " + ", ".join(part))

    def _vals(vs, n=38):
        s = "/".join(vs)
        return s if len(s) <= n else s[:n - 1].rstrip("-/") + "\u2026"

    for r in diff[:2]:
        bits.append("%s differs (%s vs %s)" % (r["facet"], _vals(r["a"]), _vals(r["b"])))
    return "; ".join(bits) if bits else "no facet overlap"


def _band(pct):
    """A label on the number — never a judgment that shades it (research _band)."""
    if pct >= BAND_NEAR_DUPLICATE:
        return "near-duplicate"
    if pct >= BAND_SAME_FAMILY:
        return "same-family"
    return "new-territory"


# semantic (model)

_CARD_ONLY = """
THE NEW CARD IS ALREADY EXTRACTED and given below. SKIP STEP 1 — do not re-profile,
do not invent evidence, use this card exactly as given. Begin at STEP 2 and match its
values against every library card BY MEANING.

===== THE NEW CARD =====
%s
"""

_ASK = ("\nCompare the new SOP against every library card and rank them. Return ONE "
        "JSON object exactly as the OUTPUT section specifies. Every library project "
        "must appear in comparisons, including the zeros."
        "\n\nEVERY comparison carries a `note` that JUSTIFIES ITS OWN NUMBER — not only "
        "the top match. Each note names the concrete facet values that are shared and "
        "the specific ones that diverge, in plain words, so a reader can see why that "
        "score is what it is and not ten points higher or lower. Write it as one or two "
        "plain sentences. A note that would fit any pair, such as 'these projects are "
        "somewhat related', is not acceptable — cite the actual values. A low score "
        "needs its reason stated just as clearly as a high one.")


def _first_json(text):
    """First complete JSON object in a model reply (tolerates fences / trailing prose)."""
    if not text:
        return None
    t = re.sub(r"```$", "", re.sub(r"^```(?:json)?", "", text.strip())).strip()
    start = t.find("{")
    if start < 0:
        return None
    depth, instr, esc = 0, False, False
    for i, ch in enumerate(t[start:], start):
        if instr:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                instr = False
            continue
        if ch == '"':
            instr = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                try:
                    return json.loads(t[start:i + 1])
                except Exception:
                    return None
    return None


def semantic_rank(env, new_card, library, usage_ctx=None):
    """One call under prompts/mapping.md -> {project: {overall, per_facet, matches, note}}.

    Matching by meaning is the whole point: it recognises that two runs wrote
    different words for the same kind of work. Retry x3 — an occasional reply
    comes back truncated or wrapped in prose, and a silently empty ranking is
    worse than a slower one. Returns ``(scores, extracted_new_sop, summary)``;
    ``scores`` is EMPTY on total failure so the caller degrades to lexical.
    """
    from . import vertex
    system = _get_mapping_prompt(env)
    slim = [{k: c.get(k) for k in ("project", "sop_title", "summary", "mapping",
                                   "tags", "question_types") if k in c}
            for c in library]
    clean = {k: v for k, v in new_card.items() if not k.startswith("_")}
    parts = [
        {"text": _CARD_ONLY % json.dumps(clean, indent=1)},
        {"text": "\n===== THE LIBRARY (existing project cards) =====\n"
                 + json.dumps({"library": slim}, indent=1)},
        {"text": _ASK},
    ]
    obj = {}
    for attempt in range(3):
        try:
            raw = vertex._call_vertex(
                env, system, user_text="", user_parts=parts,
                model=vertex._generation_model(env), max_tokens=24000,
                temperature=0.2, response_json=True, usage_ctx=usage_ctx)
        except Exception as exc:  # noqa: BLE001 — degrade to lexical, never crash a page
            _logger.warning("similarity semantic attempt %d failed: %s",
                            attempt + 1, repr(exc)[:200])
            continue
        obj = _first_json(raw) or {}
        if obj.get("comparisons"):
            break
        _logger.warning("similarity semantic attempt %d: no comparisons "
                        "(%d chars, parsed=%s) — retrying",
                        attempt + 1, len(raw or ""), list(obj)[:4])
    out = {}
    for c in obj.get("comparisons") or []:
        name = c.get("project") or c.get("name")
        if not name:
            continue
        sc = c.get("overall", c.get("score", c.get("similarity", 0))) or 0
        try:
            sc = float(sc)
        except Exception:
            sc = 0.0
        out[str(name).split(" (")[0].strip()] = {
            "overall": sc if sc <= 1 else sc / 100.0,
            "per_facet": c.get("per_facet") or {},
            "matches": c.get("matches") or [],
            "note": c.get("note") or "",
            "band": c.get("band") or "",
        }
    return out, obj.get("new_sop") or {}, obj.get("top_match_summary") or ""


def _get_mapping_prompt(env):
    """The SOP-mapping comparator prompt (research prompts/tags.md, shipped here as
    prompts/mapping.md so it never collides with our tag+knowledge extraction
    prompt which ALSO lives at prompts/tags.md). Config-param overridable."""
    from . import vertex
    p = (env["ir.config_parameter"].sudo().get_param(
        "assessments_be_v2.mapping_prompt", "") or "").strip()
    if p:
        return p
    bundled = vertex._load_bundled_prompt("mapping.md")
    return bundled.strip() if bundled.strip() else _MAPPING_PROMPT_FALLBACK


# Odoo card + blend glue

def card_from_prompt(prompt):
    """The Odoo analogue of research card_from_meta: reduce a generator to the
    minimum a similarity comparison needs, read straight off queryable fields.

    ``mapping`` is the load-bearing faceted array (mapping_json); ``tags`` are the
    light 10% corroborating signal (plain_tags). A generator with no mapping is
    NOT a valid library card — the caller skips it, exactly as research skips a
    project with an empty mapping."""
    mapping = []
    raw = prompt.mapping_json or ""
    if raw:
        try:
            data = json.loads(raw)
            if isinstance(data, list):
                mapping = [m for m in data if isinstance(m, str)]
        except Exception:
            mapping = []
    tags = []
    if prompt.plain_tags:
        tags = [t.strip() for t in prompt.plain_tags.split(",") if t.strip()]
    qtypes = sorted({q.question_type for q in prompt.question_ids if q.question_type})
    return {
        "project": prompt.id,
        "sop_title": prompt.sop_title or prompt.name or "",
        "summary": (prompt.sop_summary or "")[:700],
        "mapping": mapping,
        "tags": tags,
        "question_types": qtypes,
    }


def blend(lexical01, semantic01):
    """final = 0.30*lexical + 0.70*semantic (research Stage 5), in 0..1."""
    return BLEND_LEXICAL * lexical01 + BLEND_SEMANTIC * semantic01


# Fallback if prompts/mapping.md is somehow missing from the bundle. Kept terse;
# the real prompt is the file. (Same defensive pattern as vertex._get_tag_prompt.)
_MAPPING_PROMPT_FALLBACK = (
    "You are a project mapper. Read the NEW CARD and compare it against every "
    "LIBRARY card facet by facet, matching values BY MEANING (1.0 same, 0.5 "
    "clearly related, 0 otherwise). Per facet, similarity = sum of matched value "
    "scores / size of the larger value set. Combine with fixed weights task 0.30, "
    "skill 0.25, domain 0.20, modality 0.20, output-format 0.05; overall is the "
    "weighted sum 0.0-1.0. Bands: >=0.75 near-duplicate, 0.40-0.74 same-family, "
    "<0.40 new-territory. Return ONE JSON object: {\"comparisons\":[{\"project\","
    "\"overall\",\"band\",\"per_facet\",\"matches\":[{\"new\",\"library\",\"score\"}],"
    "\"note\"}],\"top_match_summary\"}. Every library project appears, including "
    "zeros, sorted by score. Each note cites the concrete shared and diverging "
    "facet values. You rank similarity, never quality.")
