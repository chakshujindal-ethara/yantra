# -*- coding: utf-8 -*-
"""ACL-checked media proxies for the admin/back-office client.

WHY THIS EXISTS. The JSON API hands the client URLs for question images and
video clips that live in a PRIVATE S3 bucket - raw S3 URLs 403, so the bytes
have to come through an authenticated proxy. Before the fork those four routes
were served by `etp_assessment_pro/controllers/portal.py` under the
`/assessments_be/admin_*` prefix, which made every image in the question bank a
runtime dependency on a module we are decommissioning.

Ported here, under `/assessments_be/admin_*`, so the prefix cannot collide with
upstream's while both modules are installed. Only the ADMIN routes came across:
the candidate-facing exam portal (`/pro_assessment/*`) was not forked at all -
the Flutter client replaced it.

The IDOR guard on each route is not decoration. A portal account holds a broad
`base.group_portal` read grant on question.image / question.video with NO record
rule, so `check_access("read")` alone would pass for ANY id and leak question
content across assessments. `_be_is_staff()` is the first gate; `check_access`
stays as the second.

THE FIRST GATE ASKS FOR STAFF, NOT MERELY FOR AN INTERNAL ACCOUNT. It used to
call `_is_internal()`, which was the right answer while every candidate was a
portal user and stopped being one when candidates became internal accounts: from
then on it admitted candidates to the admin proxy and left `check_access` as the
only thing between them and another cohort's question bank. `_be_assessment_role`
tells staff and candidate apart - see `models/res_users.py` for the four gates
that each answered this differently.
"""
import logging

from odoo import http
from odoo.http import request

from . import media_stream

_logger = logging.getLogger(__name__)


