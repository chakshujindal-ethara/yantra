// "Golden questions and Sample questions are the same thing" (owner,
// 2026-09-29).
//
// WHAT CHANGED. Skills & Templates had its own "Golden examples" uploader:
// text only (.txt/.md), category `golden`, a list separate from the "Sample
// questions" under Generation > Advanced options. It is now the SAME list in
// both tabs: category `sample`, the same file types (PDF, Word, images...),
// the same words. Rows the server still stores as `golden` (before the module
// migrates them) show in that list, and nothing in the app can create a new
// `golden` row.
library;

import 'dart:convert';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/generator_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/services/file_pick_stub.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const String kAttach = 'Attach a sample questions file';

/// A generator row as the server sends it, with tags so the Generation tab is
/// past its "extract the skills first" gate.
Map<String, dynamic> genRow(List<Map<String, dynamic>> resources) =>
    <String, dynamic>{
      'id': 77,
      'name': 'T2I Gen',
      'resource_count': resources.length,
      'tags': const <String>['Domain'],
      'resources': resources,
    };

/// Every visible string and tooltip on screen.
List<String> shownText(WidgetTester t) => <String>[
  for (final RichText w in t.widgetList<RichText>(find.byType(RichText)))
    w.text.toPlainText(),
  for (final Tooltip w in t.widgetList<Tooltip>(find.byType(Tooltip)))
    w.message ?? '',
];

/// [file] as a chip INSIDE the Sample questions list - not merely on screen,
/// where a row mis-parsed as `reference` would sit in Reference files.
Finder inSampleList(String file) => find.descendant(
  of: find
      .ancestor(
        of: find.text('SAMPLE QUESTIONS (OPTIONAL)'),
        matching: find.byType(Column),
      )
      .first,
  matching: find.ancestor(of: find.text(file), matching: find.byType(Chip)),
);

void main() {
  group('the wire', () {
    test("an old 'golden' row parses into the Sample questions list", () {
      expect(ResourceKind.parse('golden'), ResourceKind.sample);
      final Resource r = Resource.fromJson(<String, dynamic>{
        'id': 5,
        'name': 'old-example.md',
        'category': 'golden',
      });
      expect(r.kind, ResourceKind.sample);
      expect(r.kind.label, 'Sample questions');
    });

    test("no kind can be uploaded as 'golden'", () {
      // Uploads send `kind.wire`; with no golden value there is no way to.
      expect(
        ResourceKind.values.map((ResourceKind k) => k.wire),
        isNot(contains('golden')),
      );
    });
  });

  group('the screen', () {
    late AppStore store;
    late List<Map<String, dynamic>> rows;
    late List<Map<String, dynamic>> uploads;
    late List<String> accepts;

    setUp(() {
      rows = <Map<String, dynamic>>[
        <String, dynamic>{'id': 4, 'name': 'sop.pdf', 'category': 'sop'},
        <String, dynamic>{
          'id': 5,
          'name': 'old-example.md',
          'category': 'golden',
        },
      ];
      uploads = <Map<String, dynamic>>[];
      accepts = <String>[];
      GeneratorDetailScreen.pick = ({String accept = ''}) async {
        accepts.add(accept);
        return const PickedFile('paper.pdf', <int>[37, 80, 68, 70]);
      };
      store = AppStore(
        api: ApiClient(
          client: MockClient((http.Request req) async {
            final String p = req.url.path;
            Object? data = <dynamic>[];
            if (p.endsWith('/generators')) {
              data = <dynamic>[genRow(rows)];
            } else if (p.endsWith('/generators/77')) {
              data = genRow(rows);
            } else if (p.endsWith('/generators/77/resources')) {
              final Map<String, dynamic> body =
                  jsonDecode(req.body) as Map<String, dynamic>;
              uploads.add(body);
              final Map<String, dynamic> row = <String, dynamic>{
                'id': 6,
                'name': body['name'],
                'category': body['category'],
              };
              rows.add(row);
              data = <String, dynamic>{'resource': row};
            }
            return http.Response(
              jsonEncode(<String, dynamic>{'ok': true, 'data': data}),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }),
          baseUrl: 'http://x',
        ),
      );
      store.source = DataSource.live;
      store.generators = <Generator>[Generator.fromJson(genRow(rows))];
    });

    tearDown(() => GeneratorDetailScreen.pick = pickFile);

    Future<void> open(WidgetTester t, String tab) async {
      t.view.physicalSize = const Size(1500, 4200);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: AssessmentNavScope(
              nav: AssessmentNav(),
              child: GeneratorDetailScreen(
                store: store,
                genId: '77',
                tab: tab,
              ),
            ),
          ),
        ),
      );
      await t.pump();
      if (tab == 'generation') {
        await t.tap(find.text('Advanced options (optional)'));
        await t.pump();
      }
    }

    Future<void> close(WidgetTester t) async {
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 4));
    }

    testWidgets('Skills & Templates takes any sample file, sent as sample', (
      WidgetTester t,
    ) async {
      await open(t, 'skills');
      expect(find.text('SAMPLE QUESTIONS (OPTIONAL)'), findsOneWidget);

      await t.tap(find.byTooltip(kAttach));
      await t.pump();
      await t.pump();

      expect(accepts, hasLength(1));
      for (final String ext in <String>[
        '.pdf',
        '.docx',
        '.txt',
        '.md',
        '.markdown',
        '.csv',
        '.png',
        '.jpg',
        '.jpeg',
        '.webp',
      ]) {
        expect(accepts.single.split(','), contains(ext), reason: ext);
      }
      expect(uploads, hasLength(1));
      expect(uploads.single['category'], 'sample');
      expect(uploads.single['name'], 'paper.pdf');

      // The re-read landed: the new file is in the list on THIS tab...
      expect(inSampleList('paper.pdf'), findsOneWidget);
      await close(t);

      // ...and on the other one, because both read the one store record.
      await open(t, 'generation');
      expect(inSampleList('paper.pdf'), findsOneWidget);
      expect(inSampleList('old-example.md'), findsOneWidget);
      await close(t);
    });

    testWidgets('Generation > Advanced uploads the same way', (
      WidgetTester t,
    ) async {
      await open(t, 'generation');
      await t.tap(find.byTooltip(kAttach));
      await t.pump();
      await t.pump();

      expect(uploads.single['category'], 'sample');
      await close(t);
    });

    for (final String tab in <String>['skills', 'generation']) {
      testWidgets("an old 'golden' row shows in the Sample list on $tab", (
        WidgetTester t,
      ) async {
        await open(t, tab);
        expect(find.byTooltip(kAttach), findsOneWidget);
        expect(inSampleList('old-example.md'), findsOneWidget);
        await close(t);
      });
    }

    testWidgets("the Resources tab types an old 'golden' row as Sample", (
      WidgetTester t,
    ) async {
      await open(t, 'corpus');
      expect(find.text('old-example.md'), findsOneWidget);
      expect(find.text('Sample questions'), findsOneWidget);
      await close(t);
    });

    for (final String tab in <String>['corpus', 'skills', 'generation']) {
      testWidgets('nothing on $tab offers "Golden" for a new upload', (
        WidgetTester t,
      ) async {
        await open(t, tab);
        // The one allowed mention is the help line naming the old term.
        final List<String> golden = shownText(t)
            .where((String s) => s.toLowerCase().contains('golden'))
            .where((String s) => !s.startsWith('Also called golden questions'))
            .toList();
        expect(golden, isEmpty);
        await close(t);
      });
    }
  });
}
