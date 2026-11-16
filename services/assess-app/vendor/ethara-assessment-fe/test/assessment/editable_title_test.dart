// The shared in-place title editor.
//
// It was private to `generator_detail_screen.dart` and is now used by the
// assessment header too, so its five behaviours are pinned here rather than
// only implied by the generator-rename widget tests. Each one fixes a real
// defect - see the notes in `widgets/editable_title.dart`:
//
//   * commit on blur, because an inline field has no Save button
//   * refuse an empty name (the route answers 422)
//   * refuse an unchanged name (a round trip and a toast to say nothing)
//   * Escape restores, via an ANCESTOR Focus - EditableText does not handle it
//   * `enabled: false` renders a plain label with no affordance, which is what
//     a read-only role gets
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/widgets/editable_title.dart';

Finder _field() => find.byType(TextField);

Future<List<String>> _pump(
  WidgetTester t, {
  String value = 'Original name',
  bool startEditing = false,
  bool enabled = true,
}) async {
  final List<String> committed = <String>[];
  // Tokens resolve off the ambient theme brightness (`PortalTokens.of`), so a
  // plain themed MaterialApp is the whole harness - same as
  // `admin_shell_builds_test.dart`.
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: EditableTitle(
          value: value,
          startEditing: startEditing,
          enabled: enabled,
          onCommit: committed.add,
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
  return committed;
}

void main() {
  testWidgets('a resting title is a label with a rename affordance', (
    WidgetTester t,
  ) async {
    await _pump(t);
    expect(_field(), findsNothing);
    expect(find.text('Original name'), findsOneWidget);
    expect(
      find.byIcon(Icons.edit_outlined),
      findsOneWidget,
      reason: 'a title that silently happens to be editable is one nobody finds',
    );
  });

  testWidgets('tapping it opens an editor seeded and fully selected', (
    WidgetTester t,
  ) async {
    await _pump(t);
    await t.tap(find.byIcon(Icons.edit_outlined));
    await t.pumpAndSettle();

    final TextField f = t.widget<TextField>(_field());
    expect(f.controller?.text, 'Original name');
    expect(
      f.controller?.selection.textInside('Original name'),
      'Original name',
      reason: 'selected, so the first keystroke replaces the old name',
    );
  });

  testWidgets('Enter commits the trimmed name', (WidgetTester t) async {
    final List<String> committed = await _pump(t, startEditing: true);
    await t.enterText(_field(), '  Renamed  ');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pumpAndSettle();

    expect(committed, <String>['Renamed']);
  });

  testWidgets('an empty name is refused, not committed as blank', (
    WidgetTester t,
  ) async {
    // The route answers 422 on a blank name, and a record with no name cannot
    // be picked out of a list - so this must not reach the server at all.
    final List<String> committed = await _pump(t, startEditing: true);
    await t.enterText(_field(), '   ');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pumpAndSettle();

    expect(committed, isEmpty);
    expect(find.text('Original name'), findsOneWidget);
  });

  testWidgets('an unchanged name is not a write', (WidgetTester t) async {
    final List<String> committed = await _pump(t, startEditing: true);
    await t.enterText(_field(), 'Original name');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pumpAndSettle();

    expect(
      committed,
      isEmpty,
      reason: 'it would cost a round trip and a "Saved" toast to say nothing',
    );
  });

  testWidgets('Escape abandons the edit without renaming', (
    WidgetTester t,
  ) async {
    final List<String> committed = await _pump(t, startEditing: true);
    await t.enterText(_field(), 'Half-typed');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();

    expect(committed, isEmpty);
    expect(find.text('Original name'), findsOneWidget);
  });

  testWidgets('a read-only title has no editor and no affordance', (
    WidgetTester t,
  ) async {
    // What a read-only role sees. The label still renders - hiding the name
    // would be worse than not offering to change it.
    await _pump(t, enabled: false);
    expect(find.text('Original name'), findsOneWidget);
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('a read-only title ignores startEditing', (
    WidgetTester t,
  ) async {
    await _pump(t, startEditing: true, enabled: false);
    expect(_field(), findsNothing);
  });
}
