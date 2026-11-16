// Does each sidebar destination actually open its own screen?
//
// This exists because browser automation cannot verify it: Flutter web renders
// to a canvas, so a synthetic click never reaches the handler and a screenshot
// only proves what was already on screen. A widget test drives the real
// widgets, so it is the only honest check that `AssessmentEntry.generators`
// opens the generator list rather than silently falling back to the console.
//
// The gap this guards against is real: before the entry enum was extended,
// Generators / Question bank / Review queue were unreachable from anywhere in
// the app, because the assessment list only ever links to assessments.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ethara_assessment/assessment/assessment_section.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/nav.dart';

void main() {
  group('Sidebar destinations open their own root screen', () {
    // Pump the section for one entry and read back which route the internal
    // navigator settled on. The store runs in seed mode here (no injected
    // ApiClient), so the screens have fixtures to render and the test needs
    // no backend.
    Future<AssessmentRoute> rootFor(
      WidgetTester tester,
      AssessmentEntry entry,
    ) async {
      // A desktop-sized surface. The default test window is 800x600, but the
      // data grids declare a minWidth of 860, so every screen would overflow
      // and the failure would look like a routing bug rather than a viewport
      // that is simply narrower than the app targets.
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // The store is INJECTED now rather than built inside the section, so the
      // test constructs it. With no ApiClient it runs on seed data, which is
      // what lets these assertions work with no backend.
      final AppStore store = AppStore();
      addTearDown(store.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AssessmentSection(store: store, entry: entry),
          ),
        ),
      );
      await tester.pump();

      // Read from the scope element itself, not from AssessmentSection: the
      // section BUILDS the scope, so its own element sits above it and
      // `of(context)` would find nothing.
      final AssessmentNavScope scope = tester.widget<AssessmentNavScope>(
        find.byType(AssessmentNavScope),
      );
      return scope.notifier!.current;
    }

    testWidgets('generators opens the generator list', (WidgetTester t) async {
      expect(
        await rootFor(t, AssessmentEntry.generators),
        isA<GeneratorList>(),
      );
    });

    testWidgets('question bank opens the bank', (WidgetTester t) async {
      expect(
        await rootFor(t, AssessmentEntry.questionBank),
        isA<QuestionBank>(),
      );
    });

    testWidgets('review queue opens the queue', (WidgetTester t) async {
      expect(await rootFor(t, AssessmentEntry.reviewQueue), isA<ReviewQueue>());
    });

    testWidgets('responses opens the response list', (WidgetTester t) async {
      expect(await rootFor(t, AssessmentEntry.responses), isA<ResponsesList>());
    });

    testWidgets('tags opens the tag vocabulary', (WidgetTester t) async {
      expect(await rootFor(t, AssessmentEntry.tags), isA<TagsAdmin>());
    });

    testWidgets('budget opens the LLM budget', (WidgetTester t) async {
      expect(await rootFor(t, AssessmentEntry.budget), isA<BudgetAdmin>());
    });

    testWidgets('settings opens assessment settings', (WidgetTester t) async {
      expect(await rootFor(t, AssessmentEntry.settings), isA<SettingsAdmin>());
    });

    testWidgets('my assessments opens the candidate list', (
      WidgetTester t,
    ) async {
      expect(await rootFor(t, AssessmentEntry.mine), isA<MyAssessments>());
    });

    testWidgets('console lands on the Dashboard', (WidgetTester t) async {
      // The plain entry - no destination asked for - opens the dashboard. It
      // used to open the assessment list, which answers "what papers exist"
      // rather than "how is this going", and left the rail's first row unlit.
      expect(await rootFor(t, AssessmentEntry.console), isA<Analytics>());
    });
  });
}
