# -*- coding: utf-8 -*-
"""The Form Studio import template: one empty item of every element kind.

A STRUCTURE, NOT A FORM. The file this renders carries no question text, no
options, no answer keys and no media - only the SHAPE of each kind, with every
slot an author can write present and blank. The author fills it in, deletes what
they do not need, and imports it. It is therefore not expected to publish as-is:
pressing Publish on an unfilled template is how the operator gets the list of
what is still missing, because `validate_structure` names every gap per item.

GENERATED, NEVER AUTHORED. Every kind in `constants.FORM_ITEM_KINDS` already
declares the slots it needs (`needs`) and a sentence of guidance (`hint`), and
`static/src/fields/form_item_editor/form_item_editor.js:newItem` already turns
that declaration into a blank item for the back office's Add-question button.
This is that same function rendered to a file, which is the property that makes
it a template rather than a second opinion: a kind added to the catalogue
appears here with no edit, and `tests/test_form_template.py` fails if it cannot
be seeded. A hand-written template is a second copy of the catalogue, and a
second copy is how an editor comes to offer a kind publish refuses.

THE GUIDANCE RIDES IN `_note`, AND `help` IS BLANK LIKE EVERY OTHER SLOT.
`help` is not a comment field - it is CANDIDATE-FACING text. `studio_form.
_item_spec` publishes it as the question's `description`, and a `textBlock`'s
`help` is folded into the next question's lead text by `_attach_carry`. Seeding
it with the catalogue `hint` therefore shipped sentences written for the AUTHOR
("Write the model answer. The judge marks each candidate against it...") to the
CANDIDATE, and nothing downstream would have caught it: `validate_structure`
never inspects `help`, so Publish - the one feedback loop this whole design
leans on - stays silent about it. `_note` carries the same sentence instead, and
is read by NEITHER parser (`_item_spec` reads named keys only, so an unknown key
is inert; the Flutter importer likewise ignores item keys it does not know). The
guidance stays visible in the FILE the author edits and reaches nothing else.

WHAT THIS NAMES THAT `newItem` DOES NOT, and why. `newItem` seeds the keys the
EDITOR'S OWN CONTROLS write - a slot the widget fills in later does not need to
exist up front. A hand-authored JSON file has no widget, so this seeds every key
an author can legitimately write, which additionally means:

* `media_url_b` on `promptWriting` (`media_b_optional`) and its optional rating
  axes (`options_optional`). `newItem` tests for the tokens `media_b` and
  `options` EXACTLY, so neither optional spelling seeds anything there. Without
  the second plate named, nothing in the file teaches the reference-then-output
  transform shape - one of the least guessable parts of the format, and the one
  where the medium follows the OUTPUT.
* `media_kind` beside every `media_url`. The designer stamps it from the upload's
  content type, so the widget never needs it seeded. It is load-bearing for a
  hand-authored file in exactly one case the author cannot otherwise express: a
  CDN or signed URL that is a clip but carries no recognisable extension and no
  embed host, where `_looks_like_video` would otherwise read it as an image.
* `regions` on `imageAnnotation`. Drawn in the annotation editor, never typed -
  but an author writing JSON has no editor, and `{n, x, y, w, h}` is not a shape
  anybody guesses. (`newItem` does seed `annotation_count` and `golden_labels`;
  `regions` is the one the annotation canvas writes, so only it is missing.)
* every declared `flag`, seeded `False`. `newItem` seeds NO flag at all - the
  switch renders from `kind.flags` and the key is written on the first toggle -
  so `multi_select` (`imageBlock`, `videoBlock`) and `require_justification`
  (`comparePair`) exist nowhere in a blank editor item. An author reading JSON
  has no switch to notice, so a flag has to be IN the file to be discoverable.

THE ONE EXCEPTION, in the other direction: `allow_other` is a declared flag on
the three choice kinds and is deliberately NOT seeded. Publish drops it with a
warning (`studio_form.py:693`), so naming it here would teach a dead field.

CONSTANT COST. Everything below is module-level data and a pure render of it -
no env, no ORM, no I/O - so the download route cannot be turned into a scan by
asking for it repeatedly. Same property `bank_json_template` documents at its
head, for the same reason.
"""
import json

from ..constants import FORM_ITEM_KINDS

