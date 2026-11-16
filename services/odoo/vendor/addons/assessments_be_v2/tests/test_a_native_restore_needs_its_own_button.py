# -*- coding: utf-8 -*-
"""RV3-01: a native bank export reaches the live bank only through the
button that says so and asks first.

`detected_format` is set only by the onchange and is readonly, and the web
client drops a readonly field without `force_save` from every save. So any
save of the wizard ("Download Template", a failed import) reloaded it blank,
the footer flipped a native export to "Import as drafts", and that button
restored the questions into the live bank with no confirm.

`odoo.tests.Form` honours readonly/force_save the way the web client does, so
it is what shows the format surviving a save. The server half: `run_import`
refuses a native file unless the Restore button's context flag is present.
"""
import base64

from odoo.exceptions import UserError
from odoo.tests import Form
from odoo.tests.common import TransactionCase, tagged

from ..services import bank_json_template as json_template


@tagged("-at_install", "post_install")
class TestANativeRestoreNeedsItsOwnButton(TransactionCase):

    def _native_form(self):
        form = Form(self.env["assessments.be.bank.import.wizard"])
        form.data_file = base64.b64encode(
            json_template.native_template_json(self.env)[1]).decode()
        return form

    def test_the_detected_format_survives_a_save(self):
        form = self._native_form()
        self.assertEqual(form.detected_format, "native")
        wizard = form.save()
        self.assertEqual(
            wizard.detected_format, "native",
            "a save dropped the format, so the footer offers Import as drafts")
        self.assertEqual(wizard.question_count, 1)

    def test_a_native_file_needs_the_restore_flag(self):
        wizard = self._native_form().save()
        before = self.env["assessments.be.question"].search_count([])
        with self.assertRaisesRegex(UserError, "Restore into the bank"):
            wizard.run_import()
        self.assertEqual(
            self.env["assessments.be.question"].search_count([]), before,
            "the live bank changed without the confirm")

        result = wizard.with_context(confirm_native_restore=True).run_import()
        self.assertEqual(result["format"], "native")
        self.assertEqual(result["questions_created"], 1)
