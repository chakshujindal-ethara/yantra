# -*- coding: utf-8 -*-
"""The JSON question-bank import templates, and the schema doc rendered from them.

ONE DEFINITION, because a template that disagrees with the importer is worse
than no template - the convention `export_api.CANDIDATE_TEMPLATE_COLUMNS`
already states for the candidate CSV. The downloadable file, the API payload and
the knowledge base schema section are all rendered from what is below, so the three
cannot drift apart from each other. `tests/test_import_parity.py` then feeds each
template through the REAL importer, which is what stops any of them drifting
away from the parser.

TWO JSON PATHS, TREATED DIFFERENTLY:

* **harness** - the authoring harness's `questions.json` / `output.json`, parsed
  by `bank_import.import_bank_harness` and fingerprinted by
  `bank_import_wizard._try_harness_payload`. It has NO exporter, so nothing can
  be derived from a round trip and the template is hand-authored here. This is
  the gap D4 is about.
* **native** - the lossless bank export carrying the `assessments_be_bank`
  sentinel, parsed by `bank_import.import_bank_native`, partner to
  `question._export_native`. It DOES have an exporter, so its template is
  produced BY that exporter rather than hand-authored, which makes it
  self-maintaining: a field added to `_export_native` appears in the template
  without anyone editing this file.

CONSTANT COST, ON PURPOSE. Both templates are served from a download route on
the shared worker pool. `HARNESS_TEMPLATE` is a module constant, and
`native_template_json` exports ONE in-memory `new()` record - no `search()`, no
`browse()`, no read of the live bank. The template's cost does not grow with the
database, so the route cannot be turned into a scan by asking for it repeatedly.
"""
import json

#: The asset URL every template uses. `_apply_harness_assets`
#: (`bank_import.py:163`) auto-attaches an asset ONLY when it carries a fetchable
#: `http(s)` location and records a warning for anything else, because Odoo
#: cannot read the harness's run folder. A template shipping `assets/q01_a.png`
#: would therefore demonstrate the WARNING path rather than the working one.
#:
#: The URL is a placeholder that is never fetched by the import itself: the
#: harness importer only writes the address into the draft's `images_json`, and
#: the download happens later, on approval, in `prompt._materialize_images` ->
#: `services/image_ingest.ingest` (which has a 20s timeout and does not follow
#: redirects). Importing a template is not an outbound request.
_ASSET_HOST = "https://picsum.photos/seed"


#: The authoring-harness template. One question per shape the parser branches
#: on - `mcq`, `msq`, `subjective_rubric` - because those three branches are
#: where a parser change would silently drop an answer key.
HARNESS_TEMPLATE = {
    "questions": [
        {
            "id": "q01",
            "instruction": "Which city is the capital of France?",
            "covers_elements": ["geography.capitals"],
            "fields": {
                "question_type": "mcq",
                "difficulty": "easy",
                "options": ["Paris", "London", "Berlin", "Madrid"],
                "correct_answer": "Paris",
                "official_reasoning": "Paris has been the capital since 1944.",
            },
            "assets": {
                "single": {
                    "type": "image",
                    "url": "%s/capital/512" % _ASSET_HOST,
                },
            },
        },
        {
            "id": "q02",
            "instruction": "Select ALL prime numbers below.",
            "covers_elements": ["maths.number-theory"],
            "fields": {
                "question_type": "msq",
                "difficulty": "medium",
                "options": ["2", "3", "4", "9"],
                "correct_answer": ["2", "3"],
                "official_reasoning": "2 and 3 have no divisors other than 1 "
                                     "and themselves; 4 and 9 are squares.",
            },
        },
        {
            "id": "q03",
            "instruction": "Explain what idempotency means for a REST API and "
                           "why it matters.",
            "covers_elements": ["engineering.api-design"],
            "fields": {
                "question_type": "subjective_rubric",
                "difficulty": "hard",
                "rubric": [
                    {
                        "label": "Idempotency",
                        "checklist": [
                            "Defines idempotency as same request, same state",
                            "Names at least one idempotent method",
                            "Says why retries need it",
                        ],
                        "constraints": ["No code required"],
                        "pass_condition": "Covers the definition and one "
                                          "concrete retry consequence.",
                    },
                ],
                "official_reasoning": "A retry must not create a second "
                                      "resource, which is what makes PUT and "
                                      "DELETE safe to repeat.",
            },
        },
    ],
    #: Keyed by the question's own `id`. `_apply_harness_solution`
    #: (`bank_import.py:150`) reads exactly `answers` and `rationale`.
    "solutions": {
        "q01": {
            "answers": "Paris",
            "rationale": "The other three are capitals of other countries.",
        },
        "q02": {
            "answers": ["2", "3"],
            "rationale": "4 = 2x2 and 9 = 3x3, so neither is prime.",
        },
        "q03": {
            "answers": {"Idempotency": "pass"},
            "rationale": "A full answer names the property and one retry "
                         "consequence.",
        },
    },
}


