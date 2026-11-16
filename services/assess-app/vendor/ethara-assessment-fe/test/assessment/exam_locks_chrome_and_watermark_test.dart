/// The exam locks the app chrome away, and the watermark covers the surface.
///
/// WHY THESE TWO LIVE TOGETHER. They are the same defect from the demo seen
/// from two sides: the exam surface was not treated as a locked surface. The
/// sidebar stayed live on it (a candidate could leave a running sitting), and
/// the watermark was sized for a slab in the middle of it rather than for the
/// surface itself.
///
/// Both were reproduced in a browser before being changed here.
library;

import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/exam/exam_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Same shape the other widget suites in this directory mount with.
Widget mount(Widget child) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(
    body: Stack(children: <Widget>[Positioned.fill(child: child)]),
  ),
);

/// The rule the shell applies, kept here in the same shape the shell uses.
///
/// `_examIsLocked` is private to `_AssessmentSectionState` and the whole
/// section needs a live store plus a navigator to build, which is a far larger
/// rig than this decision deserves. The predicate is one switch, so it is
/// restated here.
///
/// THE RESTATEMENT IS ALSO HOW THE SECOND HOLE SURVIVED, and that is worth
/// naming. This copy said "a drift between the two cannot pass silently", and
/// a drift is exactly what happened: the shell gained nothing, but the ROUTE
/// stopped telling the whole truth. A deep link - `?token=...`, how every
/// invitation and every resume arrives - builds `Exam(token)` at the default
/// stage, `gate`, and the runner then draws the question itself without the
/// route ever moving off `gate`. Every test below still passed while a
/// candidate who reloaded mid-exam sat the rest of the paper with a live rail
/// beside them. Reproduced in a browser at question 10 of 29.
///
/// So the predicate now takes what the shell takes: the stage AND whether that
/// attempt is actually under way.
bool locked(AssessmentRoute r, {bool sittingUnderWay = false}) => switch (r) {
  Exam(:final ExamStage stage) =>
    stage == ExamStage.question ||
        stage == ExamStage.answers ||
        stage == ExamStage.review ||
        (stage == ExamStage.gate && sittingUnderWay),
  _ => false,
};

