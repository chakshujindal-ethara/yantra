# -*- coding: utf-8 -*-
"""A Form Studio Publish with warnings opens its draft instead of crashing.

The warning notice hands the draft assessment on through `next`. The web
client runs `next` as it is - the server-side clean-up that fills an
act_window's `views` from `view_mode` never touches a notification's
params - so `next` must carry `views`, or the client dies on
`action.views.map` after the draft is saved and a second press makes a
duplicate.
"""
from unittest.mock import patch

from odoo.tests.common import tagged

from odoo.addons.assessments_be_v2.tests.test_authored_question_marks import (
    _FormBase,
)


@tagged("-at_install", "post_install")
class TestAWarnedSendOpensItsDraft(_FormBase):

    def _warned_send(self):
        form = self._form(self._item(
            "imageBlock", title="What is wrong with this weld",
            media_url="https://example.test/weld.png", multi_select=False,
            options=self._opts(("Porosity", True), ("Clean", False))))
        with patch.object(type(self.Form), "_fetch_media_b64",
                          lambda self, url: (False, "image not downloaded")):
            return form.action_publish()

    def test_the_draft_after_the_notice_names_its_form_view(self):
        action = self._warned_send()
        self.assertEqual(action["tag"], "display_notification")
        draft = action["params"]["next"]
        self.assertEqual(draft["type"], "ir.actions.act_window")
        self.assertEqual([list(v) for v in draft.get("views") or []],
                         [[False, "form"]],
                         "the client opens `next` as-is and needs `views`")
        self.assertTrue(self.env["assessments.be"].browse(
            draft["res_id"]).exists())

    def test_a_clean_send_opens_the_same_form_view(self):
        action = self._form(self._item(
            "multipleChoice", title="Pick one",
            options=self._opts(("Yes", True), ("No", False)))).action_publish()
        self.assertEqual([list(v) for v in action["views"]],
                         [[False, "form"]])
