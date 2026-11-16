// The "Edit the markers and golden answers" action must be offered only where it
// can actually work.
//
// FOUND BY ADVERSARIAL REVIEW of the SNo 168 change. The action's guard was
// `q.type == QType.imageLabel && q.state != DraftState.draft`, and `!= draft` is
// not the same as "is a bank question": DraftState also has `denied`.
//
// WHY THAT IS A REAL DEFECT AND NOT A TIDINESS POINT. A draft - denied or not -
// is an `assessments.be.prompt.question`: a DIFFERENT model, with its own id
// sequence. Its id sent to `/api/v1/bank/<id>/studio_item` addresses whatever
// BANK question happens to hold that number. Best case a 404 and a confusing
// toast; worst case the examiner opens, edits and saves the markers of an
// unrelated question. The module already documents this exact hazard for a
// neighbouring route (`serializers.bank_question_row` sends `"state":
// "approved"` explicitly, with a comment about the two id sequences diverging),
// so the fix is an ALLOW-LIST rather than a longer deny-list.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/screens/admin/assessment_detail_screen.dart'
    show showQuestionPreview;
import 'package:ethara_assessment/assessment/state/app_store.dart';

/// A labelling question in [state]. `image_label` is the type the action exists
/// for, so the type is never the reason a case here is refused.
///
/// The RECORD, not the [Question]: the stub server below has to answer the
/// hydration fetch with the same question the sheet was opened on.
Map<String, dynamic> _labelling(String state) => <String, dynamic>{
  'id': '9602',
  'name': 'Mark and name each defect you can see in this output.',
  'question_type': 'image_label',
  'state': state,
  'difficulty': 'medium',
  'prompt': 'Mark and name each defect you can see in this output.',
  'label_boxes': <dynamic>[
    <String, dynamic>{'number': 1, 'box_2d': <int>[100, 100, 200, 200]},
  ],
};

/// A question the action must never be offered for, whatever its state.
Map<String, dynamic> _notLabelling() => <String, dynamic>{
  'id': '9603',
  'name': 'Which action comes first?',
  'question_type': 'mcq',
  'state': 'approved',
  'difficulty': 'easy',
  'prompt': 'Which action comes first?',
};

/// True when the sheet is offering the annotation action.
Future<bool> _offersMarkerEditor(
  WidgetTester t,
  Map<String, dynamic> record,
) async {
  final Question q = Question.fromJson(record);

  t.view.physicalSize = const Size(1600, 1600);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);

  // A STUBBED CLIENT, not a bare live store, because `showQuestionPreview`
  // hydrates BEFORE it opens the sheet and only opens it when that fetch
  // settles. A live store with no client posts to the real world: on the Dart
  // VM that fails in a microtask and the sheet opens anyway, but under
  // `--platform chrome` it is a genuine browser request that the test's fake
  // clock never lets finish - so the sheet never opened, and all four cases
  // died on the harness guard below rather than on the guard under test.
  final AppStore store = AppStore(
    api: ApiClient(
      baseUrl: 'http://x',
      client: MockClient(
        (http.Request _) async => http.Response(
          jsonEncode(<String, dynamic>{'ok': true, 'data': record}),
          200,
          headers: const <String, String>{'content-type': 'application/json'},
        ),
      ),
    ),
  )..source = DataSource.live;
  addTearDown(store.dispose);

  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => showQuestionPreview(context, store, q),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.text('open'));
  await t.pumpAndSettle();

  // Guard the harness: the sheet itself must have opened, or every "not
  // offered" assertion below would pass for the wrong reason.
  expect(find.textContaining(q.name.split(' ').first), findsWidgets,
      reason: 'the preview sheet did not open, so nothing here is under test');

  final bool offered = find
      .byTooltip('Edit the markers and golden answers')
      .evaluate()
      .isNotEmpty;

  // A live-mode store toasts on its own schedule, and a toast schedules a 3.2s
  // dismissal. Left pending it trips the binding's timer check, which reads as a
  // failure of the guard under test rather than of the harness.
  await t.pump(const Duration(seconds: 4));
  return offered;
}

void main() {
  testWidgets('an approved labelling question offers it', (
    WidgetTester t,
  ) async {
    // The case the feature exists for. If this ever goes false the fix has
    // hidden the feature instead of guarding it, which is the failure mode a
    // tightened guard actually risks.
    expect(await _offersMarkerEditor(t, _labelling('approved')), isTrue);
  });

  testWidgets('a draft does not', (WidgetTester t) async {
    // A draft's markers live on a different model with different fields; its
    // own editor covers the text and the key.
    expect(await _offersMarkerEditor(t, _labelling('draft')), isFalse);
  });

  testWidgets('a DENIED draft does not either', (WidgetTester t) async {
    // THE FINDING. `state != draft` admitted this one: still a draft record,
    // still the wrong id sequence, and the action would have addressed an
    // unrelated bank question with it.
    expect(await _offersMarkerEditor(t, _labelling('denied')), isFalse);
  });

  testWidgets('a question of another type does not', (WidgetTester t) async {
    // The editor opens on a plate and edits numbered markers. An MCQ has
    // neither, so the action would open an editor with nothing in it.
    expect(await _offersMarkerEditor(t, _notLabelling()), isFalse);
  });
}