void main() {
  group('The chrome is locked away while answers are being given', () {
    test('a live question locks it', () {
      // THE DEMO DEFECT. Mid-sitting, "My performance" was clickable in the
      // rail: clicking it left the exam and showed the candidate's results
      // while the clock kept running.
      expect(locked(const Exam('t', stage: ExamStage.question)), isTrue);
    });

    test('the answer sheet and the review pass lock it too', () {
      // Answers are still editable on both, so both are still the exam.
      expect(locked(const Exam('t', stage: ExamStage.answers)), isTrue);
      expect(locked(const Exam('t', stage: ExamStage.review)), isTrue);
    });

    test('the briefing does NOT lock it', () {
      // The briefing offers "Not now" in its own copy. Trapping somebody on a
      // page that invites them to leave would be a worse bug than the one
      // being fixed.
      expect(locked(const Exam('t')), isFalse);
      expect(locked(const Exam('t', stage: ExamStage.gate)), isFalse);
    });

    test('a RESUMED sitting locks it, though the route still says gate', () {
      // THE DEEP-LINK HOLE. `?token=...` builds Exam(token) with the default
      // stage; the runner decides for itself that the attempt is under way and
      // draws question 10 of 29. Nothing about the route changes, so a rule
      // that reads only the route leaves the rail live for the rest of the
      // paper - on the single most ordinary path there is, a page reload.
      expect(
        locked(const Exam('t'), sittingUnderWay: true),
        isTrue,
        reason: 'a candidate who reloaded mid-exam could still click through '
            'to their own results with the clock running',
      );
      expect(
        locked(const Exam('t', stage: ExamStage.gate), sittingUnderWay: true),
        isTrue,
      );
    });

    test('a briefing for a sitting NOT yet started stays leavable', () {
      // The distinction that keeps the fix from becoming a trap: the briefing
      // offers "Not now", and an attempt nobody has started is exactly that.
      expect(locked(const Exam('t'), sittingUnderWay: false), isFalse);
    });

    test('the completion card does NOT lock it', () {
      // Nothing is left to protect once the sitting is submitted, and the
      // candidate needs the rail to get back to their list.
      expect(locked(const Exam('t', stage: ExamStage.complete)), isFalse);
    });

    test('ordinary candidate and admin routes never lock it', () {
      expect(locked(const MyAssessments()), isFalse);
      expect(locked(const Analytics()), isFalse);
      expect(locked(const AssessmentsList()), isFalse);
    });
  });

  group('The watermark covers the whole surface it is given', () {
    /// Pumps the watermark at a given surface size and reports the painted
    /// tile block's size.
    Future<Size> blockFor(WidgetTester tester, Size surface) async {
      tester.view.physicalSize = surface;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(mount(const Watermark(label: 'Priya Sharma')));
      await tester.pump();

      // The SizedBox the tiles are laid into - the thing that used to be a
      // hardcoded 1140x600.
      final Finder box = find.descendant(
        of: find.byType(Watermark),
        matching: find.byType(SizedBox),
      );
      final SizedBox sized = tester.widgetList<SizedBox>(box).firstWhere(
        (SizedBox b) => (b.width ?? 0) > 0 && (b.height ?? 0) > 0,
      );
      return Size(sized.width!, sized.height!);
    }

    testWidgets('on a large display it still spans past both axes', (
      WidgetTester tester,
    ) async {
      // 1728x1049 is the window the defect was photographed at. The old fixed
      // block was 1140x600 - narrower AND shorter than the surface, so the
      // corners were bare and the overhang fell on the sidebar.
      const Size surface = Size(1728, 1049);
      final Size block = await blockFor(tester, surface);

      expect(
        block.width,
        greaterThan(surface.width),
        reason: 'a block narrower than the surface leaves bare corners',
      );
      expect(block.height, greaterThan(surface.height));
    });

    testWidgets('the rotation is paid for, not just the bounding box', (
      WidgetTester tester,
    ) async {
      // Covering a rotated rectangle needs MORE than the rectangle: at -30
      // degrees the corners swing outside it. Rounding up to exactly the
      // surface would clip them at the diagonal.
      const Size surface = Size(1728, 1049);
      final Size block = await blockFor(tester, surface);
      final double longest = surface.width > surface.height
          ? surface.width
          : surface.height;

      expect(block.width, greaterThan(longest * 1.4));
      expect(block.height, greaterThan(longest * 1.4));
    });

    testWidgets('it scales to an ultrawide surface too', (
      WidgetTester tester,
    ) async {
      // Proves the size is COMPUTED rather than merely bumped to a bigger
      // constant: a wider surface must produce a wider block.
      final Size small = await blockFor(tester, const Size(1280, 800));
      final Size wide = await blockFor(tester, const Size(3440, 1440));

      expect(wide.width, greaterThan(small.width));
      expect(wide.width, greaterThan(3440));
    });

    testWidgets('an empty label paints nothing at all', (
      WidgetTester tester,
    ) async {
      // A watermark with no name on it is pure cost: it dims the exam and
      // deters nobody. The server sends an empty label when the roster row has
      // no name yet.
      await tester.pumpWidget(mount(const Watermark(label: '')));

      // Scoped to the Watermark's OWN subtree. `MaterialApp` builds Transforms
      // of its own (page transitions, the Material ink), so a bare
      // `find.byType(Transform)` is non-empty on an empty page and the
      // assertion would pass or fail for reasons unrelated to this widget.
      expect(
        find.descendant(
          of: find.byType(Watermark),
          matching: find.byType(Transform),
        ),
        findsNothing,
      );
      // Nothing paints at all, not merely "no rotation".
      expect(
        find.descendant(
          of: find.byType(Watermark),
          matching: find.byType(Text),
        ),
        findsNothing,
      );
    });

    testWidgets('it never intercepts a pointer aimed at the exam', (
      WidgetTester tester,
    ) async {
      // The watermark sits OVER the questions. If it took a tap, every answer
      // on the surface would be unclickable - a far worse bug than a missing
      // watermark.
      await tester.pumpWidget(mount(const Watermark(label: 'Priya Sharma')));

      // Scoped for the same reason as above: Material puts IgnorePointers of
      // its own on the tree, so an unscoped finder proves nothing about this
      // widget.
      expect(
        find.descendant(
          of: find.byType(Watermark),
          matching: find.byType(IgnorePointer),
        ),
        findsWidgets,
      );
    });
  });
}