class _Field(object):
    """One documented field: where it lives, whether it is required, what it does."""

    __slots__ = ("path", "required", "note")

    def __init__(self, path, required, note):
        self.path = path
        self.required = required
        self.note = note


#: Every key the harness parser READS, in the order the doc lists them. The
#: paths are asserted against `HARNESS_TEMPLATE` in `test_import_parity.py`, so
#: a key added to the template without a row here (or the reverse) fails the
#: suite rather than shipping an undocumented field.
HARNESS_FIELDS = (
    _Field("questions[].id", True,
           "Stable key. Also the join to `solutions`, and it becomes the "
           "draft's `gen_batch` as `harness:<id>`. Defaults to `qNN` by "
           "position when omitted, which breaks the solutions join."),
    _Field("questions[].instruction", True,
           "The question text. `prompt` is accepted as a fallback. The first "
           "60 characters become the draft's title."),
    _Field("questions[].covers_elements", False,
           "List of syllabus elements the question covers. Stored verbatim as "
           "`covers_elements_json`."),
    _Field("questions[].fields.question_type", True,
           "One of the draft model's own codes - `mcq`, `msq`, "
           "`subjective_rubric`, `image_ab`, `image_prompt`, `image_label`, "
           "`video_prompt`. An unknown code is imported as "
           "`subjective_rubric` WITH A WARNING, not refused."),
    _Field("questions[].fields.difficulty", False,
           "`easy`, `medium` or `hard`. Anything else becomes `medium`."),
    _Field("questions[].fields.options", False,
           "Required for `mcq` and `msq`; ignored for every other type."),
    _Field("questions[].fields.correct_answer", False,
           "The answer key for `mcq` / `msq`. A string for one answer, a list "
           "for several."),
    _Field("questions[].fields.rubric", False,
           "Required for `subjective_rubric`; ignored for every other type. A "
           "list of `{label, checklist, constraints, pass_condition}`."),
    _Field("questions[].fields.official_reasoning", False,
           "The model answer shown to a reviewer, never to a candidate."),
    _Field("questions[].assets", False,
           "`{role: {type, url}}`. ONLY an `http(s)` `url` (or `file`) is "
           "auto-attached, as the draft's `images_json`. A local run-folder "
           "path is reported in the import warnings for a manual upload, "
           "because Odoo cannot read the harness's filesystem."),
    _Field("solutions.<id>.answers", False,
           "The worked answer, keyed by the question's `id`. Stored as "
           "`solution_json`."),
    _Field("solutions.<id>.rationale", False,
           "Why that answer is right. Stored as `solution_rationale`."),
)

#: Every key `question._export_native` emits and `import_bank_native` reads.
#: Asserted against a real export in `test_import_parity.py`, so this list
#: cannot fall behind the exporter.
NATIVE_FIELDS = (
    _Field("name", True, "Question title, truncated to 200 characters."),
    _Field("prompt", True, "The question text."),
    _Field("description", False, "Sub-heading shown under the prompt."),
    _Field("question_type", True,
           "Must be one of the live codes. An unknown code is SKIPPED with a "
           "warning rather than restamped, because restamping keeps an answer "
           "key the new type cannot read."),
    _Field("difficulty", False, "`easy`, `medium` or `hard`; anything else is dropped."),
    _Field("time_minutes", False, "Suggested time. 0 when unset."),
    _Field("sequence", False, "Ordering within the bank. Defaults to 10."),
    _Field("source_ref", False, "Free-text provenance."),
    _Field("official_reasoning", False, "Reviewer-facing model answer."),
    _Field("subjective_rubric_json", False,
           "Rubric as a JSON STRING (not an object), for subjective types."),
    _Field("grading_json", False, "Grading spec as a JSON string."),
    _Field("meta_json", False, "Arbitrary metadata as a JSON string."),
    _Field("generator", False,
           "Batch name. Matched by name, and CREATED if no generator has it."),
    _Field("dimensions", False,
           "`[{name, options: [{name, is_correct}]}]`. A dimension with no "
           "options is skipped - that is how an answer key goes missing."),
    _Field("images", False,
           "`[{slot, label, image_url, image_b64}]`. `image_url` is used "
           "as-is; `image_b64` is stored as the binary."),
)

