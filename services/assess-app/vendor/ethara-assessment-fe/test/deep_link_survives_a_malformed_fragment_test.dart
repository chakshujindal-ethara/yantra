// A MALFORMED HASH MUST NOT TAKE DOWN THE APP.
//
// `examTokenFrom` and `resetTokenFrom` both called `Uri.parse(uri.fragment)`,
// and `Uri.parse` throws on anything that is not a URI. A fragment is not
// required to be one - it is whatever follows the `#`.
//
// Both are called during startup routing (`main.dart`) and during build
// (`login_screen.dart`), with no try/catch above them, so one bad fragment
// meant a WHITE SCREEN instead of a login form, with no route back. It was
// found because the chrome test harness puts JSON metadata in the fragment and
// every chrome-hosted test died on it - the same crash a real candidate hits.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/deep_link.dart';

void main() {
  group('a fragment that is not a URI', () {
    // The exact shape the chrome harness produces, plus the ordinary ways a
    // hash gets mangled in an email client or a chat app.
    const List<String> nasty = <String>[
      '{"metadata":{"a":1}}',
      '%7B%22metadata%22:%7B%22a%22:1%7D%7D',
      ':::',
      '1http://x',
      ' ',
      '#',
      // THE SECOND THROW, which is not `Uri.parse` at all.
      //
      // `Uri.fragment`, `Uri.pathSegments` and `Uri.queryParameters` all DECODE
      // percent escapes as they are read, and a half-written escape has no
      // decoding. `Uri.parse` is what saves these: it re-encodes a stray `%` as
      // `%25` while parsing, so the decode downstream always has something
      // legal to work on. Pinned because it is not obvious, and because a
      // future reader reaching for a raw `Uri` built some other way - the
      // constructor, `Uri.tryParse` on an already-split string - would lose
      // that normalisation and get a FormatException out of a plain getter.
      '%',
      '%zz',
      // The empty-ish shapes. Each has to fall through to "no token" rather
      // than yielding the empty string, which would send a candidate into the
      // exam runner with nothing to look up.
      '',
      '/',
      'exam/',
      'exam//',
      '/exam/',
    ];

    for (final String frag in nasty) {
      test('examTokenFrom survives ${frag.trim()}', () {
        final Uri uri = Uri.parse('http://localhost:1234/x#$frag');
        expect(() => examTokenFrom(uri), returnsNormally);
        expect(examTokenFrom(uri), isNull);
      });

      test('resetTokenFrom survives ${frag.trim()}', () {
        final Uri uri = Uri.parse('http://localhost:1234/x#$frag');
        expect(() => resetTokenFrom(uri), returnsNormally);
        expect(resetTokenFrom(uri), isNull);
      });
    }
  });

  // The other half of "must not white-screen": a fragment that DOES yield a
  // token, but a mangled one. There is nothing to fix in these - the token is
  // whatever the link carried, and the server is the only thing that can say
  // whether it is real - but reading them must not throw, because the throw is
  // what costs a candidate the login form.
  group('a mangled fragment that still yields a token', () {
    test('a fragment big enough to be a tracking blob', () {
      final Uri uri = Uri.parse('http://host/x#${'a' * 4096}');
      expect(() => examTokenFrom(uri), returnsNormally);
      expect(examTokenFrom(uri), isNull, reason: 'no /exam/ segment in it');
    });

    test('a token a mail client wrapped onto a second line', () {
      final Uri uri = Uri.parse('http://host/#/exam/tok\nen');
      expect(examTokenFrom(uri), 'tok\nen');
    });

    test('a token carrying an escaped slash', () {
      // `%2F` decodes to a slash INSIDE one segment, so the token survives
      // whole rather than being split at it.
      expect(examTokenFrom(Uri.parse('http://host/#/exam/%2Fabc')), '/abc');
    });

    test('a token that really does contain a slash is cut at it', () {
      // Documented, not endorsed: a raw slash is a segment separator, so only
      // the first half reaches the server, which answers "this assessment is
      // not available". That is a dead link, not a white screen, and it is the
      // link that is wrong.
      expect(examTokenFrom(Uri.parse('http://host/#/exam/ab/cd')), 'ab');
    });

    test('a query tacked onto a hash-routed exam link', () {
      expect(examTokenFrom(Uri.parse('http://host/#exam/tok?x=1')), 'tok');
    });
  });

  group('the links that must still work', () {
    test('a hash-routed exam link still yields its token', () {
      expect(
        examTokenFrom(Uri.parse('http://host/#/exam/abc123')),
        'abc123',
      );
    });

    test('a query exam link still yields its token', () {
      expect(examTokenFrom(Uri.parse('http://host/?token=abc123')), 'abc123');
    });

    test('a hash-routed reset link still yields its token', () {
      expect(
        resetTokenFrom(Uri.parse('http://host/#/reset-password?token=xyz')),
        'xyz',
      );
    });

    test('a reset link is never read as an exam link', () {
      // The reader has to be asked first, or the exam runner claims the bare
      // `?token=` and the candidate lands on "assessment not available".
      final Uri uri = Uri.parse('http://host/reset-password?token=xyz');
      expect(resetTokenFrom(uri), 'xyz');
      expect(examTokenFrom(uri), isNull);
    });
  });
}
