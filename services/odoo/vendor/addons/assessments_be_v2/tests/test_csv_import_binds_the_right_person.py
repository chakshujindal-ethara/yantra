"""A roster row must never bind a colleague's account to somebody else's exam.

THE DEFECT. The candidate CSV import matched an existing applicant with

    Applicant.search([("email_from", "=ilike", email)], limit=1)

on the RAW address from the file. `=ilike` reads `_` and `%` as wildcards, and
`_` is legal - and common - in an email local-part. So a roster row for
`a_b@corp.com` matched applicant `axb@corp.com`, and with `limit=1` that wrong
row was reused: the exam token was minted against a colleague, the invitation
mailed them a paper meant for someone else, and the candidate the row actually
named was never created.

Worst of all it was SILENT. No exception, nothing appended to `errors`, so the
import reported success and the roster looked complete. The mistake would only
surface when the wrong person opened the exam - or when the right person asked
why they never got one.

This is the THIRD site in this codebase to need the same escaping.
`_ensure_candidate_user` escapes its login needle and re-checks identity with
`_be_same_person`, and its comment says exactly why. This one did neither.

WHY BOTH HALVES ARE NEEDED. Escaping alone stops a wildcard reaching the wrong
row. The normalised re-check is what lets the search look PAST a bad hit: the
whole failure was accepting the first pattern match, so a fix that still takes
`limit=1` cannot express "keep looking". `_norm_email` is deliberately the same
fold `_be_same_person` and the create branch already use, so all three agree.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase


class TestCsvImportBindsTheRightPerson(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Applicant = self.env["hr.applicant"].sudo()
        self.assessment = self.env["assessments.be"].create({
            "name": "Roster paper %s" % uuid4().hex[:6],
        })

    def _import(self, rows):
        """Drive the real importer with a CSV built in memory."""
        import base64
        csv = "name,email\n" + "\n".join(
            "%s,%s" % (n, e) for n, e in rows)
        self.assessment.candidate_csv_file = base64.b64encode(csv.encode())
        self.assessment.candidate_csv_filename = "roster.csv"
        return self.assessment.action_import_candidates_csv()

    def test_an_underscore_address_does_not_match_a_wildcard_neighbour(self):
        """THE HEADLINE. `a_b@` must not bind to `axb@`.

        Before the fix this asserted-on applicant was never created and the
        import silently reused the neighbour instead.
        """
        neighbour = self.Applicant.create({
            "partner_name": "Wrong Person",
            "email_from": "axb@corp.com",
        })

        self._import([("Right Person", "a_b@corp.com")])

        bound = self.assessment.evaluator_ids
        self.assertNotIn(
            neighbour.id, bound.ids,
            "a wildcard match must NEVER bind a colleague to this exam")
        self.assertEqual(len(bound), 1)
        self.assertEqual(bound.email_from, "a_b@corp.com")

    def test_the_intended_candidate_is_actually_created(self):
        """The other half of the same bug: the real person went missing.

        Asserting only "the neighbour is not bound" would pass if the importer
        simply dropped the row, which is a different silent failure.
        """
        self.Applicant.create({
            "partner_name": "Wrong Person",
            "email_from": "axb@corp.com",
        })

        self._import([("Right Person", "a_b@corp.com")])

        created = self.Applicant.search([("email_from", "=", "a_b@corp.com")])
        self.assertEqual(
            len(created), 1,
            "the candidate the roster named must exist afterwards")
        self.assertEqual(created.partner_name, "Right Person")

    def test_a_percent_address_does_not_match_everything(self):
        """`%` is the other wildcard, and it is the wider blast radius.

        An unescaped `%@corp.com` matches EVERY corp.com applicant, so the
        first row of the roster would silently capture an arbitrary colleague.
        """
        self.Applicant.create({
            "partner_name": "Someone Else",
            "email_from": "unrelated@corp.com",
        })

        self._import([("Percent Person", "%@corp.com")])

        bound = self.assessment.evaluator_ids
        self.assertEqual(len(bound), 1)
        self.assertEqual(bound.email_from, "%@corp.com")

    def test_a_genuine_repeat_still_reuses_the_same_applicant(self):
        """The fix must not stop legitimate matching.

        Importing the same person twice - or an address differing only in case -
        must still find the existing row, or every re-import would fork a
        duplicate applicant and split one person's history in two.
        """
        first = self.Applicant.create({
            "partner_name": "Asha Rao",
            "email_from": "asha.rao@corp.com",
        })

        self._import([("Asha Rao", "Asha.Rao@CORP.com")])

        self.assertEqual(
            self.assessment.evaluator_ids.ids, first.ids,
            "a case-different repeat is the SAME person, not a new one")
        self.assertEqual(
            len(self.Applicant.search(
                [("email_from", "=ilike", "asha.rao@corp.com")])),
            1, "no duplicate applicant may be created")

    def test_a_backslash_address_does_not_raise(self):
        """`\\` is escaped first, or the escaping itself corrupts the needle.

        Order matters: escaping `_` and `%` before `\\` would double-escape the
        markers just inserted. Asserted through behaviour rather than by reading
        the string, so the test survives a rewrite of the escaping.
        """
        self._import([("Odd Person", "a\\b@corp.com")])
        self.assertEqual(len(self.assessment.evaluator_ids), 1)
