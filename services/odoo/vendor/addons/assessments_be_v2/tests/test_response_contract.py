"""What the server SENDS, checked against what it means.

WHY THIS FILE EXISTS. `tools/contract_audit.py` audits one direction: every key
the Dart client sends against every key each route reads. Its docstring names
the three bugs that justified it - `person_ids` vs `applicant_ids`, `dry_run`
vs `confirm`, `option_ids` vs `selected_option_ids` - and all three are
client-to-server.

Nothing checked the other direction, and the other direction is where the next
bug was. `draft_detail` sent `dimensions` out of `dimensions_json`, a column the
generator fills for `image_ab` and NOTHING else. For every mcq and msq it sent
`dimensions: []` while the answer key sat in `options_json` and in the
relational `answer_dimension_ids` rows - so the client rendered five options as
none, and printed "no correct option marked" over a key the server had stored
correctly. No error, no 400, no failing test: an unread response key is silence
in exactly the way an unread request key is.

The tests here are about MEANING rather than shape. A key that is present but
computed from the wrong column is what shipped, so asserting that `dimensions`
exists would not have caught it. Asserting that it equals what approval will
publish would.
"""
import json
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.controllers.api import serializers as S


@tagged("-at_install", "post_install")
class _DraftBase(TransactionCase):
    def setUp(self):
        super().setUp()
        self.Generator = self.env["assessments.be.prompt"]
        self.Draft = self.env["assessments.be.prompt.question"]

    def _gen(self):
        return self.Generator.create({"name": "Gen %s" % uuid4().hex[:6]})

    def _draft(self, qtype="msq", options=None, correct=None, **extra):
        """A draft exactly as the generator writes one: flat JSON only.

        Nothing here creates `answer_dimension_ids` by hand - `create()` syncs
        them from the JSON, and that behaviour is half of what is under test.
        """
        options = ["Alpha", "Bravo", "Charlie"] if options is None else options
        if correct is None:
            correct = ["Alpha", "Charlie"] if qtype == "msq" else "Alpha"
        vals = {
            "prompt_id": self._gen().id,
            "name": "Draft %s" % uuid4().hex[:6],
            "question_prompt": "Pick the right one",
            "question_type": qtype,
            "difficulty": "easy",
            "options_json": json.dumps(options),
            "correct_answer_json": json.dumps(correct),
        }
        vals.update(extra)
        return self.Draft.create(vals)

    @staticmethod
    def _key(rows):
        """{axis label -> the set of option names marked correct}."""
        return {
            row["label"]: frozenset(
                o["name"] for o in row["options"] if o["is_correct"])
            for row in rows
        }


