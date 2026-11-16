"""Answer-key helpers for image labelling questions.

`_ideal_labels_count` lived in `etp_assessment_pro/controllers/portal.py`, the
QWeb candidate portal. This addon is headless - the Flutter client replaced
that portal - so the controller is not forked, but the API still needs this one
pure function to decide how many "Label N" inputs a labelling question implies.
Lifted here rather than dragging a whole QWeb controller across for it.
"""
import json
import re

from ..constants import DEFAULT_IMAGE_LABEL_COUNT


def _resolve_cap(cap):
    """Normalise a caller-supplied cap to a usable positive ceiling.

    A caller reading `image_label_count` off an unset/`False` Many2one gets 0 or
    None, and clamping a count to 0 would silently render a labelling question
    with no inputs at all - worse than the old hard-coded 20. So anything that
    is not a positive integer means "no opinion" and falls back to the default.
    """
    try:
        n = int(cap)
    except (TypeError, ValueError):
        return DEFAULT_IMAGE_LABEL_COUNT
    return n if n >= 1 else DEFAULT_IMAGE_LABEL_COUNT


def ideal_labels_count(value, cap=None):
    """How many labelling boxes an image_label ``ideal_labels`` answer key
    implies - used to synthesise one "Label N" input per numbered box when the
    boxes are baked into the rendered image and no detections_json exists.

    ``value`` may be a Python list, a JSON-array/-object string, or free text
    with entries separated by ';' and/or newlines (optionally "Box N = ..."
    segments). Returns the count of distinct non-empty entries, capped to
    ``cap`` boxes; 0 for empty/None (keeps the textarea fallback).

    ``cap`` is the authoring generator's own `image_label_count` where the
    caller can reach one: the render path must never offer MORE "Label N" inputs
    than the authoring path was allowed to draw boxes for, or a candidate types
    an answer into a box that was never on the image and is graded on it.
    ``cap=None`` - every caller with no generator in scope - falls back to
    DEFAULT_IMAGE_LABEL_COUNT, which is the same 20 this function hard-coded
    before the cap existed, so those callers do not move.
    """
    limit = _resolve_cap(cap)
    if not value:
        return 0
    if isinstance(value, str):
        raw = value.strip()
        if raw[:1] in ("[", "{"):
            try:
                parsed = json.loads(raw)
            except (TypeError, ValueError):
                parsed = None
            if isinstance(parsed, list):
                value = parsed
            elif isinstance(parsed, dict):
                value = list(parsed.values())
    if isinstance(value, (list, tuple)):
        n = sum(1 for v in value if str(v or "").strip())
        return max(0, min(n, limit))
    if not isinstance(value, str):
        return 0
    text = value.strip()
    if not text:
        return 0
    box_nums = re.findall(r"box\s*(\d+)", text, flags=re.IGNORECASE)
    if box_nums:
        n = len({int(x) for x in box_nums})
    else:
        n = sum(1 for seg in re.split(r"[;\n]+", text) if seg.strip())
    return max(0, min(n, limit))


# The portal exported it under a leading underscore; keep that name working so
# the API import site reads the same as it did before the fork.
_ideal_labels_count = ideal_labels_count


def _json_list(raw):
    try:
        value = json.loads(raw or "[]")
    except (ValueError, TypeError):
        return []
    return value if isinstance(value, list) else []


def _box_2d(value):
    return (isinstance(value, (list, tuple)) and len(value) >= 4
            and all(isinstance(v, (int, float)) for v in value[:4]))