FLAVORS = ("harness", "native")

_FILENAMES = {
    "harness": "question_bank_harness_template.json",
    "native": "question_bank_native_template.json",
}


def _dump(payload):
    """The one serialisation, so the button and the route emit the SAME BYTES."""
    return json.dumps(payload, indent=2, ensure_ascii=False,
                      sort_keys=False).encode("utf-8")


def harness_template_json():
    """``(filename, bytes)`` for the authoring-harness template.

    A constant render of a module constant: no env, no query, no I/O.
    """
    return _FILENAMES["harness"], _dump(HARNESS_TEMPLATE)


#: The synthetic question the native template is exported from. NOT a record in
#: the database and not the result of a search: `native_template_json` builds it
#: with `new()`, which lives in the cache for the length of the call. A template
#: derived from `search([], limit=1)` would hand out somebody's real question and
#: would make a download route's cost depend on the size of the bank.
_NATIVE_SEED = {
    "name": "Capital of France",
    "prompt": "Which city is the capital of France?",
    "description": "Single correct answer.",
    "question_type": "mcq",
    "difficulty": "easy",
    "time_minutes": 1,
    "sequence": 10,
    "source_ref": "template:native",
    "official_reasoning": "Paris has been the capital since 1944.",
    # A STRING, not an object - the field holds serialised JSON and the
    # importer writes it through unparsed. Filled on an `mcq` so the template
    # exercises the field at all; it is only READ for subjective types.
    "subjective_rubric_json": json.dumps(
        [{"label": "Justification", "pass_condition": "Names the country."}],
        ensure_ascii=False),
    "grading_json": json.dumps({"mode": "objective"}, ensure_ascii=False),
    "meta_json": json.dumps({"authored_by": "template"}, ensure_ascii=False),
}

_NATIVE_SEED_GENERATOR = "Question Bank Import Template"

_NATIVE_SEED_DIMENSION = {
    "name": "Capital city",
    "options": ["Paris", "London", "Berlin", "Madrid"],
    "correct": "Paris",
}

_NATIVE_SEED_IMAGE = {
    "slot": "single",
    "label": "Map of France",
    "url": "%s/capital/512" % _ASSET_HOST,
}


def native_template_payload(env):
    """The native template as a dict, exported from ONE synthetic question.

    Self-maintaining by construction: the keys come from
    `question._export_native`, so a field added there appears here without an
    edit. Bounded by construction too - exactly one `new()` record, so the cost
    is the same whether the bank holds ten questions or ten million.
    """
    question = env["assessments.be.question"].new(dict(
        _NATIVE_SEED,
        generator_id=env["assessments.be.prompt"].new(
            {"name": _NATIVE_SEED_GENERATOR}),
        question_dimension_ids=[(0, 0, {
            "name": _NATIVE_SEED_DIMENSION["name"],
            "sequence": 10,
            "option_line_ids": [
                (0, 0, {
                    "name": option,
                    "sequence": (index + 1) * 10,
                    "is_correct": option == _NATIVE_SEED_DIMENSION["correct"],
                })
                for index, option in enumerate(_NATIVE_SEED_DIMENSION["options"])
            ],
        })],
        image_ids=[(0, 0, {
            "slot": _NATIVE_SEED_IMAGE["slot"],
            "label": _NATIVE_SEED_IMAGE["label"],
            "image_url": _NATIVE_SEED_IMAGE["url"],
            "sequence": 10,
        })],
    ))
    return {
        # The sentinel `_try_native_payload` fingerprints on, and the same one
        # `question.action_export_native_json` writes.
        "assessments_be_bank": "1",
        "questions": question._export_native(),
    }


