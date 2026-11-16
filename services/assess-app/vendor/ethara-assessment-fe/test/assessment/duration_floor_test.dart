// Every assessment is timed, and the floor is two minutes.
//
// THE EXPECTATION HERE WAS DELIBERATELY REVERSED. This file used to state the
// rule as "{0} plus [2, max]" and warned that raising `min` to 2 would remove
// the no-limit option. That option is gone on purpose: an untimed sitting
// never gets a deadline, so the server's expiry sweep skipped it and the
// attempt could never be settled. One was launched at 0 and its candidates
// were emailed "Duration: 0 minutes".
//
// WHY THE CONTROL AND NOT JUST THE SERVER. The duration field on the detail
// screen PERSISTS ON EVERY CHANGE. A reachable 0 or 1 would post a value the
// server refuses and answer with a toast for something the operator never
// meant to commit.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/widgets/controls.dart';

Widget host(Widget child) =>
    MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: child));

/// Drives a NumberField the way a person does, holding the value between
/// pumps so the stepper sees the state it just produced.
class _Harness extends StatefulWidget {
  const _Harness({required this.initial, this.min = 2});

  final int initial;
  final int min;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late int value = widget.initial;

  @override
  Widget build(BuildContext context) => NumberField(
    value: value,
    min: widget.min,
    max: 600,
    onChanged: (int v) => setState(() => value = v),
  );
}

void main() {
  Future<_HarnessState> pumpField(
    WidgetTester tester,
    int initial, {
    int min = 2,
  }) async {
    await tester.pumpWidget(host(_Harness(initial: initial, min: min)));
    return tester.state<_HarnessState>(find.byType(_Harness));
  }

  testWidgets('the stepper cannot go below the floor', (
    WidgetTester tester,
  ) async {
    final _HarnessState s = await pumpField(tester, 2);

    await tester.tap(find.text('-'));
    await tester.pump();

    expect(s.value, 2, reason: 'two minutes is the floor, not a waypoint');
  });

  testWidgets('typing a value below the floor commits nothing', (
    WidgetTester tester,
  ) async {
    // THE DEFECT THIS PINS. "15" arrives as "1" first. Clamping that up would
    // save a 2-minute exam on a screen that posts as you type; an earlier
    // version escaped downward instead and saved 0, which then meant "no
    // limit" - so a 45-minute exam silently became untimed with no error.
    final _HarnessState s = await pumpField(tester, 45);

    await tester.enterText(find.byType(TextField), '1');
    await tester.pump();
    expect(
      s.value,
      45,
      reason: 'below the floor is a prefix, not an answer',
    );

    await tester.enterText(find.byType(TextField), '15');
    await tester.pump();
    expect(s.value, 15);
  });

  testWidgets('zero can never be reached', (WidgetTester tester) async {
    final _HarnessState s = await pumpField(tester, 2);

    await tester.enterText(find.byType(TextField), '0');
    await tester.pump();

    expect(s.value, isNot(0), reason: 'no assessment is untimed');
  });

  testWidgets('ordinary values are untouched', (WidgetTester tester) async {
    final _HarnessState s = await pumpField(tester, 45);

    await tester.enterText(find.byType(TextField), '30');
    await tester.pump();

    expect(s.value, 30);
  });

  testWidgets('a value above the maximum still clamps', (
    WidgetTester tester,
  ) async {
    final _HarnessState s = await pumpField(tester, 45);

    await tester.enterText(find.byType(TextField), '9999');
    await tester.pump();

    expect(
      s.value,
      600,
      reason: 'there is no prefix reading of a number already too big',
    );
  });

  test('both duration controls carry the floor', () {
    // A source rule, because the widget cannot enforce where it is used and
    // the rule is only real if BOTH screens carry it - the create form and the
    // one that saves on every keystroke.
    for (final String path in <String>[
      'lib/assessment/screens/admin/new_assessment_screen.dart',
      'lib/assessment/screens/admin/assessment_detail_screen.dart',
    ]) {
      final File f = File(path);
      expect(f.existsSync(), isTrue, reason: 'run from the package root');
      final String src = f.readAsStringSync();
      final int at = src.indexOf('Duration (minutes)');
      expect(at, greaterThan(-1), reason: '$path lost its duration field');
      expect(
        src.substring(at, at + 900),
        contains('min: 2'),
        reason: '$path can still produce an assessment under two minutes',
      );
    }
  });
}
