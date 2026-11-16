// A side-by-side comparison whose axes name no side (Yes/No checks on a tagged
// frame and a reference) shows a LEFT and a RIGHT image, never "Response A /
// Response B" (owner, 2026-09-29, "make it a perfect product"). An A/B
// comparison keeps its captions exactly as before.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/screens/exam/answer_layouts.dart';
import 'package:ethara_assessment/assessment/screens/exam/stimulus.dart';

const List<String> kYesNo = <String>['Yes', 'No', 'Nothing meaningful shown'];
const List<String> kAb = <String>[
  'Response A',
  'Response B',
  'Both Good',
  'Both Bad',
];

List<Asset> _pair() => const <Asset>[
  Asset(id: 'a', label: 'Response A', slot: 'a'),
  Asset(id: 'b', label: 'Response B', slot: 'b'),
];

Future<List<String>> _captions(WidgetTester t, {required bool sideFree}) async {
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 1000,
          // Not a ListView: that builds only what is on screen, and the
          // stacked A/B pair's second plate is below the fold.
          child: SingleChildScrollView(
            child: Column(
              children: mediaPlates(
                _pair(),
                const <Asset>[],
                sideFree: sideFree,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  return t
      .widgetList<StimulusPlate>(find.byType(StimulusPlate))
      .map((StimulusPlate p) => p.caption)
      .toList();
}

void main() {
  test('Yes/No axes are side-free; A/B axes are not', () {
    expect(abIsSideFree(QType.imageAb, kYesNo), isTrue);
    expect(abIsSideFree(QType.imageAb, kAb), isFalse);
    expect(abIsSideFree(QType.imageAb, const <String>[]), isFalse,
        reason: 'no options is no evidence: stay the ordinary A/B pair');
    expect(abIsSideFree(QType.mcq, kYesNo), isFalse);
  });

  test('a side label gives way to the position; any other label is kept', () {
    expect(sideFreeCaption('Response A', 0), 'Left image');
    expect(sideFreeCaption('Response B', 1), 'Right image');
    expect(sideFreeCaption('', 1), 'Right image');
    expect(sideFreeCaption('Reference image', 1), 'Reference image');
  });

  testWidgets('a Yes/No pair is captioned Left / Right', (WidgetTester t) async {
    final List<String> captions = await _captions(t, sideFree: true);
    expect(captions, <String>['Left image', 'Right image']);
  });

  testWidgets('an A/B pair keeps Response A / Response B', (
    WidgetTester t,
  ) async {
    final List<String> captions = await _captions(t, sideFree: false);
    expect(captions, <String>['Response A', 'Response B']);
  });
}