def native_template_json(env):
    """``(filename, bytes)`` for the native round-trip template."""
    return _FILENAMES["native"], _dump(native_template_payload(env))


def template_json(flavor, env=None):
    """``(filename, bytes)`` for either flavour. The wizard button and the API
    route both come through here, which is why they cannot hand out different
    files."""
    if flavor == "harness":
        return harness_template_json()
    if flavor == "native":
        if env is None:
            raise ValueError("the native template needs an env to export from")
        return native_template_json(env)
    raise ValueError("unknown template flavour %r; expected one of %s"
                     % (flavor, ", ".join(FLAVORS)))


def template_api_payload(flavor, env=None):
    """The API download shape every other template route on this API uses -
    ``{filename, mimetype, content}`` with `content` base64. See
    `/api/v1/candidates/template`."""
    import base64

    filename, content = template_json(flavor, env=env)
    return {
        "filename": filename,
        "mimetype": "application/json",
        "content": base64.b64encode(content).decode("ascii"),
    }


# ── the schema doc ──────────────────────────────────────────────────────────
#
# The knowledge base's generated schema region is the OUTPUT of `schema_doc_markdown()`, and
# `test_import_parity.py` asserts the committed file still equals it. Editing
# the doc by hand fails the suite; the fix is to change the template or the
# field list here and regenerate. That is the whole point: the prose cannot
# describe a payload the importer no longer accepts.
#
# Deliberately env-free, so the file can be regenerated with plain Python:
#
#     python -c "from bank_json_template import write_schema_doc; write_schema_doc()"

_DOC_HEADER = """<!-- GENERATED FILE - do not edit by hand.

Rendered by `services/bank_json_template.py:schema_doc_markdown()`, and
`tests/test_import_parity.py` asserts this file still equals that render. To
change it, edit the template or the field list in that module and regenerate:

    python -c "import sys; sys.path.insert(0, 'services'); \\
        import bank_json_template as t; t.write_schema_doc()"
-->

# Importing a question bank as JSON

The importer accepts THREE formats through one file box, and works out which it
is holding rather than asking. Whichever surface you drop the file into - the
Odoo wizard (Question Bank > Import) or `POST /api/v1/bank/import` - it is the
same parser, so the same file produces the same records.

## Which format is which

The wizard sniffs in this order (`bank_import_wizard.run_import`):

| Order | Format | Recognised by | Lands as |
|---|---|---|---|
| 1 | **harness** | a top-level list, or an object with `questions`, whose first item has a `fields` key or both `instruction` and `id` (`_try_harness_payload`) | review DRAFTS on a generator, for approval |
| 2 | **native** | an object carrying `assessments_be_bank` AND a `questions` list (`_try_native_payload`) | LIVE questions in the bank, rebuilt as exported |
| 3 | **CSV** | anything else, with a `title` or `prompt` column | approved questions on a generator |

A harness file that omits both `fields` and `id` is not recognised as harness,
falls through to the CSV path, and is refused for having no header row. If an
import reports the wrong format, that fingerprint is why.

Download a filled example of either JSON format from the wizard footer, or from
`GET /api/v1/bank/template/json?flavor=harness` (`flavor=native` for the other).
Both surfaces return the same bytes.

"""

_DOC_HARNESS_INTRO = """## The harness format

What the authoring harness writes: `questions.json` (a bare list) or
`output.json` (`{{questions, solutions}}`). Solutions are keyed by the
question's own `id`, which is the ONE field that has to line up between the two
halves.

Imported by `bank_import.import_bank_harness`. Questions arrive as review
drafts, NOT as live bank questions - an admin approves them through the normal
pipeline, and that approval is when any asset URL is actually downloaded.

{table}

### Example

```json
{payload}
```

"""

_DOC_NATIVE_INTRO = """## The native round-trip format

What `question._export_native` writes and `import_bank_native` reads: a lossless
export, used to move a bank between instances. It writes LIVE questions
directly, so it needs no approval step - and no generator, unless a question
names one.

An `assessments_be_bank` sentinel at the top level is what tells the importer
this is a native file rather than a harness one. Without it, a file with a
`questions` list is read as harness.

Every field below is a key of one entry in `questions`.

{table}

### Example

The Question Bank list's **Export Native JSON** action emits exactly this shape.
For a filled one-question example, download
`GET /api/v1/bank/template/json?flavor=native`, or use the wizard's
**JSON Template (Native)** button.

"""

