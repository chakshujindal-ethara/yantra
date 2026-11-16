// The admin's attempt page shows how long the sitting took and its Pace tag.
//
// WHY: time taken, the test's median and the Fast / Normal / Slow tag lived
// only in the dashboard's Time Analysis panel. The owner wants them on the
// candidate's result too, in the Session panel. Pace stays admin-side: this is
// the admin's screen, and the candidate's own screens are not touched.
//
// WHAT CAN GO WRONG HERE is a tag with nothing true behind it: a duration
// invented for a paper still being written, or a median taken over the wrong
// set. So each row appears only when it has something true to say, and the
// median is the server's when it sent one, else the store's.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/category_scores.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/attempt_detail_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/dashboard_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/marks.dart';
import 'package:ethara_assessment/assessment/widgets/panel.dart';

/// One sitting of `a1`, [mins] minutes long when [submitted].
Map<String, dynamic> row(
  String id, {
  required int mins,
  bool submitted = true,
  Map<String, dynamic> extra = const <String, dynamic>{},
}) => <String, dynamic>{
  'id': id,
  'assessment_id': 'a1',
  'candidate': <String, dynamic>{'id': 'p1', 'name': 'Anita Rao'},
  'state': submitted ? 'submitted' : 'started',
  'is_locked': submitted,
  'invite_state': 'sent',
  // Both ends in UTC: a bare "2026-08-13 11:00:00" parses as LOCAL time, and
  // mixing the two would skew every span by the machine's offset.
  'started_at': '2026-08-13T11:00:00Z',
  if (submitted)
    'submitted_at': DateTime.utc(
      2026,
      8,
      13,
      11,
      0,
    ).add(Duration(minutes: mins)).toIso8601String(),
  'answered_count': 1,
  'total_questions': 1,
  ...extra,
};

/// The instant [mins] minutes after the sittings' shared start, as the server
/// spells it (UTC), for a `deadline` or `submitted_at`.
String at(int mins) => DateTime.utc(
  2026,
  8,
  13,
  11,
  0,
).add(Duration(minutes: mins)).toIso8601String();

/// A store holding attempt `80` plus [others] (minutes each) of the same test.
AppStore seeded(
  Map<String, dynamic> mine, {
  List<int> others = const <int>[],
  int limit = 0,
}) {
  final AppStore s = AppStore();
  s.people = <Person>[
    const Person(id: 'p1', name: 'Anita Rao', email: 'anita@example.com'),
  ];
  s.assessments = <Assessment>[
    Assessment.fromJson(<String, dynamic>{
      'id': 'a1',
      'name': 'ETP Assessment Pro',
      'state': 'done',
      'duration_minutes': limit,
      'questions': <dynamic>[
        <String, dynamic>{
          'id': 'q1',
          'name': 'Question 1',
          'question_type': 'mcq',
        },
      ],
    }),
  ];
  s.attempts = <Attempt>[
    Attempt.fromJson(mine),
    for (int i = 0; i < others.length; i++)
      Attempt.fromJson(row('${i + 1}', mins: others[i])),
  ];
  return s;
}

