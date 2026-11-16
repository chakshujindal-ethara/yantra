// R8: Edit Draft saves the key the examiner authored, by axis.
//
// THE DEFECT. A draft's editor read the flat `options` / `correct_answer`
// pair, which a template-authored draft does not carry (its key lives on its
// axes). So the sheet opened with no options and Save disabled, and a draft
// that did save sent the flat pair, which has no axes and no `input_kind`. A
// refused save (422) closed the sheet over what had been typed.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';
import 'package:ethara_assessment/assessment/widgets/question_editor.dart';

http.Response _ok(Object data) => http.Response(
  jsonEncode(<String, dynamic>{'ok': true, 'data': data}),
  200,
  headers: <String, String>{'content-type': 'application/json'},
);

http.Response _refused() => http.Response(
  jsonEncode(<String, dynamic>{
    'ok': false,
    'error': <String, dynamic>{
      'code': 'invalid',
      'message': 'Axis "Verdict" takes one correct answer.',
    },
  }),
  422,
  headers: <String, String>{'content-type': 'application/json'},
);

/// A template draft: the key is on its axis, the flat pair is empty.
Question _templateDraft() => Question.fromJson(<String, dynamic>{
  'id': 5,
  'name': 'Was the instruction applied?',
  'question_type': 'mcq',
  'state': 'draft',
  'options': <String>[],
  'dimensions': <dynamic>[
    <String, dynamic>{
      'id': 41,
      'label': 'Q1 Instruction Aligned',
      'input_kind': 'dropdown',
      'options': <dynamic>[
        <String, dynamic>{'id': 411, 'name': 'Yes', 'is_correct': true},
        <String, dynamic>{'id': 412, 'name': 'No', 'is_correct': false},
      ],
    },
  ],
});

/// An A/B draft, which the editor has always saved by axis, so Save is
/// pressable on the old code too.
Question _abDraft() => Question.fromJson(<String, dynamic>{
  'id': 5,
  'name': 'Compare the two images',
  'question_type': 'image_ab',
  'state': 'draft',
  'dimensions': <dynamic>[
    <String, dynamic>{
      'id': 51,
      'label': 'Verdict',
      'options': <dynamic>[
        <String, dynamic>{'id': 511, 'name': 'Response A', 'is_correct': true},
        <String, dynamic>{'id': 512, 'name': 'Response B', 'is_correct': false},
      ],
    },
  ],
});

class _Rig {
  _Rig({bool refuse = false}) {
    store = AppStore(
      api: ApiClient(
        baseUrl: 'http://x',
        client: MockClient((http.Request req) async {
          final String p = req.url.path;
          paths.add(p);
          if (p.endsWith('/update')) {
            updates.add(jsonDecode(req.body) as Map<String, dynamic>);
            return refuse ? _refused() : _ok(<String, dynamic>{'id': 5});
          }
          if (p.endsWith('/drafts/5') || p.endsWith('/bank/5')) {
            return _ok(<String, dynamic>{'id': 5, 'name': 'Q5'});
          }
          return _ok(<dynamic>[]);
        }),
      ),
    );
    addTearDown(store.dispose);
  }

  late final AppStore store;
  final List<String> paths = <String>[];
  final List<Map<String, dynamic>> updates = <Map<String, dynamic>>[];
}

Future<void> _open(
  WidgetTester tester,
  AppStore store,
  Question q, {
  bool bank = false,
}) async {
  tester.view.physicalSize = const Size(1600, 5000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Builder(
        builder: (BuildContext context) => Scaffold(
          body: ElevatedButton(
            onPressed: () => bank
                ? showBankEditor(context, store, q)
                : showDraftEditor(context, store, q),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump(const Duration(milliseconds: 400));
}

Btn _save(WidgetTester tester) => tester.widget<Btn>(
  find.byWidgetPredicate((Widget w) => w is Btn && w.label == 'Save'),
);

Future<void> _pressSave(WidgetTester tester) async {
  await tester.tap(find.text('Save'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('a template draft shows its axis and can be saved', (
    WidgetTester tester,
  ) async {
    final _Rig rig = _Rig();
    await _open(tester, rig.store, _templateDraft());

    expect(find.widgetWithText(TextField, 'Yes'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'No'), findsOneWidget);
    expect(
      _save(tester).onPressed,
      isNotNull,
      reason: 'the key is on the axis; the empty flat pair is not the key',
    );
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('saving sends the axis tree with ids and kinds, never the pair', (
    WidgetTester tester,
  ) async {
    final _Rig rig = _Rig();
    await _open(tester, rig.store, _templateDraft());
    await _pressSave(tester);

    final Map<String, dynamic> body = rig.updates.single;
    expect(body.containsKey('options'), isFalse);
    expect(body.containsKey('correct_answer'), isFalse);
    final List<dynamic> dims = body['dimensions'] as List<dynamic>;
    final Map<String, dynamic> axis = dims.single as Map<String, dynamic>;
    expect(axis['id'], '41');
    expect(axis['input_kind'], 'dropdown');
    expect(
      (axis['options'] as List<dynamic>).map(
        (dynamic o) => (o as Map<String, dynamic>)['id'],
      ),
      <String>['411', '412'],
    );
    expect(find.text('Edit Draft'), findsNothing, reason: 'saved, so closed');
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets(
    'a draft with only the flat pair sends new options, not text ids',
    (WidgetTester tester) async {
      // An older payload: no `dimensions`, so `Question.fromJson` makes one
      // axis whose option ids are their TEXT. Those must not reach the server as
      // ids.
      final _Rig rig = _Rig();
      await _open(
        tester,
        rig.store,
        Question.fromJson(<String, dynamic>{
          'id': 5,
          'name': 'Pick one',
          'question_type': 'mcq',
          'state': 'draft',
          'options': <String>['Alpha', 'Beta'],
          'correct_answer': 'Alpha',
        }),
      );
      await _pressSave(tester);

      final Map<String, dynamic> axis =
          (rig.updates.single['dimensions'] as List<dynamic>).single
              as Map<String, dynamic>;
      expect(axis.containsKey('id'), isFalse);
      expect(axis['options'], <Map<String, dynamic>>[
        <String, dynamic>{'name': 'Alpha', 'is_correct': true},
        <String, dynamic>{'name': 'Beta', 'is_correct': false},
      ]);
      await tester.pump(const Duration(seconds: 30));
    },
  );

  testWidgets('a refused save keeps the sheet open over what was typed', (
    WidgetTester tester,
  ) async {
    final _Rig rig = _Rig(refuse: true);
    await _open(tester, rig.store, _abDraft());
    await tester.enterText(
      find.widgetWithText(TextField, 'Compare the two images'),
      'Compare the two renders',
    );
    await _pressSave(tester);

    expect(rig.updates, hasLength(1));
    expect(find.text('Edit Draft'), findsOneWidget);
    expect(
      find.widgetWithText(TextField, 'Compare the two renders'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('a bank save re-reads the question', (WidgetTester tester) async {
    final _Rig rig = _Rig();
    await _open(tester, rig.store, _abDraft(), bank: true);
    await _pressSave(tester);

    expect(rig.paths, contains('/api/v1/bank/5'));
    expect(find.text('Edit Question'), findsNothing);
    await tester.pump(const Duration(seconds: 30));
  });
}
