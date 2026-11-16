// The chatter panel: whose history it shows, and what it refuses to send.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/chatter.dart';
import 'package:ethara_assessment/assessment/widgets/controls.dart';

/// Every path the fake server was asked for, in order.
final List<String> calls = <String>[];

/// One entry per record, so a test can tell whose history is on screen.
const Map<String, String> byRecord = <String, String>{
  '1': 'FIRST record line',
  '2': 'SECOND record line',
};

http.Client server() => MockClient((http.Request req) async {
  final String path = req.url.path;
  calls.add(path);
  if (path.contains('/post')) {
    return http.Response(
      jsonEncode(<String, dynamic>{
        'ok': true,
        'data': <String, dynamic>{
          'id': 9,
          'author': 'Administrator',
          'date': '2026-08-10T00:00:00Z',
          'subtype': 'Note',
          'text': 'posted',
        },
      }),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
  }
  final String id = path.split('/').last;
  return http.Response(
    jsonEncode(<String, dynamic>{
      'ok': true,
      'data': <dynamic>[
        <String, dynamic>{
          'id': 1,
          'author': 'A',
          'date': '2026-08-10T00:00:00Z',
          'subtype': 'Note',
          'text': byRecord[id] ?? 'unknown record $id',
        },
      ],
    }),
    200,
    headers: <String, String>{'content-type': 'application/json'},
  );
});

AppStore storeWithApi() => AppStore(
  api: ApiClient(client: server(), baseUrl: 'http://x'),
);

Widget host(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  setUp(calls.clear);

  testWidgets('switching record reloads the history', (WidgetTester t) async {
    // THE BUG: `_load()` ran only in initState. Flutter reuses the element when
    // the widget type and position match, so navigating from one generator to
    // another kept the first record's history on screen under the second
    // record's name.
    final AppStore s = storeWithApi();

    await t.pumpWidget(
      host(ChatterPanel(store: s, kind: 'generator', recordId: '1')),
    );
    await t.pumpAndSettle();
    expect(find.text('FIRST record line'), findsOneWidget);

    await t.pumpWidget(
      host(ChatterPanel(store: s, kind: 'generator', recordId: '2')),
    );
    await t.pumpAndSettle();

    expect(find.text('SECOND record line'), findsOneWidget);
    expect(
      find.text('FIRST record line'),
      findsNothing,
      reason: 'showing the previous record\'s audit trail is the bug',
    );
    expect(
      calls.where((String c) => c.endsWith('/2')).length,
      1,
      reason: 'the new record must actually be fetched',
    );
  });

  testWidgets('the same record does NOT refetch', (WidgetTester t) async {
    final AppStore s = storeWithApi();
    final Widget panel = ChatterPanel(
      store: s,
      kind: 'generator',
      recordId: '1',
    );

    await t.pumpWidget(host(panel));
    await t.pumpAndSettle();
    final int after = calls.length;

    // A parent rebuild is not a reason to hit the server again.
    await t.pumpWidget(
      host(ChatterPanel(store: s, kind: 'generator', recordId: '1')),
    );
    await t.pumpAndSettle();

    expect(calls.length, after, reason: 'a rebuild must not refetch');
  });

  testWidgets('an empty note is refused, and says so', (WidgetTester t) async {
    // It used to return silently: the button swallowed the click and the
    // operator had no idea why nothing happened.
    final AppStore s = storeWithApi();
    await t.pumpWidget(
      MaterialApp(
        home: ToastHost(
          toaster: s.toaster,
          child: Scaffold(
            body: SingleChildScrollView(
              child: ChatterPanel(store: s, kind: 'generator', recordId: '1'),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();

    await t.tap(find.text('Log note'));
    await t.pumpAndSettle();

    expect(
      calls.any((String c) => c.contains('/post')),
      isFalse,
      reason: 'an empty body must not reach the server',
    );
    expect(
      find.textContaining('Write something'),
      findsOneWidget,
      reason: 'a swallowed click reads as a broken button',
    );

    // Let the toast's own 3.2s auto-dismiss timer fire: flutter_test fails a
    // test that ends with a Timer still pending.
    await t.pump(const Duration(seconds: 4));
    await t.pumpAndSettle();
  });

  testWidgets('a note posts and then reloads', (WidgetTester t) async {
    final AppStore s = storeWithApi();
    await t.pumpWidget(
      MaterialApp(
        home: ToastHost(
          toaster: s.toaster,
          child: Scaffold(
            body: SingleChildScrollView(
              child: ChatterPanel(store: s, kind: 'generator', recordId: '1'),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();

    await t.enterText(find.byType(TextField), 'a real note');
    await t.tap(find.text('Log note'));
    await t.pumpAndSettle();

    expect(calls.any((String c) => c.contains('/post')), isTrue);
    // Reloaded, so the line shown is the SERVER's, not one invented locally.
    expect(
      calls.last.endsWith('/1'),
      isTrue,
      reason: 'the panel must re-read after posting',
    );

    await t.pump(const Duration(seconds: 4));
    await t.pumpAndSettle();
  });

  testWidgets('there is ONE verb, and it is the internal note', (
    WidgetTester t,
  ) async {
    // "Send message" posted with mail.mt_comment, which EMAILS every follower.
    // That is a materially different act from writing an internal note, and it
    // sat one keystroke away from it - which is how somebody notifies a
    // candidate by accident.
    final AppStore s = storeWithApi();
    await t.pumpWidget(
      host(ChatterPanel(store: s, kind: 'generator', recordId: '1')),
    );
    await t.pumpAndSettle();

    expect(find.text('Log note'), findsOneWidget);
    expect(
      find.text('Send message'),
      findsNothing,
      reason:
          'the follower-emailing verb must not be one click from an '
          'internal note',
    );
  });

  testWidgets('the newest line is at the BOTTOM', (WidgetTester t) async {
    // The route returns newest-first, which is right for a paged API and wrong
    // for reading. Odoo's chatter runs oldest-first with the newest at the
    // bottom, next to the composer, and that is what a conversation reads like.
    calls.clear();
    final http.Client c = MockClient((http.Request req) async {
      calls.add(req.url.path);
      return http.Response(
        jsonEncode(<String, dynamic>{
          'ok': true,
          // Wire order: newest first.
          'data': <dynamic>[
            <String, dynamic>{
              'id': 2,
              'author': 'A',
              'date': '2026-08-10T10:00:00Z',
              'subtype': 'Note',
              'text': 'NEWEST',
            },
            <String, dynamic>{
              'id': 1,
              'author': 'A',
              'date': '2026-08-10T09:00:00Z',
              'subtype': 'Note',
              'text': 'OLDEST',
            },
          ],
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });
    final AppStore s = AppStore(
      api: ApiClient(client: c, baseUrl: 'http://x'),
    );
    await t.pumpWidget(
      host(ChatterPanel(store: s, kind: 'generator', recordId: '1')),
    );
    await t.pumpAndSettle();

    final double oldest = t.getTopLeft(find.text('OLDEST')).dy;
    final double newest = t.getTopLeft(find.text('NEWEST')).dy;
    expect(
      newest,
      greaterThan(oldest),
      reason:
          'the newest entry must sit below the oldest, as Odoo does - '
          'the wire order is newest-first and was being rendered verbatim',
    );
  });

  testWidgets('Enter logs the note; Shift+Enter does not', (
    WidgetTester t,
  ) async {
    final AppStore s = storeWithApi();
    await t.pumpWidget(
      host(ChatterPanel(store: s, kind: 'generator', recordId: '1')),
    );
    await t.pumpAndSettle();

    await t.enterText(find.byType(TextField).last, 'typed with the keyboard');
    calls.clear();

    // Shift+Enter must fall through to the field as a newline, not post.
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await t.pumpAndSettle();
    expect(
      calls.where((String c) => c.contains('/post')),
      isEmpty,
      reason: 'Shift+Enter is a new line, not a send',
    );

    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pumpAndSettle();
    expect(
      calls.where((String c) => c.contains('/post')),
      isNotEmpty,
      reason: 'Enter must log the note without reaching for the mouse',
    );
    // Let the success toast's auto-dismiss timer expire, or the framework
    // fails the test for a pending timer that is simply the toast doing its
    // job.
    await t.pump(const Duration(seconds: 4));
  });

  testWidgets('an empty search names the text searched for', (
    WidgetTester t,
  ) async {
    // THE BUG: the message was written `\${...}`, so it printed the Dart
    // expression itself rather than what the operator typed.
    final AppStore s = storeWithApi();
    await t.pumpWidget(
      host(ChatterPanel(store: s, kind: 'generator', recordId: '1')),
    );
    await t.pumpAndSettle();

    await t.tap(find.byIcon(Icons.search));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).first, 'zebra');
    await t.pumpAndSettle();

    expect(
      find.text('Nothing in this history matches "zebra".'),
      findsOneWidget,
    );
  });
}
