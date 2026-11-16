// AI proctoring rides on the webcam rule, and a paper the viewer cannot edit
// shows its AI violation pair as words.
//
// [RuleSet.set] takes AI proctoring off with the webcam in the same write,
// because the server refuses AI proctoring alone. A read-only
// [ViolationPolicy] says a 0 threshold in words, and which words depends on
// the action: "First Violation" under Auto-submit, "No Limit" under Log only.

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/widgets/violation_policy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('the webcam carries AI proctoring', () {
    const RuleSet both = RuleSet(<ProctorRule, bool>{
      ProctorRule.webcam: true,
      ProctorRule.aiProctor: true,
    });

    test('webcam off takes AI proctoring off with it', () {
      final RuleSet next = both.set(ProctorRule.webcam, false);
      expect(next[ProctorRule.webcam], isFalse);
      expect(next[ProctorRule.aiProctor], isFalse);
    });

    test('webcam on leaves AI proctoring as it was', () {
      final RuleSet next = const RuleSet(<ProctorRule, bool>{})
          .set(ProctorRule.webcam, true);
      expect(next[ProctorRule.webcam], isTrue);
      expect(next[ProctorRule.aiProctor], isFalse);
    });

    test('AI proctoring off leaves the webcam on', () {
      final RuleSet next = both.set(ProctorRule.aiProctor, false);
      expect(next[ProctorRule.webcam], isTrue);
      expect(next[ProctorRule.aiProctor], isFalse);
    });
  });

  group('a read-only AI pair reads as words', () {
    Future<void> pump(WidgetTester tester, ViolationAction action, int cap) =>
        tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ViolationPolicy(ai: true, action: action, cap: cap),
            ),
          ),
        ));

    testWidgets('0 under Auto-submit is the first violation', (tester) async {
      await pump(tester, ViolationAction.autoSubmit, 0);
      // Field labels render upper-case (panel.dart `Field`).
      expect(find.text('ON AI VIOLATION'), findsOneWidget);
      expect(find.text('AI THRESHOLD'), findsOneWidget);
      expect(find.text(ViolationAction.autoSubmit.label), findsOneWidget);
      expect(find.text('First Violation'), findsOneWidget);
    });

    testWidgets('0 under Log only is no limit', (tester) async {
      await pump(tester, ViolationAction.logOnly, 0);
      expect(find.text('No Limit'), findsOneWidget);
    });

    testWidgets('a set threshold reads as its number', (tester) async {
      await pump(tester, ViolationAction.logOnly, 3);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('No Limit'), findsNothing);
    });
  });
}
