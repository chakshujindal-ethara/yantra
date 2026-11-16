# -*- coding: utf-8 -*-
"""R4: candidates test Safe Exam Browser on their own laptop before the exam.

The setup check is its own .seb, never an exam's: it opens the app's public
`/seb-check` page with the camera allowed, and it quits with no password, so
a candidate who is only testing can always get out. Its settings share the
exam builder, so a check that passes means the exam's settings work too.
"""
import plistlib

from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.services import seb


@tagged("-at_install", "post_install")
class TestTheSetupCheckNeedsNoQuitPassword(TransactionCase):

    def test_the_check_opens_the_check_page_with_the_camera_on(self):
        settings = seb.check_settings("https://exam.example.com/")
        self.assertEqual(settings["startURL"],
                         "https://exam.example.com/seb-check")
        self.assertEqual(settings["quitURL"],
                         "https://exam.example.com/seb-check/quit")
        self.assertIs(settings["browserMediaCaptureCamera"], True)
        self.assertEqual(settings["browserWindowWebView"], 3,
                         "the modern web view, which has the JS API")
        self.assertNotIn("hashedQuitPassword", settings)

    def test_the_check_file_is_the_check_settings(self):
        served = plistlib.loads(
            seb.check_config_file("https://exam.example.com"))
        self.assertEqual(served, seb.check_settings("https://exam.example.com"))
        self.assertNotIn("hashedQuitPassword", served)