Future<void> open(WidgetTester t, AppStore store) async {
  t.view.physicalSize = const Size(1800, 3000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: AssessmentNavScope(
          nav: AssessmentNav(),
          child: AttemptDetailScreen(
            store: store,
            portal: Portal.admin,
            attemptId: '80',
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

/// The Session panel row called [k], or nothing.
Finder kv(String k) =>
    find.byWidgetPredicate((Widget w) => w is KvRow && w.k == k);

void main() {
  group('The Session panel carries time taken and pace', () {
    testWidgets('a submitted attempt with a server median shows both rows', (
      WidgetTester t,
    ) async {
      // 7 min against a server median of 10 min is 0.70x: Fast. The store
      // holds sittings whose own median would say Slow, so a pass here means
      // the server's number won.
      await open(
        t,
        seeded(
          row(
            '80',
            mins: 7,
            extra: <String, dynamic>{'test_median_seconds': 600},
          ),
          others: <int>[4, 5, 6],
          limit: 45,
        ),
      );

      expect(kv('Time taken'), findsOneWidget);
      expect(
        find.descendant(
          of: kv('Time taken'),
          // The span itself, not "7 of 45 min": the row shares one number
          // with the Pace tag beside it, whatever the paper's limit is now.
          matching: find.text('7m'),
        ),
        findsOneWidget,
      );
      expect(kv('Pace'), findsOneWidget);
      expect(
        find.descendant(
          of: kv('Pace'),
          matching: find.widgetWithText(Pill, 'Fast'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: kv('Pace'), matching: find.text('median 10m')),
        findsOneWidget,
        reason: 'the tag shows the number it was judged by',
      );
      expect(
        find.byTooltip(
          paceExplanation(
            const Duration(minutes: 7),
            const Duration(seconds: 600),
          ),
        ),
        findsOneWidget,
        reason: 'the same tooltip the dashboard cell carries',
      );
    });

    testWidgets('the rows sit directly under Submitted, in that order', (
      WidgetTester t,
    ) async {
      await open(
        t,
        seeded(
          row(
            '80',
            mins: 7,
            extra: <String, dynamic>{'test_median_seconds': 600},
          ),
        ),
      );

      final List<String> keys = find
          .byType(KvRow)
          .evaluate()
          .map((Element e) => (e.widget as KvRow).k)
          .toList();
      final int i = keys.indexOf('Submitted');
      expect(keys.sublist(i, i + 3), <String>[
        'Submitted',
        'Time taken',
        'Pace',
      ]);
      expect(keys.last, 'Candidate link');
    });

    testWidgets('with no time limit the time reads as plain duration', (
      WidgetTester t,
    ) async {
      await open(
        t,
        seeded(
          row(
            '80',
            mins: 75,
            extra: <String, dynamic>{'test_median_seconds': 4500},
          ),
        ),
      );

      expect(
        find.descendant(of: kv('Time taken'), matching: find.text('1h 15m')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: kv('Pace'),
          matching: find.widgetWithText(Pill, 'Normal'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('an attempt that is not submitted shows neither row', (
      WidgetTester t,
    ) async {
      // The server may well send a median for the test; with no finished
      // sitting there is no duration to judge against it.
      await open(
        t,
        seeded(
          row(
            '80',
            mins: 7,
            submitted: false,
            extra: <String, dynamic>{'test_median_seconds': 600},
          ),
        ),
      );

      expect(kv('Time taken'), findsNothing);
      expect(kv('Pace'), findsNothing);
      expect(find.text('Not submitted'), findsOneWidget);
    });

    testWidgets(
      'without the server key the page falls back to the store median',
      (WidgetTester t) async {
        // Timed sittings held: 4, 5, 6 and this 7. Median (5 + 6) / 2 = 5.5 min,
        // so 7 min is 1.27x: Slow.
        await open(t, seeded(row('80', mins: 7), others: <int>[4, 5, 6]));

        expect(
          find.descendant(
            of: kv('Pace'),
            matching: find.widgetWithText(Pill, 'Slow'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: kv('Pace'), matching: find.text('median 5m 30s')),
          findsOneWidget,
        );
      },
    );

    // ONE FORMAT ON THE PAGE (BR-D12). "Time taken" read "1 min" while the
    // Pace tooltip beside it read "1m 45s": the same span, two answers.
    testWidgets('time taken, the median and the tooltip agree to the second', (
      WidgetTester t,
    ) async {
      final Map<String, dynamic> mine = row(
        '80',
        mins: 0,
        extra: <String, dynamic>{
          'submitted_at': '2026-08-13T11:01:45Z',
          'test_median_seconds': 105,
        },
      );
      await open(t, seeded(mine));

      expect(
        find.descendant(of: kv('Time taken'), matching: find.text('1m 45s')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: kv('Pace'), matching: find.text('median 1m 45s')),
        findsOneWidget,
      );
      const Duration span = Duration(minutes: 1, seconds: 45);
      expect(find.byTooltip(paceExplanation(span, span)), findsOneWidget);
    });

    testWidgets('a lone sitting is its own median, so it reads Normal', (
      WidgetTester t,
    ) async {
      await open(t, seeded(row('80', mins: 7)));

      expect(kv('Time taken'), findsOneWidget);
      expect(
        find.descendant(
          of: kv('Pace'),
          matching: find.widgetWithText(Pill, 'Normal'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('an unsubmitted sitting does not pull the fallback median', (
      WidgetTester t,
    ) async {
      final AppStore s = seeded(row('80', mins: 7), others: <int>[4, 5, 6]);
      s.attempts = <Attempt>[
        ...s.attempts,
        Attempt.fromJson(row('9', mins: 1, submitted: false)),
      ];
      await open(t, s);

      expect(
        find.descendant(of: kv('Pace'), matching: find.text('median 5m 30s')),
        findsOneWidget,
      );
    });
  });

  group('test_median_seconds parses like every other server number', () {
    Duration? parsed(Object? v, {bool present = true}) => Attempt.fromJson(
      <String, dynamic>{'id': '1', if (present) 'test_median_seconds': v},
    ).testMedian;

    test('an int becomes that many seconds', () {
      expect(parsed(600), const Duration(minutes: 10));
    });

    test('a double does, which is what compiled JS may hand over', () {
      expect(parsed(30.0), const Duration(seconds: 30));
    });

    test('the camelCase spelling is read too', () {
      expect(
        Attempt.fromJson(<String, dynamic>{
          'id': '1',
          'testMedianSeconds': 90,
        }).testMedian,
        const Duration(seconds: 90),
      );
    });

    test('null, absent, zero, negative and non-numbers give null', () {
      expect(parsed(null), isNull);
      expect(parsed(null, present: false), isNull);
      expect(parsed(0), isNull);
      expect(parsed(-5), isNull);
      expect(parsed('600'), isNull);
    });
  });

  group('A list refresh keeps what only the detail route carries', () {
    AppStore live() => AppStore(
      api: ApiClient(
        client: MockClient((http.Request req) async {
          final String path = req.url.path;
          final Object body = path.endsWith('/attempts')
              // The LIST shape: no `test_median_seconds`.
              ? <dynamic>[row('4', mins: 7)]
              : path.contains('/attempts/')
              ? row(
                  '4',
                  mins: 7,
                  extra: <String, dynamic>{'test_median_seconds': 600},
                )
              : path.endsWith('/assessments')
              ? <dynamic>[
                  <String, dynamic>{'id': 'a1', 'name': 'T', 'state': 'done'},
                ]
              : <String, dynamic>{'id': 'a1', 'name': 'T', 'state': 'done'};
          return http.Response(
            jsonEncode(<String, dynamic>{'ok': true, 'data': body}),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
        baseUrl: 'http://x',
      ),
    );

    test(
      'a list-row merge after the detail load does not erase testMedian',
      () async {
        final AppStore s = live();

        await s.loadAttempt('4');
        expect(
          s.attemptById('4')!.testMedian,
          const Duration(minutes: 10),
          reason: 'the detail route sends it',
        );

        await s.refresh(background: true);

        expect(
          s.attemptById('4')!.testMedian,
          const Duration(minutes: 10),
          reason: 'list rows never carry the key, so they must not blank it',
        );
      },
    );
  });

  // THE SERVER STAMPS `submitted_at` WHEN A SITTING IS SETTLED, not when it
  // ended. An expired paper swept by the cron an hour late must count only up
  // to its deadline, in ONE place, so every screen agrees.
  group('A sitting counts only up to its deadline', () {
    Attempt sitting({String? deadline, int? submittedAt}) =>
        Attempt.fromJson(<String, dynamic>{
          'id': '1',
          'started_at': at(0),
          if (submittedAt != null) 'submitted_at': at(submittedAt),
          'deadline': ?deadline,
        });

    test('stamped an hour after its deadline, it counts to the deadline', () {
      expect(
        attemptDuration(sitting(deadline: at(60), submittedAt: 120)),
        const Duration(hours: 1),
      );
    });

    test('with no deadline the stamp stands', () {
      expect(
        attemptDuration(sitting(submittedAt: 120)),
        const Duration(hours: 2),
      );
    });

    test('submitted before the deadline is unchanged', () {
      expect(
        attemptDuration(sitting(deadline: at(60), submittedAt: 30)),
        const Duration(minutes: 30),
      );
    });

    test('a deadline that is not after the start gives no span', () {
      // Only a positive span counts, same as for a backwards stamp.
      expect(
        attemptDuration(sitting(deadline: at(0), submittedAt: 30)),
        isNull,
      );
      expect(
        attemptDuration(sitting(deadline: at(-5), submittedAt: 30)),
        isNull,
      );
    });

    test('an unsubmitted sitting still has none, deadline or not', () {
      expect(attemptDuration(sitting(deadline: at(60))), isNull);
    });

    test('timeUsed agrees even with no time limit to cap against', () {
      expect(
        timeUsed(sitting(deadline: at(60), submittedAt: 120), null),
        '60 min',
        reason: 'before the rule this read 120 min when no limit was known',
      );
    });

    testWidgets('the attempt page shows the capped time and the pace of it', (
      WidgetTester t,
    ) async {
      // No limit on the assessment, so "Time taken" comes from attemptDuration
      // and not from timeUsed's own cap. 60 min against a 50 min median is
      // 1.20x: Normal. Counted to the stamp it would be 120 min, 2.40x: Slow.
      await open(
        t,
        seeded(
          row(
            '80',
            mins: 120,
            extra: <String, dynamic>{
              'deadline': at(60),
              'test_median_seconds': 3000,
            },
          ),
        ),
      );

      expect(
        find.descendant(of: kv('Time taken'), matching: find.text('1h')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: kv('Pace'),
          matching: find.widgetWithText(Pill, 'Normal'),
        ),
        findsOneWidget,
      );
      expect(
        find.byTooltip(
          paceExplanation(
            const Duration(hours: 1),
            const Duration(minutes: 50),
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the attempt page without a deadline is unchanged', (
      WidgetTester t,
    ) async {
      await open(
        t,
        seeded(
          row(
            '80',
            mins: 120,
            extra: <String, dynamic>{'test_median_seconds': 3000},
          ),
        ),
      );

      expect(
        find.descendant(of: kv('Time taken'), matching: find.text('2h')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: kv('Pace'),
          matching: find.widgetWithText(Pill, 'Slow'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the dashboard Time Analysis row counts to the deadline', (
      WidgetTester t,
    ) async {
      // Three 50 min sittings and one settled late: capped it is 60 min
      // (median 50, 1.20x, Normal); uncapped 120 min (2.40x, Slow).
      final AppStore s = seeded(
        row('80', mins: 120, extra: <String, dynamic>{'deadline': at(60)}),
        others: <int>[50, 50, 50],
      );
      t.view.physicalSize = const Size(1900, 3000);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: AssessmentNavScope(
              nav: AssessmentNav(),
              child: DashboardScreen(store: s),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();

      final Finder panel = find.ancestor(
        of: find.text('Time Analysis'),
        matching: find.byType(Panel),
      );
      expect(panel, findsOneWidget);
      expect(
        find.descendant(of: panel, matching: find.widgetWithText(Mono, '1h')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: panel, matching: find.widgetWithText(Mono, '2h')),
        findsNothing,
      );
      expect(
        find.descendant(of: panel, matching: find.widgetWithText(Pill, 'Slow')),
        findsNothing,
      );
      expect(
        find.descendant(
          of: panel,
          matching: find.widgetWithText(Pill, 'Normal'),
        ),
        findsNWidgets(4),
      );
    });
  });
}
