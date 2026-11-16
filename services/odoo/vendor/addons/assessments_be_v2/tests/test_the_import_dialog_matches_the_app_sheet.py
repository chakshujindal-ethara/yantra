# -*- coding: utf-8 -*-
"""pm-ux-admin-23: the bank import dialog is one action, not five buttons.

Same shape as the console's import sheet: what this does, what can go wrong
(a single bad row refuses the whole import, stated before the file picker),
the file, ONE Download Template with the flavour beside it, the limits. The
footer holds only Cancel and the import, so templates read as reference files
rather than as other ways to IMPORT, and no column syntax buries the warning.
The flavour selector reaches both JSON templates; `action_download_template` /
`action_download_json_template` are unchanged underneath.
"""
from lxml import etree

from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.models import bank_import_wizard as W


@tagged("-at_install", "post_install")
class TestTheImportDialogMatchesTheAppSheet(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Wizard = self.env["assessments.be.bank.import.wizard"]

    def _arch(self):
        view = self.env.ref(
            "assessments_be_v2.assessments_be_bank_import_wizard_form")
        return etree.fromstring(self.Wizard.get_view(view.id, "form")["arch"])

    def test_the_footer_holds_only_cancel_and_the_import(self):
        # Two buttons on screen: Cancel and ONE primary. The two primaries are
        # mutually exclusive on the detected format - "Import as drafts" for
        # CSV and harness JSON, "Restore into the bank" for a native export,
        # which does not land in Pending Approvals and must not say it does.
        footer = self._arch().xpath("//footer")[0]
        buttons = footer.xpath(".//button")
        self.assertEqual(
            [b.get("string") for b in buttons],
            ["Cancel", "Import as drafts", "Restore into the bank"],
            etree.tostring(footer))
        primaries = [b for b in buttons if b.get("class") == "btn-primary"]
        self.assertEqual(
            sorted(b.get("invisible") for b in primaries),
            ["detected_format != 'native'", "detected_format == 'native'"],
            "exactly one primary may be visible at a time")
        self.assertTrue(
            [b for b in primaries
             if b.get("string") == "Restore into the bank"][0].get("confirm"),
            "restoring into the live bank is the outcome to ask about")

    def test_there_is_one_download_control(self):
        arch = self._arch()
        downloads = arch.xpath("//button[starts-with(@name, "
                               "'action_download')]")
        self.assertEqual(len(downloads), 1)
        self.assertEqual(downloads[0].get("string"), "Download Template")
        self.assertTrue(arch.xpath("//field[@name='template_format']"),
                        "no capability may be lost: the flavour is a choice "
                        "beside the one button")

    def test_the_warning_comes_before_the_file_picker(self):
        arch = self._arch()
        body = etree.tostring(arch, encoding="unicode")
        self.assertIn("One bad row stops the whole import.", body)
        self.assertIn("accepted or refused as a whole", body)
        self.assertLess(
            body.index("One bad row stops the whole import."),
            body.index('name="data_file"'),
            "it is what decides how the file is prepared, so it belongs "
            "above the picker")

    def test_the_sub_line_is_the_apps_sentence(self):
        self.assertIn(
            "CSV or harness JSON arrive as drafts for review; a native JSON "
            "bank export restores questions straight into the bank.",
            " ".join(etree.tostring(self._arch(), encoding="unicode").split()))

    def test_the_limits_are_stated_and_are_the_servers(self):
        wizard = self.Wizard.create({})
        self.assertEqual(
            wizard.size_limits,
            "Max %d MB  ·  up to %s rows" % (
                W.EtpAssessmentBankImportWizard._MAX_CSV_BYTES // (1024 ** 2),
                "{:,}".format(
                    W.EtpAssessmentBankImportWizard._MAX_CSV_ROWS)))
        self.assertIn("size_limits",
                      etree.tostring(self._arch(), encoding="unicode"))

    def test_the_csv_columns_are_listed_beside_the_download(self):
        wizard = self.Wizard.create({"template_format": "csv"})
        for column in ("title", "question_type", "correct_answer"):
            self.assertIn(column, wizard.template_columns)
        wizard.template_format = "native"
        self.assertFalse(wizard.template_columns,
                         "the CSV column list does not describe a JSON bank "
                         "export")

    def test_the_column_prose_is_gone_from_the_dialog(self):
        body = etree.tostring(self._arch(), encoding="unicode")
        self.assertNotIn("dim1_label", body)
        self.assertNotIn("img1_url", body)

    def test_each_flavour_still_downloads(self):
        for flavour, expect in (("csv", "text/csv"),
                                ("harness", "application/json"),
                                ("native", "application/json")):
            wizard = self.Wizard.create({"template_format": flavour})
            action = wizard.action_download_selected_template()
            self.assertEqual(action["type"], "ir.actions.act_url")
            att_id = int(action["url"].split("/web/content/")[1].split("?")[0])
            self.assertEqual(
                self.env["ir.attachment"].browse(att_id).mimetype, expect,
                "flavour %s" % flavour)