class TestTheDraftKeyIsSerialized(_DraftBase):
    """The reported bug, pinned at the level it actually broke."""

    def test_a_generated_draft_gets_relational_rows(self):
        """`create()` seeds the axis tree from the JSON.

        The route that edits a draft carried a comment asserting the opposite -
        that these rows "are not populated for generated drafts" - and that
        false belief is why the edit path never rebuilt them. Pinning the real
        behaviour is what stops the comment coming back.
        """
        draft = self._draft()
        self.assertTrue(
            draft.answer_dimension_ids,
            "a draft created from flat JSON has no axis rows, so every "
            "downstream assumption about which key is published is wrong")
        self.assertEqual(
            {o.name for o in draft.answer_dimension_ids.option_line_ids
             if o.is_correct},
            {"Alpha", "Charlie"})

    def test_an_msq_key_reaches_the_wire(self):
        """Five options in, five options out, with the right ones flagged."""
        draft = self._draft(
            options=["Upload buttons", "Navigation elements",
                     "Static background images", "Tabs",
                     "Plain text paragraphs"],
            correct=["Upload buttons", "Navigation elements", "Tabs"])
        rows = S.draft_row(draft)["dimensions"]
        self.assertEqual(len(rows), 1)
        self.assertEqual(len(rows[0]["options"]), 5,
                         "the option list arrived empty")
        self.assertEqual(
            {o["name"] for o in rows[0]["options"] if o["is_correct"]},
            {"Upload buttons", "Navigation elements", "Tabs"})

    def test_the_serialized_key_is_what_approve_will_publish(self):
        """The one that matters.

        `_dimension_specs` is what `_materialize_dimensions` publishes into the
        bank at approve time. A reviewer approving what they were shown must get
        what they approved, so the preview is bound to the publisher rather than
        to any column that merely resembles it. Under the old code this failed
        for every mcq and msq: the serializer read `dimensions_json` and the
        publisher read the axis rows.
        """
        for qtype in ("mcq", "msq"):
            with self.subTest(qtype=qtype):
                draft = self._draft(qtype=qtype)
                published = {
                    spec["label"]: frozenset(spec["correct"])
                    for spec in draft._dimension_specs()
                }
                self.assertEqual(
                    self._key(S.draft_dimensions(draft)), published,
                    "the key shown to the reviewer is not the key approving "
                    "would publish")

    def test_row_and_detail_agree_on_the_key(self):
        """A detail route must not narrow a key the row got right.

        `draft_detail` used to overwrite the row's `dimensions` with a different
        column. Two routes disagreeing about one question's answer is worse than
        either being wrong alone, because which one a screen believes depends on
        whether it happened to fetch the detail yet.
        """
        draft = self._draft()
        row, detail = S.draft_row(draft), S.draft_detail(draft)
        self.assertEqual(row["dimensions"], detail["dimensions"])
        self.assertEqual(row["has_valid_key"], detail["has_valid_key"])

    def test_the_flag_and_the_tree_cannot_disagree(self):
        """`has_valid_key` is derived from the same rows it describes."""
        good = self._draft()
        self.assertTrue(S.draft_row(good)["has_valid_key"])

        blind = self._draft(correct=[])
        self.assertFalse(
            S.draft_row(blind)["has_valid_key"],
            "a draft with nothing marked correct reported a usable key")

        # Every non-objective type is valid by default - it is marked by a
        # rubric, not by a correct option. Same rule as the bank's own compute.
        rubric = self._draft(qtype="subjective_rubric", options=[], correct=[])
        self.assertTrue(S.draft_row(rubric)["has_valid_key"])

    def test_a_json_only_draft_still_serializes(self):
        """The fallback path, for a draft whose axis rows were never built."""
        draft = self._draft()
        draft.answer_dimension_ids.unlink()
        rows = S.draft_dimensions(draft)
        self.assertEqual(len(rows), 1)
        self.assertEqual(
            {o["name"] for o in rows[0]["options"] if o["is_correct"]},
            {"Alpha", "Charlie"})
        self.assertIsNone(rows[0]["id"],
                          "a row with no record must not claim an id")


class TestEditingTheKeyIsNotDiscarded(_DraftBase):
    """The second bug: a 200 that changed nothing that mattered.

    `/drafts/<id>/update` wrote `options_json` and stopped. `_dimension_specs`
    prefers the relational rows, so approving after an edit published the
    PRE-EDIT key. The save reported success, the detail route echoed the new
    values back, and the bank question came out with the old answer.
    """

    def test_writing_the_json_alone_leaves_the_published_key_stale(self):
        """THE NEGATIVE CONTROL, and the reason the next test proves anything.

        This is the old behaviour, asserted deliberately: without it, a rebuild
        that silently did nothing would look identical to a rebuild that worked.
        """
        draft = self._draft(correct=["Alpha"])
        draft.write({"correct_answer_json": json.dumps(["Bravo"])})
        published = {frozenset(s["correct"]) for s in draft._dimension_specs()}
        self.assertEqual(
            published, {frozenset(["Alpha"])},
            "the relational rows changed on their own, so this test no longer "
            "controls for anything")

    def test_the_rebuild_moves_the_published_key(self):
        draft = self._draft(correct=["Alpha"])
        draft.write({"correct_answer_json": json.dumps(["Bravo"])})
        draft.action_rebuild_answer_key_from_json()
        published = {
            spec["label"]: frozenset(spec["correct"])
            for spec in draft._dimension_specs()
        }
        self.assertEqual(set(published.values()), {frozenset(["Bravo"])})
        self.assertEqual(
            self._key(S.draft_dimensions(draft)), published,
            "the wire and the publisher disagree after an edit")


