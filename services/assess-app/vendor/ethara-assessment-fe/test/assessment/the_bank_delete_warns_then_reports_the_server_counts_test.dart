// The bank's selection-bar Delete (hidden for now, `showQuestionDelete`; the
// flow behind it is kept, so this turns it on).
//
// Pinned here: pressing it asks the server for a PREVIEW of exactly the ticked
// questions, warns with what the server said ("Delete anyway" when some of it
// is in use), deletes only after that, and the toast repeats the server's own
// erased-versus-kept counts.
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
import 'package:ethara_assessment/assessment/widgets/feedback.dart';

Map<String, dynamic> _row(String id, String name) => <String, dynamic>{
  'id': id,
  'name': name,
  'prompt': 'About $name',
  'question_type': 'subjective_rubric',
  'active': true,
};

void main() {
  setUp(() => showQuestionDelete = true);
  tearDown(() => showQuestionDelete = false);

  testWidgets('Delete previews the ticked questions, warns, then deletes and '
      'reports what was erased and what was kept', (WidgetTester t) async {
    /// Every `/bank/delete` body, in order: the preview, then the delete.
    final List<Map<String, dynamic>> deletes = <Map<String, dynamic>>[];
    final AppStore s = AppStore(
      api: ApiClient(
        baseUrl: 'http://x',
        client: MockClient((http.Request req) async {
          final String p = req.url.path;
          Object data = <String, dynamic>{};
          if (p.endsWith('/bank')) {
            data = <dynamic>[_row('1', 'Unused one'), _row('2', 'Sat one')];
          } else if (p.endsWith('/bank/delete')) {
            deletes.add(jsonDecode(req.body) as Map<String, dynamic>);
            // One nothing points at (erased), one a paper uses (kept).
            data = <String, dynamic>{
              'questions': <dynamic>[
                <String, dynamic>{'id': 1, 'answer_count': 0},
                <String, dynamic>{'id': 2, 'answer_count': 5},
              ],
              'assessments': <dynamic>[
                <String, dynamic>{'id': 3, 'name': 'Warehouse Q3'},
              ],
              'deleted_count': 1,
              'retired_count': 1,
            };
          }
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
    addTearDown(s.dispose);
    await s.refresh();

    t.view.physicalSize = const Size(1600, 1400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: AssessmentNavScope(
          nav: AssessmentNav(),
          child: Scaffold(
            body: SingleChildScrollView(child: BankScreen(store: s)),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();

    // One row at a time: the first tick raises the selection bar, which moves
    // the rows down under the second tap.
    final Finder boxes = find.byType(Checkbox);
    await t.tap(boxes.at(boxes.evaluate().length - 2));
    await t.pumpAndSettle();
    await t.tap(boxes.last);
    await t.pumpAndSettle();
    expect(find.text('2 questions selected'), findsOneWidget);

    await t.tap(find.text('Delete'));
    // Not `pumpAndSettle`: the bar spins while the sheet is open, for good.
    await t.pump();
    await t.pump(const Duration(seconds: 1));

    // A preview of exactly the ticked two, and nothing deleted yet.
    expect(deletes, hasLength(1));
    expect(deletes.single['preview'], isTrue);
    expect((deletes.single['ids'] as List<dynamic>).toSet(), <String>{
      '1',
      '2',
    });
    expect(find.text('Delete 2 questions?'), findsOneWidget);

    await t.tap(find.text('Delete anyway'));
    await t.pumpAndSettle();

    expect(deletes, hasLength(2));
    expect(deletes.last.containsKey('preview'), isFalse);
    expect(
      s.toaster.items.map((ToastMsg m) => m.message),
      contains('1 erased, 1 moved to Deleted with their results kept'),
    );
    expect(
      find.text('2 questions selected'),
      findsNothing,
      reason: 'the selection goes with the rows it named',
    );
    await t.pump(const Duration(seconds: 30));
  });
}
