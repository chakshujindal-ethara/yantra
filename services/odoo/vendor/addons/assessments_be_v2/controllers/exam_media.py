# -*- coding: utf-8 -*-
"""Token-scoped media for the candidate sitting an exam.

WHY THIS EXISTS. `question_for_candidate` used to hand the client
`/pro_assessment/qimage|qvideo/<token>/<id>` - a route only `etp_assessment_pro`
serves. It worked solely because that module was installed alongside; the moment
it is decommissioned every image and video in every exam answers 404, leaving a
broken plate above numbered inputs the candidate has to answer. These are those
two routes, owned here.

auth="public" is REQUIRED, not lax. The browser issues `<img>` and `<video>`
requests itself with no Authorization header, and the Flutter client signs in
with a bearer and holds no Odoo cookie, so `request.env.user` is PUBLIC on every
media request. The exam token in the path is the credential, and it grants no
more than it already does: whoever holds it can open the exam and sit the paper.
Access is still narrowed to media whose question is in THIS evaluator's own
`question_order`.
"""
import logging

from odoo import http
from odoo.http import request

_logger = logging.getLogger(__name__)

from ..constants import ROLE_CANDIDATE, ROLE_STAFF
from . import media_stream


class AssessmentsBeExamMedia(http.Controller):

    def _evaluator(self, token):
        if not token:
            return False
        # A draft paper's token is unknown here, as in `evaluator_from_token`.
        return request.env["assessments.be.evaluator"].sudo().search(
            [("access_token", "=", token),
             ("assessment_id.state", "!=", "draft")], limit=1)

    def _refused(self, evaluator):
        """Why this caller must not see this attempt's media, or "" to admit.

        A REASON, NOT A BOOLEAN, because the two refusing branches are entirely
        different faults and the caller can only log what it is handed. Both
        used to be reported as "attempt is not live for this candidate" - a
        condition NOTHING here tests, since this method reads identity only and
        never a state or a deadline - so the one security-relevant case, a
        signed-in candidate fetching somebody else's paper, was indistinguishable
        in the log from a portal account wandering onto the route, and support
        chasing the reason it was given found a perfectly live attempt.

        Still only ever truthy or falsy at the call sites, so a caller that just
        asks "was this refused" reads the same as it always did.

        Four outcomes, in the order they have to be asked:

        A PUBLIC CALLER IS ADMITTED ON THE TOKEN, and this is load-bearing. An
        `<img>` or `<video>` tag is issued by the browser itself with no
        Authorization header, and the app signs in with a bearer token and holds
        no Odoo cookie - so `request.env.user` is PUBLIC on every media request a
        real candidate's page makes. Refusing here made a candidate sit an exam
        whose clips were black frames stuck at 0:00. The token grants no more
        than it already does: whoever holds it can open the exam and sit the
        paper, and `_in_paper` still confines the caller to questions on THIS
        attempt's own frozen `question_order`.

        STAFF ARE ADMITTED. `ir_http._auth_method_public` adopts a bearer on this
        prefix, so an admin previewing a candidate's paper arrives as themselves
        - not as the candidate, not as public. Refusing them made the same URL
        work in an `<img>` tag and 404 from any fetch that carried a credential,
        while `admin_media.py` served the identical bytes to the identical people
        through its own routes.

        A CANDIDATE MUST BE THIS CANDIDATE. This is the check that was DEAD. The
        old code admitted every internal user outright and only then compared
        identities - and candidate accounts are internal, so the comparison was
        unreachable for every caller it was written for. Candidate A signed in,
        holding candidate B's token, was admitted to B's exam media; the
        docstring claimed "a caller who IS signed in as somebody else is still
        refused" and it could not be. Telling staff from candidate is exactly
        what `_be_assessment_role` exists for.

        A PORTAL ACCOUNT IS REFUSED OUTRIGHT. This platform is internal-only, so
        a portal caller has no role here at all - not even a token-bearing one.
        It reaches this branch as `none`.

        A plain 404, never a 403: upstream rendered a QWeb "wrong candidate"
        page, this addon is headless, and a 404 leaks nothing about whose attempt
        the id belongs to.
        """
        user = request.env.user
        if user._is_public():
            return ""
        role = user._be_assessment_role()
        if role == ROLE_STAFF:
            return ""
        if role == ROLE_CANDIDATE:
            candidate = evaluator._candidate_user()
            if candidate and user.id != candidate.id:
                return "caller is signed in as a different candidate"
            return ""
        # ROLE_NONE: portal, or an internal account with no assessment access.
        return ("caller has no assessment role "
                "(portal, or internal with no access)")

    @staticmethod
    def _in_paper(evaluator, question_id):
        """The question must be on THIS candidate's frozen paper.

        `question_order` is the instrument as drawn for this attempt, so an id
        outside it is either another candidate's question or a bank item never
        served - both are 404, not 403, so the route reveals nothing.
        """
        import json
        try:
            order = set(json.loads(evaluator.question_order or "[]"))
        except (TypeError, ValueError):
            order = set()
        return question_id in order

    @staticmethod
    def _missing(reason, kind, media_id, evaluator=None):
        """A 404 that says WHY in the log while still saying nothing on the wire.

        Five different faults answered with the same bare `not_found()` and no
        log line anywhere: an unknown token, a caller who is not this
        candidate, a caller with no assessment access at all, a media row
        that was deleted, and a question not drawn for this candidate. A
        candidate sees a broken image in a live exam and support has nothing
        to work from - during the 753-candidate run these were invisible.

        THE RESPONSE IS UNCHANGED. It stays a 404 and never a 403, because
        distinguishing "does not exist" from "not yours" on the wire tells an
        attacker which media ids are real. The diagnosis goes to the log, which
        is the one place it can be read without leaking it to the caller.

        NO TOKEN IS EVER LOGGED. It is a live exam credential - anyone holding
        it can fetch that candidate's paper - and putting credentials in the
        log aggregator is the defect G14 already tracks. The evaluator id is
        enough to find the row, and it is not a secret.
        """
        _logger.warning(
            "exam media 404: %s (kind=%s id=%s evaluator=%s)",
            reason, kind, media_id,
            evaluator.id if evaluator else "unresolved")
        return request.not_found()

    @http.route("/assessments_be/exam/qimage/<string:token>/<int:image_id>",
                type="http", auth="public")
    def serve_exam_image(self, token, image_id, **kw):
        evaluator = self._evaluator(token)
        if not evaluator:
            return self._missing("token does not resolve to an attempt",
                                 "image", image_id)
        refusal = self._refused(evaluator)
        if refusal:
            return self._missing(refusal, "image", image_id, evaluator)
        image = request.env["assessments.be.question.image"].sudo().browse(
            image_id)
        if not image.exists():
            return self._missing("image row does not exist",
                                 "image", image_id, evaluator)
        if not self._in_paper(evaluator, image.question_id.id):
            return self._missing(
                "question %s is not in this candidate's paper"
                % image.question_id.id, "image", image_id, evaluator)
        annotated = bool(kw.get("annotated")) and \
            media_stream.annotated_is_worker_safe(image.question_id)
        return media_stream.serve_image(image, annotated=annotated)

    @http.route("/assessments_be/exam/qvideo/<string:token>/<int:video_id>",
                type="http", auth="public")
    def serve_exam_video(self, token, video_id, **kw):
        evaluator = self._evaluator(token)
        if not evaluator:
            return self._missing("token does not resolve to an attempt",
                                 "video", video_id)
        refusal = self._refused(evaluator)
        if refusal:
            return self._missing(refusal, "video", video_id, evaluator)
        video = request.env["assessments.be.question.video"].sudo().browse(
            video_id)
        if not video.exists():
            return self._missing("video row does not exist",
                                 "video", video_id, evaluator)
        if not self._in_paper(evaluator, video.question_id.id):
            return self._missing(
                "question %s is not in this candidate's paper"
                % video.question_id.id, "video", video_id, evaluator)
        return media_stream.serve_video(video)