#: Kinds the catalogue defines that the template deliberately leaves out.
#:
#: NAMED, NOT OMITTED, so the exclusion is a decision on the record and the
#: coverage test can tell "left out on purpose" from "forgotten". All three are
#: kinds the FLUTTER designer - the surface this template is imported into -
#: cannot author:
#:
#: * `date` / `time`: retired on the client (`form_models.dart:129-133`). They
#:   still publish as free text with a warning, but a template item of either
#:   would import into Form Studio as a `shortAnswer` with NO warning, so the
#:   author would silently lose the kind they were shown.
#: * `fileUpload`: role `refused`. One of them refuses the whole form
#:   (`studio_form.py:601`), so a template carrying one could never be published
#:   however carefully it was filled in.
SKIPPED_KINDS = ("date", "time", "fileUpload")

#: Flags the catalogue declares that are NOT seeded. See the module docstring.
_DEAD_FLAGS = ("allow_other",)

#: The sections, and which families land in each. FAMILIES, NOT KIND NAMES, so
#: a kind added to an existing family needs no edit here - and one added to a
#: NEW family fails `_grouped()` loudly rather than vanishing from the template.
_SECTIONS = (
    {
        "title": "1. Instructions, and the written answers",
        "description": "A text block carries prose and never becomes a "
                       "question - it folds into the question below it, across "
                       "section boundaries. The two written kinds are marked by "
                       "a judge against the golden answer you write.",
        "families": ("layout", "written"),
    },
    {
        "title": "2. Choices, grids and scales",
        "description": "Everything scored by matching the candidate's pick "
                       "against a key you set. Delete the kinds you do not "
                       "need; two blank options are seeded because one option "
                       "is not a choice and publish says so.",
        "families": ("choice", "grid", "scale"),
    },
    {
        "title": "3. Media questions",
        "description": "Each needs its plate before it can be published. Paste "
                       "a public URL, or upload the file in the designer and "
                       "let it fill the field in for you.",
        "families": ("media", "compare", "annotate", "prompt",
                     "transcription"),
    },
)


def _blank_option():
    """One empty option. No `id`: the importer re-mints every id it is given
    (`form_models.dart:755-781`), so an authored one never survives the trip."""
    return {"label": "", "correct": False}


def _seed_options(item):
    # TWO, not one and not none. An options-carrying kind with no `options` key
    # reads as "no options" everywhere, and publish refuses a single-option
    # choice by name - so a template seeding fewer would hand the author a form
    # that is broken before they have typed anything.
    item["options"] = [_blank_option(), _blank_option()]


def _seed_grid(item):
    # PLAIN STRINGS, matching `newItem`'s own note: `_item_spec` coerces rows
    # and columns with `str(...)`, so a dict here would stringify to
    # "{'label': 'x'}" and become a column labelled with its own source code.
    #
    # `grid_key` is keyed by the row's INDEX as a string, zero-based - that is
    # what `studio_form._item_spec` reads (`key.get(str(i))` over
    # `enumerate(rows)`), and it is the single least guessable key in the format.
    item["rows"] = ["", ""]
    item["columns"] = ["", ""]
    item["grid_key"] = {}


def _seed_scale(item):
    item["scale_min"] = 1
    item["scale_max"] = 5
    item["scale_min_label"] = ""
    item["scale_max_label"] = ""


def _seed_rating(item):
    item["rating_max"] = 5


def _seed_golden(item):
    # THE KEY GOES HERE FOR THE SCALES TOO, not in `scale_golden` /
    # `rating_golden`. Those two are the Flutter designer's typed fields and
    # `studio_form` never reads them - it reads `golden_answer` for every kind
    # that has one, including `linearScale` and `rating`, whose `needs` carry
    # `golden_point`. Seeding it here is what keeps a hand-filled template
    # publishable without depending on the client to rewrite the key.
    item["golden_answer"] = ""


def _seed_media(item):
    item["media_url"] = ""
    item["media_kind"] = ""


def _seed_media_b(item):
    item["media_url_b"] = ""


def _seed_regions(item):
    item["annotation_count"] = 1
    item["regions"] = []
    item["golden_labels"] = {}


def _seed_nothing(item):
    """`multi_key` names a RULE, not a panel: it is what makes several `correct`
    flags legal on a kind. There is no key to write for it."""


