"""What the model DECLARES and what Postgres actually enforces must agree.

THE BUG CLASS (SNo 126, SNo 127b). Odoo 19 stopped reading `_sql_constraints`.
It does not raise, and it does not skip the model - it logs

    Model attribute '_sql_constraints' is no longer supported,
    please define model.Constraint on the model

at registry load and carries on. So `assessments.be.similarity` declared

    _sql_constraints = [("uniq_pair", "unique(source_id, target_id)", ...)]

for as long as that file has existed, while the database held no such
constraint - confirmed directly: `assessments_be_similarity` carried its primary
key and its two foreign keys and nothing else. Duplicate (source, target) pairs
were always insertable, and a duplicate pair double-counts one SOP against a
target in every similarity read.

THIS IS THE DANGEROUS SHAPE OF DEPRECATION, and it is why these tests query
Postgres rather than the model. The Python still says what it always said. Every
test that never inserted a duplicate still passed. `self.env[...]._constraints`
would have looked fine. Only `pg_constraint` knew - so `pg_constraint` is what is
asserted. A test that read the declaration back would have passed against the
broken build, which makes it worthless.

THE SAME REASONING COVERS THE INDEX. `assessments_be_response_line` is the
fastest-growing table in the schema (one row per answered dimension, not per
answer) and it had exactly ONE index, its primary key - so every read of an
answer's lines scanned it, and `ondelete="cascade"` makes Postgres re-scan per
parent row deleted. `index=True` is the declaration; `pg_indexes` is the fact.

NOT SWEPT HERE, DELIBERATELY. The same dead `_sql_constraints` exists in 25+
sibling addons in this monorepo. They are outside this module and outside this
handover, so they are reported rather than edited - but the guard below stops
OURS from regressing.
"""
from psycopg2 import IntegrityError

from odoo.tests.common import TransactionCase, tagged
from odoo.tools import mute_logger


