// The Candidates roster row: who it is, why an invitation failed, and the
// writes an operator makes from it without opening the sitting.
//
// Pinned here:
//   - a failed invitation shows the server's reason on hover, and its Resend
//     icon puts that one invitation back on the queue;
//   - a read-only Manager still sees the reason, but gets no Resend and no
//     remark control (both are writes an Admin-only route would refuse);
//   - a row the route sent without a candidate name falls back to the person
//     the console knows, and then to the bare id - never a blank cell;
//   - the remark glyph opens a sheet titled with THAT name and saves the
//     remark on that attempt.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/assessment_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

const String _kResend = 'Resend this invitation';
const String _kWriteRemark = 'Write an internal remark on this sitting';

class _Rig {
  /// Every write the screen made, path to body, in order.
  final List<(String, Map<String, dynamic>)> writes =
      <(String, Map<String, dynamic>)>[];

  late final AppStore store = AppStore(
    api: ApiClient(
      baseUrl: 'http://x',
      client: MockClient((http.Request req) async {
        final String p = req.url.path;
        if (p.endsWith('/resend') || p.endsWith('/flag')) {
          final Map<String, dynamic> body = req.body.isEmpty
              ? <String, dynamic>{}
              : jsonDecode(req.body) as Map<String, dynamic>;
          writes.add((p, body));
          return _json(<String, dynamic>{
            'candidate_flag': <String, dynamic>{
              'flagged': false,
              'remark': body['remark'] ?? '',
            },
          });
        }
        if (p.endsWith('/candidates')) {
          return _json(
            <dynamic>[
              <String, dynamic>{
                'id': '100',
                'assessment_id': '58',
                'candidate': <String, dynamic>{'id': 'p1', 'name': 'Anita'},
                'state': 'pending',
                'invite_state': 'failed',
                'invite_error': 'Mailbox full',
              },
              // No candidate object: the name has to come from elsewhere.
              <String, dynamic>{
                'id': '101',
                'assessment_id': '58',
                'employee_id': 'p2',
                'state': 'pending',
                'invite_state': 'sent',
              },
              <String, dynamic>{
                'id': '102',
                'assessment_id': '58',
                'employee_id': 'p404',
                'state': 'pending',
                'invite_state': 'sent',
              },
            ],
            meta: <String, dynamic>{'total': 3},
          );
        }
        // The console-wide walk: where the console learns who p2 is, and the
        // cache the Resend and the remark look their attempt up in.
        if (p.endsWith('/attempts')) {
          return _json(<dynamic>[
            <String, dynamic>{
              'id': '100',
              'assessment_id': '58',
              'candidate': <String, dynamic>{'id': 'p1', 'name': 'Anita'},
              'state': 'pending',
              'invite_state': 'failed',
            },
            <String, dynamic>{
              'id': '101',
              'assessment_id': '58',
              'candidate': <String, dynamic>{'id': 'p2', 'name': 'Ravi Kumar'},
              'state': 'pending',
            },
          ]);
        }
        if (p.endsWith('/assessments')) return _json(<dynamic>[_asm]);
        if (RegExp(r'/assessments/[^/]+$').hasMatch(p)) return _json(_asm);
        return _json(<String, dynamic>{});
      }),
    ),
  );

  static const Map<String, dynamic> _asm = <String, dynamic>{
    'id': '58',
    'name': 'Q7r',
    'state': 'in_progress',
    'active': true,
  };

  static http.Response _json(Object data, {Map<String, dynamic>? meta}) =>
      http.Response(
        jsonEncode(<String, dynamic>{
          'ok': true,
          'data': data,
          if (data is List)
            'meta': meta ?? <String, dynamic>{'total': data.length},
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );

  Widget app() => MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(
      body: AssessmentNavScope(
        nav: AssessmentNav(),
        child: SingleChildScrollView(
          child: AssessmentDetailScreen(
            store: store,
            portal: Portal.admin,
            asmId: '58',
            tab: 'candidates',
          ),
        ),
      ),
    ),
  );
}

/// Opens the Candidates tab; [caps] narrows what the signed-in operator may
/// change, as the server's capability list does for a read-only Manager.
Future<_Rig> _open(WidgetTester t, {Set<Capability>? caps}) async {
  t.view.physicalSize = const Size(1600, 3000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  final _Rig r = _Rig();
  addTearDown(r.store.dispose);
  if (caps != null) {
    r.store.adoptSession(orgRole: 'admin', uid: '2', capabilities: caps);
  }
  await r.store.refresh();
  await t.pumpWidget(r.app());
  await t.pumpAndSettle();
  return r;
}

void main() {
  testWidgets('a failed invitation shows why, and Resend requeues that one', (
    WidgetTester t,
  ) async {
    final _Rig r = await _open(t);

    expect(find.byTooltip('Mailbox full'), findsOneWidget);
    expect(
      find.byTooltip(_kResend),
      findsOneWidget,
      reason: 'only the failed row offers a resend',
    );

    await t.tap(find.byTooltip(_kResend));
    await t.pumpAndSettle();

    expect(r.writes.map(((String, Map<String, dynamic>) w) => w.$1), <String>[
      '/api/v1/attempts/100/resend',
    ]);
    await t.pump(const Duration(seconds: 30));
  });

  testWidgets('a read-only Manager sees the reason but no Resend or remark', (
    WidgetTester t,
  ) async {
    await _open(
      t,
      caps: Capability.values.toSet()..remove(Capability.lifecycle),
    );

    expect(find.byTooltip('Mailbox full'), findsOneWidget);
    expect(find.byTooltip(_kResend), findsNothing);
    expect(find.byTooltip(_kWriteRemark), findsNothing);
  });

  testWidgets('a row without a name shows the known person, then the id', (
    WidgetTester t,
  ) async {
    await _open(t);

    expect(find.text('Anita'), findsOneWidget);
    expect(find.text('Ravi Kumar'), findsOneWidget);
    expect(find.text('p404'), findsOneWidget);
  });

  testWidgets('the remark glyph names the row it was opened from and saves '
      'the remark on that attempt', (WidgetTester t) async {
    final _Rig r = await _open(t);

    // Rows in the server's order: Anita, Ravi Kumar, p404.
    await t.tap(find.byTooltip(_kWriteRemark).at(1));
    await t.pumpAndSettle();
    expect(find.text('Add a remark on Ravi Kumar'), findsOneWidget);

    await t.enterText(find.byType(TextField).last, 'Left the room twice.');
    await t.pumpAndSettle();
    await t.tap(find.text('Save Remark'));
    await t.pumpAndSettle();

    expect(r.writes, hasLength(1));
    expect(r.writes.single.$1, '/api/v1/attempts/101/flag');
    expect(r.writes.single.$2, <String, dynamic>{
      'remark': 'Left the room twice.',
    });
    await t.pump(const Duration(seconds: 30));
  });
}
