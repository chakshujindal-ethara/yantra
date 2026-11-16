// BR-D15: a violation report that does not reach the server is kept and sent
// again, before any answer typed after it.
//
// THE CHEAT IT CLOSES. A `/violation` that failed in transport was dropped
// and never retried, while the answers typed meanwhile went in once the
// connection came back. So: go offline (or block the one route), use a phone
// (detection runs on the device, its reports were lost), come back, and the
// answers land with no violation behind them. And a candidate at the cap was
// told the exam had ended while the server, which never heard, kept it open.
//
// Now each report waits in the store until the server answers it, goes before
// any answer typed after it, before Next and before the submit, and is tried
// again. At the cap under auto-submit the exam is locked until the server
// says whether that ended it - never called submitted. Log only queues and
// resends too, and never locks.
//
// This build keeps the queue in memory (there is no device store behind the
// answers here), so the page asks before it is left while one is unsent.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/exam/exam_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/feedback.dart';
import 'package:ethara_assessment/services/proctor_stub.dart';

const String kToken = 'tok-d15';

/// A sitting of one written question. [down] drops every request; with
/// [violationDown] only `/violation` gets no answer (a blocked route, or a
/// connection that comes back between two calls). The server ends the
/// sitting when its own count reaches [cap] under auto-submit; [dedup] makes
/// it count nothing (a folded repeat). A report it has already recorded with
/// the same `at` counts once, as the real route does. [violationStatus]
/// refuses `/violation` (500, 503) or ends on the clock (409, with
/// [violationCode]); [replyLost] records a report and loses the reply.
/// [answerFails] fails that many `/answer`s with a 500; `/submit` waits on
/// [holdSubmit], and is refused `attempt_locked` once the sitting is over.
class _Server extends http.BaseClient {
  _Server({this.cap = 1, this.autoSubmit = true});

  final int cap;
  final bool autoSubmit;
  bool down = false;
  bool violationDown = false;
  bool dedup = false;
  bool replyLost = false;
  int violationStatus = 200;
  String violationCode = 'server_error';
  int answerFails = 0;
  Future<void>? holdSubmit;
  int count = 0;
  final Set<Object?> stamps = <Object?>{};

  /// The server ended the sitting (its count reached the cap, or its own
  /// ending raised after the count): `/state` says complete.
  bool ended = false;
  bool get _over => ended || submitted || _violated;
  bool get _violated => ended || (autoSubmit && count >= cap);

  /// The server took a submit of this sitting.
  bool submitted = false;

  /// The paper's rules: fullscreen on, for the fullscreen bar.
  bool fullscreenRule = false;

  final List<({String route, Map<String, dynamic> body})> calls =
      <({String route, Map<String, dynamic> body})>[];

