// The reset form states the password rules, and ticks them as the user types.
//
// THE REPORT (prod, 2026-09-29): ~60 users failed `POST
// /api/v1/auth/reset_password` over and over with 422 "Your password must
// contain at least 12 characters and only has 10." and "Password must contain
// an uppercase letter." - the form never said what the rules were, so the only
// way to learn them was to be refused one at a time.
//
// The checklist is a GUIDE: the submit button must not be gated on it (the
// server stays the authority), and the server's own refusal must still show.
import 'dart:convert';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';
import 'package:ethara_assessment/password_reset.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The core policy's exact refusal, in the module's `fail()` envelope at the
/// 422 its `api_endpoint` gives a UserError.
const String kServerRefusal =
    'Your password must contain at least 12 characters and only has 10.';

void main() {
  late int resets;

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    resets = 0;
    final ApiClient api = ApiClient(
      baseUrl: 'http://stub',
      maxAttempts: 1,
      client: MockClient((http.Request req) async {
        if (req.url.path.endsWith('/auth/reset_password')) resets++;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'ok': false,
            'error': <String, dynamic>{
              'code': 'rejected',
              'message': kServerRefusal,
            },
          }),
          422,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ResetPasswordScreen(token: 'tok', onDone: () {}, api: api),
      ),
    );
    await tester.pump();
  }

  Finder rule(String label, {required bool met}) =>
      find.bySemanticsLabel('$label, ${met ? 'met' : 'not met'}');

  testWidgets('every rule is listed, none met on an empty field', (
    WidgetTester tester,
  ) async {
    await open(tester);
    for (final ({String label, bool Function(String) met}) r
        in kPasswordRules) {
      expect(find.text(r.label), findsWidgets, reason: r.label);
      expect(rule(r.label, met: false), findsOneWidget, reason: r.label);
    }
  });

  testWidgets('the rules tick live as the password is typed', (
    WidgetTester tester,
  ) async {
    await open(tester);
    // 10 characters with every class: only the length is still short - the
    // exact password prod refused.
    await tester.enterText(find.byType(TextField).first, 'Abcdefgh1!');
    await tester.pump();
    expect(rule('At least 12 characters', met: false), findsOneWidget);
    expect(rule('One uppercase letter', met: true), findsOneWidget);
    expect(rule('One lowercase letter', met: true), findsOneWidget);
    expect(rule('One number', met: true), findsOneWidget);
    expect(
      rule('One special character, e.g. ! @ # or a space', met: true),
      findsOneWidget,
    );

    await tester.enterText(find.byType(TextField).first, 'Abcdefgh1!xy');
    await tester.pump();
    expect(rule('At least 12 characters', met: true), findsOneWidget);
  });

  testWidgets('unmet rules do not disable submit; the server refusal shows', (
    WidgetTester tester,
  ) async {
    await open(tester);
    await tester.enterText(find.byType(TextField).at(0), 'abcdefgh1!');
    await tester.enterText(find.byType(TextField).at(1), 'abcdefgh1!');
    await tester.pump();
    expect(rule('One uppercase letter', met: false), findsOneWidget);

    final Finder submit = find.widgetWithText(Btn, 'Set new password');
    expect(tester.widget<Btn>(submit).onPressed, isNotNull,
        reason: 'the checklist guides; the server decides');

    await tester.tap(submit);
    await tester.pump();
    await tester.pump();
    expect(resets, 1, reason: 'the request must still reach the server');
    expect(find.text(kServerRefusal), findsOneWidget,
        reason: "the server's own words stay on screen when it refuses");
  });

  group('the policy from /auth/password_policy', () {
    setUp(resetPasswordPolicyCache);
    tearDown(resetPasswordPolicyCache);

    late int asked;

    /// The reset page on a client whose policy route answers [policy]
    /// (null: the route fails, as on a backend without it).
    Future<void> openWith(
      WidgetTester tester,
      Map<String, dynamic>? policy,
    ) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      asked = 0;
      final ApiClient api = ApiClient(
        baseUrl: 'http://stub',
        maxAttempts: 1,
        client: MockClient((http.Request req) async {
          if (req.url.path.endsWith('/auth/password_policy')) asked++;
          if (policy == null) throw http.ClientException('no route');
          return http.Response(
            jsonEncode(<String, dynamic>{'ok': true, 'data': policy}),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ResetPasswordScreen(token: 'tok', onDone: () {}, api: api),
        ),
      );
      await tester.pump();
    }

    testWidgets('a fetched policy changes the list', (
      WidgetTester tester,
    ) async {
      await openWith(tester, <String, dynamic>{
        'min_length': 14,
        'require': <String>['upper', 'digit'],
      });

      expect(asked, 1);
      expect(rule('At least 14 characters', met: false), findsOneWidget);
      expect(find.text('At least 12 characters'), findsNothing);
      expect(rule('One uppercase letter', met: false), findsOneWidget);
      expect(rule('One number', met: false), findsOneWidget);
      expect(find.text('One lowercase letter'), findsNothing);
      expect(
        find.text('One special character, e.g. ! @ # or a space'),
        findsNothing,
      );

      await tester.enterText(find.byType(TextField).first, 'ABCDEFGHIJKL12');
      await tester.pump();
      expect(rule('At least 14 characters', met: true), findsOneWidget);
      expect(rule('One uppercase letter', met: true), findsOneWidget);
      expect(rule('One number', met: true), findsOneWidget);
    });

    testWidgets('a failed fetch keeps the static list', (
      WidgetTester tester,
    ) async {
      await openWith(tester, null);

      expect(asked, 1);
      for (final PasswordRule r in kPasswordRules) {
        expect(rule(r.label, met: false), findsOneWidget, reason: r.label);
      }
    });

    testWidgets('an unreadable answer keeps the static list', (
      WidgetTester tester,
    ) async {
      await openWith(tester, <String, dynamic>{'min_length': 'twelve'});

      for (final PasswordRule r in kPasswordRules) {
        expect(rule(r.label, met: false), findsOneWidget, reason: r.label);
      }
    });

    testWidgets('fetched once per session', (WidgetTester tester) async {
      final Map<String, dynamic> policy = <String, dynamic>{
        'min_length': 14,
        'require': <String>['upper'],
      };
      await openWith(tester, policy);
      // A fresh screen, not the same State updated in place.
      await tester.pumpWidget(const SizedBox());
      await openWith(tester, policy);

      expect(asked, 0, reason: 'the second screen reads the cached policy');
      expect(rule('At least 14 characters', met: false), findsOneWidget);
    });
  });
}