_DOC_ASSETS = """## The asset rule, and why a local path is not enough

`_apply_harness_assets` attaches an asset only when it carries an `http(s)`
address in `url` or `file`. Anything else - `assets/q01_a.png`, an absolute path
on the machine that ran the harness - is reported in the import warnings and has
to be uploaded by hand, because Odoo has no access to the harness's filesystem.

The address is only WRITTEN at import time. The download happens later, when the
draft is approved (`prompt._materialize_images` -> `services/image_ingest`),
with a 20-second timeout and no redirect following. So an unreachable URL does
not fail the import; it fails the approval, where it can be corrected.

## Limits

| Limit | Value | Where |
|---|---|---|
| JSON payload | 50 MB | `bank_import._coerce_json` |
| CSV upload | 25 MB | `bank_import_wizard._MAX_CSV_BYTES` |
| CSV rows | 5000 | `bank_import_wizard._MAX_CSV_ROWS` |

Both JSON paths parse the whole payload into memory in one go and create one
record per question inside a single transaction, so a large file is best split
into batches even where no explicit row cap refuses it.
"""


def _field_table(fields):
    lines = ["| Field | Required | Notes |", "|---|---|---|"]
    for field in fields:
        lines.append("| `%s` | %s | %s |" % (
            field.path, "yes" if field.required else "no", field.note))
    return "\n".join(lines)


def schema_doc_markdown():
    """The schema section of the knowledge base, rendered from the definitions above."""
    return "".join([
        _DOC_HEADER,
        _DOC_HARNESS_INTRO.format(
            table=_field_table(HARNESS_FIELDS),
            payload=json.dumps(HARNESS_TEMPLATE, indent=2,
                               ensure_ascii=False)),
        _DOC_NATIVE_INTRO.format(table=_field_table(NATIVE_FIELDS)),
        _DOC_ASSETS,
    ])


#: The knowledge base owns ONE managed region, and these mark it.
#:
#: The schema prose used to be its own file, which made the anti-drift rule
#: easy: the file WAS the render, so comparing them was a string equality. The
#: docs are now consolidated into a single knowledge base, and a generator
#: cannot own a hand-written 8,000-line file - so it owns a delimited region
#: inside it instead, and the same equality still holds over that region.
#:
#: HTML COMMENTS, so the markers are invisible in every renderer while staying
#: greppable in the source.
DOC_BEGIN = "<!-- BEGIN GENERATED: bank-import-json-schema -->"
DOC_END = "<!-- END GENERATED: bank-import-json-schema -->"


def doc_path():
    """The knowledge base. One file, per the docs consolidation."""
    import os

    return os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "docs", "ETP_KNOWLEDGE_BASE.md")


def _split_doc(text):
    """(before, region, after) around the managed block.

    Raises rather than guessing: a knowledge base whose markers have been
    deleted must fail loudly at the point somebody regenerates, not silently
    append a second copy of the schema.
    """
    start = text.find(DOC_BEGIN)
    end = text.find(DOC_END)
    if start == -1 or end == -1 or end < start:
        raise ValueError(
            "the knowledge base has no %s / %s region - restore the markers "
            "before regenerating" % (DOC_BEGIN, DOC_END))
    return (text[:start + len(DOC_BEGIN)],
            text[start + len(DOC_BEGIN):end],
            text[end:])


def committed_schema_doc():
    """What the knowledge base currently carries in the managed region."""
    with open(doc_path(), encoding="utf-8") as handle:
        return _split_doc(handle.read())[1]


def write_schema_doc():
    """Rewrite the managed region of the knowledge base.

    Run this after editing anything above. Everything outside the two markers
    is left byte-for-byte alone, so the hand-written parts of the knowledge
    base are never touched by a regeneration.
    """
    path = doc_path()
    with open(path, encoding="utf-8") as handle:
        before, _old, after = _split_doc(handle.read())
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(before + "\n" + schema_doc_markdown() + "\n" + after)
    return path
