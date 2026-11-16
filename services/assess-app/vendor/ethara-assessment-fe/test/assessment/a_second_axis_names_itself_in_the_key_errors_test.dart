// A key error on axis two says WHICH axis, and axis two edits like axis one.
//
// A template-authored question keys one axis per examiner question. With
// several axes, "needs at least two options" or "nothing is marked correct"
// does not say where to look, so the editor names the axis. Axis two also has
// its own "Add Option", and a row left blank there is not saved as an option
// with no text.
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

const String _second = 'Is the subject preserved?';

Map<String, dynamic> _opt(int id, String name, bool correct) =>
    <String, dynamic>{'id': id, 'name': name, 'is_correct': correct};

/// A two-axis mcq draft; [second] is axis two's option list.
Question _draft(List<Map<String, dynamic>> second) =>
    Question.fromJson(<String, dynamic>{
      'id': 5,
      'name': 'Verify an object removal',
      'question_type': 'mcq',
      'state': 'draft',
      'dimensions': <dynamic>[
        <String, dynamic>{
          'id': 41,
          'label': 'Was the instruction applied?',
          'options': <dynamic>[
            _opt(411, 'Applied', true),
            _opt(412, 'Not applied', false),
          ],
        },
        <String, dynamic>{'id': 42, 'label': _second, 'options': second},
      ],
    });

http.Response _ok(Object data) => http.Response(
  jsonEncode(<String, dynamic>{'ok': true, 'data': data}),
  200,
  headers: <String, String>{'content-type': 'application/json'},
);

/// A store whose every draft update lands in [updates].
AppStore _store(List<Map<String, dynamic>> updates) {
  final AppStore s = AppStore(
    api: ApiClient(
      baseUrl: 'http://x',
      client: MockClient((http.Request req) async {
        final String p = req.url.path;
        if (p.endsWith('/update')) {
          updates.add(jsonDecode(req.body) as Map<String, dynamic>);
          return _ok(<String, dynamic>{'id': 5});
        }
        if (p.endsWith('/drafts/5')) {
          return _ok(<String, dynamic>{'id': 5, 'name': 'Q5'});
        }
        return _ok(<dynamic>[]);
      }),
    ),
  );
  addTearDown(s.dispose);
  return s;
}

Future<void> _open(WidgetTester tester, AppStore store, Question q) async {
  tester.view.physicalSize = const Size(1600, 5000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
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

VoidCallback? _save(WidgetTester tester) => tester
    .widget<Btn>(
      find.byWidgetPredicate((Widget w) => w is Btn && w.label == 'Save'),
    )
    .onPressed;

/// Axis two's "Add Option" - the second one on the sheet, axes in order.
Future<void> _addOnAxisTwo(WidgetTester tester) async {
  await tester.tap(find.text('Add Option').at(1));
  await tester.pump();
}

/// The option field directly after [text] - where a fresh row lands.
Finder _fieldAfter(WidgetTester tester, String text) {
  final List<TextField> fields = tester
      .widgetList<TextField>(find.byType(TextField))
      .toList();
  final int at = fields.indexWhere((TextField f) => f.controller?.text == text);
  return find.byType(TextField).at(at + 1);
}

/// Axis two's saved options as `name/is_correct/id` lines.
List<String> _savedAxisTwo(Map<String, dynamic> body) {
  final List<dynamic> dims = body['dimensions'] as List<dynamic>;
  return <String>[
    for (final dynamic o
        in (dims[1] as Map<String, dynamic>)['options'] as List<dynamic>)
      '${o['name']}/${o['is_correct']}/${o['id'] ?? 'new'}',
  ];
}

Future<void> _pressSave(WidgetTester tester) async {
  await tester.tap(find.text('Save'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('axis two with one option says so by name', (
    WidgetTester tester,
  ) async {
    await _open(
      tester,
      _store(<Map<String, dynamic>>[]),
      _draft(<Map<String, dynamic>>[_opt(421, 'Preserved', true)]),
    );

    expect(
      find.text('Axis "$_second" needs at least two options.'),
      findsOneWidget,
    );
    expect(find.text('A question needs at least two options.'), findsNothing);
    expect(_save(tester), isNull);
  });

  testWidgets('axis two with nothing correct says so by name', (
    WidgetTester tester,
  ) async {
    await _open(
      tester,
      _store(<Map<String, dynamic>>[]),
      _draft(<Map<String, dynamic>>[
        _opt(421, 'Preserved', false),
        _opt(422, 'Not preserved', false),
      ]),
    );

    expect(find.text('Axis "$_second" has nothing marked correct.'), findsOne);
    expect(_save(tester), isNull);
  });

  testWidgets('a one-pick axis two with two correct says so by name', (
    WidgetTester tester,
  ) async {
    await _open(
      tester,
      _store(<Map<String, dynamic>>[]),
      _draft(<Map<String, dynamic>>[
        _opt(421, 'Preserved', true),
        _opt(422, 'Not preserved', true),
      ]),
    );

    expect(
      find.text(
        'Axis "$_second" takes one answer, so only one option can be correct.',
      ),
      findsOneWidget,
    );
    expect(_save(tester), isNull);
  });

  testWidgets('Add Option on axis two adds a row there and saves it', (
    WidgetTester tester,
  ) async {
    final List<Map<String, dynamic>> updates = <Map<String, dynamic>>[];
    await _open(
      tester,
      _store(updates),
      _draft(<Map<String, dynamic>>[_opt(421, 'Preserved', true)]),
    );
    final int before = tester.widgetList(find.byType(TextField)).length;

    await _addOnAxisTwo(tester);

    expect(tester.widgetList(find.byType(TextField)), hasLength(before + 1));
    final Finder fresh = _fieldAfter(tester, 'Preserved');
    expect(tester.widget<TextField>(fresh).controller!.text, isEmpty);

    await tester.enterText(fresh, 'Not preserved');
    await tester.pump();
    expect(find.textContaining('needs at least two options'), findsNothing);
    expect(_save(tester), isNotNull);

    await _pressSave(tester);
    final List<dynamic> dims = updates.single['dimensions'] as List<dynamic>;
    expect(
      ((dims[0] as Map<String, dynamic>)['options'] as List<dynamic>).length,
      2,
      reason: 'the row went to axis two, not axis one',
    );
    expect(_savedAxisTwo(updates.single), <String>[
      'Preserved/true/421',
      'Not preserved/false/new',
    ]);
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('a blank row left on axis two is not saved', (
    WidgetTester tester,
  ) async {
    final List<Map<String, dynamic>> updates = <Map<String, dynamic>>[];
    await _open(
      tester,
      _store(updates),
      _draft(<Map<String, dynamic>>[
        _opt(421, 'Preserved', true),
        _opt(422, 'Not preserved', false),
      ]),
    );

    await _addOnAxisTwo(tester);
    expect(
      tester.widget<TextField>(_fieldAfter(tester, 'Not preserved')).controller!.text,
      isEmpty,
    );
    await _pressSave(tester);

    expect(_savedAxisTwo(updates.single), <String>[
      'Preserved/true/421',
      'Not preserved/false/422',
    ]);
    await tester.pump(const Duration(seconds: 30));
  });
}
