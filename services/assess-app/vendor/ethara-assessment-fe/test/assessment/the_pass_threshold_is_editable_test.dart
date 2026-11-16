// Q20: the pass threshold is its own per-assessment setting.
//
// The config page edits it with a stepper like the subjective threshold and
// shows the value the server sends; Settings edits the default a new
// assessment starts with.
library;

import 'dart:convert';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/assessment_detail_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/new_assessment_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/settings_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';
import 'package:ethara_assessment/assessment/widgets/controls.dart';
import 'package:ethara_assessment/assessment/widgets/panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const String kPass = 'Pass threshold (%)';
const String kDefault = 'Default pass threshold (%)';
const String kSubjective = 'Subjective threshold (%)';

/// Serves one API and records every request body by path.
class _Server {
  final Map<String, dynamic> Function(String path) answer;
  final List<MapEntry<String, Map<String, dynamic>>> calls =
      <MapEntry<String, Map<String, dynamic>>>[];

  _Server(this.answer);

  AppStore store() {
    final AppStore s = AppStore(
      api: ApiClient(
        baseUrl: 'http://x',
        client: MockClient((http.Request req) async {
          Map<String, dynamic> body = <String, dynamic>{};
          try {
            body = jsonDecode(req.body) as Map<String, dynamic>;
          } on FormatException {
            // A GET carries no body.
          }
          calls.add(MapEntry<String, Map<String, dynamic>>(req.url.path, body));
          return http.Response(
            jsonEncode(<String, dynamic>{
              'ok': true,
              'data': answer(req.url.path),
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      ),
    );
    s.adoptSession(orgRole: 'admin', name: 'Aarav Mehta', uid: '2');
    return s;
  }

  List<Map<String, dynamic>> bodiesFor(String fragment) =>
      <Map<String, dynamic>>[
        for (final MapEntry<String, Map<String, dynamic>> c in calls)
          if (c.key.contains(fragment)) c.value,
      ];

  Map<String, dynamic> lastBodyFor(String fragment) => calls
      .lastWhere(
        (MapEntry<String, Map<String, dynamic>> c) => c.key.contains(fragment),
      )
      .value;
}

Map<String, dynamic> get _detail => <String, dynamic>{
  'id': '7',
  'name': 'Warehouse safety',
  'state': 'in_progress',
  'duration_minutes': 45,
  'question_limit': 6,
  'total_questions': 6,
  'subjective_threshold': 60.0,
  'pass_threshold': 85.0,
};

void _desktop(WidgetTester t) {
  t.view.physicalSize = const Size(1600, 4000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
}

Finder _field(String label) =>
    find.byWidgetPredicate((Widget w) => w is Field && w.label == label);

NumberField _stepper(WidgetTester t, String label) => t.widget<NumberField>(
  find.descendant(of: _field(label), matching: find.byType(NumberField)),
);

Future<_Server> _openConfig(WidgetTester t) async {
  _desktop(t);
  final _Server server = _Server((String path) => _detail);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: AssessmentNavScope(
          nav: AssessmentNav(),
          child: AssessmentDetailScreen(
            store: server.store(),
            portal: Portal.admin,
            asmId: '7',
          ),
        ),
      ),
    ),
  );
  await t.pump();
  await t.pump(const Duration(milliseconds: 50));
  return server;
}

void main() {
  group('the config page', () {
    testWidgets('the pass threshold shows the payload value, not 70', (
      WidgetTester t,
    ) async {
      await _openConfig(t);

      final NumberField pass = _stepper(t, kPass);
      expect(pass.value, 85);
      expect(pass.min, 1);
      expect(pass.max, 100);
      expect(_stepper(t, kSubjective).value, 60);
    });

    testWidgets('the stepper edits it and sends pass_threshold alone', (
      WidgetTester t,
    ) async {
      final _Server server = await _openConfig(t);

      await t.tap(
        find.descendant(
          of: _field(kPass),
          matching: find.widgetWithText(Btn, '+'),
        ),
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 3300));

      final Map<String, dynamic> body = server.lastBodyFor('/update');
      expect(body['pass_threshold'], 86);
      expect(body.containsKey('subjective_threshold'), isFalse);
    });
  });

  // Every save re-decides every candidate, so a typed threshold saves once,
  // on Enter or leaving the field - never "6" on the way to "65".
  group('typing a threshold on the config page', () {
    const Map<String, String> wire = <String, String>{
      kPass: 'pass_threshold',
      kSubjective: 'subjective_threshold',
    };
    for (final String label in wire.keys) {
      Finder box() =>
          find.descendant(of: _field(label), matching: find.byType(TextField));

      testWidgets('$label: typing 65 saves 65 once, on Enter', (
        WidgetTester t,
      ) async {
        final _Server server = await _openConfig(t);

        await t.enterText(box(), '6');
        await t.enterText(box(), '65');
        await t.pump();
        expect(server.bodiesFor('/update'), isEmpty);

        await t.testTextInput.receiveAction(TextInputAction.done);
        await t.pump();
        await t.pump(const Duration(milliseconds: 3300));

        final List<Map<String, dynamic>> updates = server.bodiesFor('/update');
        expect(updates, hasLength(1));
        expect(updates.single[wire[label]], 65);
      });

      testWidgets('$label: typing 101 saves nothing and says why', (
        WidgetTester t,
      ) async {
        final _Server server = await _openConfig(t);
        final int before = _stepper(t, label).value;

        await t.enterText(box(), '101');
        await t.testTextInput.receiveAction(TextInputAction.done);
        await t.pump();
        await t.pump(const Duration(milliseconds: 3300));

        expect(server.bodiesFor('/update'), isEmpty);
        expect(find.textContaining('101 is not allowed'), findsOneWidget);
        expect(t.widget<TextField>(box()).controller!.text, '$before');

        // Typing again clears the message and keeps the field focused: the
        // "7" of "70" is not saved on its own.
        await t.enterText(box(), '7');
        await t.pump();
        expect(find.textContaining('is not allowed'), findsNothing);
        expect(server.bodiesFor('/update'), isEmpty);
        await t.enterText(box(), '70');
        await t.testTextInput.receiveAction(TextInputAction.done);
        await t.pump();
        await t.pump(const Duration(milliseconds: 3300));
        expect(server.bodiesFor('/update').single[wire[label]], 70);
      });
    }
  });

  group('the New Assessment form', () {
    Future<_Server> open(WidgetTester t, Object? settingsDefault) async {
      _desktop(t);
      final _Server server = _Server(
        (String path) => path.endsWith('/settings')
            ? <String, dynamic>{
                'scoring': <String, dynamic>{
                  'default_pass_threshold': settingsDefault,
                },
              }
            : <String, dynamic>{},
      );
      final AppStore s = server.store();
      await s.reloadSettings();
      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: AssessmentNavScope(
              nav: AssessmentNav(),
              child: NewAssessmentScreen(store: s),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      return server;
    }

    testWidgets('starts at the Settings default and sends the typed value', (
      WidgetTester t,
    ) async {
      final _Server server = await open(t, 83);
      expect(_stepper(t, kPass).value, 83);
      expect(_stepper(t, kPass).min, 1);
      expect(_stepper(t, kPass).max, 100);

      await t.enterText(find.byType(TextField).first, 'Warehouse Safety');
      await t.enterText(
        find.descendant(of: _field(kPass), matching: find.byType(TextField)),
        '55',
      );
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(Btn, 'Save as draft'));
      await t.pumpAndSettle();
      await t.pump(const Duration(seconds: 4));

      expect(server.lastBodyFor('/assessments/create')['pass_threshold'], 55);
    });

    testWidgets('a missing or out-of-range default shows 70', (
      WidgetTester t,
    ) async {
      await open(t, 0);
      expect(_stepper(t, kPass).value, 70);
    });
  });

  group('Settings', () {
    testWidgets('the default pass threshold is shown and saved', (
      WidgetTester t,
    ) async {
      _desktop(t);
      final _Server server = _Server(
        (String path) => path.endsWith('/settings')
            ? <String, dynamic>{
                'scoring': <String, dynamic>{'default_pass_threshold': 80},
              }
            : <String, dynamic>{'updated': <String, dynamic>{}},
      );
      final AppStore s = server.store();
      await s.reloadSettings();
      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(body: SettingsScreen(store: s)),
        ),
      );
      await t.pumpAndSettle();

      final Finder box = find.descendant(
        of: _field(kDefault),
        matching: find.byType(TextField),
      );
      expect(t.widget<TextField>(box).controller!.text, '80');

      await t.enterText(box, '75');
      await t.pumpAndSettle();
      await t.tap(
        find.descendant(
          of: find
              .ancestor(of: _field(kDefault), matching: find.byType(Panel))
              .first,
          matching: find.widgetWithText(Btn, 'Save'),
        ),
      );
      await t.pumpAndSettle();
      await t.pump(const Duration(seconds: 4));

      expect(
        server.lastBodyFor('/settings/update')['default_pass_threshold'],
        75,
      );
    });
  });
}
