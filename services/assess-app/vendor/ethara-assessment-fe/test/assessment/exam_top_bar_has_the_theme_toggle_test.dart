// During a sitting the rail that carries the theme toggle is hidden, so the
// exam's top bar carries one. Pressing it flips the theme and is not a
// violation. Also pins the stored-theme parse.
@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/exam/exam_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/main.dart';

const String kToken = 'tok-theme';

void main() {
  test('stored theme: only "light" is light, anything else is dark', () {
    expect(themeFromPref('light'), ThemeMode.light);
    expect(themeFromPref('dark'), ThemeMode.dark);
    expect(themeFromPref(null), ThemeMode.dark);
    expect(themeFromPref('purple'), ThemeMode.dark);
    expect(themeFromPref(''), ThemeMode.dark);
  });

  testWidgets('question page: toggle present, flips, records no violation', (
    WidgetTester t,
  ) async {
    final AppStore s = AppStore();
    s.portal = Portal.member;
    s.source = DataSource.live;
    s.meId = '2';
    s.attempts = <Attempt>[
      Attempt.fromJson(<String, dynamic>{
        'id': 7,
        'access_token': kToken,
        'assessment_id': 21,
        'state': 'in_progress',
        'started_at': DateTime.now().toUtc().toIso8601String(),
        'deadline': DateTime.now()
            .add(const Duration(minutes: 30))
            .toUtc()
            .toIso8601String(),
      }),
    ];
    s.assessments = <Assessment>[
      Assessment.fromJson(<String, dynamic>{
        'id': 21,
        'name': 'sample test',
        'state': 'in_progress',
        'duration_minutes': 45,
      }),
    ];
    s.examByToken[kToken] = ExamView.fromJson(<String, dynamic>{
      'outcome': 'question',
      'question': <String, dynamic>{
        'id': '10',
        'index': 1,
        'total': 3,
        'name': 'Question 1',
        'prompt': 'Prompt.',
        'question_type': 'subjective_rubric',
        'dimensions': <dynamic>[],
        'images': <dynamic>[],
        'videos': <dynamic>[],
        'label_boxes': <dynamic>[],
      },
      'answered_question_ids': <dynamic>[],
      'progress_percent': 0,
    });
    t.view.physicalSize = const Size(1400, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    bool dark = true;
    await t.pumpWidget(
      StatefulBuilder(
        builder: (BuildContext c, StateSetter set) => MaterialApp(
          theme: ThemeData.dark(),
          home: AssessmentNavScope(
            nav: AssessmentNav(),
            child: ExamScreen(
              store: s,
              token: kToken,
              sub: ExamSub.question,
              isDark: dark,
              onToggleTheme: () => set(() => dark = !dark),
            ),
          ),
        ),
      ),
    );
    await t.pump();

    expect(find.byTooltip('Switch to light'), findsOneWidget);
    await t.tap(find.byTooltip('Switch to light'));
    await t.pump();
    expect(dark, isFalse);
    expect(find.byTooltip('Switch to dark'), findsOneWidget);
    expect(s.attemptByToken(kToken)!.violationCount, 0);
    // Dispose the clock's timer.
    await t.pumpWidget(const SizedBox());
  });
}
