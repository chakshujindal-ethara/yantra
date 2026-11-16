// A transcription clip has its OWN pass bar (15 Oct, R7).
//
// `transcription_threshold`, 0 = follow the subjective bar, so a paper nobody
// touched decides as it always did. The field is offered only where the paper
// has a transcription question, on the Configuration tab and on the create
// form; the create form's subjective default is the server's 70, not 60.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/assessment_detail_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/new_assessment_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';
import 'package:ethara_assessment/assessment/widgets/controls.dart';
import 'package:ethara_assessment/assessment/widgets/panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const String kTranscription = 'Transcription threshold (%)';

/// One API: [detail] on `/assessments/7`, [bank] on `/bank`, one generator,
/// and every request body recorded by path.
class _Server {
  final Map<String, dynamic> detail;
  final List<Map<String, dynamic>> bank;
  final List<MapEntry<String, Map<String, dynamic>>> calls =
      <MapEntry<String, Map<String, dynamic>>>[];

  _Server({
    this.detail = const <String, dynamic>{},
    this.bank = const <Map<String, dynamic>>[],
  });

  AppStore store() {
    final AppStore s = AppStore(
      api: ApiClient(
        baseUrl: 'http://x',
        client: MockClient((http.Request req) async {
          final String p = req.url.path;
          Map<String, dynamic> body = <String, dynamic>{};
          try {
            body = jsonDecode(req.body) as Map<String, dynamic>;
          } on FormatException {
            // A GET carries no body.
          }
          calls.add(MapEntry<String, Map<String, dynamic>>(p, body));
          Object data = detail;
          if (p.endsWith('/bank')) data = bank;
          if (p.endsWith('/generators')) {
            data = <Map<String, dynamic>>[
              <String, dynamic>{'id': 3, 'name': 'SOP alpha', 'active': true},
            ];
          }
          if (p.endsWith('/assessments')) data = <dynamic>[];
          return http.Response(
            jsonEncode(<String, dynamic>{
              'ok': true,
              'data': data,
              if (data is List) 'meta': <String, dynamic>{'total': data.length},
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

  Map<String, dynamic>? lastBodyFor(String fragment) {
    for (final MapEntry<String, Map<String, dynamic>> c in calls.reversed) {
      if (c.key.endsWith(fragment)) return c.value;
    }
    return null;
  }
}

Map<String, dynamic> _question(String type) => <String, dynamic>{
  'id': type == 'transcription' ? 11 : 12,
  'name': 'Q $type',
  'question_type': type,
};

Map<String, dynamic> _detail(List<String> types, {double bar = 0}) =>
    <String, dynamic>{
      'id': '7',
      'name': 'Hindi clips',
      'state': 'in_progress',
      'duration_minutes': 45,
      'question_limit': types.length,
      'total_questions': types.length,
      'subjective_threshold': 70.0,
      'transcription_threshold': bar,
      'questions': <Map<String, dynamic>>[
        for (final String t in types) _question(t),
      ],
    };

Map<String, dynamic> _row(int id, String type) => <String, dynamic>{
  'id': id,
  'name': 'Q$id',
  'question_type': type,
  'difficulty': 'medium',
  'sequence': id,
  'active': true,
  'state': 'approved',
  'generator': <String, dynamic>{'id': 3, 'name': 'SOP alpha'},
  'has_valid_key': true,
  'missing_media_warning': '',
  'servable': true,
};

void _desktop(WidgetTester t) {
  t.view.physicalSize = const Size(1600, 4000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
}

Finder _field(String label) =>
    find.byWidgetPredicate((Widget w) => w is Field && w.label == label);

Future<_Server> _openConfig(WidgetTester t, Map<String, dynamic> detail) async {
  _desktop(t);
  final _Server server = _Server(detail: detail);
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

Future<_Server> _openCreate(WidgetTester t, List<String> types) async {
  _desktop(t);
  final _Server server = _Server(
    bank: <Map<String, dynamic>>[
      for (int i = 0; i < types.length; i++) _row(i + 1, types[i]),
    ],
  );
  final AppStore s = server.store();
  await s.refresh();
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
  await t.enterText(find.byType(TextField).first, 'Hindi clips');
  await t.tap(find.text('Choose a generator'));
  await t.pumpAndSettle();
  await t.tap(find.text('SOP alpha').last);
  await t.pumpAndSettle();
  return server;
}

void main() {
  test('barFor: a set bar for a clip, the subjective bar otherwise', () {
    final Assessment unset = Assessment(
      id: '1',
      name: 'x',
      subjectiveThreshold: 70,
    );
    expect(unset.barFor(QType.transcription), 70, reason: '0 follows');
    final Assessment set = unset.copyWith(transcriptionThreshold: 85);
    expect(set.barFor(QType.transcription), 85);
    expect(
      set.barFor(QType.subjectiveRubric),
      70,
      reason: 'only the clip moves',
    );
  });

  group('the Configuration tab', () {
    testWidgets('offers it only on a paper with a transcription question', (
      WidgetTester t,
    ) async {
      await _openConfig(t, _detail(<String>['subjective_rubric']));
      expect(_field(kTranscription), findsNothing);

      await t.pumpWidget(const SizedBox.shrink());
      await _openConfig(
        t,
        _detail(<String>['subjective_rubric', 'transcription']),
      );
      expect(_field(kTranscription), findsOneWidget);
      expect(
        t.widget<Field>(_field(kTranscription)).help,
        contains('0 follows the subjective threshold'),
      );
    });

    // A draft's `questions` is empty until launch; what it can draw is its
    // `pool`. Reading `questions` alone hid the field on every draft.
    testWidgets('offers it on a DRAFT whose pool has a transcription', (
      WidgetTester t,
    ) async {
      Map<String, dynamic> draft(String type) => <String, dynamic>{
        ..._detail(<String>[]),
        'state': 'draft',
        'pool': <Map<String, dynamic>>[
          <String, dynamic>{..._question('mcq'), 'in_use': true},
          <String, dynamic>{..._question(type), 'in_use': true},
        ],
      };
      await _openConfig(t, draft('subjective_rubric'));
      expect(_field(kTranscription), findsNothing);

      await t.pumpWidget(const SizedBox.shrink());
      await _openConfig(t, draft('transcription'));
      expect(_field(kTranscription), findsOneWidget);
    });

    // After launch `pool` still lists every row the generator could serve,
    // ticks off included, so reading it offered the field on a paper that
    // left its only clip out. Once launched, the drawn paper decides.
    testWidgets('hides it on a LAUNCHED paper that left the clip out', (
      WidgetTester t,
    ) async {
      await _openConfig(t, <String, dynamic>{
        ..._detail(<String>['subjective_rubric']),
        'pool': <Map<String, dynamic>>[
          <String, dynamic>{..._question('subjective_rubric'), 'in_use': true},
          <String, dynamic>{..._question('transcription'), 'in_use': false},
        ],
      });
      expect(_field(kTranscription), findsNothing);
    });

    testWidgets('typing a bar sends transcription_threshold alone, on Enter', (
      WidgetTester t,
    ) async {
      final _Server server = await _openConfig(
        t,
        _detail(<String>['transcription']),
      );

      await t.enterText(
        find.descendant(
          of: _field(kTranscription),
          matching: find.byType(TextField),
        ),
        '85',
      );
      await t.pump();
      expect(server.lastBodyFor('/update'), isNull, reason: 'Enter commits');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pump();
      await t.pump(const Duration(milliseconds: 3300));

      final Map<String, dynamic> body = server.lastBodyFor('/update')!;
      expect(body['transcription_threshold'], 85);
      expect(body.containsKey('subjective_threshold'), isFalse);
    });
  });

  group('the New Assessment form', () {
    testWidgets('shows it only once a transcription question is picked', (
      WidgetTester t,
    ) async {
      await _openCreate(t, <String>['mcq']);
      expect(_field(kTranscription), findsNothing);
    });

    testWidgets('starts the subjective bar at 70 and sends the clip bar', (
      WidgetTester t,
    ) async {
      final _Server server = await _openCreate(t, <String>[
        'mcq',
        'transcription',
      ]);
      expect(_field(kTranscription), findsOneWidget);
      expect(
        t
            .widget<NumberField>(
              find.descendant(
                of: _field('Subjective threshold (%)'),
                matching: find.byType(NumberField),
              ),
            )
            .value,
        70,
      );

      await t.enterText(
        find.descendant(
          of: _field(kTranscription),
          matching: find.byType(TextField),
        ),
        '90',
      );
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(Btn, 'Create draft'));
      await t.pumpAndSettle();
      await t.pump(const Duration(seconds: 4));

      final Map<String, dynamic> body = server.lastBodyFor(
        '/assessments/create',
      )!;
      expect(body['transcription_threshold'], 90);
      expect(body['subjective_threshold'], 70);
    });
  });
}
