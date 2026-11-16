// The Back / Forward pair, as it is actually mounted.
//
// `history_nav_test.dart` pins the navigator. This pins the half a unit test
// cannot see: that the control is mounted ONCE for the whole section, that it
// is disabled rather than absent at the ends of the trail, that pressing it
// moves the page, and that it stays out of the exam runner - which owns its own
// Previous and Next over questions and moves through the server to do it.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ethara_assessment/assessment/assessment_section.dart';
import 'package:ethara_assessment/assessment/domain/nav_entries.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/dashboard_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/tags_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';
import 'package:ethara_assessment/assessment/widgets/history_bar.dart';

void main() {
  /// The arrow inside the history bar, never one a screen happens to draw.
  ///
  /// The exam runner's own Previous button is an `Icons.arrow_back` too, so an
  /// unscoped finder would match whichever came first and the test would pass
  /// for the wrong reason.
  Finder arrow(IconData icon) => find.descendant(
    of: find.byType(HistoryBar),
    matching: find.byWidgetPredicate(
      (Widget w) => w is IconBtn && w.icon == icon,
    ),
  );

  bool enabled(WidgetTester tester, IconData icon) =>
      tester.widget<IconBtn>(arrow(icon)).onPressed != null;

  /// Pump the section on a desktop-sized surface, with the rail rendered as
  /// plain buttons so a test can drive real navigation through the section's
  /// own `onOpen`.
  Future<AssessmentNav> pumpSection(
    WidgetTester tester, {
    AssessmentEntry entry = AssessmentEntry.console,
    String? examToken,
  }) async {
    // The data grids declare a minWidth of 860, so the default 800x600 test
    // window would overflow every screen and the failure would read as a
    // layout bug rather than a viewport narrower than the app targets.
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final AppStore store = AppStore();
    addTearDown(store.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AssessmentSection(
            store: store,
            entry: entry,
            examToken: examToken,
            sidebarBuilder:
                (
                  BuildContext _,
                  List<NavEntry> entries,
                  String _,
                  void Function(String) onOpen,
                ) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: entries
                      .map(
                        (NavEntry n) => TextButton(
                          key: ValueKey<String>('rail-${n.key}'),
                          onPressed: () => onOpen(n.key),
                          child: Text(n.label),
                        ),
                      )
                      .toList(),
                ),
          ),
        ),
      ),
    );
    await tester.pump();

    // Read from the scope element itself: the section BUILDS the scope, so its
    // own element sits above it and `of(context)` would find nothing.
    return tester
        .widget<AssessmentNavScope>(find.byType(AssessmentNavScope))
        .notifier!;
  }

  group('The pair is mounted once, for the whole section', () {
    testWidgets('exactly one bar, whatever page is showing', (
      WidgetTester tester,
    ) async {
      await pumpSection(tester);
      expect(find.byType(HistoryBar), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('rail-tags')));
      await tester.pumpAndSettle();
      expect(
        find.byType(HistoryBar),
        findsOneWidget,
        reason:
            'a per-screen control would come and go with the page and let '
            'two screens disagree about whether Back exists',
      );
    });
  });

  group('Disabled at the ends, not hidden', () {
    testWidgets('a freshly opened section offers neither direction', (
      WidgetTester tester,
    ) async {
      await pumpSection(tester);

      // Present but dead. A control that appears only once there is somewhere
      // to go is one nobody learns is there, and it shifts the page under the
      // pointer every time it arrives.
      expect(arrow(Icons.arrow_back), findsOneWidget);
      expect(arrow(Icons.arrow_forward), findsOneWidget);
      expect(enabled(tester, Icons.arrow_back), isFalse);
      expect(enabled(tester, Icons.arrow_forward), isFalse);
    });

    testWidgets('Back lights up once there is somewhere to go back to', (
      WidgetTester tester,
    ) async {
      await pumpSection(tester);
      await tester.tap(find.byKey(const ValueKey<String>('rail-tags')));
      await tester.pumpAndSettle();

      expect(enabled(tester, Icons.arrow_back), isTrue);
      expect(enabled(tester, Icons.arrow_forward), isFalse);
    });
  });

  group('Pressing them moves the page', () {
    testWidgets('Back returns, and Forward comes back again', (
      WidgetTester tester,
    ) async {
      final AssessmentNav nav = await pumpSection(tester);
      expect(nav.current, isA<Analytics>());

      await tester.tap(find.byKey(const ValueKey<String>('rail-tags')));
      await tester.pumpAndSettle();
      expect(nav.current, isA<TagsAdmin>());

      await tester.tap(arrow(Icons.arrow_back));
      await tester.pumpAndSettle();
      expect(nav.current, isA<Analytics>());

      expect(enabled(tester, Icons.arrow_forward), isTrue);
      await tester.tap(arrow(Icons.arrow_forward));
      await tester.pumpAndSettle();
      expect(nav.current, isA<TagsAdmin>());
    });

    testWidgets('the SCREEN changes, not just the navigator', (
      WidgetTester tester,
    ) async {
      // EVERY OTHER TEST HERE READS `nav.current`, which is the model. Two
      // browser-history attempts shipped green through this file and were both
      // broken in a real browser, and the reported symptom was exactly the gap
      // between those two things: an arrow that moved the model while the page
      // underneath did not follow.
      //
      // So this one asserts on what is rendered.
      await pumpSection(tester);
      expect(find.byType(DashboardScreen), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('rail-tags')));
      await tester.pumpAndSettle();
      expect(find.byType(TagsScreen), findsOneWidget);
      expect(find.byType(DashboardScreen), findsNothing);

      await tester.tap(arrow(Icons.arrow_back));
      await tester.pumpAndSettle();
      expect(
        find.byType(DashboardScreen),
        findsOneWidget,
        reason: 'Back must repaint the page, not only move the cursor',
      );

      await tester.tap(arrow(Icons.arrow_forward));
      await tester.pumpAndSettle();
      expect(
        find.byType(TagsScreen),
        findsOneWidget,
        reason: 'and so must Forward - this is the reported failure',
      );
    });

    testWidgets('a rail jump after Back abandons the forward branch', (
      WidgetTester tester,
    ) async {
      final AssessmentNav nav = await pumpSection(tester);

      await tester.tap(find.byKey(const ValueKey<String>('rail-tags')));
      await tester.pumpAndSettle();
      await tester.tap(arrow(Icons.arrow_back));
      await tester.pumpAndSettle();
      expect(enabled(tester, Icons.arrow_forward), isTrue);

      await tester.tap(find.byKey(const ValueKey<String>('rail-bank')));
      await tester.pumpAndSettle();

      expect(nav.current, isA<QuestionBank>());
      expect(
        enabled(tester, Icons.arrow_forward),
        isFalse,
        reason: 'what was ahead is no longer a trail anyone walked',
      );
    });
  });

  group('The keyboard reaches them', () {
    /// Press a chord and let the frame settle.
    Future<void> chord(
      WidgetTester tester,
      LogicalKeyboardKey modifier,
      LogicalKeyboardKey key,
    ) async {
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyDownEvent(key);
      await tester.sendKeyUpEvent(key);
      await tester.sendKeyUpEvent(modifier);
      await tester.pumpAndSettle();
    }

    /// Run [body] as though the app were on [platform].
    ///
    /// Reset inside the test rather than in a `tearDown`: the binding verifies
    /// that no foundation debug variable outlived the body, and it does that
    /// check BEFORE tear-downs run, so clearing it there fails every test that
    /// set it.
    Future<void> onPlatform(
      TargetPlatform platform,
      Future<void> Function() body,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        await body();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    testWidgets('Cmd+[ goes back on an Apple platform', (
      WidgetTester tester,
    ) async {
      await onPlatform(TargetPlatform.macOS, () async {
        final AssessmentNav nav = await pumpSection(tester);

        await tester.tap(find.byKey(const ValueKey<String>('rail-tags')));
        await tester.pumpAndSettle();
        expect(nav.current, isA<TagsAdmin>());

        await chord(
          tester,
          LogicalKeyboardKey.meta,
          LogicalKeyboardKey.bracketLeft,
        );
        expect(nav.current, isA<Analytics>());

        await chord(
          tester,
          LogicalKeyboardKey.meta,
          LogicalKeyboardKey.bracketRight,
        );
        expect(nav.current, isA<TagsAdmin>());
      });
    });

    testWidgets('Alt+Arrow goes back off one', (WidgetTester tester) async {
      await onPlatform(TargetPlatform.windows, () async {
        final AssessmentNav nav = await pumpSection(tester);

        await tester.tap(find.byKey(const ValueKey<String>('rail-tags')));
        await tester.pumpAndSettle();

        await chord(
          tester,
          LogicalKeyboardKey.alt,
          LogicalKeyboardKey.arrowLeft,
        );
        expect(nav.current, isA<Analytics>());

        await chord(
          tester,
          LogicalKeyboardKey.alt,
          LogicalKeyboardKey.arrowRight,
        );
        expect(nav.current, isA<TagsAdmin>());
      });
    });

    testWidgets('Alt+Left is left alone on macOS, where it edits text', (
      WidgetTester tester,
    ) async {
      // THE REASON THE BINDINGS ARE PLATFORM-SPLIT AT ALL.
      //
      // On macOS Option+Left is "move one word left" inside a text field, a
      // binding Flutter installs in `DefaultTextEditingShortcuts` at the app
      // root. Anything registered inside the app sits CLOSER to the focused
      // widget than that does, so claiming Alt+Left here would quietly shadow
      // word-navigation across a product whose operators spend the day typing
      // question text and prompts. If this test ever fails, that regression
      // has shipped.
      await onPlatform(TargetPlatform.macOS, () async {
        final AssessmentNav nav = await pumpSection(tester);

        await tester.tap(find.byKey(const ValueKey<String>('rail-tags')));
        await tester.pumpAndSettle();
        expect(nav.current, isA<TagsAdmin>());

        await chord(
          tester,
          LogicalKeyboardKey.alt,
          LogicalKeyboardKey.arrowLeft,
        );
        expect(
          nav.current,
          isA<TagsAdmin>(),
          reason:
              'Alt+Left must not navigate on macOS - it belongs to the caret',
        );
      });
    });
  });

  group('The shortcut respects what is on top', () {
    testWidgets('a dialog over the page swallows the history keys', (
      WidgetTester tester,
    ) async {
      final AssessmentNav nav = await pumpSection(tester);
      await tester.tap(find.byKey(const ValueKey<String>('rail-tags')));
      await tester.pumpAndSettle();
      expect(nav.current, isA<TagsAdmin>());

      // The handler registers with HardwareKeyboard rather than the focus
      // chain, deliberately, so that the shortcut works before the first click.
      // The cost is that it kept firing for things the user was no longer
      // looking at: Cmd+[ inside a "delete this?" dialog moved the page
      // underneath and left the dialog floating over a screen it was not about.
      final BuildContext ctx = tester.element(find.byType(HistoryBar));
      unawaited(showDialog<void>(
        context: ctx,
        builder: (BuildContext _) => const AlertDialog(content: Text('Sure?')),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Sure?'), findsOneWidget);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      expect(
        nav.current,
        isA<TagsAdmin>(),
        reason: 'the page under an open dialog must not move',
      );
    });
  });

  group('The exam runner keeps its own arrows', () {
    // THE ONLY TESTS IN THE SUITE THAT MOUNT THE RUNNER THE WAY THE APP DOES.
    //
    // Every other exam test mounts `ExamScreen` straight as `MaterialApp.home`
    // (`exam_navigation_test.dart:190`), which hands it the screen's height. An
    // invitation link does not arrive that way: it is read at `main.dart:35`
    // and comes through `AssessmentSection` as `examToken`, which used to drop
    // the runner's own `Scaffold` inside the section's `SingleChildScrollView`
    // and throw on an unbounded height. Nothing covered that path, so nothing
    // caught it. These two do.

    testWidgets('an invitation link lays out, with no exception', (
      WidgetTester tester,
    ) async {
      // `pump`, not `pumpAndSettle`: the runner starts its own timers, and
      // settling would wait on a clock this test has no reason to run.
      await pumpSection(tester, examToken: 'tok');

      // `takeException` returns the first error the binding recorded, or null.
      // Before the section learned to hand the runner a bounded box, this was
      // "RenderCustomMultiChildLayoutBox was given an infinite size".
      expect(
        tester.takeException(),
        isNull,
        reason:
            'the runner draws its own Scaffold, so the section must give it a '
            'bounded height rather than its page scroll',
      );
    });


    testWidgets('the keyboard cannot walk a candidate out of a live sitting', (
      WidgetTester tester,
    ) async {
      // THE ESCAPE HATCH, and the reason hiding the arrows is not a guard.
      //
      // The boundary used to be enforced by the navigator: entering an exam
      // cleared the trail, so `canGoBack` was false and this handler moved
      // nothing. Keeping one entry across the boundary made `canGoBack` true
      // again - and this handler registers with `HardwareKeyboard`, so it never
      // saw that the pair was hidden. Alt+Left mid-paper left the sitting.
      // NAVIGATED INTO, not deep-linked. A deep link seeds the section with
      // `replaceRoot`, leaving a one-entry trail where `canGoBack` is already
      // false - so the first version of this test passed with the guard removed
      // and proved nothing. The hatch exists only when the runner is opened
      // FROM a page, which is how an operator previews and how a candidate
      // starts from their list.
      final AssessmentNav nav = await pumpSection(tester);
      nav.exam('tok');
      await tester.pumpAndSettle();
      expect(nav.current, isA<Exam>());
      expect(nav.canGoBack, isTrue, reason: 'the page behind it is the hatch');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      expect(
        nav.current,
        isA<Exam>(),
        reason: 'the runner owns its own Previous and Next; page history must '
            'not offer a way out of a paper that is being sat',
      );
    });

    testWidgets('no history bar over a live attempt', (
      WidgetTester tester,
    ) async {
      await pumpSection(tester, examToken: 'tok');

      expect(
        find.byType(HistoryBar),
        findsNothing,
        reason:
            'two pairs of arrows on one screen, one of them permanently '
            'disabled because the exam is a history boundary, is worse than '
            'none - and the exam pair moves through the server',
      );
    });
  });
}
