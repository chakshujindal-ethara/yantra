"""The SOP's `skill:` tags must survive question generation.

WHAT WAS BROKEN. `_capture_sop_metadata` runs during QUESTION GENERATION and
wrote the generator's tags with a `(6, 0, ...)` command built from the generation
`mapping` list. That is a REPLACE: whatever tag extraction had already stored was
discarded and only what generation happened to mention survived. In practice the
mapping carries modality/output-format and the odd domain, so every `skill:`
facet was dropped.

WHY IT MATTERED. `skill:` IS the vocabulary the per-category strengths and
weaknesses are computed from. With the skills gone, the backfill copied
domain/modality/output-format onto each question, the category breakdown had
nothing to group by, and the strengths/weaknesses card came out empty for a paper
where every question had in fact been marked.

Observed on a live run against a real SOP: extraction reported four skills, the
generator ended with six non-skill tags and no skills at all, and all eight
generated questions were unusable for categories.

TransactionCase and a direct call into the service, matching
test_backfill_tags_to_questions: the rule under test is the write, not the
transport, and it must not need a Vertex call to prove.
"""
import json
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestSopTagsSurviveGeneration(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Generator = self.env["assessments.be.prompt"]
        self.Tag = self.env["assessments.be.tag"]

    def _tag(self, name):
        """A tag with a REAL faceted key, so `prefix` computes to the facet."""
        facet, value = name.split(":", 1)
        return self.Tag.create(
            {"name": "%s:%s-%s" % (facet, value, uuid4().hex[:6])})

    def _generator(self, tags):
        return self.Generator.create({
            "name": "Forklift SOP %s" % uuid4().hex[:6],
            "tag_ids": [(6, 0, tags.ids)],
        })

    def test_extraction_skills_survive_a_generation_capture(self):
        """The regression: generation must ADD its mapping, never replace."""
        from odoo.addons.assessments_be_v2.services import vertex

        skill_a = self._tag("skill:pre-shift-inspection")
        skill_b = self._tag("skill:load-handling")
        domain = self._tag("domain:warehouse-safety")
        generator = self._generator(skill_a | skill_b | domain)

        # What generation reports: question-shaped facets only, exactly the
        # shape that used to wipe the skills.
        vertex._capture_sop_metadata(self.env, generator, json.dumps({
            "metadata": {"mapping": ["modality:text", "output-format:mcq"]},
        }))

        self.assertIn(skill_a, generator.tag_ids)
        self.assertIn(skill_b, generator.tag_ids)
        self.assertIn(domain, generator.tag_ids)

    def test_the_generations_own_mapping_is_still_added(self):
        """Adding must not become ignoring - the mapping still has to land."""
        from odoo.addons.assessments_be_v2.services import vertex

        skill = self._tag("skill:pedestrian-awareness")
        generator = self._generator(skill)

        vertex._capture_sop_metadata(self.env, generator, json.dumps({
            "metadata": {"mapping": ["modality:text"]},
        }))

        names = generator.tag_ids.mapped("name")
        self.assertIn(skill.name, names)
        self.assertTrue(
            any(n.startswith("modality:") for n in names),
            "the mapping's own facets are still copied onto the generator",
        )

    def test_a_capture_with_no_mapping_leaves_the_tags_alone(self):
        from odoo.addons.assessments_be_v2.services import vertex

        skill = self._tag("skill:hazard-identification")
        generator = self._generator(skill)
        before = generator.tag_ids

        vertex._capture_sop_metadata(
            self.env, generator, json.dumps({"metadata": {"summary": "x"}}))

        self.assertEqual(generator.tag_ids, before)

    def test_the_source_does_not_replace_the_tag_set(self):
        """Read as source, because the defect was one command character.

        `(6, 0, ids)` replaces, `(4, id)` adds. A future edit that reaches for
        the convenient `(6, 0, ...)` form here reintroduces the bug silently -
        the tags simply stop being there, with nothing raised.
        """
        import inspect

        from odoo.addons.assessments_be_v2.services import vertex

        # The INNER function, not the wrapper. `_capture_sop_metadata` is now a
        # savepoint around `_capture_sop_metadata_inner`, so reading the wrapper's
        # source finds no tag handling at all and this guard silently passes
        # nothing. Assert the split actually found the block for that reason.
        source = inspect.getsource(vertex._capture_sop_metadata_inner)
        marker = "mapping = meta.get(\"mapping\")"
        self.assertIn(marker, source,
                      "the mapping block moved; this guard is reading the "
                      "wrong function and would pass vacuously")
        mapping_block = source.split(marker)[-1]
        self.assertNotIn(
            'vals["tag_ids"] = [(6, 0, tag_recs.ids)]',
            mapping_block,
            "that is a REPLACE; it drops every skill extraction stored",
        )
        self.assertIn("(4, tid)", mapping_block)

    def test_a_database_error_does_not_poison_the_transaction(self):
        """The swallow must be scoped by a savepoint.

        A failed write inside a Postgres transaction ABORTS it. This function
        swallows its own errors by design (a malformed metadata block must not
        lose a paid-for generation run), so without a savepoint a DB error left
        generation running on a dead cursor and every later statement failed with
        "current transaction is aborted, commands ignored until end of
        transaction block" - which is what the admin saw after pressing Generate,
        instead of the real cause.
        """
        import inspect

        from odoo.addons.assessments_be_v2.services import vertex

        wrapper = inspect.getsource(vertex._capture_sop_metadata)
        self.assertIn("savepoint()", wrapper,
                      "without a savepoint the swallowed error takes the whole "
                      "transaction down with it")
        self.assertIn("_capture_sop_metadata_inner", wrapper)

        inner = inspect.getsource(vertex._capture_sop_metadata_inner)
        self.assertIn(
            "raise", inner,
            "the inner handler must RE-RAISE psycopg2 errors so the savepoint "
            "can roll them back; swallowing them there defeats the wrapper")
