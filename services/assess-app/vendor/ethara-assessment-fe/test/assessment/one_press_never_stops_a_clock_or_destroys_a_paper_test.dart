// Archiving and deleting an assessment, and the presses in front of both.
//
// WHY THIS FILE IS ABOUT REQUEST BODIES. Both of these features are a
// conversation with a route that treats an unknown argument as an ABSENT one:
// `bool_arg("confirm_live_attempts")` and `str_arg("confirm_name")` in
// `controllers/api/write.py`. A client that spells either key differently does
// not get an error - it gets a refusal it can never satisfy, or worse, a
// confirmation the server never saw. That has happened on this codebase
// already: the roster sort shipped with the client sending `order`/`order_dir`
// against a route reading `sort`/`sort_desc`, and both halves' tests passed
// because each mocked its own. So the fake server below mirrors the real
// route's own logic - it refuses exactly what `write.py` refuses, on exactly
// the keys `write.py` reads - and every assertion here is about the wire.
//
// The other half of the subject is the pressing. Stopping 12 people's exam
// clock and destroying a cohort's results are both one button away, and
// neither may be one PRESS away: the tests below check that a cancelled sheet
// sends nothing at all, and that the call which destroys is reached only from
// the second confirmation.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/assessment_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';

const String kAsmId = '58';
const String kAsmName = 'Forklift Safety - Line 2';

/// One write, with the body it carried.
class Call {
  Call(this.path, this.body);
  final String path;
  final Map<String, dynamic> body;

  bool get isArchive => path.endsWith('/archive');
  bool get isDelete => path.endsWith('/delete');

  /// `action_done`, and the only one of the three with no server-side guard
  /// over a live sitting - and no way back once it lands.
  bool get isClose => path.endsWith('/close');

  /// The route's own spelling. See `_live_attempt_refusal` in `write.py`.
  bool get confirmsLiveAttempts => body['confirm_live_attempts'] == true;

  /// Present only on the call that DESTROYS. Step one of the delete leaves it
  /// out, which is what makes step one an archive.
  bool get destroys => body.containsKey('confirm_name');
  String get confirmName => (body['confirm_name'] as String?) ?? '';

  @override
  String toString() => '$path $body';
}

class _Rig {
  final List<Call> writes = <Call>[];
  late final AppStore store;

  /// How many of the roster are mid-sitting. The fake refuses like the route:
  /// archiving is refused while this is positive and the confirmation is
  /// absent.
  int live;

  /// People the SERVER counts as mid-sitting who are not in the roster this
  /// screen holds - a second page, or somebody who started since it loaded.
  /// The client cannot know about them, which is the point.
  int hiddenLive;

  int get serverLive => live + hiddenLive;

  /// Flipped by the fake when a call archives, so the client and the fake
  /// agree about which step the delete is on.
  bool active = true;
  bool deleted = false;
  bool closed = false;

  _Rig({this.live = 0, this.hiddenLive = 0});

  List<Call> get archives => writes.where((Call c) => c.isArchive).toList();
  List<Call> get deletes => writes.where((Call c) => c.isDelete).toList();
  List<Call> get destroys => deletes.where((Call c) => c.destroys).toList();
  List<Call> get closes => writes.where((Call c) => c.isClose).toList();

  Map<String, dynamic> get asmRow => <String, dynamic>{
    'id': kAsmId,
    'name': kAsmName,
    'state': closed ? 'done' : 'in_progress',
    'active': active,
    'assigned_count': 12,
    'response_count': 40,
  };

  List<Map<String, dynamic>> get attemptRows => <Map<String, dynamic>>[
    for (int i = 0; i < 12; i++)
      <String, dynamic>{
        'id': '${900 + i}',
        'assessment_id': kAsmId,
        'candidate': <String, dynamic>{'id': 'p$i', 'name': 'Candidate $i'},
        'state': i < live ? 'in_progress' : 'submitted',
        'answered_count': 3,
        'total_questions': 10,
      },
  ];