class TestDraftMediaCarriesNoBytes(_DraftBase):
    """Draft media is a URL, not half a megabyte of base64.

    `images_json` and `video_files_json` hold whole `data:` URIs, and the review
    queue re-fetches the detail route for every card it moves to - so walking a
    queue of A/B drafts shipped about a megabyte per keystroke. The proxy routes
    that serve these bytes already existed and were already reachable with the
    client's bearer token.
    """

    def _staged(self):
        return self._draft(
            qtype="image_ab",
            options=[], correct=[],
            dimensions_json=json.dumps([
                {"label": "Instruction Following",
                 "options": ["Response A", "Response B"],
                 "correct": ["Response A"]},
            ]),
            images_json=json.dumps([
                {"slot": "a", "label": "Response A",
                 "data": "data:image/png;base64,iVBORw0KGgo="},
                {"slot": "b", "label": "Response B",
                 "url": "https://example.invalid/b.png"},
            ]))

    def test_no_base64_reaches_the_client(self):
        detail = S.draft_detail(self._staged())
        blob = json.dumps(detail["images"] + detail["video_files"])
        self.assertNotIn(
            "data:", blob,
            "a staged image is still being shipped inline as base64")

    def test_every_staged_slot_gets_a_proxy_url_with_a_cache_buster(self):
        detail = S.draft_detail(self._staged())
        self.assertEqual(len(detail["images"]), 2)
        for image in detail["images"]:
            self.assertTrue(
                image["admin_url"].startswith(
                    "/assessments_be/admin_draft_qimage/"),
                image["admin_url"])
            # Without this the browser keeps serving the previous picture after
            # `apply_image` - the one moment a reviewer must see the new one.
            self.assertIn("?v=", image["admin_url"])

    def test_a_slot_with_nothing_staged_gets_no_url(self):
        """An empty string reads as "absent"; a URL that 404s reads as broken."""
        draft = self._draft(
            qtype="image_ab", options=[], correct=[],
            images_json=json.dumps([{"slot": "a", "label": "Response A"}]))
        self.assertEqual(S.draft_detail(draft)["images"][0]["admin_url"], "")


class TestMediumNamesTheMedium(_DraftBase):
    def test_video_is_not_reported_as_text(self):
        """A `video_prompt` draft said its medium was Text, over a staged clip.

        Three media exist and the module's own MEDIUM_SELECTION has named all
        three all along; the compute only ever returned two of them.
        """
        cases = {"video_prompt": "Video", "image_ab": "Image", "mcq": "Text",
                 "image_label": "Image", "subjective_rubric": "Text"}
        for qtype, expected in cases.items():
            with self.subTest(qtype=qtype):
                draft = self._draft(qtype=qtype, options=[], correct=[])
                self.assertEqual(S.draft_row(draft)["medium"], expected)


class TestNoDetailRouteNarrowsItsRow(_DraftBase):
    """A `*_detail` payload must be a superset of its `*_row`, in VALUE.

    Presence is not the property that broke - `dimensions` was present on both.
    The detail simply meant something different by it. So this compares values,
    which is the only version of the check that would have failed.
    """

    def test_draft_detail_is_a_superset_of_draft_row(self):
        draft = self._draft()
        row, detail = S.draft_row(draft), S.draft_detail(draft)
        self.assertLessEqual(set(row), set(detail))
        for key, value in row.items():
            self.assertEqual(
                value, detail[key],
                "draft_detail redefines %r, so which value a screen believes "
                "depends on whether it fetched the detail yet" % key)