  List<String> get routes => <String>[
    for (final ({String route, Map<String, dynamic> body}) c in calls) c.route,
  ];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final String route = request.url.path.split('/').last;
    final Map<String, dynamic> body =
        request is http.Request && request.body.isNotEmpty
        ? jsonDecode(request.body) as Map<String, dynamic>
        : <String, dynamic>{};
    if (down || (violationDown && route == 'violation')) {
      throw http.ClientException('Failed to fetch');
    }
    calls.add((route: route, body: body));
    if (route == 'submit') await holdSubmit;
    final int status = switch (route) {
      'violation' => violationStatus,
      'answer' when answerFails > 0 => 500,
      'submit' when _over => 409,
      _ => 200,
    };
    if (route == 'answer' && answerFails > 0) answerFails--;
    if (status != 200) {
      return http.StreamedResponse(
        Stream<List<int>>.value(
          utf8.encode(
            jsonEncode(<String, dynamic>{
              'ok': false,
              'error': <String, dynamic>{
                'code': switch (route) {
                  'violation' => violationCode,
                  'submit' => 'attempt_locked',
                  _ => 'server_error',
                },
                'message': 'refused',
              },
            }),
          ),
        ),
        status,
        headers: <String, String>{'content-type': 'application/json'},
        request: request,
      );
    }
    final Object data = switch (route) {
      'violation' => () {
        final bool again = body['at'] != null && !stamps.add(body['at']);
        final bool counted = !dedup && !again;
        if (counted) count++;
        return <String, dynamic>{
          'recorded': counted,
          'violation_count': count,
          'attempt_ended': autoSubmit && count >= cap,
          'violation_limit_breached': count >= cap,
        };
      }(),
      'state' => <String, dynamic>{
        'outcome': _over ? 'complete' : 'question',
        'assessment': _assessment(),
        'attempt': _attempt(),
        'question': <String, dynamic>{
          'id': 10,
          'index': 1,
          'total': 1,
          'name': 'Q1',
          'prompt': 'Explain.',
          'question_type': 'subjective_rubric',
        },
      },
      'answer' => <String, dynamic>{'saved': true, 'next': null},
      'submit' => () {
        submitted = true;
        return <String, dynamic>{};
      }(),
      // The candidate's list, as the re-read after an ending asks for it.
      'assessments' => <String, dynamic>{
        'buckets': <String, dynamic>{
          'all': <dynamic>[_attempt()],
        },
      },
      _ => <String, dynamic>{},
    };
    if (replyLost && route == 'violation') {
      throw http.ClientException('Failed to fetch');
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(
        utf8.encode(jsonEncode(<String, dynamic>{'ok': true, 'data': data})),
      ),
      200,
      headers: <String, String>{'content-type': 'application/json'},
      request: request,
    );
  }

  Map<String, dynamic> _assessment() => <String, dynamic>{
    'id': 55,
    'name': 'Paper',
    'state': 'in_progress',
    'duration_minutes': 60,
    'violation_action': autoSubmit ? 'auto_submit' : 'log_only',
    'max_violations': cap,
    if (fullscreenRule) 'rules': <String, dynamic>{'fullscreen': true},
  };

  Map<String, dynamic> _attempt() => <String, dynamic>{
    'id': 1,
    'access_token': kToken,
    'assessment_id': 55,
    'state': _over ? 'submitted' : 'in_progress',
    'is_locked': _over,
    'auto_submitted': _violated,
    'auto_submit_reason': _violated ? 'violation' : '',
    'started_at': DateTime.now().toUtc().toIso8601String(),
    'deadline': DateTime.now()
        .add(const Duration(hours: 1))
        .toUtc()
        .toIso8601String(),
    'violation_count': count,
    'total_questions': 1,
  };
}

/// A live store seated on the sitting, as `/state` left it.
AppStore _store(
  _Server server, {
  void Function(void Function()? onLeave)? leaveGuard,
}) {
  final AppStore s = AppStore(
    api: ApiClient(
      client: server,
      baseUrl: 'https://x.invalid',
      bearer: 't',
      maxAttempts: 1,
    ),
    answerDebounce: const Duration(hours: 1),
    // Retried by hand below, never by the clock.
    violationRetry: const Duration(hours: 1),
    leaveGuard: leaveGuard ?? (void Function()? _) {},
  );
  s.portal = Portal.member;
  s.source = DataSource.live;
  s.meId = '2';
  return s;
}

Future<AppStore> _open(
  _Server server, {
  void Function(void Function()? onLeave)? leaveGuard,
}) async {
  final AppStore s = _store(server, leaveGuard: leaveGuard);
  await s.loadExamByToken(kToken);
  await _settle();
  return s;
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 40));

const Response _typed = Response(justification: 'typed after the report');

List<String> _said(AppStore s) =>
    s.toaster.items.map((ToastMsg m) => m.message).toList();

