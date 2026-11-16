# -*- coding: utf-8 -*-
"""R6: a release shows the answer key unless the admin turns it off.

`results_show_answers` defaults to True, today's behaviour, so -u fills every
existing paper with True and nothing a candidate sees changes. What the review
hides when it is off is tested beside the serializer.
"""
from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestTheAnswerKeyIsShownByDefault(TransactionCase):

    def test_a_new_paper_shows_the_key_and_can_hold_it_back(self):
        paper = self.env["assessments.be"].create({"name": "Key shown"})
        self.assertTrue(paper.results_show_answers)
        paper.results_show_answers = False
        self.assertFalse(paper.copy().results_show_answers,
                         "a copy keeps the setting")

    def test_a_paper_inserted_by_an_old_pod_shows_the_key(self):
        """During a rolling deploy a pod still on the old code inserts papers
        without this column. With no database default the row held NULL,
        which the ORM reads as False - the key hidden, against a default of
        shown. The insert below is that pod's, by raw SQL."""
        paper = self.env["assessments.be"].create({"name": "Old pod"})
        self.env.flush_all()
        cr = self.env.cr
        cr.execute("""
            SELECT column_name FROM information_schema.columns
             WHERE table_name = 'assessments_be'
               AND column_name NOT IN ('id', 'results_show_answers')""")
        columns = ", ".join('"%s"' % name for name, in cr.fetchall())
        cr.execute("INSERT INTO assessments_be (%s) SELECT %s FROM "
                   "assessments_be WHERE id = %%s RETURNING id"
                   % (columns, columns), (paper.id,))
        inserted = self.env["assessments.be"].browse(cr.fetchone()[0])

        self.assertTrue(inserted.results_show_answers)