  void init() {
    store = AppStore(
      api: ApiClient(
        client: MockClient((http.Request req) async {
          final String path = req.url.path;
          final Map<String, dynamic> body = req.body.isEmpty
              ? <String, dynamic>{}
              : jsonDecode(req.body) as Map<String, dynamic>;

          if (path.endsWith('/archive')) {
            writes.add(Call(path, body));
            final bool archiving = body['archive'] != false;
            // `_live_attempt_refusal`, transcribed: refused once, by number,
            // unless the confirmation travelled with the call.
            if (archiving &&
                serverLive > 0 &&
                !(body['confirm_live_attempts'] == true)) {
              return _refusal(
                'live_attempts',
                '$serverLive candidate(s) are sitting \'$kAsmName\' right '
                    'now.',
                extra: <String, dynamic>{'live_attempt_count': serverLive},
              );
            }
            active = !archiving;
            return _json(asmRow);
          }

          if (path.endsWith('/delete')) {
            writes.add(Call(path, body));
            // STEP ONE: archive, then answer with what step two would cost.
            if (active) {
              if (serverLive > 0 && !(body['confirm_live_attempts'] == true)) {
                return _refusal(
                  'live_attempts',
                  '$serverLive candidate(s) are sitting \'$kAsmName\' right '
                      'now.',
                  extra: <String, dynamic>{'live_attempt_count': serverLive},
                );
              }
              active = false;
            }
            final String confirm = (body['confirm_name'] as String?) ?? '';
            if (confirm.trim().toLowerCase() != kAsmName.trim().toLowerCase()) {
              return _refusal(
                'confirm_required',
                '\'$kAsmName\' has been archived and is no longer running.',
                status: 409,
                extra: <String, dynamic>{
                  'archived': true,
                  'name': kAsmName,
                  'candidate_count': 12,
                  'response_count': 40,
                  'llm_usage_kept': 7,
                },
              );
            }
            deleted = true;
            return _json(<String, dynamic>{
              'deleted': true,
              'candidate_count': 12,
              'response_count': 40,
              'llm_usage_kept': 7,
            });
          }

          if (path.endsWith('/close')) {
            writes.add(Call(path, body));
            // NO REFUSAL HERE, and that is the route, not a simplification:
            // `assessment_close` calls `action_done()` with no
            // `_live_attempt_refusal`, so unlike archive and delete the server
            // will happily close a paper twelve people are sitting. The
            // question has to be asked before the call or it is not asked at
            // all.
            closed = true;
            return _json(asmRow);
          }

          if (path.endsWith('/candidates')) {
            // THE ROSTER ROUTE, FILTERED AND COUNTED SERVER-SIDE.
            // `_attempt_page` answers `meta.total` from `search_count` over the
            // whole domain rather than from the page it returns, which is why
            // asking for one row is enough to learn how many people are
            // sitting.
            final String state = (body['state'] as String?) ?? '';
            final List<Map<String, dynamic>> rows = state.isEmpty
                ? attemptRows
                : attemptRows
                      .where((Map<String, dynamic> r) => r['state'] == state)
                      .toList();
            final int limit = (body['limit'] as int?) ?? 200;
            return _json(
              rows.take(limit).toList(),
              // The server counts people this console cannot see: a second
              // page, or somebody who pressed Begin after the walk that filled
              // the cache.
              total: state == 'in_progress' ? serverLive : rows.length,
            );
          }
          if (path.endsWith('/assessments')) {
            return _json(deleted ? <dynamic>[] : <dynamic>[asmRow]);
          }
          if (path.endsWith('/attempts')) {
            return _json(deleted ? <dynamic>[] : attemptRows);
          }
          if (RegExp(r'/assessments/[^/]+$').hasMatch(path)) {
            return _json(asmRow);
          }
          return _json(<String, dynamic>{});
        }),
        baseUrl: 'http://x',
      ),
    );
  }

  static http.Response _json(Object data, {int? total}) => http.Response(
    jsonEncode(<String, dynamic>{
      'ok': true,
      'data': data,
      if (data is List)
        'meta': <String, dynamic>{
          'total': total ?? data.length,
          'limit': 200,
          'offset': 0,
          'has_more': false,
        },
    }),
    200,
    headers: <String, String>{'content-type': 'application/json'},
  );

