// THE ONE SETTING THAT MUST OUTLIVE LAUNCH.
//
// 'Grade subjective answers automatically' (`llm_auto_score`) is how an
// operator restarts a grading queue that has starved. Freezing it the moment
// the assessment launches takes away the only lever they have - and the server
// never asked for that: `llm_auto_score` is in `assessment_update`'s
// POST_DRAFT_FIELDS (`controllers/api/write.py`), so the route has always
// accepted it on a RUNNING assessment. The Odoo form agrees, carrying
// `readonly="state in ('done','cancelled')"` for this field alone.
//
// The draw settings are the opposite case and this file guards that too. The
// question draw happens AT launch, so 'Shuffle Questions' and the 'Questions'
// count describe a paper that has already been served. `shuffle_questions` is
// folded into `preserve_question_order` before the draft gate even runs, and a
// CHANGED `question_limit` on a launched assessment is refused as
// `locked_after_launch` - so offering either post-launch moves a control on
// screen and comes back refused.
//
// 'Same questions for everybody' is gone altogether: launch always draws one
// shared set, and the server ignores the key.
library;

import 'dart:convert';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/assessment_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';
import 'package:ethara_assessment/assessment/widgets/controls.dart';
import 'package:ethara_assessment/assessment/widgets/feedback.dart';
import 'package:ethara_assessment/assessment/widgets/panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const String kAutoScore = 'Grade subjective answers automatically';
const String kSameForAll = 'Same questions for everybody';
const String kShuffle = 'Shuffle Questions';

/// The server's refusal of a changed count on a launched assessment.
const String kLockedMessage =
    'The question count is locked once the assessment has launched.';

/// Serves one assessment detail in a given state and records every update body.
class _Rig {
  final List<Map<String, dynamic>> writes = <Map<String, dynamic>>[];
  final String state;
  final bool autoScore;

  /// The update route answers 422 `locked_after_launch`, as it does when the
  /// assessment was launched (in another tab, say) after this screen loaded.
  final bool refuseUpdate;
  late final AppStore store;

