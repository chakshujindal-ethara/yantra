// A generator is archived from its own page, and deleted (when Delete is
// shown) from the list's selection bar (Q11).
//
// Pinned here:
//   - the page's Archive sends `archive: true` for that generator, and on an
//     archived one the same button is Restore and sends `archive: false`;
//   - the bar's Delete previews exactly the ticked generators, warns, deletes
//     only after "Delete anyway", and the toast names the generators first and
//     their questions second, in the server's counts.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/generator_detail_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/generator_list_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';
import 'package:ethara_assessment/assessment/widgets/feedback.dart';

http.Response _json(Object data) => http.Response(
  jsonEncode(<String, dynamic>{
    'ok': true,
    'data': data,
    if (data is List)
      'meta': <String, dynamic>{'total': data.length, 'has_more': false},
  }),
  200,
  headers: <String, String>{'content-type': 'application/json'},
);

/// The console's list routes, answered empty so the refresh after an action
/// lands cleanly.
bool _isList(String p) => <String>[
  '/attempts',
  '/tags',
  '/drafts',
  '/responses',
  '/ledger',
  '/forms',
  '/assessments',
  '/bank',
].any(p.endsWith);

void main() {
  group('the generator page', () {
    /// The body of every `/generators/<id>/archive` call, in order.
    late List<Map<String, dynamic>> archives;

    Future<void> open(WidgetTester t, {required bool active}) async {
      archives = <Map<String, dynamic>>[];
      final Map<String, dynamic> row = <String, dynamic>{
        'id': 7,
        'name': 'Forklift SOP',
        'active': active,
      };
      final AppStore store = AppStore(
        api: ApiClient(
          baseUrl: 'http://x',
          client: MockClient((http.Request req) async {
            final String p = req.url.path;
            if (p.endsWith('/generators/7/archive')) {
              archives.add(jsonDecode(req.body) as Map<String, dynamic>);
            }
            if (p.endsWith('/generators')) return _json(<dynamic>[row]);
            if (p.endsWith('/generators/7')) return _json(row);
            if (_isList(p)) return _json(<dynamic>[]);
            return _json(<String, dynamic>{});
          }),
        ),
      )..generators = <Generator>[Generator.fromJson(row)];
      t.view.physicalSize = const Size(1600, 2400);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: AssessmentNavScope(
              nav: AssessmentNav(),
              child: GeneratorDetailScreen(store: store, genId: '7'),
            ),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 100));
      await t.pump();
      addTearDown(() async => t.pumpWidget(const SizedBox.shrink()));
    }

    testWidgets('Archive archives this generator', (WidgetTester t) async {
      await open(t, active: true);
      await t.tap(find.text('Archive'));
      await t.pump(const Duration(milliseconds: 100));
      await t.pump();

      expect(archives, <Map<String, dynamic>>[
        <String, dynamic>{'archive': true},
      ]);
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('on an archived generator the same button restores it', (
      WidgetTester t,
    ) async {
      await open(t, active: false);
      expect(find.text('Archive'), findsNothing);
      // The header's own button. The archived banner carries a small Restore
      // of its own, which is a different control.
      await t.tap(
        find.byWidgetPredicate(
          (Widget w) =>
              w is Btn && w.label == 'Restore' && w.size != BtnSize.sm,
        ),
      );
      await t.pump(const Duration(milliseconds: 100));
      await t.pump();

      expect(archives, <Map<String, dynamic>>[
        <String, dynamic>{'archive': false},
      ]);
      await t.pump(const Duration(seconds: 30));
    });
  });

  group('the selection bar, with Delete shown', () {
    setUp(() => showGeneratorDelete = true);
    tearDown(() => showGeneratorDelete = false);

    testWidgets('Delete previews the ticked generators, warns, then deletes '
        'and names generators and questions apart', (WidgetTester t) async {
      /// Every `/generators/delete` body: the preview, then the delete.
      final List<Map<String, dynamic>> deletes = <Map<String, dynamic>>[];
      final AppStore store = AppStore(
        api: ApiClient(
          baseUrl: 'http://x',
          client: MockClient((http.Request req) async {
            final String p = req.url.path;
            if (p.endsWith('/generators/delete')) {
              deletes.add(jsonDecode(req.body) as Map<String, dynamic>);
              // 7 is used by a paper (kept as Deleted), 8 is not (erased).
              return _json(<String, dynamic>{
                'generators': <dynamic>[
                  <String, dynamic>{
                    'id': 7,
                    'name': 'Forklift SOP',
                    'outcome': 'kept',
                    'assessments': <dynamic>[
                      <String, dynamic>{'id': 3, 'name': 'Warehouse Q3'},
                    ],
                  },
                  <String, dynamic>{
                    'id': 8,
                    'name': 'Old SOP',
                    'outcome': 'deleted',
                    'draft_count': 2,
                    'resource_count': 1,
                  },
                ],
                'deleted_question_count': 4,
                'retired_question_count': 3,
              });
            }
            if (p.endsWith('/generators')) {
              return _json(<dynamic>[
                <String, dynamic>{
                  'id': 7,
                  'name': 'Forklift SOP',
                  'active': true,
                },
                <String, dynamic>{'id': 8, 'name': 'Old SOP', 'active': true},
              ]);
            }
            if (_isList(p)) return _json(<dynamic>[]);
            return _json(<String, dynamic>{});
          }),
        ),
      );
      addTearDown(store.dispose);
      await store.refresh();

      t.view.physicalSize = const Size(1600, 2400);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: AssessmentNavScope(
            nav: AssessmentNav(),
            child: Scaffold(
              body: SingleChildScrollView(
                child: GeneratorListScreen(store: store),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();

      // One row at a time: the first tick raises the bar and moves the rows.
      final Finder boxes = find.byType(Checkbox);
      await t.tap(boxes.at(boxes.evaluate().length - 2));
      await t.pumpAndSettle();
      await t.tap(boxes.last);
      await t.pumpAndSettle();
      expect(find.text('2 generators selected'), findsOneWidget);

      await t.tap(find.text('Delete'));
      // Not `pumpAndSettle`: the bar spins while the sheet is open.
      await t.pump();
      await t.pump(const Duration(seconds: 1));

      expect(deletes, hasLength(1));
      expect(deletes.single['preview'], isTrue);
      expect((deletes.single['ids'] as List<dynamic>).toSet(), <String>{
        '7',
        '8',
      });
      expect(find.text('Delete 2 generators?'), findsOneWidget);

      await t.tap(find.text('Delete anyway'));
      await t.pumpAndSettle();

      expect(deletes, hasLength(2));
      expect(deletes.last.containsKey('preview'), isFalse);
      expect(
        store.toaster.items.map((ToastMsg m) => m.message),
        contains(
          '1 generator erased, 1 moved to Deleted with their results kept. '
          '7 questions: 4 erased, 3 moved to Deleted',
        ),
      );
      expect(find.text('2 generators selected'), findsNothing);
      await t.pump(const Duration(seconds: 30));
    });
  });
}
