"""Routes that ``@validate_token`` authenticates but does NOT authorize.

``validate_token`` normally does two jobs: it proves the caller owns a valid
access token, and it then checks that the caller's ``api.role`` has been
granted this endpoint in ``api_role_endpoint``. Listing a route here keeps the
first job and drops the second.

Everything below still applies to an exempt route:

  * the ``access_token`` header must be present,
  * the token must exist, be unexpired, and belong to a non-public user,
  * that user must have a role assigned,
  * ``request.env`` is switched to that user, so ORM record rules and any
    in-controller permission logic behave exactly as before.

The only thing skipped is the role -> endpoint grant lookup. Use this for
endpoints every signed-in user legitimately needs regardless of role, where
maintaining a grant row per role is pure overhead.

Write each pattern exactly as its ``@http.route`` declares it, converters and
all. Matching is converter-aware: '/api/v1/contracts/templates/<int:template_id>'
covers '/api/v1/contracts/templates/43' but deliberately NOT
'/api/v1/contracts/templates/refresh', which is a different route.

This list lives in code rather than in ``ir.config_parameter`` on purpose:
widening it should require a commit and show up in review and in git history,
not a database edit.
"""

ACCESS_CHECK_EXEMPT_ENDPOINTS = (
    # Assessment templates - authored by the test POC, who may hold any role.
    '/api/v1/assessment-template/list',
    '/api/v1/assessment-template/create',
    '/api/v1/assessment-template/detail',
    '/api/v1/assessment-template/update',

    # Contract templates - authored by the contract POC, likewise any role.
    '/api/v1/contracts/templates',
    '/api/v1/contracts/templates/<int:template_id>',
    '/api/v1/contracts/templates/<int:template_id>/pdf',

    # ESSL attendance list - every signed-in employee may read their OWN rows
    # regardless of role; HR/CTO may read others. The self-vs-others boundary
    # is enforced inside the handler (essl/controllers/main.py), not by a role
    # -> endpoint grant, so the route authenticates here but does not authorize.
    '/essl/api/attendance/list',

    # Employee ID card details - every signed-in employee reads/updates their
    # OWN card (HR may target another via ?employee_id). The self-vs-others
    # boundary is handled in employee_profile_controller, so authenticate here
    # but skip the role -> endpoint grant.
    '/api/v1/employees/id_card',
    '/api/v1/employees/id_card/update',
    # Employee ID card fulfilment queue (staff/TA console) - guarded by an
    # employee-record check inside employee_profile_controller.
    '/api/v1/employees/id_card/list',
    '/api/v1/employees/id_card/queue_detail',
    '/api/v1/employees/id_card/mark_done',

    # Candidate ID card (hr.applicant). The `me` routes are scoped to the
    # caller's own application; the staff queue routes are guarded by an
    # employee-record check inside id_card_controller. Authenticate here, skip
    # the role -> endpoint grant.
    '/api/v1/candidates/me/id_card',
    '/api/v1/candidates/me/id_card/update',
    '/api/v1/candidates/id_card/list',
    '/api/v1/candidates/id_card/detail',
    '/api/v1/candidates/id_card/update',
    '/api/v1/candidates/id_card/mark_done',

    # "Report an issue" from the finance portal (fms_feedback). Every signed-in
    # user must be able to file a bug report regardless of role. The handler
    # derives the reporter from the access token and drops every identity field
    # in the payload, so a per-role grant would gate nothing - it would only be a
    # list somebody has to remember to extend. Authenticate here, skip the
    # role -> endpoint grant.
    '/api/v1/fms/feedback/report',
)
