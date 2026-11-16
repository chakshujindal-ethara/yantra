"""Routes for Yantra's assess adapter, each proven by a Keycloak token for the service client (see service_auth).

    POST /api/v1/yantra/service/token    -> {access_token, expires_at}: a 15-minute v2 bearer for the service
                                            user, for v2's own admin routes (create, assign, launch, release,
                                            attempts)
    POST /api/v1/yantra/service/people   {sub, email, email_verified, name, kind: worker|staff}
                                         -> {user_id, applicant_id}
    POST /api/v1/yantra/service/tickets  {sub, kind: candidate|staff, assessment_id | exam_token, next, return_url}
                                         -> {ticket, launch_url, expires_at, evaluator_id, attempt_state}

Envelope and error shape are Assessment v2's own (`ok` / `fail`), so the adapter reads one dialect.
"""

import secrets
from datetime import timedelta
from urllib.parse import quote, urlparse

from odoo import fields, http
from odoo.http import request

from odoo.addons.assessments_be_v2.controllers.api.common import (
    API_TYPE,
    api_endpoint,
    arg,
    bool_arg,
    fail,
    int_arg,
    ok,
    str_arg,
)

from ..models.res_users import IdentityConflict
from ..services import service_auth

SERVICE_TOKEN_TTL = timedelta(minutes=15)


def _service():
    """The verified service caller, or the failure to return."""
    try:
        service_auth.verify(request.env, service_auth.bearer(request.httprequest.headers))
    except service_auth.ServiceRefused as exc:
        return fail("unauthorized", str(exc), status=401)
    return None


def _origin(url):
    p = urlparse(url or "")
    return f"{p.scheme}://{p.netloc}" if p.scheme and p.netloc else ""


class YantraAssessService(http.Controller):
    @http.route("/api/v1/yantra/service/token", type=API_TYPE, auth="public", methods=["POST"], csrf=False)
    @api_endpoint
    def service_token(self, **kw):
        refused = _service()
        if refused:
            return refused
        user = request.env.ref("yantra_assess_bridge.user_assess_service").sudo()
        expiry = fields.Datetime.now() + SERVICE_TOKEN_TTL
        token = secrets.token_urlsafe(32)
        request.env["api.access_token"].sudo().create({"user_id": user.id, "access_token": token, "expiry": expiry})
        return ok({"access_token": token, "expires_at": fields.Datetime.to_string(expiry), "user_id": user.id})

    @http.route("/api/v1/yantra/service/people", type=API_TYPE, auth="public", methods=["POST"], csrf=False)
    @api_endpoint
    def service_people(self, **kw):
        refused = _service()
        if refused:
            return refused
        kind = str_arg("kind") or "worker"
        if kind not in ("worker", "staff"):
            return fail("invalid", "kind must be worker or staff", status=422)
        try:
            user, applicant = request.env["res.users"].sudo()._yantra_ensure_person(
                str_arg("sub"),
                email=str_arg("email", max_len=254),
                verified=bool_arg("email_verified"),
                name=str_arg("name", max_len=120),
                kind=kind,
            )
        except IdentityConflict as exc:
            status = 422 if exc.code == "invalid_subject" else 409
            return fail(exc.code, str(exc.args[0]), status=status)
        return ok({"user_id": user.id, "applicant_id": applicant.id, "login": user.login})

    @http.route("/api/v1/yantra/service/tickets", type=API_TYPE, auth="public", methods=["POST"], csrf=False)
    @api_endpoint
    def service_tickets(self, **kw):
        refused = _service()
        if refused:
            return refused
        env = request.env
        params = env["ir.config_parameter"].sudo()
        user = env["res.users"].sudo().with_context(active_test=False).search(
            [("yantra_keycloak_sub", "=", str_arg("sub"))], limit=1
        )
        if not user:
            return fail("unknown_person", "Provision the person first (/api/v1/yantra/service/people)", status=404)
        kind = str_arg("kind") or "candidate"
        if kind not in ("candidate", "staff"):
            return fail("invalid", "kind must be candidate or staff", status=422)
        return_url = str_arg("return_url", max_len=500)
        allowed = {o.strip().rstrip("/") for o in (params.get_param("yantra_assess_bridge.return_origins") or "").split(",") if o.strip()}
        if return_url and _origin(return_url) not in allowed:
            return fail("invalid", "return_url is not a Yantra origin", status=422)
        next_path = str_arg("next", max_len=300)
        if next_path and (not next_path.startswith("/") or next_path.startswith("//") or "://" in next_path):
            return fail("invalid", "next must be a path inside the assessment app", status=422)
        evaluator = env["assessments.be.evaluator"]
        if kind == "candidate":
            evaluator, refused = self._evaluator_for(user)
            if refused is not None:
                return refused
        elif not user.has_group("assessments_be_v2.group_assessment_manager"):
            return fail("forbidden", "This person is not assessment staff", status=403)
        raw, ticket = env["yantra.assess.ticket"].sudo()._mint(
            user, kind, evaluator=evaluator or None, next_path=next_path, return_url=return_url
        )
        app_url = (params.get_param("yantra_assess_bridge.app_url") or "").rstrip("/")
        return ok({
            "ticket": raw,
            "launch_url": f"{app_url}/yantra/launch#ticket={quote(raw, safe='')}",
            "expires_at": fields.Datetime.to_string(ticket.expires_at),
            "evaluator_id": evaluator.id or None,
            "attempt_state": evaluator.state or None,
        })

    @staticmethod
    def _evaluator_for(user):
        """`(attempt, None)` for the person's attempt on the named assessment (or exam token), else
        `(None, failure response)`."""
        Evaluator = request.env["assessments.be.evaluator"].sudo()
        exam_token = str_arg("exam_token", max_len=64)
        if exam_token:
            evaluator = Evaluator.search([("access_token", "=", exam_token)], limit=1)
        else:
            assessment_id = int_arg("assessment_id") or int(arg("assessment_id") or 0)
            evaluator = Evaluator.search(
                [("assessment_id", "=", assessment_id), ("applicant_id.be_candidate_user_id", "=", user.id)], limit=1
            )
        if not evaluator:
            return None, fail("not_assigned", "This person has no attempt on that assessment", status=404)
        if evaluator.applicant_id.be_candidate_user_id != user:
            return None, fail("forbidden", "That attempt belongs to someone else", status=403)
        return evaluator, None
