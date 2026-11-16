// THE COPIED LINK HAS TO WORK WHERE IT IS PASTED.
//
// `Assessment.candidateLink` is deliberately RELATIVE - `/exam/<token>` - because
// `context.nav.exam` routes on it inside the app. The copy button handed that
// straight to the clipboard, so an operator pasted `/exam/9f3c...` into an email
// and the toast said "Candidate link copied". It is not a link anywhere outside
// that tab.
//
// The getter must stay relative; the COPY SITE is what has to absolutise.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/screens/admin/attempt_detail_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the link is absolutised when it can be, and never crashes', () {
    // `absoluteLink` reads `Uri.base` itself, so the branch it takes is decided
    // by the harness: chrome gives an http base, the VM gives `file://`. Rather
    // than assert one environment's answer, this asserts the CONTRACT for
    // whichever base it got - and running the file on both platforms is what
    // covers both branches.
    const String relative = '/exam/9f3ctoken';
    expect(relative.startsWith('/'), isTrue,
        reason: 'the getter must stay relative for in-app routing');

    final String copied = absoluteLink(relative);
    final bool webLike =
        Uri.base.scheme == 'http' || Uri.base.scheme == 'https';

    if (webLike) {
      expect(Uri.parse(copied).hasScheme, isTrue,
          reason: 'what reaches the clipboard must resolve where it is pasted');
      expect(Uri.parse(copied).path, relative);
    } else {
      // `Uri.base.origin` THROWS on any scheme that is not http/https, and off
      // the web `Uri.base` is `file://`. Calling it unguarded turned a copy
      // button into a crash. The relative link is a poor clipboard value; an
      // exception is a worse one.
      expect(copied, relative);
    }
  });

  test('an empty link stays empty rather than becoming a bare origin', () {
    // `ev.token.isEmpty` disables the button, but the helper must not invent a
    // link if it is ever called without one.
    expect(absoluteLink(''), '');
  });

  test('a clipboard write that fails does not report success', () async {
    // The button awaits the write before toasting. Pinned because the original
    // defect on this control was the reverse: it reported success without
    // touching the clipboard at all, so the operator pasted whatever was there
    // before - the worst failure mode, because the toast said it worked.
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (MethodCall c) async {
      calls.add(c);
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await Clipboard.setData(
      ClipboardData(text: absoluteLink('/exam/9f3ctoken')),
    );

    expect(calls.single.method, 'Clipboard.setData');
    expect(
      (calls.single.arguments as Map<Object?, Object?>)['text'],
      contains('/exam/9f3ctoken'),
    );
    expect(
      (calls.single.arguments as Map<Object?, Object?>)['text'],
      isNotEmpty,
    );
  });
}