def overlay_for(numbers, authored_json, detections_json, captured,
                authored_key, has_baked):
    """ONE numbered overlay, numbered exactly as scoring grades (2026-09-29).

    A labelling picture could carry two overlays at once: the generator's own
    rectangles (drawn by the client from `label_boxes_json`) and a detection
    pass baked into the annotated picture - two unrelated numberings on one
    image, while scoring graded a third thing. This picks the single overlay
    whose numbering IS the key:

    * `regions` - the key is the generator's (`authored_key`) and its
      rectangles cover every key number: the client draws them on the PLAIN
      picture, and the baked detection picture is not served.
    * `regions` too when the key came from a capture or detection and every
      detection has `box_2d` geometry (Form Studio regions, baked or not):
      the client draws them, interactive, and the baked picture is not served.
    * `baked` - the key came from a live-page capture or from detection
      without full geometry: the annotated picture carries exactly those
      numbers.
    * `none` - nothing to draw; the numbers still drive the inputs. Also the
      answer when the key is the generator's but its rectangles are
      incomplete: the baked picture numbers something else (on q1170, 17
      detected controls against a 4-panel key), so serving it would put two
      numberings in front of the candidate again.

    Returns ``(mode, boxes)``; ``boxes`` is a list of ints or of
    ``{"number", "box_2d"}`` maps, the two shapes the client understands.
    """
    if not numbers:
        return "none", []
    authored = {b["number"]: list(b["box_2d"][:4])
                for b in _json_list(authored_json)
                if isinstance(b, dict) and isinstance(b.get("number"), int)
                and _box_2d(b.get("box_2d"))}
    if authored_key:
        if not captured and all(n in authored for n in numbers):
            return "regions", [{"number": n, "box_2d": authored[n]}
                               for n in numbers]
        return "none", list(numbers)
    detected = {d["number"]: list(d["box_2d"][:4])
                for d in _json_list(detections_json)
                if isinstance(d, dict) and isinstance(d.get("number"), int)
                and _box_2d(d.get("box_2d"))}
    if all(n in detected for n in numbers):
        return "regions", [{"number": n, "box_2d": detected[n]}
                           for n in numbers]
    if has_baked:
        return "baked", list(numbers)
    return "none", list(numbers)


def label_overlay(question):
    """`overlay_for` for a bank question: its key is what scoring grades."""
    from . import scoring
    if question.question_type != "image_label":
        return "none", []
    numbers = sorted({int(k) for k in scoring._label_boxes(question)
                      if str(k).isdigit()})
    image = question.image_ids.filtered(lambda i: i.slot == "single")[:1]
    if not image:
        return "none", numbers
    captured = bool((image.capture_viewport or "").strip()
                    or _json_list(image.dom_manifest_json))
    behavioural = bool(scoring._image_label_behavioural_key(question))
    detections = bool(scoring._image_label_detections(question))
    # The generator's key: its authored behavioural key on a picture no live
    # capture numbered, or its ideal labels when nothing was detected.
    authored_key = (behavioural and not captured) or (
        not behavioural and not detections)
    return overlay_for(
        numbers, image.label_boxes_json, image.detections_json, captured,
        authored_key,
        bool(image.annotated_image or image.annotated_image_url))


def draft_label_overlay(draft):
    """`overlay_for` for a DRAFT, so the review preview shows the one overlay
    the approved question will: its key is the behavioural key, else the
    render-time detections, else the authored boxes' own numbers."""
    authored = [b for b in _json_list(draft.label_boxes_json)
                if isinstance(b, dict) and isinstance(b.get("number"), int)]
    if draft.question_type != "image_label":
        return "none", authored
    spec = next((s for s in draft._image_specs()
                 if (s.get("slot") or "single") == "single"), None) or {}

    def _numbered(raw):
        return [e for e in _json_list(raw)
                if isinstance(e, dict) and isinstance(e.get("number"), int)]

    behavioural = _numbered(draft.behavioural_key_json)
    detections = _numbered(spec.get("detections_json"))
    # A live capture replaces the authored boxes with its DOM manifest, whose
    # rects are `box_css`: the picture it baked is the key's own overlay.
    captured = any("box_css" in b for b in authored)
    numbers = sorted({e["number"] for e in (behavioural or detections
                                            or authored)})
    authored_key = (bool(behavioural) and not captured) or (
        not behavioural and not detections)
    return overlay_for(
        numbers, draft.label_boxes_json, spec.get("detections_json"),
        captured, authored_key,
        bool(spec.get("annotated_data") or spec.get("annotated_url")))
