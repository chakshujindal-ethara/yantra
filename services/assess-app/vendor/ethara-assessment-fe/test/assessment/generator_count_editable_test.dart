/// "Questions to generate" stays typeable once a quota exists.
///
/// THE DEFECT. Setting a single per-type quota REPLACED the number field with
/// a printed number and a "derived from the picks below" pill, so the control
/// vanished mid-edit and the total could no longer be raised from this screen
/// at all. The model never worked that way: `effectiveQuestionCount` is
/// `max(typed, quotaFloor)` - the floor RAISES a total that is too small and
/// never caps one that is large enough - and `_countHelp` has always been able
/// to render the remainder as "N the model's choice". "20 across these three
/// types" was expressible everywhere except in the field the operator types
/// into.
///
/// The lock existed to stop two numbers disagreeing on screen. Making the
/// floor the field's own `min` keeps that guarantee without taking the control
/// away: there is still exactly one number, and it is the one that will run.
library;

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/generator_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A generator committed to 2 MCQ + 2 Rubric: a floor of 4.
///
/// Built off the store's own record, because the screen resolves its generator
/// out of the store by id.
Generator quoted(Generator base, {int typed = 0}) => base.copyWith(
  allowedTypes: const <QType>[QType.mcq, QType.subjectiveRubric],
  shapeQuotas: const <String, int>{'mcq': 2, 'subjective_rubric': 2},
  sopQuestionCount: typed,
  questionCountMode: typed == 0 ? 'auto' : 'fixed',
);

/// The Generation tab as an OPERATOR sees it.
///
/// Live, because every editable control on this tab is gated on `isLive` - a
/// seed store renders the read-only twin and would pass this file's central
/// assertion for the wrong reason.
///
/// The store is built on fixtures and then switched, because the seed
/// constructor is what populates it. Caller must finish with [close].
Future<AppStore> openGeneration(WidgetTester tester, {int typed = 0}) async {
  tester.view.physicalSize = const Size(1500, 4200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final AppStore s = AppStore();
  final Generator g = s.generators.first;
  s.source = DataSource.live;
  s.updateGenerator(quoted(g, typed: typed));

  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: AssessmentNavScope(
          nav: AssessmentNav(),
          child: GeneratorDetailScreen(store: s, genId: g.id, tab: 'generation'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return s;
}

/// Ends the test cleanly.
///
/// A live screen hydrates its generator from a server this binary does not
/// have, so the failed call raises a toast - and a toast holds a 3200ms
/// dismissal timer (`feedback.dart:216`) that outlives the widget tree and
/// trips the framework's pending-timer check. Pumping past it lets the toast
/// expire on its own rather than reaching around it. `addTearDown` is too
/// late: that check runs before tear-downs do.
Future<void> close(WidgetTester tester, AppStore s) async {
  await tester.pump(const Duration(seconds: 4));
  s.dispose();
}

/// The count control, told apart from "Image labelling count" beside it by the
/// cap the two do not share.
NumberField countField(WidgetTester tester) => tester
    .widgetList<NumberField>(find.byType(NumberField))
    .firstWhere((NumberField f) => f.max == 50);

void main() {
  group('The field survives a quota', () {
    testWidgets('a quota leaves a real number field, not a printed number', (
      WidgetTester tester,
    ) async {
      final AppStore s = await openGeneration(tester);
      // The regression in one line: this used to find nothing.
      expect(
        find.byType(NumberField),
        findsWidgets,
        reason: 'the count must stay editable once a quota exists',
      );
      expect(countField(tester).value, 4);
      await close(tester, s);
    });

    testWidgets('the floor is the field\'s minimum, not a lock', (
      WidgetTester tester,
    ) async {
      // Typing under 4 clamps to 4 - the same answer the locked number gave,
      // but one the operator can watch happen.
      final AppStore s = await openGeneration(tester);
      expect(countField(tester).min, 4);
      await close(tester, s);
    });

    testWidgets('the note sits BELOW the field, not in place of it', (
      WidgetTester tester,
    ) async {
      final AppStore s = await openGeneration(tester);
      final Finder note = find.text('derived from the picks below');
      expect(note, findsOneWidget);
      expect(
        tester.getTopLeft(note).dy,
        greaterThan(tester.getBottomLeft(find.byType(NumberField).first).dy),
      );
      await close(tester, s);
    });

    testWidgets('raised past the floor, the note stops claiming the total', (
      WidgetTester tester,
    ) async {
      // 20 asked for, 4 committed: the total is the operator's number, so
      // "derived from the picks below" would be a false claim about it.
      final AppStore s = await openGeneration(tester, typed: 20);
      expect(countField(tester).value, 20);
      expect(find.text('derived from the picks below'), findsNothing);
      expect(find.text('4 of it from the picks below'), findsOneWidget);
      await close(tester, s);
    });

    testWidgets('the help line spends the remainder on the model', (
      WidgetTester tester,
    ) async {
      final AppStore s = await openGeneration(tester, typed: 20);
      expect(find.textContaining("16 the model's choice"), findsOneWidget);
      await close(tester, s);
    });
  });

  group('The arithmetic behind it', () {
    test('the floor raises a short count and never caps a long one', () {
      final AppStore s = AppStore();
      final Generator base = s.generators.first;
      expect(quoted(base).effectiveQuestionCount, 4);
      expect(quoted(base, typed: 2).effectiveQuestionCount, 4);
      expect(quoted(base, typed: 20).effectiveQuestionCount, 20);
      s.dispose();
    });
  });
}
