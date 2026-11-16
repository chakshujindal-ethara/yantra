# -*- coding: utf-8 -*-
"""Numbered-box overlay for image_label detection, using Pillow (Odoo core).

Mirrors the reference proj-2 asset generator: red bounding rectangles + numbered
badges placed with a 7-candidate overlap-avoiding search (so a badge never sits
over a neighbouring element or another number), and a label_key answer sheet.
"""
import io

_RED = (214, 40, 40)
_WHITE = (255, 255, 255)


def _harden_pillow():
    """M-3: bound Pillow's decompression-bomb exposure. A crafted image with a
    huge declared canvas (CVE-2023-4863 libwebp class + generic DoS) can pin RAM
    when opened. Cap the pixel count so PIL raises DecompressionBombError instead
    of allocating gigabytes. 64MP is far above any real question stimulus.

    Also enforce the M-3 version FLOOR here (the manifest can only assert PIL is
    importable, not its version): a Pillow older than 10.3.0 ships the vulnerable
    libwebp build, so log loudly if the runtime is stale."""
    try:
        from PIL import Image
        Image.MAX_IMAGE_PIXELS = 64_000_000
    except Exception:  # noqa: BLE001 - never break rendering if PIL is odd
        return
    try:
        import logging
        from PIL import __version__ as _pil_ver
        parts = tuple(int(x) for x in _pil_ver.split(".")[:2])
        if parts < (10, 3):
            logging.getLogger(__name__).error(
                "etp_assessment M-3: Pillow %s is BELOW the 10.3.0 security floor "
                "(CVE-2023-4863 libwebp class). Upgrade Pillow>=10.3.0.", _pil_ver)
    except Exception:  # noqa: BLE001 - version check must never break rendering
        pass


_harden_pillow()


def _to_pixels(box_2d, w, h):
    ymin, xmin, ymax, xmax = box_2d  # Gemini order [ymin,xmin,ymax,xmax], 0-1000
    return (
        round(xmin / 1000 * w),
        round(ymin / 1000 * h),
        round(xmax / 1000 * w),
        round(ymax / 1000 * h),
    )


