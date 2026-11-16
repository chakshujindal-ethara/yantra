// The four audit findings: false "not found", route-blind skeleton, nested
// tickers, and a chatter count that understated a paged history.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/chatter.dart';
import 'package:ethara_assessment/assessment/widgets/skeleton.dart';

/// Holds the response open so a test can observe the in-flight window.
class Gate {
  final List<String> paths = <String>[];
  Completer<void>? hold;
}

http.Client slowServer(Gate g, Map<String, dynamic> record) =>
    MockClient((http.Request req) async {
      g.paths.add(req.url.path);
      final Completer<void>? h = g.hold;
      if (h != null) await h.future;
      return http.Response(
        jsonEncode(<String, dynamic>{'ok': true, 'data': record}),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });

void main() {
  group('a fetch in flight is not "not found"', () {
    test('isHydrating is true only while the request is open', () async {
      final Gate g = Gate()..hold = Completer<void>();
      final AppStore s = AppStore(
        api: ApiClient(
          client: slowServer(g, <String, dynamic>{'id': '5', 'name': 'A'}),
          baseUrl: 'http://x',
        ),
      );

      expect(s.isHydrating('assessment', '5'), isFalse);

      final Future<void> f = s.loadAssessment('5');
      expect(
        s.isHydrating('assessment', '5'),
        isTrue,
        reason: 'the screen needs this to avoid claiming a deletion',
      );

      g.hold!.complete();
      await f;

      expect(s.isHydrating('assessment', '5'), isFalse);
      expect(s.asmById('5'), isNotNull);
    });

    test('a FAILED fetch also clears the flag', () async {
      // Otherwise the screen shows a skeleton forever, which is worse than the
      // wrong message it replaced.
      final AppStore s = AppStore(
        api: ApiClient(
          client: MockClient(
            (http.Request _) async => throw http.ClientException('down'),
          ),
          baseUrl: 'http://x',
        ),
      );

      await s.loadAssessment('9');

      expect(s.isHydrating('assessment', '9'), isFalse);
    });

    test('loadAttempt exists and hydrates', () async {
      // The attempt screen had NO fetch at all, so a refresh there always
      // claimed the record was removed.
      final Gate g = Gate();
      final AppStore s = AppStore(
        api: ApiClient(
          client: slowServer(g, <String, dynamic>{
            'id': '4',
            'assessment_id': '18',
            'employee_id': 'e1',
            'state': 'submitted',
          }),
          baseUrl: 'http://x',
        ),
      );

      await s.loadAttempt('4');

      expect(s.attemptById('4'), isNotNull);
      // TWO calls, not one: the attempt, then the assessment it needs for the
      // question list and marking scheme.
      expect(g.paths.any((String p) => p.contains('/attempts/4')), isTrue);
    });
  });

  group('skeleton tickers', () {
    testWidgets('a nested SkeletonTheme reuses the ancestor ticker', (
      WidgetTester tester,
    ) async {
      // The file's rule is one controller per screen. Nesting opened three, so
      // any block mounted later drifted out of phase and read as a fault.
      //
      // COUNTS SCOPES, not opacity: sibling controllers all start at t=0, so
      // every block shows the same opacity whether there is one ticker or
      // three. Only the number of _SkeletonScope elements distinguishes them.
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: ListScreenSkeleton())),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        tester.widgetList<SkeletonTheme>(find.byType(SkeletonTheme)).length,
        greaterThan(1),
        reason: 'the composite really does nest themes',
      );

      // One scope means one animation shared by every nested theme.
      final Iterable<InheritedWidget> scopes = tester
          .widgetList<InheritedWidget>(
            find.byWidgetPredicate(
              (Widget w) => w.runtimeType.toString() == '_SkeletonScope',
            ),
          );
      expect(
        scopes.length,
        1,
        reason: 'a nested theme must NOT publish a second animation',
      );

      // ...and they pulse together.
      final Iterable<Opacity> ops = tester.widgetList<Opacity>(
        find.byType(Opacity),
      );
      expect(ops.map((Opacity o) => o.opacity).toSet().length, 1);
    });

    testWidgets('the detail skeleton is not the list skeleton', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: DetailScreenSkeleton()),
          ),
        ),
      );
      await tester.pump();

      // No KPI strip: a detail page never becomes that shape.
      expect(find.byType(KpiStripSkeleton), findsNothing);
      expect(find.byType(Skeleton), findsWidgets);
    });
  });

  group('chatter counts the whole history', () {
    testWidgets('a capped page reports "N of TOTAL"', (WidgetTester t) async {
      final AppStore s = AppStore(
        api: ApiClient(
          client: MockClient(
            (http.Request req) async => http.Response(
              jsonEncode(<String, dynamic>{
                'ok': true,
                'data': <dynamic>[
                  for (int i = 0; i < 3; i++)
                    <String, dynamic>{
                      'id': i,
                      'author': 'A',
                      'date': '2026-08-10T00:00:00Z',
                      'subtype': 'Note',
                      'text': 'line $i',
                    },
                ],
                'meta': <String, dynamic>{
                  'total': 112,
                  'limit': 3,
                  'offset': 0,
                  'has_more': true,
                },
              }),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            ),
          ),
          baseUrl: 'http://x',
        ),
      );

      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ChatterPanel(store: s, kind: 'generator', recordId: '1'),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();

      expect(
        find.text('3 of 112 entries'),
        findsOneWidget,
        reason: 'printing "3 entries" understates the record history',
      );
    });
  });
}
