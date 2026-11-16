// Panel header: the actions belong on the right edge.
//
// THE BUG THIS EXISTS FOR: the header was `Flexible(title) + Flexible(note) +
// Spacer() + actions`. Flexible and Spacer are BOTH flex children, so they
// divided the free width rather than the Spacer taking all of it - on a wide
// panel with a short title the actions landed near the CENTRE. Reported from
// the answer review, where the Correct / Passed / Failed pill floated mid-card
// instead of lining up down the right edge.
library;

import 'package:ethara_assessment/assessment/widgets/panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('head actions sit on the right edge whatever the title says', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light(),
        home: Scaffold(
          body: SizedBox(
            width: 1400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: const <Widget>[
                Panel(
                  title: 'Question 1',
                  headActions: <Widget>[Icon(Icons.check, key: Key('a'))],
                  child: Text('one'),
                ),
                Panel(
                  title: 'Question 14 with a considerably longer heading',
                  headActions: <Widget>[Icon(Icons.check, key: Key('b'))],
                  child: Text('two'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final double a = tester.getRect(find.byKey(const Key('a'))).right;
    final double b = tester.getRect(find.byKey(const Key('b'))).right;
    final double panelRight = tester.getRect(find.byType(Panel).first).right;

    expect(
      a,
      moreOrLessEquals(b, epsilon: 0.5),
      reason: 'a short title must not pull the actions toward the centre',
    );
    expect(
      panelRight - a,
      lessThan(20),
      reason: 'the actions belong against the right edge, not floating',
    );
  });
}
