// A refused sign-in must hand the password field back, still typable.
//
// THE REPORT: after the red "Access Denied" banner the password box accepted
// no typing and the candidate had to reload the page. Nothing disables it and
// nothing clears it - it comes back UNFOCUSED, and on web a keystroke with
// nothing focused goes to the document. `focusNode.hasFocus` below is the
// assertion that catches that, and the only one that can: `enterText` focuses
// the field itself, so assertion 3 passes even with the defect present. The
// other three pin the rest of the reported symptom so a later change cannot
// trade one away for another.
//
// The REAL `LoginScreen`, `Session` and `ApiClient`; only the socket is faked,
// and it answers the exact body `api_auth_gateway/controllers/utility.py`
// produces for a wrong password - `message` overwritten with
// `", ".join(errors)`, where `str(AccessDenied())` is "Access Denied".
//
// RUN IT BOTH WAYS. The two causes of the lost focus land on different
// platforms: the `enabled: !s.busy` rebuild drops it everywhere, and
// `EditableText`'s tap-outside action drops it for a mouse only on web
// (`editable_text.dart:6777-6807`). On the VM this test fails on the first
// alone; under `--platform chrome` it fails on both, and chrome is where the
// ticket came from.
import 'dart:async';
import 'dart:convert';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/login_screen.dart';
import 'package:ethara_assessment/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/widgets/buttons.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('a refused sign-in leaves the password field focused and typable', (
    WidgetTester tester,
  ) async {
    // Under `Layout.twoColumn` on purpose: the wide layout mounts the brand
    // mark with `spin: true`, and a never-ending animation makes
    // `pumpAndSettle` time out rather than settle. Tall enough that the Sign
    // in button is on screen and can really be tapped.
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // The request is held open until the test lets it go. Without the gate the
    // mock answers inside the same microtask drain, no frame is ever built
    // while `session.busy` is true, and the whole disable/re-enable cycle that
    // strips the caret never happens - the test would pass against the bug.
    final Completer<void> inFlight = Completer<void>();
    final Session session = Session(
      api: ApiClient(
        baseUrl: 'http://stub',
        client: MockClient((http.Request req) async {
          await inFlight.future;
          return http.Response(
            jsonEncode(<String, dynamic>{
              'message': 'Access Denied',
              'errors': <String>['Access Denied'],
              'status_code': 400,
            }),
            400,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      ),
    );
    addTearDown(session.dispose);

    await tester.pumpWidget(MaterialApp(home: LoginScreen(session: session)));

    final Finder password = find.byType(TextField).at(1);
    await tester.enterText(find.byType(TextField).first, 'admin@ethara.ai');
    await tester.enterText(password, 'hunter2');
    await tester.pump();
    expect(
      tester.widget<TextField>(password).focusNode!.hasFocus,
      isTrue,
      reason: 'the caret has to start in the field for losing it to mean '
          'anything',
    );

    // The reported gesture is a CLICK on Sign in, not the Enter key - both
    // lose the focus on web, and this is the one the screenshot came from.
    // Found by its icon rather than its label: `Text('Sign in')` also titles
    // the card, and reaching for `Btn` would import a widget file that is
    // under edit elsewhere.
    await tester.tap(find.byIcon(Icons.login));
    await tester.pump();
    expect(
      session.busy,
      isTrue,
      reason: 'the in-flight frame must actually render, or the '
          '`enabled: !s.busy` half of the defect is never exercised',
    );

    inFlight.complete();
    await tester.pumpAndSettle();
    // One more frame: the restore runs in a post-frame callback, and the
    // FocusManager applies the change in a microtask after that.
    await tester.pump();

    expect(find.text('Wrong email or password.'), findsOneWidget);

    final TextField field = tester.widget<TextField>(password);
    expect(
      field.focusNode!.hasFocus,
      isTrue,
      reason: 'the field must come back focused, or every keystroke of the '
          'retyped password goes to the document and the only way out the '
          'candidate finds is a page reload',
    );

    await tester.enterText(password, 'second-try');
    expect(field.controller!.text, 'second-try');

    expect(session.busy, isFalse);
  });

  // AND IT HAS TO BE SPOKEN, not merely drawn.
  //
  // The refusal banner is a plain `Notice` - a Container/Row/Text.rich with no
  // semantics of its own - so a screen reader was never told the sign-in had
  // been refused. One frame later `_submit`'s post-frame callback drives the
  // accessibility cursor onto the password field, so the ONLY thing announced
  // is the field's hint: "Your password". A candidate on VoiceOver or NVDA
  // therefore retypes the same password into a form that has already told the
  // sighted user why it was refused, until the gateway's attempt limit stops
  // them.
  //
  // The label is asserted as well as the flag: a live region with no label of
  // its own announces nothing, which is the shape a bare
  // `Semantics(liveRegion: true)` around a multi-child widget produces.
  testWidgets('a refused sign-in announces itself to a screen reader', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Disposed inline, not in a tearDown: `WidgetTester` verifies that every
    // SemanticsHandle is gone BEFORE tearDowns run, so a tearDown is too late.
    final SemanticsHandle semantics = tester.ensureSemantics();

    final Session session = Session(
      api: ApiClient(
        baseUrl: 'http://stub',
        client: MockClient(
          (http.Request req) async => http.Response(
            jsonEncode(<String, dynamic>{
              'message': 'Access Denied',
              'errors': <String>['Access Denied'],
              'status_code': 400,
            }),
            400,
            headers: <String, String>{'content-type': 'application/json'},
          ),
        ),
      ),
    );
    addTearDown(session.dispose);

    await tester.pumpWidget(MaterialApp(home: LoginScreen(session: session)));
    await tester.enterText(find.byType(TextField).first, 'admin@ethara.ai');
    await tester.enterText(find.byType(TextField).at(1), 'hunter2');
    await tester.tap(find.byIcon(Icons.login));
    await tester.pumpAndSettle();
    await tester.pump();

    expect(find.text('Wrong email or password.'), findsOneWidget);

    final SemanticsNode node = tester.getSemantics(
      find.text('Wrong email or password.'),
    );
    expect(
      node.label,
      'Wrong email or password.',
      reason: 'the region has to carry the refusal as its own label, or a '
          'reader polling it finds nothing to read out',
    );
    expect(
      node.flagsCollection.isLiveRegion,
      isTrue,
      reason: 'without this the banner is silent and the candidate is told '
          'only "Your password" as focus returns to the field',
    );

    semantics.dispose();
  });

  // ONE REQUEST, NOT FIVE, when the gateway sheds a sign-in.
  //
  // The gateway answers 400 for the first ten wrong passwords on a login and
  // 429 with `Retry-After: 60` after that. `ApiError.isRetryable` is true for a
  // 429 - correctly, for the candidate write path it was written for - so the
  // ONLY thing keeping the retry ladder off the front door is that `login()`
  // routes through `_call` rather than `_callWithRetry`. That is one word in
  // `api_client.dart` with nothing pinning it, and moving it would turn each
  // refused sign-in into five, spend the candidate's remaining allowance in
  // one press and hold the form busy through four backoff sleeps.
  //
  // Counted at the socket, not at any one layer, so an interceptor or a
  // caller-level replay added anywhere above it would also fail this.
  testWidgets('a rate-limited sign-in is sent exactly once', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    int requests = 0;
    final Session session = Session(
      api: ApiClient(
        baseUrl: 'http://stub',
        client: MockClient((http.Request req) async {
          requests++;
          return http.Response(
            jsonEncode(<String, dynamic>{
              'message': 'Too many sign-in attempts. Try again in 60 seconds.',
              'status_code': 429,
            }),
            429,
            headers: <String, String>{
              'content-type': 'application/json',
              'retry-after': '60',
            },
          );
        }),
      ),
    );
    addTearDown(session.dispose);

    await tester.pumpWidget(MaterialApp(home: LoginScreen(session: session)));
    await tester.enterText(find.byType(TextField).first, 'admin@ethara.ai');
    await tester.enterText(find.byType(TextField).at(1), 'hunter2');
    await tester.tap(find.byIcon(Icons.login));
    await tester.pumpAndSettle();

    expect(
      requests,
      1,
      reason: 'a 429 on the front door must not be replayed - the ladder '
          'exists for the exam write path, where losing the call loses work',
    );
    expect(
      find.text('Too many sign-in attempts. Try again in 60 seconds.'),
      findsOneWidget,
      reason: "the gateway's own sentence is the only thing that tells the "
          'candidate their password is not what is being refused',
    );
    expect(
      session.busy,
      isFalse,
      reason: 'the form must not be left waiting out the `Retry-After` window '
          'with no way to cancel',
    );

    // THE DOOR IS HELD, AND IT SAYS FOR HOW LONG.
    //
    // `busy` false above means no request is in flight; it must NOT mean the
    // form is ready to be fired again. The server sent `Retry-After: 60`, and
    // until this landed the client parsed that header and threw it away, so
    // the button and - worse - "Forgot password?" went live on the same frame.
    // That is the 2026-09-17 shape: several hundred candidates followed the
    // reset link for a refusal no password could fix.
    expect(find.text('Try again in 60s'), findsOneWidget);
    expect(
      tester.widget<Btn>(find.widgetWithText(Btn, 'Try again in 60s')).onPressed,
      isNull,
      reason: 'a cooldown that only relabels the button still lets it be '
          'pressed, which spends the candidate\'s next attempt for nothing',
    );

    // AND IT LETS GO BY ITSELF. A cooldown that needs a reload to clear is a
    // worse bug than the one it fixes.
    await tester.pump(const Duration(seconds: 61));
    expect(session.cooldownSeconds, 0);
    expect(find.text('Try again in 60s'), findsNothing);
    // Scoped to the Btn: the card also carries a "Sign in" heading, so a bare
    // text finder here would pass on the heading alone and prove nothing.
    expect(
      tester.widget<Btn>(find.widgetWithText(Btn, 'Sign in')).onPressed,
      isNotNull,
      reason: 'the cooldown has to let go by itself - one that needs a reload '
          'to clear is a worse bug than the one it fixes',
    );
  });
}
