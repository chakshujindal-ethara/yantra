"""Who a candidate is, resolved the same way in both directions.

WHY THIS FILE EXISTS. Identity was resolved by two hand-copied walks that
disagreed. `resolve_applicant` (the candidate's own list) went user ->
applicant and deliberately allowed internal users, because an employee sitting
an assessment is an ordinary case here. `evaluator._candidate_user` (the exam
gate) went applicant -> user and deliberately REFUSED them. The result on
stage: an employee saw the assessment on "My assessments", pressed Start, and
was told "This link belongs to somebody else" - with the server naming their
own address as both the invited candidate and the current user.

The second half of the same bug is quieter and worse. The gate's partner step
matched any user sharing the applicant's `partner_id` without checking it was
the same person, and on stage the "Admin" partner carried a candidate's email
address. That resolves one person's exam to another account: Admin passed the
"are you the assigned candidate" test for somebody else's attempt.

Both directions now go through `hr.applicant._be_candidate_user` /
`_be_applicant_for_user`. These tests pin the two properties that made the
bug: an employee-candidate resolves, and a shared partner never hands an
attempt to the wrong person.

TransactionCase rather than HttpCase, matching test_candidate_password: the
assertions are about the resolution the routes delegate to, not transport.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestCandidateIdentity(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Applicant = self.env["hr.applicant"]
        self.Users = self.env["res.users"]
        self.Assessment = self.env["assessments.be"]
        self.Evaluator = self.env["assessments.be.evaluator"]

    # ------------------------------------------------------------------
    # Fixtures
    # ------------------------------------------------------------------
    def _email(self, slug="candidate"):
        return "%s_%s@example.com" % (slug, uuid4().hex[:8])

    def _user(self, login, group):
        return self.Users.with_context(no_reset_password=True).create({
            "name": "User %s" % login,
            "login": login,
            "email": login,
            "group_ids": [(6, 0, [self.env.ref(group).id])],
        })

    def _employee(self, login):
        """An INTERNAL user - the shape that used to be refused at the gate."""
        return self._user(login, "base.group_user")

    def _applicant(self, email, name="Asha Rao", partner=None):
        """An applicant for `email`, optionally forced onto a given partner.

        `email_from` has an inverse that finds-or-creates a partner, so the
        partner has to be forced AFTER create and the email re-asserted: the
        `partner_id` depends recompute `email_from` from the partner it was
        just pointed at.
        """
        applicant = self.Applicant.create({
            "partner_name": name,
            "email_from": email,
        })
        if partner is not None:
            # Writing `partner_id` recomputes `email_from` FROM that partner
            # (`_compute_partner_phone_email`), so the address has to be put
            # back afterwards - and putting it back fires
            # `_inverse_partner_email`, which renames the partner and
            # overwrites its email. That is not fixture noise: it is exactly
            # how a shared contact ends up carrying somebody else's address in
            # production, which is the shape under test.
            applicant.partner_id = partner.id
            applicant.email_from = email
            self.assertEqual(
                applicant.email_from, email,
                "fixture: the applicant must still carry the candidate's "
                "address after being forced onto a shared partner")
        return applicant

    def _attempt(self, applicant):
        """A bare attempt row. No launch: the gate resolves identity from the
        applicant, so nothing here needs a question draw."""
        assessment = self.Assessment.create({
            "name": "Gate %s" % uuid4().hex[:6],
            "duration_minutes": 30,
        })
        return self.Evaluator.create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
        })

    # ------------------------------------------------------------------
    # An employee-candidate is a candidate
    # ------------------------------------------------------------------
    def test_an_employee_is_bound_like_any_other_candidate(self):
        """Provisioning binds a staff account instead of walking away.

        It must not CREATE anything - the account exists - but leaving
        `be_candidate_user_id` empty is what dropped the gate onto fallbacks
        that refused the person the invitation named. The record rules key on
        this field too, so an unbound candidate has no row access either.
        """
        staff = self._employee(self._email("staff"))
        applicant = self._applicant(staff.login, name="Staff Person")

        result = self.Assessment._ensure_candidate_user(applicant)

        self.assertEqual(result, "linked")
        self.assertEqual(
            applicant.be_candidate_user_id, staff,
            "an employee sitting an assessment must be bound to their "
            "applicant, not skipped")

    def test_an_employee_candidate_passes_the_exam_gate(self):
        """The failure the candidate actually saw.

        Unbound, with no usable partner link: this is the row shape that
        answered `wrong_candidate` to its own candidate.
        """
        staff = self._employee(self._email("staff"))
        applicant = self._applicant(staff.login, name="Staff Person")
        applicant.partner_id = False
        attempt = self._attempt(applicant)

        self.assertEqual(
            attempt._candidate_user(), staff,
            "the gate must resolve an employee-candidate to their own user")

    # ------------------------------------------------------------------
    # A shared partner must not hand over an attempt
    # ------------------------------------------------------------------
    def test_a_shared_partner_does_not_resolve_to_the_wrong_person(self):
        """The stage shape: an admin partner carrying a candidate's email.

        The applicant points at the admin's partner, so the partner step finds
        the ADMIN's user. Matching a partner is not evidence of being the same
        person - the login is.
        """
        admin = self._employee(self._email("admin"))
        candidate = self._employee(self._email("candidate"))
        applicant = self._applicant(
            candidate.login, name="Candidate", partner=admin.partner_id)
        attempt = self._attempt(applicant)

        self.assertEqual(
            applicant.partner_id, admin.partner_id,
            "fixture: the applicant must be on the admin's partner")
        self.assertEqual(
            attempt._candidate_user(), candidate,
            "a partner shared with another account must never resolve that "
            "account as the assigned candidate")

    def test_a_shared_partner_does_not_list_somebody_elses_assessments(self):
        """The same hole walked the other way.

        Signed in as the admin, the reverse resolver used to return the
        applicant that merely pointed at the admin's partner - putting another
        candidate's assessments on the admin's own list.
        """
        admin = self._employee(self._email("admin"))
        candidate = self._employee(self._email("candidate"))
        applicant = self._applicant(
            candidate.login, name="Candidate", partner=admin.partner_id)

        self.assertFalse(
            self.Applicant._be_applicant_for_user(admin),
            "a shared partner must not put somebody else's assessments on "
            "this user's list")
        self.assertEqual(
            self.Applicant._be_applicant_for_user(candidate), applicant,
            "the real candidate must still resolve")

    # ------------------------------------------------------------------
    # The two directions agree
    # ------------------------------------------------------------------
    def test_the_list_and_the_gate_agree(self):
        """The invariant the bug broke.

        If the list offers somebody an attempt, the gate has to let that same
        person in. Asserted for both user kinds, because the rule that broke
        it applied to only one of them.
        """
        portal = self._user(self._email("portal"), "base.group_portal")
        staff = self._employee(self._email("staff"))

        for user in (portal, staff):
            applicant = self._applicant(user.login, name="Both Ways")
            attempt = self._attempt(applicant)

            self.assertEqual(
                self.Applicant._be_applicant_for_user(user), applicant,
                "the list must find the applicant for %s" % user.login)
            self.assertEqual(
                attempt._candidate_user(), user,
                "the gate must admit the person the list just offered it to "
                "(%s)" % user.login)

    # ------------------------------------------------------------------
    # The bind is the authority, and the address is the only other key
    # ------------------------------------------------------------------
    def test_an_explicit_bind_outranks_every_fallback(self):
        """A bind that disagrees with the address must not split the two walks.

        The gate reads the bind, so a list that reached the same applicant by
        address would offer an attempt the gate then refuses - the reported
        bug, rebuilt out of a mis-bind rather than an internal user. The
        reverse walk therefore has to CONFIRM its answer with the forward one,
        not mirror its steps by hand.
        """
        bound = self._user(self._email("bound"), "base.group_portal")
        other = self._user(self._email("other"), "base.group_portal")
        applicant = self._applicant(other.login, name="Mis Bound")
        applicant.be_candidate_user_id = bound.id

        self.assertEqual(applicant._be_candidate_user(), bound)
        self.assertFalse(
            self.Applicant._be_applicant_for_user(other),
            "the list must not offer an attempt the gate resolves to somebody "
            "else")

    def test_an_address_wildcard_cannot_name_another_account(self):
        """`_` is legal in a local-part, and `=ilike` is a SQL pattern.

        `a_b@…` also matches the account `axb@…`, so a search alone can name a
        stranger's login. This module has fixed the same bug once before, in
        the assign route. The bind is permanent and every gate keys on it, so a
        wrong one hands somebody else's account an exam.
        """
        domain = "wild%s.example.com" % uuid4().hex[:6]
        stranger = self._user("axb@%s" % domain, "base.group_portal")
        applicant = self._applicant("a_b@%s" % domain, name="Real Person")

        self.assertFalse(
            applicant._be_candidate_user(),
            "a wildcard match is not evidence of being the same person")

        self.Assessment._ensure_candidate_user(applicant)

        self.assertNotEqual(
            applicant.be_candidate_user_id, stranger,
            "provisioning must never bind an account the address does not "
            "actually name")

    def test_a_display_name_in_the_email_still_resolves(self):
        """`email_from` is free text and often carries a display name.

        Read strictly, `"Asha Rao" <asha@…>` normalises to nothing and the
        candidate silently gets an empty list. The stored `email_normalized`
        column the reverse walk searches is computed loosely, so both sides
        have to agree on the loose reading.
        """
        user = self._user(self._email("asha"), "base.group_portal")
        applicant = self._applicant(
            '"Asha Rao" <%s>' % user.login, name="Asha Rao")

        self.assertEqual(applicant._be_candidate_user(), user)
        self.assertEqual(
            self.Applicant._be_applicant_for_user(user), applicant)

    def test_a_provisioned_login_is_always_reachable_by_its_owner(self):
        """A created login must be lowercase - the gateway folds what is typed.

        The create wrote `email_from` raw while the search normalised it, so a
        login stored with capitals matched nothing its owner could type.
        """
        address = self._email("mixedcase")
        applicant = self._applicant(address.upper(), name="Mixed Case")

        self.assertEqual(self.Assessment._ensure_candidate_user(applicant),
                         "created")

        user = applicant.be_candidate_user_id
        self.assertTrue(user, "provisioning must bind the account it made")
        self.assertEqual(
            user.login, address.lower(),
            "a login carrying capitals is unreachable through the sign-in "
            "gateway, which folds the typed address before matching it")

    def test_a_display_name_never_becomes_the_login(self):
        """`email_from` may hold `"Asha Rao" <asha@corp.com>`; a login may not.

        Written verbatim that is an account nobody could ever sign in to.
        """
        address = self._email("displayname")
        applicant = self._applicant(
            '"Asha Rao" <%s>' % address, name="Asha Rao")

        self.assertEqual(self.Assessment._ensure_candidate_user(applicant),
                         "created")

        user = applicant.be_candidate_user_id
        self.assertEqual(
            user.login, address.lower(),
            "the login must be the bare address, not the display-name form")

    # ------------------------------------------------------------------
    # The Assign-candidates picker maps a directory user onto an applicant
    # ------------------------------------------------------------------
    def test_picking_a_new_person_makes_and_binds_their_applicant(self):
        """Assigning from the directory must not need a prior applicant.

        The picker offers `res.users`; the roster is keyed on `hr.applicant`.
        Somebody with an account but no applicant is the ordinary case - it is
        the whole reason the picker used to be unable to assign anybody who had
        not already sat an assessment.
        """
        user = self._user(self._email("newbie"), "base.group_portal")

        applicant, created = self.Applicant._be_ensure_applicant_for_user(user)

        self.assertTrue(created)
        self.assertEqual(applicant.be_candidate_user_id, user)
        self.assertEqual(applicant._be_candidate_user(), user,
                         "an applicant made from the directory must satisfy "
                         "the gate that will admit them")

    def test_picking_an_existing_person_reuses_their_applicant(self):
        """One person, one applicant - matched on the address, not a pattern.

        A second applicant for the same person splits their history and gives
        them two rosters to be removed from.
        """
        user = self._user(self._email("known"), "base.group_portal")
        existing = self._applicant(user.login, name="Known Person")

        applicant, created = self.Applicant._be_ensure_applicant_for_user(user)

        self.assertFalse(created)
        self.assertEqual(applicant, existing)
        self.assertEqual(applicant.be_candidate_user_id, user)

    def test_picking_someone_does_not_capture_a_wildcard_neighbour(self):
        """`_` is legal in a local-part and `=ilike` is a pattern.

        Matching `a_b@...` with a pattern also matches the account `axb@...`,
        which would put one person's assignment on another person's applicant.
        """
        domain = "pick%s.example.com" % uuid4().hex[:6]
        neighbour = self._applicant("axb@%s" % domain, name="Neighbour")
        user = self._user("a_b@%s" % domain, "base.group_portal")

        applicant, created = self.Applicant._be_ensure_applicant_for_user(user)

        self.assertTrue(created)
        self.assertNotEqual(applicant, neighbour)

    def test_an_archived_applicant_is_revived_rather_than_duplicated(self):
        user = self._user(self._email("returning"), "base.group_portal")
        existing = self._applicant(user.login, name="Returning")
        existing.active = False

        applicant, created = self.Applicant._be_ensure_applicant_for_user(user)

        self.assertFalse(created)
        self.assertEqual(applicant, existing)
        self.assertTrue(applicant.active)

    # ------------------------------------------------------------------
    # The assessment entry points store the case-folded address (Task 9a)
    # ------------------------------------------------------------------
    #
    # WHY THESE MATTER. `email_normalized` is the identity key everything
    # searches on, but `email_from` is what an operator READS and what the
    # login is provisioned from. When an entry point stored the operator's raw
    # casing, the visible address disagreed with the identity key, and a later
    # lowercase invite of the same person found no `=` match and made a
    # duplicate. The fix folds the address at the point it is stored, using the
    # same `_norm_email` the identity walk uses, so there is one spelling.

    def _assign_via_route(self, assessment, name, email):
        """Drive the assign route's create path with a request stub.

        Both `admin.request` (the route body's `request.env`) and
        `common.request` (what `arg`/`id_list_arg`/the decorators read) are the
        same proxy in production but distinct module bindings, so both are
        patched to one stub. The env is elevated to the Manager group the route
        gates on. This is the shipped route - re-implementing the store here
        would assert a copy behaves like itself.
        """
        from unittest.mock import patch
        from odoo.addons.assessments_be_v2.controllers.api import admin as A
        from odoo.addons.assessments_be_v2.controllers.api import common as CM

        manager = self.env.ref("assessments_be_v2.group_assessment_manager")
        env = self.env(user=self.env.ref("base.user_admin"))
        env.user.sudo().write({"group_ids": [(4, manager.id)]})

        class _Req:
            def __init__(self):
                self.params = {"assessment_id": assessment.id,
                               "candidates": [{"name": name, "email": email}]}
                self.env = env

            def make_json_response(self, payload, headers=None, status=200):
                return payload

        req = _Req()
        controller = A.EtpAssessmentApiAdmin()
        with patch.object(A, "request", req), \
                patch.object(CM, "request", req):
            controller.assessment_assign(assessment.id)

    def _blank_assessment(self):
        return self.Assessment.create(
            {"name": "Assign %s" % uuid4().hex[:6], "duration_minutes": 30})

    def test_assign_stores_the_folded_address(self):
        """`Asha.Rao@Corp.COM` must land as `asha.rao@corp.com`."""
        assessment = self._blank_assessment()
        domain = "fold%s.example.com" % uuid4().hex[:6]
        raw = "Asha.Rao@%s" % domain

        self._assign_via_route(assessment, "Asha Rao", raw)

        applicant = assessment.evaluator_ids
        self.assertEqual(len(applicant), 1)
        self.assertEqual(
            applicant.email_from, raw.lower(),
            "the assign route must store the case-folded address, not the "
            "operator's casing")

    def test_assign_matches_a_pre_existing_lowercase_applicant(self):
        """A mixed-case invite must find the lowercase record, not duplicate it.

        This is the whole point: identity is folded, so `Asha.Rao@Corp.COM` and
        `asha.rao@corp.com` are one person and must resolve to one applicant.
        """
        assessment = self._blank_assessment()
        domain = "match%s.example.com" % uuid4().hex[:6]
        lower = "asha.rao@%s" % domain
        existing = self._applicant(lower, name="Asha Rao")

        self._assign_via_route(assessment, "Asha Rao", lower.upper())

        self.assertEqual(
            assessment.evaluator_ids, existing,
            "a mixed-case invite of a known person must reuse their applicant, "
            "not create a second one")

    def test_csv_import_stores_the_folded_address(self):
        """The other entry point: the roster CSV importer folds on store too."""
        import base64
        assessment = self._blank_assessment()
        domain = "csv%s.example.com" % uuid4().hex[:6]
        raw = "Asha.Rao@%s" % domain
        csv_text = "name,email\nAsha Rao,%s\n" % raw
        assessment.candidate_csv_file = base64.b64encode(
            csv_text.encode("utf-8"))

        assessment.action_import_candidates_csv()

        self.assertEqual(
            assessment.evaluator_ids.email_from, raw.lower(),
            "the CSV importer must store the case-folded address")

    def test_candidate_email_related_inherits_the_fold(self):
        """`evaluator.candidate_email` is a stored related on `email_from`, so
        the fix propagates without a second normalisation to maintain."""
        assessment = self._blank_assessment()
        domain = "rel%s.example.com" % uuid4().hex[:6]
        applicant = self._applicant("asha.rao@%s" % domain, name="Asha Rao")
        evaluator = self.Evaluator.create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
        })
        self.assertEqual(evaluator.candidate_email, applicant.email_from)
