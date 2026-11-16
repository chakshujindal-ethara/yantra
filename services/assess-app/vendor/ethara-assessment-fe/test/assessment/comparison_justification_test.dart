// "REQUIRE JUSTIFICATION" IS ONE SWITCH READ IN FOUR PLACES, and this pins the
// two of them that live in Dart.
//
// THE DEFECT IT EXISTS FOR. A candidate sitting a side-by-side comparison was
// always shown a Justification textarea, whatever the examiner authored, and its
// placeholder promised the prose was "marked in its own right". On a comparison
// published with no answer rationale that was false: the backend drops the
// justification mark and skips the judge entirely when `official_reasoning` is
// empty, so the candidate spent exam minutes writing for nobody.
//
// THE SHAPE OF THE FIX. Form Studio gained a "Require justification" switch, and
// publish makes the switch TRUE rather than trusting it - on demands a rationale,
// off discards one - so "a rationale exists" and "the switch was on" are the same
// fact. Everything downstream derives the switch from that: the marks, the judge,
// the candidate's textarea (`requires_justification` on the payload) and the
// submit gate.
//
// WHY BOTH JSON HALVES ARE ASSERTED. `FormItem` is deliberately mutable with no
// `copyWith`, so Duplicate copies an item by round-tripping it through
// `toJson`/`fromJson`. A key present in one half and missing from the other is
// lost silently on duplicate - the examiner's switch quietly resets and the copy
// publishes as verdict-only.
@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/form_models.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/screens/admin/form_item_editor.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

Future<FormItem> _pump(
  WidgetTester tester, {
  void Function(FormItem)? tweak,
}) async {
  tester.view.physicalSize = const Size(1600, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final FormItem item = FormItem(
    'item-1',
    FormItemKind.comparePair,
    title: 'Which render is better?',
    options: <FormOption>[
      FormOption('a', 'A is better', correct: true),
      FormOption('b', 'B is better'),
    ],
  );
  tweak?.call(item);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: FormItemEditor(
            store: AppStore(),
            item: item,
            index: 0,
            onEdit: (VoidCallback mutate) => mutate(),
            onDuplicate: () {},
            onDelete: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return item;
}

void main() {
  group('the designer offers the switch', () {
    testWidgets('a comparison carries a "Require justification" switch', (
      WidgetTester tester,
    ) async {
      await _pump(tester);
      expect(find.text('Require justification'), findsOneWidget);
    });

    testWidgets('a new comparison starts with the switch OFF', (
      WidgetTester tester,
    ) async {
      final FormItem item = await _pump(tester);
      expect(
        item.requireJustification,
        isFalse,
        reason: 'a comparison must default to its scorable shape - verdict only - so '
        'an examiner who never touches the switch cannot publish a question '
        'demanding prose it has no standard for',
      );
    });

    testWidgets('the rationale field is hidden while the switch is OFF', (
      WidgetTester tester,
    ) async {
      await _pump(tester);
      expect(find.textContaining('ANSWER RATIONALE'), findsNothing);
      // And the examiner is told what off MEANS, rather than just seeing a gap.
      expect(find.textContaining('verdict alone'), findsOneWidget);
    });

    testWidgets('turning the switch ON reveals the rationale field', (
      WidgetTester tester,
    ) async {
      await _pump(tester, tweak: (FormItem it) => it.requireJustification = true);
      expect(find.textContaining('ANSWER RATIONALE'), findsOneWidget);
      // The field the server's refusal names must be the field on screen, or
      // the examiner is sent looking for something that is not there.
      expect(find.textContaining('verdict alone'), findsNothing);
    });

    testWidgets('the rationale field shows the text already authored', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        tweak: (FormItem it) => it
          ..requireJustification = true
          ..goldenAnswer = 'A holds detail in the shadows.',
      );
      expect(find.text('A holds detail in the shadows.'), findsOneWidget);
    });
  });

  group('the switch survives a duplicate', () {
    // Duplicate copies an item THROUGH JSON, so a one-sided key is lost.
    FormItem roundTrip(FormItem item) =>
        FormItem.fromJson(item.toJson());

    test('ON round-trips as ON, with its rationale', () {
      final FormItem item = FormItem(
        'item-1',
        FormItemKind.comparePair,
        title: 'Which render?',
      )
        ..requireJustification = true
        ..goldenAnswer = 'A holds detail in the shadows.';

      final FormItem copy = roundTrip(item);
      expect(copy.requireJustification, isTrue);
      expect(copy.goldenAnswer, 'A holds detail in the shadows.');
    });

    test('OFF round-trips as OFF', () {
      final FormItem item = FormItem(
        'item-1',
        FormItemKind.comparePair,
        title: 'Which render?',
      );
      expect(roundTrip(item).requireJustification, isFalse);
    });

    test('the wire key is snake_case, as the publisher reads it', () {
      final FormItem item = FormItem(
        'item-1',
        FormItemKind.comparePair,
        title: 'Which render?',
      )..requireJustification = true;
      // `studio_form.py` reads `require_justification` and tolerates no camel
      // spelling anywhere in that file, so the name is the contract.
      expect(item.toJson()['require_justification'], isTrue);
    });

    test('the key is not emitted for kinds that have no such switch', () {
      final FormItem item = FormItem(
        'item-1',
        FormItemKind.paragraph,
        title: 'Explain the fault.',
      );
      expect(item.toJson().containsKey('require_justification'), isFalse);
    });
  });

  group('the candidate payload carries the answer', () {
    Question parse({bool? requires}) => Question.fromJson(<String, dynamic>{
      'id': 'q-1',
      'name': 'Which render?',
      'prompt': 'Pick the better render.',
      'question_type': 'image_ab',
      'requires_justification': ?requires,
    });

    test('requires_justification true is read off the wire', () {
      expect(parse(requires: true).requiresJustification, isTrue);
    });

    test('requires_justification false is read off the wire', () {
      expect(parse(requires: false).requiresJustification, isFalse);
    });

    test('a payload missing the key asks for no prose', () {
      // An older server, or a question type that never sends it. Defaulting to
      // true would show a box that is worth nothing and block Next on it.
      expect(parse().requiresJustification, isFalse);
    });

    test('the flag survives copyWith and re-serialisation', () {
      final Question q = parse(requires: true);
      expect(q.copyWith(name: 'Renamed').requiresJustification, isTrue);
      expect(
        Question.fromJson(q.toJson()).requiresJustification,
        isTrue,
        reason: 'the cached copy a candidate resumes on must ask for the same thing',
      );
    });
  });
}
