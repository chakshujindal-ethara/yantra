# -*- coding: utf-8 -*-
"""Odoo's generic "Import records" is off the Question Bank and Pending
Approvals gear menus.

It would create bank questions directly, skipping the review our CSV and
harness imports wait for, and it sits beside our own Import as a second,
different one.
The Generators and Tags lists already hide it the same way.
"""
from lxml import etree

from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestBankListsHaveNoGenericImport(TransactionCase):

    def test_the_bank_and_pending_approvals_hide_import_records(self):
        for xmlid, model, view_type in (
                ("assessments_be_question_tree", "assessments.be.question",
                 "list"),
                ("assessments_be_question_kanban", "assessments.be.question",
                 "kanban"),
                ("assessments_be_prompt_question_tree",
                 "assessments.be.prompt.question", "list")):
            view = self.env.ref("assessments_be_v2.%s" % xmlid)
            root = etree.fromstring(
                self.env[model].get_view(view.id, view_type)["arch"])
            self.assertEqual(root.get("import"), "0", xmlid)
