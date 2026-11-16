// Creating a generator: one click, straight onto the generator's own screen.
//
// Nothing is collected up front. This replaced a sheet that asked for the name,
// and before that a whole page ("Step 1 of 3 - attach the document") that asked
// for the name AND the SOP and then dropped the operator on the corpus tab -
// where the SOP is uploaded anyway. The generator's own screen shows every one
// of those fields and can edit them, so asking first was a form standing in
// front of a form.
//
// Two halves have to hold for that to be an improvement rather than a
// shortcut, and both are asserted here:
//   * the click creates a real record and opens ITS screen, on the corpus tab
//   * the screen opens with the name ready to be typed over, because the name
//     it arrives with is a placeholder nobody chose
//
// A widget test is the only honest check: Flutter web renders to a canvas, so a
// synthetic click in a browser never reaches the handler and a screenshot only
// proves what was already there. `dart analyze` cannot see a dead button -
// `onPressed` is satisfied by any callback.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ethara_assessment/assessment/assessment_section.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/generator_list_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';

/// The whole SECTION, not the list screen alone.
///
/// Creating finishes by navigating, and `context.nav` resolves through an
/// `AssessmentNavScope` that only the section builds - so pumping the screen
/// bare would assert on a create whose second half could not run.
Future<(AppStore, AssessmentNav)> _pumpList(WidgetTester tester) async {
  // A desktop-sized surface. The default test window is 800x600 and this
  // screen's grid declares a minWidth of 1080, so everything would overflow and
  // the failure would read as a layout bug rather than a viewport that is
  // simply narrower than the app targets.
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  // Seed mode - no injected ApiClient - so the screens have fixtures and the
  // test needs no backend. `addGenerator`'s seed branch returns a real id,
  // which is what the navigation is keyed on.
  final AppStore store = AppStore();
  addTearDown(store.dispose);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AssessmentSection(
          store: store,
          entry: AssessmentEntry.generators,
        ),
      ),
    ),
  );
  await tester.pump();

  // Read from the scope element itself, not from AssessmentSection: the section
  // BUILDS the scope, so its own element sits above it.
  final AssessmentNavScope scope = tester.widget<AssessmentNavScope>(
    find.byType(AssessmentNavScope),
  );
  return (store, scope.notifier!);
}

/// Press the page head's "New generator" and let the navigation land.
///
/// `.first` is the page head's copy, which is present whether or not the list
/// has rows; the grid's empty action is the other.
Future<void> _pressNew(WidgetTester t) async {
  await t.tap(find.widgetWithText(Btn, 'New Generator').first);
  await t.pumpAndSettle();
  // Creating raises a toast, which auto-dismisses on a 3.2s timer. Let it fire,
  // or the binding reports a pending timer once the tree is torn down and the
  // failure reads as if the create had leaked something.
  await t.pump(const Duration(milliseconds: 3300));
  await t.pumpAndSettle();
}

/// The name field, which only exists while the title is being edited.
Finder _nameField() => find.byType(TextField);

void main() {
  group('New generator creates and opens the generator', () {
    testWidgets('one click creates the record and opens its corpus tab', (
      WidgetTester t,
    ) async {
      final (AppStore store, AssessmentNav nav) = await _pumpList(t);
      final int before = store.generators.length;

      await _pressNew(t);

      expect(store.generators.length, before + 1);
      expect(store.generators.first.name, kNewGeneratorName);
      expect(
        store.generators.first.fileCount,
        0,
        reason:
            'the document is attached on the corpus tab, so a freshly '
            'created generator has none - every screen has to read '
            'coherently in that state',
      );

      expect(nav.current, isA<GeneratorDetail>());
      final GeneratorDetail route = nav.current as GeneratorDetail;
      expect(route.id, store.generators.first.id);
      expect(
        route.tab,
        'corpus',
        reason: 'attaching the SOP is the only possible next action',
      );
      expect(
        route.focusName,
        isTrue,
        reason: 'the name it arrives with is a placeholder nobody chose',
      );
    });

    testWidgets('nothing is asked for before the record exists', (
      WidgetTester t,
    ) async {
      await _pumpList(t);
      await _pressNew(t);

      // The words of both things this replaced. If either comes back, a form
      // has been put in front of the screen that already holds these fields.
      expect(find.text('Drop the SOP here'), findsNothing);
      expect(find.widgetWithText(Btn, 'Choose a file'), findsNothing);
      expect(find.widgetWithText(Btn, 'Create generator'), findsNothing);
    });

    testWidgets('the title opens ready to type over', (WidgetTester t) async {
      await _pumpList(t);
      await _pressNew(t);

      expect(
        _nameField(),
        findsOneWidget,
        reason: 'the title is already an open editor, not a label to discover',
      );
      final TextField field = t.widget<TextField>(_nameField());
      expect(field.controller?.text, kNewGeneratorName);
      expect(
        field.controller?.selection.textInside(kNewGeneratorName),
        kNewGeneratorName,
        reason: 'selected, so the first keystroke replaces the placeholder',
      );
    });

    testWidgets('typing a name and pressing Enter renames it', (
      WidgetTester t,
    ) async {
      final (AppStore store, _) = await _pumpList(t);
      await _pressNew(t);

      await t.enterText(_nameField(), 'Forklift SOP v2');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pumpAndSettle();
      await t.pump(const Duration(milliseconds: 3300));
      await t.pumpAndSettle();

      expect(store.generators.first.name, 'Forklift SOP v2');
      expect(
        _nameField(),
        findsNothing,
        reason: 'committing puts the title back to a label',
      );
      expect(find.text('Forklift SOP v2'), findsWidgets);
    });

    testWidgets('Escape puts back the name that was there', (
      WidgetTester t,
    ) async {
      final (AppStore store, _) = await _pumpList(t);
      await _pressNew(t);

      await t.enterText(_nameField(), 'typed then abandoned');
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      await t.pump(const Duration(milliseconds: 3300));
      await t.pumpAndSettle();

      expect(
        store.generators.first.name,
        kNewGeneratorName,
        reason: 'an abandoned edit is not a rename',
      );
      expect(_nameField(), findsNothing);
    });

    testWidgets('there is no separate Rename control any more', (
      WidgetTester t,
    ) async {
      await _pumpList(t);
      await _pressNew(t);
      // Commit the open editor so the head is in its resting state.
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pumpAndSettle();
      await t.pump(const Duration(milliseconds: 3300));
      await t.pumpAndSettle();

      expect(
        find.widgetWithText(Btn, 'Rename'),
        findsNothing,
        reason:
            'the title IS the rename control - two ways to change one field '
            'is the duplication this flow was cut down for',
      );
    });
  });
}
