// Opened from Yantra, the app signs in with the ticket and opens the sitting
// straight away: no login form, and the exam token comes from the redeem, not
// the address bar (which held only the ticket).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/app_shell.dart';
import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/login_screen.dart';
import 'package:ethara_assessment/main.dart';
import 'package:ethara_assessment/session.dart';

http.Response _json(int status, Object body) => http.Response(
  jsonEncode(body),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

Session _session(List<String> paths, {int redeemStatus = 200}) => Session(
  api: ApiClient(
    baseUrl: 'http://app',
    client: MockClient((http.Request r) async {
      paths.add(r.url.path);
      switch (r.url.path) {
        case '/api/v1/yantra/launch/redeem':
          return redeemStatus == 200
              ? _json(200, <String, Object?>{
                  'ok': true,
                  'data': <String, Object?>{
                    'access_token': 'bearer-1',
                    'exam_token': 'exam-1',
                    'return_url': 'http://localhost:8095/work',
                  },
                })
              : _json(redeemStatus, <String, Object?>{
                  'ok': false,
                  'error': <String, Object?>{
                    'code': 'ticket_used',
                    'message': 'used',
                  },
                });
        case '/api/v1/auth/me':
          return _json(200, <String, Object?>{
            'ok': true,
            'data': <String, Object?>{
              'user': <String, Object?>{
                'name': 'Worker',
                'uid': 8,
                'role': 'candidate',
              },
            },
          });
      }
      return _json(200, <String, Object?>{'ok': true, 'data': {}});
    }),
  ),
);

Future<void> _pump(WidgetTester t, String url, Session s) async {
  t.view.physicalSize = const Size(1600, 1200);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  addTearDown(s.dispose);
  await t.pumpWidget(EtharaAssessmentApp(pageUrl: Uri.parse(url), session: s));
  await t.pump();
  await t.pump();
}

void main() {
  testWidgets('a launch link opens the sitting with no login form', (
    WidgetTester t,
  ) async {
    final List<String> paths = <String>[];
    await _pump(t, 'http://localhost:8096/yantra/launch#ticket=t-1', _session(paths));
    expect(paths.take(2), <String>[
      '/api/v1/yantra/launch/redeem',
      '/api/v1/auth/me',
    ]);
    expect(find.byType(LoginScreen), findsNothing);
    final AppShell shell = t.widget(find.byType(AppShell));
    expect(shell.examToken, 'exam-1');
  });

  testWidgets('a spent link lands on the login form, saying why', (
    WidgetTester t,
  ) async {
    final List<String> paths = <String>[];
    await _pump(
      t,
      'http://localhost:8096/yantra/launch#ticket=t-1',
      _session(paths, redeemStatus: 410),
    );
    expect(paths, <String>['/api/v1/yantra/launch/redeem']);
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.textContaining('already been used'), findsWidgets);
  });

  testWidgets('without a ticket nothing is redeemed', (WidgetTester t) async {
    final List<String> paths = <String>[];
    await _pump(t, 'http://localhost:8096/exam/abc', _session(paths));
    expect(paths, isNot(contains('/api/v1/yantra/launch/redeem')));
    expect(find.byType(LoginScreen), findsOneWidget);
  });
}
