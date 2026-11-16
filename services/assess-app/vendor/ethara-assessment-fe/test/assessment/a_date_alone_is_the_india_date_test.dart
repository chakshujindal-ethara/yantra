// A date shown on its own is the INDIA date, like every time beside it.
//
// Times already read in IST with an "IST" label. The bare dates did not: the
// candidate's "Submitted" (My results, My performance), Form Studio's
// "Updated" and the flag tooltip's "on Sep 8th" each printed `.day` of either
// the UTC stamp or the browser's local time. Anything done between midnight
// and 05:30 in India - 18:30 to 00:00 UTC - showed the day before.
//
// Every case starts from a UTC instant in that window. Run this file with
// `TZ=UTC` and `TZ=America/Los_Angeles` as well as in India: a date that is
// only right on an IST machine is the defect, not the fix.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/form_models.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/form_studio_screen.dart';
import 'package:ethara_assessment/assessment/screens/member/my_assessments_screen.dart';
import 'package:ethara_assessment/assessment/screens/member/my_performance_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

/// 20 Sep 19:00 UTC is 21 Sep 00:30 in India.
const String kLateUtc = '2026-09-20T19:00:00Z';

/// One released, submitted sitting for the signed-in candidate.
AppStore _candidate() {
  final AppStore s = AppStore();
  s.people = <Person>[
    const Person(id: 'p1', name: 'Priya Sharma', email: 'priya@example.com'),
  ];
  s.meId = 'p1';
  s.assessments = <Assessment>[
    Assessment(
      id: 'a1',
      name: 'Forklift',
      state: AsmState.done,
      durationMinutes: 45,
      questions: <Question>[
        Question(
          id: 'q1',
          genId: 'g1',
          name: 'Q1',
          prompt: 'Why?',
          type: QType.subjectiveRubric,
        ),
      ],
    ),
  ];
  s.attempts = <Attempt>[
    Attempt(
      id: '11',
      assessmentId: 'a1',
      employeeId: 'p1',
      token: '11',
      state: AttemptState.submitted,
      resultsReleased: true,
      startedAt: DateTime.parse('2026-09-20T18:20:00Z'),
      submittedAt: DateTime.parse(kLateUtc),
    ),
  ];
  return s;
}

Future<void> _mount(WidgetTester t, Widget child) async {
  t.view.physicalSize = const Size(1600, 3000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: AssessmentNavScope(nav: AssessmentNav(), child: child),
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  group('the India date of an instant', () {
    test('a late UTC evening is already the next day in India', () {
      expect(istShortDate(DateTime.parse(kLateUtc)), '21/9/2026');
    });

    test('the day turns at 18:30 UTC, not at midnight UTC', () {
      expect(istShortDate(DateTime.utc(2026, 9, 20, 18, 29)), '20/9/2026');
      expect(istShortDate(DateTime.utc(2026, 9, 20, 18, 30)), '21/9/2026');
    });

    test('a local DateTime is converted, not read as India', () {
      expect(istShortDate(DateTime.parse(kLateUtc).toLocal()), '21/9/2026');
    });
  });

  test('the flag tooltip names the India date', () {
    const CandidateFlag f = CandidateFlag(
      flagged: true,
      by: 'Akshay Kumar',
      at: '2026-09-07T19:00:00Z',
    );
    expect(f.raisedSentence, 'Raised by Akshay Kumar on Sep 8th, 2026');
  });

  group('a form\'s updated_at, which the route sends with no zone', () {
    test('is read as UTC, not as the browser\'s local time', () {
      // `write_date.isoformat()`: UTC, and no `Z` to say so.
      final FormDef f = FormDef.fromJson(<String, dynamic>{
        'id': 'f1',
        'updated_at': '2026-09-20T19:00:00.123456',
      });
      expect(
        f.updatedAt.isAtSameMomentAs(
          DateTime.utc(2026, 9, 20, 19, 0, 0, 123, 456),
        ),
        isTrue,
      );
    });

    test('a stamp that names its zone keeps it', () {
      final FormDef f = FormDef.fromJson(<String, dynamic>{
        'id': 'f1',
        'updated_at': '2026-09-21T00:30:00+05:30',
      });
      expect(
        f.updatedAt.isAtSameMomentAs(DateTime.utc(2026, 9, 20, 19)),
        isTrue,
      );
    });

    test('survives its own export and re-import', () {
      final FormDef f = FormDef('f1', updatedAt: DateTime.parse(kLateUtc));
      final FormDef back = FormDef.fromJson(f.toJson());
      expect(back.updatedAt.isAtSameMomentAs(f.updatedAt), isTrue);
    });
  });

  group('on screen', () {
    testWidgets('My results says the candidate submitted on the India date', (
      WidgetTester t,
    ) async {
      await _mount(t, MyResultsScreen(store: _candidate()));
      expect(find.text('21/9/2026'), findsOneWidget);
      expect(find.text('20/9/2026'), findsNothing);
    });

    testWidgets('My performance says the same', (WidgetTester t) async {
      await _mount(t, MyPerformanceScreen(store: _candidate()));
      expect(find.text('21/9/2026'), findsOneWidget);
      expect(find.text('20/9/2026'), findsNothing);
    });

    testWidgets('Form Studio\'s Updated column is the India date', (
      WidgetTester t,
    ) async {
      final AppStore s = AppStore();
      s.forms = <FormDef>[
        FormDef.fromJson(<String, dynamic>{
          'id': 'f1',
          'title': 'Intake',
          'updated_at': '2026-09-20T19:00:00',
        }),
      ];
      await _mount(t, FormStudioScreen(store: s));
      expect(find.text('2026-09-21'), findsOneWidget);
    });
  });
}