class AssessmentsBeAdminMedia(http.Controller):

    def _serve_image(self, image, annotated=False):
        return media_stream.serve_image(image, annotated=annotated)

    @staticmethod
    def _annotated_is_worker_safe(question):
        return media_stream.annotated_is_worker_safe(question)

    # cors: the Flutter admin app is served from its own origin and fetches
    # these with an Authorization bearer, which makes the request non-simple -
    # the browser sends a PREFLIGHT first. Without this the route has no
    # OPTIONS handler, so the preflight hit auth="user", answered 401, and the
    # browser discarded the real request before it was ever made. The
    # allow-origin header is then narrowed to the caller's actual origin (and
    # paired with allow-credentials) by assessments_be_v2's _set_cors_headers;
    # it is NOT left as a wildcard on the response. Access itself is unchanged:
    # _is_internal() plus check_access below still decide, and a preflight
    # carries no credentials to leak.

    @http.route("/assessments_be/admin_qimage/<int:image_id>",
                type="http", auth="user", cors="*")
    def serve_admin_question_image(self, image_id, **kw):
        """Internal, ACL-checked proxy so backend admins can preview a
        private-S3 question image (raw S3 URLs 403). Mirrors the candidate
        ``serve_question_image`` serving logic but gates on the internal user's
        model/record read access instead of an exam token."""
        # Only STAFF reach this backend route - not a portal account, and not a
        # candidate either. check_access stays as the second layer.
        #
        # This comment used to assert a broad base.group_portal read grant on
        # question.image. There is no such row in ir.model.access.csv - only
        # question.video carries one (see the sibling route below). The gate is
        # still the right shape and stays: check_access alone would admit any
        # image_id the moment such a row were added, which is exactly what
        # happened to question.video.
        if not request.env.user._be_is_staff():
            return request.not_found()
        image = request.env["assessments.be.question.image"].browse(
            image_id)
        if not image.exists():
            return request.not_found()
        try:
            # ACL gate: raises AccessError unless this user may read the record.
            image.check_access("read")
        except Exception:  # noqa: BLE001 - never leak existence on denial
            return request.not_found()
        return self._serve_image(image.sudo(), bool(kw.get("annotated")))

    def _serve_video(self, video):
        return media_stream.serve_video(video)

    @http.route("/assessments_be/admin_qvideo/<int:video_id>",
                type="http", auth="user", cors="*")
    def serve_admin_question_video(self, video_id, **kw):
        """Internal, ACL-checked proxy so backend admins can preview a
        private-S3 question video. Mirrors serve_admin_question_image: gates on
        the internal user's record read access, then reuses _serve_video."""
        # Same IDOR guard as serve_admin_question_image, and here the exposure
        # is REAL rather than hypothetical: portal candidates hold a
        # base.group_portal read grant on question.video with no record rule
        # (ir.model.access.csv:6), so check_access("read") alone would leak any
        # clip by integer id. Backend users only; check_access is layer two.
        if not request.env.user._be_is_staff():
            return request.not_found()
        video = request.env["assessments.be.question.video"].browse(
            video_id)
        if not video.exists():
            return request.not_found()
        try:
            video.check_access("read")
        except Exception:  # noqa: BLE001 - never leak existence on denial
            return request.not_found()
        return self._serve_video(video.sudo())

    def _serve_draft_video(self, draft, slot):
        """Serve one staged clip from a video_prompt DRAFT's video_files_json.
        Prefer a presigned 302 (private S3) like _serve_video; else stream the
        small base64 dev-fallback. not_found when that slot has no clip."""
        spec = next((f for f in draft._video_files()
                     if (f.get("slot") or "single") == slot), None)
        if not spec:
            return request.not_found()
        url = spec.get("url")
        if url:
            from ..services import s3_service
            key = s3_service.object_key_from_url(request.env, url)
            if key:
                signed = s3_service.presigned_url(
                    request.env, key,
                    expires=media_stream._presign_seconds(request.env))
                if signed:
                    return request.redirect(signed, code=302, local=False)
            return request.redirect(url, code=302, local=False)
        data = spec.get("data")
        if isinstance(data, str) and data.startswith("data:"):
            import base64 as _b64
            try:
                raw = _b64.b64decode(data.split(",", 1)[1])
            except Exception:  # noqa: BLE001 - malformed staged data
                return request.not_found()
            return request.make_response(
                raw, headers=[("Content-Type", "video/mp4"),
                              ("Content-Length", str(len(raw))),
                              ("Accept-Ranges", "none")])
        return request.not_found()

    # cors: see serve_admin_question_image.

    @http.route(
        "/assessments_be/admin_draft_qvideo/<int:draft_id>/<string:slot>",
        type="http", auth="user", cors="*")
    def serve_admin_draft_video(self, draft_id, slot, **kw):
        """Internal, ACL-checked proxy so a backend reviewer can preview a
        video_prompt DRAFT's staged clips before Approve. Mirrors
        serve_admin_question_video: gates on the internal user's read access to
        the draft record, then serves from video_files_json."""
        # THE DOCSTRING ABOVE WAS TRUE OF THE OTHER THREE ROUTES AND FALSE HERE.
        #
        # This route was the only one of the four without the `_is_internal()`
        # gate (the siblings have it), while claiming in its own docstring to
        # mirror one that does - and the module docstring asserts the guard is on
        # every route. `check_access("read")` alone is not that guard: the whole
        # reason it is called the FIRST gate is that a portal read grant with no
        # record rule passes the second one for any id.
        if not request.env.user._be_is_staff():
            return request.not_found()
        draft = request.env[
            "assessments.be.prompt.question"].browse(draft_id)
        if not draft.exists():
            return request.not_found()
        try:
            draft.check_access("read")
        except Exception:  # noqa: BLE001 - never leak existence on denial
            return request.not_found()
        return self._serve_draft_video(draft.sudo(), slot)

    def _serve_draft_image(self, draft, slot, plain=False):
        """Serve one staged image from a DRAFT's images_json. Prefer a presigned
        302 (private S3) like _serve_image; else stream the base64 dev-fallback.
        Draft images offloaded to S3 carry a private-bucket url that 403s if the
        browser loads it directly, so the draft preview must route through here
        (the video twin _serve_draft_video already does this)."""
        specs = draft._image_specs()
        spec = next((s for s in specs
                     if (s.get("slot") or "single") == slot), None)
        if not spec:
            return request.not_found()
        # Prefer the annotated overlay (image_label) unless `plain`: the
        # preview then draws the key's own rectangles on the clean picture, and
        # the baked overlay would be a second numbering. Else the plain image.
        # `plain`: the preview draws the key's own rectangles on the clean
        # picture, so the baked detection overlay would be a second numbering.
        url = (spec.get("url") if plain
               else spec.get("annotated_url") or spec.get("url"))
        if url:
            from ..services import s3_service
            # Same reasoning as media_stream.serve_image: this client fetches
            # with a bearer, so it is an XHR, and an XHR cannot follow a
            # redirect to a bucket that answers no CORS headers. Proxy first,
            # redirect only as the fallback.
            proxied = media_stream._s3_image_response(request.env, url)
            if proxied is not None and not media_stream._prefers_redirect(
                    request.env):
                return proxied
            key = s3_service.object_key_from_url(request.env, url)
            if key:
                signed = s3_service.presigned_url(
                    request.env, key,
                    expires=media_stream._presign_seconds(request.env))
                if signed:
                    return request.redirect(signed, code=302, local=False)
            if proxied is not None:
                return proxied
            return request.redirect(url, code=302, local=False)
        data = (None if plain else spec.get("annotated_data")) \
            or spec.get("data") or spec.get("src")
        if isinstance(data, str) and data.startswith("data:"):
            import base64 as _b64
            try:
                header, payload = data.split(",", 1)
                raw = _b64.b64decode(payload)
            except Exception:  # noqa: BLE001 - malformed staged data
                return request.not_found()
            ctype = "image/png"
            if ":" in header and ";" in header:
                ctype = header[header.index(":") + 1:header.index(";")] \
                    or ctype
            return request.make_response(
                raw, headers=[("Content-Type", ctype),
                              ("Content-Length", str(len(raw))),
                              ("Cache-Control", "private, max-age=3600")])
        return request.not_found()

    # cors: see serve_admin_question_image.

    @http.route(
        "/assessments_be/admin_draft_qimage/<int:draft_id>/<string:slot>",
        type="http", auth="user", cors="*")
    def serve_admin_draft_image(self, draft_id, slot, **kw):
        """Internal, ACL-checked proxy so a backend reviewer can preview a
        DRAFT's staged images before Approve. Mirrors serve_admin_draft_video:
        gates on the internal user's read access to the draft, then presigns the
        private-S3 image (or streams the inline base64 fallback)."""
        if not request.env.user._be_is_staff():
            return request.not_found()
        draft = request.env[
            "assessments.be.prompt.question"].browse(draft_id)
        if not draft.exists():
            return request.not_found()
        try:
            draft.check_access("read")
        except Exception:  # noqa: BLE001 - never leak existence on denial
            return request.not_found()
        return self._serve_draft_image(draft.sudo(), slot,
                                       plain=kw.get("plain") == "1")

