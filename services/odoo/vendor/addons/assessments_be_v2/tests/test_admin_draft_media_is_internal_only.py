# -*- coding: utf-8 -*-
"""Every admin media route refuses a non-internal caller, including draft video.

THE DEFECT. `serve_admin_draft_video` was the only one of the four routes in
`controllers/admin_media.py` without the `_is_internal()` gate - while its own
docstring claimed to mirror `serve_admin_question_video`, which has it, and the
module docstring asserts the guard is on every route. `serve_admin_draft_image`
then documented itself as mirroring the one route that was broken.

WHY IT STILL MATTERED, given today's ACL refuses anyway. `check_access("read")`
is the SECOND gate, and `assessments.be.prompt.question` currently has no portal
grant - so a portal caller was refused by luck of the ACL table rather than by
the guard the file says is there. `assessments.be.question.video` already
carries exactly such a portal read grant (`ir.model.access.csv:6`), so a row
added for the draft model later would have opened this route silently. These
tests therefore GRANT the portal user model read access first, which is what
makes them a real negative control: with the grant in place, `_is_internal()` is
the only thing left that can refuse, so deleting it turns the first test red.

`_serve_draft_video` is patched rather than exercised. The question is whether a
caller gets PAST the gates, not what S3 hands back, and asserting on "was the
serve method reached" cannot be satisfied by a route that merely happens to 404
for some other reason.
"""
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase

from ..controllers import admin_media

_NOT_FOUND = object()


class _FakeRequest:
    """The three attributes the admin media routes touch."""

    def __init__(self, env):
        self.env = env

    def not_found(self):
        return _NOT_FOUND


