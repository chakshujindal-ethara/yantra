// An archived question comes back through Restore, from the bank row or from
// its editor - and a deleted one never does (Q11).
//
// Pinned here:
//   - the archived row's Restore calls `bank/<id>/restore`, never archive or
//     delete, and drops the row from a selection the operator had ticked;
//   - the editor of an archived question states "Archived" with a Restore in
//     place of the circulation switch, and once restored shows the switch;
//   - the editor of a deleted question states "Deleted for good" with no
//     Restore, because the server refuses one.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/bank_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/question_editor.dart';

/// The bank row's Restore, found by its tooltip: on the archived side the
/// selection bar also offers a "Restore", and that one is a different call.
const String _kRowRestore =
    'Put this question back in the bank so new assessments can draw it again. '
    'The assessments already built with it never lost it.';

class _Rig {
  _Rig({this.deleted = false});

  final bool deleted;

  /// Flipped by the restore route, so the re-read after it sees the change.
  bool retired = true;

  final List<String> paths = <String>[];

  late final AppStore store = AppStore(
    api: ApiClient(
      baseUrl: 'http://x',
      client: MockClient((http.Request req) async {
        final String p = req.url.path;
        paths.add(p);
        if (p.endsWith('/restore')) retired = false;
        final Object data = p.endsWith('/bank')
            ? <dynamic>[
                <String, dynamic>{
                  'id': '2',
                  'name': 'Archived one',
                  'prompt': 'About it',
                  'question_type': 'subjective_rubric',
                  'active': true,
                  'retired': retired,
                  'deleted': deleted,
                },
              ]
            : <String, dynamic>{};
        return http.Response(
          jsonEncode(<String, dynamic>{
            'ok': true,
            'data': data,
            if (data is List)
              'meta': <String, dynamic>{
                'total': data.length,
                'has_more': false,
              },
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    ),
  );

  Iterable<String> hits(String suffix) =>
      paths.where((String p) => p.endsWith(suffix));
}

Future<void> _wide(WidgetTester t) async {
  t.view.physicalSize = const Size(1600, 1400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
}

/// Opens the bank editor on the rig's one question.
Future<void> _openEditor(WidgetTester t, _Rig r) async {
  await _wide(t);
  await r.store.refresh();
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: Builder(
          builder: (BuildContext c) => TextButton(
            onPressed: () => showBankEditor(c, r.store, r.store.bank.first),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
}

void main() {
  testWidgets("the archived row's Restore restores it and unticks it", (
    WidgetTester t,
  ) async {
    final _Rig r = _Rig();
    addTearDown(r.store.dispose);
    await _wide(t);
    await r.store.refresh();
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: AssessmentNavScope(
          nav: AssessmentNav(),
          child: Scaffold(
            body: SingleChildScrollView(child: BankScreen(store: r.store)),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('Show archived'));
    await t.pumpAndSettle();
    await t.tap(find.byType(Checkbox).last);
    await t.pumpAndSettle();
    expect(find.text('1 question selected'), findsOneWidget);

    await t.tap(find.byTooltip(_kRowRestore));
    await t.pumpAndSettle();

    expect(r.hits('/bank/2/restore'), hasLength(1));
    expect(r.hits('/bank/archive'), isEmpty);
    expect(r.hits('/bank/delete'), isEmpty);
    expect(
      find.text('1 question selected'),
      findsNothing,
      reason: 'a bulk action pressed next would act on the row just restored',
    );
    await t.pump(const Duration(seconds: 30));
  });

  testWidgets('the editor of an archived question offers Restore, then the '
      'circulation switch once it is back', (WidgetTester t) async {
    final _Rig r = _Rig();
    addTearDown(r.store.dispose);
    await _openEditor(t, r);

    expect(find.text('CIRCULATION'), findsOneWidget);
    expect(find.text('Archived'), findsOneWidget);
    expect(
      find.textContaining(
        'cannot be drawn into a new assessment until it is '
        'restored',
      ),
      findsOneWidget,
    );
    expect(find.text('In circulation'), findsNothing);

    await t.tap(find.text('Restore'));
    await t.pumpAndSettle();

    expect(r.hits('/bank/2/restore'), hasLength(1));
    expect(find.text('CIRCULATION'), findsNothing);
    expect(find.text('In circulation'), findsOneWidget);
    await t.pump(const Duration(seconds: 30));
  });

  testWidgets(
    'the editor of a deleted question says so and offers no Restore',
    (WidgetTester t) async {
      final _Rig r = _Rig(deleted: true);
      addTearDown(r.store.dispose);
      await _openEditor(t, r);

      expect(find.text('Deleted'), findsOneWidget);
      expect(find.textContaining('Deleted for good.'), findsOneWidget);
      expect(find.text('Archived'), findsNothing);
      expect(find.text('Restore'), findsNothing);
    },
  );
}