def _font(size):
    from PIL import ImageFont
    for name in ("Arial Bold.ttf", "Arial.ttf", "DejaVuSans-Bold.ttf",
                 "Helvetica.ttc"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    return ImageFont.load_default()


def _rects_intersect(a, b):
    """True when two [l,t,r,b] rects overlap (touching edges do not count)."""
    return not (a[2] <= b[0] or b[2] <= a[0] or a[3] <= b[1] or b[3] <= a[1])


def _intersect_area(a, b):
    """Overlap area of two [l,t,r,b] rects (0 when disjoint)."""
    ix = max(0, min(a[2], b[2]) - max(a[0], b[0]))
    iy = max(0, min(a[3], b[3]) - max(a[1], b[1]))
    return ix * iy


def place_badge(box, bw, bh, boxes, placed, w, h, own_idx):
    """Choose the least-overlapping badge rect for element ``box`` ([l,t,r,b]).

    Ported from the reference ``place_badge``: try seven candidate anchors around
    the element (above-left, left, right, above-right, below, inside-top-left,
    inside-top-right), skip any that fall off-image or collide with an
    already-``placed`` badge, and score the rest by how much they overlap OTHER
    element ``boxes`` (never the element's own box at ``own_idx``); take the first
    zero-overlap candidate, else the least-overlapping one.

    Returns ``(rect, overlap_px)`` with rect as [l,t,r,b]. When every anchor is
    blocked the badge is nudged along a diagonal that stays ANCHORED ON its own
    element (overlap -1). When even that finds no clear spot, returns
    ``(None, -1)``: there is no position for this number that a candidate could
    read unambiguously, and the caller has to decide what to do about it rather
    than be handed a rect that sits on something else."""
    left, top, right, bottom = box
    candidates = [
        (left, top - bh - 2),           # above, flush left, outside the box
        (left - bw - 2, top),           # left of the box
        (right + 2, top),               # right of the box
        (right - bw, top - bh - 2),     # above, flush right
        (left + 2, bottom + 2),         # below the box
        (left + 2, top + 2),            # inside the top-left corner
        (right - bw - 2, top + 2),      # inside the top-right corner
    ]
    scored = []
    for cx, cy in candidates:
        if cx < 0 or cy < 0 or cx + bw > w or cy + bh > h:
            continue
        rect = (cx, cy, cx + bw, cy + bh)
        if any(_rects_intersect(rect, p) for p in placed):
            continue
        overlap = 0
        for i, ob in enumerate(boxes):
            if i == own_idx:
                continue
            overlap += _intersect_area(rect, ob)
        scored.append((overlap, rect))
        if overlap == 0:
            break
    if not scored:
        # EVERY anchor was blocked. The original fallback returned the
        # inside-top-left corner unconditionally, which ignores `placed` - so on
        # a cluster of overlapping elements two badges landed on the SAME pixels
        # and the upper one hid the lower. The rendered image then read
        # 1,2,3,3,5,6: a candidate sees a duplicate number, cannot tell which
        # element it belongs to, and one element carries no visible number.
        #
        # So nudge the badge along a diagonal until it clears the badges already
        # drawn - but the walk is bounded BY THE ELEMENT, not by an arbitrary
        # badge-count. `max_x`/`max_y` are the last offsets at which the badge
        # rect still overlaps the box it is labelling; one step past that and the
        # number is sitting on a NEIGHBOUR, which is the same "number on the
        # wrong thing" defect as a mis-detected box, only silent. An earlier
        # version stepped `bw + 2` up to eleven times, i.e. eleven badge-widths
        # away from its own element.
        step_px = max(2, min(bw, bh) // 2)
        max_x = max(left + 2, right - bw)
        max_y = max(top + 2, bottom - bh)
        # Clamp targets, precomputed: a badge wider/taller than the image itself
        # pins to 0 rather than going negative.
        pin_x, pin_y = max(0, w - bw), max(0, h - bh)
        seen = set()
        offset = 0
        while True:
            # Each axis is clamped to its own element bound FIRST, so a wide,
            # short element is scanned across its width without the badge sliding
            # off the bottom (and vice versa), then to the image edge.
            rect_x = min(max(0, min(left + 2 + offset, max_x)), pin_x)
            rect_y = min(max(0, min(top + 2 + offset, max_y)), pin_y)
            rect = (rect_x, rect_y, rect_x + bw, rect_y + bh)
            if rect in seen:
                # Both axes have hit their bound (element extent, or the image
                # edge), so every further step yields this IDENTICAL rect. The
                # old loop kept spinning on the clamped value and then returned
                # the overlapping corner anyway.
                break
            seen.add(rect)
            if not any(_rects_intersect(rect, p) for p in placed):
                return rect, -1
            offset += step_px
        # No readable position exists for this number: every spot on its own
        # element is already carrying another badge. Say so instead of returning
        # a rect that lands on a different element - a candidate reading a number
        # pointing at the wrong object is a wrong answer key, and silent.
        return None, -1
    scored.sort(key=lambda t: t[0])
    return scored[0][1], scored[0][0]


def annotate_from_pixels(image_bytes, items):
    """Numbered-box overlay working directly in IMAGE-PIXEL space.

    ``items`` is ``[{"label","description","box_px":[l,t,r,b]}]`` with box_px
    already in the image's own pixel coordinates — NO 0-1000 round trip — so a
    caller holding exact rects (the DOM capture path, whose boxes are CSS px *
    device-scale-factor) draws them tight on the real element edges instead of
    quantizing every edge to the ~1.4px steps of Gemini's 0-1000 grid. Element
    rectangles are drawn first, then each numbered badge is positioned with
    :func:`place_badge` so it avoids covering neighbouring boxes and other badges.
    Returns ``(annotated_png_bytes, label_key)`` where label_key is the answer
    sheet ``[{"number","label","description","box_px":[l,t,r,b]}]``.

    An element whose number had nowhere readable to go keeps its answer-key entry
    (never drop generated content) and carries ``"badge_unplaced": True`` so the
    admin reviewing the draft can see that the picture shows a red rectangle with
    no numeral on it. The alternative - stamping the numeral wherever it fits -
    puts the number on a neighbouring element, and then the answer key is wrong
    with nothing on screen to say so."""
    from PIL import Image, ImageDraw
    base = Image.open(io.BytesIO(image_bytes)).convert("RGB")
    w, h = base.size
    draw = ImageDraw.Draw(base)
    fsize = max(13, w // 90)
    font = _font(fsize)

    valid = [it for it in (items or [])
             if isinstance(it, dict)
             and isinstance(it.get("box_px"), (list, tuple))
             and len(it["box_px"]) == 4]
    px_boxes = [[int(round(float(v))) for v in it["box_px"]] for it in valid]

    for left, top, right, bottom in px_boxes:
        draw.rounded_rectangle(
            [left, top, right, bottom], radius=6, outline=_RED, width=2)

    label_key = []
    placed = []
    for i, it in enumerate(valid):
        # THE CALLER'S OWN NUMBER WINS WHEN IT HAS ONE.
        #
        # Numbering strictly by POSITION is right for a detection lane, where
        # this function IS what assigns the numbers - Gemini and the DOM capture
        # both hand over an unnumbered list, and 1..N in draw order is the key.
        #
        # It is WRONG for a re-draw of an already-keyed plate. A stored key can
        # legitimately be SPARSE - an examiner deletes marker 2 and markers 1, 3
        # and 5 remain, because marker numbers are stable for the question's life
        # so a submitted answer can never point at a renumbered marker. Numbering
        # by position then burns badges 1, 2, 3 into the picture while the answer
        # key still says 1, 3, 5: every candidate reads a number that means a
        # different region than the one they are graded against. Verified by
        # experiment before this guard existed - markers 1/3/5 came back painted
        # 1/2/3.
        #
        # `int(...)` rather than a bare truth test: 0 is not a marker number
        # (`bank_label_boxes` and every reader treat > 0 as the contract), so a
        # zero or an unparseable value falls back to the position.
        try:
            explicit = int(it.get("number") or 0)
        except (TypeError, ValueError):
            explicit = 0
        marker = explicit if explicit > 0 else i + 1
        number = str(marker)
        tb = draw.textbbox((0, 0), number, font=font)
        tw, th = tb[2] - tb[0], tb[3] - tb[1]
        bw, bh = tw + 10, th + 8
        rect, _overlap = place_badge(
            px_boxes[i], bw, bh, px_boxes, placed, w, h, i)
        left, top, right, bottom = px_boxes[i]
        entry = {
            "number": marker,
            "label": str(it.get("label") or "").strip(),
            "description": str(it.get("description") or "").strip(),
            "box_px": [left, top, right, bottom],
        }
        if rect is None:
            # place_badge found no position that is both clear of the badges
            # already drawn and still on this element. Draw nothing rather than
            # stamp the numeral onto a neighbour, and flag the entry.
            entry["badge_unplaced"] = True
        else:
            placed.append(rect)
            draw.rectangle([rect[0], rect[1], rect[2], rect[3]], fill=_RED)
            draw.text(((rect[0] + rect[2]) / 2, (rect[1] + rect[3]) / 2),
                      number, fill=_WHITE, font=font, anchor="mm")
        label_key.append(entry)

    buf = io.BytesIO()
    base.save(buf, format="PNG")
    return buf.getvalue(), label_key


def annotate_image(image_bytes, detections):
    """Draw numbered red boxes for ``detections`` (each ``{"box_2d","label",
    "description"}`` with box_2d in 0-1000 space) onto ``image_bytes``. Element
    rectangles are drawn first, then each numbered badge is positioned with
    :func:`place_badge` so it avoids covering neighbouring boxes and other badges.
    Returns ``(annotated_png_bytes, label_key)`` where label_key is the answer
    sheet ``[{"number","label","description","box_px":[l,t,r,b]}]``.

    This is the Gemini-detection entry point: box_2d rects are mapped from the
    0-1000 grid into pixel space against the image size, then drawn by
    :func:`annotate_from_pixels`. Callers that already hold exact pixel rects
    (the DOM capture path) should call :func:`annotate_from_pixels` directly."""
    from PIL import Image
    w, h = Image.open(io.BytesIO(image_bytes)).size
    items = []
    for d in (detections or []):
        if not (isinstance(d, dict)
                and isinstance(d.get("box_2d"), (list, tuple))
                and len(d["box_2d"]) == 4):
            continue
        items.append({
            # Carried through when the detection already HAS a number, so a
            # re-draw of a keyed plate keeps the examiner's own numbering
            # instead of being renumbered by position. See annotate_from_pixels.
            "number": d.get("number"),
            "label": d.get("label"),
            "description": d.get("description"),
            "box_px": list(_to_pixels(d["box_2d"], w, h)),
        })
    return annotate_from_pixels(image_bytes, items)
