// A-092: every generator row carries its own Delete.
//
// It must be the SAME delete the bulk bar runs - the server's preview first,
// the warning built from it, then `/generators/delete` for that one id - not a
// second path that could skip the warning or disagree with the server about
// whether the generator is erased or kept as Deleted.
//
// Delete is hidden for now (`showGeneratorDelete`); the tests of its flow turn
// it back on. Archive, Restore and the Deleted list stay.
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
import 'package:ethara_assessment/assessment/widgets/data_grid.dart';

http.Response _json(Object data) => http.Response(
  jsonEncode(<String, dynamic>{
    'ok': true,
    'data': data,
    if (data is List)
      'meta': <String, dynamic>{
        'total': data.length,
        'limit': 200,
        'offset': 0,
        'has_more': false,
      },
  }),
  200,
  headers: <String, String>{'content-type': 'application/json'},
);

void main() {
  group('with Delete shown', () {
    setUp(() => showGeneratorDelete = true);
    tearDown(() => showGeneratorDelete = false);

    testWidgets('a row Delete warns with the server preview, then deletes that '
        'one generator through the bulk route', (WidgetTester t) async {
      final List<Map<String, dynamic>> deletes = <Map<String, dynamic>>[];
      final AppStore store = AppStore(
        api: ApiClient(
          client: MockClient((http.Request req) async {
            final String path = req.url.path;
            final Map<String, dynamic> body =
                jsonDecode(req.body) as Map<String, dynamic>;
            if (path.endsWith('/generators/delete')) {
              deletes.add(body);
              // The server's answer for a generator an assessment uses: kept as
              // Deleted, not erased. The sheet has to say THAT, not a generic
              // "deleted".
              return _json(<String, dynamic>{
                'generators': <dynamic>[
                  <String, dynamic>{
                    'id': 7,
                    'name': 'Forklift SOP',
                    'outcome': 'kept',
                    'draft_count': 0,
                    'resource_count': 0,
                    'assessments': <dynamic>[
                      <String, dynamic>{'id': 3, 'name': 'Warehouse Q3'},
                    ],
                  },
                ],
                'generator_count': 1,
                'deleted_count': 0,
                'kept_count': 1,
                'retired_question_count': 4,
                'deleted_question_count': 0,
              });
            }
            if (path.endsWith('/generators')) {
              return _json(<dynamic>[
                <String, dynamic>{
                  'id': 7,
                  'name': 'Forklift SOP',
                  'active': true,
                },
              ]);
            }
            if (path.endsWith('/attempts') ||
                path.endsWith('/tags') ||
                path.endsWith('/drafts') ||
                path.endsWith('/responses') ||
                path.endsWith('/ledger') ||
                path.endsWith('/forms') ||
                path.endsWith('/assessments') ||
                path.endsWith('/bank')) {
              return _json(<dynamic>[]);
            }
            return _json(<String, dynamic>{});
          }),
          baseUrl: 'http://x',
        ),
      );
      await store.refresh();

      t.view.physicalSize = const Size(1600, 2400);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
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

      // No row ticked: this is the row's own control, not the bulk bar.
      await t.tap(find.byTooltip('Delete'));
      await t.pumpAndSettle();

      // Preview first, for this generator alone, and nothing deleted yet.
      expect(deletes, hasLength(1));
      expect(deletes.single['preview'], true);
      expect(deletes.single['ids'], <dynamic>['7']);

      // The warning says what the server said: kept as Deleted, not erased.
      expect(find.text('Delete Forklift SOP?'), findsOneWidget);
      expect(
        find.textContaining('so it moves to Deleted', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.text('Generators moved to Deleted, results kept'),
        findsOneWidget,
      );

      await t.tap(find.text('Delete anyway'));
      await t.pumpAndSettle();

      expect(deletes, hasLength(2));
      expect(deletes.last['ids'], <dynamic>['7']);
      expect(deletes.last.containsKey('preview'), isFalse);

      // Let the outcome toast expire so no timer outlives the test.
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('at 1440px the widest row action - Restore beside Delete - is '
        'on screen, not clipped at the table edge', (WidgetTester t) async {
      final AppStore store = AppStore(
        api: ApiClient(
          client: MockClient((http.Request req) async {
            if (req.url.path.endsWith('/generators')) {
              return _json(<dynamic>[
                <String, dynamic>{'id': 8, 'name': 'Old SOP', 'active': false},
              ]);
            }
            return _json(
              req.url.path.endsWith('/settings')
                  ? <String, dynamic>{}
                  : <dynamic>[],
            );
          }),
          baseUrl: 'http://x',
        ),
      );
      await store.refresh();

      // The content pane of a 1440px window: the 224px nav rail off the left,
      // then the section's 22px gutters (assessment_section.dart).
      t.view.physicalSize = const Size(1440 - 224, 1600);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: AssessmentNavScope(
            nav: AssessmentNav(),
            child: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 18, 22, 48),
                child: GeneratorListScreen(store: store),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('Show archived'));
      await t.pumpAndSettle();

      expect(find.text('Restore'), findsOneWidget);
      final Rect grid = t.getRect(find.byType(DataGrid));
      final Rect delete = t.getRect(find.byTooltip('Delete'));
      // The grid scrolled, and its 28px right-edge fade sat over the icon.
      expect(
        find.descendant(
          of: find.byType(DataGrid),
          matching: find.byType(Scrollbar),
        ),
        findsNothing,
        reason: 'the table must fit the pane, not scroll its last column away',
      );
      expect(delete.right, lessThanOrEqualTo(grid.right));
    });
  });

  testWidgets('Delete is not offered on a row or the selection bar; Archive '
      'still is', (WidgetTester t) async {
    expect(showGeneratorDelete, isFalse);
    final List<String> paths = <String>[];
    final AppStore store = AppStore(
      api: ApiClient(
        client: MockClient((http.Request req) async {
          paths.add(req.url.path);
          if (req.url.path.endsWith('/generators')) {
            return _json(<dynamic>[
              <String, dynamic>{'id': 7, 'name': 'Live SOP', 'active': true},
            ]);
          }
          return _json(
            req.url.path.endsWith('/settings')
                ? <String, dynamic>{}
                : <dynamic>[],
          );
        }),
        baseUrl: 'http://x',
      ),
    );
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
    expect(find.byTooltip('Delete'), findsNothing);
    expect(find.byTooltip('Archive'), findsOneWidget);

    await t.tap(find.byType(Checkbox).last);
    await t.pumpAndSettle();
    expect(find.text('1 generator selected'), findsOneWidget);
    expect(find.text('Delete'), findsNothing);
    expect(find.text('Archive'), findsOneWidget);
    expect(paths.where((String p) => p.contains('/delete')), isEmpty);
  });

  testWidgets('the selection bar archives without deleting, and a deleted '
      'generator shows only under Show deleted', (WidgetTester t) async {
    final List<String> paths = <String>[];
    final AppStore store = AppStore(
      api: ApiClient(
        client: MockClient((http.Request req) async {
          paths.add(req.url.path);
          if (req.url.path.endsWith('/generators')) {
            return _json(<dynamic>[
              <String, dynamic>{'id': 7, 'name': 'Live SOP', 'active': true},
              <String, dynamic>{
                'id': 9,
                'name': 'Gone SOP',
                'active': false,
                'deleted': true,
              },
            ]);
          }
          return _json(
            req.url.path.endsWith('/settings')
                ? <String, dynamic>{}
                : <dynamic>[],
          );
        }),
        baseUrl: 'http://x',
      ),
    );
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
    expect(find.text('Gone SOP'), findsNothing);

    await t.tap(find.byType(Checkbox).last);
    await t.pumpAndSettle();
    await t.tap(find.text('Archive'));
    await t.pumpAndSettle();
    expect(
      paths.where((String p) => p.endsWith('/generators/7/archive')),
      hasLength(1),
    );
    expect(paths.where((String p) => p.contains('/delete')), isEmpty);

    await t.tap(find.text('Show archived'));
    await t.pumpAndSettle();
    expect(
      find.text('Gone SOP'),
      findsNothing,
      reason: 'Deleted is out of Archived too, for good',
    );

    await t.tap(find.text('Show deleted'));
    await t.pumpAndSettle();
    expect(find.text('Gone SOP'), findsOneWidget);
    expect(find.text('Restore'), findsNothing);
    expect(find.byTooltip('Delete'), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
    await t.pump(const Duration(seconds: 30));
  });

  group('the generator page', () {
    Future<void> open(WidgetTester t, Map<String, dynamic> row) async {
      final AppStore store = AppStore(
        api: ApiClient(
          client: MockClient((http.Request req) async {
            final String path = req.url.path;
            if (path.endsWith('/generators')) return _json(<dynamic>[row]);
            if (path.endsWith('/generators/${row['id']}')) return _json(row);
            return _json(<String, dynamic>{});
          }),
          baseUrl: 'http://x',
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
              child: GeneratorDetailScreen(store: store, genId: '${row['id']}'),
            ),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 100));
      await t.pump();
      addTearDown(() async => t.pumpWidget(const SizedBox.shrink()));
    }

    testWidgets('offers Archive but not Delete', (WidgetTester t) async {
      expect(showGeneratorDelete, isFalse);
      await open(t, <String, dynamic>{
        'id': 7,
        'name': 'Live SOP',
        'active': true,
      });
      expect(find.text('Archive'), findsOneWidget);
      expect(find.text('Delete'), findsNothing);
    });

    testWidgets('offers Delete again when it is shown', (WidgetTester t) async {
      showGeneratorDelete = true;
      addTearDown(() => showGeneratorDelete = false);
      await open(t, <String, dynamic>{
        'id': 7,
        'name': 'Live SOP',
        'active': true,
      });
      expect(find.text('Delete'), findsOneWidget);
    });

    testWidgets('a deleted generator says so and offers no way back', (
      WidgetTester t,
    ) async {
      showGeneratorDelete = true;
      addTearDown(() => showGeneratorDelete = false);
      await open(t, <String, dynamic>{
        'id': 9,
        'name': 'Gone SOP',
        'active': false,
        'deleted': true,
      });
      expect(
        find.textContaining('This generator is deleted.', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('This generator is archived.', findRichText: true),
        findsNothing,
      );
      expect(find.text('Restore'), findsNothing);
      expect(find.text('Archive'), findsNothing);
      expect(find.text('Delete'), findsNothing);
      expect(find.text('Generate questions'), findsNothing);
    });
  });
}