  /// `fail()`'s envelope, extras merged at the TOP level - which is where the
  /// counts a confirmation quotes actually arrive.
  static http.Response _refusal(
    String code,
    String message, {
    int status = 409,
    Map<String, dynamic> extra = const <String, dynamic>{},
  }) => http.Response(
    jsonEncode(<String, dynamic>{
      'ok': false,
      'error': <String, dynamic>{'code': code, 'message': message},
      ...extra,
    }),
    status,
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
            asmId: kAsmId,
          ),
        ),
      ),
    ),
  );
}

// ignore: library_private_types_in_public_api
Future<_Rig> open(WidgetTester t, {int live = 0, int hiddenLive = 0}) async {
  t.view.physicalSize = const Size(1600, 3000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);

  final _Rig r = _Rig(live: live, hiddenLive: hiddenLive);
  r.init();
  await r.store.refresh();
  await t.pumpWidget(r.app());
  await t.pumpAndSettle();
  return r;
}

/// A button by its label, scoped to the design system's own control so a
/// matching word in a paragraph cannot be tapped instead.
Finder btn(String label) => find.widgetWithText(Btn, label);

/// Let the toaster's auto-dismiss timer fire.
///
/// A toast schedules a 3.2s dismissal, and a tree disposed while it is pending
/// fails the test on a timer that has nothing to do with what was asserted.
/// The house pattern, as in `chatter_panel_test.dart`.
Future<void> quiet(WidgetTester t) async {
  await t.pump(const Duration(seconds: 4));
}

/// Tab until the ring is on the button called [label].
///
/// Tab is the only way in - there is no API for "focus that button" that a
/// keyboard operator also has - so the walk itself is part of what is under
/// test: a control that cannot be reached by tabbing fails here too.
Future<void> tabTo(WidgetTester t, String label) async {
  for (int i = 0; i < 12; i++) {
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pumpAndSettle();
    final Btn? on = FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<Btn>();
    if (on?.label == label) return;
  }
  fail('twelve tabs never landed on "$label"');
}

Future<void> press(WidgetTester t, String label) async {
  expect(btn(label), findsOneWidget, reason: 'no button labelled "$label"');
  await t.ensureVisible(btn(label));
  await t.pumpAndSettle();
  await t.tap(btn(label));
  await t.pumpAndSettle();
}