void main() {
  test('an offline report is kept and goes before the next answer', () async {
    final _Server server = _Server(cap: 3);
    final AppStore s = await _open(server);

    server.down = true;
    s.recordViolation('1', 'Phone detected');
    await _settle();
    expect(s.violationReportsUnsent(kToken), isTrue);
    expect(s.violationReportsWaiting(kToken), isTrue);

    // Typed after the report. Answers get through again, the report does
    // not: the answer waits for it.
    s.saveAnswerQuiet('1', '10', _typed);
    server
      ..down = false
      ..violationDown = true;
    server.calls.clear();
    expect(await s.flushAnswers(), isFalse, reason: 'not kept yet');
    await _settle();
    expect(server.routes, isNot(contains('answer')));

    server.violationDown = false;
    s.retryViolationReports(kToken);
    await _settle();

    expect(server.routes, <String>['violation', 'answer']);
    expect(
      server.calls.last.body,
      containsPair('justification', 'typed after the report'),
    );
    expect(s.violationReportsUnsent(kToken), isFalse);
    s.dispose();
  });

  test('a report goes before the submit, and holds it while unsent', () async {
    final _Server server = _Server(cap: 3);
    final AppStore s = await _open(server);

    server.violationDown = true;
    s.recordViolation('1', 'Phone detected');
    s.saveAnswerQuiet('1', '10', _typed);
    await _settle();
    server.calls.clear();

    // Held, so not submitted: the caller stays where Submit was pressed.
    expect(await s.finishExam('1', force: true), isFalse);
    expect(server.routes, isNot(contains('submit')));
    expect(server.routes, isNot(contains('answer')));
    expect(_said(s).join(' '), contains('NOT submitted'));
    expect(s.attemptById('1')!.isDone, isFalse, reason: 'never marked');

    server.violationDown = false;
    s.finishExam('1', force: true);
    await _settle();
    expect(server.routes, contains('submit'));
    expect(
      server.routes.indexOf('violation'),
      lessThan(server.routes.indexOf('submit')),
    );
    expect(
      server.routes.indexOf('violation'),
      lessThan(server.routes.indexOf('answer')),
    );
    expect(s.attemptById('1')!.isDone, isTrue);
    s.dispose();
  });

  test('a queued report that ends the sitting at Submit: what was typed '
      'before it is sent first, and it is the ending', () async {
    final _Server server = _Server();
    final AppStore s = await _open(server);
    // Typed before the report, and offline with it: neither got through.
    server.down = true;
    s.saveAnswerQuiet('1', '10', const Response(justification: 'before'));
    s.recordViolation('1', 'Phone detected');
    await _settle();
    expect(s.violationLocked(kToken), isTrue);

    server
      ..down = false
      ..calls.clear();
    // Ended, so the caller moves on to the completion page (BR-D1).
    expect(await s.finishExam('1', force: true), isTrue);
    await _settle();
    expect(server.routes.take(2), <String>['answer', 'violation']);
    expect(server.routes, isNot(contains('submit')), reason: 'it ended it');
    expect(s.attemptById('1')!.autoSubmitReason, 'violation');
    expect(s.unsavedAtEnd, isEmpty);
    expect(_said(s), isNot(contains('Assessment submitted')));
    s.dispose();
  });

  test(
    'Next waits for an unsent report, and goes once it is answered',
    () async {
      final _Server server = _Server(cap: 3)..violationDown = true;
      final AppStore s = await _open(server);
      s.recordViolation('1', 'Phone detected');
      await _settle();
      s.saveAnswerQuiet('1', '10', _typed);
      server.calls.clear();

      expect(await s.examAdvance(kToken, '10', _typed), isFalse);
      expect(server.routes, isNot(contains('answer')));
      expect(_said(s), contains(AppStore.reportsHeldMessage));

      server.violationDown = false;
      await s.examAdvance(kToken, '10', _typed);
      await _settle();
      expect(server.routes.take(2), <String>['violation', 'answer']);
      s.dispose();
    },
  );

  test('while a report is unsent the page asks before it is left', () async {
    final List<bool> guarded = <bool>[];
    final _Server server = _Server(cap: 3);
    final AppStore s = await _open(
      server,
      leaveGuard: (void Function()? onLeave) => guarded.add(onLeave != null),
    );

    server.violationDown = true;
    s.recordViolation('1', 'Phone detected');
    await _settle();
    expect(guarded.last, isTrue, reason: 'nothing else keeps it');

    server.violationDown = false;
    s.retryViolationReports(kToken);
    await _settle();
    expect(guarded.last, isFalse);
    s.dispose();
  });

  group('at the cap under auto-submit, unconfirmed', () {
    test('offline: locked, never called submitted', () async {
      final _Server server = _Server();
      final AppStore s = await _open(server);

      server.violationDown = true;
      expect(s.recordViolation('1', 'Phone detected'), isFalse);
      await _settle();

      expect(s.violationLocked(kToken), isTrue);
      expect(s.violationReportsWaiting(kToken), isTrue);
      expect(s.attemptById('1')!.isDone, isFalse);
      expect(_said(s).join(' '), isNot(contains('submitted')));

      // It gets through: the server ends the sitting.
      server.violationDown = false;
      s.retryViolationReports(kToken);
      await _settle();
      expect(s.attemptByToken(kToken)?.isDone ?? true, isTrue);
      expect(s.violationLocked(kToken), isFalse);
      s.dispose();
    });

    test('the server counted less and did not end it: unlocked, the sitting '
        'goes on', () async {
      final _Server server = _Server()..dedup = true;
      final AppStore s = await _open(server);

      s.recordViolation('1', 'Phone detected');
      expect(s.violationLocked(kToken), isTrue, reason: 'until it answers');
      await _settle();

      expect(s.violationLocked(kToken), isFalse);
      expect(s.attemptById('1')!.isDone, isFalse);
      expect(s.attemptById('1')!.violationCount, 0, reason: 'its count');
      s.dispose();
    });

    testWidgets('on screen: a plain lock over the paper, no "submitted"', (
      WidgetTester t,
    ) async {
      final _Server server = _Server()..violationDown = true;
      final AppStore s = _store(server);
      await t.runAsync(() => s.loadExamByToken(kToken));
      t.view.physicalSize = const Size(1400, 1600);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: AssessmentNavScope(
            nav: AssessmentNav(),
            child: ExamScreen(store: s, token: kToken, sub: ExamSub.question),
          ),
        ),
      );
      await t.pump();

      s.recordViolation('1', 'Phone detected');
      await t.runAsync(_settle);
      await t.pump();

      expect(find.text('Violation limit reached'), findsOneWidget);
      expect(
        find.text(
          'Your exam has reached its violation limit. Reconnecting to '
          'finish it.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('submitted'), findsNothing);

      await t.pumpWidget(const SizedBox());
      s.dispose();
      await t.pump(const Duration(minutes: 1));
    });
  });

  test('log only: queued and sent again, never locked', () async {
    final _Server server = _Server(autoSubmit: false);
    final AppStore s = await _open(server);

    server.down = true;
    s.recordViolation('1', 'Phone detected');
    await _settle();
    expect(s.violationLocked(kToken), isFalse);
    expect(s.violationReportsWaiting(kToken), isTrue);

    server.down = false;
    server.calls.clear();
    s.retryViolationReports(kToken);
    await _settle();
    expect(server.routes, contains('violation'));
    expect(s.violationReportsWaiting(kToken), isFalse);
    expect(s.attemptById('1')!.isDone, isFalse);
    s.dispose();
  });

  group('the BR-D15 review', () {
    test('P1-1: a 500 on /violation is the server\'s answer: later answers '
        'and the Submit still go', () async {
      final _Server server = _Server(cap: 3)..violationStatus = 500;
      final AppStore s = await _open(server);
      s.recordViolation('1', 'Phone detected');
      await _settle();
      expect(s.violationReportsWaiting(kToken), isFalse, reason: 'dropped');
      expect(s.violationReportsUnsent(kToken), isFalse);

      s.saveAnswerQuiet('1', '10', _typed);
      server.calls.clear();
      expect(await s.flushAnswers(), isTrue);
      expect(server.routes, <String>['answer']);
      s.finishExam('1', force: true);
      await _settle();
      expect(server.routes, contains('submit'));
      expect(s.attemptById('1')!.isDone, isTrue);
      s.dispose();
    });

    test('P1-1: a 503 is "not now": kept and tried again', () async {
      final _Server server = _Server(cap: 3)..violationStatus = 503;
      final AppStore s = await _open(server);
      s.recordViolation('1', 'Phone detected');
      await _settle();
      expect(s.violationReportsWaiting(kToken), isTrue);

      server.violationStatus = 200;
      s.retryViolationReports(kToken);
      await _settle();
      expect(s.violationReportsWaiting(kToken), isFalse);
      expect(server.count, 1);
      s.dispose();
    });

    test('P2-2: a report whose reply was lost goes again with the same '
        'stamp, and counts once', () async {
      final _Server server = _Server(cap: 2)..replyLost = true;
      final AppStore s = await _open(server);
      s.recordViolation('1', 'Phone detected');
      await _settle();
      expect(s.violationReportsWaiting(kToken), isTrue);

      server.replyLost = false;
      s.retryViolationReports(kToken);
      await _settle();
      final List<Object?> stamps = <Object?>[
        for (final ({String route, Map<String, dynamic> body}) c
            in server.calls)
          if (c.route == 'violation') c.body['at'],
      ];
      expect(stamps, hasLength(2));
      expect(stamps.first, isNotNull);
      expect(stamps.toSet(), hasLength(1), reason: 'the same report');
      expect(server.count, 1);
      expect(s.attemptById('1')!.isDone, isFalse, reason: 'cap 2, one act');
      s.dispose();
    });

    test('P3-3: an answer whose autosave failed goes before the ending '
        'report', () async {
      final _Server server = _Server()..answerFails = 1;
      final AppStore s = await _open(server);
      s.saveAnswerQuiet('1', '10', const Response(justification: 'before'));
      expect(await s.flushAnswers(), isFalse, reason: 'its autosave failed');

      server.calls.clear();
      s.recordViolation('1', 'Phone detected');
      await _settle();
      expect(server.routes.take(2), <String>['answer', 'violation']);
      expect(s.unsavedAtEnd, isEmpty, reason: 'it was kept, and said so');
      s.dispose();
    });

    test('P3-3: time_expired with a report queued: the typing still goes, '
        'and is said to', () async {
      final _Server server = _Server(cap: 5, autoSubmit: false)
        ..answerFails = 1
        ..violationDown = true;
      final AppStore s = await _open(server);
      s.saveAnswerQuiet('1', '10', const Response(justification: 'before'));
      await s.flushAnswers();
      s.recordViolation('1', 'Phone detected');
      await _settle();
      expect(s.violationReportsWaiting(kToken), isTrue);

      server
        ..violationDown = false
        ..violationStatus = 409
        ..violationCode = 'time_expired';
      server.calls.clear();
      s.retryViolationReports(kToken);
      await _settle();
      expect(server.routes.take(2), <String>['violation', 'answer']);
      expect(_said(s), contains(AppStore.timeUpMessage));
      expect(_said(s), isNot(contains(AppStore.timeUpIncompleteMessage)));
      s.dispose();
    });

    test('an answer typed after a queued report waits for it', () async {
      final _Server server = _Server(cap: 3)..violationDown = true;
      final AppStore s = await _open(server);
      s.recordViolation('1', 'Phone detected');
      await _settle();
      s.saveAnswerQuiet('1', '10', _typed);
      server.calls.clear();
      expect(await s.flushAnswers(), isFalse);
      expect(server.routes, isNot(contains('answer')));

      server.violationDown = false;
      s.retryViolationReports(kToken);
      await _settle();
      expect(server.routes, <String>['violation', 'answer']);
      s.dispose();
    });

    test('P3-4: on an auto-submit paper the typing before ANY report goes '
        'first, not only before the one this device counted last', () async {
      final _Server server = _Server(cap: 3);
      final AppStore s = await _open(server);
      s.saveAnswerQuiet('1', '10', const Response(justification: 'before'));
      server.calls.clear();
      s.recordViolation('1', 'Phone detected');
      await _settle();
      expect(server.routes.take(2), <String>['answer', 'violation']);
      s.dispose();
    });
  });

  group('the BR-D15 re-review', () {
    test('N1: an ending report the server refuses with a 500 takes the lock '
        'off on screen, and the server says the sitting ended', () async {
      final _Server server = _Server()..violationStatus = 500;
      final AppStore s = await _open(server);
      // What the screen shows: the lock as of the last repaint.
      bool shownLocked = false;
      s.addListener(() => shownLocked = s.violationLocked(kToken));

      s.recordViolation('1', 'Phone detected');
      expect(shownLocked, isTrue);
      // Its own ending raised after the count: the server answered 500, and
      // the sitting is over there all the same.
      server.ended = true;
      await _settle();

      expect(shownLocked, isFalse, reason: 'repainted without the lock');
      expect(server.routes, contains('state'), reason: 'asked where it is');
      await _settle();
      expect(s.attemptByToken(kToken)?.isDone, isTrue);
      s.dispose();
    });

    test('N1: ... and when the server says it is open: unlocked, the '
        'sitting goes on', () async {
      final _Server server = _Server()..violationStatus = 500;
      final AppStore s = await _open(server);
      bool shownLocked = false;
      s.addListener(() => shownLocked = s.violationLocked(kToken));

      s.recordViolation('1', 'Phone detected');
      await _settle();
      expect(shownLocked, isFalse);
      expect(s.attemptByToken(kToken)?.isDone, isFalse);
      s.dispose();
    });

    test('N1: "Try again" with nothing queued asks the server', () async {
      final _Server server = _Server(cap: 3);
      final AppStore s = await _open(server);
      server
        ..ended = true
        ..calls.clear();
      s.retryViolationReports(kToken);
      await _settle();
      expect(server.routes.first, 'state');
      expect(s.attemptByToken(kToken)?.isDone, isTrue);
      s.dispose();
    });

    test('N5: an answer held behind an earlier unsent report does not mark '
        'the end, once the ending report kept everything', () async {
      final _Server server = _Server(cap: 2)..violationDown = true;
      final AppStore s = await _open(server);
      s.recordViolation('1', 'Tab switched');
      await _settle();
      // Typed after the first report: held, so every flush reads false.
      s.saveAnswerQuiet('1', '10', _typed);
      expect(await s.flushAnswers(), isFalse);

      server.violationDown = false;
      s.recordViolation('1', 'Phone detected'); // the limit: it ends there
      await _settle();
      expect(s.attemptById('1')!.isDone, isTrue);
      expect(s.unsavedAtEnd, isEmpty, reason: 'all of it was kept by then');
      s.dispose();
    });

    // BR-D1: the sitting stays open while the submit is out, so the watchers
    // still fire under "Submitting...". The candidate is done: nothing they do
    // now is counted, or the server could end the sitting as a violation (its
    // own cap) instead of as their submit.
    test('P3-6: a violation under "Submitting..." is not counted, and counts '
        'again once the submit has failed', () async {
      final Completer<void> hold = Completer<void>();
      final _Server server = _Server()..holdSubmit = hold.future;
      final AppStore s = await _open(server);
      final Future<bool> submitted = s.finishExam('1', force: true);
      await _settle();

      expect(s.recordViolation('1', 'Tab switched'), isFalse);
      await _settle();
      expect(s.attemptById('1')!.violationCount, 0, reason: 'not counted');
      expect(s.violationReportsWaiting(kToken), isFalse);
      expect(server.count, 0, reason: 'nothing sent');

      hold.completeError(http.ClientException('Failed to fetch'));
      expect(await submitted, isFalse);
      // Back in the exam: the next one counts and goes out.
      s.recordViolation('1', 'Tab switched');
      await _settle();
      expect(s.attemptById('1')!.violationCount, 1);
      expect(server.count, 1);
      s.dispose();
    });

    test('N2: a violation under "Submitting..." never ends the sitting a '
        'second way: the submit stands as "Assessment submitted"', () async {
      final Completer<void> hold = Completer<void>();
      final _Server server = _Server()..holdSubmit = hold.future;
      final AppStore s = await _open(server);
      final Future<bool> submitted = s.finishExam('1', force: true);
      await _settle();

      s.recordViolation('1', 'Tab switched');
      await _settle();
      expect(s.attemptById('1')!.isDone, isFalse, reason: 'not ended by it');
      hold.complete();

      expect(await submitted, isTrue);
      expect(s.attemptById('1')!.autoSubmitReason, isNot('violation'));
      expect(_said(s), contains('Assessment submitted'));
      await _settle();
      s.dispose();
    });

    test('F5: a refresh that reads this submit back as done before its reply '
        'still says "Assessment submitted"', () async {
      final Completer<void> hold = Completer<void>();
      final _Server server = _Server(cap: 3)..holdSubmit = hold.future;
      final AppStore s = await _open(server);
      final Future<bool> submitted = s.finishExam('1', force: true);
      await _settle();

      // The server took it; the reply is still on its way when a reconnect
      // refresh reads the sitting back as done.
      server.submitted = true;
      await s.refresh();
      expect(s.attemptById('1')!.isDone, isTrue);
      hold.complete();

      expect(await submitted, isTrue);
      expect(_said(s), contains('Assessment submitted'));
      await _settle();
      s.dispose();
    });
  });

  group('the screen', () {
    Future<void> mount(WidgetTester t, AppStore s, {ProctorWatch? w}) async {
      t.view.physicalSize = const Size(1400, 1600);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: AssessmentNavScope(
            nav: AssessmentNav(),
            child: ExamScreen(
              store: s,
              token: kToken,
              sub: ExamSub.question,
              proctor: w,
            ),
          ),
        ),
      );
      await t.pump();
    }

    Future<void> done(WidgetTester t, AppStore s) async {
      await t.pumpWidget(const SizedBox());
      s.dispose();
      await t.pump(const Duration(minutes: 1));
    }

    testWidgets('RT-2: log only, report not through yet: "noted", then '
        '"recorded"', (WidgetTester t) async {
      final _Server server = _Server(cap: 5, autoSubmit: false)
        ..violationDown = true;
      final AppStore s = _store(server);
      await t.runAsync(() => s.loadExamByToken(kToken));
      await mount(t, s);

      s.recordViolation('1', 'Tab switched');
      await t.runAsync(_settle);
      await t.pump();
      expect(
        find.textContaining(
          'Proctoring violation noted (1).',
          findRichText: true,
        ),
        findsOneWidget,
      );

      server.violationDown = false;
      s.retryViolationReports(kToken);
      await t.runAsync(_settle);
      await t.pump();
      expect(
        find.textContaining(
          'Proctoring violation recorded (1).',
          findRichText: true,
        ),
        findsOneWidget,
      );
      await done(t, s);
    });

    test('F3: after a 500 dropped the ending report, the server\'s count is '
        'adopted, so the next violation is not the ending one', () async {
      final _Server server = _Server(cap: 3)..violationStatus = 500;
      final AppStore s = await _open(server);
      for (final String reason in <String>['a', 'b', 'c']) {
        s.recordViolation('1', reason);
        await _settle();
      }
      expect(server.count, 0, reason: 'none was counted');
      await _settle();

      server.violationDown = true;
      s.recordViolation('1', 'd');
      expect(s.attemptById('1')!.violationCount, 1);
      expect(s.violationLocked(kToken), isFalse, reason: 'one of three');
      s.dispose();
    });

    testWidgets('F4: the fullscreen bar says "noted" while the report of the '
        'exit is queued', (WidgetTester t) async {
      final _Server server = _Server(cap: 5)
        ..fullscreenRule = true
        ..violationDown = true;
      final AppStore s = _store(server);
      await t.runAsync(() => s.loadExamByToken(kToken));
      await mount(t, s, w: _OutOfFullscreen());
      s.recordViolation('1', 'Exited fullscreen');
      await t.runAsync(_settle);
      await t.pump();
      expect(find.textContaining('That has been noted'), findsOneWidget);

      server.violationDown = false;
      s.retryViolationReports(kToken);
      await t.runAsync(_settle);
      await t.pump();
      expect(find.textContaining('That has been recorded'), findsOneWidget);
      await done(t, s);
    });

    testWidgets('RT-6: after the ending report is dropped, the banner reads '
        'the server\'s count', (WidgetTester t) async {
      final _Server server = _Server(cap: 2);
      final AppStore s = _store(server);
      await t.runAsync(() => s.loadExamByToken(kToken));
      await mount(t, s);
      s.recordViolation('1', 'Tab switched');
      await t.runAsync(_settle);
      // The one that would end it: the server answers 500, and counted 1.
      server.violationStatus = 500;
      s.recordViolation('1', 'Phone detected');
      await t.runAsync(_settle);
      await t.runAsync(_settle);
      await t.pump();

      expect(
        find.textContaining(
          'Warning: proctoring violation 1 of 2.',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(find.text('Violation limit reached'), findsNothing);
      await done(t, s);
    });
  });
}

/// A watcher whose candidate has left fullscreen, and whose exit was a
/// recorded violation: the fullscreen bar is up.
class _OutOfFullscreen implements ProctorWatch {
  @override
  void start({
    required ProctorRules rules,
    required void Function(String reason) onViolation,
    void Function()? onCameraChanged,
  }) {}
  @override
  void stop() {}
  @override
  void setEvidencePolicy(Map<String, Object?> policy) {}
  @override
  void requestFullscreen() {}
  @override
  bool get isFullscreen => false;
  @override
  bool get needsFullscreenPrompt => false;
  @override
  bool get shouldOfferReturnToFullscreen => true;
  @override
  void exitFullscreen() {}
  @override
  void requestCamera() {}
  @override
  CameraState get cameraState => CameraState.idle;
  @override
  String get cameraMessage => '';
  @override
  String? get cameraViewType => null;
  @override
  String? fullscreenButtonView() => null;
  @override
  bool get fullscreenRefused => false;
  @override
  bool get fullscreenExitRecorded => true;
  @override
  bool get escapeCaptured => false;
}
