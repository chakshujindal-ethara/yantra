"""Listing drafts must not read the rendered images it never sends.

THE DEFECT, measured during the pre-handover walkthrough: the admin app took
over a minute to leave its loading skeleton, and `POST /api/v1/drafts` was
73 SECONDS cold for 86 rows. Timed per field over the real recordset, the cost
was not in paging and not in the query:

    reading `name` alone   32.8s     <- a plain stored Char
    reading `has_images`  126.9s

`images_json` holds RENDERED BASE64 IMAGES - 213 MB across 147 rows on both
databases, averaging 3.8 MB a row, largest 5.5 MB. Two separate mechanisms each
pulled all of it for a payload that contains none of it:

  1. PREFETCH. Odoo fetches every stored field of a recordset on the first
     field read, so touching `name` dragged the base64 through the cursor.
     `images_json` is now `prefetch=False`, so it is read only when something
     actually wants the specs. That alone took `name` to 1.7s.

  2. A SHARED COMPUTE. `has_images` sat on `_compute_previews`, which parses
     the specs to build an HTML <figure> gallery AND resolves the answer-key
     preview beside it. `has_images` is a LIST field - a review-queue badge,
     and a key on every row of this route - so the cheap flag was charged the
     price of the expensive render. It now has its own compute with the same
     rule.

Result: 73.0s -> 6.6s cold, 481ms -> 70ms warm, with an identical payload.

WHAT IS NOT ASSERTED HERE, deliberately: wall-clock timings. A test that fails
when a laptop is busy is a test that gets muted. These pin the two MECHANISMS
instead - what gets read, and what the flag still answers - because those are
what regress if someone folds the compute back together or drops the prefetch
flag.
"""
import json
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestTheReviewQueueDoesNotLoadItsImages(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Draft = self.env["assessments.be.prompt.question"]
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Draft image fixture %s" % uuid4().hex[:6]})

    def _draft(self, images):
        """A draft carrying `images` as its spec list.

        The payload is deliberately a real base64 data URL rather than a URL:
        that is the shape that made the column 3.8 MB a row, and a `url` spec
        would not exercise the same branch.
        """
        return self.Draft.create({
            "name": "Draft %s" % uuid4().hex[:6],
            "prompt_id": self.generator.id,
            "question_type": "mcq",
            "question_prompt": "Pick one",
            "difficulty": "easy",
            "images_json": json.dumps(images) if images is not None else False,
        })

    _PNG = ("data:image/png;base64,"
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8"
            "z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==")

    # ── mechanism 1: the column is not prefetched ─────────────────────

    def test_reading_a_draft_name_does_not_fetch_its_images(self):
        """THE HEADLINE, and the reason `name` cost 32.8s.

        Asserted through the field cache rather than by timing: after reading
        `name`, `images_json` must NOT be in the cache. If it is, it came along
        for the ride - which is precisely the prefetch this fix removes, and no
        clock is needed to see it.
        """
        draft = self._draft([{"slot": "single", "label": "Plate",
                              "data": self._PNG}])
        draft.invalidate_recordset()

        self.assertEqual(draft.name[:5], "Draft", "the name reads back")

        field = self.Draft._fields["images_json"]
        cached = self.env.cache.contains(draft, field)
        self.assertFalse(
            cached,
            "reading `name` pulled images_json into the cache - the column "
            "holds megabytes of base64 per row and this is the 32.8s")

    def test_the_images_are_still_readable_when_asked_for(self):
        """The other half: not prefetched is not unreachable.

        A fix that made the specs hard to get would break the preview routes
        and the approve path, so the guarantee is only about WHEN it is read.
        """
        draft = self._draft([{"slot": "single", "label": "Plate",
                              "data": self._PNG}])
        draft.invalidate_recordset()

        specs = draft._image_specs()
        self.assertEqual(len(specs), 1, "the spec list still parses")
        self.assertEqual(specs[0]["label"], "Plate")

    # ── mechanism 2: the badge has its own compute ────────────────────

    def test_the_badge_does_not_build_the_html_gallery(self):
        """`has_images` must not drag `image_preview` in with it.

        The two shared `_compute_previews`, so asking for the flag rendered a
        <figure> per image and the answer-key preview beside it. Same cache
        argument as above: if `image_preview` is populated after reading only
        the flag, the computes are still fused.
        """
        draft = self._draft([{"slot": "single", "label": "Plate",
                              "data": self._PNG}])
        draft.invalidate_recordset()

        self.assertTrue(draft.has_images, "the flag still answers True")

        self.assertFalse(
            self.env.cache.contains(draft,
                                    self.Draft._fields["image_preview"]),
            "reading has_images also rendered image_preview - the flag is "
            "back on the previews compute and pays for the HTML again")

    # ── the rule itself is unchanged ──────────────────────────────────

    def test_the_flag_answers_exactly_what_it_did_before(self):
        """A faster answer that differs anywhere is a new bug, not a fix.

        These four cases are the whole rule as `_compute_previews` had it: a
        spec counts when it carries one of the source keys, and a spec list
        with no source at all is False - the old code skipped exactly those
        when building the gallery, so `has_images` was False for them too.
        Verified equal against the pre-fix parse on all 147 rows of the live
        clone; these pin the boundaries in the suite.
        """
        cases = (
            ("no column at all", None, False),
            ("an empty list", [], False),
            ("a spec with base64 data", [{"slot": "s", "data": self._PNG}],
             True),
            ("a spec with a url", [{"slot": "s", "url": "http://x/y.png"}],
             True),
            ("an annotated overlay only",
             [{"slot": "s", "annotated_url": "http://x/o.png"}], True),
            # THE BOUNDARY that a naive "is the list non-empty" rewrite gets
            # wrong: a brief exists but nothing has rendered yet, so there is
            # no image to badge.
            ("a spec carrying no source", [{"slot": "s", "label": "Pending"}],
             False),
        )
        for label, images, expected in cases:
            with self.subTest(label):
                draft = self._draft(images)
                draft.invalidate_recordset()
                self.assertEqual(
                    draft.has_images, expected,
                    "has_images for %s should be %s" % (label, expected))

    def test_unparseable_json_is_not_an_error(self):
        """A malformed column must answer False, not raise.

        `_image_specs` already swallowed a parse failure, and the review queue
        has to render even when a generator wrote something odd - a list that
        500s is worse than a missing badge.
        """
        draft = self.Draft.create({
            "name": "Draft %s" % uuid4().hex[:6],
            "prompt_id": self.generator.id,
            "question_type": "mcq",
            "question_prompt": "Pick one",
            "difficulty": "easy",
            "images_json": "{not json",
        })
        draft.invalidate_recordset()
        self.assertFalse(draft.has_images)

    def test_the_list_row_still_carries_the_badge(self):
        """The payload is unchanged, which is the point of the whole fix.

        The review queue renders its badge from the LIST row (the client
        replaces its draft cache on every refresh, so a detail-only field
        vanishes after the next action). Serialising the row here rather than
        asserting on the model catches a fix that made the model fast by
        dropping the key the client reads.
        """
        from ..controllers.api import serializers as S

        draft = self._draft([{"slot": "single", "label": "Plate",
                              "data": self._PNG}])
        row = S.draft_row(draft)
        self.assertIn("has_images", row, "the row lost its badge")
        self.assertTrue(row["has_images"])
        # And the base64 itself is still not on the row - the reason the
        # prefetch was pure waste.
        self.assertNotIn("images_json", row)
        self.assertNotIn(self._PNG, json.dumps(row),
                         "the row is carrying the raw image data")

    def test_listing_a_draft_does_not_write_it(self):
        """Serialising a row is a READ. `_compute_previews` once also assigned
        `has_images`, a field another compute owns, and Odoo turns that into a
        real `write()`: every `/api/v1/drafts` poll stamped `write_date` on
        every listed draft, raced the image-render cron into
        SerializationFailure and changed each image's `?v=` URL (stage,
        2026-10-13)."""
        from ..controllers.api import serializers as S

        draft = self._draft([{"slot": "single", "label": "Plate",
                              "data": self._PNG}])
        self.env.flush_all()
        self.env.cr.execute(
            "UPDATE assessments_be_prompt_question "
            "SET write_date = '2020-01-01' WHERE id = %s", [draft.id])
        draft.invalidate_recordset()

        S.draft_row(draft)
        draft.image_preview  # the form view's gallery, same compute
        self.env.flush_all()

        self.env.cr.execute(
            "SELECT write_date FROM assessments_be_prompt_question "
            "WHERE id = %s", [draft.id])
        self.assertEqual(str(self.env.cr.fetchone()[0]), "2020-01-01 00:00:00")