void main() {
  group('archiving a paper people are sitting', () {
    testWidgets('asks first, and sends the route\'s own confirmation after', (
      WidgetTester t,
    ) async {
      final _Rig r = await open(t, live: 4);

      await press(t, 'Archive');

      // THE SHEET, not a toast. It has to say how many people and what happens
      // to them, because the count is what tells an operator they picked the
      // wrong row.
      expect(find.textContaining('4 candidate(s) are sitting'), findsWidgets);
      expect(
        r.archives,
        isEmpty,
        reason:
            'the sheet is a question, not a receipt - nothing may have '
            'been sent before it was answered',
      );

      await press(t, 'Archive Anyway');

      expect(r.archives.length, 1);
      expect(
        r.archives.single.confirmsLiveAttempts,
        isTrue,
        reason:
            'the key must be `confirm_live_attempts` exactly - '
            '`_live_attempt_refusal` reads that and nothing else, and an '
            'unknown key is an ABSENT one, so a rename leaves this archive '
            'refused forever with no error to show for it',
      );
      expect(r.archives.single.body['archive'], isTrue);
      await quiet(t);
    });

    // THE WARNING HAS TO BE TRUE, which is a different test from the warning
    // APPEARING. This sheet used to lead with "Their clock stops where it is."
    // and it does not: `deadline_datetime` is `started_at + duration_minutes`,
    // archiving never touches it, and no candidate route gates on `active`, so
    // an archived paper stays sittable and everybody is still submitted at
    // their original deadline. An operator who reads "stops" and confirms has
    // been told the opposite of what the server will do - and the server's own
    // `_live_attempt_refusal` says the true thing, so the two surfaces
    // disagreed about one behaviour.
    testWidgets('says the clock KEEPS running, because it does', (
      WidgetTester t,
    ) async {
      await open(t, live: 4);
      await press(t, 'Archive');

      expect(find.textContaining('clock keeps running'), findsWidgets);
      expect(
        find.textContaining('original deadline'),
        findsWidgets,
        reason:
            'the deadline is the fact that decides whether archiving was '
            'a mistake, so the sheet has to name it',
      );
      expect(
        find.textContaining('clock stops'),
        findsNothing,
        reason:
            'archiving pauses no exam; claiming it does is what made an '
            'operator confirm this in the first place',
      );
      expect(
        find.textContaining('nobody is auto-submitted'),
        findsNothing,
        reason:
            'only the closed-tab sweep is suspended - a candidate who is '
            'still answering is submitted at their deadline exactly as usual',
      );
    });

    testWidgets('cancelling sends nothing at all', (WidgetTester t) async {
      final _Rig r = await open(t, live: 4);

      await press(t, 'Archive');
      await press(t, 'Leave It Running');

      expect(
        r.writes,
        isEmpty,
        reason:
            'a cancelled confirmation is not a quieter version of the '
            'action - no request of any kind may leave',
      );
      // And the paper is still running, which is the whole point of cancelling.
      expect(r.store.asmById(kAsmId)!.active, isTrue);
    });

    testWidgets('an empty room is archived without being asked, and the '
        'confirmation is NOT sent', (WidgetTester t) async {
      final _Rig r = await open(t);

      await press(t, 'Archive');

      expect(r.archives.length, 1);
      expect(
        r.archives.single.body.containsKey('confirm_live_attempts'),
        isFalse,
        reason:
            'sending the confirmation unconditionally would make the '
            'route\'s guard unreachable - it would be answered before it was '
            'ever asked',
      );
      await quiet(t);
    });

    testWidgets('a roster that says nobody is sitting still gets the '
        'question, with the server\'s own count', (WidgetTester t) async {
      // THE ROSTER ON THIS SCREEN IS ONE PAGE AND MINUTES OLD. Believing it
      // is how the refusal became a dead end: the client saw an empty room,
      // sent the plain archive, and had nothing to show for the 409 but a
      // toast with no button on it. The answer is to ask with the number the
      // route refused over.
      final _Rig r = await open(t, hiddenLive: 6);

      await press(t, 'Archive');

      expect(r.archives.length, 1);
      expect(r.archives.single.confirmsLiveAttempts, isFalse);
      expect(find.textContaining('6 candidate(s) are sitting'), findsWidgets);

      await press(t, 'Archive Anyway');

      expect(r.archives.length, 2);
      expect(r.archives.last.confirmsLiveAttempts, isTrue);
      await quiet(t);
    });
  });

  group('closing a paper people are sitting', () {
    testWidgets('asks the SERVER who is mid-sitting, not the roster this '
        'console happens to hold', (WidgetTester t) async {
      // THE BLOCKER THIS TEST CLOSES. The question was answered from
      // `AppStore.attempts` - a console-wide walk capped at 25 pages across
      // EVERY assessment, filled once by `refresh()` and never again while the
      // operator sits on this screen. Every attempt is `pending` until its
      // candidate presses Begin, so an ordinary cohort reads zero minutes
      // after launch; zero SKIPPED the confirmation, and `/close` has no
      // server-side refusal behind it. The warning the operator was taught to
      // expect simply never appeared, and the close-out cannot be undone.
      final _Rig r = await open(t, hiddenLive: 6);

      await press(t, 'Mark Done');

      expect(
        r.closes,
        isEmpty,
        reason:
            'the sheet is a question, not a receipt - nothing may have '
            'been sent before it was answered',
      );
      expect(
        find.textContaining('6 candidate(s) are sitting'),
        findsWidgets,
        reason:
            'the cache says the room is empty and the server says six are '
            'in it; the number on the sheet is the one that closes exams',
      );

      await press(t, 'Close It Anyway');

      expect(r.closes.length, 1);
      await quiet(t);
    });

    testWidgets('an empty room is closed without being asked', (
      WidgetTester t,
    ) async {
      // The confirmation has to stay conditional or it becomes noise on every
      // tidy-up, which is how an operator learns to click through it.
      final _Rig r = await open(t);

      await press(t, 'Mark Done');

      expect(r.closes.length, 1);
      expect(find.text('Close this assessment?'), findsNothing);
      await quiet(t);
    });

    testWidgets('cancelling sends nothing at all', (WidgetTester t) async {
      final _Rig r = await open(t, live: 4);

      await press(t, 'Mark Done');
      await press(t, 'Leave It Open');

      expect(r.writes.where((Call c) => c.isClose), isEmpty);
      expect(r.store.asmById(kAsmId)!.state, AsmState.inProgress);
    });

    testWidgets('the button\'s own tooltip says what the server does', (
      WidgetTester t,
    ) async {
      // IT USED TO SAY THE OPPOSITE, and it is the only sentence an operator
      // reads BEFORE deciding to press. `action_done` writes `state = "done"`
      // and touches no per-candidate clock; `exam_begin` and `exam_answer`
      // both refuse with `assessment_closed` on `state != "in_progress"`. So
      // "attempts already in flight keep their remaining time" was false, and
      // it contradicted the confirmation eight lines below it - two
      // descriptions of one server behaviour, disagreeing.
      await open(t, live: 4);

      final String done = t.widget<Btn>(btn('Mark Done')).tooltip ?? '';
      expect(
        done,
        isNot(contains('keep their remaining time')),
        reason:
            'nothing preserves a sitting: the candidate is refused on '
            'their very next call',
      );
      expect(done, contains('closed screen on their next action'));
      expect(
        done,
        contains('Cannot be undone'),
        reason:
            '`action_cancel` refuses a done paper and '
            '`action_reset_draft` accepts only a cancelled one, so there is '
            'no route back - and the button has to say so before it is '
            'pressed, not after',
      );

      await press(t, 'Mark Done');
      final String anyway = t.widget<Btn>(btn('Close It Anyway')).tooltip ?? '';
      // The two must not drift: they describe the same call.
      for (final String claim in const <String>[
        'closed screen on their next action',
        'Cannot be undone',
      ]) {
        expect(anyway, contains(claim));
      }
    });

    testWidgets('the confirmation can be ANSWERED from the keyboard', (
      WidgetTester t,
    ) async {
      // `Btn` took focus and drew the ring but bound no activation, so every
      // confirmation sheet in the console could be tabbed into, read, and then
      // not answered: a ring advertising an interaction that did not exist.
      // Escape backed out, so the only thing a keyboard could not do was say
      // yes.
      final _Rig r = await open(t, live: 4);

      await press(t, 'Mark Done');
      await tabTo(t, 'Close It Anyway');
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();

      expect(r.closes.length, 1);
      await quiet(t);
    });

    testWidgets('and Space presses it too', (WidgetTester t) async {
      final _Rig r = await open(t, live: 4);

      await press(t, 'Mark Done');
      await tabTo(t, 'Leave It Open');
      await t.sendKeyEvent(LogicalKeyboardKey.space);
      await t.pumpAndSettle();

      expect(find.text('Close this assessment?'), findsNothing);
      expect(r.writes.where((Call c) => c.isClose), isEmpty);
    });
  });

  testWidgets('Delete is not offered; Archive still is', (
    WidgetTester t,
  ) async {
    expect(showAssessmentDelete, isFalse);
    await open(t);

    expect(find.widgetWithText(Btn, 'Delete'), findsNothing);
    expect(find.widgetWithText(Btn, 'Archive'), findsOneWidget);
  });

  // The flow below is kept, only hidden (`showAssessmentDelete`), so its
  // tests turn the button back on.
  group('deleting is two confirmations and one destroy', () {
    setUp(() => showAssessmentDelete = true);
    tearDown(() => showAssessmentDelete = false);

    testWidgets('the first press destroys nothing and sends nothing', (
      WidgetTester t,
    ) async {
      final _Rig r = await open(t);

      await press(t, 'Delete');

      expect(r.writes, isEmpty);
      expect(find.text('Delete ${_name()}?'), findsOneWidget);
      // The reversible half is named before the irreversible one. The copy is
      // deliberately terse - what is asserted is that the sheet SAYS nothing is
      // destroyed yet, not how many words it takes to say it.
      expect(find.textContaining('Nothing is destroyed yet'), findsWidgets);
    });

    testWidgets('the second press archives and previews; only the third '
        'destroys, and it carries the name', (WidgetTester t) async {
      final _Rig r = await open(t);

      await press(t, 'Delete');
      await press(t, 'Delete Permanently');

      // ARCHIVED, NOT DESTROYED. One call, and it deliberately carries no
      // `confirm_name` - that omission is what makes it the archive step.
      expect(r.deletes.length, 1);
      expect(r.deletes.single.destroys, isFalse);
      expect(r.destroys, isEmpty);
      expect(r.deleted, isFalse);
      expect(
        r.store.asmById(kAsmId)!.active,
        isFalse,
        reason:
            'the server archived it, so the screen behind the sheet must '
            'say so - an operator who backs out now needs Restore, not '
            'Archive',
      );

      await press(t, 'Delete Forever');

      expect(r.destroys.length, 1);
      expect(
        r.destroys.single.confirmName,
        kAsmName,
        reason:
            'the route compares `confirm_name` against the assessment\'s '
            'own name; a boolean or a different key is silently ignored and '
            'the delete never happens',
      );
      expect(r.deleted, isTrue);
      await quiet(t);
    });

    testWidgets('the confirmation names what is KEPT, not only what is lost', (
      WidgetTester t,
    ) async {
      await open(t);

      await press(t, 'Delete');
      await press(t, 'Delete Permanently');

      // The server's own counts, on the sheet that asks for the irreversible
      // yes.
      expect(find.textContaining('12 candidate(s)'), findsWidgets);
      expect(find.textContaining('40 recorded response(s)'), findsWidgets);
      expect(find.text('Destroyed'), findsOneWidget);

      // AND THE THING THAT SURVIVES. The fear this action provokes is losing
      // the spend record with the paper, and the spend record is exactly what
      // stays - `llm.usage.evaluator_id` is `ondelete="set null"`, so the
      // day's budget is unchanged by a delete.
      // WHAT is kept and HOW MUCH, in as few words as the fact allows. The
      // wording shortened; the guarantee did not - a delete that quietly
      // refunded the budget would be a way to spend it twice.
      expect(find.text('Kept'), findsOneWidget);
      expect(find.textContaining('LLM spend'), findsWidgets);
      expect(find.textContaining('7 row(s)'), findsWidgets);
      expect(find.textContaining('stays on the budget'), findsWidgets);
    });

    testWidgets('backing out of the second sheet leaves it archived and '
        'destroys nothing', (WidgetTester t) async {
      final _Rig r = await open(t);

      await press(t, 'Delete');
      await press(t, 'Delete Permanently');
      await press(t, 'Keep It Archived');

      expect(r.destroys, isEmpty);
      expect(r.deleted, isFalse);
      expect(r.store.asmById(kAsmId)!.active, isFalse);
      // The reversible action is the one now on offer - in the header, and in
      // the banner that explains why the paper has left the list.
      expect(btn('Archive'), findsNothing);
      expect(btn('Restore'), findsWidgets);
    });

    testWidgets('a live sitting is asked about before the delete archives it', (
      WidgetTester t,
    ) async {
      final _Rig r = await open(t, live: 3);

      await press(t, 'Delete');
      await press(t, 'Delete Permanently');

      // The route refused the ARCHIVE half - stopping their clock is a
      // different question from destroying the paper, and it is asked first.
      expect(find.textContaining('3 candidate(s) are sitting'), findsWidgets);
      expect(r.deletes.length, 1);
      expect(r.deletes.single.confirmsLiveAttempts, isFalse);
      expect(r.store.asmById(kAsmId)!.active, isTrue);

      await press(t, 'Archive Anyway');

      expect(r.deletes.length, 2);
      expect(r.deletes.last.confirmsLiveAttempts, isTrue);
      expect(r.deletes.last.destroys, isFalse);
      expect(r.destroys, isEmpty);

      await press(t, 'Delete Forever');

      expect(r.destroys.length, 1);
      expect(r.destroys.single.confirmName, kAsmName);
      await quiet(t);
    });

    testWidgets('cancelling the live-sitting question sends no second call', (
      WidgetTester t,
    ) async {
      final _Rig r = await open(t, live: 3);

      await press(t, 'Delete');
      await press(t, 'Delete Permanently');
      await press(t, 'Leave It Running');

      expect(r.deletes.length, 1);
      expect(r.destroys, isEmpty);
      expect(r.store.asmById(kAsmId)!.active, isTrue);
    });
  });
}

String _name() => kAsmName;
