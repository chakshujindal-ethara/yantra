// Editing a template-authored draft shows EVERY axis it keys.
//
// THE DEFECT. The editor seeded from `dims.first` and kept axes 2..n as opaque
// passthrough JSON so a save would not delete them. That was survivable when an
// A/B question had one rating axis. A TEMPLATE-authored question keys one axis
// per question the examiner wrote - "Was the instruction applied?", "Is the
// subject preserved?", "Is the rest of the frame free of collateral damage?" -
// so opening one to review it showed a single Yes/No and silently hid the rest
// of the answer key the human was being asked to approve.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/question_editor.dart';

const List<String> _axes = <String>[
  'Was the instruction applied?',
  'Is the subject preserved?',
  'Is the rest of the frame free of collateral damage?',
];

Question _threeAxisDraft() => Question.fromJson(<String, dynamic>{
      'id': 148,
      'name': 'Task: Verify an object removal',
      'prompt': 'Verify the edit below.',
      'type': 'image_ab',
      'state': 'draft',
      'source_template': <String, dynamic>{
        'id': 16,
        'name': 'Verify a single photo edit',
      },
      'dimensions': <dynamic>[
        for (int i = 0; i < _axes.length; i++)
          <String, dynamic>{
            'id': 'd$i',
            'name': _axes[i],
            'options': <dynamic>[
              <String, dynamic>{
                'id': 'o${i}y',
                'label': 'Yes',
                'is_correct': i != 1,
              },
              <String, dynamic>{
                'id': 'o${i}n',
                'label': 'No',
                'is_correct': i == 1,
              },
            ],
          },
      ],
    });

Future<void> _open(WidgetTester tester, Question q) async {
  tester.view.physicalSize = const Size(1600, 5000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final AppStore store = AppStore();
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Builder(
        builder: (BuildContext context) => Scaffold(
          body: ElevatedButton(
            onPressed: () => showDraftEditor(context, store, q),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('every axis the question keys is on screen',
      (WidgetTester tester) async {
    await _open(tester, _threeAxisDraft());

    for (final String axis in _axes) {
      expect(
        find.widgetWithText(TextField, axis),
        findsOneWidget,
        reason: 'axis "$axis" must be visible and editable, not passthrough',
      );
    }
  });

  testWidgets('each axis brings its own options', (WidgetTester tester) async {
    await _open(tester, _threeAxisDraft());

    // Three axes x Yes/No.
    expect(find.widgetWithText(TextField, 'Yes'), findsNWidgets(3));
    expect(find.widgetWithText(TextField, 'No'), findsNWidgets(3));
  });

  testWidgets('a single-axis question is unchanged', (WidgetTester tester) async {
    // The legacy shape must keep rendering as one plain "Options" block.
    await _open(
      tester,
      Question.fromJson(<String, dynamic>{
        'id': 1,
        'name': 'Compare the two images',
        'type': 'image_ab',
        'state': 'draft',
        'dimensions': <dynamic>[
          <String, dynamic>{
            'id': 'd0',
            'name': 'Answer',
            'options': <dynamic>[
              <String, dynamic>{'id': 'a', 'label': 'Response A', 'is_correct': true},
              <String, dynamic>{'id': 'b', 'label': 'Response B', 'is_correct': false},
            ],
          },
        ],
      }),
    );

    expect(find.text('OPTIONS'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Response A'), findsOneWidget);
  });
}
