"""An answer key that DRIFTS from its option text must still resolve.

The model writes the option list and the answer key as separate fields, so it
restates the option text and sometimes mis-transcribes it. Run 1 against the
real IG Entity SOP produced:

    option : "A stock photo of the exact red handbag isolated on a white background."
    key    : "A stock photo of the exact red handbag isolated on a a white background."

One doubled article. Exact string equality marked NO option correct, and the
question published to the bank with has_valid_key=False - unscoreable, every
candidate wrong whatever they picked. (The launch guard does keep such a
question out of assessments, so nobody sat it; the loss was a silently wasted
question, not a mis-scored candidate.)

Normalising punctuation, whitespace, case and doubled words rescues the
question. A genuinely different answer must still fail to match, or the key
would stop meaning anything.
"""
from odoo.tests.common import TransactionCase


class TestAnswerKeyDriftStillResolves(TransactionCase):

    OPTION = ("A stock photo of the exact red handbag isolated on a white "
              "background.")

    def _matches(self, option, key):
        PQ = self.env["assessments.be.prompt.question"]
        return PQ._key_matches_option(option, [key])

    def test_the_real_run1_drift_resolves(self):
        """The exact failure seen against the live SOP."""
        drifted = ("A stock photo of the exact red handbag isolated on a a "
                   "white background.")
        self.assertTrue(
            self._matches(self.OPTION, drifted),
            "a doubled article made the question unscoreable")

    def test_trailing_period_resolves(self):
        self.assertTrue(
            self._matches(self.OPTION, self.OPTION.rstrip(".")))

    def test_case_and_whitespace_resolve(self):
        noisy = "  A STOCK photo of the exact red handbag  isolated on a white background. "
        self.assertTrue(self._matches(self.OPTION, noisy))

    def test_curly_punctuation_resolves(self):
        """NFKC expands an ellipsis to dots, which are then stripped as
        trailing punctuation. That is the right call: an ellipsis carries no
        meaning the answer depends on."""
        curly = "A stock photo of the exact red handbag isolated on a white background\u2026"
        self.assertTrue(self._matches(self.OPTION, curly))

    def test_a_curly_apostrophe_resolves(self):
        """The drift form that actually bites: smart quotes from a docx."""
        option = "Don't annotate the dog."
        key = "Don\u2019t annotate the dog."
        self.assertTrue(self._matches(option, key))

    def test_a_genuinely_different_answer_does_not_match(self):
        """The key must keep meaning something."""
        other = "A photo of a model carrying the exact red handbag."
        self.assertFalse(self._matches(self.OPTION, other))

    def test_a_negated_answer_does_not_match(self):
        wrong = ("A stock photo of the exact BLUE handbag isolated on a white "
                 "background.")
        self.assertFalse(self._matches(self.OPTION, wrong))

    def test_an_empty_key_does_not_match(self):
        self.assertFalse(self._matches(self.OPTION, ""))