  _Rig({required this.state, this.autoScore = false, this.refuseUpdate = false}) {
    store = AppStore(
      api: ApiClient(
        client: MockClient((http.Request req) async {
          if (req.url.path.endsWith('/update')) {
            writes.add(jsonDecode(req.body) as Map<String, dynamic>);
            if (refuseUpdate) {
              return http.Response(
                jsonEncode(<String, dynamic>{
                  'ok': false,
                  'error': <String, dynamic>{
                    'code': 'locked_after_launch',
                    'message': kLockedMessage,
                  },
                }),
                422,
                headers: <String, String>{'content-type': 'application/json'},
              );
            }
          }
          return http.Response(
            jsonEncode(<String, dynamic>{'ok': true, 'data': _detail}),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
        baseUrl: 'http://x',
      ),
    );
  }

  Map<String, dynamic> get _detail => <String, dynamic>{
    'id': '7',
    'name': 'test_cj',
    'state': state,
    'duration_minutes': 45,
    'question_limit': 6,
    'total_questions': 6,
    'subjective_threshold': 60.0,
    'shuffle_questions': true,
    'llm_auto_score': autoScore,
  };

  Widget get app => MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(
      body: AssessmentNavScope(
        nav: AssessmentNav(),
        child: AssessmentDetailScreen(
          store: store,
          portal: Portal.admin,
          asmId: '7',
        ),
      ),
    ),
  );
}

void main() {
  void desktop(WidgetTester tester) {
    tester.view.physicalSize = const Size(1600, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// A switch is offered when its `onChanged` is wired and locked when it is
  /// null - the same fact `Switcher` reads to decide whether it responds.
  bool enabled(WidgetTester tester, String name) {
    final Iterable<SwitchRow> rows = tester
        .widgetList<SwitchRow>(find.byType(SwitchRow))
        .where((SwitchRow r) => r.name == name);
    expect(rows, hasLength(1), reason: '"$name" must be on the tab exactly once');
    return rows.single.onChanged != null;
  }

  /// The count is offered when its stepper is on screen; locked, it is a
  /// read-only value under the same label.
  bool countEditable(WidgetTester tester) {
    final Finder field = find.byWidgetPredicate(
      (Widget w) => w is Field && w.label == 'Questions',
    );
    expect(field, findsOneWidget, reason: '"Questions" must be on the tab once');
    return find
        .descendant(of: field, matching: find.byType(NumberField))
        .evaluate()
        .isNotEmpty;
  }

  Finder noticeSaying(String strong) => find.byWidgetPredicate(
    (Widget w) => w is Notice && w.strong == strong,
  );

  for (final String live in <String>['draft', 'in_progress']) {
    testWidgets('automatic grading stays editable while $live', (
      WidgetTester tester,
    ) async {
      desktop(tester);
      await tester.pumpWidget(_Rig(state: live).app);
      await settle(tester);

      expect(
        enabled(tester, kAutoScore),
        isTrue,
        reason: 'the route accepts llm_auto_score post-draft; locking it here '
            'strands a starved queue with no way to restart it',
      );
    });
  }

  for (final String over in <String>['done', 'cancelled']) {
    testWidgets('automatic grading is locked once $over', (
      WidgetTester tester,
    ) async {
      desktop(tester);
      await tester.pumpWidget(_Rig(state: over).app);
      await settle(tester);

      expect(
        enabled(tester, kAutoScore),
        isFalse,
        reason: 'Odoo marks this readonly in done and cancelled - nothing is '
            'left to grade, so the switch would only mislead',
      );
    });
  }

  testWidgets('a running assessment can post the toggle on its own', (
    WidgetTester tester,
  ) async {
    desktop(tester);
    final _Rig rig = _Rig(state: 'in_progress');
    await tester.pumpWidget(rig.app);
    await settle(tester);

    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text(kAutoScore),
          matching: find.byType(SwitchRow),
        ),
        matching: find.byType(Switcher),
      ),
    );
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 3300));

    expect(rig.writes, isNotEmpty, reason: 'the edit must reach the server');
    expect(rig.writes.last['llm_auto_score'], true);
    // The store diffs against the record it already holds, so the two fields
    // the route WOULD refuse post-draft must not ride along and fail a write
    // the server would otherwise have taken.
    expect(rig.writes.last.containsKey('question_limit'), isFalse);
    expect(rig.writes.last.containsKey('shuffle_questions'), isFalse);
    expect(rig.writes.last.containsKey('same_questions_for_all'), isFalse);
  });

  // THE OVER-CORRECTION GUARD. Unlocking the scoring toggle must not unlock
  // the draw beside it.
  for (final String over in <String>['in_progress', 'done', 'cancelled']) {
    testWidgets('the draw settings stay locked once $over', (
      WidgetTester tester,
    ) async {
      desktop(tester);
      await tester.pumpWidget(_Rig(state: over).app);
      await settle(tester);

      expect(enabled(tester, kShuffle), isFalse);
      expect(
        countEditable(tester),
        isFalse,
        reason: 'late candidates copy the set launch drew, so a new count '
            'reaches nobody - and the server refuses a changed one',
      );
      // The value stays what launch drew, not the pool size.
      expect(
        find.descendant(
          of: find.byWidgetPredicate(
            (Widget w) => w is Field && w.label == 'Questions',
          ),
          matching: find.text('6'),
        ),
        findsOneWidget,
      );
    });
  }

  testWidgets('the draw settings are editable on a draft', (
    WidgetTester tester,
  ) async {
    desktop(tester);
    await tester.pumpWidget(_Rig(state: 'draft').app);
    await settle(tester);

    expect(enabled(tester, kShuffle), isTrue);
    expect(countEditable(tester), isTrue);
  });

  for (final String any in <String>['draft', 'in_progress', 'done']) {
    testWidgets('"Same questions for everybody" is not offered ($any)', (
      WidgetTester tester,
    ) async {
      desktop(tester);
      await tester.pumpWidget(_Rig(state: any).app);
      await settle(tester);

      expect(find.text(kSameForAll), findsNothing);
    });
  }

  // A screen loaded while the assessment was a draft still offers the
  // stepper; if it was launched meanwhile, the server's refusal is the only
  // thing that can tell the operator why the number did not stick.
  testWidgets('a refused count shows the server\'s own message', (
    WidgetTester tester,
  ) async {
    desktop(tester);
    final _Rig rig = _Rig(state: 'draft', refuseUpdate: true);
    await tester.pumpWidget(rig.app);
    await settle(tester);

    await rig.store.updateAsm(
      rig.store.asmById('7')!.copyWith(questionLimit: 4),
    );
    await settle(tester);

    expect(rig.writes.last['question_limit'], 4);
    expect(
      rig.store.toaster.items.map((ToastMsg m) => m.message),
      contains(kLockedMessage),
    );
    await tester.pump(const Duration(seconds: 10));
  });

  // It binds on the NEXT submit and never re-reads itself, so an operator who
  // flips it on mid-cohort gets nobody who already submitted.
  testWidgets('a post-launch On says who it does not pick up', (
    WidgetTester tester,
  ) async {
    desktop(tester);
    await tester.pumpWidget(_Rig(state: 'in_progress', autoScore: true).app);
    await settle(tester);

    expect(
      noticeSaying('This applies from the next submission onwards.'),
      findsOneWidget,
    );
  });

  testWidgets('a draft is not told about a backlog it cannot have', (
    WidgetTester tester,
  ) async {
    desktop(tester);
    await tester.pumpWidget(_Rig(state: 'draft', autoScore: true).app);
    await settle(tester);

    expect(
      noticeSaying('This applies from the next submission onwards.'),
      findsNothing,
    );
  });
}