@tagged("-at_install", "post_install")
class TestTheSchemaMatchesWhatTheCodeClaims(TransactionCase):

    # ── the constraint ────────────────────────────────────────────────

    def test_the_similarity_pair_constraint_exists_in_postgres(self):
        """THE FACT, read from the catalogue rather than from the model."""
        self.env.cr.execute(
            """
            SELECT conname FROM pg_constraint
             WHERE conrelid = 'assessments_be_similarity'::regclass
               AND contype = 'u'
            """)
        found = [r[0] for r in self.env.cr.fetchall()]
        self.assertTrue(
            found,
            "assessments_be_similarity has NO unique constraint. The model "
            "declares one; Odoo 19 ignores `_sql_constraints` silently, so the "
            "declaration and the database disagreed and duplicates were "
            "insertable")

    def test_a_duplicate_pair_is_actually_refused(self):
        """THE BEHAVIOUR, which is the only thing that really matters.

        A constraint that exists but does not fire would satisfy the catalogue
        test above, so the refusal is provoked directly.
        """
        prompt = self.env["assessments.be.prompt"]
        a = prompt.create({"name": "Schema probe source"})
        b = prompt.create({"name": "Schema probe target"})
        sim = self.env["assessments.be.similarity"]
        sim.create({"source_id": a.id, "target_id": b.id, "overall": 40})
        self.env.flush_all()

        with self.assertRaises(IntegrityError, msg=(
                "a second row for the same (source, target) was accepted, so "
                "one SOP can be double-counted against a target")):
            with mute_logger("odoo.sql_db"):
                sim.create({"source_id": a.id, "target_id": b.id,
                            "overall": 90})
                self.env.flush_all()

    def test_a_different_pair_is_still_allowed(self):
        """The constraint must bound duplicates, not uniqueness per source.

        `unique(source_id, target_id)` - not unique(source_id). One SOP is
        compared against many targets by design, so a constraint that refused
        the second target would break the feature while passing the test above.
        """
        prompt = self.env["assessments.be.prompt"]
        a = prompt.create({"name": "Schema probe source 2"})
        b = prompt.create({"name": "Schema probe target 2a"})
        c = prompt.create({"name": "Schema probe target 2b"})
        sim = self.env["assessments.be.similarity"]
        sim.create({"source_id": a.id, "target_id": b.id, "overall": 40})
        sim.create({"source_id": a.id, "target_id": c.id, "overall": 55})
        self.env.flush_all()

        self.assertEqual(
            sim.search_count([("source_id", "=", a.id)]), 2,
            "one source must be comparable against many targets")

    def test_no_model_in_this_addon_still_uses_sql_constraints(self):
        """THE REGRESSION GUARD, over the whole addon rather than one file.

        Nothing fails when somebody adds a `_sql_constraints` back: the registry
        logs a line nobody reads and the constraint quietly never exists. So the
        only way this stays fixed is a test that refuses the attribute outright.
        """
        import os

        here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        offenders = []
        for root, _dirs, files in os.walk(os.path.join(here, "models")):
            for name in files:
                if not name.endswith(".py"):
                    continue
                path = os.path.join(root, name)
                with open(path, encoding="utf-8") as fh:
                    for lineno, line in enumerate(fh, 1):
                        if line.lstrip().startswith("_sql_constraints"):
                            offenders.append("%s:%d" % (name, lineno))
        self.assertFalse(
            offenders,
            "Odoo 19 IGNORES `_sql_constraints`, so these declare a constraint "
            "the database will not have. Use `models.Constraint` instead: %s"
            % ", ".join(offenders))

    # ── the index ─────────────────────────────────────────────────────

    def test_every_hot_path_foreign_key_is_indexed(self):
        """THE SWEEP, because fixing only the one that was noticed is not a fix.

        `response_line.response_id` is what SNo 127 named, but a catalogue query
        for foreign keys with no leading index returned THIRTEEN across this
        addon - `assessments_be_response.evaluator_id` among them, which is
        `required=True` on the answers table. Nine of those are on paths that
        scale with the number of candidates, and those nine are asserted here.

        The other four (generator_id, the two prompt_question links,
        prompt_resource.prompt_id) are generation-time and deliberately NOT
        indexed - an index costs a B-tree insert on every write, and this module
        is trying to write less, not more. They are named in
        migrations/19.0.3.18.0 so the omission reads as a decision.
        """
        wanted = [
            ("assessments_be_response", "evaluator_id"),
            ("assessments_be_response_line", "response_id"),
            ("assessments_be_response_line", "question_dimension_id"),
            ("assessments_be_response_line", "selected_option_id"),
            ("assessments_be_evaluator", "applicant_id"),
            ("assessments_be_question_dimension", "question_id"),
            ("assessments_be_question_dimension_option",
             "question_dimension_id"),
            ("assessments_be_question_image", "question_id"),
            ("assessments_be_question_video", "question_id"),
            ("assessments_be_llm_usage", "evaluator_id"),
        ]
        # Asked of the catalogue as ONE question, so the failure names every
        # missing index at once instead of stopping at the first.
        self.env.cr.execute(
            """
            SELECT c.conrelid::regclass::text, a.attname
              FROM pg_constraint c
              JOIN unnest(c.conkey) WITH ORDINALITY k(attnum, ord) ON TRUE
              JOIN pg_attribute a
                ON a.attrelid = c.conrelid AND a.attnum = k.attnum
             WHERE c.contype = 'f'
               AND NOT EXISTS (
                   SELECT 1 FROM pg_index i
                    WHERE i.indrelid = c.conrelid
                      AND i.indkey[0] = a.attnum)
            """)
        unindexed = {(t, c) for t, c in self.env.cr.fetchall()}
        missing = [w for w in wanted if w in unindexed]
        self.assertFalse(
            missing,
            "these foreign keys are read on a per-candidate path and have no "
            "index, so each read scans the table and each cascade or restrict "
            "re-scans it: %s"
            % ", ".join("%s.%s" % m for m in missing))

    def test_the_response_line_parent_link_is_indexed(self):
        """The fastest-growing table's parent link, read from `pg_indexes`."""
        self.env.cr.execute(
            """
            SELECT indexdef FROM pg_indexes
             WHERE tablename = 'assessments_be_response_line'
            """)
        defs = [r[0] for r in self.env.cr.fetchall()]
        self.assertTrue(
            any("(response_id" in d.replace(" ", "") or "(response_id)" in d
                for d in defs),
            "assessments_be_response_line has no index on response_id, so "
            "every read of an answer's lines scans the table and every cascade "
            "delete re-scans it. Indexes present: %s" % defs)

    def test_the_answers_table_keeps_its_hot_indexes(self):
        """The three columns the exam and the roster actually filter on.

        Pinned together because they are one decision: `assessment_id` was added
        for the roster counts (19.0.3.17.0) and it would be easy to drop one of
        the others while editing the same field block.
        """
        self.env.cr.execute(
            """
            SELECT indexdef FROM pg_indexes
             WHERE tablename = 'assessments_be_response'
            """)
        blob = " ".join(r[0] for r in self.env.cr.fetchall()).replace(" ", "")
        # THE COLUMN IS `assessment_evaluator_id`, not `evaluator_id` - the
        # first version of this test asserted the latter and failed against a
        # schema that was entirely correct. Reading the catalogue means using
        # the catalogue's names.
        for column in ("assessment_id", "question_id",
                       "assessment_evaluator_id"):
            self.assertIn(
                "(%s" % column, blob,
                "assessments_be_response.%s is not indexed" % column)
