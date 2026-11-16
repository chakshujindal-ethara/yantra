// Browser campaign, 8 Oct 2026, BR-D2: a toast over an exam sat on top of
// Previous and Review & Submit, the controls it was asking the candidate to
// use. Toasts over an exam now sit above its pinned footer.
//
// Ported from stage's `a_submit_is_shown_only_once_the_server_takes_it_test`
// (its BR-D2 group).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/assessment_section.dart';
import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/screens/exam/exam_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';

void main() {
  testWidgets('on the question page, nothing in the footer is covered', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    // The fixture store: an exam in progress, no backend.
    final AppStore s = AppStore();
    addTearDown(s.dispose);
    final Attempt sitting = s.attempts.firstWhere(
      (Attempt a) => a.state == AttemptState.inProgress && a.startedAt != null,
    );
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: AssessmentSection(store: s, examToken: sitting.token),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.byType(ExamTopBar), findsOneWidget);

    const String said =
        'Your exam was NOT submitted. $kNoConnection And a second line, '
        'so it is as tall as a real refusal.';
    s.toaster.bad(said);
    await t.pumpAndSettle();

    final double footerTop = t
        .getTopLeft(find.widgetWithText(Btn, 'Previous'))
        .dy;
    expect(t.getBottomLeft(find.text(said)).dy, lessThan(footerTop));
    // The lift is the footer's real height - the buttons, the 12 px above
    // them and its 1 px top border - so the two cannot drift apart.
    expect(900 - footerTop + 12 + 1, kExamFooterHeight);

    await t.pump(const Duration(minutes: 1));
  });
}