class TestAdminDraftMediaIsInternalOnly(TransactionCase):

    def setUp(self):
        super().setUp()
        prompt = self.env["assessments.be.prompt"].create(
            {"name": "Gen %s" % uuid4().hex[:6]})
        self.draft = self.env["assessments.be.prompt.question"].create({
            "prompt_id": prompt.id,
            "name": "Draft %s" % uuid4().hex[:6],
            "video_files_json": '[{"slot": "single", "url": "s3://x/clip.mp4"}]',
        })
        self.controller = admin_media.AssessmentsBeAdminMedia()
        self.portal_group = self.env.ref("base.group_portal")
        self.portal = self.env["res.users"].create({
            "name": "Portal caller",
            "login": "portal_%s@example.com" % uuid4().hex[:8],
            # `group_ids` in Odoo 19; `groups_id` was renamed.
            "group_ids": [(6, 0, [self.portal_group.id])],
        })

    def _question(self, question_type):
        return self.env["assessments.be.question"].create({
            "name": "Q %s" % uuid4().hex[:6],
            "question_type": question_type,
            "prompt": "Prompt text",
        })

    def _grant_portal_read(self, model_name):
        """Give the portal group model-level read, so the ACL stops being the
        thing that refuses and the route's own gate is under test.

        No manual cache clearing: `ir.model.access.create` calls
        `call_cache_clearing_methods()` itself, which clears the `stable` cache
        the access lookup is keyed on.
        """
        self.env["ir.model.access"].create({
            "name": "test portal read %s" % model_name,
            "model_id": self.env["ir.model"]._get(model_name).id,
            "group_id": self.portal_group.id,
            "perm_read": True,
        })

    def _call_as(self, user, route_name, *args):
        """Run a route as `user`, with the serve helpers stubbed out.

        Returns (result, video_served, image_served).

        CALLS `original_endpoint`, NOT THE DECORATED ATTRIBUTE. `@http.route`
        wraps every `type="http"` endpoint in `route_wrapper`, which finishes with
        `Response.load(result)` - so calling the bound method put both stubs
        through werkzeug: the `_NOT_FOUND` sentinel raised
        `TypeError: returns an invalid value`, and the "VIDEO" string came back as
        a `_Response` that no `assertEqual` against a string can match. The gate
        under test is a line in the endpoint BODY, so the body is what to call;
        `route_wrapper.original_endpoint` is the handle Odoo keeps for exactly
        this. Unbound, hence the explicit controller argument.
        """
        endpoint = getattr(
            admin_media.AssessmentsBeAdminMedia, route_name).original_endpoint
        with patch.object(admin_media, "request",
                          _FakeRequest(self.env(user=user))), \
             patch.object(admin_media.AssessmentsBeAdminMedia,
                          "_serve_draft_video",
                          return_value="VIDEO") as vid, \
             patch.object(admin_media.AssessmentsBeAdminMedia,
                          "_serve_draft_image",
                          return_value="IMAGE") as img, \
             patch.object(admin_media.AssessmentsBeAdminMedia,
                          "_serve_image", return_value="IMG") as plain_img, \
             patch.object(admin_media.AssessmentsBeAdminMedia,
                          "_serve_video", return_value="VID") as plain_vid:
            result = endpoint(self.controller, *args)
        return result, (vid.called or plain_vid.called), \
            (img.called or plain_img.called)

    # ── the fix ──────────────────────────────────────────────────────────

    def test_a_portal_caller_is_refused_the_draft_video(self):
        """THE regression. With model read granted, only the gate can refuse."""
        self._grant_portal_read("assessments.be.prompt.question")
        self.assertFalse(self.portal._is_internal(), "fixture check")
        # Fixture check with teeth: prove the SECOND gate now passes, so a
        # refusal below can only have come from `_is_internal()`.
        self.draft.with_user(self.portal).check_access("read")

        result, video_served, _ = self._call_as(
            self.portal, "serve_admin_draft_video", self.draft.id, "single")

        self.assertIs(result, _NOT_FOUND,
                      "a non-internal caller must not reach a staged clip")
        self.assertFalse(
            video_served,
            "the route returned before serving, but still called the serve "
            "helper - the gate has to short-circuit, not just discard")

    def test_an_internal_caller_still_reaches_the_draft_video(self):
        """The guard must not close the route to the people it is for."""
        admin = self.env.ref("base.user_admin")
        self.assertTrue(admin._is_internal(), "fixture check")

        result, video_served, _ = self._call_as(
            admin, "serve_admin_draft_video", self.draft.id, "single")

        self.assertEqual(result, "VIDEO")
        self.assertTrue(video_served)

    # ── the property that was never asserted anywhere ────────────────────

    def test_every_admin_media_route_refuses_a_portal_caller(self):
        """Uniformity, checked by CALLING all four rather than reading source.

        This is the test that would have caught the original defect: three
        routes had the gate, one did not, and nothing compared them. A source
        grep for the decorator would not have helped - there is no decorator,
        the gate is a line in each body.
        """
        for model in ("assessments.be.prompt.question",
                      "assessments.be.question.image",
                      "assessments.be.question.video",
                      "assessments.be.question"):
            self._grant_portal_read(model)

        image = self.env["assessments.be.question.image"].create({
            "question_id": self._question("image_label").id,
            "label": "Plate",
            "slot": "single",
        })
        video = self.env["assessments.be.question.video"].create({
            "question_id": self._question("video_prompt").id,
            "slot": "single",
        })

        cases = (
            ("admin_qimage", "serve_admin_question_image", (image.id,)),
            ("admin_qvideo", "serve_admin_question_video", (video.id,)),
            ("admin_draft_qvideo",
             "serve_admin_draft_video", (self.draft.id, "single")),
            ("admin_draft_qimage",
             "serve_admin_draft_image", (self.draft.id, "single")),
        )
        for label, route_name, args in cases:
            with self.subTest(route=label):
                result, video_served, image_served = self._call_as(
                    self.portal, route_name, *args)
                self.assertIs(
                    result, _NOT_FOUND,
                    "%s admitted a portal caller" % label)
                self.assertFalse(
                    video_served or image_served,
                    "%s reached its serve helper for a portal caller" % label)
