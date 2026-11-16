// The dashboard renders with a SERVER-supplied leaderboard.
//
// THE BUG THIS EXISTS FOR: the panel used to rank candidates in the client from
// whatever attempts happened to be cached, dropping every unreleased one - so it
// read "Nobody can be ranked yet" while `/api/v1/leaderboard` was returning nine
// ranked people, and it contradicted the score distribution printed beside it.
//
// It now renders the server's rows. That moves a snake_case wire payload into a
// widget, which is exactly the kind of change that throws during build and paints
// Flutter's release-mode ErrorWidget - the grey rectangle where the body should
// be. Reading that exception out of a browser was not possible (capture returns
// "image readback failed"), so the render is asserted here instead.
@TestOn('vm')
// The first assertion below reads this repo's own source with `dart:io`, which
// does not exist in a browser - so under Chrome the whole file died on an
// UnsupportedError before any widget test ran. Every other source-reading test
// in this suite carries this tag; this one was missed.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/dashboard_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

Widget mount(Widget child, AssessmentNav nav) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(body: AssessmentNavScope(nav: nav, child: child)),
);

Future<void> setSurface(WidgetTester tester) async {
  // Tall on purpose. The dashboard is a long scroll of panels; at a laptop
  // height the empty-state variants overflow by ~129px and every assertion then
  // fails on a RenderFlex complaint rather than on the thing being tested.
  tester.view.physicalSize = const Size(1600, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

AppStore seeded() {
  final AppStore s = AppStore();
  s.people = <Person>[
    const Person(id: 'p1', name: 'Diya Sharma', email: 'diya@example.com'),
  ];
  s.assessments = <Assessment>[
    Assessment.fromJson(<String, dynamic>{
      'id': 'a1',
      'name': 'DEMO Q3 Certification',
      'state': 'done',
      'questions': <dynamic>[
        <String, dynamic>{
          'id': 'q1',
          'name': 'Question 1',
          'question_type': 'mcq',
        },
      ],
    }),
  ];
  return s;
}

/// Straight off the wire: snake_case keys, exactly as `/api/v1/leaderboard`
/// returned them on etp_local.
List<Map<String, dynamic>> liveRows() => <Map<String, dynamic>>[
  <String, dynamic>{
    'rank': 1,
    'applicant_id': 33,
    'applicant_name': 'Diya Sharma',
    'attempts': 2,
    'avg_score': 63.3,
    'best_score': 66.7,
    'passed': 0,
  },
  <String, dynamic>{
    'rank': 2,
    'applicant_id': 32,
    'applicant_name': 'Aarav Mehta',
    'attempts': 1,
    'avg_score': 60.0,
    'best_score': 60.0,
    'passed': 0,
  },
];

void main() {
  group('Dashboard leaderboard', () {
    test('no numeric jval anywhere in lib/ uses an int fallback', () {
      // WHY A SOURCE CHECK: the widget tests below run on the VM, where
      // `0 is double` is FALSE, so jval takes its int branch and passes. In
      // compiled JavaScript there is one numeric type and `0 is double` is
      // TRUE, so an int fallback sends 66.7 down the double branch and then
      // casts it to int:
      //   TypeError: 66.7: type 'double' is not a subtype of type 'int'
      // That threw during build and painted the whole dashboard body grey,
      // while every VM test stayed green. Only a source rule catches it.
      //
      // WHOLE TREE, not just the dashboard. The first version of this guard
      // read one file, which would have passed while the identical mistake sat
      // in models.dart or any other screen. The server sends 24 float-valued
      // keys (avg_score, best_score, cost_usd, pass_rate, final_mark, the *_pct
      // family, ...), and every one of them is reachable from more than one
      // screen.
      final Directory lib = Directory('lib');
      expect(lib.existsSync(), isTrue, reason: 'run from the package root');

      // Keyed on the FIELDS THE SERVER ACTUALLY SENDS AS FLOATS, sampled off a
      // live backend, not on a keyword guess. A name-shape rule ("anything
      // containing score") flags `score`, `max_score`, `llm_score` and
      // `progress_percent`, and every one of those is a genuine
      // `fields.Integer` on the Odoo side (models/assessment.py:2080-2157) or
      // an explicit `int(...)` in the serializer — so the broad rule reports
      // six false positives and trains whoever hits it to widen the exemption
      // list instead of reading the payload.
      final RegExp floatKey = RegExp(
        r"jval\((?!<double>)[^)]*?'("
        r"avg_?[Ss]core|best_?[Ss]core|score_?[Pp]ercent|scorePercent|"
        r"pass_?[Rr]ate|completion_?[Rr]ate|"
        r"cost_?[Uu]sd|spend_?[Uu]sd|cap_?[Uu]sd|per_?[Ee]valuator_?[Cc]ap_?[Uu]sd|"
        r"final_?[Mm]ark|mcq_?[Mm]ark|raw_?[Rr]esult|llm_?[Rr]aw_?100|"
        r"key_?[Cc]loseness|sop_?[Cc]overage|video_?[Ss]econds|"
        r"pass_?[Tt]hreshold|subjective_?[Tt]hreshold|"
        r"[a-zA-Z_]*[Pp]ct"
        r")'\s*,\s*-?\d+\s*\)",
      );

      final List<String> offenders = <String>[];
      for (final FileSystemEntity f in lib.listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final List<String> lines = f.readAsLinesSync();
        for (int i = 0; i < lines.length; i++) {
          final String line = lines[i];
          if (line.trimLeft().startsWith('//')) continue;
          for (final RegExpMatch m in floatKey.allMatches(line)) {
            offenders.add('${f.path}:${i + 1}  ${m.group(0)}');
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason: 'use a double fallback (0.0) or jval<double>: an int fallback '
            'on a value the server sends as a float throws in compiled JS and '
            'paints an ErrorWidget',
      );
    });

    test('the dashboard leaderboard reads its scores as doubles', () {
      final File screen = File(
        'lib/assessment/screens/admin/dashboard_screen.dart',
      );
      expect(screen.existsSync(), isTrue, reason: 'run from the package root');
      final String src = screen.readAsStringSync();

      // Any score/percent/rate/avg read with a bare `0` fallback.
      final RegExp intFallback = RegExp(
        r"jval\([^)]*?'[a-z_]*(?:score|percent|rate|avg)[a-z_]*'\s*,\s*0\s*\)",
      );
      final Iterable<RegExpMatch> hits = intFallback.allMatches(src);
      expect(
        hits.map((RegExpMatch m) => m.group(0)).toList(),
        isEmpty,
        reason: 'use 0.0 - an int fallback throws in compiled JS',
      );
    });

    testWidgets('a live payload builds without throwing', (
      WidgetTester tester,
    ) async {
      await setSurface(tester);
      final AppStore s = seeded()..leaderboard = liveRows();

      await tester.pumpWidget(mount(DashboardScreen(store: s),
          AssessmentNav()));
      await tester.pumpAndSettle();

      // ErrorWidget is what paints the grey box; its presence IS the defect.
      expect(find.byType(ErrorWidget), findsNothing);
      expect(tester.takeException(), isNull);
      expect(find.text('Diya Sharma'), findsWidgets);
    });

    testWidgets('an empty board renders its empty state', (
      WidgetTester tester,
    ) async {
      await setSurface(tester);
      final AppStore s = seeded()..leaderboard = <Map<String, dynamic>>[];

      await tester.pumpWidget(mount(DashboardScreen(store: s),
          AssessmentNav()));
      await tester.pumpAndSettle();

      expect(find.byType(ErrorWidget), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a row missing every key still builds', (
      WidgetTester tester,
    ) async {
      // The server always sends the full shape, but one partial row must cost a
      // blank cell, not the whole screen.
      await setSurface(tester);
      final AppStore s = seeded()
        ..leaderboard = <Map<String, dynamic>>[<String, dynamic>{}];

      await tester.pumpWidget(mount(DashboardScreen(store: s),
          AssessmentNav()));
      await tester.pumpAndSettle();

      expect(find.byType(ErrorWidget), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
