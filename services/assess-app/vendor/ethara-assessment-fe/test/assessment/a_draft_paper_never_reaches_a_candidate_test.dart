// Owner rule: a candidate never gets a link or an assessment while it is in
// draft. The server answers a draft paper's token with the gate outcome
// `invalid`, like an unknown link.
//
//   a. The runner shows the invalid-link page for it, and a `/me` landing
//      after `/state` (with an attempt row, over an assessment cached from an
//      earlier sitting) does not turn that into another page - or an exam.
//   b. The admin's attempt page offers no candidate link to copy or open
//      while the paper is a draft.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/attempt_detail_screen.dart';
import 'package:ethara_assessment/assessment/screens/exam/exam_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';

const String kToken = 'tok-draft';

http.Response _ok(Object data) => http.Response(
  jsonEncode(<String, dynamic>{'ok': true, 'data': data}),
  200,
  headers: <String, String>{'content-type': 'application/json'},
);

Widget _mount(Widget child) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(
    body: AssessmentNavScope(nav: AssessmentNav(), child: child),
  ),
);

AppStore _admin(String state) {
  final AppStore s = AppStore();
  s.people = <Person>[Person(id: 'p1', name: 'Anita Rao', email: 'a@x.io')];
  s.assessments = <Assessment>[
    Assessment.fromJson(<String, dynamic>{
      'id': 'a1',
      'name': 'Paper',
      'state': state,
    }),
  ];
  s.attempts = <Attempt>[
    Attempt.fromJson(<String, dynamic>{
      'id': '80',
      'assessment_id': 'a1',
      'candidate': <String, dynamic>{'id': 'p1', 'name': 'Anita Rao'},
      'state': 'pending',
      'access_token': kToken,
    }),
  ];
  return s;
}

Btn _copyLink(WidgetTester t) => t.widget<Btn>(
  find.byWidgetPredicate(
    (Widget w) => w is Btn && w.label == 'Copy Candidate Link',
  ),
);

void main() {
  testWidgets('a. /me after an invalid /state still shows the invalid page', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1400, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    final AppStore s = AppStore(
      api: ApiClient(
        baseUrl: 'http://stub',
        bearer: 't',
        client: MockClient((http.Request req) async {
          if (req.url.path.endsWith('/state')) {
            return _ok(<String, dynamic>{'outcome': 'invalid'});
          }
          if (req.url.path.endsWith('/me/assessments')) {
            // The race: a list answered before the paper went back to draft.
            return _ok(<String, dynamic>{
              'buckets': <String, dynamic>{
                'upcoming': <dynamic>[
                  <String, dynamic>{
                    'id': 7,
                    'access_token': kToken,
                    'assessment_id': 21,
                    'state': 'pending',
                  },
                ],
              },
            });
          }
          return _ok(<String, dynamic>{});
        }),
      ),
    );
    s.portal = Portal.member;
    s.source = DataSource.live;
    s.meId = '2';
    // Left over from an earlier sitting of the same paper.
    s.assessments = <Assessment>[
      Assessment.fromJson(<String, dynamic>{
        'id': 21,
        'name': 'Paper',
        'state': 'in_progress',
      }),
    ];

    // Rebuilt on every notify, as the section does.
    await t.pumpWidget(
      _mount(
        ListenableBuilder(
          listenable: s,
          builder: (BuildContext _, Widget? _) =>
              ExamScreen(store: s, token: kToken),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('This link does not work'), findsOneWidget);

    await s.refresh();
    await t.pumpAndSettle();
    expect(s.attemptByToken(kToken), isNotNull, reason: '/me did land');
    expect(find.text('This link does not work'), findsOneWidget);
    expect(find.text('This assessment is closed'), findsNothing);
    expect(find.textContaining('not open yet'), findsNothing);
  });

  testWidgets('b. a draft paper offers no candidate link', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1800, 3000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    await t.pumpWidget(
      _mount(
        AttemptDetailScreen(
          store: _admin('draft'),
          portal: Portal.admin,
          attemptId: '80',
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(_copyLink(t).onPressed, isNull);
    expect(_copyLink(t).tooltip, kLinkAfterLaunch);
    expect(find.text(kLinkAfterLaunch), findsOneWidget);
    expect(find.textContaining('/exam/'), findsNothing);
  });

  testWidgets('b. a launched paper still offers it', (WidgetTester t) async {
    t.view.physicalSize = const Size(1800, 3000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    await t.pumpWidget(
      _mount(
        AttemptDetailScreen(
          store: _admin('in_progress'),
          portal: Portal.admin,
          attemptId: '80',
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(_copyLink(t).onPressed, isNotNull);
    expect(find.text('/exam/$kToken'), findsOneWidget);
    expect(find.text(kLinkAfterLaunch), findsNothing);
  });
}
