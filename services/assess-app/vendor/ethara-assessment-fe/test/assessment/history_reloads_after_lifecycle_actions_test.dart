// An open History panel re-reads its record when an action lands.
//
// Release, Cancel and Reset each log a line on the assessment server-side, but
// the panel loaded once and never again, so the operator who had just
// cancelled a paper saw no trace of it until they closed and reopened the dock.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/chatter.dart';

void main() {
  testWidgets('Release, Cancel and Reset each reload the open history', (
    WidgetTester t,
  ) async {
    int reads = 0;
    final AppStore s = AppStore(
      api: ApiClient(
        baseUrl: 'http://stub',
        client: MockClient((http.Request req) async {
          final bool history = req.url.path.contains('/chatter/');
          if (history) reads++;
          return http.Response(
            jsonEncode(<String, dynamic>{
              'ok': true,
              'data': history
                  ? <dynamic>[
                      <String, dynamic>{
                        'id': reads,
                        'author': 'Administrator',
                        'date': '2026-09-25T00:00:00Z',
                        'subtype': 'Note',
                        'text': 'line $reads',
                      },
                    ]
                  : <String, dynamic>{},
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      ),
    );
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ChatterPanel(store: s, kind: 'assessment', recordId: '7'),
          ),
        ),
      ),
    );
    await t.pump();
    expect(reads, 1);

    final Assessment asm = Assessment(id: '7', name: 'Warehouse Safety');
    await t.runAsync(() => s.releaseResults(asm));
    await t.pump();
    expect(reads, 2, reason: 'Release must reload the history');

    await t.runAsync(() => s.cancel(asm));
    await t.pump();
    expect(reads, 3, reason: 'Cancel must reload the history');

    await t.runAsync(() => s.resetToDraft(asm));
    await t.pump();
    expect(reads, 4, reason: 'Reset must reload the history');
    expect(find.text('line 4'), findsOneWidget);

    // Past the success toasts' own dismiss timers.
    await t.pump(const Duration(seconds: 4));
  });
}