#: One handler per `needs` token the catalogue can declare. A token with no
#: entry raises in `blank_item` rather than seeding nothing, so a token added to
#: `constants.py` cannot half-land - the template would otherwise ship an item
#: missing a slot and nothing would say so.
_SLOTS = {
    "options": _seed_options,
    "options_optional": _seed_options,
    "grid": _seed_grid,
    "multi_key": _seed_nothing,
    "scale": _seed_scale,
    "rating": _seed_rating,
    "golden": _seed_golden,
    "golden_optional": _seed_golden,
    "golden_point": _seed_golden,
    "media": _seed_media,
    "media_b": _seed_media_b,
    "media_b_optional": _seed_media_b,
    "regions": _seed_regions,
}


def blank_item(kind_def):
    """One empty item of `kind_def`, seeded from its own `needs` and `flags`.

    EVERY WRITABLE SLOT PRESENT AND BLANK, `help` INCLUDED. The catalogue's
    `hint` rides in `_note` instead, because the two are for different readers:
    `_note` is guidance for the AUTHOR, and `help` is what the CANDIDATE reads -
    `studio_form._item_spec` publishes it as the question's `description`, and a
    `textBlock`'s `help` becomes the next question's lead text. Publish cannot
    catch a `help` the author never wrote (`validate_structure` does not inspect
    it), so anything seeded there ships. `_note` is dropped by both parsers: the
    sentence stays in the file being edited and reaches nothing downstream.
    """
    item = {"kind": kind_def["kind"],
            "_note": str(kind_def.get("hint") or ""),
            "title": "", "help": ""}
    for token in kind_def.get("needs") or ():
        try:
            seed = _SLOTS[token]
        except KeyError:
            raise ValueError(
                "constants.FORM_ITEM_KINDS declares an unknown `needs` token "
                "%r on kind %r - add a seeder for it in services/"
                "form_json_template._SLOTS, or the template ships that kind "
                "with a slot missing." % (token, kind_def["kind"]))
        seed(item)
    for flag in kind_def.get("flags") or ():
        if flag["name"] not in _DEAD_FLAGS:
            item[flag["name"]] = False
    return item


def _grouped():
    """The templated kinds, per section, in catalogue order.

    Refuses rather than guesses when a family is in the catalogue and in no
    section: a kind that is neither templated nor skipped would otherwise
    disappear from the template silently, which is the exact failure this whole
    module exists to prevent.
    """
    placed = {family for section in _SECTIONS for family in section["families"]}
    live = {kind["family"] for kind in FORM_ITEM_KINDS
            if kind["kind"] not in SKIPPED_KINDS}
    missing = sorted(live - placed)
    if missing:
        raise ValueError(
            "constants.FORM_ITEM_KINDS has families no template section "
            "claims: %s. Add them to services/form_json_template._SECTIONS, or "
            "name their kinds in SKIPPED_KINDS." % ", ".join(missing))
    return [
        (section, [kind for kind in FORM_ITEM_KINDS
                   if kind["family"] in section["families"]
                   and kind["kind"] not in SKIPPED_KINDS])
        for section in _SECTIONS
    ]


def template_payload():
    """The template as a dict, in the shape `formFromImportedJson` reads.

    `id`, `published` and `updated_at` are omitted on purpose. The importer
    re-mints every id, forces `published` to false and resets `updated_at` on
    save - a key the file cannot influence does not belong in a document whose
    whole job is to teach the format.
    """
    return {
        "title": "Form import template",
        "internal_name": "Template - every question kind",
        "description":
            "One empty item of every kind Form Studio can author. Fill in the "
            "titles, the options and the golden answers, delete what you do "
            "not need, then import it. Publishing an unfilled template is "
            "refused, and the refusal names every slot still blank.",
        "shuffle_questions": False,
        "sections": [
            {
                "title": section["title"],
                "description": section["description"],
                "items": [blank_item(kind) for kind in kinds],
            }
            for section, kinds in _grouped()
        ],
    }


FILENAME = "form_studio_import_template.json"


def _dump(payload):
    """The one serialisation, so every surface emits the SAME BYTES."""
    return json.dumps(payload, indent=2, ensure_ascii=False,
                      sort_keys=False).encode("utf-8")


def template_json():
    """``(filename, bytes)`` for the template."""
    return FILENAME, _dump(template_payload())


def template_api_payload():
    """The API download shape every other template route on this API uses -
    ``{filename, mimetype, content}`` with `content` base64. See
    `/api/v1/bank/template/json` and `/api/v1/candidates/template`."""
    import base64

    filename, content = template_json()
    return {
        "filename": filename,
        "mimetype": "application/json",
        "content": base64.b64encode(content).decode("ascii"),
    }
