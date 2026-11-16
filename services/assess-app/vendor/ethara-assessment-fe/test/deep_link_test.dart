// The URL an invited candidate arrives on must open their exam.
//
// THE FAILURE THIS PREVENTS. The Odoo module emails an invitation link. If the
// app cannot read the token out of that URL, the candidate lands on a login
// screen and then their own list, having to find the assessment by hand - and
// on a `?q=` retry link, with no way back to the question they were on. The
// parsing is small and fails quietly on a trailing slash or a fragment, which
// is exactly why it is a pure function with tests rather than an inline read
// of `Uri.base`.
import 'package:flutter_test/flutter_test.dart';
import 'package:ethara_assessment/deep_link.dart';

void main() {
  _resetLinkTests();
  group('An invitation link yields its token', () {
    test('the plain path the module emails', () {
      expect(
        examTokenFrom(Uri.parse('https://assess.example.com/exam/abc123')),
        'abc123',
      );
    });

    test('a trailing slash does not swallow the token', () {
      expect(examTokenFrom(Uri.parse('https://x.dev/exam/abc123/')), 'abc123');
    });

    test('hash routing, which is Flutter web default', () {
      // `https://host/#/exam/<token>` - the path lives in the FRAGMENT, and
      // `uri.pathSegments` alone returns nothing for it.
      expect(examTokenFrom(Uri.parse('https://x.dev/#/exam/abc123')), 'abc123');
    });

    test('an explicit query parameter wins', () {
      expect(examTokenFrom(Uri.parse('https://x.dev/?token=abc123')), 'abc123');
    });

    test('the ODOO portal path is honoured too', () {
      // A link issued before this app existed, or copied from the Odoo
      // backoffice, still opens the right sitting. The token is the same key
      // either way, so refusing it would strand a candidate for no reason.
      expect(
        examTokenFrom(Uri.parse('https://odoo.dev/pro_assessment/tok9')),
        'tok9',
      );
    });

    test('a deeper link keeps working', () {
      expect(
        examTokenFrom(Uri.parse('https://x.dev/exam/abc123/review')),
        'abc123',
      );
    });
  });

  group('Everything else yields nothing', () {
    test('the app root is not an exam', () {
      expect(examTokenFrom(Uri.parse('https://x.dev/')), isNull);
    });

    test('a bare /exam with no token is not a token', () {
      // Returning '' here would send the section into the exam runner with an
      // empty token, which reports "this link does not work" instead of just
      // showing the normal home screen.
      expect(examTokenFrom(Uri.parse('https://x.dev/exam')), isNull);
      expect(examTokenFrom(Uri.parse('https://x.dev/exam/')), isNull);
    });

    test('another section is not mistaken for one', () {
      expect(examTokenFrom(Uri.parse('https://x.dev/assessments/12')), isNull);
    });

    test('an empty query parameter does not count', () {
      expect(examTokenFrom(Uri.parse('https://x.dev/?token=')), isNull);
    });
  });
}

void _resetLinkTests() {
  group('A reset link is not an exam link', () {
    test('the reset token is read off the reset page', () {
      expect(
        resetTokenFrom(Uri.parse('https://a.test/reset-password?token=abc123')),
        'abc123',
      );
    });

    test('the exam reader refuses to claim it', () {
      // THE COLLISION. Both tokens travel as `?token=`, and `examTokenFrom`
      // used to take any of them - so an emailed reset link opened the exam
      // runner against a token no evaluator holds, which dead-ends as "this
      // assessment is not available" with no route back to the reset form.
      expect(
        examTokenFrom(Uri.parse('https://a.test/reset-password?token=abc123')),
        isNull,
      );
    });

    test('a real exam link is untouched', () {
      final Uri exam = Uri.parse('https://a.test/exam/tok999');
      expect(examTokenFrom(exam), 'tok999');
      expect(resetTokenFrom(exam), isNull);
    });

    test('a bare query token is still an exam token', () {
      // The shape a link that lost its path arrives in. Only the reset PAGE
      // claims a token, so this must keep working.
      final Uri bare = Uri.parse('https://a.test/?token=tok999');
      expect(examTokenFrom(bare), 'tok999');
      expect(resetTokenFrom(bare), isNull);
    });

    test('hash routing carries the token in the fragment', () {
      expect(
        resetTokenFrom(Uri.parse('https://a.test/#/reset-password?token=abc')),
        'abc',
      );
    });

    test('a path-form token is accepted', () {
      expect(
        resetTokenFrom(Uri.parse('https://a.test/reset-password/abc')),
        'abc',
      );
    });

    test('the page with no token is still the reset page', () {
      // Empty, not null: the reset screen says "this link is incomplete",
      // which is far more use than silently showing the login form.
      expect(resetTokenFrom(Uri.parse('https://a.test/reset-password')), '');
    });
  });
}
