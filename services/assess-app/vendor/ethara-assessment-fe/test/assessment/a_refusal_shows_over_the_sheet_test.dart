// A refusal shows OVER the sheet that stays open for it.
//
// THE DEFECT. The toast layer sits inside the section content, and every sheet
// is a dialog on the root navigator, so the dialog painted over every toast. A
// save the server refused inside a sheet - Edit Draft's 422, a bank save's 409
// - kept the sheet open "while the toast explains why", and the toast only
// showed after Cancel.
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
import 'package:ethara_assessment/assessment/widgets/controls.dart';
import 'package:ethara_assessment/assessment/widgets/feedback.dart';
import 'package:ethara_assessment/assessment/widgets/question_editor.dart';

const String _refusal = "Axis 'River' takes one answer.";

/// The app's shape: a screen under a [ToastHost], a button that opens a sheet.
Future<void> _mount(
  WidgetTester tester, {
  Toaster? toaster,
  required void Function(BuildContext) open,
  Size size = const Size(1600, 1000),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final Widget screen = Builder(
    builder: (BuildContext context) => Center(
      child: ElevatedButton(
        onPressed: () => open(context),
        child: const Text('open'),
      ),
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: toaster == null
            ? screen
            : ToastHost(toaster: toaster, child: screen),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('a toast fired while a sheet is open paints above it, once', (
    WidgetTester tester,
  ) async {
    final Toaster toaster = Toaster();
    await _mount(
      tester,
      toaster: toaster,
      open: (BuildContext c) =>
          showSheet<void>(c, title: 'Edit Draft', body: const Text('body')),
    );
    toaster.bad(_refusal);
    await _settle(tester);

    expect(find.text('Edit Draft'), findsOneWidget);
    expect(
      find.text(_refusal).hitTestable(),
      findsOneWidget,
      reason: 'the toast must be on top of the sheet, not under its scrim',
    );
    expect(
      find.text(_refusal),
      findsOneWidget,
      reason: "the screen's copy under the scrim would read as a dimmed twin",
    );

    // Closed, the screen's own layer carries it again.
    await tester.tap(find.byTooltip('Close'));
    await _settle(tester);
    await tester.pump(); // the screen's layer hears of it after the frame
    expect(find.text('Edit Draft'), findsNothing);
    expect(find.text(_refusal).hitTestable(), findsOneWidget);
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('a sheet opened from a sheet shows the toast once, on top', (
    WidgetTester tester,
  ) async {
    final Toaster toaster = Toaster();
    await _mount(
      tester,
      toaster: toaster,
      open: (BuildContext c) => showSheet<void>(
        c,
        title: 'Outer',
        body: Builder(
          builder: (BuildContext inner) => TextButton(
            onPressed: () => showSheet<void>(
              inner,
              title: 'Inner',
              body: const Text('inner body'),
            ),
            child: const Text('open inner'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open inner'));
    await _settle(tester);
    toaster.bad(_refusal);
    await _settle(tester);

    expect(find.text('Inner'), findsOneWidget);
    expect(find.text(_refusal).hitTestable(), findsOneWidget);
    expect(find.text(_refusal), findsOneWidget);
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('a sheet with no toast host above it opens unwrapped', (
    WidgetTester tester,
  ) async {
    await _mount(
      tester,
      open: (BuildContext c) =>
          showSheet<void>(c, title: 'Edit Draft', body: const Text('body')),
    );
    expect(find.text('Edit Draft'), findsOneWidget);
    expect(find.byType(ToastLayer), findsNothing);
  });

  testWidgets('a refused draft save shows its message while Edit Draft stays '
      'open', (WidgetTester tester) async {
    final AppStore store = AppStore(
      api: ApiClient(
        baseUrl: 'http://x',
        client: MockClient((http.Request req) async {
          final bool update = req.url.path.endsWith('/update');
          return http.Response(
            jsonEncode(
              update
                  ? <String, dynamic>{
                      'ok': false,
                      'error': <String, dynamic>{
                        'code': 'invalid',
                        'message': _refusal,
                      },
                    }
                  : <String, dynamic>{
                      'ok': true,
                      'data': <String, dynamic>{'id': 5, 'name': 'Q5'},
                    },
            ),
            update ? 422 : 200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      ),
    );
    addTearDown(store.dispose);
    final Question draft = Question.fromJson(<String, dynamic>{
      'id': 5,
      'name': 'Compare the two images',
      'question_type': 'image_ab',
      'state': 'draft',
      'dimensions': <dynamic>[
        <String, dynamic>{
          'id': 51,
          'label': 'River',
          'options': <dynamic>[
            <String, dynamic>{
              'id': 511,
              'name': 'Response A',
              'is_correct': true,
            },
            <String, dynamic>{
              'id': 512,
              'name': 'Response B',
              'is_correct': false,
            },
          ],
        },
      ],
    });
    await _mount(
      tester,
      toaster: store.toaster,
      size: const Size(1600, 5000),
      open: (BuildContext c) => showDraftEditor(c, store, draft),
    );

    await tester.tap(find.text('Save'));
    await _settle(tester);

    expect(find.text('Edit Draft'), findsOneWidget, reason: 'refused, so open');
    expect(find.text(_refusal).hitTestable(), findsOneWidget);
    expect(find.text(_refusal), findsOneWidget);
    await tester.pump(const Duration(seconds: 30));
  });
}
